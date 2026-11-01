import AppKit
import CoreText
import XCTest

@testable import FormCore
@testable import FormGraphics

final class SVGImportTests: XCTestCase {
  private static func svg(
    _ content: String,
    attributes: String = "width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\""
  ) -> Data {
    Data("<svg xmlns=\"http://www.w3.org/2000/svg\" \(attributes)>\(content)</svg>".utf8)
  }
  func testPhysicalUnitsViewBoxAndTextBaselineRemainExact() async throws {
    try await MainActor.run {
      let result = try SVGImporter.read(
        Self.svg(
          """
          <rect id="frame" x="10" y="20" width="200" height="100" fill="navy"/>
          <text id="label" x="110" y="70" font-family="Arial" font-size="10" text-anchor="middle">Orbit</text>
          """, attributes: "width=\"2in\" height=\"72pt\" viewBox=\"10 20 200 100\""))
      XCTAssertEqual(result.width, 50.8, accuracy: 1e-9)
      XCTAssertEqual(result.height, 25.4, accuracy: 1e-9)
      let e = result.artwork.elements.first { $0.name == "frame" }!
      let b = result.artwork.bounds(of: e)
      XCTAssertEqual(b.x, 0, accuracy: 1e-9)
      XCTAssertEqual(b.y, 0, accuracy: 1e-9)
      XCTAssertEqual(b.width, 50.8, accuracy: 1e-9)
      XCTAssertEqual(b.height, 25.4, accuracy: 1e-9)
      let text = result.artwork.elements.first { $0.kind == "text" }!
      XCTAssertEqual(text.fontSize, 7.2, accuracy: 1e-9)
      let baseline = result.artwork.worldTransform(text).apply(
        .init(0, TypographyEngine.firstBaseline(text)))
      XCTAssertEqual(baseline.y, 12.7, accuracy: 1e-7)
      XCTAssertFalse(result.hasWarnings)
      let large = try SVGImporter.read(
        Self.svg(
          "<rect width=\"10\" height=\"10\"/>", attributes: "width=\"1000mm\" height=\"1mm\""))
      XCTAssertEqual(large.width, 1000)
      XCTAssertEqual(large.height, 1)
    }
  }
  func testAllPathCommandsCreateEditableNodesAndReflectControls() throws {
    let p = try SVGGeometry.path(
      "m10 10 10 0 v10 h-10 z M30 10 C35 0 45 0 50 10 s15 10 20 0 Q75 0 80 10 t10 0 A5 5 0 0 1 100 10"
    )
    let e = try VectorGeometry.element(from: p, color: "#000000")
    XCTAssertEqual(e.path?.contours.count, 2)
    XCTAssertTrue(e.path!.contours[0].closed)
    XCTAssertFalse(e.path!.contours[1].closed)
    let nodes = e.path!.contours[1].nodes
    XCTAssertEqual(nodes[1].outgoing?.x, 45)  // reflected control 55 minus path minX 10
    XCTAssertEqual(nodes[1].outgoing!.y, 20 - Double(p.boundingBoxOfPath.minY), accuracy: 1e-6)
    XCTAssertNotNil(nodes.last?.incoming)
    XCTAssertEqual(try SVGScanner.numbers("1e2 -2.5e-1 .5").count, 3)
    XCTAssertEqual(try SVGLength.value("1.5em", font: 20), 30)
    XCTAssertThrowsError(try SVGGeometry.path("L1 2"))
    XCTAssertThrowsError(try SVGGeometry.path("M0 0 A5 5 0 2 1 10 0"))
    XCTAssertThrowsError(try SVGGeometry.path("M0 0 L1e+ 4"))
  }
  func testArcsCorrectRadiiAndCompactFlagsWithoutLosingEndpoints() throws {
    for flags in ["01", "10"] {
      let path = try SVGGeometry.path("M0 0 A5 5 0 \(flags)20 0")
      XCTAssertEqual(path.boundingBoxOfPath.width, 20, accuracy: 1e-6)
      XCTAssertEqual(path.boundingBoxOfPath.height, 10, accuracy: 0.0001)
      XCTAssertEqual(path.currentPoint.x, 20, accuracy: 1e-9)
      XCTAssertEqual(path.currentPoint.y, 0, accuracy: 1e-9)
    }
    let line = try SVGGeometry.path("M0 0 A0 8 45 0 1 10 10")
    XCTAssertEqual(line.currentPoint, CGPoint(x: 10, y: 10))
    XCTAssertThrowsError(try SVGGeometry.path("M0 0 A1e-50 5 0 0 1 10 0"))
  }
  func testTransformOrderRotationCenterAndReflection() throws {
    let t = try SVGGeometry.transform("translate(10 20) rotate(90,2,3) scale(-2 .5)")
    let expected = Affine2.translation(10, 20).followed(by: .translation(2, 3)).followed(
      by: .rotation(90)
    ).followed(by: .translation(-2, -3)).followed(by: .scale(-2, 0.5))
    XCTAssertEqual(t.apply(.init(4, 5)).x, expected.apply(.init(4, 5)).x, accuracy: 1e-9)
    XCTAssertEqual(t.apply(.init(4, 5)).y, expected.apply(.init(4, 5)).y, accuracy: 1e-9)
    XCTAssertThrowsError(try SVGGeometry.transform("scale(0)"))
    XCTAssertThrowsError(try SVGGeometry.transform("translate(10) garbage(2)"))
  }
  func testCSSCascadeInheritanceAndRichUTF16Text() async throws {
    try await MainActor.run {
      let r = try SVGImporter.read(
        Self.svg(
          """
          <style>rect{fill:red}.ink{fill:blue}#shape{fill:green}g .ink{stroke:gold;stroke-width:2}</style>
          <g fill="orange"><rect id="shape" class="ink" width="20" height="20" style="fill:rebeccapurple!important"/>
          <text x="5" y="50" font-family="Arial" font-size="10">A<tspan fill="red" font-weight="bold">🚀B</tspan></text></g>
          """))
      let e = r.artwork.elements.first { $0.name == "shape" }!
      XCTAssertEqual(e.color, "#663399")
      XCTAssertEqual(e.stroke?.color, "#FFD700")
      let text = r.artwork.elements.first { $0.kind == "text" }!
      XCTAssertEqual(text.text, "A🚀B")
      XCTAssertEqual(text.textRuns?.count, 2)
      XCTAssertEqual(text.textRuns?[1].location, 1)
      XCTAssertEqual(text.textRuns?[1].length, 3)
      XCTAssertEqual(text.textRuns?[1].color, "#FF0000")
      XCTAssertFalse(r.hasWarnings)
    }
  }
  func testPositionedSpansStaySeparateEditableTextAtTheirBaselines() async throws {
    try await MainActor.run {
      let r = try SVGImporter.read(
        Self.svg(
          "<text x=\"10\" y=\"20\" font-family=\"Arial\" font-size=\"8\">First<tspan x=\"10\" dy=\"12\">Second</tspan></text>"
        ))
      let texts = r.artwork.elements.filter { $0.kind == "text" }
      XCTAssertEqual(texts.count, 2)
      let baseline = texts.map {
        r.artwork.worldTransform($0).apply(.init(0, TypographyEngine.firstBaseline($0))).y
      }
      XCTAssertEqual(baseline[0], 20, accuracy: 1e-7)
      XCTAssertEqual(baseline[1], 32, accuracy: 1e-7)
      XCTAssertFalse(r.hasWarnings)
    }
  }
  func testUseExpansionNestedViewportAndReferenceCycleSafety() async throws {
    try await MainActor.run {
      let r = try SVGImporter.read(
        Self.svg(
          """
          <defs><symbol id="mark" viewBox="0 0 10 10"><rect width="10" height="10" fill="red"/></symbol></defs>
          <use href="#mark" x="10" y="20" width="20" height="30"/>
          <svg x="50" y="60" width="20" height="10" viewBox="0 0 10 10" preserveAspectRatio="none"><rect id="nested" width="10" height="10"/></svg>
          """))
      XCTAssertEqual(r.artwork.elements.filter { $0.kind == "path" }.count, 2)
      let e = r.artwork.elements.first { $0.name == "nested" }!
      let b = r.artwork.bounds(of: e)
      XCTAssertEqual(b.x, 50, accuracy: 1e-7)
      XCTAssertEqual(b.y, 60, accuracy: 1e-7)
      XCTAssertEqual(b.width, 20, accuracy: 1e-7)
      XCTAssertEqual(b.height, 10, accuracy: 1e-7)
      XCTAssertFalse(r.hasWarnings)
      XCTAssertThrowsError(
        try SVGImporter.read(
          Self.svg("<defs><g id=\"loop\"><use href=\"#loop\"/></g></defs><use href=\"#loop\"/>")))
    }
  }
  func testGroupOpacityAndAlphaGradientRenderWithTransparency() async throws {
    try await MainActor.run {
      let r = try SVGImporter.read(
        Self.svg(
          """
          <defs><linearGradient id="ink"><stop offset="0" stop-color="red" stop-opacity=".25"/><stop offset="1" stop-color="blue" stop-opacity=".75"/></linearGradient></defs>
          <g opacity=".6"><rect width="100" height="100" fill="url(#ink)" fill-opacity=".5"/></g>
          """))
      let bitmap = Self.bitmap(r)
      XCTAssertEqual(bitmap.colorAt(x: 250, y: 250)!.alphaComponent, 0.15, accuracy: 0.012)
      XCTAssertLessThan(
        bitmap.colorAt(x: 50, y: 250)!.alphaComponent,
        bitmap.colorAt(x: 450, y: 250)!.alphaComponent)
      let text = try SVGRenderer.document(
        r.artwork, width: r.width, height: r.height, assets: URL(fileURLWithPath: "/tmp"))
      XCTAssertTrue(text.contains("gradientTransform="))
      XCTAssertTrue(text.contains("stop-opacity=\"0.25\""))
      XCTAssertTrue(text.contains("fill-opacity=\"0.5\""))
    }
  }
  func testNativeClipsIncludeObjectBoundsTransformsAndHoles() async throws {
    try await MainActor.run {
      let r = try SVGImporter.read(
        Self.svg(
          """
          <defs><clipPath id="cut" clipPathUnits="objectBoundingBox"><path clip-rule="evenodd" d="M0 0H1V1H0Z M.3 .3H.7V.7H.3Z"/></clipPath></defs>
          <g transform="translate(10 10)"><rect width="80" height="80" fill="navy" clip-path="url(#cut)"/></g>
          """))
      let b = Self.bitmap(r)
      XCTAssertEqual(b.colorAt(x: 250, y: 250)!.alphaComponent, 0, accuracy: 0.01)
      XCTAssertGreaterThan(b.colorAt(x: 100, y: 100)!.alphaComponent, 0.99)
      XCTAssertEqual(b.colorAt(x: 15, y: 15)!.alphaComponent, 0, accuracy: 0.01)
      XCTAssertFalse(r.hasWarnings)
    }
  }
  func testUnsupportedFeaturesAreReportedAndNoExternalImagesAreRead() async throws {
    try await MainActor.run {
      let r = try SVGImporter.read(
        Self.svg(
          """
          <rect width="20" height="20" filter="url(#blur)"/>
          <image href="file:///etc/passwd" width="10" height="10"/>
          <script>throw new Error('must never run')</script><foreignObject width="10" height="10"><div>HTML</div></foreignObject>
          """))
      XCTAssertTrue(r.hasWarnings)
      XCTAssertEqual(r.assets.count, 0)
      XCTAssertTrue(r.issues.contains { $0.element == "script" })
      XCTAssertTrue(r.issues.contains { $0.message.contains("filter") })
    }
  }
  func testXMLDeclarationsMalformedPathsAndExcessiveExpansionAreRejected() async throws {
    try await MainActor.run {
      let xml = "<!DOCTYPE svg [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><svg>&secret;</svg>"
      XCTAssertThrowsError(try SVGImporter.read(Data(xml.utf8)))
      XCTAssertThrowsError(try SVGImporter.read(xml.data(using: .utf16)!))
      XCTAssertThrowsError(try SVGImporter.read(Self.svg("<path d=\"M0 0 C1 2\"/>")))
      XCTAssertThrowsError(
        try SVGImporter.read(
          Self.svg(
            String(repeating: "<g>", count: 65) + "<rect width=\"1\" height=\"1\"/>"
              + String(repeating: "</g>", count: 65))))
      XCTAssertThrowsError(try SVGImporter.read(Self.svg("<rect id=\"same\"/><rect id=\"same\"/>")))
    }
  }
  func testEmbeddedImageCropKeepsOriginalBytesAndGroupCoordinates() async throws {
    try await MainActor.run {
      let image = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      )!
      image.setColor(.red, atX: 0, y: 0)
      image.setColor(.blue, atX: 1, y: 0)
      let png = image.representation(using: .png, properties: [:])!
      let r = try SVGImporter.read(
        Self.svg(
          "<g transform=\"translate(10 10)\"><image x=\"10\" y=\"10\" width=\"40\" height=\"40\" preserveAspectRatio=\"xMidYMid slice\" href=\"data:image/png;base64,\(png.base64EncodedString())\"/></g>"
        ))
      let element = r.artwork.elements.first { $0.kind == "image" }!
      XCTAssertEqual(r.assets[element.asset!], png)
      let mask = r.artwork.elements.first { $0.id == element.clipID }!
      XCTAssertEqual(element.parentID, mask.parentID)
      let box = r.artwork.bounds(of: mask)
      XCTAssertEqual(box.x, 20, accuracy: 1e-6)
      XCTAssertEqual(box.y, 20, accuracy: 1e-6)
      XCTAssertEqual(box.width, 40, accuracy: 1e-6)
      XCTAssertEqual(box.height, 40, accuracy: 1e-6)
      let disguisedGIF = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
      XCTAssertThrowsError(
        try SVGImporter.read(
          Self.svg(
            "<image width=\"10\" height=\"10\" href=\"data:image/png;base64,\(disguisedGIF)\"/>")))
    }
  }
  func testProcessingInstructionsCSSAtRulesAndAnimationNeedReview() async throws {
    try await MainActor.run {
      let xml =
        "<?xml-stylesheet href=\"file:///missing.css\"?>"
        + String(
          decoding: Self.svg(
            "<style>@media print { rect {fill:red} }</style><rect width=\"20\" height=\"20\"><animate attributeName=\"width\" to=\"80\"/></rect>"
          ), as: UTF8.self)
      let result = try SVGImporter.read(Data(xml.utf8))
      XCTAssertTrue(result.hasWarnings)
      XCTAssertTrue(result.issues.contains { $0.message.contains("Processing instruction") })
      XCTAssertTrue(result.issues.contains { $0.message.contains("at-rules") })
      XCTAssertTrue(result.issues.contains { $0.message.contains("Animation") })
      XCTAssertEqual(result.artwork.elements.first { $0.kind == "path" }?.color, "#000000")
    }
  }
  func testImportMatchesSystemSVGRenderingForTrustedArtwork() async throws {
    try await MainActor.run {
      let data = Self.svg(
        """
        <defs><linearGradient id="ink" gradientTransform="rotate(20 .5 .5)"><stop offset="0" stop-color="#D45A37"/><stop offset="1" stop-color="#224B9B"/></linearGradient><clipPath id="cut"><circle cx="50" cy="50" r="30"/></clipPath></defs>
        <rect width="100" height="100" fill="white"/>
        <g opacity=".7" transform="translate(5 8) rotate(12 40 30)"><rect x="10" y="10" width="60" height="35" fill="url(#ink)" stroke="navy" stroke-width="1" stroke-dasharray="3 2"/></g>
        <path d="M10 55 Q50 10 90 55 T90 90 L10 90Z" clip-path="url(#cut)" fill="#DCCB83"/>
        <text x="8" y="94" font-family="Arial" font-size="9">Orbit — 01</text>
        """)
      let imported = try SVGImporter.read(data)
      guard let source = NSImage(data: data) else {
        throw XCTSkip("System SVG decoder unavailable.")
      }
      var box = CGRect(x: 0, y: 0, width: 500, height: 500)
      let reference = NSBitmapImageRep(
        cgImage: source.cgImage(forProposedRect: &box, context: nil, hints: nil)!)
      let actual = Self.bitmap(imported)
      var error = 0.0
      for y in stride(from: 0, to: 500, by: 3) {
        for x in stride(from: 0, to: 500, by: 3) {
          let a = actual.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
          let b = reference.colorAt(
            x: min(reference.pixelsWide - 1, x * reference.pixelsWide / 500),
            y: min(reference.pixelsHigh - 1, y * reference.pixelsHigh / 500))!.usingColorSpace(
              .sRGB)!
          error +=
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
        }
      }
      XCTAssertLessThan(error / (167 * 167 * 3), 0.035)
    }
  }
  func testImportIsOneUndoableEditAndRetainsSourceWhenLinked() async throws {
    try await MainActor.run {
      let result = try SVGImporter.read(Self.svg("<path d=\"M10 10 H90 V90 H10Z\" fill=\"#246\"/>"))
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: folder) }
      let repo = try ProjectRepository(root: folder)
      let engine = OperationEngine(repository: repo)
      engine.project = Project(name: "SVG import")
      var id = UUID()
      let source = ArtworkImport(
        asset: "original.svg", name: "Imported mark", width: result.width, height: result.height)
      try engine.edit("SVG import") { id = try $0.importArtwork(result.artwork, source: source) }
      let sheet = engine.project!.objects.first { $0.id == id }!
      var physical = try engine.project!.makeObject(
        recipeID: "box", parameters: ["width": 140, "depth": 140])
      engine.project!.objects.append(physical)
      try engine.project!.linkArtwork(physical.id, sourceID: id)
      physical = engine.project!.objects.first { $0.id == physical.id }!
      let extra = try SVGImporter.read(
        Self.svg("<circle cx=\"50\" cy=\"50\" r=\"20\" fill=\"red\"/>"))
      try engine.edit("Add to linked source") { p in
        XCTAssertEqual(
          try p.importArtwork(extra.artwork, source: source, targetID: physical.id), id)
      }
      XCTAssertEqual(engine.project!.objects.first { $0.id == physical.id }, physical)
      XCTAssertGreaterThan(
        engine.project!.editableArtwork(physical)!.elements.count, sheet.artwork!.elements.count)
      engine.undo()
      XCTAssertEqual(engine.project!.editableArtwork(physical), sheet.artwork)
      engine.redo()
      try engine.flush()
      let loaded = try repo.load(engine.project!.id)
      XCTAssertEqual(loaded.schemaVersion, 58)
      XCTAssertEqual(loaded.editableArtwork(physical)?.imports?.last?.elementIDs, extra.artwork.elements.map(\.id))
      XCTAssertEqual(loaded.editableArtwork(physical)?.imports?.count, 2)
      var bad = source
      bad.asset = "../escape.svg"
      let before = engine.project!
      XCTAssertThrowsError(
        try engine.edit("Invalid import") { _ = try $0.importArtwork(extra.artwork, source: bad) })
      XCTAssertEqual(engine.project, before)
    }
  }
  @MainActor func testImportOntoBarePhysicalFacePreservesMaterialAndCentersArtwork() throws {
    let result = try SVGImporter.read(Self.svg("<circle cx=\"50\" cy=\"50\" r=\"20\"/>"))
    var project = Project(name: "Direct surface import")
    let box = try project.makeObject(
      recipeID: "box", parameters: ["width": 140, "depth": 120], materialID: "oak")
    project.objects.append(box)
    XCTAssertNil(box.artwork)
    let source = ArtworkImport(
      asset: "mark.svg", name: "Mark", width: result.width, height: result.height)
    XCTAssertEqual(
      try project.importArtwork(result.artwork, source: source, targetID: box.id), box.id)
    let imported = project.objects.first { $0.id == box.id }!
    XCTAssertEqual(imported.materialID, box.materialID)
    XCTAssertEqual(imported.parameters, box.parameters)
    XCTAssertEqual(imported.artwork?.backgroundOpacity, 0)
    XCTAssertEqual(imported.artwork?.bleed, 0)
    let root = imported.artwork!.elements.first { $0.parentID == nil && $0.hidden != true }!
    let oldRoot = result.artwork.elements.first { $0.id == root.id }!
    let original = (oldRoot.affine ?? .init()).apply(.init())
    let placed = root.affine!.apply(.init())
    XCTAssertEqual(placed.x - original.x, (140 - result.width) / 2, accuracy: 1e-9)
    XCTAssertEqual(placed.y - original.y, (120 - result.height) / 2, accuracy: 1e-9)
  }
  @MainActor private static func bitmap(_ result: SVGImportResult) -> NSBitmapImageRep {
    ArtworkRenderer.image(
      result.artwork, width: result.width, height: result.height,
      assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 5
    ).representations[0] as! NSBitmapImageRep
  }
}

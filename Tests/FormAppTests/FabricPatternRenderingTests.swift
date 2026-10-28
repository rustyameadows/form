import AppKit
import SceneKit
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class FabricPatternRenderingTests: XCTestCase {
  private func fixture() throws -> (StudioStore, UUID, UUID) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var p = Samples.flightJacket()
    var tile = try p.makeObject(recipeID: "artboard", name: "Fabric motif", parameters: ["width": 40, "depth": 20])
    var art = Artwork(background: "#F4E7C6", bleed: 0); art.backgroundOpacity = 0
    art.elements = [ArtworkElement(kind: "rectangle", x: 2, y: 3, width: 8, height: 5, color: "#DA3028"),
      ArtworkElement(kind: "rectangle", x: 26, y: 12, width: 6, height: 4, color: "#2942C6")]
    tile.artwork = art; p.objects.append(tile)
    var pattern = FabricPattern(sourceObjectID: tile.id); pattern.outputWidth = 120; pattern.outputLength = 80
    try p.setFabricPattern(pattern, materialID: "flight-nylon")
    store.engine.project = p
    return (store, tile.id, p.objects[0].id)
  }
  private func close(_ store: StudioStore) { try? FileManager.default.removeItem(at: store.repository.root) }
  private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep { try XCTUnwrap(image.representations.first as? NSBitmapImageRep) }
  private func rgb(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
    var pixel = [UInt](repeating: 0, count: 4)
    bitmap.getPixel(&pixel, atX: x, y: y)
    return NSColor(srgbRed: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255, alpha: Double(pixel[3]) / 255)
  }
  private func assertColor(_ actual: NSColor, _ hex: String, file: StaticString = #filePath, line: UInt = #line) {
    let expected = NSColor(hex: hex).usingColorSpace(.sRGB)!
    XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.035, file: file, line: line)
    XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.035, file: file, line: line)
    XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.035, file: file, line: line)
  }
  private func preview(_ design: ResolvedFabricPattern, assets: URL, width: Double, height: Double, density: Double) throws -> NSBitmapImageRep {
    let w = Int(width * density), h = Int(height * density)
    let graphics = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    graphics.translateBy(x: 0, y: Double(h)); graphics.scaleBy(x: density, y: -density)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: true)
    FabricPatternRenderer.drawPreview(design, assets: assets, width: width, height: height)
    NSGraphicsContext.restoreGraphicsState(); return NSBitmapImageRep(cgImage: graphics.makeImage()!)
  }
  func testRasterAndCachedPreviewAgreeOnAsymmetricPhysicalMotifsForEveryRepeatMode() throws {
    let (store, _, _) = try fixture(); defer { close(store) }
    let assets = store.repository.url(for: store.project!.id).appendingPathComponent("Assets")
    for mode in FabricPattern.Repeat.allCases {
      var p = store.project!, pattern = p.material("flight-nylon").fabric!.pattern!; pattern.repeatMode = mode
      try p.setFabricPattern(pattern, materialID: "flight-nylon")
      let design = try XCTUnwrap(p.resolvedFabricPattern(materialID: "flight-nylon"))
      let direct = try bitmap(FabricPatternRenderer.image(design, assets: assets, width: 120, height: 80, pixelsPerMM: 4))
      let cached = try preview(design, assets: assets, width: 120, height: 80, density: 4)
      // Interior points avoid antialiased contour/clip pixels while detecting flips and wrong phase.
      for y in stride(from: 5, to: 78, by: 7) { for x in stride(from: 3, to: 118, by: 7) {
        let a = rgb(direct, x * 4, y * 4), b = rgb(cached, x * 4, y * 4)
        // Supersampling gives different boundary coverage; compare only genuinely uniform interiors.
        let nearby = [(-2, 0), (2, 0), (0, -2), (0, 2)].map { rgb(direct, x * 4 + $0.0, y * 4 + $0.1) }
        if nearby.contains(where: { abs($0.redComponent - a.redComponent) > 0.01 || abs($0.blueComponent - a.blueComponent) > 0.01 }) { continue }
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.06, "\(mode): \(x),\(y)")
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.06, "\(mode): \(x),\(y)")
      } }
      if mode == .straight {
        assertColor(rgb(direct, 5 * 4, 5 * 4), "#DA3028")
        assertColor(rgb(direct, 45 * 4, 25 * 4), "#DA3028")
        assertColor(rgb(direct, 28 * 4, 14 * 4), "#2942C6")
        assertColor(rgb(direct, 18 * 4, 10 * 4), p.material("flight-nylon").color)
      }
      if mode == .halfDrop { assertColor(rgb(direct, 45 * 4, 15 * 4), "#DA3028") }
      if mode == .brick { assertColor(rgb(direct, 25 * 4, 25 * 4), "#DA3028") }
      if mode == .mirror { assertColor(rgb(direct, 75 * 4, 35 * 4), "#DA3028") }
    }
  }
  func testRotatedOffsetAndScaledPreviewKeepsTheSamePhysicalPhaseAsVectorOutput() throws {
    let (store, _, _) = try fixture(); defer { close(store) }
    var p = store.project!, pattern = p.material("flight-nylon").fabric!.pattern!
    pattern.scale = 0.75; pattern.rotation = 90; pattern.offset = .init(70, 7); pattern.spacing = .init(8, 4)
    pattern.repeatMode = .halfDrop; try p.setFabricPattern(pattern, materialID: "flight-nylon")
    let design = try XCTUnwrap(p.resolvedFabricPattern(materialID: "flight-nylon")), assets = store.repository.root
    let direct = try bitmap(FabricPatternRenderer.image(design, assets: assets, width: 100, height: 80, pixelsPerMM: 4))
    let cached = try preview(design, assets: assets, width: 100, height: 80, density: 4)
    let red = pattern.latticeTransform.apply(.init(5 * pattern.scale, 5 * pattern.scale))
    assertColor(rgb(direct, Int(red.x * 4), Int(red.y * 4)), "#DA3028")
    assertColor(rgb(cached, Int(red.x * 4), Int(red.y * 4)), "#DA3028")
    let svg = try FabricPatternRenderer.svg(design, assets: assets, width: 100, height: 80)
    XCTAssertTrue(svg.contains("patternUnits=\"userSpaceOnUse\"")); XCTAssertTrue(svg.contains("width=\"100.0mm\""))
    XCTAssertTrue(svg.contains("patternTransform=\"matrix(")); XCTAssertTrue(svg.contains("70.0 7.0)"))
  }
  func testRotatedFabricBaseHasNoTransparentHairlinesAtRepeatBoundaries() throws {
    let (store, _, _) = try fixture(); defer { close(store) }
    var p = store.project!, pattern = p.material("flight-nylon").fabric!.pattern!
    pattern.repeatMode = .halfDrop; pattern.rotation = 15; pattern.offset = .init(12, 7)
    pattern.spacing = .init(4, 4); try p.setFabricPattern(pattern, materialID: "flight-nylon")
    let design = try XCTUnwrap(p.resolvedFabricPattern(materialID: "flight-nylon"))
    let rep = try bitmap(FabricPatternRenderer.image(design, assets: store.repository.root, width: 180, height: 120, pixelsPerMM: 3))
    XCTAssertEqual(rep.samplesPerPixel, 4); XCTAssertEqual(rep.bitsPerSample, 8)
    let data = try XCTUnwrap(rep.bitmapData), alpha = rep.bitmapFormat.contains(.alphaFirst) ? 0 : 3
    var gaps = 0
    for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
      if data[y * rep.bytesPerRow + x * 4 + alpha] != 255 { gaps += 1 }
    } }
    XCTAssertEqual(gaps, 0, "Repeated fabric must have one opaque continuous base, including rotated supertile boundaries.")
  }
  func testSourcePaintAndFrameEditsInvalidateGarmentTextureAndGeometryCache() throws {
    let (store, tileID, garmentID) = try fixture(); defer { close(store) }
    let p = store.project!, assets = store.repository.root, garment = p.objects.first { $0.id == garmentID }!
    let before = try XCTUnwrap(p.resolvedFabricPattern(materialID: "flight-nylon"))
    let first = FabricPatternRenderer.texture(before, assets: assets, limit: 512)
    XCTAssertTrue(first === FabricPatternRenderer.texture(before, assets: assets, limit: 512))
    var placementOnly = before; placementOnly.pattern.rotation = 71; placementOnly.pattern.offset = .init(17, -39)
    placementOnly.pattern.outputLength = 500; placementOnly.pattern.outputWidth = 1400
    XCTAssertTrue(first === FabricPatternRenderer.texture(placementOnly, assets: assets, limit: 512),
      "Changing yardage size or lattice placement must reuse the shaped/rasterized motif texture.")
    var changed = p, i = changed.objects.firstIndex { $0.id == tileID }!
    changed.objects[i].artwork!.elements[0].color = "#13C358"; changed.objects[i].parameters["width"] = 60
    let after = try XCTUnwrap(changed.resolvedFabricPattern(materialID: "flight-nylon"))
    let second = FabricPatternRenderer.texture(after, assets: assets, limit: 512)
    XCTAssertFalse(first === second); XCTAssertNotEqual(before.renderDefinition, after.renderDefinition)
    let controller = TableSceneController(store: store)
    controller.sync(p, selection: [], isolated: [], showGrid: true, studio: false, preset: "Perspective", assets: assets)
    let builds = controller.geometryBuilds
    var outputOnly = p, exportSettings = p.material("flight-nylon").fabric!.pattern!
    exportSettings.outputWidth = 1400; exportSettings.outputLength = 1500
    exportSettings.colorways = [FabricColorway(name: "Unused colorway", baseColor: "#AA2244")]
    try outputOnly.setFabricPattern(exportSettings, materialID: "flight-nylon")
    XCTAssertEqual(before.renderDefinition, try outputOnly.resolvedFabricPattern(materialID: "flight-nylon")!.renderDefinition)
    controller.sync(outputOnly, selection: [], isolated: [], showGrid: true, studio: false, preset: "Perspective", assets: assets)
    XCTAssertEqual(controller.geometryBuilds, builds, "Output dimensions and inactive colorways must not rebuild the Table.")
    controller.sync(changed, selection: [], isolated: [], showGrid: true, studio: false, preset: "Perspective", assets: assets)
    XCTAssertGreaterThan(controller.geometryBuilds, builds)
    let node = GeometryFactory.object(garment, project: changed, assets: assets)
    var patternedMaterial: SCNMaterial?
    node.enumerateChildNodes { child, _ in
      if let material = child.geometry?.firstMaterial, !SCNMatrix4EqualToMatrix4(material.diffuse.contentsTransform, SCNMatrix4Identity) { patternedMaterial = material }
    }
    let material = try XCTUnwrap(patternedMaterial)
    XCTAssertTrue(material.diffuse.contents is NSImage); XCTAssertEqual(material.diffuse.wrapS, .repeat)
    let expected = after.pattern.bomberTextureTransform(sourceSize: after.sourceSize), actual = material.diffuse.contentsTransform
    XCTAssertEqual(Double(actual.m11), expected.a, accuracy: 1e-6); XCTAssertEqual(Double(actual.m22), expected.d, accuracy: 1e-6)
    XCTAssertEqual(changed.objects.filter { $0.textile?.attachment != nil }, p.objects.filter { $0.textile?.attachment != nil })
  }
  func testYardageMCPExportsPhysicalSVGAndVectorPDFAndKeepsOriginalArtwork() throws {
    let (store, tileID, garmentID) = try fixture(); defer { close(store) }
    let before = store.project!
    let folder = store.repository.root.appendingPathComponent("Exports"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for format in ["svg", "pdf", "png"] {
      let path = folder.appendingPathComponent("yardage." + format)
      let result = try store.graphicsCall("form_export_artwork", ["object_id": garmentID.uuidString, "fabric_pattern_material": "flight-nylon", "format": format, "path": path.path, "dpi": 72]) as! [String: Any]
      XCTAssertEqual(result["width_mm"] as? Double, 120); XCTAssertEqual(result["height_mm"] as? Double, 80)
      XCTAssertEqual(result["source_object_id"] as? String, tileID.uuidString)
      let data = try Data(contentsOf: path); XCTAssertGreaterThan(data.count, 300)
      if let proofDirectory = ProcessInfo.processInfo.environment["FORM_FABRIC_PROOF_DIR"] {
        let proof = URL(fileURLWithPath: proofDirectory)
        try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
        try data.write(to: proof.appendingPathComponent("yardage." + format), options: .atomic)
      }
      if format == "pdf" {
        let document = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!)), page = try XCTUnwrap(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        XCTAssertEqual(box.width / TypographyEngine.pointsPerMM, 120, accuracy: 0.001)
        XCTAssertEqual(box.height / TypographyEngine.pointsPerMM, 80, accuracy: 0.001)
      }
      if format == "png" { let rep = try XCTUnwrap(NSBitmapImageRep(data: data)); XCTAssertEqual(rep.pixelsWide, 341); XCTAssertEqual(rep.pixelsHigh, 227) }
    }
    XCTAssertEqual(store.project, before)
    XCTAssertThrowsError(try store.exportFabricPattern(materialID: "flight-sage", arguments: ["format": "svg"]))
    XCTAssertThrowsError(try store.exportFabricPattern(materialID: "flight-nylon", arguments: ["format": "svg", "roles": ["print"]]))
    XCTAssertThrowsError(try store.exportFabricPattern(materialID: "flight-nylon", arguments: ["format": "png", "path": folder.appendingPathComponent("must-not-exist.png").path, "dpi": 1201]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("must-not-exist.png").path))
    if let proofDirectory = ProcessInfo.processInfo.environment["FORM_FABRIC_PROOF_DIR"] {
      let proof = URL(fileURLWithPath: proofDirectory)
      var design = try XCTUnwrap(before.resolvedFabricPattern(materialID: "flight-nylon"))
      design.sourceSize = .init(40, 40); design.baseColor = "#233748"
      design.pattern.repeatMode = .halfDrop; design.pattern.scale = 1.2
      design.pattern.spacing = .init(4, 4); design.pattern.rotation = 15; design.pattern.offset = .init(12, 7)
      design.artwork.elements = [ArtworkElement(kind: "star", x: 12, y: 9, width: 16, height: 16, color: "#DB814A"),
        ArtworkElement(kind: "ellipse", x: 6, y: 29, width: 3, height: 3, color: "#C8C4A9"),
        ArtworkElement(kind: "ellipse", x: 30, y: 4, width: 3, height: 3, color: "#C8C4A9")]
      try FabricPatternRenderer.pdf(design, assets: store.repository.root, width: 300, height: 200, dpi: 150)
        .write(to: proof.appendingPathComponent("flight-repeat.pdf"), options: .atomic)
      try Data(FabricPatternRenderer.svg(design, assets: store.repository.root, width: 300, height: 200).utf8)
        .write(to: proof.appendingPathComponent("flight-repeat.svg"), options: .atomic)
      let image = try bitmap(FabricPatternRenderer.image(design, assets: store.repository.root, width: 300, height: 200, pixelsPerMM: 3))
      try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: proof.appendingPathComponent("flight-repeat.png"), options: .atomic)
    }
  }
}

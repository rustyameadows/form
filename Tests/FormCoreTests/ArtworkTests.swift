import AppKit
import CoreText
import XCTest

@testable import FormCore
@testable import FormGraphics

final class ArtworkTests: XCTestCase {
  func testVerticalAlignmentMovesVisibleTextDownAndPreservesOutlineInk() async throws {
    try await MainActor.run {
      var element = ArtworkElement(
        kind: "text", x: 0, y: 0, width: 50, height: 40,
        text: "12", color: "#111111", fontSize: 36)
      var style = Typography()
      style.fontName = "Georgia"
      style.alignment = "center"
      style.underline = true
      element.typography = style
      let top = try TypographyEngine.outlines(element).boundingBoxOfPath
      for alignment in ["middle", "bottom"] {
        element.typography?.verticalAlignment = alignment
        let outline = try TypographyEngine.outlines(element)
        let box = outline.boundingBoxOfPath
        let offset = TypographyEngine.verticalOffset(element)
        XCTAssertGreaterThan(offset, 10)
        XCTAssertEqual(box.minY, top.minY + offset, accuracy: 1e-6)
        XCTAssertEqual(box.height, top.height, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(box.maxY, element.height)
        let vector = try VectorGeometry.element(from: outline, color: element.color)
        let original = ArtworkRenderer.image(
          .init(background: "#FFFFFF", elements: [element]), width: 50, height: 40,
          assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 4)
        let converted = ArtworkRenderer.image(
          .init(background: "#FFFFFF", elements: [vector]), width: 50, height: 40,
          assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 4)
        let a = original.representations[0] as! NSBitmapImageRep
        let b = converted.representations[0] as! NSBitmapImageRep
        let count = a.bytesPerRow * a.pixelsHigh
        let error =
          zip(
            UnsafeBufferPointer(start: a.bitmapData!, count: count),
            UnsafeBufferPointer(start: b.bitmapData!, count: count)
          )
          .reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(count * 255)
        XCTAssertLessThan(error, 0.008)
      }
    }
  }
  func testAffineTextContainerClipsPointerHitTestingToPhysicalFrame() async throws {
    await MainActor.run {
      let canvas = NativeAffineView(frame: .init(x: 0, y: 0, width: 1000, height: 1000))
      let clip = NativeAffineView(frame: canvas.bounds)
      clip.configure(frame: .init(x: 100, y: 100, width: 200, height: 200), transform: .init())
      clip.clipsToBounds = true
      canvas.addSubview(clip)
      let host = NativeAffineView(frame: clip.bounds)
      host.configure(
        frame: clip.bounds, transform: .translation(-50, 30).followed(by: .rotation(15)))
      clip.addSubview(host)
      let text = NSView(frame: .init(x: 0, y: 0, width: 300, height: 100))
      host.addSubview(text)
      XCTAssertNil(clip.hitTest(.init(x: 80, y: 150)))
      let inside = host.convert(CGPoint(x: 100, y: 30), to: canvas)
      XCTAssertTrue(clip.hitTest(inside) === text)
    }
  }
  func testNativeAffineCoordinatesMatchArtworkIncludingReflectionAndShear() async throws {
    await MainActor.run {
      let parent = NativeAffineView(frame: .init(x: 0, y: 0, width: 1000, height: 1000))
      let child = NativeAffineView(frame: parent.bounds)
      parent.addSubview(child)
      var transforms: [Affine2] = [
        .init(), .rotation(31), .scale(-1, 1), .scale(1, -1), .scale(-2, -0.6),
        .init(a: 1.3, b: 0.2, c: 0.8, d: 0.7, tx: 300, ty: 250),
        .translation(300, 200).followed(by: .rotation(-60)).followed(by: .scale(2, -0.3)),
        .init(),
      ]
      for i in 0..<40 {
        transforms.append(
          .translation(Double(i) * 3, Double(i) * 2).followed(by: .rotation(Double(i) * 17))
            .followed(by: .scale(0.6 + Double(i % 5) * 0.17, i % 2 == 0 ? 0.8 : -1.3))
            .followed(by: .rotation(Double(i) * 7)))
      }
      for (i, transform) in transforms.enumerated() {
        let frame = CGRect(
          x: Double(i % 3) * 12, y: Double(i % 4) * 9, width: 1000 - Double(i),
          height: 1000 - Double(i))
        child.configure(frame: frame, transform: transform)
        for point in [Point2(), .init(12, 8), .init(-7, 20)] {
          var expected = transform.apply(point)
          expected.x += frame.origin.x
          expected.y += frame.origin.y
          let actual = child.convert(CGPoint(x: point.x, y: point.y), to: parent)
          XCTAssertEqual(actual.x, expected.x, accuracy: 1e-8)
          XCTAssertEqual(actual.y, expected.y, accuracy: 1e-8)
          let inverse = child.convert(actual, from: parent)
          XCTAssertEqual(inverse.x, point.x, accuracy: 1e-8)
          XCTAssertEqual(inverse.y, point.y, accuracy: 1e-8)
        }
      }
    }
  }
  func testInteractionCoalescesTextAndPreservesCancelledRedo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    engine.project = Project(name: "Original")
    try engine.edit("Rename") { $0.name = "Prior edit" }
    engine.undo()
    let before = engine.project!
    let redo = engine.redoStack
    engine.beginInteraction("text")
    try engine.edit("Typing", coalescing: "text") { $0.name = "New" }
    engine.beginInteraction("text")
    try engine.edit("Typing", coalescing: "text") { $0.name = "New text" }
    XCTAssertEqual(engine.undoStack.count, 1)
    // A native text undo can remove every character typed during this session.
    try engine.edit("Native undo", coalescing: "text") { $0.name = before.name }
    engine.endInteraction()
    XCTAssertEqual(engine.project, before)
    XCTAssertTrue(engine.undoStack.isEmpty)
    XCTAssertEqual(engine.redoStack, redo)
    engine.redo()
    XCTAssertEqual(engine.project?.name, "Prior edit")
  }
  func testCompletedInteractionIsOneUndoAndDifferentCommandsStaySeparate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    engine.project = Project(name: "Original")
    engine.beginInteraction("text")
    try engine.edit("Typing", coalescing: "text") { $0.name = "A" }
    try engine.edit("Typing", coalescing: "text") { $0.name = "A whole sentence" }
    try engine.edit("Other operation") { $0.subtitle = "Independent change" }
    XCTAssertEqual(engine.undoStack.count, 2)
    engine.undo()
    XCTAssertEqual(engine.project?.name, "A whole sentence")
    engine.undo()
    XCTAssertEqual(engine.project?.name, "Original")
    engine.redo()
    XCTAssertEqual(engine.project?.name, "A whole sentence")
  }
  func testProjectSwitchCommitsEditingBeforeSavingOldProject() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root: root)
    let engine = OperationEngine(repository: repository)
    let first = Project(name: "First")
    let second = Project(name: "Second")
    try repository.save(first)
    try repository.save(second)
    try engine.open(first.id)
    engine.onProjectWillChange = {
      try! engine.edit("Finish native draft") { $0.name = "Committed draft" }
    }
    try engine.open(second.id)
    XCTAssertEqual(try repository.load(first.id).name, "Committed draft")
    XCTAssertEqual(engine.project?.id, second.id)
    XCTAssertTrue(engine.undoStack.isEmpty)
  }
  func testOutlinedDecoratedTextMatchesNativeInk() async throws {
    try await MainActor.run {
      var e = ArtworkElement(
        kind: "text", x: 2, y: 2, width: 45, height: 20, text: "FORM", color: "#222222",
        fontSize: 36)
      var t = Typography()
      t.underline = true
      t.strikethrough = true
      e.typography = t
      let original = ArtworkRenderer.image(
        .init(background: "#FFFFFF", elements: [e]), width: 50, height: 25,
        assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 8)
      var elements: [ArtworkElement] = []
      for (path, color) in try TypographyEngine.outlineRuns(e) {
        var vector = try VectorGeometry.element(from: path, color: color)
        vector.affine = e.localTransform
        elements.append(vector)
      }
      let outlined = ArtworkRenderer.image(
        .init(background: "#FFFFFF", elements: elements), width: 50, height: 25,
        assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 8)
      let a = original.representations[0] as! NSBitmapImageRep
      let b = outlined.representations[0] as! NSBitmapImageRep
      let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
          ".local/validation")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try a.representation(using: .png, properties: [:])!.write(
        to: folder.appendingPathComponent("text-native.png"))
      try b.representation(using: .png, properties: [:])!.write(
        to: folder.appendingPathComponent("text-outlined.png"))
      let count = a.bytesPerRow * a.pixelsHigh
      let left = UnsafeBufferPointer(start: a.bitmapData!, count: count)
      let right = UnsafeBufferPointer(start: b.bitmapData!, count: count)
      let error =
        zip(left, right).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
        / Double(count * 255)
      XCTAssertLessThan(
        error, 0.008, "Outlined glyphs and decorations should preserve the visible native text.")
    }
  }
  func testSelectionExportRetainsAncestorOpacityAndClipping() throws {
    var group = ArtworkElement(kind: "group", x: 40, y: 30, width: 120, height: 100)
    group.contentSize = .init(120, 100)
    group.opacity = 0.4
    var mask = ArtworkElement(kind: "ellipse", x: 0, y: 0, width: 80, height: 80)
    mask.parentID = group.id
    var shape = ArtworkElement(kind: "rectangle", x: 0, y: 0, width: 100, height: 90)
    shape.parentID = group.id
    shape.clipID = mask.id
    var unrelated = ArtworkElement(kind: "rectangle", x: 10, y: 10)
    unrelated.parentID = group.id
    let art = Artwork(elements: [group, mask, shape, unrelated])
    let export = try art.exporting([shape.id])
    XCTAssertEqual(Set(export.artwork.elements.map(\.id)), [group.id, mask.id, shape.id])
    XCTAssertEqual(export.artwork.elements.first { $0.id == group.id }?.opacity, 0.4)
    XCTAssertEqual(
      export.artwork.bounds(of: export.artwork.elements.first { $0.id == shape.id }!).x, 0,
      accuracy: 1e-8)
    XCTAssertNoThrow(try validateArtwork(export.artwork))
  }
  func testExtendedArtworkPackagesAdvertiseTheirRequiredFormat() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root: root)
    var project = Project(name: "Format migration")
    var object = try project.makeObject(recipeID: "artboard")
    object.artwork = .init(background: "#FFFFFF")
    project.objects = [object]
    try repository.save(project)
    XCTAssertEqual(try repository.load(project.id).schemaVersion, 1)
    project.objects[0].artwork?.elements = [
      .init(kind: "text", x: 0, y: 0, text: "Keep my typography")
    ]
    project.objects[0].artwork?.elements[0].typography = .init()
    try repository.save(project)
    let reopened = try repository.load(project.id)
    XCTAssertEqual(reopened.schemaVersion, 2)
    XCTAssertNotNil(reopened.objects[0].artwork?.elements[0].typography)
  }
  func testCanvasMetadataDoesNotInvalidatePhysicalArtwork() throws {
    var art = Artwork(
      background: "#FFFFFF", elements: [.init(kind: "rectangle", x: 10, y: 10, color: "#D45A37")])
    let ink = art.renderDefinition
    art.unit = .inches
    art.gridSpacing = 5
    art.showGrid = true
    art.snapEnabled = false
    art.canvasPosition = .init(400, 120)
    art.guides = [.init(axis: "x", position: 40)]
    art.elements[0].name = "Renamed"
    art.elements[0].locked = true
    XCTAssertEqual(art.renderDefinition, ink)
    art.elements[0].color = "#224B9B"
    XCTAssertNotEqual(art.renderDefinition, ink)
  }
  func testLockedLayersRejectDestructiveArtworkCommands() throws {
    var e = ArtworkElement(kind: "ellipse", x: 0, y: 0)
    e.locked = true
    var art = Artwork(elements: [e])
    let before = art
    XCTAssertThrowsError(try ArtworkCommands.apply("delete", to: &art, ids: [e.id]))
    XCTAssertEqual(art, before)
    XCTAssertThrowsError(try ArtworkCommands.apply("align", to: &art, ids: [UUID()]))
    XCTAssertEqual(art, before)
  }
  func testTextLayoutCacheIgnoresPlacementAndInvalidatesTypography() async throws {
    await MainActor.run {
      var e = ArtworkElement(
        kind: "text", x: 0, y: 0, width: 80, height: 20, text: "A sharp canvas", color: "#222222",
        fontSize: 20)
      _ = TypographyEngine.measured(e)
      let first = TypographyEngine.diagnostics["layout_builds"] as! Int
      e.x = 100
      e.rotation = 30
      _ = TypographyEngine.measured(e)
      XCTAssertEqual(TypographyEngine.diagnostics["layout_builds"] as! Int, first)
      e.fontSize = 24
      _ = TypographyEngine.measured(e)
      XCTAssertEqual(TypographyEngine.diagnostics["layout_builds"] as! Int, first + 1)
    }
  }
  func testNativeRichTextRetainsMissingFontAndTypographicMetadata() async throws {
    await MainActor.run {
      var e = ArtworkElement(
        kind: "text", x: 0, y: 0, text: "Native input", color: "#222222", fontSize: 20)
      var t = Typography()
      t.fontName = "Uninstalled-FORM-Face"
      t.horizontalScale = 105
      t.wordSpacing = 2
      e.typography = t
      let runs = TypographyEngine.spans(
        from: TypographyEngine.attributed(e, millimeters: false), fallback: t)
      XCTAssertEqual(runs[0].typography.fontName, t.fontName)
      XCTAssertEqual(runs[0].typography.horizontalScale, 105)
      XCTAssertEqual(runs[0].typography.wordSpacing, 2)
    }
  }
  func testUnderlineAndStrikeProduceVisibleInk() async throws {
    await MainActor.run {
      var e = ArtworkElement(
        kind: "text", x: 2, y: 2, width: 45, height: 20, text: "FORM", color: "#222222",
        fontSize: 36)
      @MainActor func pixels(_ element: ArtworkElement) -> Data {
        let image = ArtworkRenderer.image(
          .init(background: "#FFFFFF", elements: [element]), width: 50, height: 25,
          assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 6)
        let rep = image.representations.first as! NSBitmapImageRep
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
      }
      let plain = pixels(e)
      var t = Typography()
      t.underline = true
      e.typography = t
      let underline = pixels(e)
      t.underline = false
      t.strikethrough = true
      e.typography = t
      let strike = pixels(e)
      XCTAssertNotEqual(plain, underline)
      XCTAssertNotEqual(plain, strike)
    }
  }
  func testPhysicalUnitsAndExplicitConversions() throws {
    XCTAssertEqual(try PhysicalUnit.mm.parse("8 in"), 203.2, accuracy: 0.000001)
    XCTAssertEqual(try PhysicalUnit.inches.parse("100mm"), 100, accuracy: 0.000001)
    XCTAssertEqual(try PhysicalUnit.cm.parse("72pt"), 25.4, accuracy: 0.000001)
    XCTAssertEqual(try PhysicalUnit.inches.parse("8.5"), 215.9, accuracy: 0.000001)
    XCTAssertThrowsError(try PhysicalUnit.mm.parse("nan"))
    XCTAssertThrowsError(try PhysicalUnit.mm.parse("2px"))
  }
  func testLegacyArtworkAndPartialTypographyDecode() throws {
    let json = """
      {"background":"#FFFFFF","bleed":3,"elements":[{"id":"7C4A77D4-55FC-41A0-87C6-24961F831225","kind":"text","x":10,"y":10,"width":80,"height":30,"text":"Hello","color":"#000000","fontSize":14}]}
      """
    let old = try JSONDecoder().decode(Artwork.self, from: Data(json.utf8))
    XCTAssertNil(old.unit)
    XCTAssertNil(old.elements[0].typography)
    XCTAssertNoThrow(try validateArtwork(old))
    let style = try JSONDecoder().decode(
      Typography.self, from: Data("{\"fontName\":\"Georgia\",\"tracking\":-0.3}".utf8))
    XCTAssertEqual(style.fontName, "Georgia")
    XCTAssertEqual(style.horizontalScale, 100)
    XCTAssertEqual(style.frameMode, "area")
  }
  func testGroupingAndTransformedUngroupKeepWorldGeometry() throws {
    var a = ArtworkElement(kind: "rectangle", x: 15, y: 20, width: 30, height: 20)
    a.rotation = 24
    let b = ArtworkElement(kind: "ellipse", x: 70, y: 30, width: 20, height: 40)
    var art = Artwork(background: "#FFFFFF", elements: [a, b])
    let before = art.worldTransform(a)
    let groupID = try XCTUnwrap(ArtworkCommands.apply("group", to: &art, ids: [a.id, b.id]).first)
    let grouped = art.worldTransform(art.elements.first { $0.id == a.id }!)
    XCTAssertEqual(grouped.a, before.a, accuracy: 1e-10)
    XCTAssertEqual(grouped.b, before.b, accuracy: 1e-10)
    XCTAssertEqual(grouped.tx, before.tx, accuracy: 1e-10)
    XCTAssertEqual(grouped.ty, before.ty, accuracy: 1e-10)
    let i = art.elements.firstIndex { $0.id == groupID }!
    art.elements[i].rotation = 31
    art.elements[i].width *= 1.7
    let rotated = art.worldTransform(art.elements.first { $0.id == a.id }!)
    try ArtworkCommands.apply("ungroup", to: &art, ids: [groupID])
    let ungrouped = art.elements.first { $0.id == a.id }!
    let p = rotated.apply(.init(15, 10))
    let q = art.worldTransform(ungrouped).apply(.init(15, 10))
    XCTAssertEqual(p.x, q.x, accuracy: 1e-9)
    XCTAssertEqual(p.y, q.y, accuracy: 1e-9)
    XCTAssertNil(ungrouped.parentID)
  }
  func testInvalidHierarchyAndEditRollback() throws {
    var e = ArtworkElement(kind: "rectangle", x: 0, y: 0)
    e.parentID = UUID()
    XCTAssertThrowsError(try validateArtwork(.init(elements: [e])))
    e.parentID = nil
    var art = Artwork(elements: [e])
    let before = art
    e.opacity = 2
    XCTAssertThrowsError(
      try ArtworkCommands.apply("replace", to: &art, arguments: ["elements": [try jsonObject(e)]]))
    XCTAssertEqual(art, before)
    var g = ArtworkElement(kind: "group", x: 0, y: 0)
    g.parentID = g.id
    XCTAssertThrowsError(try validateArtwork(.init(elements: [g])))
  }
  func testNestedDuplicateRemapsClipsAndParents() throws {
    let mask = ArtworkElement(kind: "ellipse", x: 0, y: 0)
    var content = ArtworkElement(kind: "rectangle", x: 0, y: 0)
    content.clipID = mask.id
    var art = Artwork(elements: [mask, content])
    let ids = try ArtworkCommands.apply("group", to: &art, ids: [mask.id, content.id])
    let duplicate = try ArtworkCommands.apply("duplicate", to: &art, ids: ids)
    let children = art.elements.filter { $0.parentID == duplicate.first }
    XCTAssertEqual(children.count, 2)
    XCTAssertTrue(children.contains { $0.clipID != nil && children.map(\.id).contains($0.clipID!) })
    XCTAssertNoThrow(try validateArtwork(art))
  }
  func testBezierConversionAndBooleanHoleGeometry() throws {
    let shape = CGPath(ellipseIn: .init(x: 12, y: 14, width: 80, height: 60), transform: nil)
    let e = try VectorGeometry.element(from: shape, color: "#222222")
    let copy = VectorGeometry.worldPath(e, in: .init(elements: [e]))
    XCTAssertEqual(copy.boundingBoxOfPath.minX, 12, accuracy: 1e-6)
    XCTAssertEqual(copy.boundingBoxOfPath.height, 60, accuracy: 1e-6)
    let hole = CGPath(ellipseIn: .init(x: 30, y: 25, width: 20, height: 20), transform: nil)
    let result = shape.subtracting(hole, using: .evenOdd)
    XCTAssertFalse(result.contains(.init(x: 40, y: 35), using: .evenOdd))
    XCTAssertTrue(result.contains(.init(x: 25, y: 35), using: .evenOdd))
    var converted = try VectorGeometry.element(from: result, color: "#222222")
    converted.path?.evenOdd = true
    XCTAssertFalse(
      VectorGeometry.worldPath(converted, in: .init(elements: [converted])).contains(
        .init(x: 40, y: 35), using: .evenOdd))
  }
  func testCoreTextOutlinesMatchVisibleGlyphBoundsAndRemainVector() async throws {
    try await MainActor.run {
      var e = ArtworkElement(
        kind: "text", x: 0, y: 0, width: 120, height: 30, text: "office ffi", color: "#224B9B",
        fontSize: 48)
      var t = Typography()
      t.fontName = "Georgia"
      t.tracking = -0.2
      e.typography = t
      let path = try TypographyEngine.outlines(e)
      XCTAssertFalse(path.isEmpty)
      XCTAssertGreaterThan(path.boundingBoxOfPath.width, 20)
      XCTAssertLessThan(path.boundingBoxOfPath.width, 120)
      let vector = try VectorGeometry.element(from: path, color: e.color)
      XCTAssertGreaterThan(vector.path!.contours.flatMap(\.nodes).count, 50)
      let art = Artwork(background: "#FFFFFF", elements: [e])
      let svg = try SVGRenderer.document(
        art, width: 120, height: 30, assets: URL(fileURLWithPath: "/tmp"))
      XCTAssertTrue(svg.contains("width=\"120.0mm\""))
      XCTAssertTrue(svg.contains("<path"))
      XCTAssertFalse(svg.contains("<text"))
      let pdfText = TypographyEngine.attributed(e)
      XCTAssertEqual(pdfText.string, "office ffi")
    }
  }
  func testRichTextUTF16AndMissingFontAssignmentSurviveRoundTrip() async throws {
    try await MainActor.run {
      var e = ArtworkElement(
        kind: "text", x: 10, y: 10, width: 100, height: 30, text: "A😀Z", color: "#222222",
        fontSize: 14)
      var style = Typography()
      style.fontName = "MissingFace-FORM-Validation"
      e.typography = style
      e.textRuns = [
        .init(location: 1, length: 2, typography: .init(), fontSize: 20, color: "#D45A37")
      ]
      let art = Artwork(background: "#FFFFFF", elements: [e])
      try validateArtwork(art)
      XCTAssertEqual(FontCatalog.missing(in: art), [style.fontName])
      let reopened = try JSONDecoder.form.decode(Artwork.self, from: JSONEncoder.form.encode(art))
      XCTAssertEqual(reopened, art)
      XCTAssertEqual(reopened.elements[0].typography?.fontName, style.fontName)
      let text = TypographyEngine.attributed(e, millimeters: false)
      XCTAssertEqual((text.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.pointSize, 20)
      XCTAssertEqual(
        FormColor.hex(text.attribute(.foregroundColor, at: 1, effectiveRange: nil) as! NSColor),
        "#D45A37")
    }
  }
  func testMCPArtworkCommandsShareUndoAndPersistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    _ = try engine.call("form_create_project", arguments: ["name": "Artwork test"])
    let object = try engine.project!.makeObject(recipeID: "artboard")
    try engine.edit("Add frame") { $0.objects.append(object) }
    let element = ArtworkElement(
      kind: "ellipse", x: 20, y: 20, width: 100, height: 100, color: "#D45A37")
    _ = try engine.call(
      "form_edit_artwork",
      arguments: [
        "object_id": object.id.uuidString, "command": "add", "elements": [try jsonObject(element)],
      ])
    XCTAssertEqual(engine.project!.objects[0].artwork?.elements.count, 1)
    engine.undo()
    XCTAssertNil(engine.project!.objects[0].artwork)
    engine.redo()
    try engine.flush()
    XCTAssertEqual(
      try engine.repository.load(engine.project!.id).objects[0].artwork?.elements.first?.id,
      element.id)
  }
  func testDiscreteNativeArtworkCommandsHaveSeparateUndoSteps() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    var project = Project(name: "Native commands")
    let object = try project.makeObject(recipeID: "artboard")
    project.objects = [object]
    engine.project = project
    for kind in ["ellipse", "rectangle"] {
      let element = ArtworkElement(kind: kind, x: 10, y: 10)
      _ = try engine.call(
        "form_edit_artwork",
        arguments: [
          "object_id": object.id.uuidString, "command": "add",
          "elements": [try jsonObject(element)],
        ], source: "Studio")
    }
    engine.undo()
    XCTAssertEqual(engine.project?.objects[0].artwork?.elements.map(\.kind), ["ellipse"])
    engine.undo()
    XCTAssertNil(engine.project?.objects[0].artwork)
  }
}

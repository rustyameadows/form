import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

final class SwatchTests: XCTestCase {
  private func fixture() throws -> (Project, UUID, UUID, UUID, UUID) {
    var p = Project(name: "Shared palette")
    var sheet = try p.makeObject(recipeID: "artboard")
    let mark = ArtworkElement(kind: "ellipse", x: 20, y: 20, width: 45, height: 45, color: "#000000")
    sheet.artwork = .init(background: "#FFFFFF", elements: [mark], bleed: 0)
    p.objects = [sheet]
    let red = try SwatchCommands.save(in: &p, name: "Accent", color: "#D45A37")
    let blue = try SwatchCommands.save(in: &p, name: "Ink", color: "#263C64")
    return (p, sheet.id, mark.id, red, blue)
  }
  private func art(_ p: Project, _ id: UUID) -> Artwork {
    p.objects.first { $0.id == id }!.artwork!
  }
  @MainActor private func png(_ p: Project, _ id: UUID) -> Data {
    let object = p.objects.first { $0.id == id }!
    let image = ArtworkRenderer.image(p.surfaceArtwork(object)!, width: 120, height: 100,
      assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 2)
    return (image.representations[0] as! NSBitmapImageRep).representation(using: .png, properties: [:])!
  }

  func testPaletteNamesColorSpaceAndInvalidEditsAreAtomic() throws {
    var (p, _, _, red, _) = try fixture()
    let before = p
    XCTAssertThrowsError(try SwatchCommands.save(in: &p, name: " accent ", color: "#FFFFFF"))
    XCTAssertEqual(p, before)
    XCTAssertThrowsError(try SwatchCommands.save(in: &p, id: red, name: "Accent", color: "invalid"))
    XCTAssertEqual(p, before)
    XCTAssertEqual(p.swatches!.first!.colorSpace, "sRGB")
    p.swatches![0].colorSpace = "CMYK"
    XCTAssertThrowsError(try p.validateArtworkLinks())
  }

  func testAllPaintLocationsResolveWithoutRewritingStoredArtwork() throws {
    var (p, sheet, _, red, blue) = try fixture()
    var a = art(p, sheet)
    a.backgroundSwatchID = blue
    a.elements[0].fillSwatchID = red
    a.elements[0].stroke = .init(color: "#000000")
    a.elements[0].stroke?.swatchID = blue
    a.elements[0].gradient = .init()
    a.elements[0].gradient?.stops[0].swatchID = red
    a.elements[0].gradient?.stops[1].swatchID = blue
    try p.setArtwork(a, for: sheet)
    let before = p.objects
    let resolved = p.resolvingSwatches(in: a)
    XCTAssertEqual(resolved.background, "#263C64")
    XCTAssertEqual(resolved.elements[0].color, "#D45A37")
    XCTAssertEqual(resolved.elements[0].stroke?.color, "#263C64")
    XCTAssertEqual(resolved.elements[0].gradient?.stops.map(\.color), ["#D45A37", "#263C64"])
    XCTAssertTrue(resolved.referencedSwatches.isEmpty)
    XCTAssertEqual(p.objects, before)
    XCTAssertEqual(p.resolvingSwatches(in: a, keepingReferences: true).referencedSwatches, [red, blue])
  }

  func testFillStrokeGradientAndBackgroundAssignmentsShareOneModel() throws {
    var (p, sheet, mark, red, blue) = try fixture()
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [mark], swatchID: red)
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [mark], target: "stroke", swatchID: blue)
    var a = art(p, sheet)
    a.elements[0].gradient = .init()
    let stop = a.elements[0].gradient!.stops[1].id
    try p.setArtwork(a, for: sheet)
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [mark], target: "gradient_stop", swatchID: blue, stopID: stop)
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [], target: "background", swatchID: red)
    XCTAssertEqual(art(p, sheet).referencedSwatches, [red, blue])
    try SwatchCommands.save(in: &p, id: blue, name: "Ink", color: "#849381")
    let rendered = p.surfaceArtwork(p.objects[0])!
    XCTAssertEqual(rendered.elements[0].stroke?.color, "#849381")
    XCTAssertEqual(rendered.elements[0].gradient?.stops[1].color, "#849381")
  }

  func testBackgroundBindingCanInitializeAnEmptyPhysicalFrame() throws {
    var (p, _, _, red, _) = try fixture()
    let blank = try p.makeObject(recipeID: "artboard")
    p.objects.append(blank)
    try SwatchCommands.assign(in: &p, objectID: blank.id, ids: [], target: "background", swatchID: red)
    XCTAssertEqual(art(p, blank.id).backgroundSwatchID, red)
    XCTAssertEqual(p.surfaceArtwork(p.objects.last!)?.background, "#D45A37")
  }

  func testGroupColorInspectionAndDetachmentReachTheSameVisiblePaints() throws {
    var (p, sheet, mark, red, blue) = try fixture()
    var a = art(p, sheet)
    let group = ArtworkElement(kind: "group", x: 0, y: 0)
    a.elements[0].parentID = group.id
    a.elements[0].fillSwatchID = red
    var line = ArtworkElement(kind: "line", x: 10, y: 10)
    line.parentID = group.id
    line.stroke = .init(color: "#000000")
    line.stroke?.swatchID = blue
    var hidden = ArtworkElement(kind: "ellipse", x: 0, y: 0)
    hidden.parentID = group.id
    hidden.hidden = true
    hidden.fillSwatchID = blue
    var mask = ArtworkElement(kind: "rectangle", x: 0, y: 0)
    mask.parentID = group.id
    mask.fillSwatchID = blue
    a.elements[0].clipID = mask.id
    a.elements += [group, line, hidden, mask]
    try p.setArtwork(a, for: sheet)
    XCTAssertEqual(a.swatchPaintTargets(for: [group.id]), [mark, line.id])
    XCTAssertEqual(a.fillSwatchReferences(for: [group.id]), [red, blue])
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [group.id], swatchID: nil)
    let detached = art(p, sheet)
    XCTAssertEqual(detached.fillSwatchReferences(for: [group.id]), [nil])
    XCTAssertEqual(detached.elements.first { $0.id == mark }?.color, "#D45A37")
    XCTAssertEqual(detached.elements.first { $0.id == line.id }?.stroke?.color, "#263C64")
    XCTAssertEqual(detached.elements.first { $0.id == hidden.id }?.fillSwatchID, blue)
    XCTAssertEqual(detached.elements.first { $0.id == mask.id }?.fillSwatchID, blue)
  }

  func testUTF16RangeBindingAndDetachmentPreserveMixedTypographyAndColors() throws {
    var (p, sheet, _, red, blue) = try fixture()
    var text = ArtworkElement(kind: "text", x: 0, y: 0, text: "AB🪐CD", color: "#000000", fontSize: 14)
    text.fillSwatchID = red
    var style = Typography()
    style.tracking = 2
    var first = TextSpan(location: 0, length: 2, typography: style, fontSize: 28, color: "#000000")
    first.swatchID = red
    text.textRuns = [first]
    try p.setArtwork(.init(background: "#FFFFFF", elements: [text]), for: sheet)
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [text.id], target: "text_range",
      swatchID: blue, location: 2, length: 2)
    let bound = art(p, sheet).elements[0]
    XCTAssertEqual(bound.textRuns?.map(\.swatchID), [red, blue, red])
    XCTAssertEqual(bound.textRuns?[0].fontSize, 28)
    XCTAssertEqual(bound.textRuns?[0].typography.tracking, 2)
    try SwatchCommands.save(in: &p, id: blue, name: "Ink", color: "#849381")
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [text.id], target: "text_range",
      swatchID: nil, location: 0, length: 6)
    XCTAssertEqual(art(p, sheet).elements[0].textRuns?.map(\.color), ["#D45A37", "#849381", "#D45A37"])
    XCTAssertTrue(art(p, sheet).elements[0].textRuns!.allSatisfy { $0.swatchID == nil })
    let before = p
    XCTAssertThrowsError(try SwatchCommands.assign(in: &p, objectID: sheet, ids: [text.id], target: "text_range",
      swatchID: blue, location: 3, length: 1))
    XCTAssertEqual(p, before)
  }

  @MainActor func testNativeAttributedTextAndGlyphOutlinesRetainColorReferences() throws {
    var (p, sheet, _, red, blue) = try fixture()
    var text = ArtworkElement(kind: "text", x: 0, y: 0, width: 100, height: 30, text: "FORM", color: "#000000", fontSize: 32)
    text.fillSwatchID = red
    var span = TextSpan(location: 0, length: 2, typography: .init(), fontSize: 32, color: "#000000")
    span.swatchID = blue
    text.textRuns = [span]
    try p.setArtwork(.init(elements: [text]), for: sheet)
    let colored = p.resolvingSwatches(in: art(p, sheet), keepingReferences: true).elements[0]
    let attributed = TypographyEngine.attributed(colored)
    let runs = TypographyEngine.spans(from: attributed, fallback: .init())
    XCTAssertEqual(Set(runs.compactMap(\.swatchID)), [red, blue])
    XCTAssertEqual(Set(try TypographyEngine.outlinePaintRuns(colored).compactMap(\.swatchID)), [red, blue])
  }

  func testComponentOverridesAndDetachKeepSharedSwatches() throws {
    var (p, sheet, mark, red, blue) = try fixture()
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [mark], swatchID: red)
    let made = try ComponentCommands.create(in: &p, objectID: sheet, elements: [mark], name: "Mark")
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [made.instance], swatchID: blue)
    XCTAssertEqual(art(p, sheet).elements[0].component?.colorSwatchID, blue)
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [made.instance], target: "component_part", swatchID: red, partID: mark)
    let rendered = p.surfaceArtwork(p.objects[0])!
    XCTAssertEqual(rendered.elements.first { $0.id == ComponentCommands.derivedID(made.instance, mark) }!.color, "#D45A37")
    try ComponentCommands.detach(in: &p, objectID: sheet, ids: [made.instance])
    XCTAssertTrue(art(p, sheet).referencedSwatches.contains(red))
    try SwatchCommands.save(in: &p, id: red, name: "Accent", color: "#849381")
    XCTAssertEqual(p.surfaceArtwork(p.objects[0])!.elements.first { $0.kind == "ellipse" }!.color, "#849381")
  }

  func testPhysicalArtworkDetachmentRetainsPaletteLinks() throws {
    var (p, sheet, mark, red, _) = try fixture()
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [mark], swatchID: red)
    let box = try p.makeObject(recipeID: "box")
    p.objects.append(box)
    try p.linkArtwork(box.id, sourceID: sheet)
    try p.linkArtwork(box.id, sourceID: nil)
    XCTAssertTrue(art(p, box.id).referencedSwatches.contains(red))
    try SwatchCommands.save(in: &p, id: red, name: "Accent", color: "#849381")
    XCTAssertEqual(p.surfaceArtwork(p.objects.last!)!.elements[0].color, "#849381")
  }

  @MainActor func testDeletingAUsedSwatchFreezesPixelsIncludingLockedLayersAndUndo() throws {
    var (p, sheet, mark, red, _) = try fixture()
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [mark], swatchID: red)
    p.objects[0].artwork!.elements[0].locked = true
    let before = png(p, sheet)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = OperationEngine(repository: try .init(root: folder))
    engine.project = p
    try engine.call("form_swatch", arguments: ["command": "delete", "swatch_id": red.uuidString])
    XCTAssertEqual(png(engine.project!, sheet), before)
    XCTAssertFalse(art(engine.project!, sheet).referencedSwatches.contains(red))
    XCTAssertEqual(art(engine.project!, sheet).elements[0].locked, true)
    engine.undo()
    XCTAssertEqual(engine.project, p)
  }

  func testPaletteUpdatesOnlyChangeManifestAndRoundTripSchemaSeven() throws {
    var (p, sheet, mark, red, _) = try fixture()
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [mark], swatchID: red)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try ProjectRepository(root: folder)
    try repo.save(p)
    let package = repo.url(for: p.id)
    func resources() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("Objects").path).sorted()
    }
    let files = try resources()
    let objects = p.objects
    try SwatchCommands.save(in: &p, id: red, name: "Warm accent", color: "#B57860")
    try repo.save(p)
    XCTAssertEqual(try resources(), files)
    XCTAssertEqual(p.objects, objects)
    let loaded = try repo.load(p.id)
    XCTAssertEqual(loaded.schemaVersion, 7)
    XCTAssertEqual(loaded.objects, p.objects)
    XCTAssertEqual(loaded.swatches, p.swatches)
    XCTAssertEqual(loaded.surfaceArtwork(loaded.objects[0])!.elements[0].color, "#B57860")
  }

  func testLockedOrInvalidAssignmentsAndFailedBatchesRejectAtomically() throws {
    var (p, sheet, mark, red, _) = try fixture()
    p.objects[0].artwork!.elements[0].locked = true
    let before = p
    XCTAssertThrowsError(try SwatchCommands.assign(in: &p, objectID: sheet, ids: [mark], swatchID: red))
    XCTAssertEqual(p, before)
    p.objects[0].artwork!.elements[0].locked = nil
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = OperationEngine(repository: try .init(root: folder))
    engine.project = p
    XCTAssertThrowsError(try engine.call("form_batch", arguments: ["operations": [
      ["name": "form_swatch", "arguments": ["command": "assign", "object_id": sheet.uuidString,
        "element_ids": [mark.uuidString], "swatch_id": red.uuidString]],
      ["name": "form_swatch", "arguments": ["command": "update", "swatch_id": red.uuidString, "color": "bad"]],
    ]]))
    XCTAssertEqual(engine.project, p)
    XCTAssertTrue(engine.undoStack.isEmpty)
  }

  func testComponentCacheOnlyDependsOnReferencedPaletteValues() throws {
    var (p, sheet, mark, red, blue) = try fixture()
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [mark], swatchID: red)
    let made = try ComponentCommands.create(in: &p, objectID: sheet, elements: [mark], name: "Cached")
    let raw = art(p, sheet)
    let first = try p.resolvingComponents(in: raw)
    let count = ComponentCommands.resolutionDiagnostics["builds"] as! Int
    try SwatchCommands.save(in: &p, id: blue, name: "Ink", color: "#000000")
    XCTAssertEqual(try p.resolvingComponents(in: raw), first)
    XCTAssertEqual(ComponentCommands.resolutionDiagnostics["builds"] as! Int, count)
    try SwatchCommands.save(in: &p, id: red, name: "Accent", color: "#849381")
    XCTAssertNotEqual(try p.resolvingComponents(in: raw), first)
    XCTAssertEqual(ComponentCommands.resolutionDiagnostics["builds"] as! Int, count + 1)
    XCTAssertEqual(art(p, sheet).elements[0].component?.sourceObjectID, made.source)
  }

  @MainActor func testBooleanCreationAndFlatteningPreservePaintReferences() throws {
    var (p, sheet, mark, _, blue) = try fixture()
    var a = art(p, sheet)
    var second = ArtworkElement(kind: "ellipse", x: 40, y: 20, width: 45, height: 45)
    second.fillSwatchID = blue
    a.elements.append(second)
    try p.setArtwork(a, for: sheet)
    let id = try BooleanCommands.create("union", artwork: &a, elements: [mark, second.id])
    XCTAssertEqual(a.elements.first { $0.id == id }?.fillSwatchID, blue)
    try p.setArtwork(a, for: sheet)
    XCTAssertEqual(p.surfaceArtwork(p.objects[0])!.elements.first { $0.id == id }?.color, "#263C64")
    let before = png(p, sheet)
    let proxy = try BooleanGeometry.proxy(a.elements.first { $0.id == id }!, in: a, normalize: true)
    let all = a.descendants(of: [id])
    a.elements.removeAll { all.contains($0.id) }
    a.elements.append(proxy)
    try p.setArtwork(a, for: sheet)
    XCTAssertEqual(proxy.fillSwatchID, blue)
    XCTAssertEqual(png(p, sheet), before)
    try SwatchCommands.save(in: &p, id: blue, name: "Ink", color: "#849381")
    XCTAssertEqual(p.surfaceArtwork(p.objects[0])!.elements[0].color, "#849381")
  }
}

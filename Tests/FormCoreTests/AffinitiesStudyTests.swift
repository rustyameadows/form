import XCTest

@testable import FormCore

final class AffinitiesStudyTests: XCTestCase {
  private func source(_ p: Project) throws -> ProductObject {
    try XCTUnwrap(p.objects.first { $0.name == AffinitiesStudy.sourceName })
  }
  private func alternate(_ p: Project) throws -> ProductObject {
    try XCTUnwrap(p.objects.first { $0.name == AffinitiesStudy.alternateName })
  }
  private func uuids(_ value: Any) -> Set<UUID> {
    if let raw = value as? String, let id = UUID(uuidString: raw) { return [id] }
    if let values = value as? [Any] { return values.reduce(into: []) { $0.formUnion(uuids($1)) } }
    if let values = value as? [String: Any] {
      return values.reduce(into: []) {
        $0.formUnion(uuids($1.key))
        $0.formUnion(uuids($1.value))
      }
    }
    return []
  }
  private func engine(_ p: Project) throws -> OperationEngine {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    engine.project = p
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return engine
  }
  func testDiscoverableStudyRetainsExactPhysicalFrameAndRichOriginalTypography() throws {
    XCTAssertTrue(Samples.templates.prefix(3).contains { $0.id == "affinities" })
    let tool = MCP.tools.first { $0["name"] as? String == "form_create_project" }!
    let schema = tool["inputSchema"] as! [String: Any]
    let properties = schema["properties"] as! [String: Any]
    XCTAssertTrue(
      ((properties["template"] as! [String: Any])["enum"] as! [String]).contains("affinities"))
    let p = try Samples.make("affinities")
    let original = try source(p)
    XCTAssertEqual(original["width"], 203.2)
    XCTAssertEqual(original["depth"], 254)
    XCTAssertEqual(original.artwork!.unit, .inches)
    let title = try XCTUnwrap(
      original.artwork!.elements.first { $0.name == "Editable display wordmark" })
    XCTAssertEqual(title.kind, "text")
    XCTAssertEqual(title.text, "Affinities.")
    XCTAssertEqual(title.fontSize, 67)
    XCTAssertEqual(title.typography!.fontName, "Baskerville")
    XCTAssertEqual(title.typography!.featureSelections?[1], [2, 4, 20])
    XCTAssertEqual(title.typography!.tracking, -0.3)
    XCTAssertEqual(title.typography!.leading, 70)
    XCTAssertEqual(title.typography!.pairKerning[0], -0.8)
    let variable = try XCTUnwrap(
      original.artwork!.elements.first { $0.typography?.fontName == "Skia" })
    XCTAssertEqual(variable.typography!.variations[2_003_265_652], 1.8)
    XCTAssertEqual(variable.typography!.variations[2_003_072_104], 1.12)
    XCTAssertTrue(
      original.artwork!.guides?.contains { $0.axis == "x" && $0.position == 18 } == true)
    XCTAssertEqual(p.history.count, 1)
    XCTAssertNotNil(p.canvasWorkspace)
    XCTAssertNoThrow(try p.validateArtworkLinks())
  }
  func testEveryNewStudyReidentifiesAllUUIDsWhileRetainingScopedMasksAndSharedEditions() throws {
    let a = try Samples.affinities()
    let b = try Samples.affinities()
    let idsA = uuids(try jsonObject(a))
    let idsB = uuids(try jsonObject(b))
    XCTAssertGreaterThan(idsA.count, 100)
    XCTAssertTrue(idsA.isDisjoint(with: idsB))
    let original = try source(a)
    let art = original.artwork!
    let other = try alternate(a)
    let mask = try XCTUnwrap(art.elements.first { $0.name == "Circular geometric mask" })
    let wave = try XCTUnwrap(art.elements.first { $0.name == "Editable curved landscape" })
    XCTAssertEqual(wave.clipID, mask.id)
    XCTAssertEqual(wave.parentID, mask.parentID)
    let group = try XCTUnwrap(art.elements.first { $0.id == mask.parentID })
    XCTAssertEqual(
      atan2(group.localTransform.b, group.localTransform.a) * 180 / Double.pi, -6, accuracy: 1e-8)
    XCTAssertTrue(
      wave.path!.contours[0].nodes.contains { $0.outgoing != nil && $0.incoming != nil })
    let editions = a.objects.filter { $0.recipeID == "box" }
    XCTAssertEqual(editions.count, 2)
    XCTAssertEqual(Set(editions.map(\.designID)).count, 1)
    XCTAssertTrue(
      editions.allSatisfy { $0.artworkSourceID == original.id && $0.artworkFit == "actual" })
    XCTAssertNil(other.artworkSourceID)
    XCTAssertNotEqual(original.designID, other.designID)
    for pair in zip(a.objects.prefix(3), a.objects.dropFirst().prefix(3)) {
      XCTAssertGreaterThan(pair.1.position.x - pair.0.position.x, 203.2)
    }
  }
  func testAlternateHasActualComplexOutlineGeometryAndRetainsHiddenEditableSource() throws {
    let p = try Samples.affinities()
    let art = try alternate(p).artwork!
    let hidden = try XCTUnwrap(
      art.elements.first { $0.name == "Editable display wordmark · editable source" })
    XCTAssertEqual(hidden.kind, "text")
    XCTAssertEqual(hidden.hidden, true)
    XCTAssertEqual(hidden.typography?.fontName, "Baskerville")
    let paths = art.elements.filter {
      $0.name == "Editable display wordmark · outlines" && $0.kind == "path"
    }
    XCTAssertFalse(paths.isEmpty)
    let contours = paths.flatMap { $0.path?.contours ?? [] }
    XCTAssertGreaterThan(contours.count, 10)
    XCTAssertGreaterThan(contours.flatMap(\.nodes).count, 150)
    XCTAssertTrue(contours.flatMap(\.nodes).contains { $0.incoming != nil || $0.outgoing != nil })
    XCTAssertTrue(p.notes.contains { $0.text.contains("No fonts are bundled") })
  }
  func testEditingSourceNodesUpdatesBothLinkedFacesButLeavesAlternateAndRestoresWithUndo() throws {
    let p = try Samples.affinities()
    let original = try source(p)
    let beforeAlternate = try alternate(p)
    let wave = original.artwork!.elements.first { $0.name == "Editable curved landscape" }!
    let node = wave.path!.contours[0].nodes[1]
    let e = try engine(p)
    _ = try e.call(
      "form_edit_path",
      arguments: [
        "object_id": original.id.uuidString, "element_id": wave.id.uuidString,
        "operation": "transform", "node_ids": [node.id.uuidString],
        "matrix": ["a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": -0.8],
      ])
    XCTAssertEqual(e.undoStack.count, 1)
    let changed = e.project!
    XCTAssertNotEqual(try source(changed).artwork, original.artwork)
    XCTAssertEqual(try alternate(changed), beforeAlternate)
    for object in p.objects where object.recipeID == "box" {
      XCTAssertEqual(changed.editableArtwork(object), try source(changed).artwork)
      XCTAssertNotEqual(changed.surfaceArtwork(object), p.surfaceArtwork(object))
    }
    e.undo()
    XCTAssertEqual(e.project, p)
    e.redo()
    XCTAssertEqual(e.project, changed)
  }
  func testProjectCreationAndDiskReopenKeepRealGeometryTypographyAndLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root: root)
    let e = OperationEngine(repository: repository)
    _ = try e.call(
      "form_create_project", arguments: ["name": "Affinity test", "template": "affinities"])
    let p = e.project!
    let reopened = try repository.load(p.id)
    XCTAssertEqual(reopened.objects, p.objects)
    XCTAssertEqual(reopened.notes.map(\.text), p.notes.map(\.text))
    XCTAssertTrue(e.undoStack.isEmpty)
    XCTAssertEqual(reopened.camera, p.camera)
    XCTAssertEqual(try source(reopened).artwork, try source(p).artwork)
    XCTAssertNoThrow(try reopened.validateArtworkLinks())
  }
}

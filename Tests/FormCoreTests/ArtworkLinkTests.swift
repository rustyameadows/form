import AppKit
import XCTest

@testable import FormCore
@testable import FormGraphics

final class ArtworkLinkTests: XCTestCase {
  func testClockStudyUsesOneIndependentSourceForTwoPhysicalVariants() throws {
    let p = Samples.clock()
    let clocks = p.objects.filter { $0.recipeID == "clock" }
    XCTAssertEqual(clocks.count, 2)
    XCTAssertEqual(clocks[0].designID, clocks[1].designID)
    XCTAssertEqual(clocks[0].artworkSourceID, clocks[1].artworkSourceID)
    XCTAssertNil(clocks[0].artwork)
    XCTAssertEqual(p.artworkOwner(clocks[0]).recipeID, "artboard")
    XCTAssertEqual(
      p.editableArtwork(clocks[0])?.elements.filter { $0.name?.hasPrefix("Hour ") == true }.count,
      13)
    XCTAssertEqual(p.minimumSchemaVersion, 3)
    XCTAssertNoThrow(try p.validateArtworkLinks())
    XCTAssertEqual(
      p.surfaceArtwork(clocks[0]), p.surfaceArtwork(clocks[0]),
      "Boundary node IDs must be stable for caching.")
  }
  func testSourceEditsPropagateWithoutChangingConsumerObjectsOrParameters() throws {
    var p = Samples.clock()
    let clock = p.objects[0]
    let source = p.artworkOwner(clock)
    var art = try XCTUnwrap(source.artwork)
    let before = p.objects.filter { $0.recipeID == "clock" }
    art.background = "#EBE2CE"
    try p.setArtwork(art, for: clock.id)
    XCTAssertEqual(p.objects.filter { $0.recipeID == "clock" }, before)
    XCTAssertEqual(p.editableArtwork(p.objects[1])?.background, "#EBE2CE")
    XCTAssertEqual(p.objects.first { $0.id == source.id }?.artwork, art)
  }
  func testActualSizeCentersArtworkAndFitPreservesAspectAndSourceData() throws {
    var p = Project(name: "Placement")
    var source = try p.makeObject(recipeID: "artboard", parameters: ["width": 100, "depth": 80])
    var mark = ArtworkElement(
      kind: "text", x: 10, y: 20, width: 30, height: 10, text: "Type", fontSize: 18)
    mark.typography = Typography()
    source.artwork = .init(elements: [mark])
    let target = try p.makeObject(recipeID: "box", parameters: ["width": 200, "depth": 240])
    p.objects = [target, source]
    try p.linkArtwork(target.id, sourceID: source.id)
    let actual = try XCTUnwrap(p.surfaceArtwork(p.objects[0])?.elements[0])
    let a = actual.localTransform.apply(.init())
    XCTAssertEqual(a.x, 60, accuracy: 1e-8)
    XCTAssertEqual(a.y, 100, accuracy: 1e-8)
    try p.linkArtwork(target.id, sourceID: source.id, fit: "fit")
    let fit = try XCTUnwrap(p.surfaceArtwork(p.objects[0])?.elements[0])
    let b = fit.localTransform.apply(.init())
    XCTAssertEqual(b.x, 20, accuracy: 1e-8)
    XCTAssertEqual(b.y, 80, accuracy: 1e-8)
    XCTAssertEqual(fit.localTransform.a, 2, accuracy: 1e-8)
    XCTAssertEqual(fit.localTransform.d, 2, accuracy: 1e-8)
    XCTAssertEqual(p.editableArtwork(p.objects[0])?.elements[0], mark)
  }
  func testInvalidLinksAreAtomicAndUnsupportedSurfacesRejectThem() throws {
    var p = Samples.clock()
    let before = p
    XCTAssertThrowsError(try p.linkArtwork(p.objects[0].id, sourceID: UUID()))
    XCTAssertEqual(p, before)
    XCTAssertThrowsError(try p.linkArtwork(p.objects[2].id, sourceID: p.objects[2].id))
    XCTAssertEqual(p, before)
    let lamp = try p.makeObject(recipeID: "lamp")
    p.objects.append(lamp)
    XCTAssertThrowsError(try p.linkArtwork(lamp.id, sourceID: p.objects[2].id))
    p.objects[0].artworkSourceID = UUID()
    XCTAssertThrowsError(try p.validateArtworkLinks())
  }
  func testDeletingSourceDetachesConsumersAtSamePhysicalAppearanceAndUndoRestoresLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let e = OperationEngine(repository: try ProjectRepository(root: root))
    var p = Samples.clock()
    p.objects[0].parameters["diameter"] = 280
    p.objects[1].parameters["diameter"] = 280
    let original = p.surfaceArtwork(p.objects[0])
    e.project = p
    _ = try e.call("form_delete_objects", arguments: ["object_ids": [p.objects[2].id.uuidString]])
    XCTAssertNil(e.project!.objects[0].artworkSourceID)
    XCTAssertEqual(e.project!.surfaceArtwork(e.project!.objects[0]), original)
    e.undo()
    XCTAssertEqual(e.project, p)
  }
  func testClockCreationIndependentIterationAndSchemaThreeRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root: root)
    let e = OperationEngine(repository: repository)
    _ = try e.call("form_create_project", arguments: ["name": "Clock test"])
    _ = try e.call("form_add_object", arguments: ["recipe_id": "clock"])
    let clock = try XCTUnwrap(e.project?.objects.first { $0.recipeID == "clock" })
    XCTAssertNotNil(clock.artworkSourceID)
    XCTAssertEqual(e.project!.objects.count, 2)
    _ = try e.call(
      "form_duplicate_object", arguments: ["object_id": clock.id.uuidString, "mode": "iteration"])
    let iteration = e.project!.objects.last!
    XCTAssertNil(iteration.artworkSourceID)
    XCTAssertEqual(e.project!.surfaceArtwork(iteration), e.project!.surfaceArtwork(clock))
    try e.flush()
    let loaded = try repository.load(e.project!.id)
    XCTAssertEqual(loaded.schemaVersion, 3)
    XCTAssertEqual(loaded.objects, e.project!.objects)
    let before = e.project!.objects[0]
    _ = try e.call(
      "form_update_object",
      arguments: ["object_id": clock.id.uuidString, "parameters": ["hour": 3, "minute": 30]])
    XCTAssertEqual(
      e.project!.objects[1], loaded.objects[1], "Clock time must not change the source document.")
    XCTAssertEqual(e.project!.objects[0].artworkSourceID, before.artworkSourceID)
  }
  func testAllStudyTemplatesAndClockTimeValidation() throws {
    for template in Samples.templates {
      let project = try Samples.make(template.id)
      try project.validateArtworkLinks()
      for object in project.objects {
        try project.recipe(object.recipeID)!.validate(object.parameters)
        if let art = object.artwork { try validateArtwork(art) }
      }
    }
    XCTAssertThrowsError(try Samples.make("missing"))
    XCTAssertThrowsError(try Recipe.builtins.first { $0.id == "clock" }!.validate(["hour": 3.5]))
    XCTAssertThrowsError(try Recipe.builtins.first { $0.id == "clock" }!.validate(["hands": 0.5]))
    XCTAssertThrowsError(try Recipe("clock", "Malformed clock", "clock", "", []).validate([:]))
  }
  func testSavingSourceEditWritesOnlyItsOwnImmutableObjectRevision() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root: root)
    var project = Samples.clock()
    try repository.save(project)
    let package = repository.url(for: project.id)
    func references() throws -> [String: String] {
      let manifest =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: package.appendingPathComponent("Manifest.json"))) as! [String: Any]
      return Dictionary(
        uniqueKeysWithValues: (manifest["objects"] as! [[String: Any]]).map {
          ($0["id"] as! String, $0["file"] as! String)
        })
    }
    let before = try references()
    let files = try FileManager.default.contentsOfDirectory(
      atPath: package.appendingPathComponent("Objects").path)
    var artwork = try XCTUnwrap(project.editableArtwork(project.objects[0]))
    artwork.elements[0].name = "Revised source"
    try project.setArtwork(artwork, for: project.objects[0].id)
    try repository.save(project)
    let after = try references()
    for clock in project.objects.filter({ $0.recipeID == "clock" }) {
      XCTAssertEqual(before[clock.id.uuidString], after[clock.id.uuidString])
    }
    let source = project.artworkOwner(project.objects[0])
    XCTAssertNotEqual(before[source.id.uuidString], after[source.id.uuidString])
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: package.appendingPathComponent("Objects").path
      ).count, files.count + 1)
    XCTAssertEqual(try repository.load(project.id).objects, project.objects)
  }
  func testBatchFailureRestoresArtworkGraphAndUndoHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    let project = Samples.clock()
    engine.project = project
    XCTAssertThrowsError(
      try engine.call(
        "form_batch",
        arguments: [
          "operations": [
            [
              "name": "form_link_artwork",
              "arguments": ["object_id": project.objects[0].id.uuidString],
            ],
            [
              "name": "form_link_artwork",
              "arguments": [
                "object_id": project.objects[0].id.uuidString,
                "source_object_id": UUID().uuidString,
              ],
            ],
          ]
        ]))
    XCTAssertEqual(engine.project, project)
    XCTAssertTrue(engine.undoStack.isEmpty)
  }
  func testSurfaceBoundaryKeepsCircularCornersAndBoreTransparentAndSVGMatches() async throws {
    try await MainActor.run {
      var art = Artwork(background: "#FFFFFF")
      art.boundary = ClockDesign.boundary(diameter: 100, bore: 10)
      let image = ArtworkRenderer.image(
        art, width: 100, height: 100, assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 2)
      let bitmap = image.representations[0] as! NSBitmapImageRep
      XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)!.alphaComponent, 0)
      XCTAssertEqual(bitmap.colorAt(x: 100, y: 100)!.alphaComponent, 0)
      XCTAssertEqual(bitmap.colorAt(x: 100, y: 30)!.alphaComponent, 1)
      let svg = try SVGRenderer.document(
        art, width: 100, height: 100, assets: URL(fileURLWithPath: "/tmp"))
      XCTAssertTrue(svg.contains("clip-rule=\"evenodd\""))
      XCTAssertTrue(svg.contains("surface-boundary"))
      let corner = ArtworkElement(kind: "rectangle", x: 0, y: 0, width: 10, height: 10)
      art.elements = [corner]
      let selected = try art.exporting([corner.id])
      let crop = ArtworkRenderer.image(
        selected.artwork, width: 10, height: 10, assets: URL(fileURLWithPath: "/tmp"),
        pixelsPerMM: 2)
      XCTAssertEqual(
        (crop.representations[0] as! NSBitmapImageRep).colorAt(x: 10, y: 10)!.alphaComponent, 0)
    }
  }
}

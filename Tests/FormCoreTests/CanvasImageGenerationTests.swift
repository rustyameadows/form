import Foundation
import XCTest
@testable import FormCore

final class CanvasImageGenerationTests: XCTestCase {
  private func provenance() -> CanvasImageGenerationProvenance {
    .init(createdAt: Date(timeIntervalSince1970: 123456), prompt: "A quiet blue composition", model: "sunburst",
      provider: "Local demo · no AI request", isDemo: true, settings: ["transport": "none"],
      references: [.init(sourceProjectID: UUID(), objectID: UUID(), elementIDs: [UUID(), UUID()], name: "Historical composition",
        sourceSHA256: String(repeating: "a", count: 64), renderedSHA256: String(repeating: "b", count: 64))],
      outputSHA256: String(repeating: "c", count: 64), pixelWidth: 512, pixelHeight: 768)
  }
  func testBlankCreationAndResultAreIndependentUndoStepsAndPortableNormalArtwork() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root: root), engine = OperationEngine(repository: repository)
    engine.project = Project(name: "Generated study")
    let original = engine.project!
    var id = UUID()
    try engine.edit("Created image artboard") { id = try CanvasImageGeneration.createArtboard(in: &$0, at: .init(72,-24)).id }
    let blank = engine.project!, snapshot = try CanvasImageGeneration.destination(in: blank, objectID: id)
    XCTAssertEqual(blank.objects.last?.artwork?.canvasPosition, .init(72,-24))
    XCTAssertTrue(blank.objects.last?.artwork?.elements.isEmpty == true)
    XCTAssertEqual(engine.undoStack.count, 1)
    let metadata = provenance()
    var imageID = UUID()
    try engine.edit("Generated Canvas image") {
      imageID = try CanvasImageGeneration.placeResult(in: &$0, destination: snapshot, asset: "generated.png", provenance: metadata)
    }
    let result = engine.project!, object = try XCTUnwrap(result.objects.first { $0.id == id })
    XCTAssertEqual(result.minimumSchemaVersion, 60)
    XCTAssertEqual(object["width"], snapshot.width)
    XCTAssertEqual(object["depth"], snapshot.height)
    XCTAssertEqual(object.artwork?.elements.first?.width, snapshot.width)
    XCTAssertEqual(object.artwork?.elements.first?.height, snapshot.height)
    XCTAssertEqual(object.artwork?.elements.first?.kind, "image")
    XCTAssertEqual(object.artwork?.elements.first?.imageGeneration, metadata)
    XCTAssertEqual(engine.undoStack.count, 2)
    engine.undo(); XCTAssertEqual(engine.project, blank)
    engine.undo(); XCTAssertEqual(engine.project, original)
    engine.redo(); engine.redo(); XCTAssertEqual(engine.project, result)
    try repository.save(result)
    XCTAssertEqual(try repository.load(result.id).objects.first?.artwork?.elements.first?.imageGeneration, metadata)
    let bundle = try ArtworkTransferGraph.capture(project: result, objectID: id, ids: [imageID], readAsset: { _, _ in Data([1,2,3]) })
    let decoded = try ArtworkTransferBundle.decode(bundle.encoded())
    var destinationProject = Project(name: "Another document")
    let workspace = try destinationProject.ensureCanvasWorkspace()
    let plan = try ArtworkTransferGraph.plan(decoded, into: destinationProject, objectID: workspace.id)
    XCTAssertEqual(plan.project.canvasWorkspace?.artwork?.elements.first?.imageGeneration, metadata)
    XCTAssertEqual(plan.project.canvasWorkspace?.artwork?.elements.first?.kind, "image")
  }
  func testDestinationAllowsPlacementChangesButNeverOverwritesUserContentLocksOrAnotherProject() throws {
    var project = Project(name: "Destination")
    let id = try CanvasImageGeneration.createArtboard(in: &project, at: .init(1,2)).id
    let snapshot = try CanvasImageGeneration.destination(in: project, objectID: id), original = project
    project.objects[0].name = "Renamed"; project.objects[0].artwork?.canvasPosition = .init(90,100)
    XCTAssertNoThrow(try CanvasImageGeneration.validateDestination(snapshot, in: project))
    for mutation: (inout Project) -> Void in [
      { $0.objects[0].locked = true },
      { $0.objects[0].parameters["width"] = 33 },
      { $0.objects[0].artwork?.background = "#123456" },
      { $0.objects[0].artwork?.elements = [ArtworkElement(kind: "rectangle", x: 0, y: 0)] },
      { $0.objects.removeAll() },
      { $0.id = UUID() }
    ] {
      var changed = original; mutation(&changed); let before = changed
      XCTAssertThrowsError(try CanvasImageGeneration.placeResult(in: &changed, destination: snapshot, asset: "generated.png", provenance: provenance()))
      XCTAssertEqual(changed, before)
    }
  }
  func testEditingAidsDoNotInvalidateBlankDestinationButRenderingConfigurationDoes() throws {
    var project = Project(name:"Editing aids")
    let id = try CanvasImageGeneration.createArtboard(in:&project,at:.init(20,30)).id
    let snapshot = try CanvasImageGeneration.destination(in:project,objectID:id)
    project.objects[0].artwork?.guides = [.init(axis:"x",position:12),.init(axis:"y",position:18)]
    project.objects[0].artwork?.showGuides = false; project.objects[0].artwork?.showGrid = true
    project.objects[0].artwork?.gridSpacing = 5; project.objects[0].artwork?.snapEnabled = false
    project.objects[0].artwork?.nudge = 2; project.objects[0].artwork?.unit = .inches
    XCTAssertNoThrow(try CanvasImageGeneration.validateDestination(snapshot,in:project))
    let aids = project.objects[0].artwork!
    for mutation: (inout Artwork)->Void in [
      { $0.backgroundOpacity = 0.5 }, { $0.bleed = 2 }, { $0.safeInset = 4 }, { $0.language = "fr" }
    ] {
      var changed = project; mutation(&changed.objects[0].artwork!)
      XCTAssertThrowsError(try CanvasImageGeneration.validateDestination(snapshot,in:changed,allowingResize:true))
    }
    try CanvasImageGeneration.placeResult(in:&project,destination:snapshot,asset:"generated.png",provenance:provenance())
    var retained = project.objects[0].artwork!; retained.elements = []
    XCTAssertEqual(retained,aids,"Result publication preserves all user editing aids")
  }
  func testMalformedOrOversizedProvenanceAndUnsafePathsAreRejectedAtomically() throws {
    var project = Project(name: "Bounded")
    let id = try CanvasImageGeneration.createArtboard(in: &project, at: .init()).id
    let snapshot = try CanvasImageGeneration.destination(in: project, objectID: id), original = project
    var malformed = provenance(); malformed.prompt = String(repeating: "é", count: 8_001)
    XCTAssertThrowsError(try malformed.validate())
    malformed = provenance(); malformed.references[0].elementIDs = [id,id]
    XCTAssertThrowsError(try malformed.validate())
    malformed = provenance(); malformed.outputSHA256 = "not a hash"
    XCTAssertThrowsError(try malformed.validate())
    for path in ["../outside.png", "/tmp/a.png", "a\\b.png", "a.jpg"] {
      XCTAssertThrowsError(try CanvasImageGeneration.placeResult(in: &project, destination: snapshot, asset: path, provenance: provenance()))
      XCTAssertEqual(project, original)
    }
    XCTAssertThrowsError(try CanvasImageGeneration.createArtboard(in: &project, at: .init(.infinity,0)))
    XCTAssertEqual(project, original)
    try CanvasImageGeneration.placeResult(in: &project, destination: snapshot, asset: "ok.png", provenance: provenance())
    project.objects[0].artwork?.elements[0].imageGeneration?.pixelWidth = 0
    XCTAssertThrowsError(try project.validateArtworkLinks())
  }

  func testGenerationProvenanceRequiresAnImageLayer() throws {
    var element = ArtworkElement(kind: "image", x: 0, y: 0, width: 20, height: 10, asset: "generated.png")
    element.imageGeneration = provenance()
    XCTAssertNoThrow(try validateArtwork(Artwork(elements: [element])))
    for kind in ["rectangle", "text", "group"] {
      element.kind = kind
      XCTAssertThrowsError(try validateArtwork(Artwork(elements: [element]))) { error in
        XCTAssertTrue(error.localizedDescription.contains("only to image layers"))
      }
    }
  }
}

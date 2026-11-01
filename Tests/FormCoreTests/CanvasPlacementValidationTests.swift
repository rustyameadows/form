import Foundation
import XCTest
@testable import FormCore

final class CanvasPlacementValidationTests: XCTestCase {
  private func fixture() throws -> OperationEngine {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("placement-validation-" + UUID().uuidString)
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    var project = Project(name: "Canvas placement validation")
    var sheet = try project.makeObject(recipeID: "artboard")
    sheet.artwork = .init(elements: (0..<128).map {
      .init(kind: "rectangle", x: Double($0), y: 0, width: 10, height: 10, color: "#315746")
    })
    var paper = try project.makeObject(recipeID: "paperEnvelope")
    paper.paperConstruction = try PaperConstruction.definition(for: paper)
    paper.paperConstruction?.insideArtwork = .init(background: "#FFFFFF")
    project.objects = [sheet, paper]
    project.schemaVersion = project.minimumSchemaVersion
    engine.project = project
    return engine
  }

  func testPlacementGestureValidatesOnceAndPreservesExactUndoRedoAndCancellation() throws {
    let engine = try fixture(), original = try XCTUnwrap(engine.project)
    let token = engine.beginInteraction("place-frame")
    for step in 1...20 {
      try engine.edit("Move frame", coalescing: "place-frame") {
        $0.objects[0].artwork?.canvasPosition = .init(Double(step), -Double(step))
        $0.objects[1].canvasProjectionPositions = ["front": .init(Double(step) * 3, 60)]
        $0.objects[1].paperConstruction?.insideArtwork?.canvasPosition = .init(40, Double(step))
      }
    }
    engine.endInteraction(ifGeneration: token)
    let moved = try XCTUnwrap(engine.project)
    XCTAssertEqual(engine.artworkLinkValidationCount, 1)
    XCTAssertEqual(engine.placementValidationReuseCount, 19)
    XCTAssertEqual(engine.undoStack, [original])
    XCTAssertEqual(moved.objects[0].artwork?.elements, original.objects[0].artwork?.elements)
    engine.undo(); XCTAssertEqual(engine.project, original)
    engine.redo(); XCTAssertEqual(engine.project, moved)
    let next = engine.beginInteraction("cancel-frame")
    try engine.edit("Move frame", coalescing: "cancel-frame") { $0.objects[0].artwork?.canvasPosition = .init(500, 900) }
    XCTAssertTrue(engine.cancelInteraction(ifGeneration: next))
    XCTAssertEqual(engine.project, moved)
    XCTAssertEqual(engine.undoStack, [original])
    XCTAssertEqual(engine.artworkLinkValidationCount, 1)
  }

  func testAuthoredAndSharedContentChangesAlwaysRequireFullValidation() throws {
    let engine = try fixture()
    try engine.edit("Validate unchanged document") { _ in }
    let edits: [(inout Project) -> Void] = [
      { $0.objects[0].artwork!.elements[0].x += 1 },
      { $0.objects[0].artwork!.elements[0].color = "#889944" },
      { $0.objects[0].artwork!.guides = [.init(axis: "x", position: 7)] },
      { $0.objects[1].paperConstruction!.insideArtwork!.background = "#EEEEEE" },
      { $0.objects[0].parameters["width"] = 220 },
      { $0.objects[0].position.x += 10 },
      { $0.camera.azimuth += 0.2 },
      { $0.swatches = [.init(name: "Accent", color: "#2288AA")] },
      { $0.textStyles = [.init(name: "Body", fontSize: 16)] },
      { $0.textStories = [.init(source: .init(kind: "text", x: 0, y: 0, text: "Shared source"))] },
      { $0.objects.swapAt(0, 1) }
    ]
    for (index, edit) in edits.enumerated() {
      try engine.edit("Content edit") { value in
        edit(&value)
        value.objects[0].canvasProjectionPositions = ["proof": .init(Double(index), 0)]
      }
      XCTAssertEqual(engine.artworkLinkValidationCount, index + 2, "Content change \(index) was not fully validated")
    }
    XCTAssertEqual(engine.placementValidationReuseCount, 0)
  }

  func testFirstAndExternallyReplacedMalformedDocumentsCannotSeedOrUseSnapshot() throws {
    let engine = try fixture(), valid = try XCTUnwrap(engine.project)
    var invalid = valid; invalid.objects[0].artworkSourceID = UUID()
    engine.project = invalid
    XCTAssertThrowsError(try engine.edit("Initial invalid move") { $0.objects[0].artwork?.canvasPosition = .init(1, 2) })
    XCTAssertEqual(engine.project, invalid); XCTAssertTrue(engine.undoStack.isEmpty)
    XCTAssertEqual(engine.artworkLinkValidationCount, 1)
    engine.project = valid
    try engine.edit("First valid move") { $0.objects[0].artwork?.canvasPosition = .init(3, 4) }
    XCTAssertEqual(engine.artworkLinkValidationCount, 2)
    invalid = try XCTUnwrap(engine.project); invalid.objects[0].artworkSourceID = UUID()
    engine.project = invalid
    let undo = engine.undoStack
    XCTAssertThrowsError(try engine.edit("External invalid move") { $0.objects[0].artwork?.canvasPosition = .init(5, 6) })
    XCTAssertEqual(engine.project, invalid); XCTAssertEqual(engine.undoStack, undo)
    XCTAssertEqual(engine.artworkLinkValidationCount, 3); XCTAssertEqual(engine.placementValidationReuseCount, 0)
    var other = valid; other.id = UUID()
    engine.project = other
    try engine.edit("Different project") { $0.objects[0].artwork?.canvasPosition = .init(7, 8) }
    XCTAssertEqual(engine.artworkLinkValidationCount, 4)
  }

  func testInvalidPlacementCannotUseAValidSnapshotOrAlterHistory() throws {
    let engine = try fixture()
    try engine.edit("Seed validation") { _ in }
    let original = try XCTUnwrap(engine.project)
    let invalidEdits: [(inout Project) -> Void] = [
      { $0.objects[0].canvasProjectionPositions = ["": .init(1, 2)] },
      { $0.objects[0].canvasProjectionPositions = [String(repeating: "é", count: 257): .init(1, 2)] },
      { $0.objects[0].canvasProjectionPositions = Dictionary(uniqueKeysWithValues: (0...256).map { (String($0), Point2(1, 2)) }) },
      { $0.objects[0].canvasProjectionPositions = ["front": .init(Double.infinity, 0)] },
      { $0.objects[0].canvasProjectionPositions = ["front": .init(0, Double.nan)] },
      { $0.objects[0].canvasProjectionPositions = ["front": .init(100001, 0)] },
      { $0.objects[0].artwork?.canvasPosition = .init(0, -Double.infinity) },
      { $0.objects[0].artwork?.canvasPosition = .init(-100001, 0) },
      { $0.objects[1].paperConstruction?.insideArtwork?.canvasPosition = .init(Double.nan, 0) }
    ]
    for (index, edit) in invalidEdits.enumerated() {
      XCTAssertThrowsError(try engine.edit("Invalid placement", edit), "Invalid placement \(index)")
      XCTAssertEqual(engine.project, original); XCTAssertTrue(engine.undoStack.isEmpty)
      XCTAssertEqual(engine.artworkLinkValidationCount, 1)
      XCTAssertEqual(engine.placementValidationReuseCount, 0)
    }
    try engine.edit("Boundary placement") { $0.objects[0].artwork?.canvasPosition = .init(-100000, 100000) }
    XCTAssertEqual(engine.placementValidationReuseCount, 1)
  }

  func testPreparedEditIsValidatedAndFailuresNeverAdvanceSnapshot() throws {
    let engine = try fixture()
    try engine.edit("Seed validation") { _ in }
    let original = try XCTUnwrap(engine.project)
    engine.onPrepareProjectEdit = { _, value in value.objects[0].artworkSourceID = UUID() }
    XCTAssertThrowsError(try engine.edit("Prepared invalid move") { $0.objects[0].artwork?.canvasPosition = .init(20, 30) })
    XCTAssertEqual(engine.project, original); XCTAssertTrue(engine.undoStack.isEmpty)
    XCTAssertEqual(engine.artworkLinkValidationCount, 2)
    engine.onPrepareProjectEdit = nil
    try engine.edit("Recovered move") { $0.objects[0].artwork?.canvasPosition = .init(20, 30) }
    XCTAssertEqual(engine.artworkLinkValidationCount, 2); XCTAssertEqual(engine.placementValidationReuseCount, 1)
    let moved = try XCTUnwrap(engine.project)
    engine.onPrepareProjectEdit = { _, value in value.objects[0].artwork!.elements[0].width += 1 }
    try engine.edit("Prepared content change") { $0.objects[0].artwork?.canvasPosition = .init(40, 60) }
    XCTAssertEqual(engine.artworkLinkValidationCount, 3)
    engine.undo(); XCTAssertEqual(engine.project, moved)
    engine.onPrepareProjectEdit = nil
    try engine.edit("Move restored content") { $0.objects[0].artwork?.canvasPosition = .init(50, 70) }
    XCTAssertEqual(engine.artworkLinkValidationCount, 4, "Undo of content must not reuse the newer content validation")
  }

  func testDetachedSurfacePositionsAreCheckedWithoutRewritingSourceStories() throws {
    let engine = try fixture()
    var project = try XCTUnwrap(engine.project)
    var binding = PhysicalSurfaceArtworkBinding(surfaceID: "detached", sourceObjectID: UUID(), widthMM: 20, heightMM: 20)
    binding.sourceObjectID = nil; binding.artwork = .init(elements: [.init(kind: "text", x: 0, y: 0, text: "Exact detached source")])
    project.objects[0].surfaceArtworkBindings = [binding]
    let original = project
    project.objects[0].surfaceArtworkBindings?[0].artwork?.canvasPosition = .init(500, -900)
    XCTAssertTrue(CanvasPlacementValidation.sameContent(original, project))
    XCTAssertNoThrow(try CanvasPlacementValidation.validatePositions(in: project))
    XCTAssertEqual(project.objects[0].surfaceArtworkBindings?[0].artwork?.elements,
      original.objects[0].surfaceArtworkBindings?[0].artwork?.elements)
    project.objects[0].surfaceArtworkBindings?[0].artwork?.canvasPosition = .init(0, Double.nan)
    XCTAssertThrowsError(try CanvasPlacementValidation.validatePositions(in: project))
    project.objects[0].surfaceArtworkBindings?[0].artwork?.canvasPosition = nil
    project.objects[0].surfaceArtworkBindings?[0].artwork?.elements[0].text = "Changed source"
    XCTAssertFalse(CanvasPlacementValidation.sameContent(original, project))
  }

  func testBookkeepingNormalizationPreservesIdentitySchemaCreationAndResourceValues() throws {
    let engine = try fixture(), original = try XCTUnwrap(engine.project)
    var placed = original
    placed.history.append(.init("Moved frame")); placed.updatedAt = original.updatedAt.addingTimeInterval(10)
    placed.objects[0].artwork?.canvasPosition = .init(90, 80)
    XCTAssertTrue(CanvasPlacementValidation.sameContent(original, placed))
    let edits: [(inout Project) -> Void] = [
      { $0.id = UUID() },
      { $0.createdAt = $0.createdAt.addingTimeInterval(1) },
      { $0.schemaVersion += 1 },
      { $0.objects[0].id = UUID() },
      { $0.materials = [Material.presets[0]] },
      { $0.objects[0].artwork!.elements[0].x += 1 }
    ]
    for edit in edits {
      var changed = placed; edit(&changed)
      XCTAssertFalse(CanvasPlacementValidation.sameContent(original, changed))
    }
  }

  func testSeededWorkspaceCannotMoveAwayFromOrigin() throws {
    let engine = try fixture()
    var project = try XCTUnwrap(engine.project)
    let workspace = try project.ensureCanvasWorkspace()
    engine.project = project
    try engine.edit("Seed workspace validation") { _ in }
    let original = try XCTUnwrap(engine.project)
    let index = try XCTUnwrap(original.objects.firstIndex { $0.id == workspace.id })
    XCTAssertThrowsError(try engine.edit("Invalid workspace position") {
      $0.objects[index].artwork?.canvasPosition = .init(1, 2)
    })
    XCTAssertEqual(engine.project, original); XCTAssertTrue(engine.undoStack.isEmpty)
    XCTAssertEqual(engine.artworkLinkValidationCount, 2)
    XCTAssertEqual(engine.placementValidationReuseCount, 0)
    try engine.edit("Unspecified workspace origin") { $0.objects[index].artwork?.canvasPosition = nil }
    XCTAssertEqual(engine.artworkLinkValidationCount, 3)
    XCTAssertNil(engine.project?.objects[index].artwork?.canvasPosition)
    try engine.edit("Move an independent frame") { $0.objects[0].artwork?.canvasPosition = .init(20, 30) }
    XCTAssertEqual(engine.artworkLinkValidationCount, 3)
    XCTAssertEqual(engine.placementValidationReuseCount, 1)
  }

  func testClosingOrSwitchingProjectsDropsTheValidationSnapshot() throws {
    let engine = try fixture()
    try engine.edit("Seed validation") { _ in }
    let original = try XCTUnwrap(engine.project)
    let generation = engine.projectGeneration
    engine.project = nil
    engine.project = original
    XCTAssertEqual(engine.projectGeneration, generation + 2)
    try engine.edit("Reopened project placement") { $0.objects[0].artwork?.canvasPosition = .init(10, 20) }
    XCTAssertEqual(engine.artworkLinkValidationCount, 2)
    XCTAssertEqual(engine.placementValidationReuseCount, 0)
    let current = try XCTUnwrap(engine.project)
    var other = original; other.id = UUID()
    engine.project = other
    engine.project = current
    try engine.edit("Returned project placement") { $0.objects[0].artwork?.canvasPosition = .init(30, 40) }
    XCTAssertEqual(engine.artworkLinkValidationCount, 3)
    XCTAssertEqual(engine.placementValidationReuseCount, 0)
  }
}

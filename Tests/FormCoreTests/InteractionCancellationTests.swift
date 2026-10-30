import Foundation
import XCTest
@testable import FormCore

final class InteractionCancellationTests: XCTestCase {
  private func fixture() throws -> OperationEngine {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("interaction-cancel-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    engine.project = Project(name: "Original")
    return engine
  }

  func testCancelRestoresExactProjectAndExistingUndoRedoHistory() throws {
    let engine = try fixture()
    try engine.edit("Earlier edit") { $0.subtitle = "Keep this edit" }
    try engine.edit("Redo candidate") { $0.name = "Redo this" }
    engine.undo()
    let before = engine.project, undo = engine.undoStack, redo = engine.redoStack
    let token = engine.beginInteraction("drag")
    try engine.edit("Drag", coalescing: "drag") { $0.name = "Intermediate" }
    try engine.edit("Drag", coalescing: "drag") { $0.name = "Final"; $0.subtitle = "Temporary" }
    XCTAssertTrue(engine.cancelInteraction(ifGeneration: token))
    XCTAssertEqual(engine.project, before)
    XCTAssertEqual(engine.undoStack, undo); XCTAssertEqual(engine.redoStack, redo)
    XCTAssertFalse(engine.isInteracting(with: "drag"))
    XCTAssertFalse(engine.cancelInteraction(ifGeneration: token))
    engine.redo(); XCTAssertEqual(engine.project?.name, "Redo this")
  }

  func testStaleGenerationCannotCancelNewGestureEvenWithTheSameKey() throws {
    let engine = try fixture()
    let old = engine.beginInteraction("drag")
    try engine.edit("First drag", coalescing: "drag") { $0.name = "First" }
    engine.endInteraction()
    let current = engine.beginInteraction("drag"), before = engine.project
    XCTAssertNotEqual(current, old)
    XCTAssertTrue(engine.isInteracting(withGeneration: current))
    XCTAssertFalse(engine.isInteracting(withGeneration: old))
    try engine.edit("Second drag", coalescing: "drag") { $0.name = "Second" }
    let changed = engine.project
    XCTAssertFalse(engine.cancelInteraction(ifGeneration: old))
    XCTAssertEqual(engine.project, changed); XCTAssertTrue(engine.isInteracting(with: "drag"))
    XCTAssertTrue(engine.cancelInteraction(ifGeneration: current))
    XCTAssertFalse(engine.isInteracting(withGeneration: current))
    XCTAssertEqual(engine.project, before)
    XCTAssertEqual(engine.undoStack.count, 1)
    engine.undo(); XCTAssertEqual(engine.project?.name, "Original")
  }

  func testUnrelatedCommandCommitsGestureAndCannotBeRolledBackByLateCancellation() throws {
    let engine = try fixture(), token = engine.beginInteraction("drag")
    try engine.edit("Drag", coalescing: "drag") { $0.name = "Moved" }
    try engine.edit("Separate command") { $0.subtitle = "Keep independent change" }
    let changed = engine.project, undo = engine.undoStack
    XCTAssertFalse(engine.cancelInteraction(ifGeneration: token))
    XCTAssertEqual(engine.project, changed); XCTAssertEqual(engine.undoStack, undo)
  }

  func testCancellationDoesNotReplaceAnotherProject() throws {
    let engine = try fixture(), token = engine.beginInteraction("drag")
    try engine.edit("Drag", coalescing: "drag") { $0.name = "Moved" }
    let replacement = Project(name: "Different document")
    engine.project = replacement
    XCTAssertFalse(engine.cancelInteraction(ifGeneration: token))
    XCTAssertEqual(engine.project, replacement)
    engine.endInteraction()
  }
}

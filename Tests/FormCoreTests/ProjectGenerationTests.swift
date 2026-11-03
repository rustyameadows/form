import Foundation
import XCTest
@testable import FormCore

final class ProjectGenerationTests: XCTestCase {
  func testDirectNestedAssignmentsUndoAndRedoAdvanceGeneration() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    XCTAssertEqual(engine.projectGeneration,0)
    engine.project=Project(name:"Generation")
    let assigned=engine.projectGeneration
    engine.project?.camera.azimuth=0.8
    XCTAssertGreaterThan(engine.projectGeneration,assigned)
    let camera=engine.projectGeneration
    try engine.edit("Rename") { $0.name="Updated" }
    XCTAssertGreaterThan(engine.projectGeneration,camera)
    let edited=engine.projectGeneration
    engine.undo();XCTAssertEqual(engine.project?.name,"Generation")
    XCTAssertGreaterThan(engine.projectGeneration,edited)
    let undone=engine.projectGeneration
    engine.redo();XCTAssertEqual(engine.project?.name,"Updated")
    XCTAssertGreaterThan(engine.projectGeneration,undone)
    let redone=engine.projectGeneration
    engine.project=nil;XCTAssertGreaterThan(engine.projectGeneration,redone)
  }
}

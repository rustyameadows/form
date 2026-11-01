import Foundation
import XCTest
@testable import FormCore

final class LiveContextTests: XCTestCase {
  private func engine() throws -> OperationEngine {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-context-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return OperationEngine(repository: try ProjectRepository(root: root))
  }

  private func dictionary(_ value: Any, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
    try XCTUnwrap(value as? [String: Any], file: file, line: line)
  }

  private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }

  private func response(_ method: String, params: [String: Any] = [:], engine: OperationEngine) throws -> [String: Any] {
    let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
    return try XCTUnwrap(MCP.respond(to: json(request), invoke: { try engine.call($0, arguments: $1) }))
  }

  func testCoreWithoutProjectExplicitlyReportsUIUnavailableAndNoTarget() throws {
    let engine = try engine()
    engine.selection = [UUID()]
    let context = try dictionary(engine.call("form_get_context"))
    XCTAssertEqual(context["schema_version"] as? Int, 1)
    XCTAssertEqual(context["ui_available"] as? Bool, false)
    XCTAssertTrue(context["project_id"] is NSNull)
    XCTAssertTrue(context["active_target"] is NSNull)
    XCTAssertEqual(try dictionary(context["table"] as Any)["selected_object_ids"] as? [String], [])
    XCTAssertNil(context["canvas"])
    XCTAssertNil(context["studio"])
    XCTAssertNil(engine.project)
    XCTAssertTrue(engine.undoStack.isEmpty)
  }

  func testCoreSelectionFiltersStaleAndNonTableIDsWithoutChangingSelection() throws {
    let engine = try engine()
    var project = Project(name: "Selection context")
    let workspace = try project.ensureCanvasWorkspace()
    let physical = try project.makeObject(recipeID: "artboard")
    var source = try project.makeObject(recipeID: "artboard")
    source.canvasSourceOnly = true
    project.objects += [physical, source]
    engine.project = project
    let selected: Set<UUID> = [physical.id, source.id, workspace.id, UUID()]
    engine.selection = selected
    let context = try dictionary(engine.call("form_get_context"))
    let table = try dictionary(context["table"] as Any)
    XCTAssertEqual(table["selected_object_ids"] as? [String], [physical.id.uuidString])
    XCTAssertEqual(context["project_id"] as? String, project.id.uuidString)
    XCTAssertTrue(context["active_target"] is NSNull)
    let status = try dictionary(engine.call("form_status"))
    XCTAssertEqual(status["selected_objects"] as? [String], [physical.id, source.id, workspace.id].map(\.uuidString).sorted())
    XCTAssertEqual(try json(status["context"] as Any), try json(context))
    XCTAssertEqual(engine.project, project)
    XCTAssertEqual(engine.selection, selected)
    // An un-reconciled selection from a different document must never leak.
    engine.project = Project(name: "Other document")
    let switched = try dictionary(engine.call("form_get_context"))
    XCTAssertEqual(try dictionary(switched["table"] as Any)["selected_object_ids"] as? [String], [])
  }

  func testNativeCallbackIsFreshAndSharedByToolStatusAndResource() throws {
    let engine = try engine()
    var calls = 0
    var selected = UUID().uuidString
    engine.onContext = {
      calls += 1
      return ["schema_version": 1, "ui_available": true, "canvas": ["selected_element_ids": [selected]], "active_target": NSNull()]
    }
    let first = try dictionary(engine.call("form_get_context"))
    XCTAssertEqual(calls, 1)
    let status = try dictionary(engine.call("form_status"))
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(try json(status["context"] as Any), try json(first))
    selected = UUID().uuidString
    let resource = try dictionary(response("resources/read", params: ["uri": "form://context"], engine: engine)["result"] as Any)
    XCTAssertEqual(calls, 3)
    let contents = try XCTUnwrap(resource["contents"] as? [[String: Any]])
    XCTAssertEqual(contents.first?["uri"] as? String, "form://context")
    let text = try XCTUnwrap(contents.first?["text"] as? String)
    let live = try dictionary(JSONSerialization.jsonObject(with: Data(text.utf8)))
    XCTAssertEqual(try dictionary(live["canvas"] as Any)["selected_element_ids"] as? [String], [selected])
    XCTAssertNotEqual(try json(live), try json(first), "Context must not reuse a previous selection snapshot")
  }

  func testReadingContextPreservesActiveGestureHistoryRedoAndProjectShape() throws {
    let engine = try engine()
    engine.project = Project(name: "Original")
    try engine.edit("First") { $0.name = "First" }
    try engine.edit("Second") { $0.name = "Second" }
    engine.undo()
    let token = engine.beginInteraction("native-live-edit")
    let before = try XCTUnwrap(engine.project)
    let undo = engine.undoStack, redo = engine.redoStack, generation = engine.projectGeneration
    let selected: Set<UUID> = [UUID()]
    engine.selection = selected
    var preparations = 0
    engine.onPrepareProjectEdit = { _, _ in preparations += 1 }
    _ = try engine.call("form_get_context")
    _ = try engine.call("form_status")
    _ = try response("resources/read", params: ["uri": "form://context"], engine: engine)
    let stored = try dictionary(engine.call("form_get_project"))
    XCTAssertEqual(try json(stored), try json(jsonObject(before)))
    XCTAssertNil(stored["context"], "form_get_project retains the Project wire shape")
    XCTAssertEqual(engine.project, before)
    XCTAssertEqual(engine.undoStack, undo)
    XCTAssertEqual(engine.redoStack, redo)
    XCTAssertEqual(engine.projectGeneration, generation)
    XCTAssertEqual(engine.selection, selected)
    XCTAssertEqual(preparations, 0)
    XCTAssertTrue(engine.isInteracting(withGeneration: token))
  }

  func testDiscoveryAndInstructionsExposeReadOnlyFreshContext() throws {
    let engine = try engine()
    let listing = try dictionary(response("tools/list", engine: engine)["result"] as Any)
    let tools = try XCTUnwrap(listing["tools"] as? [[String: Any]])
    let matching = tools.filter { $0["name"] as? String == "form_get_context" }
    XCTAssertEqual(matching.count, 1)
    let tool = try XCTUnwrap(matching.first)
    XCTAssertEqual(try dictionary(tool["annotations"] as Any)["readOnlyHint"] as? Bool, true)
    let schema = try dictionary(tool["inputSchema"] as Any)
    XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    XCTAssertTrue(try dictionary(schema["properties"] as Any).isEmpty)
    let resources = try dictionary(response("resources/list", engine: engine)["result"] as Any)
    XCTAssertEqual(Set((resources["resources"] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String }), ["form://project", "form://recipes", "form://context"])
    let initialized = try dictionary(response("initialize", engine: engine)["result"] as Any)
    let instructions = try XCTUnwrap(initialized["instructions"] as? String)
    XCTAssertTrue(instructions.contains("Call form_get_context fresh"))
    XCTAssertTrue(instructions.contains("Explicit copied references and IDs take precedence"))
    XCTAssertTrue(instructions.contains("never silently retarget"))
  }

  func testUnknownResourceDoesNotInvokeAnyTool() throws {
    let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": ["uri": "form://unknown"]]
    var calls = 0
    let result = try XCTUnwrap(MCP.respond(to: json(request), invoke: { _, _ in calls += 1; return [:] }))
    XCTAssertEqual(try dictionary(result["error"] as Any)["code"] as? Int, -32602)
    XCTAssertEqual(calls, 0)
  }
}

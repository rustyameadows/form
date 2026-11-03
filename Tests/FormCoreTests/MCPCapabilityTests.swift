import Foundation
import XCTest
@testable import FormCore

final class MCPCapabilityTests: XCTestCase {
  private func dictionary(_ value: Any?) throws -> [String: Any] { try XCTUnwrap(value as? [String: Any]) }
  private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
  }
  private func engine() throws -> OperationEngine {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-capabilities-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return OperationEngine(repository: try ProjectRepository(root: root))
  }
  private func request(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
    try json(["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
  }

  func testFingerprintIsOrderIndependentAndIncludesNestedContractChanges() throws {
    let a: [String: Any] = ["name": "alpha", "inputSchema": ["type": "object", "properties": ["layout": ["enum": ["pages", "spreads"]]]]]
    let b: [String: Any] = ["name": "beta", "annotations": ["readOnlyHint": true]]
    let reversedKeys: [String: Any] = ["inputSchema": ["properties": ["layout": ["enum": ["pages", "spreads"]]], "type": "object"], "name": "alpha"]
    XCTAssertEqual(try MCPCapabilities.fingerprint(of: [a, b]), try MCPCapabilities.fingerprint(of: [b, reversedKeys]))
    var changed = a
    changed["inputSchema"] = ["type": "object", "properties": ["layout": ["enum": ["pages", "spreads", "booklet"]]]]
    XCTAssertNotEqual(try MCPCapabilities.fingerprint(of: [a, b]), try MCPCapabilities.fingerprint(of: [changed, b]))
    XCTAssertEqual(MCPCapabilities.schemaFingerprint, try MCPCapabilities.fingerprint(of: MCP.tools))
    XCTAssertEqual(MCPCapabilities.schemaFingerprint.count, 71)
  }

  func testLegacyStatusCarriesExactBoundedPublicationRecoverySchemas() throws {
    let engine = try engine()
    let status = try dictionary(engine.call("form_status")), capabilities = try dictionary(status["capabilities"])
    let schemas = try XCTUnwrap(capabilities["recovery_schemas"] as? [[String: Any]])
    XCTAssertEqual(schemas.compactMap { $0["name"] as? String }, MCPCapabilities.recoverySchemaNames)
    XCTAssertEqual(capabilities["recovery_schemas_complete"] as? Bool, true)
    XCTAssertLessThanOrEqual(try json(schemas).count, 131_072)
    for schema in schemas {
      let canonical = try XCTUnwrap(MCP.tools.first { $0["name"] as? String == schema["name"] as? String })
      XCTAssertEqual(try json(schema), try json(canonical))
    }
    let publication = try XCTUnwrap(schemas.first { $0["name"] as? String == "form_publication" })
    let properties = try dictionary(dictionary(publication["inputSchema"])["properties"])
    let commands = try XCTUnwrap(dictionary(properties["command"])["enum"] as? [String])
    XCTAssertTrue(commands.contains("sheet_assembly_inspect")); XCTAssertTrue(commands.contains("page_settings"))
    let assemblyProperties = try dictionary(dictionary(properties["definition"])["properties"])
    XCTAssertNotNil(assemblyProperties["parentSheets"]); XCTAssertNotNil(assemblyProperties["binding"])
    let export = try XCTUnwrap(schemas.first { $0["name"] as? String == "form_export_publication" })
    let exportFields = try dictionary(dictionary(export["inputSchema"])["properties"])
    XCTAssertNotNil(exportFields["layout"]); XCTAssertNotNil(exportFields["physical_object_id"])
    XCTAssertNotNil(exportFields["pad_to_multiple_of_four"])
    XCTAssertNil(engine.project); XCTAssertTrue(engine.undoStack.isEmpty)
  }

  func testCatalogPaginationAndCompleteSchemaRetrievalMatchToolsList() throws {
    var names: [String] = [], offset = 0
    repeat {
      let page = try MCPCapabilities.call(["command": "list", "offset": offset, "limit": 7])
      let entries = try XCTUnwrap(page["tools"] as? [[String: Any]])
      XCTAssertLessThanOrEqual(entries.count, 7)
      names += entries.compactMap { $0["name"] as? String }
      guard let next = page["next_offset"] as? Int else { break }
      XCTAssertGreaterThan(next, offset); offset = next
    } while offset < 1_000
    XCTAssertEqual(names, MCP.toolNames.sorted())
    let selected = ["form_studio_scene", "form_publication"]
    let result = try MCPCapabilities.call(["command": "schema", "tool_names": selected])
    XCTAssertEqual(result["schemas_complete"] as? Bool, true)
    let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.compactMap { $0["name"] as? String }, selected)
    for tool in tools {
      let original = try XCTUnwrap(MCP.tools.first { $0["name"] as? String == tool["name"] as? String })
      XCTAssertEqual(try json(tool), try json(original))
    }
    XCTAssertLessThan(try json(result).count, MCPCapabilities.maximumResponseBytes)
  }

  func testInvalidDiscoveryArgumentsRejectWithoutTruncationOrUnknownFallback() throws {
    let invalid: [[String: Any]] = [
      ["command": "schema", "tool_names": []],
      ["command": "schema", "tool_names": ["form_status", "form_status"]],
      ["command": "schema", "tool_names": ["not_a_tool"]],
      ["command": "schema", "tool_names": Array(MCP.toolNames.sorted().prefix(9))],
      ["command": "list", "offset": -1], ["command": "list", "offset": true],
      ["command": "list", "limit": 1.5], ["command": "list", "limit": 33],
      ["command": "summary", "limit": 1], ["command": "other"],
      ["expected_schema_fingerprint": true], ["unknown": 1]
    ]
    for arguments in invalid { XCTAssertThrowsError(try MCPCapabilities.call(arguments), "\(arguments)") }
  }

  func testExpectedFingerprintMismatchIsExplicitAndReadOnlyDuringGesture() throws {
    let engine = try engine(); engine.project = Project(name: "Discovery does not edit")
    try engine.edit("Rename") { $0.name = "Changed" }; engine.undo()
    let token = engine.beginInteraction("native-draft")
    let project = engine.project, undo = engine.undoStack, redo = engine.redoStack
    let generation = engine.projectGeneration
    let result = try dictionary(engine.call("form_capabilities", arguments: ["command": "schema", "tool_names": ["form_publication"], "expected_schema_fingerprint": "sha256:old"]))
    XCTAssertEqual(result["schema_match"] as? Bool, false)
    XCTAssertEqual(result["diagnostic"] as? String, "schema_mismatch")
    XCTAssertEqual(result["client_wrapper_observation"] as? String, "unavailable")
    let match = try MCPCapabilities.call(["expected_schema_fingerprint": MCPCapabilities.schemaFingerprint])
    XCTAssertEqual(match["schema_match"] as? Bool, true)
    XCTAssertEqual(engine.project, project); XCTAssertEqual(engine.undoStack, undo); XCTAssertEqual(engine.redoStack, redo)
    XCTAssertEqual(engine.projectGeneration, generation); XCTAssertTrue(engine.isInteracting(withGeneration: token))
    XCTAssertNil(try dictionary(engine.call("form_get_project"))["capabilities"])
  }

  func testResourceDiscoveryRoutesExactSchemaAndRejectsMalformedNames() throws {
    let engine = try engine()
    let response = try XCTUnwrap(MCP.respond(to: request("resources/read", ["uri": "form://schema/form_publication"]), invoke: { try engine.call($0, arguments: $1) }))
    let result = try dictionary(response["result"])
    let contents = try XCTUnwrap(result["contents"] as? [[String: Any]])
    let text = try XCTUnwrap(contents.first?["text"] as? String)
    let catalog = try dictionary(JSONSerialization.jsonObject(with: Data(text.utf8)))
    XCTAssertEqual((catalog["tools"] as? [[String: Any]])?.first?["name"] as? String, "form_publication")
    for uri in ["form://schema/", "form://schema/../project", "form://schema/form_status?extra=1"] {
      var invoked = false
      let response = try XCTUnwrap(MCP.respond(to: request("resources/read", ["uri": uri]), invoke: { _, _ in invoked = true; return [:] }))
      XCTAssertEqual(try dictionary(response["error"])["code"] as? Int, -32602)
      XCTAssertFalse(invoked)
    }
    let templates = try XCTUnwrap(MCP.respond(to: request("resources/templates/list"), invoke: { _, _ in XCTFail("Discovery must not call the app"); return [:] }))
    let values = try XCTUnwrap(dictionary(templates["result"])["resourceTemplates"] as? [[String: Any]])
    XCTAssertEqual(values.first?["uriTemplate"] as? String, "form://schema/{tool_name}")
  }

  func testOfflineProtocolDiscoveryDoesNotProbeTheAppOrClaimNotifications() throws {
    var calls = 0
    let connection = MCPBridgeConnection { _, _ in calls += 1; throw FormError.missing("Closed app") }
    for method in ["initialize", "tools/list"] {
      let response = try XCTUnwrap(MCP.respond(to: request(method), invoke: { try connection.invoke($0, arguments: $1) }, runtimeDiagnostics: { connection.diagnostics() }))
      let result = try dictionary(response["result"])
      let metadata = try dictionary(dictionary(result["_meta"])["lab"])
      XCTAssertEqual(metadata["state"] as? String, "app_not_observed")
      XCTAssertEqual(metadata["client_refresh_performed"] as? Bool, false)
      if method == "initialize" {
        let capabilities = try dictionary(result["capabilities"])
        XCTAssertNil(try dictionary(capabilities["tools"])["listChanged"])
        XCTAssertNil(try dictionary(capabilities["resources"])["listChanged"])
      }
    }
    XCTAssertEqual(calls, 0)
  }

  func testRealStatusObservationDistinguishesHelperAppAndUnknownClientWrapper() throws {
    var calls = 0, fingerprint = MCPCapabilities.schemaFingerprint
    let connection = MCPBridgeConnection { _, _ in
      calls += 1
      return ["capabilities": ["schema_fingerprint": fingerprint, "runtime": ["process_instance_id": "app-runtime"]]]
    }
    var status = try dictionary(connection.invoke("form_status", arguments: [:]))
    XCTAssertEqual(try dictionary(status["mcp_connection"])["state"] as? String, "app_helper_schema_match")
    fingerprint = "sha256:other"
    status = try dictionary(connection.invoke("form_status", arguments: [:]))
    let diagnostic = try dictionary(status["mcp_connection"])
    XCTAssertEqual(diagnostic["state"] as? String, "app_helper_schema_mismatch")
    XCTAssertEqual(diagnostic["client_wrapper_status"] as? String, "not_observable")
    XCTAssertEqual(connection.diagnostics()["app_observation"] as? String, "previous_explicit_tool_call")
    XCTAssertEqual(calls, 2)
    let unknown = MCPConnectionDiagnostics.report(applicationStatus: [:])
    XCTAssertEqual(unknown["state"] as? String, "app_metadata_unavailable")
    let differentBuild = MCPConnectionDiagnostics.report(applicationStatus: ["capabilities": ["schema_fingerprint": "same", "runtime": ["packaged_build": ["build_id": "new"]]]], helperFingerprint: "same", helperRuntime: ["packaged_build": ["build_id": "old"]])
    XCTAssertEqual(differentBuild["state"] as? String, "app_helper_build_mismatch")
  }

  func testPackagedBuildIdentityIsBoundedAndOptional() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-build-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("LAB.app/Contents/Resources")
    let executable = root.appendingPathComponent("LAB.app/Contents/MacOS/lab-mcp")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let manifest = resources.appendingPathComponent("LABBuild.json")
    XCTAssertNil(MCPRuntimeIdentity.packagedBuild(executable: executable))
    try json(["format_version": 1, "build_id": "test-build", "source_revision": "abc"]).write(to: manifest)
    XCTAssertEqual(MCPRuntimeIdentity.packagedBuild(executable: executable)?["build_id"] as? String, "test-build")
    try Data(repeating: 32, count: 65_537).write(to: manifest)
    XCTAssertNil(MCPRuntimeIdentity.packagedBuild(executable: executable))
    XCTAssertNil(MCPRuntimeIdentity.packagedBuild(executable: root.appendingPathComponent("loose-helper")))
  }
}

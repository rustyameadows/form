import XCTest

@testable import FormCore

final class FormCoreTests: XCTestCase {
  var root: URL!
  var repository: ProjectRepository!
  var engine: OperationEngine!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "form-tests-" + UUID().uuidString)
    repository = try ProjectRepository(root: root)
    engine = OperationEngine(repository: repository)
    _ = try engine.call("form_create_project", arguments: ["name": "Test study"])
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
  @discardableResult func addLamp() throws -> ProductObject {
    _ = try engine.call(
      "form_add_object",
      arguments: ["recipe_id": "lamp", "name": "Test lamp", "parameters": ["height": 350]])
    return engine.project!.objects.last!
  }
  func testArithmeticExpressions() throws {
    XCTAssertEqual(
      try Expression.evaluate(
        "(height - 12) / 2 + width*0.5", variables: ["height": 312, "width": 100]), 200)
    XCTAssertEqual(try Expression.evaluate("-radius + +2", variables: ["radius": 3]), -1)
    XCTAssertThrowsError(try Expression.evaluate("1/0", variables: [:]))
    XCTAssertThrowsError(try Expression.evaluate("unknown+2", variables: [:]))
    XCTAssertThrowsError(try Expression.evaluate("system('touch /tmp/no')", variables: [:]))
    XCTAssertThrowsError(try Expression.evaluate("1 + (2", variables: [:]))
  }
  func testInvalidEditDoesNotChangeProjectOrUndoHistory() throws {
    let lamp = try addLamp()
    let before = engine.project!
    let undoCount = engine.undoStack.count
    XCTAssertThrowsError(
      try engine.call(
        "form_update_object",
        arguments: ["object_id": lamp.id.uuidString, "parameters": ["height": -10]]))
    XCTAssertEqual(engine.project, before)
    XCTAssertEqual(engine.undoStack.count, undoCount)
    XCTAssertThrowsError(
      try engine.call(
        "form_update_object",
        arguments: ["object_id": lamp.id.uuidString, "parameters": ["madeUp": 10]]))
    XCTAssertThrowsError(
      try engine.call(
        "form_add_object", arguments: ["recipe_id": "lamp", "parameters": ["height": true]]))
  }
  func testVariantsShareGeometryAndIterationsAreIndependent() throws {
    let original = try addLamp()
    _ = try engine.call(
      "form_duplicate_object",
      arguments: ["object_id": original.id.uuidString, "mode": "variant", "material_id": "sage"])
    let variant = engine.project!.objects.last!
    _ = try engine.call(
      "form_duplicate_object",
      arguments: ["object_id": original.id.uuidString, "mode": "iteration"])
    let iteration = engine.project!.objects.last!
    _ = try engine.call(
      "form_update_object",
      arguments: ["object_id": variant.id.uuidString, "parameters": ["height": 420]])
    XCTAssertEqual(engine.project!.objects.first { $0.id == original.id }!["height"], 420)
    XCTAssertEqual(engine.project!.objects.first { $0.id == iteration.id }!["height"], 350)
    XCTAssertEqual(original.designID, variant.designID)
    XCTAssertNotEqual(original.designID, iteration.designID)
    XCTAssertEqual(variant.materialID, "sage")
    XCTAssertNotEqual(
      variant.position, iteration.position,
      "New versions must be placed beside existing versions without overlap")
  }
  func testBatchRollsBackAllChangesOnFailure() throws {
    let before = engine.project!
    let count = engine.undoStack.count
    XCTAssertThrowsError(
      try engine.call(
        "form_batch",
        arguments: [
          "operations": [
            ["name": "form_add_object", "arguments": ["recipe_id": "lamp"]],
            ["name": "form_add_object", "arguments": ["recipe_id": "doesNotExist"]],
          ]
        ]))
    XCTAssertEqual(engine.project, before)
    XCTAssertEqual(engine.undoStack.count, count)
  }
  func testBatchIsASingleUndoStepAndRedoWorks() throws {
    _ = try engine.call(
      "form_batch",
      arguments: [
        "operations": [
          ["name": "form_add_object", "arguments": ["recipe_id": "lamp"]],
          ["name": "form_add_object", "arguments": ["recipe_id": "vase"]],
        ]
      ])
    XCTAssertEqual(engine.project!.objects.count, 2)
    XCTAssertEqual(engine.undoStack.count, 1)
    engine.undo()
    XCTAssertEqual(engine.project!.objects.count, 0)
    engine.redo()
    XCTAssertEqual(engine.project!.objects.count, 2)
  }
  func testPackageRoundTripAndImmutableObjectRevisions() throws {
    let lamp = try addLamp()
    try engine.flush()
    let loaded = try repository.load(engine.project!.id)
    XCTAssertEqual(loaded.objects, engine.project!.objects)
    XCTAssertEqual(loaded.name, "Test study")
    let folder = repository.url(for: loaded.id).appendingPathComponent("Objects")
    let originalFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    try engine.flush()
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), originalFiles)
    _ = try engine.call(
      "form_update_object",
      arguments: ["object_id": lamp.id.uuidString, "parameters": ["height": 500]])
    try engine.flush()
    XCTAssertEqual(try repository.load(loaded.id).objects[0]["height"], 500)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
  }
  func testCustomParametricRecipeAndValidation() throws {
    let definition: [String: Any] = [
      "id": "stool", "name": "Stool",
      "parameters": [
        ["id": "height", "name": "Height", "value": 450.0, "minimum": 200.0, "maximum": 800.0],
        ["id": "width", "name": "Seat width", "value": 300.0, "minimum": 100.0, "maximum": 600.0],
      ],
      "parts": [
        [
          "kind": "box",
          "values": ["width": "width", "height": "20", "depth": "width", "y": "height-10"],
        ],
        [
          "kind": "cylinder",
          "values": [
            "radius": "15", "height": "height-20", "x": "width/2-20", "y": "(height-20)/2",
          ],
        ],
      ],
    ]
    _ = try engine.call("form_create_recipe", arguments: ["recipe": definition])
    _ = try engine.call(
      "form_add_object", arguments: ["recipe_id": "stool", "parameters": ["height": 500]])
    XCTAssertEqual(engine.project!.objects.last!["height"], 500)
    XCTAssertEqual(
      try engine.project!.recipes[0].parts[0].evaluate(["height": 500, "width": 300])["y"], 490)
    XCTAssertThrowsError(try engine.call("form_create_recipe", arguments: ["recipe": definition]))
    var bad = definition
    bad["id"] = "bad"
    bad["parts"] = [["kind": "box", "values": ["height": "-1"]]]
    XCTAssertThrowsError(try engine.call("form_create_recipe", arguments: ["recipe": bad]))
  }
  func testMalformedBuiltInRecipeAndNegativeTorusAreRejected() throws {
    let parameter: [String: Any] = [
      "id": "size", "name": "Size", "value": 100, "minimum": 10, "maximum": 500,
    ]
    let part: [String: Any] = [
      "kind": "box", "values": ["width": "size", "height": "size", "depth": "size"],
    ]
    XCTAssertThrowsError(
      try decodeRecipe([
        "id": "lamp", "name": "Malformed lamp", "parameters": [parameter], "parts": [part],
      ]))
    XCTAssertThrowsError(
      try decodeRecipe([
        "id": "badTorus", "name": "Invalid torus", "parameters": [parameter],
        "parts": [["kind": "torus", "values": ["ringRadius": "size", "pipeRadius": "-2"]]],
      ]))
  }
  func testReferencesAndAssetPathTraversal() throws {
    let fakeImage = root.appendingPathComponent("reference.png")
    try Data([1, 2, 3]).write(to: fakeImage)
    let name = try repository.importAsset(fakeImage, into: engine.project!.id)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: try repository.assetURL(name, in: engine.project!.id).path))
    XCTAssertThrowsError(try repository.assetURL("../../secret", in: engine.project!.id))
  }
  func testArtworkValidationAndLinkedArtwork() throws {
    let lamp = try addLamp()
    var art = Artwork.cyanotype
    art.elements[0].width = -5
    XCTAssertThrowsError(try validateArtwork(art))
    art = .cyanotype
    _ = try engine.call(
      "form_set_artwork",
      arguments: ["object_id": lamp.id.uuidString, "artwork": try jsonObject(art)])
    XCTAssertEqual(engine.project!.objects[0].artwork, art)
    XCTAssertThrowsError(try validateColor("red; background:url(...)"))
  }
  func testMCPDiscoveryErrorsAndNotificationFraming() throws {
    func response(_ source: String) -> [String: Any]? {
      MCP.respond(to: Data(source.utf8), invoke: { try self.engine.call($0, arguments: $1) })
    }
    let initialize = response(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\"}}"
    )!
    XCTAssertEqual(
      (initialize["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
    XCTAssertNil(response("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"))
    let listing = response("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")!
    XCTAssertEqual(((listing["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count, 39)
    XCTAssertEqual((response("{")?["error"] as? [String: Any])?["code"] as? Int, -32700)
    XCTAssertEqual(
      (response("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"unknown\"}")?["error"] as? [String: Any])?[
        "code"] as? Int, -32601)
    let badTool = response(
      "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"form_add_object\",\"arguments\":{\"recipe_id\":\"unknown\"}}}"
    )!
    XCTAssertEqual((badTool["result"] as? [String: Any])?["isError"] as? Bool, true)
  }
  func testLocalSocketRoundTripAndPermissions() throws {
    let path = "/tmp/form-test-" + UUID().uuidString + ".sock"
    let server = LocalBridgeServer(path: path)
    defer { server.stop() }
    try server.start { name, args, completion in completion(.success(["tool": name, "echo": args]))
    }
    let result =
      try LocalBridgeClient.call("form_status", arguments: ["test": 42], socketPath: path)
      as! [String: Any]
    XCTAssertEqual(result["tool"] as? String, "form_status")
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }
  func testManyObjectEditsStayLocal() throws {
    for i in 0..<300 {
      _ = try engine.call("form_add_object", arguments: ["recipe_id": "box", "name": "Box \(i)"])
    }
    let object = engine.project!.objects[150]
    let start = Date()
    for i in 0..<100 {
      _ = try engine.call(
        "form_update_object",
        arguments: ["object_id": object.id.uuidString, "parameters": ["height": Double(100 + i)]],
        source: "Studio")
    }
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(elapsed, 2, "100 edits among 300 objects should remain responsive")
    XCTAssertEqual(engine.project!.objects[149]["height"], 100)
    XCTAssertEqual(engine.project!.objects[150]["height"], 199)
  }
}

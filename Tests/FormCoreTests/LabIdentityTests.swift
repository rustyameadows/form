import XCTest
@testable import FormCore

final class LabIdentityTests:XCTestCase {
  func testPrimaryAndLegacyEnvironmentOverridesDoNotForkExistingStorage() {
    XCTAssertEqual(LabIdentity.libraryOverride(["LAB_LIBRARY_PATH":"/tmp/lab","FORM_LIBRARY_PATH":"/tmp/form"]),"/tmp/lab")
    XCTAssertEqual(LabIdentity.libraryOverride(["LAB_LIBRARY_PATH":"","FORM_LIBRARY_PATH":"/tmp/form"]),"/tmp/form")
    XCTAssertEqual(LabIdentity.libraryOverride(["FORM_LIBRARY_PATH":"/tmp/form"]),"/tmp/form")
    XCTAssertNil(LabIdentity.libraryOverride([:]))
    XCTAssertEqual(LabIdentity.socketOverride(["LAB_SOCKET_PATH":"/tmp/new.sock","FORM_SOCKET_PATH":"/tmp/old.sock"]),"/tmp/new.sock")
    XCTAssertEqual(LabIdentity.socketOverride(["FORM_SOCKET_PATH":"/tmp/old.sock"]),"/tmp/old.sock")
    XCTAssertEqual(LabIdentity.libraryDirectory,"FORM");XCTAssertEqual(LabIdentity.projectExtension,"form")
    XCTAssertEqual(LabIdentity.bundleIdentifier,"studio.form.mac");XCTAssertEqual(LabIdentity.projectTypeIdentifier,"studio.form.project")
  }
  func testMCPAdvertisesLabAndRetainsEstablishedToolIdentifiers()throws {
    let request=try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":MCP.protocolVersion]])
    let response=try XCTUnwrap(MCP.respond(to:request,invoke:{_,_ in [:]})),result=try XCTUnwrap(response["result"] as? [String:Any]),server=try XCTUnwrap(result["serverInfo"] as? [String:String])
    XCTAssertEqual(server["name"],"lab");XCTAssertEqual(server["version"],LabIdentity.version)
    XCTAssertTrue(MCP.toolNames.contains("form_status"));XCTAssertTrue(MCP.toolNames.contains("form_get_project"))
    XCTAssertTrue(MCP.toolNames.isSuperset(of: ["form_status", "form_get_project", "form_set_view"]))
    XCTAssertEqual(MCP.toolNames.count, MCP.tools.count, "Tool identifiers must remain unique as capabilities grow.")
  }
  @MainActor func testLegacyStatusCallReadsExistingProjectWithoutMutation()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root),engine=OperationEngine(repository:repository)
    var project=Project(name:"Existing FORM project");var clock=try project.makeObject(recipeID:"deskClock");clock.artwork=Artwork(elements:[.init(kind:"text",x:0,y:0,text:"FORM remains user artwork")]);project.objects=[clock];try repository.save(project);engine.project=try repository.load(project.id);let before=engine.project
    let status=try XCTUnwrap(engine.call("form_status") as? [String:Any]);XCTAssertEqual(status["application"] as? String,"LAB");XCTAssertEqual(status["project_name"] as? String,project.name);XCTAssertEqual(engine.project,before);XCTAssertTrue(engine.undoStack.isEmpty)
  }
}

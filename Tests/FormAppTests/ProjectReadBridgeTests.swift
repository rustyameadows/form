import AppKit
import Darwin
import XCTest
@testable import FormApp
@testable import FormCore

@MainActor final class ProjectReadBridgeTests:XCTestCase {
  func testInvalidOpenAndReadProjectionsDoNotCommitPendingNativeFields()async throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("project-read-bridge-"+UUID().uuidString)
    let socket="/tmp/lab-read-"+UUID().uuidString+".sock"
    let priorLAB=ProcessInfo.processInfo.environment["LAB_SOCKET_PATH"],priorFORM=ProcessInfo.processInfo.environment["FORM_SOCKET_PATH"]
    setenv("LAB_SOCKET_PATH",socket,1);setenv("FORM_SOCKET_PATH",socket,1)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    if let priorLAB {setenv("LAB_SOCKET_PATH",priorLAB,1)}else{unsetenv("LAB_SOCKET_PATH")}
    if let priorFORM {setenv("FORM_SOCKET_PATH",priorFORM,1)}else{unsetenv("FORM_SOCKET_PATH")}
    defer{store.bridge.stop();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    var current=Project(name:"Current edit"),target=Project(name:"Target")
    current.objects=[try current.makeObject(recipeID:"box",name:"Original field")]
    target.objects=[try target.makeObject(recipeID:"box",name:"Target surface")]
    try store.repository.save(current);try store.repository.save(target)
    store.engine.project=current;store.engine.selection=[current.objects[0].id];store.showingHome=false
    var commits=0
    let observer=NotificationCenter.default.addObserver(forName:.formCommitArtworkFields,object:nil,queue:.main){_ in
      commits+=1
      try? store.engine.edit("Committed pending field"){$0.objects[0].name="Pending edited value"}
    }
    defer{NotificationCenter.default.removeObserver(observer)}
    store.startBridge();XCTAssertTrue(store.bridgeReady)
    let sourceBefore=store.engine.project,selection=store.engine.selection,undo=store.engine.undoStack
    let bytes=try Data(contentsOf:store.repository.url(for:current.id).appendingPathComponent("Manifest.json"))
    // The observer models the same deferred field commit used by native editors;
    // it would mutate the source/Undo if the bridge called finishArtworkEditing.
    let invalid=Task.detached { ()->String? in
      do {_=try LocalBridgeClient.call("form_open_project",arguments:["project_id":target.id.uuidString,"view":"scoped","sections":["objects"],"object_ids":[current.objects[0].id.uuidString]],socketPath:socket);return nil}
      catch{return error.localizedDescription}
    }
    let message=await invalid.value;XCTAssertTrue(message?.contains("absent") == true)
    XCTAssertEqual(commits,0);XCTAssertTrue(store.engine.project==sourceBefore);XCTAssertTrue(store.engine.undoStack==undo)
    XCTAssertEqual(store.engine.selection,selection)
    XCTAssertEqual(try Data(contentsOf:store.repository.url(for:current.id).appendingPathComponent("Manifest.json")),bytes)
    let summary=try await Task.detached {try LocalBridgeClient.call("form_get_project",arguments:["view":"summary"],socketPath:socket) as? [String:Any] ?? [:]}.value
    XCTAssertEqual((summary["project"] as? [String:Any])?["id"] as? String,current.id.uuidString)
    XCTAssertEqual(commits,0);XCTAssertTrue(store.engine.project==sourceBefore);XCTAssertTrue(store.engine.undoStack==undo)
    // A real successful open still follows the normal commit and workspace path.
    let opened=try await Task.detached {try LocalBridgeClient.call("form_open_project",arguments:["project_id":target.id.uuidString,"view":"summary"],socketPath:socket) as? [String:Any] ?? [:]}.value
    XCTAssertEqual((opened["project"] as? [String:Any])?["id"] as? String,target.id.uuidString)
    XCTAssertEqual(store.engine.project?.id,target.id);XCTAssertGreaterThan(commits,0)
  }
}

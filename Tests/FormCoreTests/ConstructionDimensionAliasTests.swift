import Foundation
import XCTest
import FormCADModel
@testable import FormCore

@MainActor final class ConstructionDimensionAliasTests:XCTestCase {
  private func fixture()throws->(OperationEngine,UUID,UUID) {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("construction-alias-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:folder)}
    let engine=OperationEngine(repository:try .init(root:folder));engine.project=Project(name:"Independent cut dimensions")
    var definition=ConstructionCommands.example()
    definition.derived=["finishedSpan":"width+20","patternSpan":"finishedSpan+12"]
    let response=try XCTUnwrap(engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(definition)]) as? [String:Any])
    let owner=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(response["object_id"] as? String)))
    let created=try XCTUnwrap(engine.call("form_add_object",arguments:["recipe_id":"artboard","name":"Independent pattern source","parameters":["width":132,"depth":150]]) as? [String:Any])
    let art=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(created["id"] as? String)))
    return(engine,owner,art)
  }
  private func binding(_ owner:UUID,key:String)->PhysicalDimensionBinding {
    .init(parameter:"width",expression:"span",inputs:["span":.init(sourceObjectID:owner,measurement:.parameter,parameter:key)])
  }
  func testAuthoredDimensionUpdatesCanonicalPatternWithoutDuplicatingFormulaAndPersistsUndo()throws {
    let(e,owner,art)=try fixture()
    _ = try e.call("form_update_object",arguments:["object_id":art.uuidString,"dimension_bindings":try jsonObject([binding(owner,key:"patternSpan")])])
    let before=try XCTUnwrap(e.project)
    _ = try e.call("form_construction",arguments:["command":"parameter","object_id":owner.uuidString,"values":["width":160]])
    XCTAssertEqual(e.project?.objects.first{$0.id==art}?.parameters["width"],192)
    try e.flush();let reloaded=try e.repository.load(before.id)
    XCTAssertEqual(reloaded.objects,e.project?.objects)
    e.undo();XCTAssertEqual(e.project?.objects,before.objects)
    e.redo();XCTAssertEqual(e.project?.objects.first{$0.id==art}?.parameters["width"],192)
  }
  func testMissingAliasAndDeletingAnInUseAliasRejectAtomically()throws {
    let(e,owner,art)=try fixture();let before=e.project,count=e.undoStack.count
    XCTAssertThrowsError(try e.call("form_update_object",arguments:["object_id":art.uuidString,"dimension_bindings":try jsonObject([binding(owner,key:"notDeclared")])]))
    XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,count)
    _ = try e.call("form_update_object",arguments:["object_id":art.uuidString,"dimension_bindings":try jsonObject([binding(owner,key:"patternSpan")])])
    let accepted=e.project,undo=e.undoStack.count
    var changed=try XCTUnwrap(e.project?.objects.first{$0.id==owner}?.paperConstruction?.authored)
    changed.derived=nil
    XCTAssertThrowsError(try e.call("form_construction",arguments:["command":"configure","object_id":owner.uuidString,"definition":try jsonObject(changed)]))
    XCTAssertEqual(e.project,accepted);XCTAssertEqual(e.undoStack.count,undo)
  }
}

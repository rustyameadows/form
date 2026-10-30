import Foundation
import XCTest
@testable import FormCore

final class PaperFinishVisibilityTests:XCTestCase {
  private func fixture(_ artwork:Artwork)throws->OperationEngine {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("paper-finish-visibility-"+UUID().uuidString)
    let engine=OperationEngine(repository:try ProjectRepository(root:directory))
    addTeardownBlock{try? FileManager.default.removeItem(at:directory)}
    var project=Project(name:"Visible finish masks"),paper=try project.makeObject(recipeID:"paperEnvelope")
    paper.artwork=artwork;project.objects=[paper];engine.project=project;return engine
  }
  @discardableResult private func call(_ engine:OperationEngine,_ command:String,_ input:[String:Any]=[:])throws->Any {
    var args=input;args["command"]=command;args["object_id"]=engine.project!.objects[0].id.uuidString
    return try engine.call("form_paper",arguments:args)
  }
  func testNewAssignmentsAndWholeConfigurationRejectInvisibleAndTechnicalMasksAtomically()throws {
    var technicalGroup=ArtworkElement(kind:"group",x:0,y:0,width:30,height:30);technicalGroup.productionRole="guide"
    var inherited=ArtworkElement(kind:"rectangle",x:1,y:1,width:5,height:5);inherited.parentID=technicalGroup.id
    var hidden=ArtworkElement(kind:"ellipse",x:40,y:10,width:5,height:5);hidden.hidden=true
    var transparent=ArtworkElement(kind:"rectangle",x:50,y:10,width:5,height:5);transparent.opacity=0
    var unpainted=ArtworkElement(kind:"rectangle",x:60,y:10,width:5,height:5);unpainted.fillEnabled=false
    let emptyText=ArtworkElement(kind:"text",x:70,y:10,width:20,height:10,text:" ")
    let engine=try fixture(.init(elements:[technicalGroup,inherited,hidden,transparent,unpainted,emptyText]))
    let before=engine.project!,undo=engine.undoStack.count
    for id in [technicalGroup.id,inherited.id,hidden.id,transparent.id,unpainted.id,emptyText.id] {
      XCTAssertThrowsError(try call(engine,"set_finish",["finish":["kind":"foil","elementIDs":[id.uuidString]]]))
      XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,undo)
    }
    var definition=try PaperConstruction.definition(for:before.objects[0])
    definition.finishes=[.init(name:"Invisible guide",kind:.foil,elementIDs:[inherited.id])]
    XCTAssertThrowsError(try call(engine,"configure",["definition":try jsonObject(definition)]))
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,undo)
  }
  func testMixedGroupRequiresVisiblePrintContentForEachExplicitTarget()throws {
    let group=ArtworkElement(kind:"group",x:0,y:0,width:50,height:30)
    var printMark=ArtworkElement(kind:"rectangle",x:2,y:2,width:8,height:8);printMark.parentID=group.id
    var guide=ArtworkElement(kind:"rectangle",x:15,y:2,width:8,height:8);guide.parentID=group.id;guide.productionRole="guide"
    let artwork=Artwork(elements:[group,printMark,guide]),engine=try fixture(artwork)
    let visible=try PaperAppearance.visiblePrintTargetIDs(artwork:artwork,project:engine.project!)
    XCTAssertTrue(visible.contains(group.id));XCTAssertTrue(visible.contains(printMark.id));XCTAssertFalse(visible.contains(guide.id))
    _ = try call(engine,"set_finish",["finish":["kind":"emboss","elementIDs":[group.id.uuidString],"heightMM":0.05]])
    XCTAssertEqual(engine.project!.objects[0].artwork,artwork)
    let accepted=engine.project!,undo=engine.undoStack.count
    XCTAssertThrowsError(try call(engine,"set_finish",["finish":["kind":"foil","elementIDs":[group.id.uuidString,guide.id.uuidString]]]))
    XCTAssertEqual(engine.project,accepted);XCTAssertEqual(engine.undoStack.count,undo)
  }
  func testLaterVisibilityOrSourceRemovalRemainsRepairableAndReportsNoMask()throws {
    let mark=ArtworkElement(kind:"rectangle",x:20,y:20,width:20,height:20)
    let engine=try fixture(.init(elements:[mark])),objectID=engine.project!.objects[0].id
    _ = try call(engine,"set_finish",["finish":["kind":"foil","elementIDs":[mark.id.uuidString]]])
    let assignment=try XCTUnwrap(engine.project!.objects[0].paperConstruction?.finishes?.first)
    try engine.edit("Moved source to guide"){project in var art=project.objects[0].artwork!;art.elements[0].productionRole="guide";try project.setArtwork(art,for:objectID)}
    let inspection=try PaperAppearance.inspect(project:engine.project!,object:engine.project!.objects[0])
    XCTAssertTrue(inspection.issues.contains{$0.code=="invisibleFinishTargets" && $0.finishID==assignment.id})
    XCTAssertEqual(inspection.finishes[0].assignment,assignment)
    _ = try call(engine,"configure",["stock":["profile":["roughness":0.82]]])
    XCTAssertEqual(engine.project!.objects[0].artwork!.elements[0].productionRole,"guide")
    let retained=engine.project!,undo=engine.undoStack.count
    XCTAssertThrowsError(try call(engine,"set_finish",["finish":["id":assignment.id.uuidString,"name":"Still invisible"]]))
    XCTAssertEqual(engine.project,retained);XCTAssertEqual(engine.undoStack.count,undo)
    _ = try call(engine,"set_finish",["finish":["id":assignment.id.uuidString,"enabled":false]])
    try engine.edit("Removed source target"){project in var art=project.objects[0].artwork!;art.elements=[];try project.setArtwork(art,for:objectID)}
    _ = try call(engine,"set_finish",["finish":["id":assignment.id.uuidString,"enabled":false]])
    XCTAssertThrowsError(try call(engine,"set_finish",["finish":["id":assignment.id.uuidString,"enabled":true]]))
    _ = try call(engine,"remove_finish",["finish_id":assignment.id.uuidString])
    XCTAssertNil(engine.project!.objects[0].paperConstruction?.finishes)
  }
}

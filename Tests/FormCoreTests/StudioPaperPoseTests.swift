import Foundation
import XCTest
import FormCADModel
@testable import FormCore

final class StudioPaperPoseTests:XCTestCase {
  private func fixture()throws->(Project,ProductObject) {
    var d=PlanarConstructionDefinition(name:"Grouped display panels",size:.init(140,80),stockThickness:0.35,
      panels:[.init(id:"a",name:"First cut piece",polygon:[.init(0,0),.init(60,0),.init(60,80),.init(0,80)]),
        .init(id:"b",name:"Second cut piece",polygon:[.init(70,0),.init(130,0),.init(130,80),.init(70,80)])],rootPanelID:"a",components:[
        .init(id:"a",name:"First cut piece",rootPanelID:"a",anchor:.init(0,80)),
        .init(id:"b",name:"Second cut piece",rootPanelID:"b",anchor:.init(70,80),position:.init(70,0,0))])
    d.version=4;d.groups=[.init(id:"moving",name:"Movable parent",position:.init("explosion", "opening*0.4",0))]
    d.components![0].groupID="moving";d.components![1].groupID="moving"
    let recipe=ConstructionSourceEditing.recipe(d,id:"source-panels")
    var source=ProductObject(name:d.name,recipeID:recipe.id,parameters:recipe.defaults)
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:140,height:80,depth:0.35),stock:.init(thicknessMM:0.35))
    paper.authored=d;source.paperConstruction=paper
    var project=Project(name:"Independent planar poses");project.objects=[source];project.recipes=[recipe]
    return(project,source)
  }
  func testTwoCopiesHaveIndependentOpeningAndExplodedPosesWithoutEditingTheirSource()throws {
    let(project,source)=try fixture(),before=project
    var a=StudioInstance(name:"Closed",sourceObjectID:source.id),b=StudioInstance(name:"Raised",sourceObjectID:source.id)
    a.paperPose = .init(openingPercent:0,explosionPercent:0);b.paperPose = .init(openingPercent:50,explosionPercent:20)
    var scene=StudioComposition(name:"Independent copies",camera:.init());scene.instances=[a,b]
    let resolved=try scene.resolved(in:project)
    let first=try XCTUnwrap(resolved.project.objects.first{$0.id==a.id}),second=try XCTUnwrap(resolved.project.objects.first{$0.id==b.id})
    let x=try PaperConstruction.definition(for:first),y=try PaperConstruction.definition(for:second)
    XCTAssertEqual(x.authored,y.authored);XCTAssertEqual(x.stock,y.stock)
    XCTAssertEqual(x.openingPercent,0);XCTAssertEqual(y.openingPercent,50);XCTAssertEqual(y.explosionPercent,20)
    XCTAssertEqual(try x.net(),try y.net(),"Presentation must not edit cut contours or material quantities.")
    let xp=try x.resolvedPanels(),yp=try y.resolvedPanels()
    for index in xp.indices {
      XCTAssertEqual(yp[index].flatToWorld[3]-xp[index].flatToWorld[3],20,accuracy:1e-9)
      XCTAssertEqual(yp[index].flatToWorld[7]-xp[index].flatToWorld[7],20,accuracy:1e-9)
    }
    XCTAssertEqual(project,before)
  }
  func testInvalidPoseAndWrongSourceRejectWithoutMutatingAcceptedScene()throws {
    let(project,source)=try fixture()
    XCTAssertThrowsError(try StudioPaperPose(openingPercent:101).applying(to:source))
    XCTAssertThrowsError(try StudioPaperPose(explosionPercent:Double.nan).applying(to:source))
    var unrelated=source;unrelated.paperConstruction=nil
    XCTAssertThrowsError(try StudioPaperPose(openingPercent:10).applying(to:unrelated))
    var instance=StudioInstance(name:"Conflicting pose types",sourceObjectID:source.id)
    instance.paperPose = .init(openingPercent:10);instance.sheetPose = .init(openingDegrees:30)
    XCTAssertThrowsError(try instance.validate())
    XCTAssertEqual(project.objects.first,source)
  }
  func testPosePersistenceAndNilFieldCompatibility()throws {
    let(project,source)=try fixture()
    var instance=StudioInstance(name:"Independent pose",sourceObjectID:source.id)
    let original=try jsonObject(instance) as? [String:Any]
    XCTAssertNil(original?["paperPose"])
    instance.paperPose = .init(openingPercent:42,explosionPercent:13)
    let data=try JSONEncoder.form.encode(instance)
    XCTAssertEqual(try JSONDecoder.form.decode(StudioInstance.self,from:data),instance)
    var p=project,scene=StudioComposition(name:"Saved",camera:.init());scene.instances=[instance]
    p.studioPresentation = .init();p.studioPresentation?.scenes=[scene]
    XCTAssertEqual(p.minimumSchemaVersion,66)
  }
}

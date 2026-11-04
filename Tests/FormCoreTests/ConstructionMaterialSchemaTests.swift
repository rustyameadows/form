import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class ConstructionMaterialSchemaTests:XCTestCase {
  private func project(component:PlanarComponentDefinition?=nil)->Project {
    let panels=[PlanarPanelDefinition(id:"active",name:"Active panel",polygon:[.init(0,0),.init(40,0),.init(40,60),.init(0,60)]),
      PlanarPanelDefinition(id:"optional",name:"Optional panel",polygon:[.init(50,0),.init(90,0),.init(90,60),.init(50,60)])]
    var definition=PlanarConstructionDefinition(name:"Independent pieces",size:.init(100,60),stockThickness:0.5,
      panels:panels,rootPanelID:"active",components:[.init(id:"active",name:"Active piece",rootPanelID:"active",anchor:.init(0,0)),
        component ?? disabledComponent()])
    definition.version=4
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:100,height:60,depth:0.5),stock:.init(thicknessMM:0.5))
    paper.authored=definition
    var object=ProductObject(name:"Construction source",recipeID:"box",parameters:["width":100,"height":60,"depth":0.5])
    object.paperConstruction=paper
    var result=Project(name:"Construction and optical schema")
    result.objects=[object]
    result.createdAt=Date(timeIntervalSince1970:1_700_000_000);result.updatedAt=result.createdAt
    return result
  }
  private func disabledComponent()->PlanarComponentDefinition {
    .init(id:"optional",name:"Retained optional piece",rootPanelID:"optional",anchor:.init(50,0),enabled:0)
  }
  private func stock(edge:Bool,ply:Bool=false)->PaperStock {
    var profile=PaperSurfaceProfile(),appearance=PhysicalAppearance()
    appearance.ior=1.6;appearance.normalStrength=0.4
    if edge {profile.edgeAppearance=appearance} else {profile.appearance=appearance}
    var stock=PaperStock(thicknessMM:0.5)
    if ply {stock.plies=[.init(name:"Optical ply",color:"#FFFFFF",thicknessMM:0.5,profile:profile)]}
    else {stock.profile=profile}
    return stock
  }
  func testDisabledComponentsAndFinishesRetainEveryOpticalSchemaContribution()throws {
    var physicalFinish=PaperFinishAssignment(name:"Retained optical finish",kind:.foil,elementIDs:[],enabled:false)
    physicalFinish.appearance=PhysicalAppearance()
    var shoulder=PaperFinishAssignment(name:"Retained shoulder",kind:.emboss,elementIDs:[],enabled:false)
    shoulder.shoulderRadiusMM=0 // Explicit sharp is authored, unlike nil.
    let cases:[(String,PaperStock?,[PaperFinishAssignment]?,Int)]=[
      ("piece face",stock(edge:false),nil,67),
      ("piece ply face",stock(edge:false,ply:true),nil,67),
      ("disabled piece finish",nil,[physicalFinish],67),
      ("piece edge",stock(edge:true),nil,68),
      ("piece ply edge",stock(edge:true,ply:true),nil,68),
      ("disabled piece shoulder",nil,[shoulder],68)]
    for (label,stock,finishes,version) in cases {
      var component=disabledComponent();component.stock=stock;component.finishes=finishes
      let source=project(component:component)
      XCTAssertEqual(source.minimumSchemaVersion,version,label)
      let decoded=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(source))
      XCTAssertEqual(decoded,source,label);XCTAssertEqual(decoded.minimumSchemaVersion,version,label)
      XCTAssertEqual(decoded.objects[0].paperConstruction?.authored?.components?[1].enabled,0,label)
    }
  }
  func testMixedResourcesAndObjectsRespectConstruction66Physical67AndPaper68()throws {
    var value=project()
    var scene=StudioComposition(name:"Independent pose",camera:.init())
    var instance=StudioInstance(name:"Presentation copy",sourceObjectID:value.objects[0].id)
    instance.paperPose = .init(openingPercent:42,explosionPercent:10);scene.instances=[instance]
    value.studioPresentation = .init();value.studioPresentation?.scenes=[scene]
    XCTAssertEqual(value.minimumSchemaVersion,66)
    var material=Material("optics","Optical resource","Paper","#FFFFFF")
    material.appearance=PhysicalAppearance();value.materials=[material]
    XCTAssertEqual(value.minimumSchemaVersion,67)
    var edgeComponent=disabledComponent();edgeComponent.stock=stock(edge:true)
    let edged=project(component:edgeComponent).objects[0]
    value.objects.append(edged);XCTAssertEqual(value.minimumSchemaVersion,68)
    value.objects.reverse();XCTAssertEqual(value.minimumSchemaVersion,68)
    value.objects.removeAll{$0.id==edged.id};XCTAssertEqual(value.minimumSchemaVersion,67)
    value.materials=[];XCTAssertEqual(value.minimumSchemaVersion,66)
    value.renderSettings=CyclesRenderSettings();XCTAssertEqual(value.minimumSchemaVersion,67)
    var edgeResource=material;edgeResource.appearance=nil;edgeResource.paperStock=stock(edge:true,ply:true)
    value.materials=[edgeResource];XCTAssertEqual(value.minimumSchemaVersion,68)
    value.materials=[];value.renderSettings=nil;value.objects=[]
    XCTAssertEqual(value.minimumSchemaVersion,66,"The saved paper pose is a resource contribution even without an object scan.")
    value.studioPresentation=nil;XCTAssertEqual(value.minimumSchemaVersion,1)
    for floor in [66,67,68,69] {
      value.schemaVersion=floor;XCTAssertEqual(value.minimumSchemaVersion,floor)
    }
    XCTAssertEqual(Project.maximumSchemaVersion,68)
  }
  func testEarlierCycles66AndPaper67DecodeAndResaveWithoutLosingSource()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("construction-optical-schema-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root)
    for (oldVersion,withEdges,expectedVersion) in [(66,false,67),(67,false,67),(66,true,68),(67,true,68)] {
      var component=disabledComponent();component.stock=stock(edge:withEdges,ply:true)
      var prior=project(component:component);prior.schemaVersion=oldVersion;prior.renderSettings=CyclesRenderSettings()
      prior.camera.azimuth=0.71;prior.camera.distance=3.4
      if withEdges {
        var finish=PaperFinishAssignment(name:"Retained impression",kind:.letterpress,elementIDs:[],depthMM:0.12)
        finish.shoulderRadiusMM=0.16;prior.objects[0].paperConstruction?.authored?.components?[1].finishes=[finish]
      }
      let decoded=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(prior))
      XCTAssertEqual(decoded,prior);XCTAssertEqual(decoded.schemaVersion,oldVersion)
      XCTAssertEqual(decoded.minimumSchemaVersion,expectedVersion)
      try repository.save(decoded)
      var expected=prior;expected.schemaVersion=expectedVersion
      XCTAssertEqual(try repository.load(prior.id),expected)
      XCTAssertEqual(decoded,prior,"Saving only upgrades persisted schema metadata, not the caller's source.")
    }
  }
}

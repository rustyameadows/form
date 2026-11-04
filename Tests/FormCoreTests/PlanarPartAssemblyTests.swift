import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class PlanarPartAssemblyTests:XCTestCase {
  private func rectangle(_ id:String,_ x:Double,_ y:Double,_ width:Double,_ height:Double)->PlanarPanelDefinition {
    .init(id:id,name:id,polygon:[.init(CADScalar(x),CADScalar(y)),.init(CADScalar(x+width),CADScalar(y)),.init(CADScalar(x+width),CADScalar(y+height)),.init(CADScalar(x),CADScalar(y+height))])
  }
  private func source()->PlanarConstructionDefinition {
    .init(name:"Independent material assembly",parameters:[.init("showSecond",1,0...1,unit:""),.init("caliper",2,0.5...5,unit:"mm")],size:.init(100,50),stockThickness:2,
      panels:[rectangle("first",0,0,20,20),rectangle("second",30,0,20,20)],rootPanelID:"first",components:[
        .init(id:"first-piece",name:"First piece",rootPanelID:"first",anchor:.init(0,0),position:.init(0,1,0),rotationDegrees:.init(-90,0,0),groupID:"moving",stockThickness:"caliper"),
        .init(id:"second-piece",name:"Second piece",rootPanelID:"second",anchor:.init(30,0),position:.init(30,2,0),rotationDegrees:.init(-90,0,0),groupID:"moving",stock:.init(name:"Independent blue stock",thicknessMM:0.5,profile:.init(texture:.linen,color:"#244556")),enabled:"showSecond")],groups:[
          .init(id:"moving",name:"Shared rigid frame",position:.init("opening/2","explosion/3",0))])
  }
  func testIndependentPieceStockAndCaliperRetainInheritedPlyAppearance()throws {
    let d=source(),net=try d.net(),fallback=PaperStock(name:"Two physical plies",thicknessMM:2,profile:.init(texture:.laid),plies:[
      .init(name:"Back",color:"#EEEEDD",thicknessMM:0.5),.init(name:"Face",color:"#222222",thicknessMM:1.5,profile:.init(texture:.linen))])
    let first=try XCTUnwrap(net.panels.first{$0.id=="first"}).resolvedStock(fallback:fallback)
    XCTAssertEqual(first.plies?.map(\.name),["Back","Face"]);XCTAssertEqual(first.plies?.map(\.thicknessMM),[0.5,1.5])
    var larger=d;try larger.setParameters(["caliper":4]);let result=try XCTUnwrap(larger.net().panels.first{$0.id=="first"}).resolvedStock(fallback:fallback)
    XCTAssertEqual(result.plies?.map(\.thicknessMM),[1,3]);XCTAssertEqual(result.plies?.last?.profile?.texture,.linen)
    let second=try XCTUnwrap(net.panels.first{$0.id=="second"}).resolvedStock(fallback:fallback)
    XCTAssertEqual(second.name,"Independent blue stock");XCTAssertEqual(second.resolvedThicknessMM,0.5);XCTAssertEqual(second.profile?.color,"#244556")
  }
  func testDisabledPieceRetainsSavedSourceAndOnlyActiveNetChanges()throws {
    let d=source(),before=d.components![1];var off=d;try off.setParameters(["showSecond":0])
    XCTAssertEqual(try off.net().panels.map(\.id),["first"]);XCTAssertEqual(off.components![1],before)
    XCTAssertEqual(try off.componentPanels()["second-piece"],["second"])
    try off.setParameters(["showSecond":1]);XCTAssertEqual(try off.net(),try d.net())
    var invalid=off;try invalid.setParameters(["showSecond":0]);invalid.joins=[.init(id:"explicit",name:"Explicit joint",firstPanelID:"first",secondPanelID:"second",overlapMM:0)]
    XCTAssertThrowsError(try invalid.net())
    invalid.joins[0].enabled=0;XCTAssertEqual(try invalid.net().joins.count,0)
  }
  func testGroupPoseMovesEveryChildWithoutChangingCutGeometryOrRelativePlacement()throws {
    let d=source();var paper=PaperConstruction(kind:.authored,dimensions:.init(width:100,height:50,depth:2),stock:.init(thicknessMM:2));paper.authored=d
    let closed=try paper.resolvedPanels(),net=try paper.net();paper.openingPercent=80;paper.explosionPercent=60
    let open=try paper.resolvedPanels();XCTAssertEqual(try paper.net(),net)
    for id in ["first","second"] {
      let a=try XCTUnwrap(closed.first{$0.panelID==id}),b=try XCTUnwrap(open.first{$0.panelID==id})
      XCTAssertEqual(b.flatToWorld[3]-a.flatToWorld[3],40,accuracy:1e-8)
      XCTAssertEqual(b.flatToWorld[7]-a.flatToWorld[7],20,accuracy:1e-8)
      for i in [0,1,2,4,5,6,8,9,10] {XCTAssertEqual(a.flatToWorld[i],b.flatToWorld[i],accuracy:1e-8)}
    }
    XCTAssertEqual(paper.authored,d)
    var bad=d;bad.groups=[.init(id:"a",name:"A",parentID:"b"),.init(id:"b",name:"B",parentID:"a")]
    XCTAssertThrowsError(try bad.net())
  }
  func testConnectedCutPieceUsesOneCanonicalFaceAtPhysicalCropOffsets()throws {
    let id=UUID(),panels=[rectangle("a",10,10,20,15),rectangle("b",30,10,20,15)]
    let d=PlanarConstructionDefinition(name:"Folded surface source",size:.init(80,50),stockThickness:0.2,panels:panels,
      hinges:[.init(id:"hinge",parentPanelID:"a",childPanelID:"b",start:.init(30,10),end:.init(30,25),angleDegrees:90)],rootPanelID:"a",components:[
        .init(id:"single-cut-piece",name:"Single cut piece",rootPanelID:"a",anchor:.init(10,10),stock:.init(thicknessMM:0.2),front:.init(sourceObjectID:id,sourceOriginMM:.init(5,7)))])
    let net=try d.net();XCTAssertEqual(try d.componentBounds(componentID:"single-cut-piece"),.init(x:10,y:10,width:40,height:15))
    XCTAssertEqual(net.panels[0].front?.originMM,.init(5,7));XCTAssertEqual(net.panels[1].front?.originMM,.init(25,7))
    XCTAssertEqual(net.panels.map(\.componentID),["single-cut-piece","single-cut-piece"])
  }
  func testHistoricalJSONDoesNotAcquireVersionFourFields()throws {
    let d=PlanarConstructionDefinition(name:"Historical separate plate",size:.init(30,30),stockThickness:0.5,panels:[rectangle("plate",0,0,20,20)],rootPanelID:"plate",components:[.init(id:"plate",name:"Plate",rootPanelID:"plate",anchor:.init(0,0))])
    XCTAssertEqual(d.version,3);let data=try JSONEncoder.form.encode(d),raw=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    XCTAssertNil(raw["groups"]);XCTAssertNil(raw["jointAttachments"]);XCTAssertNil(raw["controls"]);XCTAssertNil(raw["production"])
    let decoded=try JSONDecoder().decode(PlanarConstructionDefinition.self,from:data);XCTAssertEqual(decoded,d)
    XCTAssertNil(try decoded.net().panels[0].componentID)
  }
  func testPreparedRequestRetainsDisabledOwnershipAndNeverSharesEditedState()throws {
    let initial=source(),prepared=try PlanarAssemblySourceContext(initial)
    XCTAssertEqual(prepared.ownership["second-piece"],["second"])
    XCTAssertEqual(prepared.bounds["second-piece"],try initial.componentBounds(componentID:"second-piece"))
    XCTAssertEqual(prepared.enabledIDs,["first-piece","second-piece"])
    var changed=initial;try changed.setParameters(["showSecond":0,"caliper":4])
    let next=try PlanarAssemblySourceContext(changed)
    XCTAssertEqual(next.enabledIDs,["first-piece"])
    XCTAssertEqual(next.ownership,prepared.ownership)
    XCTAssertEqual(next.stocks["first-piece"]?.resolvedThicknessMM,4)
    XCTAssertEqual(prepared.stocks["first-piece"]?.resolvedThicknessMM,2)
    XCTAssertEqual(prepared.values["showSecond"],1)
    XCTAssertEqual(next.values["showSecond"],0)
    XCTAssertEqual(next.rawPolygons,prepared.rawPolygons)
  }

  func testPreflightUsesActivePieceStockAndAuthoredAssumptionsWithoutLegacyDuplexCopy()throws {
    var d=source()
    d.components![0].front = .init(sourceObjectID:UUID())
    d.production = .init(assumptions:["Only the declared contact regions are bonded."],processNotes:"Retain physical source registration.")
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:100,height:50,depth:2),
      stock:.init(thicknessMM:2,grain:.parallelWidth,verified:true))
    paper.authored=d;paper.artworkReviewRequired=true
    let result=try paper.preflight()
    XCTAssertEqual(result.issues.first{$0.code=="unverified-stock"}?.panelIDs,["second"])
    XCTAssertEqual(result.issues.first{$0.code=="unknown-grain"}?.panelIDs,["second"])
    XCTAssertTrue(result.issues.contains{$0.code=="canonical-piece-faces"})
    XCTAssertEqual(result.issues.first{$0.code=="source-assumption-1"}?.message,"Only the declared contact regions are bonded.")
    XCTAssertTrue(result.issues.contains{$0.code=="source-production-notes"})
    XCTAssertFalse(result.issues.contains{$0.code=="duplex-proof" || $0.message.contains("scoring")})
    XCTAssertTrue(result.issues.contains{$0.code=="artwork-review"})
    try d.setParameters(["showSecond":0]);paper.authored=d
    let disabled=try paper.preflight()
    XCTAssertFalse(disabled.issues.contains{$0.code=="unverified-stock" || $0.code=="unknown-grain"})
    XCTAssertTrue(disabled.issues.contains{$0.code=="source-assumption-1"})
  }
  func testHistoricalPreflightRetainsSingleNetStockAndDuplexWarnings()throws {
    let d=PlanarConstructionDefinition(name:"Historical separate sheet",size:.init(30,30),stockThickness:0.5,
      panels:[rectangle("plate",0,0,20,20)],rootPanelID:"plate",components:[
        .init(id:"plate",name:"Plate",rootPanelID:"plate",anchor:.init(0,0))])
    XCTAssertEqual(d.version,3)
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:20,height:20,depth:1),stock:.init(thicknessMM:0.5));paper.authored=d
    let result=try paper.preflight()
    XCTAssertEqual(result.issues.first{$0.code=="unverified-stock"}?.message,"Stock caliper, grain, scoring and adhesive remain prototype assumptions; prove the construction on actual material.")
    XCTAssertEqual(result.issues.first{$0.code=="unknown-grain"}?.message,"Declare grain direction before final scoring; grain and fold tooling affect cracking and springback.")
    XCTAssertTrue(result.issues.contains{$0.code=="duplex-proof"})
    XCTAssertFalse(result.issues.contains{$0.code=="independent-cut-pieces" || $0.code=="canonical-piece-faces"})
  }

}

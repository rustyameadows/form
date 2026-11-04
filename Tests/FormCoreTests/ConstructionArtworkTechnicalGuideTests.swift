import Foundation
import XCTest
@testable import FormCore

final class ConstructionArtworkTechnicalGuideTests:XCTestCase {
  private func fixture()throws->(Project,ProductObject,PaperConstruction) {
    let front=UUID(),back=UUID()
    let first=PlanarComponentDefinition(id:"upper-piece",name:"Upper plate",rootPanelID:"upper",anchor:.init(40,20),
      stock:.init(thicknessMM:2),front:.init(sourceObjectID:front,sourceOriginMM:.init(17,23)),
      back:.init(sourceObjectID:back,sourceOriginMM:.init(31,35)))
    let second=PlanarComponentDefinition(id:"lower-piece",name:"Lower plate",rootPanelID:"lower",anchor:.init(180,20),
      position:.init(0,0,-2),stock:.init(thicknessMM:2),front:.init(sourceObjectID:front,sourceOriginMM:.init(17,70)))
    let dormant=PlanarComponentDefinition(id:"dormant-piece",name:"Saved optional material",rootPanelID:"dormant",anchor:.init(300,20),stock:.init(thicknessMM:2),enabled:0)
    let a=PlanarJointSurfaceRegion(polygon:[.init(50,25),.init(100,25),.init(100,45),.init(50,45)],side:.inside)
    let b=PlanarJointSurfaceRegion(polygon:[.init(190,25),.init(240,25),.init(240,45),.init(190,45)])
    let adhesive=PlanarAdhesiveDefinition(identity:"Declared plate adhesive",firstRegion:a,secondRegion:b,
      firstExclusions:[[.init(60,30),.init(65,30),.init(65,35),.init(60,35)]],
      secondExclusions:[[.init(200,30),.init(205,30),.init(205,35),.init(200,35)]])
    let wire=PlanarStapleDefinition(id:"plate-wire",entryPanelID:"upper",receivingPanelID:"lower",anchor:.init(80,40),
      crownWidthMM:8,wireWidthMM:0.4,wireDepthMM:0.4,legLengthMM:3.5,count:2,spacingMM:12,
      minimumReceivingDepthMM:0.75,tool:"Declared plate driver",installation:.init(presentComponentIDs:[first.id,second.id]))
    let production=ConstructionProductionDefinition(guides:[
      .init(id:"seam-registration",componentID:first.id,role:.seam,points:[.init(0,10),.init(80,10)],label:"Seam technical sentinel"),
      .init(id:"turn-registration",componentID:first.id,role:.turnIn,points:[.init(5,0),.init(5,40)]),
      .init(id:"saved-guide",componentID:dormant.id,role:.annotation,points:[.init(5,5),.init(20,5)])])
    let definition=PlanarConstructionDefinition(name:"Two joined display plates",size:.init(350,100),stockThickness:2,panels:[
      .init(id:"upper",name:"Upper plate",polygon:[.init(40,20),.init(120,20),.init(120,60),.init(40,60)],artworkRotationDegrees:90),
      .init(id:"lower",name:"Lower plate",polygon:[.init(180,20),.init(260,20),.init(260,60),.init(180,60)]),
      .init(id:"dormant",name:"Dormant plate",polygon:[.init(300,20),.init(330,20),.init(330,50),.init(300,50)])],
      joins:[.init(id:"plate-joint",name:"Joined plates",firstPanelID:"upper",secondPanelID:"lower",overlapMM:0)],
      rootPanelID:"upper",components:[first,second,dormant],
      jointAttachments:[.init(id:"plate-attachment",joinID:"plate-joint",adhesive:adhesive,staples:[wire])],production:production)
    let starter=ConstructionStarter(id:"display-plates",name:"Joined plates",definition:definition,stock:.init(thicknessMM:2),artworkSources:[
      .init(id:front,name:"Original front ink",width:160,height:120,artwork:.init(elements:[.init(kind:"rectangle",x:20,y:26,width:5,height:7,color:"#123456")])),
      .init(id:back,name:"Original reverse ink",width:160,height:120,artwork:.init())])
    var project=Project(name:"Unrelated generic technical review")
    let result=try project.importConstructionStarter(starter),owner=try XCTUnwrap(project.objects.first{$0.id==result.objectID})
    return(project,owner,try PaperConstruction.definition(for:owner))
  }
  func testSourceGuidesActualAdhesiveExclusionsAndWirePositionsShareCanonicalOwnership()throws {
    let(project,owner,paper)=try fixture(),before=project,net=try paper.net()
    let paths=try ConstructionArtworkTechnicalGuides.resolve(paper,net:net)
    XCTAssertFalse(paths.contains{$0.componentID=="dormant-piece"})
    XCTAssertEqual(try XCTUnwrap(paths.first{$0.id=="guide:seam-registration"}).points,[.init(40,30),.init(120,30)])
    let adhesive=try XCTUnwrap(paths.first{$0.role == .adhesive && $0.componentID=="upper-piece"})
    XCTAssertEqual(adhesive.side,.inside);XCTAssertTrue(adhesive.closed)
    XCTAssertEqual(adhesive.holes,[[.init(60,30),.init(65,30),.init(65,35),.init(60,35)]])
    XCTAssertEqual(paths.filter{$0.role == .glueExclusion}.count,2)
    let crowns=paths.filter{$0.role == .stapleCrown && $0.componentID=="upper-piece"}.sorted{$0.id<$1.id}
    XCTAssertEqual(crowns.count,2)
    XCTAssertEqual(crowns[0].points,[.init(76,40),.init(84,40)])
    XCTAssertEqual(crowns[1].points,[.init(88,40),.init(96,40)])
    XCTAssertEqual(paths.filter{$0.role == .stapleEntry && $0.componentID=="lower-piece"}.count,8)
    XCTAssertFalse(paths.contains{$0.role == .stapleExit},"Buried legs must not invent through holes.")
    XCTAssertEqual(project,before);XCTAssertEqual(project.objects.first{$0.id==owner.id},owner)
  }
  func testFrontReverseAndUprightMarksUseExactInkCropReflectionAndSideFiltering()throws {
    let(project,owner,paper)=try fixture(),net=try paper.net(),paths=try ConstructionArtworkTechnicalGuides.resolve(paper,net:net)
    let front=try ConstructionArtworkProjection.resolve(in:project,object:owner,paper:paper,net:net,componentID:"upper-piece")
    let reverse=try ConstructionArtworkProjection.resolve(in:project,object:owner,paper:paper,net:net,componentID:"upper-piece",inside:true)
    let frontMarks=front.technicalPaths(paths),reverseMarks=reverse.technicalPaths(paths)
    XCTAssertTrue(frontMarks.allSatisfy{$0.componentID=="upper-piece"})
    XCTAssertFalse(frontMarks.contains{$0.role == .adhesive || $0.role == .glueExclusion})
    XCTAssertEqual(frontMarks.filter{$0.role == .stapleCrown}.count,2)
    XCTAssertFalse(reverseMarks.contains{$0.role == .stapleCrown})
    let reverseBond=try XCTUnwrap(reverseMarks.first{$0.role == .adhesive})
    XCTAssertEqual(reverseBond.points.first,.init(70,5),"An independent reverse uses one whole-piece reflection, with the original source crop.")
    let upright=try ConstructionArtworkProjection.resolve(in:project,object:owner,paper:paper,net:net,panelID:"upper")
    let crown=try XCTUnwrap(upright.technicalPaths(paths).first{$0.role == .stapleCrown})
    let expected=frontMarks.first{$0.id==crown.id}!
    for (canonical,local) in zip(paths.first{$0.id==crown.id}!.points,crown.points) {
      XCTAssertEqual(local,upright.frame.sourceToLocal.apply(upright.canonicalToSource.apply(canonical)))
    }
    XCTAssertNotEqual(crown.points,expected.points,"Upright rotation must match the ink rather than silently using pattern axes.")
  }
  func testPresentationDoesNotMoveManufacturingMarksAndClinchCrownUsesActualSixPointPath()throws {
    let(_,_,paper)=try fixture(),paths=try ConstructionArtworkTechnicalGuides.resolve(paper)
    var posed=paper;posed.foldPercent=35;posed.openingPercent=80;posed.explosionPercent=60
    XCTAssertEqual(try ConstructionArtworkTechnicalGuides.resolve(posed),paths)
    var clinched=paper
    clinched.authored!.jointAttachments![0].staples![0].termination = .clinch
    clinched.authored!.jointAttachments![0].staples![0].legLengthMM=7
    clinched.authored!.jointAttachments![0].staples![0].clinchLengthMM=1
    clinched.authored!.jointAttachments![0].staples![0].clincherAccessMM=10
    let through=try ConstructionArtworkTechnicalGuides.resolve(clinched)
    XCTAssertEqual(through.filter{$0.role == .stapleCrown},paths.filter{$0.role == .stapleCrown})
    XCTAssertEqual(through.filter{$0.role == .stapleExit}.count,8)
  }
}

import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class PlanarAttachmentScheduleTests:XCTestCase {
  private func rect(_ id:String,_ x:Double,_ y:Double,_ width:Double,_ height:Double)->PlanarPanelDefinition {
    .init(id:id,name:id,polygon:[.init(CADScalar(x),CADScalar(y)),.init(CADScalar(x+width),CADScalar(y)),.init(CADScalar(x+width),CADScalar(y+height)),.init(CADScalar(x),CADScalar(y+height))])
  }
  private func source(height:Double=20)->PlanarConstructionDefinition {
    .init(name:"Actual attachment schedule",size:.init(400,CADScalar(max(140,height+10))),stockThickness:2,
      panels:[rect("first",0,0,100,100),rect("second",120,0,80,height)],joins:[.init(id:"joint",name:"Receiving edge",firstPanelID:"first",secondPanelID:"second",overlapMM:2)],rootPanelID:"first",components:[
        .init(id:"first-piece",name:"First",rootPanelID:"first",anchor:.init(0,0),position:.init(-50,1,-50),rotationDegrees:.init(-90,0,0),groupID:"frame",stock:.init(thicknessMM:2)),
        .init(id:"second-piece",name:"Second",rootPanelID:"second",anchor:.init(120,CADScalar(height)),position:.init(-40,2,0),groupID:"frame",stock:.init(thicknessMM:2))],groups:[.init(id:"frame",name:"Physical frame",position:.init("opening/2","explosion/3",0))])
  }
  private func fastened(height:Double=20)->PlanarConstructionDefinition {
    var definition=source(height:height)
    definition.jointAttachments=[.init(id:"attachment",joinID:"joint",staples:[.init(id:"wire",entryPanelID:"first",receivingPanelID:"second",anchor:.init(50,50),entrySide:.inside,crownWidthMM:8,wireWidthMM:0.4,wireDepthMM:0.4,legLengthMM:8,spacingMM:12,endMarginMM:1.5,minimumReceivingDepthMM:2,minimumEdgeDistanceMM:0.2,maximumJointGapMM:0.1,tool:"Declared driver",toolAccessMM:17,toolClearanceMM:3,installation:.init(order:4,stage:"Before later surface stock",presentComponentIDs:["first-piece","second-piece"]))])]
    return definition
  }
  func testResolvedWireScheduleRetainsActualFacesAxesAccessAndValidationCriteriaAcrossPoses()throws {
    let definition=fastened(),rest=try definition.resolveJointAttachments(stock:.init(thicknessMM:2)),wire=try XCTUnwrap(rest.staples.first)
    XCTAssertEqual(wire.entrySide,.inside);XCTAssertEqual(wire.sourceAnchorMM,.init(50,50));XCTAssertEqual(wire.instanceAnchorMM,wire.sourceAnchorMM)
    XCTAssertEqual(wire.definitionCount,1);XCTAssertEqual(wire.spacingMM,12)
    XCTAssertEqual(wire.toolAccessMM,17);XCTAssertEqual(wire.toolClearanceMM,3);XCTAssertNil(wire.clincherAccessMM);XCTAssertNil(wire.clinchLengthMM)
    XCTAssertEqual(wire.endMarginMM,1.5);XCTAssertEqual(wire.minimumReceivingDepthMM,2);XCTAssertEqual(wire.minimumEdgeDistanceMM,0.2);XCTAssertEqual(wire.maximumJointGapMM,0.1)
    XCTAssertEqual(wire.receivingEntryBoundaries.count,2);XCTAssertEqual(wire.receivingEntryBoundaries.map(\.surface),[.cutEdge,.cutEdge])
    XCTAssertEqual(wire.receivingEntryBoundaries.map(\.edgeIndex),[2,2]);XCTAssertEqual(wire.receivingThroughExitBoundaries.map(\.edgeIndex),[0,0])
    XCTAssertEqual(wire.termination,.buried);XCTAssertEqual(wire.engagementFrame,"closedInstalledAssembly")
    for axis in [wire.crownDirection,wire.driveDirection,wire.spacingDirection] {XCTAssertEqual(PlanarJointGeometry.length(axis),1,accuracy:1e-9)}
    let posed=try XCTUnwrap(definition.resolveJointAttachments(stock:.init(thicknessMM:2),openingPercent:80,explosionPercent:60).staples.first)
    XCTAssertEqual(posed.crownDirection,wire.crownDirection);XCTAssertEqual(posed.driveDirection,wire.driveDirection)
    for (a,b) in zip(wire.receivingEntryBoundaries,posed.receivingEntryBoundaries) {
      XCTAssertEqual(a.panelPointMM,b.panelPointMM);XCTAssertEqual(b.pointMM.x-a.pointMM.x,40,accuracy:1e-8);XCTAssertEqual(b.pointMM.y-a.pointMM.y,20,accuracy:1e-8)
    }
    XCTAssertEqual(try JSONDecoder.form.decode(ResolvedPlanarAttachments.self,from:JSONEncoder.form.encode(rest)),rest)
  }
  func testShortBuriedLegRecordsActualDistantReceivingExitInsteadOfAnArtificialRayLimit()throws {
    let wire=try XCTUnwrap(fastened(height:500).resolveJointAttachments(stock:.init(thicknessMM:2)).staples.first)
    for (entry,exit) in zip(wire.receivingEntryBoundaries,wire.receivingThroughExitBoundaries) {
      XCTAssertEqual(abs(exit.pointMM.y-entry.pointMM.y),500,accuracy:1e-8)
      XCTAssertEqual(exit.surface,.cutEdge);XCTAssertEqual(exit.edgeIndex,0)
    }
    XCTAssertEqual(wire.termination,.buried);XCTAssertEqual(wire.legLengthMM,8)
  }
  private func taped()->PlanarConstructionDefinition {
    var definition=source();definition.panels += [rect("strip-a",240,0,80,5),rect("strip-b",240,5,80,5)]
    definition.hinges=[.init(id:"strip-bend",parentPanelID:"strip-a",childPanelID:"strip-b",start:.init(240,5),end:.init(320,5),angleDegrees:90)]
    definition.components!.append(.init(id:"strip",name:"Actual strip",rootPanelID:"strip-a",anchor:.init(240,5),position:.init(-40,2.15,1.1),rotationDegrees:.init(90,0,0),groupID:"frame",stock:.init(name:"Actual tape stock",thicknessMM:0.1)))
    let first=PlanarJointSurfaceRegion(polygon:[.init(10.1,51.2),.init(89.9,51.2),.init(89.9,55.9),.init(10.1,55.9)])
    let second=PlanarJointSurfaceRegion(polygon:[.init(120.1,15.2),.init(199.9,15.2),.init(199.9,19.8),.init(120.1,19.8)])
    let bond=PlanarJointSurfaceRegion(polygon:[.init(10,49),.init(90,49),.init(90,51),.init(10,51)])
    let edge=PlanarJointSurfaceRegion(polygon:[.init(0,0),.init(80,0),.init(80,2),.init(0,2)],edgeIndex:2)
    definition.jointAttachments=[.init(id:"tape",joinID:"joint",tape:.init(componentID:"strip",firstRegion:first,secondRegion:second,widthMM:10,lengthMM:80,bondThicknessMM:0.1,installation:.init(order:2,presentComponentIDs:["first-piece","second-piece","strip"]))),.init(id:"glue",joinID:"joint",adhesive:.init(identity:"Declared adhesive",firstRegion:bond,secondRegion:edge))]
    return definition
  }
  func testTapeAndAdhesiveSchedulesResolveActualTargetRegionsEdgesAndEffectiveBond()throws {
    let definition=taped()
    let schedules=try definition.resolveJointAttachments(stock:.init(thicknessMM:2)),tape=try XCTUnwrap(schedules.tapes.first),adhesive=try XCTUnwrap(schedules.adhesives.first)
    XCTAssertEqual(tape.bondThicknessMM,0.1);XCTAssertEqual(tape.lengthAxis,.x);XCTAssertEqual(tape.firstTarget.componentID,"first-piece")
    XCTAssertEqual(tape.secondTarget.panelID,"second");XCTAssertEqual(tape.firstTarget.pointsMM.count,4);XCTAssertEqual(tape.stock.name,"Actual tape stock")
    XCTAssertEqual(adhesive.secondTarget.edgeIndex,2);XCTAssertEqual(adhesive.secondTarget.coordinatesMM,[.init(0,0),.init(80,0),.init(80,2),.init(0,2)])
    XCTAssertEqual(adhesive.firstTarget.coordinatesMM,adhesive.firstRegionMM);XCTAssertEqual(adhesive.secondTarget.coordinatesMM,adhesive.secondRegionMM)
  }
  func testSharedPhysicalTapeStripRetainsAllContactsWithoutDuplicatingCutQuantity()throws {
    var definition=taped(),additionalContact=definition.jointAttachments![0]
    additionalContact.id="second-contact";definition.jointAttachments!.append(additionalContact)
    definition.components![2].quantity=2
    definition.production = .init(materials:[.init(id:"stock",name:"Explicit material formats",componentIDs:["first-piece","second-piece","strip"],widthMM:500,lengthMM:500,grain:.unrestricted)],steps:[
      .init(id:"assemble",title:"Assemble actual pieces",componentIDs:["first-piece","second-piece","strip"],jointIDs:["joint"],instructions:"Cut the declared quantities and bond the shared strip at both retained contact records.")],quantity:3)
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:400,height:140,depth:2),stock:.init(thicknessMM:2));paper.authored=definition
    var object=ProductObject(name:"Shared physical strip",recipeID:"authored-source",parameters:PaperConstructionEngine.parameters(paper));object.paperConstruction=paper
    var project=Project(name:"Physical quantity authority");project.objects=[object]
    let model=try ConstructionPacketModel(project:project,object:object)
    XCTAssertTrue(model.isValid,model.issues.map(\.message).joined(separator:"\n"))
    XCTAssertEqual(model.attachments.tapes.map(\.id),["tape","second-contact"])
    XCTAssertEqual(model.attachments.tapes.map(\.componentID),["strip","strip"])
    XCTAssertEqual(model.pieces.first{$0.id=="strip"}?.quantity,2)
    XCTAssertEqual(model.physicalTapeCutCount,6,"Two source contact records share two actual strips per assembly, across three assemblies; twelve cuts would duplicate the same material.")
    XCTAssertEqual(try model.metadata()["total_tape_cut_count"] as? Int,6)
    XCTAssertEqual(model.layouts.batches.flatMap(\.placements).filter{$0.pieceID=="strip"}.count,6)
  }
}

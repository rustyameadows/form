import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class PlanarBoardJointTests:XCTestCase {
  private func rect(_ id:String,_ x:Double,_ y:Double,_ width:Double,_ height:Double)->PlanarPanelDefinition {
    .init(id:id,name:id,polygon:[.init(CADScalar(x),CADScalar(y)),.init(CADScalar(x+width),CADScalar(y)),.init(CADScalar(x+width),CADScalar(y+height)),.init(CADScalar(x),CADScalar(y+height))])
  }
  private func source()->PlanarConstructionDefinition {
    .init(name:"Orthogonal board engagement",size:.init(400,140),stockThickness:2,
      panels:[rect("floor",0,0,100,100),rect("wall",120,0,80,20)],
      joins:[.init(id:"bond",name:"Floor to receiving edge",firstPanelID:"floor",secondPanelID:"wall",overlapMM:2)],rootPanelID:"floor",components:[
        .init(id:"floor-piece",name:"Floor",rootPanelID:"floor",anchor:.init(0,0),position:.init(-50,1,-50),rotationDegrees:.init(-90,0,0),groupID:"assembly",stock:.init(thicknessMM:2)),
        .init(id:"wall-piece",name:"Wall",rootPanelID:"wall",anchor:.init(120,20),position:.init(-40,2,0),groupID:"assembly",stock:.init(thicknessMM:2))],groups:[.init(id:"assembly",name:"Connected material",position:.init("opening/2","explosion/3",0))])
  }
  private func staple()->PlanarStapleDefinition {
    .init(id:"supported-wire",entryPanelID:"floor",receivingPanelID:"wall",anchor:.init(50,50),entrySide:.inside,
      crownWidthMM:8,wireWidthMM:0.4,wireDepthMM:0.4,legLengthMM:8,minimumReceivingDepthMM:2,tool:"Declared board-edge driver",
      installation:.init(order:1,presentComponentIDs:["floor-piece","wall-piece"]))
  }
  private func withStaple(_ staple:PlanarStapleDefinition)->PlanarConstructionDefinition {
    var d=source();d.jointAttachments=[.init(id:"wire-attachment",joinID:"bond",staples:[staple])];return d
  }
  private func throughStackClinch(legLength:Double,wireDepth:Double=0.4,receivingTilt:Double=0)->PlanarConstructionDefinition {
    var definition=PlanarConstructionDefinition(name:"Through-stack rectangular wire",size:.init(400,140),stockThickness:2,
      panels:[rect("entry",0,0,100,100),rect("receiving",120,0,80,20)],
      joins:[.init(id:"through-joint",name:"Two receiving faces",firstPanelID:"entry",secondPanelID:"receiving",overlapMM:2)],rootPanelID:"entry",components:[
        .init(id:"entry-piece",name:"Entry stock",rootPanelID:"entry",anchor:.init(0,0),stock:.init(thicknessMM:2)),
        .init(id:"receiving-piece",name:"Receiving stock",rootPanelID:"receiving",anchor:.init(160,10),
          position:.init(50,-10,CADScalar(receivingTilt==0 ? -2:-3)),rotationDegrees:.init(0,CADScalar(receivingTilt),0),stock:.init(thicknessMM:receivingTilt==0 ? 2:2.4))])
    definition.jointAttachments=[.init(id:"through-attachment",joinID:"through-joint",staples:[
      .init(id:"through-wire",entryPanelID:"entry",receivingPanelID:"receiving",anchor:.init(50,10),
        crownWidthMM:8,wireWidthMM:0.4,wireDepthMM:CADScalar(wireDepth),legLengthMM:CADScalar(legLength),
        maximumJointGapMM:receivingTilt==0 ? 0.2:2,termination:.clinch,clinchLengthMM:0.01,
        tool:"Declared face clincher",clincherAccessMM:10,
        installation:.init(presentComponentIDs:["entry-piece","receiving-piece"]))])]
    return definition
  }
  func testStapleActuallyTraversesFloorAndReceivesInWallWithBuriedLegs()throws {
    let d=withStaple(staple()),result=try d.resolveJointAttachments(stock:.init(thicknessMM:2))
    let wire=try XCTUnwrap(result.staples.first);XCTAssertEqual(wire.pointsMM.count,4)
    XCTAssertEqual(wire.legMaterialIntervals.count,2)
    for spans in wire.legMaterialIntervals {
      XCTAssertEqual(spans.map(\.panelID),["floor","wall"])
      let floor=spans[0],wall=spans[1];XCTAssertEqual(floor.exitMM-floor.entryMM,2,accuracy:1e-8)
      XCTAssertEqual(wall.entryMM,floor.exitMM,accuracy:1e-8);XCTAssertGreaterThan(wall.exitMM-wall.entryMM,5)
    }
    XCTAssertEqual(PlanarJointGeometry.length(PlanarJointGeometry.sub(wire.pointsMM[0],wire.pointsMM[1])),8,accuracy:1e-8)
    XCTAssertEqual(PlanarJointGeometry.length(PlanarJointGeometry.sub(wire.pointsMM[2],wire.pointsMM[3])),8,accuracy:1e-8)
  }
  func testSourceAnchoredFastenerFollowsGroupPoseWithoutChangingSourceOrWireLength()throws {
    let d=withStaple(staple()),closed=try XCTUnwrap(d.resolveJointAttachments(stock:.init(thicknessMM:2)).staples.first)
    let posed=try XCTUnwrap(d.resolveJointAttachments(stock:.init(thicknessMM:2),openingPercent:80,explosionPercent:60).staples.first)
    for (a,b) in zip(closed.pointsMM,posed.pointsMM) {XCTAssertEqual(b.x-a.x,40,accuracy:1e-8);XCTAssertEqual(b.y-a.y,20,accuracy:1e-8);XCTAssertEqual(b.z,a.z,accuracy:1e-8)}
    XCTAssertEqual(posed.legMaterialIntervals,closed.legMaterialIntervals)
  }
  func testUnsupportedAnchorShortLegExposedEndAndEdgeClearanceReject()throws {
    var value=staple();value.anchor = .init(99,50);XCTAssertThrowsError(try withStaple(value).resolveJointAttachments(stock:.init(thicknessMM:2)))
    value=staple();value.legLengthMM=1;XCTAssertThrowsError(try withStaple(value).resolveJointAttachments(stock:.init(thicknessMM:2)))
    value=staple();value.legLengthMM=30;XCTAssertThrowsError(try withStaple(value).resolveJointAttachments(stock:.init(thicknessMM:2)))
    value=staple();value.minimumEdgeDistanceMM=1;XCTAssertThrowsError(try withStaple(value).resolveJointAttachments(stock:.init(thicknessMM:2)))
    value=staple();value.termination = .clinch;value.clinchLengthMM=2;value.clincherAccessMM=10
    XCTAssertThrowsError(try withStaple(value).resolveJointAttachments(stock:.init(thicknessMM:2)))
  }
  func testActualDriverObstructionIsRejectedAndWrongPartCannotBeSubstituted()throws {
    var d=withStaple(staple());d.panels.append(rect("obstacle",220,30,100,100))
    d.components!.append(.init(id:"obstacle-piece",name:"Driver obstacle",rootPanelID:"obstacle",anchor:.init(220,30),position:.init(-50,-10,-50),rotationDegrees:.init(-90,0,0),stock:.init(thicknessMM:2)))
    d.jointAttachments![0].staples![0].installation.presentComponentIDs.append("obstacle-piece")
    XCTAssertThrowsError(try d.resolveJointAttachments(stock:.init(thicknessMM:2))) {error in XCTAssertTrue(error.localizedDescription.contains("driver access"))}
    d=withStaple(staple());d.jointAttachments![0].staples![0].receivingPanelID="floor"
    XCTAssertThrowsError(try d.net())
  }
  func testActualCutEdgeBondAndGlueExclusionsResolveAndMissingContactRejects()throws {
    var d=source()
    let first=PlanarJointSurfaceRegion(polygon:[.init(10,49),.init(90,49),.init(90,51),.init(10,51)])
    let edge=PlanarJointSurfaceRegion(polygon:[.init(0,0),.init(80,0),.init(80,2),.init(0,2)],edgeIndex:2)
    d.jointAttachments=[.init(id:"actual-adhesive",joinID:"bond",adhesive:.init(identity:"Declared PVA",thicknessMM:0.05,firstRegion:first,secondRegion:edge,firstExclusions:[[.init(15,49.2),.init(20,49.2),.init(20,50.8),.init(15,50.8)]]))]
    let adhesive=try XCTUnwrap(d.resolveJointAttachments(stock:.init(thicknessMM:2)).adhesives.first)
    XCTAssertEqual(adhesive.firstExclusionsMM.count,1);XCTAssertEqual(adhesive.firstRegionMM.count,4)
    d.components![1].position.y=5
    XCTAssertThrowsError(try d.resolveJointAttachments(stock:.init(thicknessMM:2)))
  }
  func testTapeIsAnActualFoldedCutPieceAndBothContactRegionsAreRequired()throws {
    var d=source();d.panels += [rect("strip-floor",240,0,80,5),rect("strip-wall",240,5,80,5)]
    d.hinges=[.init(id:"strip-bend",parentPanelID:"strip-floor",childPanelID:"strip-wall",start:.init(240,5),end:.init(320,5),angleDegrees:90)]
    d.components!.append(.init(id:"strip-piece",name:"Actual fiber strip",rootPanelID:"strip-floor",anchor:.init(240,5),position:.init(-40,2.15,1.1),rotationDegrees:.init(90,0,0),groupID:"assembly",stock:.init(name:"Reinforcement",thicknessMM:0.1)))
    let first=PlanarJointSurfaceRegion(polygon:[.init(10.1,51.2),.init(89.9,51.2),.init(89.9,55.9),.init(10.1,55.9)])
    let second=PlanarJointSurfaceRegion(polygon:[.init(120.1,15.2),.init(199.9,15.2),.init(199.9,19.8),.init(120.1,19.8)])
    d.jointAttachments=[.init(id:"tape-joint",joinID:"bond",tape:.init(componentID:"strip-piece",firstRegion:first,secondRegion:second,widthMM:10,lengthMM:80,bondThicknessMM:0.1,installation:.init(order:2,presentComponentIDs:["floor-piece","wall-piece","strip-piece"])))]
    let result=try d.resolveJointAttachments(stock:.init(thicknessMM:2));XCTAssertEqual(result.tapes.count,1);XCTAssertEqual(result.tapes[0].stock.name,"Reinforcement");XCTAssertEqual(result.tapes[0].lengthMM,80)
    d.components![2].position.z=20
    XCTAssertThrowsError(try d.resolveJointAttachments(stock:.init(thicknessMM:2)))
  }
  func testInstalledSurfaceLayerChangesCrownOffsetAndMaterialIntervals()throws {
    var d=withStaple(staple());d.panels.append(rect("underlay",220,0,100,100))
    d.components!.append(.init(id:"underlay-piece",name:"Installed surface layer",rootPanelID:"underlay",anchor:.init(220,0),position:.init(-50,-0.1,-50),rotationDegrees:.init(-90,0,0),stock:.init(thicknessMM:0.2)))
    let before=try XCTUnwrap(d.resolveJointAttachments(stock:.init(thicknessMM:2)).staples.first)
    d.jointAttachments![0].staples![0].installation.presentComponentIDs.append("underlay-piece");d.jointAttachments![0].staples![0].layerComponentIDs=["underlay-piece"]
    let after=try XCTUnwrap(d.resolveJointAttachments(stock:.init(thicknessMM:2)).staples.first)
    XCTAssertEqual(before.pointsMM[1].y-after.pointsMM[1].y,0.2,accuracy:1e-8)
    XCTAssertEqual(after.legMaterialIntervals[0].map(\.panelID),["underlay","floor","wall"])
  }
  func testSupportedThroughStackClinchRetainsTwoActualReceivingRoutesAndSeparatedTips()throws {
    let wire=try XCTUnwrap(throughStackClinch(legLength:7).resolveJointAttachments(stock:.init(thicknessMM:2)).staples.first)
    XCTAssertEqual(wire.termination,.clinch);XCTAssertEqual(wire.pointsMM.count,6)
    XCTAssertEqual(wire.receivingThroughExitBoundaries.map(\.surface),[.inside,.inside])
    for spans in wire.legMaterialIntervals {XCTAssertEqual(spans.map(\.panelID),["entry","receiving"])}
    let tipGap=PlanarJointGeometry.length(PlanarJointGeometry.sub(wire.pointsMM[0],wire.pointsMM[5]))
    XCTAssertEqual(tipGap,2.8,accuracy:1e-8)
    XCTAssertEqual(try PlanarWireSection.corners(pointsMM:wire.pointsMM,widthMM:wire.wireWidthMM,depthMM:wire.wireDepthMM).count,6)
  }
  func testLongOpposedClinchesRejectActualPhysicalSelfOverlapWithRepair()throws {
    XCTAssertThrowsError(try throughStackClinch(legLength:12).resolveJointAttachments(stock:.init(thicknessMM:2))) {error in
      XCTAssertTrue(error.localizedDescription.contains("clinch wire overlaps itself"))
      XCTAssertTrue(error.localizedDescription.contains("Shorten the leg/clinch reach"))
    }
  }
  func testClinchShorterThanItsMiteredWireSectionRejectsInsteadOfFoldingItsOwnSweep()throws {
    XCTAssertThrowsError(try throughStackClinch(legLength:5.1,wireDepth:1).resolveJointAttachments(stock:.init(thicknessMM:2))) {error in
      XCTAssertTrue(error.localizedDescription.contains("clinch is too short for its physical wire section"))
    }
  }
  func testOpposedClinchesAtDifferentReceivingHeightsDoNotFailOnlyForProjectedLength()throws {
    let wire=try XCTUnwrap(throughStackClinch(legLength:11,receivingTilt:10).resolveJointAttachments(stock:.init(thicknessMM:2)).staples.first)
    // The tilted receiving board is 2.4 mm, retaining the unchanged 2 mm
    // receiving-depth requirement across every wire/edge offset ray.
    // The inward tips pass in X but have separate real Z intervals. A blanket
    // two-tip-length versus crown-span guard would wrongly reject this route.
    XCTAssertGreaterThan(wire.pointsMM[0].x,wire.pointsMM[5].x)
    XCTAssertGreaterThan(abs(wire.pointsMM[0].z-wire.pointsMM[5].z),wire.wireDepthMM)
    XCTAssertNotEqual(wire.receivingThroughExitBoundaries[0].pointMM.z,wire.receivingThroughExitBoundaries[1].pointMM.z)
  }

}

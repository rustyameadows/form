import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class PlanarAssemblyEnvelopeTests:XCTestCase {
  private func rect(_ id:String,_ x:Double,_ width:Double,_ height:Double,features:SheetPanelFeatures?=nil)->PlanarPanelDefinition {
    .init(id:id,name:id,polygon:[.init(CADScalar(x),0),.init(CADScalar(x+width),0),.init(CADScalar(x+width),CADScalar(height)),.init(CADScalar(x),CADScalar(height))],features:features)
  }
  private func joined()->PaperConstruction {
    let d=PlanarConstructionDefinition(name:"Grounded rigid stock joint",size:.init(240,120),stockThickness:2,
      panels:[rect("floor",0,100,100),rect("wall",120,80,20)],joins:[.init(id:"joint",name:"Actual receiving edge",firstPanelID:"floor",secondPanelID:"wall",overlapMM:2)],rootPanelID:"floor",components:[
        .init(id:"floor",name:"Floor",rootPanelID:"floor",anchor:.init(0,0),position:.init(-50,1,-50),rotationDegrees:.init(-90,0,0),groupID:"parent",stock:.init(thicknessMM:2)),
        .init(id:"wall",name:"Wall",rootPanelID:"wall",anchor:.init(120,20),position:.init(-40,2,0),groupID:"parent",stock:.init(thicknessMM:2))],groups:[.init(id:"parent",name:"Parent pose",position:.init("opening","explosion",0))],jointAttachments:[
          .init(id:"wire",joinID:"joint",staples:[.init(id:"engaged",entryPanelID:"floor",receivingPanelID:"wall",anchor:.init(50,50),entrySide:.inside,crownWidthMM:8,wireWidthMM:0.4,wireDepthMM:0.4,legLengthMM:8,tool:"Declared driver",installation:.init(presentComponentIDs:["floor","wall"]))])])
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:100,height:20,depth:100),stock:.init(thicknessMM:2));paper.authored=d;return paper
  }
  func testUndersideCrownContributesToFinishedBoundsAndOneSharedGroundOffset()throws {
    let paper=joined(),envelope=try PlanarAssemblyEnvelope.resolve(paper)
    XCTAssertEqual(envelope.panelFrameMinimumMM.y,-0.4,accuracy:1e-8)
    XCTAssertEqual(envelope.groundOffsetMM.x,0,accuracy:1e-8);XCTAssertEqual(envelope.groundOffsetMM.y,0.4,accuracy:1e-8);XCTAssertEqual(envelope.groundOffsetMM.z,0,accuracy:1e-8);XCTAssertEqual(envelope.minimumMM.y,0,accuracy:1e-8)
    XCTAssertEqual(envelope.sizeMM.y,22.4,accuracy:1e-8);XCTAssertEqual(envelope.sizeMM.x,100,accuracy:1e-8)
    let wire=try XCTUnwrap(paper.authored!.resolveJointAttachments(stock:paper.stock).staples.first)
    let minWire=wire.pointsMM.map(\.y).min()!-0.2+envelope.groundOffsetMM.y
    XCTAssertEqual(minWire,0,accuracy:1e-8)
  }
  func testIndependentCoreAndRealWrappingCalipersDriveTheSameEnvelope()throws {
    let panel=rect("plate",0,20,10,features:.init(wrap:.init(stock:.init(thicknessMM:0.2),turnInMM:1)))
    var d=PlanarConstructionDefinition(name:"Independent layered plate",parameters:[.init("core",0.5,0.5...2)],size:.init(40,30),stockThickness:0.5,
      panels:[panel],rootPanelID:"plate",components:[.init(id:"plate",name:"Plate",rootPanelID:"plate",anchor:.init(0,0),rotationDegrees:.init(-90,0,0),stock:.init(thicknessMM:1),stockThickness:"core")])
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:20,height:10,depth:0.5),stock:.init(thicknessMM:0.5));paper.authored=d
    let first=try PlanarAssemblyEnvelope.resolve(paper);XCTAssertEqual(first.sizeMM.y,0.9,accuracy:1e-8);XCTAssertEqual(first.sizeMM.x,20.4,accuracy:1e-8);XCTAssertEqual(first.sizeMM.z,10.4,accuracy:1e-8)
    try d.setParameters(["core":2]);paper.authored=d;let second=try PlanarAssemblyEnvelope.resolve(paper)
    XCTAssertEqual(second.sizeMM.y,2.4,accuracy:1e-8);XCTAssertEqual(second.sizeMM.x,first.sizeMM.x,accuracy:1e-8)
  }
  func testOpeningAndExplosionDoNotAlterClosedBoundsOrSavedSource()throws {
    var paper=joined();let closed=paper,before=try PlanarAssemblyEnvelope.resolve(paper)
    paper.openingPercent=95;paper.explosionPercent=100;let saved=paper
    XCTAssertEqual(try PlanarAssemblyEnvelope.resolve(paper),before);XCTAssertEqual(paper,saved)
    XCTAssertEqual(paper.authored,closed.authored)
    let actual=try paper.resolvedPanels(),rest=try closed.resolvedPanels()
    XCTAssertGreaterThan(actual[0].flatToWorld[3]-rest[0].flatToWorld[3],90)
  }
}

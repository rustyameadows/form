import AppKit
import XCTest
import FormCore
import FormCADModel
@testable import FormApp

@MainActor final class CanvasCutoutProjectionTests:XCTestCase {
  private func source()->PlanarConstructionDefinition {
    .init(name:"Window sheet",size:.init(30,20),stockThickness:1,panels:[
      .init(id:"sheet",name:"Sheet",polygon:[.init(0,0),.init(30,0),.init(30,20),.init(0,20)],
        cutouts:[.init(id:"window",polygon:[.init(4,5),.init(12,5),.init(12,11),.init(4,11)],kind:.window)])],rootPanelID:"sheet")
  }
  func testOutsideInsideAndWholeNetHitsExcludePhysicalHolesAndKeepCrossingArtwork()throws {
    let d=source(),net=try d.net()
    var object=ProductObject(name:"Window sheet",recipeID:"authored",parameters:[:]);object.paperConstruction = .init(kind:.authored,dimensions:.init(width:30,height:20,depth:1),stock:.init(thicknessMM:1));object.paperConstruction!.authored=d
    for inside in [false,true] {
      let projections=CanvasSourceProjection.views(of:object,sourceID:object.id,inside:inside,net:net)
      for projection in projections {
        let hole=projection.sourceToLocal.apply(.init(8,8)),material=projection.sourceToLocal.apply(.init(2,2))
        XCTAssertFalse(projection.contains(.init(x:hole.x,y:hole.y)))
        XCTAssertTrue(projection.contains(.init(x:material.x,y:material.y)))
        XCTAssertFalse(projection.intersects(.init(hole.x-1,hole.y-1,2,2)))
        XCTAssertTrue(projection.intersects(.init(hole.x-8,hole.y-1,16,2)))
        if !projection.isProof {
          XCTAssertFalse(projection.clipPath.contains(.init(x:hole.x,y:hole.y),using:.evenOdd))
          XCTAssertTrue(projection.clipPath.contains(.init(x:material.x,y:material.y),using:.evenOdd))
        }
      }
    }
  }
  func testSharedPhysicalFrameRoundtripKeepsCanonicalArtAndResourceIdentity()throws {
    let frame=try PhysicalArtworkFrame.paper(net:source().net(),panelID:"sheet",inside:true)
    var art=Artwork(background:"#FFFFFF",elements:[.init(kind:"text",x:2,y:2,text:"Across the window",fontSize:8)])
    art.backgroundOpacity=0
    let display=frame.display(art),roundtrip=try frame.source(from:display,original:art)
    XCTAssertEqual(roundtrip,art);XCTAssertEqual(display.elements.map(\.id),art.elements.map(\.id))
    XCTAssertEqual(frame.cutouts?.count,1)
  }
  func testExactFoldedSlabsSubtractCutoutsAndInvalidateCachedHoleGeometry()async throws {
    var d=PlanarConstructionDefinition(name:"Overlapping window plates",parameters:[
      .init("holeSize",2,1...4)],size:.init(30,10),stockThickness:1,panels:[
      .init(id:"first",name:"First",polygon:[.init(0,0),.init(10,0),.init(10,10),.init(0,10)],
        cutouts:[.init(id:"window",polygon:[.init("5-holeSize/2","5-holeSize/2"),.init("5+holeSize/2","5-holeSize/2"),.init("5+holeSize/2","5+holeSize/2"),.init("5-holeSize/2","5+holeSize/2")])]),
      .init(id:"second",name:"Second",polygon:[.init(20,0),.init(30,0),.init(30,10),.init(20,10)])],rootPanelID:"first",components:[
        .init(id:"first",name:"First",rootPanelID:"first",anchor:.init(0,10)),
        .init(id:"second",name:"Second",rootPanelID:"second",anchor:.init(20,10))])
    d.solidChecks=[.init(id:"physical-material-volume",firstPanelID:"first",secondPanelID:"second",metric:.interference,
      relation:.equal,value:"100-holeSize*holeSize",message:"Removed windows cannot contain stock volume.",tolerance:1e-7)]
    let request=PlanarConstructionValidationRequest(projectID:UUID(),objectID:UUID(),sourceRevision:"window-source",definition:d,
      fold:100,opening:0,cases:[.init(name:"two-mm-window",values:[:]),.init(name:"four-mm-window",values:["holeSize":4])])
    let report=try await PlanarSolidValidation.run(request)
    XCTAssertTrue(report.passed);XCTAssertEqual(report.cases.count,2)
    XCTAssertEqual(try XCTUnwrap(report.cases[0].solidChecks?.first?.measured),96,accuracy:1e-7)
    XCTAssertEqual(try XCTUnwrap(report.cases[1].solidChecks?.first?.measured),84,accuracy:1e-7)
  }
}

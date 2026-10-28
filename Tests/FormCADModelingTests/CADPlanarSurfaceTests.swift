import Foundation
import XCTest
import FormCADModel
import FormCADModeling

final class CADPlanarSurfaceTests: XCTestCase {
  private func fixture() -> CADModelDefinition {
    let body = CADFeatureNode(name:"Box",operation:.init(.box,values:["width":"width","height":30,"depth":40]))
    return .init(name:"Three authored surfaces",parameters:[.init("width",80,40...160)],features:[body],outputs:[body.id],surfaces:[
      .init(id:"top",name:"Top",outputFeatureID:body.id,selection:.faceAtMaximum(axis:"y"),
        origin:.init(0,30,40),uAxis:.xAxis,vAxis:.init(0,0,-1),width:"width",height:40),
      .init(id:"front",name:"Front",outputFeatureID:body.id,selection:.faceAtMinimum(axis:"z"),
        origin:.init(0,30,0),uAxis:.xAxis,vAxis:.init(0,-1,0),width:"width",height:30),
      .init(id:"right",name:"Right",outputFeatureID:body.id,selection:.faceAtMaximum(axis:"x"),
        origin:.init("width",30,0),uAxis:.zAxis,vAxis:.init(0,-1,0),width:40,height:30)
    ])
  }

  func testThreePhysicalFramesResolveAndPreserveIdentityAndOrientationAfterResize() async throws {
    var model=fixture()
    XCTAssertEqual(model.version,2)
    let evaluator=CADModelEvaluator(),first=try await evaluator.evaluate(model)
    XCTAssertTrue(first.surfaceIssues.isEmpty)
    XCTAssertEqual(first.surfaces.map(\.id),["top","front","right"])
    XCTAssertTrue(first.surfaces.allSatisfy{$0.faceIndex>0 && !$0.fingerprint.isEmpty})
    try model.setParameter("width",value:110)
    let changed=try await evaluator.evaluate(model)
    XCTAssertTrue(changed.surfaceIssues.isEmpty)
    XCTAssertEqual(changed.surfaces.map(\.id),first.surfaces.map(\.id))
    XCTAssertEqual(changed.surfaces[0].width,110)
    XCTAssertEqual(changed.surfaces[2].origin.x,110)
    XCTAssertEqual(changed.surfaces.map(\.uAxis),first.surfaces.map(\.uAxis))
    XCTAssertEqual(changed.surfaces.map(\.vAxis),first.surfaces.map(\.vAxis))
    let persisted=try JSONEncoder().encode(changed.surfaces)
    XCTAssertEqual(try JSONDecoder().decode([CADResolvedPlanarSurface].self,from:persisted),changed.surfaces)
    let reopened=try JSONDecoder().decode(CADModelDefinition.self,from:JSONEncoder().encode(model))
    XCTAssertEqual(reopened,model)
  }

  func testRemovedOrMissingSurfaceBecomesAnExplicitIssue() async throws {
    var model=fixture()
    let evaluator=CADModelEvaluator()
    _ = try await evaluator.evaluate(model)
    model.surfaces!.removeAll{$0.id=="front"}
    model.surfaces![0].selection = .faceAtCenter(point:.init(0,0,0),tolerance:1e-5)
    let changed=try await evaluator.evaluate(model)
    XCTAssertEqual(changed.surfaces.map(\.id),["right"])
    XCTAssertTrue(changed.surfaceIssues.contains{$0.surfaceID=="front" && $0.code=="removed-surface"})
    XCTAssertTrue(changed.surfaceIssues.contains{$0.surfaceID=="top" && $0.message.contains("0 faces")})
  }

  func testFrameMustBeOrthonormalAndRegionMustFitTheWholeFace() async throws {
    var model=fixture()
    model.surfaces![0].uAxis = .init(2,0,0)
    XCTAssertThrowsError(try model.validatedOrder())
    model=fixture();model.surfaces![0].width="width+10"
    let evaluator=CADModelEvaluator(),result=try await evaluator.evaluate(model)
    XCTAssertTrue(result.surfaceIssues.contains{$0.surfaceID=="top" && $0.message.contains("complete artwork boundary")})
    let report=try await CADParameterValidation.run(model:model,cases:[])
    XCTAssertFalse(report.allPassed)
    XCTAssertEqual(report.cases[0].surfaceIssues.first?.surfaceID,"top")
    model=fixture();model.surfaces![0].origin.y=29
    let offPlane=try await evaluator.evaluate(model)
    XCTAssertTrue(offPlane.surfaceIssues.contains{$0.surfaceID=="top" && $0.message.contains("plane")})
  }

  func testFullRegionContainmentDetectsAHiddenHoleWhenAllCornersFit() async throws {
    let box=CADFeatureNode(name:"Blank",operation:.init(.box,values:["width":100,"height":10,"depth":100]))
    let cylinder=CADFeatureNode(name:"Hole tool",operation:.init(.cylinder,values:["radius":10,"height":12]))
    let moved=CADFeatureNode(name:"Center hole",operation:.init(.transform,inputs:[cylinder.id],matrix:[1,0,0,50,0,1,0,-1,0,0,1,50,0,0,0,1]))
    let cut=CADFeatureNode(name:"Cut",operation:.init(.subtract,inputs:[box.id,moved.id]))
    var model=CADModelDefinition(name:"Face with a hole",features:[box,cylinder,moved,cut],outputs:[cut.id],surfaces:[
      .init(id:"top",name:"Top",outputFeatureID:cut.id,selection:.faceAtMaximum(axis:"y"),
        origin:.init(0,10,100),uAxis:.xAxis,vAxis:.init(0,0,-1),width:100,height:100)
    ])
    let evaluator=CADModelEvaluator(),invalid=try await evaluator.evaluate(model)
    XCTAssertTrue(invalid.surfaces.isEmpty)
    XCTAssertTrue(invalid.surfaceIssues[0].message.contains("hole or cutout"))
    model.surfaces![0].boundary=[.init(0,0),.init(30,0),.init(30,100),.init(0,100)]
    let valid=try await evaluator.evaluate(model)
    XCTAssertTrue(valid.surfaceIssues.isEmpty)
    XCTAssertEqual(valid.surfaces[0].boundary.count,4)
  }

  func testAmbiguousFaceSelectionLeavesArtworkUnresolved() async throws {
    let box=CADFeatureNode(name:"Box",operation:.init(.box,values:["width":20,"height":30,"depth":40]))
    let moved=CADFeatureNode(name:"Neighbor",operation:.init(.transform,inputs:[box.id],matrix:[1,0,0,20,0,1,0,0,0,0,1,0,0,0,0,1]))
    let assembly=CADFeatureNode(name:"Assembly",operation:.init(.assembly,inputs:[box.id,moved.id]))
    let model=CADModelDefinition(name:"Ambiguous target",features:[box,moved,assembly],outputs:[assembly.id],surfaces:[
      .init(id:"shared",name:"Shared wall",outputFeatureID:assembly.id,
        selection:.faceAtCenter(point:.init(20,15,20),tolerance:1e-5),origin:.init(20,0,0),
        uAxis:.zAxis,vAxis:.yAxis,width:40,height:30)
    ])
    let result=try await CADModelEvaluator().evaluate(model)
    XCTAssertTrue(result.surfaces.isEmpty)
    XCTAssertEqual(result.surfaceIssues.first?.surfaceID,"shared")
    XCTAssertTrue(result.surfaceIssues[0].message.contains("2 faces"))
  }
}

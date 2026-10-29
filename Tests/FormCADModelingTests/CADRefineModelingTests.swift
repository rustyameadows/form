import Foundation
import XCTest
import FormCADModel
import FormCADModeling

final class CADRefineModelingTests:XCTestCase {
  func testAuthoredRefineRoundtripsResizesCachesAndCanBeSuppressed()async throws {
    struct P {var x:Double,y:Double}
    let controls=(0..<16).map {i->P in let t=Double(i)*2*Double.pi/16;return .init(x:25*cos(t),y:15*sin(t))}
    func point(_ terms:[(P,Double)],divisor:Double)->CADExpressionPoint2 {
      let x=terms.reduce(0){$0+$1.0.x*$1.1}/divisor,y=terms.reduce(0){$0+$1.0.y*$1.1}/divisor
      return .init(CADScalar("\(x)*scale"),CADScalar("\(y)*scale"))
    }
    let curves=(0..<16).map {i->CADModelCurveSegment in
      let a=controls[(i+15)%16],b=controls[i],c=controls[(i+1)%16],d=controls[(i+2)%16]
      return .init(.cubicBezier,start:point([(a,1),(b,4),(c,1)],divisor:6),control1:point([(b,2),(c,1)],divisor:3),control2:point([(b,1),(c,2)],divisor:3),end:point([(b,1),(c,4),(d,1)],divisor:6))
    }
    let profile=CADFeatureNode(name:"Authored cubic sections",operation:.init(.curveProfile,curves:curves))
    let refined=CADFeatureNode(name:"Consolidate tangent spans",operation:.init(.refine,inputs:[profile.id]))
    func placed(_ name:String,_ y:CADScalar)->CADFeatureNode {
      .init(name:name,operation:.init(.transform,inputs:[refined.id],matrix:[1,0,0,0,0,1,0,y,0,0,1,0,0,0,0,1]))
    }
    let middle=placed("Middle section","height/2"),top=placed("Top section","height")
    let loft=CADFeatureNode(name:"Closed loft",operation:.init(.loft,inputs:[refined.id,middle.id,top.id]))
    let shell=CADFeatureNode(name:"True normal wall",operation:.init(.shell,inputs:[loft.id],values:["thickness":2],selection:.faceAtMaximum(axis:"y")))
    var model=CADModelDefinition(name:"Ordinary parametric smooth vessel",parameters:[.init("scale",1,0.8...1.2),.init("height",40,30...60)],features:[profile,refined,middle,top,loft,shell],outputs:[shell.id])
    let encoded=try JSONEncoder().encode(model),reopened=try JSONDecoder().decode(CADModelDefinition.self,from:encoded)
    XCTAssertEqual(model,reopened);XCTAssertEqual(try reopened.validatedOrder().count,6)
    var malformed=reopened;malformed.features[1].operation.values["distance"]=1
    XCTAssertThrowsError(try malformed.validatedOrder())
    let evaluator=CADModelEvaluator(),initial=try await evaluator.evaluate(reopened),initialShape=try XCTUnwrap(initial.outputs[shell.id])
    XCTAssertTrue(initialShape.info.valid && initialShape.info.closed)
    let topology=try await evaluator.featureTopology(modelID:model.id,featureID:refined.id,modelRevisionHash:initial.revisionHash)
    XCTAssertEqual(topology.edges.count,1)
    try model.setParameter("height",value:55)
    let taller=try await evaluator.evaluate(model),tallerShape=try XCTUnwrap(taller.outputs[shell.id])
    XCTAssertFalse(taller.rebuiltFeatureIDs.contains(profile.id));XCTAssertFalse(taller.rebuiltFeatureIDs.contains(refined.id))
    XCTAssertEqual(tallerShape.info.size.y,55,accuracy:1e-6)
    XCTAssertGreaterThan(tallerShape.info.volumeMM3,initialShape.info.volumeMM3)
    try model.setParameter("scale",value:1.1)
    let wider=try await evaluator.evaluate(model),widerShape=try XCTUnwrap(wider.outputs[shell.id])
    XCTAssertTrue(wider.rebuiltFeatureIDs.contains(refined.id))
    XCTAssertEqual(widerShape.info.size.x,tallerShape.info.size.x*1.1,accuracy:1e-5)
    model.features[1].suppressed=true
    let suppressed=try await evaluator.evaluate(model),suppressedShape=try XCTUnwrap(suppressed.outputs[shell.id])
    XCTAssertTrue(suppressedShape.info.valid && suppressedShape.info.closed)
    XCTAssertEqual(suppressedShape.info.volumeMM3,widerShape.info.volumeMM3,accuracy:0.001)
    XCTAssertEqual(suppressedShape.info.areaMM2,widerShape.info.areaMM2,accuracy:0.001)
    XCTAssertTrue(suppressed.features.contains{$0.id==refined.id && $0.suppressed})
  }
}

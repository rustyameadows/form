import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class PlanarPhysicalFlexBoundsTests:XCTestCase {
  private func paper(feature:SheetPanelFeatures,width:Double=80,height:Double=40,caliper:Double=0.4,
    rotation:CADExpressionPoint = .init(-45,20,25)) -> PaperConstruction {
    // An off-origin source catches accidental use of canonical coordinates as
    // the bend's material coordinate, independent of publication geometry.
    let x=30.0,y=20.0
    let panel=PlanarPanelDefinition(id:"panel",name:"Curved display",polygon:[
      .init(CADScalar(x),CADScalar(y)),.init(CADScalar(x+width),CADScalar(y)),
      .init(CADScalar(x+width),CADScalar(y+height)),.init(CADScalar(x),CADScalar(y+height))],features:feature)
    let definition=PlanarConstructionDefinition(name:"Material-bound curved sheet",size:.init(180,140),
      stockThickness:CADScalar(caliper),panels:[panel],rootPanelID:"panel",components:[
        .init(id:"display",name:"Display",rootPanelID:"panel",anchor:.init(CADScalar(x),CADScalar(y+height)),
          position:.init(15,7,"3+opening/10"),rotationDegrees:rotation)])
    var result=PaperConstruction(kind:.authored,dimensions:.init(width:180,height:140,depth:caliper),stock:.init(thicknessMM:caliper))
    result.authored=definition;return result
  }
  private func denseBounds(_ paper:PaperConstruction)throws->(low:Vector3,high:Vector3) {
    let panel=try XCTUnwrap(paper.net().panels.first),bounds=panel.bounds,size=Point2(bounds.width,bounds.height)
    let values=try XCTUnwrap(paper.authored).resolvedValues().merging(["fold":100,"opening":0]){_,new in new}
    let physical=try XCTUnwrap(panel.features).resolved(size:size,stock:paper.stock,variables:values){_,_ in nil}
    let flex=try XCTUnwrap(physical.1.flex),matrix=try XCTUnwrap(paper.resolvedPanels(foldPercent:100).first?.flatToWorld)
    let skin=physical.1.wrap?.stock.resolvedThicknessMM ?? 0,half=physical.0.resolvedThicknessMM/2+skin
    let horizontal=flex.edge == .left || flex.edge == .right,extent=horizontal ? size.x:size.y
    var low=Vector3(.infinity,.infinity,.infinity),high=Vector3(-.infinity,-.infinity,-.infinity)
    for i in 0...4000 {
      let axis = -skin+(extent+2*skin)*Double(i)/4000
      let cross=horizontal ? [-size.y-skin,skin]:[-skin,size.x+skin]
      for q in cross {for z in [-half,half] {
        var local=flex.deform(horizontal ? .init(axis,q,z):.init(q,-axis,z),size:size)
        local.x+=bounds.x;local.y-=bounds.y
        let p=PaperRigidMatrix.point(matrix,local)
        low = .init(min(low.x,p.x),min(low.y,p.y),min(low.z,p.z))
        high = .init(max(high.x,p.x),max(high.y,p.y),max(high.z,p.z))
      }}
    };return(low,high)
  }
  private func measuredBounds(_ source:PaperConstruction)throws->Vector3 {
    var project=Project(name:"Physical curved-sheet dependencies")
    var object=try project.makeObject(recipeID:"artboard",parameters:["width":180,"depth":140])
    object.paperConstruction=source;project.objects.append(object)
    var ids=[UUID]()
    for metric in [PhysicalDimensionMeasurement.closedWidth,.closedHeight,.closedThickness] {
      var dependent=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":100])
      dependent.dimensionBindings=[.init(parameter:"width",expression:"physical",inputs:["physical":.init(sourceObjectID:object.id,measurement:metric)])]
      project.objects.append(dependent);ids.append(dependent.id)
    }
    try project.reconcilePhysicalDimensions(previous:project)
    let values=try ids.map{id in try XCTUnwrap(project.objects.first{$0.id==id}?.parameters["width"])}
    return .init(values[0],values[1],values[2])
  }
  func testOffOriginCurvedSignIsGroundedAndBoundDimensionsMatchItsActualDeformedSurface()throws {
    let curve=SheetPanelNeutralCurve(points:[.init(0,0),.init(-1,0),.init(-1,30),.init(10,30)],fitLength:true)
    let source=paper(feature:.init(flex:.init(widthMM:80,curve:curve)))
    let dense=try denseBounds(source),measured=try measuredBounds(source)
    XCTAssertEqual(dense.low.y,0,accuracy:0.002,"Closed normalization must ground the curved caliper, rather than its unbent source rectangle.")
    XCTAssertEqual(dense.low.x+dense.high.x,0,accuracy:0.002)
    XCTAssertEqual(dense.low.z+dense.high.z,0,accuracy:0.002)
    XCTAssertEqual(measured.x,dense.high.x-dense.low.x,accuracy:0.002)
    XCTAssertEqual(measured.y,dense.high.y-dense.low.y,accuracy:0.002)
    XCTAssertEqual(measured.z,dense.high.z-dense.low.z,accuracy:0.002)
  }
  func testFiniteHalfTurnWrappedFlapUsesActualSkinAndClosedRestBoundsAtEveryViewingOpening()throws {
    let radius=2.0,feature=SheetPanelFeatures(wrap:.init(stock:.init(thicknessMM:0.1),turnInMM:2),
      flex:.init(edge:.right,widthMM:CADScalar(.pi*radius),angleDegrees:-180))
    var source=paper(feature:feature,width:60,height:30,caliper:0.2,rotation:.init(-90,0,90))
    let dense=try denseBounds(source),closed=try measuredBounds(source)
    XCTAssertEqual(dense.low.y,0,accuracy:0.002)
    XCTAssertEqual(closed.x,dense.high.x-dense.low.x,accuracy:0.002)
    XCTAssertEqual(closed.y,dense.high.y-dense.low.y,accuracy:0.002)
    XCTAssertEqual(closed.z,dense.high.z-dense.low.z,accuracy:0.002)
    XCTAssertEqual(closed.x,2*radius+0.4,accuracy:0.002,"The finite turn must contribute its diameter and both physical skin/caliper offsets instead of a flat slab.")
    for opening in [25.0,60,100] {
      source.openingPercent=opening
      XCTAssertEqual(try measuredBounds(source),closed,"Fitted rest dimensions must ignore the object's current viewing pose.")
    }
  }
  func testSingleRootFeatureNeedsNoComponentToGroundItsBentStock()throws {
    var source=paper(feature:.init(flex:.init(widthMM:20,angleDegrees:-120)))
    source.authored!.components=nil
    let dense=try denseBounds(source),measured=try measuredBounds(source)
    XCTAssertEqual(dense.low.y,0,accuracy:0.002)
    XCTAssertEqual(dense.low.x+dense.high.x,0,accuracy:0.002)
    XCTAssertEqual(dense.low.z+dense.high.z,0,accuracy:0.002)
    XCTAssertEqual(measured.x,dense.high.x-dense.low.x,accuracy:0.002)
    XCTAssertEqual(measured.y,dense.high.y-dense.low.y,accuracy:0.002)
    XCTAssertEqual(measured.z,dense.high.z-dense.low.z,accuracy:0.002)
  }

}

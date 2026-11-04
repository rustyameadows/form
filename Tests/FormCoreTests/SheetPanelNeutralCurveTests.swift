import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class SheetPanelNeutralCurveTests:XCTestCase {
  private let controls:[Point2]=[.init(0,0),.init(-1,0),.init(-1,30),.init(10,30)]
  private func fixture()throws->(Project,ProductObject) {
    var project=Project(name:"Authored curved structural sign")
    var page=try project.makeObject(recipeID:"artboard",parameters:["width":10,"depth":20])
    page.artwork=Artwork(elements:[]);project.objects.append(page)
    let publication=try PublicationCommands.createPublication(in:&project,name:"Canonical source",pages:[page.id])
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,stock:.init(thicknessMM:0.1)))
    return(project,project.objects.first{$0.id==id}!)
  }
  func testCurveFitsOnePhysicalLengthByCommonInteriorXFactorAndKeepsEndpointsAndHeight()throws {
    let profile=try SheetPanelNeutralCurveProfile(points:controls,widthMM:80,fitLength:true,maximumNormalOffsetMM:0.2)
    XCTAssertEqual(profile.points[0],controls[0]);XCTAssertEqual(profile.points[3],controls[3])
    XCTAssertEqual(profile.points[1].x,profile.points[2].x,accuracy:1e-10)
    XCTAssertLessThan(profile.points[1].x,-1)
    XCTAssertEqual(profile.points[1].y,0);XCTAssertEqual(profile.points[2].y,30)
    XCTAssertEqual(profile.lengthMM,80,accuracy:8e-6)
    let end=profile.sample(atMM:80)
    XCTAssertEqual(end.xMM,10,accuracy:1e-8);XCTAssertEqual(end.yMM,30,accuracy:1e-8)
    var prior=profile.sample(atMM:0),length=0.0
    for i in 1...4000 {
      let current=profile.sample(atMM:80*Double(i)/4000),segment=hypot(current.xMM-prior.xMM,current.yMM-prior.yMM)
      XCTAssertLessThanOrEqual(segment,0.02+1e-7,"Material arc coordinates must not stretch at high curvature.")
      length+=segment;prior=current
    }
    XCTAssertEqual(length,80,accuracy:0.001)
    XCTAssertEqual(try JSONDecoder.form.decode(SheetPanelNeutralCurveProfile.self,from:JSONEncoder.form.encode(profile)),profile)
    let authored=SheetPanelNeutralCurve(points:[.init(0,0),.init(10,0),.init(20,0),.init(30,0)])
    var raw=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder.form.encode(authored)) as? [String:Any]);raw.removeValue(forKey:"fitLength")
    let decoded=try JSONDecoder.form.decode(SheetPanelNeutralCurve.self,from:JSONSerialization.data(withJSONObject:raw))
    XCTAssertFalse(decoded.fitLength,"Omitting the optional fit flag preserves supplied physical control points.")
  }
  func testCurveRejectsStretchFallbackCuspsBadOriginsAndInsufficientCaliperRadius()throws {
    XCTAssertThrowsError(try SheetPanelNeutralCurveProfile(points:controls,widthMM:80),"Supplied curves must already match length when fitting is disabled.")
    XCTAssertThrowsError(try SheetPanelNeutralCurveProfile(points:[.init(0,0),.init(0,3),.init(0,7),.init(0,10)],widthMM:20,fitLength:true))
    XCTAssertThrowsError(try SheetPanelNeutralCurveProfile(points:[.init(0,0),.init(10,0),.init(-10,0),.init(0,0)],widthMM:30,fitLength:true)) {XCTAssertTrue($0.localizedDescription.contains("cusp"))}
    var shifted=controls;shifted[0].x=1
    XCTAssertThrowsError(try SheetPanelNeutralCurveProfile(points:shifted,widthMM:80,fitLength:true))
    XCTAssertThrowsError(try SheetPanelNeutralCurveProfile(points:Array(controls.prefix(3)),widthMM:80,fitLength:true))
    let tight=try SheetPanelNeutralCurveProfile(points:[.init(0,0),.init(-1,0),.init(-1,10),.init(0,10)],widthMM:30,fitLength:true)
    XCTAssertThrowsError(try tight.validateCaliper(maximumNormalOffsetMM:tight.minimumRadiusMM))
    XCTAssertNoThrow(try tight.validateCaliper(maximumNormalOffsetMM:tight.minimumRadiusMM*0.9))
  }
  func testWholePanelFlexAndClosedEnvelopeUseSameCurvedCaliperSamplesAtEveryViewingPose()throws {
    var(project,object)=try fixture()
    let curve=SheetPanelNeutralCurve(points:controls.map{.init(CADScalar($0.x),CADScalar($0.y))},fitLength:true)
    let feature=SheetPanelFeatures(flex:.init(widthMM:80,curve:curve))
    object.sheetAssembly!.enclosure=[.init(id:"curved-sign",name:"Curved freestanding sign",size:.init(80,40),
      positionMM:.init(-50,-20,-5),rotationDegrees:.init(30,45,20),stock:.init(thicknessMM:0.4),features:feature)]
    project.objects[project.objects.firstIndex{$0.id==object.id}!]=object
    let closed=try project.sheetAssemblyMeasurements(object),resolved=try project.resolvedSheetAssembly(object)
    let plane=try XCTUnwrap(resolved.enclosure.first),flex=try XCTUnwrap(plane.features?.flex)
    let matrix=PaperRigidMatrix.multiply(PaperRigidMatrix.translation(-50,-20,-5),PaperRigidMatrix.rotation(30,45,20))
    var points=[Vector3(0,0,-10),.init(10,0.1,10)]
    for i in 0...2000 {for y in [0.0,-40] {for z in [-0.2,0.2] {
      let local=flex.deform(.init(80*Double(i)/2000,y,z),size:.init(80,40));points.append(PaperRigidMatrix.point(matrix,local))
    }}}
    let width=points.map(\.x).max()!-points.map(\.x).min()!,height=points.map(\.z).max()!-points.map(\.z).min()!,thickness=points.map(\.y).max()!-points.map(\.y).min()!
    XCTAssertEqual(closed.closedWidth,width,accuracy:0.002)
    XCTAssertEqual(closed.closedHeight,height,accuracy:0.002)
    XCTAssertEqual(closed.closedThickness,thickness,accuracy:0.002)
    for opening in [0.0,95,180] {
      object.sheetAssembly!.openingDegrees=opening
      XCTAssertEqual(try project.sheetAssemblyMeasurements(object),closed)
    }
    var invalid=object.sheetAssembly!;invalid.enclosure![0].features!.flex!.angleDegrees=45
    let before=project
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:object.id,definition:invalid))
    XCTAssertEqual(project,before,"Competing bend definitions must reject atomically.")
    invalid=object.sheetAssembly!;invalid.enclosure![0].features!.flex!.curve!.points[0].x=2
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in:&project,objectID:object.id,definition:invalid));XCTAssertEqual(project,before)
  }
  func testParametricWrapCaliperPreservesBondedPlyProportionsAndChangesPhysicalEnvelope()throws {
    let back=PaperPly(name:"Paper backing",color:"#E9E3D6",thicknessMM:0.04),front=PaperPly(name:"Woven skin",color:"#2C4F44",thicknessMM:0.08)
    let skin=PaperStock(thicknessMM:0.12,plies:[back,front]),core=PaperStock(thicknessMM:2)
    var feature=SheetPanelFeatures(wrap:.init(stock:skin,turnInMM:4,stockThickness:"skin"))
    let resolved=try feature.resolved(size:.init(80,40),stock:core,variables:["skin":0.24],face:{_,_ in nil})
    let wrapped=try XCTUnwrap(resolved.1.wrap?.stock)
    XCTAssertEqual(wrapped.resolvedThicknessMM,0.24,accuracy:1e-10)
    XCTAssertEqual(wrapped.plies![0].thicknessMM,0.08,accuracy:1e-10);XCTAssertEqual(wrapped.plies![1].thicknessMM,0.16,accuracy:1e-10)
    XCTAssertEqual(resolved.0,core);XCTAssertEqual(feature.wrap?.stock,skin,"Resolved caliper cannot rewrite the canonical source material.")
    XCTAssertThrowsError(try feature.resolved(size:.init(80,40),stock:core,variables:["skin":-0.1],face:{_,_ in nil}))
    feature.flex = .init(widthMM:4,angleDegrees:180)
    XCTAssertThrowsError(try feature.resolved(size:.init(80,40),stock:core,variables:["skin":0.6],face:{_,_ in nil}),"The real skin contributes to the bend radius guard.")
    var(project,object)=try fixture();feature.flex=nil
    object.parameters["skin"]=0.12
    object.sheetAssembly!.enclosure=[.init(id:"panel",name:"Wrapped sign",size:.init(80,40),rotationDegrees:.init(-90,0,0),stock:core,features:feature)]
    project.objects[project.objects.firstIndex{$0.id==object.id}!]=object
    let thin=try project.sheetAssemblyMeasurements(object)
    object.parameters["skin"]=0.24
    let thick=try project.sheetAssemblyMeasurements(object)
    XCTAssertEqual(thick.closedWidth-thin.closedWidth,0.24,accuracy:1e-8)
    XCTAssertEqual(thick.closedThickness-thin.closedThickness,0.24,accuracy:1e-8)
  }
}

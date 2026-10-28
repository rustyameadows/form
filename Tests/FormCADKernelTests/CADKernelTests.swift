import Foundation
import XCTest
import FormCADKernel

final class CADKernelTests:XCTestCase {
  private func folder()throws->URL{let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);addTeardownBlock{try? FileManager.default.removeItem(at:url)};return url}
  func testMillimeterAxesAnalyticPrimitivesAndRigidTransforms() async throws {
    let k=CADKernel();XCTAssertEqual(CADKernel.version,"8.0.1")
    let box=try await k.box(width:80,height:50,depth:20);XCTAssertEqual(box.info.size,.init(80,50,20));XCTAssertEqual(box.info.volumeMM3,80000,accuracy:1e-6)
    let cylinder=try await k.cylinder(radius:10,height:40);XCTAssertEqual(cylinder.info.size.y,40,accuracy:1e-7);XCTAssertEqual(cylinder.info.volumeMM3,Double.pi*100*40,accuracy:1e-6)
    let turned=try await k.transform(cylinder,rowMajorMatrix:[1,0,0,40,0,0,-1,25,0,1,0,-10,0,0,0,1]);XCTAssertEqual(turned.info.volumeMM3,cylinder.info.volumeMM3,accuracy:1e-6)
    let faces=try await k.faces(turned);XCTAssertTrue(faces.contains{$0.surfaceType==1},"Rigid placement must preserve the analytic cylinder surface.")
    let sphere=try await k.sphere(radius:12);XCTAssertEqual(sphere.info.volumeMM3,4/3*Double.pi*1728,accuracy:1e-5)
    let cone=try await k.cone(bottomRadius:20,topRadius:10,height:30);XCTAssertEqual(cone.info.volumeMM3,Double.pi*30/3*(400+200+100),accuracy:1e-5)
    let torus=try await k.torus(majorRadius:30,minorRadius:5);XCTAssertEqual(torus.info.volumeMM3,2*Double.pi*Double.pi*30*25,accuracy:1e-5)
  }
  func testRealProfileExtrudeCutFilletStepAndBRepRoundtrip() async throws {
    let k=CADKernel(),root=try folder()
    let profile=try await k.profile(outer:[.init(0,0),.init(80,0),.init(80,50),.init(0,50)])
    let block=try await k.extrude(profile,vector:.init(0,0,20)),cylinder=try await k.cylinder(radius:10,height:40)
    let tool=try await k.transform(cylinder,rowMajorMatrix:[1,0,0,40,0,0,-1,25,0,1,0,-10,0,0,0,1])
    let cut=try await k.boolean(.subtract,block,tool);XCTAssertEqual(cut.info.volumeMM3,80000-Double.pi*100*20,accuracy:1e-6)
    let rounded=try await k.fillet(cut,radius:2);XCTAssertTrue(rounded.info.valid);XCTAssertTrue(rounded.info.closed);XCTAssertGreaterThan(rounded.info.faces,cut.info.faces)
    try await k.writeBRep(rounded,to:root.appendingPathComponent("before.brep"))
    do{_=try await k.fillet(rounded,radius:100);XCTFail("Impossible fillet must reject.")}catch let error as CADKernelError{XCTAssertFalse(error.message.isEmpty)}
    try await k.writeBRep(rounded,to:root.appendingPathComponent("after.brep"))
    XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("before.brep")),try Data(contentsOf:root.appendingPathComponent("after.brep")))
    let reopened=try await k.readBRep(from:root.appendingPathComponent("before.brep"));XCTAssertEqual(reopened.info.volumeMM3,rounded.info.volumeMM3,accuracy:1e-5)
    try await k.writeSTEP(rounded,to:root.appendingPathComponent("body.step"));let step=try await k.readSTEP(from:root.appendingPathComponent("body.step"));XCTAssertTrue(step.info.valid&&step.info.closed);XCTAssertEqual(step.info.volumeMM3,rounded.info.volumeMM3,accuracy:1e-3)
    XCTAssertEqual(step.info.size.x,80,accuracy:1e-6);XCTAssertEqual(step.info.size.y,50,accuracy:1e-6);XCTAssertEqual(step.info.size.z,20,accuracy:1e-6)
    do{try await k.writeSTEP(rounded,to:root.appendingPathComponent("body.step"));XCTFail("Existing output must be preserved.")}catch{}
  }
  func testCurvedBezierRevolveAnalyticCircleLoftSweepShellAndClearance() async throws {
    let k=CADKernel()
    let profile=try await k.curveProfile([
      .init(.cubicBezier,start:.init(20,0,0),control1:.init(45,5,0),control2:.init(45,30,0),end:.init(35,50,0)),
      .init(.line,start:.init(35,50,0),end:.init(32,50,0)),
      .init(.cubicBezier,start:.init(32,50,0),control1:.init(42,30,0),control2:.init(42,5,0),end:.init(17,3,0)),
      .init(.line,start:.init(17,3,0),end:.init(0,3,0)),.init(.line,start:.init(0,3,0),end:.init(0,0,0)),.init(.line,start:.init(0,0,0),end:.init(20,0,0))])
    let vessel=try await k.revolve(profile);XCTAssertTrue(vessel.info.valid&&vessel.info.closed);XCTAssertEqual(vessel.info.size.y,50,accuracy:1e-6)
    let circle=try await k.circleProfile(radius:25),cylinder=try await k.extrude(circle,vector:.init(0,20,0));XCTAssertEqual(cylinder.info.faces,3);XCTAssertEqual(cylinder.info.volumeMM3,Double.pi*625*20,accuracy:1e-5)
    let top=try await k.circleProfile(radius:30,plane:.init(origin:.init(0,50,0),u:.init(1,0,0),v:.init(0,0,-1))),loft=try await k.loft([circle,top]);XCTAssertTrue(loft.info.valid&&loft.info.closed)
    let sweepProfile=try await k.circleProfile(radius:8,plane:.xy),sweep=try await k.sweep(sweepProfile,path:[.init(),.init(0,0,50)]);XCTAssertEqual(sweep.info.volumeMM3,Double.pi*64*50,accuracy:1e-5)
    let box=try await k.box(width:100,height:80,depth:60),faces=try await k.faces(box),face=try XCTUnwrap(faces.first{abs($0.center.y-80)<1e-6})
    let hollow=try await k.shell(box,removingFaces:[face.index],thickness:3);XCTAssertTrue(hollow.info.valid&&hollow.info.closed);XCTAssertLessThan(hollow.info.volumeMM3,box.info.volumeMM3)
    let moved=try await k.translated(box,by:.init(110,0,0)),gap=try await k.clearance(box,moved);XCTAssertEqual(gap.distanceMM,10,accuracy:1e-6);XCTAssertEqual(gap.interferenceVolumeMM3,0,accuracy:1e-6)
    let compound=try await k.compound([box,moved]);XCTAssertEqual(compound.info.solids,2)
    let chamfer=try await k.chamfer(box,distance:2);XCTAssertTrue(chamfer.info.valid&&chamfer.info.closed)
  }
  func testTessellationKeepsSharpNormalsFaceMappingsAndIndependentQuality() async throws {
    let k=CADKernel(),box=try await k.box(width:20,height:30,depth:40)
    let mesh=try await k.tessellate(box);XCTAssertEqual(mesh.triangleCount,12);XCTAssertEqual(Set(mesh.faceIndices).count,6)
    XCTAssertEqual(mesh.positions.count,24,"Face-local vertices preserve sharp normals.")
    for n in mesh.normals{XCTAssertEqual(n.x*n.x+n.y*n.y+n.z*n.z,1,accuracy:1e-7)}
    let sphere=try await k.sphere(radius:40),coarse=try await k.tessellate(sphere,quality:.preview),fine=try await k.tessellate(sphere,quality:.fabrication)
    XCTAssertGreaterThan(fine.triangleCount,coarse.triangleCount)
    for (p,n) in zip(fine.positions,fine.normals){XCTAssertGreaterThan(p.x*n.x+p.y*n.y+p.z*n.z,39.9)}
    let after=try await k.inspect(sphere);XCTAssertEqual(after,sphere.info)
  }
  func testPublishedExactReportStaysCorrectAcrossDerivedGeometryMeshingAndFreshRead()async throws {
    let kernel=CADKernel(),root=try folder(),source=try await kernel.box(width:20,height:30,depth:40)
    XCTAssertEqual(source.info.volumeMM3,24000,accuracy:1e-7)
    XCTAssertEqual(source.info.areaMM2,5200,accuracy:1e-7)
    let before=root.appendingPathComponent("source-before.brep")
    try await kernel.writeBRep(source,to:before)
    let bore=try await kernel.cylinder(radius:3,height:60),tool=try await kernel.translated(bore,by:.init(10,-5,20))
    let drilled=try await kernel.boolean(.subtract,source,tool)
    XCTAssertEqual(drilled.info.volumeMM3,24000-270*Double.pi,accuracy:1e-6)
    let angle=0.63,c=cos(angle),s=sin(angle)
    let rotated=try await kernel.transform(source,rowMajorMatrix:[c,0,s,17,0,1,0,23,-s,0,c,-11,0,0,0,1])
    let translated=try await kernel.translated(rotated,by:.init(12,-8,21))
    for rigid in [rotated,translated] {
      XCTAssertEqual(rigid.info.volumeMM3,24000,accuracy:1e-6)
      XCTAssertEqual(rigid.info.areaMM2,5200,accuracy:1e-6)
      XCTAssertTrue(rigid.info.valid && rigid.info.closed)
    }
    let scaled=try await kernel.transform(source,rowMajorMatrix:[2,0,0,5,0,1,0,7,0,0,0.25,11,0,0,0,1])
    // General-transform bounds include OCCT Precision::Confusion padding.
    XCTAssertEqual(scaled.info.minimum.x,5,accuracy:1e-6);XCTAssertEqual(scaled.info.minimum.y,7,accuracy:1e-6);XCTAssertEqual(scaled.info.minimum.z,11,accuracy:1e-6)
    XCTAssertEqual(scaled.info.size.x,40,accuracy:1e-6);XCTAssertEqual(scaled.info.size.y,30,accuracy:1e-6);XCTAssertEqual(scaled.info.size.z,10,accuracy:1e-6)
    XCTAssertEqual(scaled.info.volumeMM3,12000,accuracy:1e-6)
    XCTAssertEqual(scaled.info.areaMM2,3800,accuracy:1e-6)
    let uniform=try await kernel.transform(source,rowMajorMatrix:[2,0,0,0,0,2,0,0,0,0,2,0,0,0,0,1])
    XCTAssertEqual(uniform.info.volumeMM3,192000,accuracy:1e-5)
    XCTAssertEqual(uniform.info.areaMM2,20800,accuracy:1e-5)
    let sheared=try await kernel.transform(source,rowMajorMatrix:[1,0.5,0,0,0,1,0,0,0,0,1,0,0,0,0,1])
    XCTAssertEqual(sheared.info.volumeMM3,24000,accuracy:1e-5)
    XCTAssertEqual(sheared.info.areaMM2,2800+2400*sqrt(1.25),accuracy:1e-5)
    _ = try await kernel.tessellate(source,quality:.fabrication)
    _ = try await kernel.tessellate(drilled,quality:.preview)
    let unchanged=try await kernel.inspect(source),changed=try await kernel.inspect(scaled)
    XCTAssertEqual(unchanged,source.info);XCTAssertEqual(changed,scaled.info)
    let after=root.appendingPathComponent("source-after.brep")
    try await kernel.writeBRep(source,to:after)
    XCTAssertEqual(try Data(contentsOf:before),try Data(contentsOf:after))
    let reopened=try await kernel.readBRep(from:before)
    XCTAssertTrue(reopened.info.valid && reopened.info.closed)
    XCTAssertEqual(reopened.info.volumeMM3,24000,accuracy:1e-6);XCTAssertEqual(reopened.info.areaMM2,5200,accuracy:1e-6)
    XCTAssertEqual(reopened.info.maximumToleranceMM,source.info.maximumToleranceMM,accuracy:1e-12)
    // STEP's default DirectFaces preprocessing may modify an indirect surface;
    // export must operate on its own copy just like other kernel operations.
    let mirrored=try await kernel.transform(bore,rowMajorMatrix:[-1,0,0,6,0,1,0,4,0,0,1,8,0,0,0,1])
    let mirroredBefore=root.appendingPathComponent("mirrored-before.brep"),mirroredAfter=root.appendingPathComponent("mirrored-after.brep")
    try await kernel.writeBRep(mirrored,to:mirroredBefore)
    try await kernel.writeSTEP(mirrored,to:root.appendingPathComponent("mirrored.step"))
    try await kernel.writeBRep(mirrored,to:mirroredAfter)
    XCTAssertEqual(try Data(contentsOf:mirroredBefore),try Data(contentsOf:mirroredAfter))
    let stillMirrored=try await kernel.inspect(mirrored)
    XCTAssertEqual(stillMirrored,mirrored.info)
    XCTAssertEqual(stillMirrored.volumeMM3,540*Double.pi,accuracy:1e-6)
    XCTAssertEqual(stillMirrored.areaMM2,378*Double.pi,accuracy:1e-6)
    let face=try await kernel.profile(outer:[.init(0,0),.init(20,0),.init(20,30),.init(0,30)])
    do{_ = try await kernel.boolean(.union,source,face);XCTFail("An inspected open face must still reject as a solid boolean input.")}catch{}
  }
  func testInvalidProfilesNonFiniteInputsAndCancelledRequestsNeverPublish() async throws {
    let k=CADKernel()
    for radius in [Double.nan,Double.infinity,-1,0]{do{_=try await k.sphere(radius:radius);XCTFail("Invalid radius accepted.")}catch{}}
    do{_=try await k.profile(outer:[.init(0,0),.init(10,10),.init(0,10),.init(10,0)]);XCTFail("Self-intersecting profile accepted.")}catch{}
    let task=Task{try await k.box(width:20,height:20,depth:20)};task.cancel()
    do{_=try await task.value;XCTFail("Cancelled task published a result.")}catch is CancellationError{}
    let valid=try await k.box(width:20,height:20,depth:20);XCTAssertEqual(valid.info.volumeMM3,8000,accuracy:1e-6)
  }
  func testSTEPAssemblyPreservesHierarchyRepeatedDefinitionsNamesTransformsAndFaceColors()async throws {
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures"),kernel=CADKernel(),source=root.appendingPathComponent("colored-assembly.step")
    let assembly=try await kernel.readSTEPAssembly(from:source)
    XCTAssertEqual(assembly.nodes.count,5);XCTAssertEqual(assembly.parts.count,3);XCTAssertEqual(assembly.nodes[0].name,"Clock movement assembly");XCTAssertTrue(assembly.nodes[0].assembly)
    let boxes=assembly.nodes.filter{!$0.assembly&&$0.name.hasPrefix("Bracket")};XCTAssertEqual(boxes.count,2)
    XCTAssertEqual(boxes[0].definitionKey,boxes[1].definitionKey);XCTAssertNotEqual(boxes[0].path,boxes[1].path)
    for node in boxes{XCTAssertEqual(node.parentIndex,1);XCTAssertEqual(node.worldTransformMM[7],205,accuracy:1e-8);XCTAssertEqual(node.worldTransformMM[11],306,accuracy:1e-8);XCTAssertNotNil(node.linearRGBA);XCTAssertTrue(node.faceColors.contains{abs($0.rgba[2]-0.9)<1e-5})}
    let part=try await kernel.readSTEP(from:source,partPath:boxes[0].path);XCTAssertEqual(part.info.minimum.x,140,accuracy:1e-6);XCTAssertEqual(part.info.minimum.y,205,accuracy:1e-6);XCTAssertEqual(part.info.volumeMM3,6000,accuracy:1e-5)
    do{_ = try await kernel.readSTEP(from:source,partPath:"9/9");XCTFail("Unknown source occurrence accepted.")}catch{}
    do{_ = try await kernel.readSTEPAssembly(from:root.appendingPathComponent("external-reference.step"));XCTFail("External filesystem references accepted.")}catch{XCTAssertTrue(error.localizedDescription.contains("external file references"))}
  }

}

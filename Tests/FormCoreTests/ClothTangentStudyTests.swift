import AppKit
import SceneKit
import Metal
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class ClothTangentStudyTests:XCTestCase {
  private func comparison()throws -> (ClothStudy,ClothStudy) {
    let object=try Project(name:"Reset comparison").makeObject(recipeID:"clothPanel")
    let tangent=try XCTUnwrap(object.cloth);var old=tangent
    let y=2*object["supportRadius"]+55
    for i in old.mesh.restPositionsMm.indices {old.mesh.restPositionsMm[i].y=y}
    return(old,tangent)
  }
  func testTangentResetRetainsPhysicsAndProducesRealDrapeWithoutInitialPinStrain()throws {
    let (old,tangent)=try comparison()
    XCTAssertEqual(old.settings,tangent.settings);XCTAssertEqual(old.colliders,tangent.colliders)
    XCTAssertEqual(old.mesh.pins,tangent.mesh.pins);XCTAssertEqual(old.mesh.massesKg,tangent.mesh.massesKg)
    XCTAssertEqual(old.mesh.links,tangent.mesh.links);XCTAssertEqual(old.mesh.uv,tangent.mesh.uv);XCTAssertEqual(old.mesh.triangles,tangent.mesh.triangles)
    var a=try ClothSolver(mesh:old.mesh,settings:old.settings,colliders:old.colliders),b=try ClothSolver(mesh:tangent.mesh,settings:tangent.settings,colliders:tangent.colliders)
    let oldInitial=a.frame,newInitial=b.frame
    XCTAssertGreaterThan(oldInitial.diagnostics.maximumDistanceErrorMm,20)
    XCTAssertLessThan(newInitial.diagnostics.maximumDistanceErrorMm,1e-8)
    XCTAssertLessThan(newInitial.diagnostics.maximumSurfacePenetrationMm,1e-7)
    XCTAssertEqual(Set(newInitial.positionsMm.map(\.y)).count,1)
    try a.start();try b.start();try a.advance();try b.advance()
    let oldFirst=a.diagnostics,newFirst=b.diagnostics
    XCTAssertLessThan(newFirst.maximumConstraintForceN,oldFirst.maximumConstraintForceN)
    for _ in 1..<90 {try a.advance();try b.advance()}
    let resetPositions=newInitial.positionsMm
    XCTAssertGreaterThan(zip(resetPositions,b.frame.positionsMm).map{$0.y-$1.y}.max()!,50)
    XCTAssertLessThan(b.diagnostics.maximumVertexPenetrationMm,0.001)
    XCTAssertLessThan(b.diagnostics.maximumSurfacePenetrationMm,0.01)
    for pin in tangent.mesh.pins {XCTAssertEqual(b.frame.positionsMm[pin.vertex],pin.targetMm)}
    let report:[String:Any]=["unchanged_vertices":tangent.mesh.restPositionsMm.count,"unchanged_triangles":tangent.mesh.triangles.count,"unchanged_total_mass_kg":tangent.mesh.massesKg.reduce(0,+),"old_reset":try jsonObject(oldInitial.diagnostics),"tangent_reset":try jsonObject(newInitial.diagnostics),"old_first_step":try jsonObject(oldFirst),"tangent_first_step":try jsonObject(newFirst),"old_after_90_frames":try jsonObject(a.diagnostics),"tangent_after_90_frames":try jsonObject(b.diagnostics)]
    if let directory=ProcessInfo.processInfo.environment["FORM_ASSEMBLY_PROOF_DIR"] {try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:directory).appendingPathComponent("tangent-drape-comparison.json"))}
    b.reset();XCTAssertEqual(b.frame.positionsMm,resetPositions);XCTAssertEqual(b.status,.stopped)
  }
  func testOddResolutionKeepsItsExistingMaterialPinAndRecoversFiniteContacts()throws {
    for cells in [5,15,17] {
      let object=try Project(name:"Odd contact").makeObject(recipeID:"clothPanel",parameters:["resolution":Double(cells)]),study=try XCTUnwrap(object.cloth)
      var solver=try ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders)
      let pin=study.mesh.pins[0],r=object["supportRadius"]+study.settings.collisionThicknessMm/2,p=pin.targetMm
      XCTAssertEqual(p.x*p.x+(p.y-object["supportRadius"])*(p.y-object["supportRadius"])+p.z*p.z,r*r,accuracy:1e-7)
      try solver.start();try solver.advance()
      XCTAssertEqual(solver.frame.positionsMm[pin.vertex].x,pin.targetMm.x,accuracy:1e-9)
      XCTAssertEqual(solver.frame.positionsMm[pin.vertex].y,pin.targetMm.y,accuracy:1e-9)
      XCTAssertEqual(solver.frame.positionsMm[pin.vertex].z,pin.targetMm.z,accuracy:1e-9)
      XCTAssertLessThan(solver.diagnostics.maximumSurfacePenetrationMm,0.01)
      XCTAssertTrue(solver.diagnostics.maximumConstraintForceN.isFinite)
      solver.reset();XCTAssertEqual(solver.frame.positionsMm[pin.vertex].x,pin.targetMm.x,accuracy:1e-9)
      XCTAssertEqual(solver.frame.positionsMm[pin.vertex].y,pin.targetMm.y,accuracy:1e-9)
      XCTAssertEqual(solver.frame.positionsMm[pin.vertex].z,pin.targetMm.z,accuracy:1e-9)
    }
  }
  func testBeforeAfterResetAndComputedDrapeUseIdenticalRealMetalCamera()throws {
    guard let device=MTLCreateSystemDefaultDevice() else {throw XCTSkip("The paired cloth comparison requires offscreen Metal.")}
    let (old,tangent)=try comparison()
    for (name,study) in [("old",old),("tangent",tangent)] {
      var solver=try ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders)
      try render(study,frame:solver.frame,device:device,name:"drape-reset-\(name)")
      try solver.start();for _ in 0..<90 {try solver.advance()}
      try render(study,frame:solver.frame,device:device,name:"drape-computed-\(name)")
    }
  }
  private func render(_ study:ClothStudy,frame:ClothFrame,device:MTLDevice,name:String)throws {
    let material=SCNMaterial();material.diffuse.contents=NSColor(srgbRed:0.72,green:0.49,blue:0.24,alpha:1);material.roughness.contents=0.95
    let surface=try ClothSurface(mesh:study.mesh,frame:frame,material:material),scene=SCNScene()
    scene.background.contents=NSColor(white:0.92,alpha:1);scene.rootNode.addChildNode(surface.node)
    for c in study.colliders where c.kind == .sphere {
      let sphere=SCNNode(geometry:SCNSphere(radius:c.radiusMm/100));sphere.position=SCNVector3(c.centerMm.x/100,c.centerMm.y/100,c.centerMm.z/100);sphere.geometry?.firstMaterial?.diffuse.contents=NSColor(white:0.3,alpha:1);scene.rootNode.addChildNode(sphere)
    }
    let floor=SCNNode(geometry:SCNPlane(width:6,height:6));floor.eulerAngles.x = -.pi/2;floor.geometry?.firstMaterial?.diffuse.contents=NSColor(white:0.83,alpha:1);scene.rootNode.addChildNode(floor)
    let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.usesOrthographicProjection=true;camera.camera?.orthographicScale=2.2;camera.position=SCNVector3(3,3.4,4);camera.look(at:SCNVector3(0,0.8,0));scene.rootNode.addChildNode(camera)
    let key=SCNNode();key.light=SCNLight();key.light?.type = .omni;key.light?.intensity=1400;key.position=SCNVector3(-3,6,4);scene.rootNode.addChildNode(key)
    let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=380;scene.rootNode.addChildNode(ambient)
    let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
    let image=renderer.snapshot(atTime:0,with:.init(width:1100,height:900),antialiasingMode:.multisampling4X),bitmap=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation))),png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
    XCTAssertGreaterThan(png.count,10000)
    if let directory=ProcessInfo.processInfo.environment["FORM_ASSEMBLY_PROOF_DIR"] {try png.write(to:URL(fileURLWithPath:directory).appendingPathComponent(name+".png"))}
  }
}

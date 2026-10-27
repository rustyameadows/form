import AppKit
import FormGeometry
import Metal
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

final class ClothSurfaceMappingTests:XCTestCase {
  func testMaterialAnchorFollowsTriangleWithoutAutoFittingOrLosingPhysicalOffset()throws {
    var mesh=try ClothMeshes.rectangle(widthMm:240,heightMm:200,columns:6,rows:5,areaDensityKgPerM2:0.2)
    mesh.pins=[.init(0,targetMm:mesh.restPositionsMm[0]),.init(6,targetMm:mesh.restPositionsMm[6])]
    var solver=try ClothSolver(mesh:mesh)
    let anchor=ClothSurfaceAnchor(triangle:36,weights:.init(0.2,0.3,0.5),normalOffsetMm:1.5),initial=try anchor.placement(mesh:mesh,frame:solver.frame)
    try solver.start();for _ in 0..<30 {try solver.advance()}
    let frame=solver.frame,placed=try anchor.placement(mesh:mesh,frame:frame),t=mesh.triangles[36]
    let x=frame.positionsMm[t.a],y=frame.positionsMm[t.b],z=frame.positionsMm[t.c]
    XCTAssertEqual(placed.positionMm.x,x.x*0.2+y.x*0.3+z.x*0.5+placed.normal.x*1.5,accuracy:1e-9)
    XCTAssertEqual(placed.positionMm.y,x.y*0.2+y.y*0.3+z.y*0.5+placed.normal.y*1.5,accuracy:1e-9)
    XCTAssertLessThan(placed.positionMm.y,initial.positionMm.y-20)
    XCTAssertEqual(placed.normal.x*placed.materialTangent.x+placed.normal.y*placed.materialTangent.y+placed.normal.z*placed.materialTangent.z,0,accuracy:1e-9)
    let bounds=try ClothBounds(positionsMm:frame.positionsMm)
    for p in frame.positionsMm {XCTAssertTrue(p.x>=bounds.minimumMm.x && p.x<=bounds.maximumMm.x && p.y>=bounds.minimumMm.y && p.y<=bounds.maximumMm.y)}
    XCTAssertThrowsError(try ClothSurfaceAnchor(triangle:0,weights:.init(-0.1,0.6,0.5)).placement(mesh:mesh,frame:frame))
    XCTAssertThrowsError(try ClothSurfaceAnchor(triangle:9000,weights:.init(1,0,0)).placement(mesh:mesh,frame:frame))
  }
  func testSeamedSidesKeepDistinctTopologyAndOutwardNormals()throws {
    let mesh=try ClothMeshes.seamedPanels(widthMm:220,heightMm:200,columns:6,rows:6,areaDensityKgPerM2:0.2),solver=try ClothSolver(mesh:mesh),half=mesh.triangles.count/2
    let front=try ClothSurfaceAnchor(triangle:0,weights:.init(1,0,0)).placement(mesh:mesh,frame:solver.frame),back=try ClothSurfaceAnchor(triangle:half,weights:.init(1,0,0)).placement(mesh:mesh,frame:solver.frame)
    XCTAssertEqual(front.normal.z,1,accuracy:1e-12);XCTAssertEqual(back.normal.z,-1,accuracy:1e-12)
    XCTAssertEqual(front.positionMm.z-back.positionMm.z,60,accuracy:1e-12)
    XCTAssertEqual(front.materialTangent.x,1,accuracy:1e-12);XCTAssertEqual(back.materialTangent.x,-1,accuracy:1e-12)
  }
}

@MainActor final class ClothSurfaceTests:XCTestCase {
  func testGeometryKeepsPhysicalScaleMaterialUVAndTopologyAcrossFrames()throws {
    let mesh=try ClothMeshes.rectangle(widthMm:240,heightMm:200,columns:6,rows:5,areaDensityKgPerM2:0.2)
    var solver=try ClothSolver(mesh:mesh)
    let material=MeshMaterial();material.diffuse.contents=NSColor.orange;material.roughness.contents=0.87;material.diffuse.wrapS = .repeat
    let surface=try ClothSurface(mesh:mesh,frame:solver.frame,material:material),first=try XCTUnwrap(surface.node.geometry),uv=try XCTUnwrap(first.sources(for:.texcoord).first),element=try XCTUnwrap(first.elements.first)
    surface.node.position=MeshVector3(3,4,5);try solver.start();try solver.advance(frames:3);try surface.update(solver.frame)
    let next=try XCTUnwrap(surface.node.geometry)
    XCTAssertTrue(next.sources(for:.texcoord).first === uv);XCTAssertTrue(next.elements.first === element)
    XCTAssertTrue(next.materials.first === surface.material);XCTAssertFalse(surface.material === material)
    XCTAssertEqual(surface.material.diffuse.wrapS,.repeat);XCTAssertEqual(surface.material.roughness.contents as? Double,0.87)
    XCTAssertEqual(surface.node.position.x,3);XCTAssertEqual(surface.node.position.y,4);XCTAssertEqual(surface.node.position.z,5)
    XCTAssertEqual(Double(next.boundingBox.max.x-next.boundingBox.min.x)*100,240,accuracy:0.001)
    XCTAssertEqual(surface.bounds.minimumMm.y,solver.frame.positionsMm.map(\.y).min()!)
    var bad=solver.frame;bad.positionsMm[0].x = .nan
    XCTAssertThrowsError(try surface.update(bad));XCTAssertTrue(surface.node.geometry === next)
    bad=solver.frame;bad.positionsMm[0].x = 1e100;XCTAssertThrowsError(try surface.update(bad));XCTAssertTrue(surface.node.geometry === next)
    bad=solver.frame;bad.normals[0].x = 1e100;XCTAssertThrowsError(try surface.update(bad));XCTAssertTrue(surface.node.geometry === next)
  }
  func testComputedDrapeProducesNativeRealityKitProof()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else {throw XCTSkip("Offscreen native cloth render needs Metal.")}
    var mesh=try ClothMeshes.rectangle(widthMm:320,heightMm:300,columns:16,rows:16,areaDensityKgPerM2:0.22,originMm:.init(0,125,0))
    mesh.pins=[.init(8*17+8,targetMm:.init(0,70.4,0))]
    var settings=ClothSettings();settings.substeps=8;settings.iterations=6;settings.velocityDampingPerSecond=1.5
    var solver=try ClothSolver(mesh:mesh,settings:settings,colliders:[.sphere(centerMm:.init(),radiusMm:70),.plane(pointMm:.init(0,-90,0))])
    try solver.start();for _ in 0..<90 {try solver.advance()}
    let imageContext=try XCTUnwrap(CGContext(data:nil,width:512,height:512,bitsPerComponent:8,bytesPerRow:512*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    imageContext.setFillColor(CGColor(red:0.69,green:0.49,blue:0.24,alpha:1));imageContext.fill(.init(x:0,y:0,width:512,height:512))
    imageContext.setStrokeColor(CGColor(red:0.9,green:0.8,blue:0.57,alpha:0.4));imageContext.setLineWidth(1)
    for index in 0...16 {let coordinate=Double(index)*32;imageContext.move(to:.init(x:coordinate,y:0));imageContext.addLine(to:.init(x:coordinate,y:512));imageContext.move(to:.init(x:0,y:coordinate));imageContext.addLine(to:.init(x:512,y:coordinate))};imageContext.strokePath()
    imageContext.setFillColor(CGColor(red:0.08,green:0.16,blue:0.2,alpha:1));imageContext.fill(.init(x:0,y:120,width:512,height:64))
    let text=NSAttributedString(string:"FORM  /  320 × 300 mm",attributes:[.font:NSFont.systemFont(ofSize:21,weight:.semibold),.foregroundColor:NSColor.white])
    imageContext.textPosition = .init(x:48,y:143);CTLineDraw(CTLineCreateWithAttributedString(text),imageContext)
    let texture=NSImage(cgImage:try XCTUnwrap(imageContext.makeImage()),size:.init(width:512,height:512))
    let material=MeshMaterial();material.diffuse.contents=texture;material.roughness.contents=0.95
    let surface=try ClothSurface(mesh:mesh,frame:solver.frame,material:material),scene=MeshScene()
    scene.background.contents=NSColor(calibratedWhite:0.92,alpha:1);scene.rootNode.addChildNode(surface.node)
    let ball=MeshNode(geometry:MeshSphere(radius:0.7));ball.geometry?.firstMaterial?.diffuse.contents=NSColor(calibratedWhite:0.27,alpha:1);scene.rootNode.addChildNode(ball)
    let floor=MeshNode(geometry:MeshPlane(width:7,height:7));floor.eulerAngles.x = -.pi/2;floor.position.y = -0.9;floor.geometry?.firstMaterial?.diffuse.contents=NSColor(calibratedWhite:0.8,alpha:1);scene.rootNode.addChildNode(floor)
    let camera=MeshNode();camera.camera=MeshCamera();camera.camera?.usesOrthographicProjection=true;camera.camera?.orthographicScale=2.2;camera.position=MeshVector3(3,2.5,4);camera.look(at:MeshVector3(0,-0.1,0));scene.rootNode.addChildNode(camera)
    let key=MeshNode();key.light=MeshLight();key.light?.type = .omni;key.light?.intensity=1300;key.position=MeshVector3(-3,5,4);scene.rootNode.addChildNode(key)
    let ambient=MeshNode();ambient.light=MeshLight();ambient.light?.type = .ambient;ambient.light?.intensity=350;scene.rootNode.addChildNode(ambient)
    let image=try await GeometryRenderingProof.capture(scene,camera:camera,size:.init(width:1400,height:1100))
    let tiff=try XCTUnwrap(image.tiffRepresentation),rep=try XCTUnwrap(NSBitmapImageRep(data:tiff)),png=try XCTUnwrap(rep.representation(using:.png,properties:[:]))
    XCTAssertGreaterThan(png.count,10000)
    if let directory=ProcessInfo.processInfo.environment["FORM_CLOTH_PROOF_DIR"] {
      let root=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try png.write(to:root.appendingPathComponent("native-cloth-drape.png"))
    }
  }
}

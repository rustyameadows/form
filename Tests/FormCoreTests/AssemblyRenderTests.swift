import AppKit
import FormGeometry
import Metal
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class AssemblyRenderTests:XCTestCase {
  func testActualSolvedCurvedPouchUsesPerPanelPhysicalMaterialsOnRealMetal()async throws {
    guard let device=MTLCreateSystemDefaultDevice() else {throw XCTSkip("The actual curved-pouch surface proof requires Metal.")}
    let (project,definition)=try PatternAssemblySamples.roundedPouch(),product=try PatternAssemblyGenerator.generate(definition,in:project)
    let source=project.objects[0].artwork!,assets=FileManager.default.temporaryDirectory
    let materials=try Dictionary(uniqueKeysWithValues:product.panels.map {($0.panelIndex,try AssemblyMaterialRenderer.material(panel:$0,source:source,project:project,assets:assets,fontRevision:0))})
    var solver=try ClothSolver(mesh:product.study.mesh,settings:product.study.settings,colliders:product.study.colliders,preparation:product.study.preparation)
    let surface=try ClothSurface(mesh:product.study.mesh,frame:solver.frame,panelMaterials:materials,fallbackMaterial:MeshMaterial()),scene=MeshScene()
    scene.background.contents=NSColor(white:0.93,alpha:1);scene.rootNode.addChildNode(surface.node)
    let floor=MeshNode(geometry:MeshPlane(width:7,height:7));floor.eulerAngles.x = -.pi/2;floor.geometry?.firstMaterial?.diffuse.contents=NSColor(white:0.87,alpha:1);scene.rootNode.addChildNode(floor)
    let camera=MeshNode();camera.camera=MeshCamera();camera.camera?.usesOrthographicProjection=true;camera.camera?.orthographicScale=1.8;camera.camera?.zNear=0.01;camera.camera?.zFar=100;scene.rootNode.addChildNode(camera)
    let key=MeshNode();key.light=MeshLight();key.light?.type = .omni;key.light?.intensity=1400;key.position=MeshVector3(-3,6,5);scene.rootNode.addChildNode(key)
    let ambient=MeshNode();ambient.light=MeshLight();ambient.light?.type = .ambient;ambient.light?.intensity=600;scene.rootNode.addChildNode(ambient)
    camera.position=MeshVector3(2.5,3.0,5);camera.look(at:MeshVector3(0,1.5,0))
    try await proof(scene,camera:camera,device:device,"curved-pouch-initial",frame:solver.frame,product:product)
    try solver.start();try finishAssemblyPreparation(&solver);for _ in 0..<240 {try solver.advance()};try surface.update(solver.frame)
    XCTAssertLessThan(solver.diagnostics.maximumSeamGapMm,3)
    try await proof(scene,camera:camera,device:device,"curved-pouch-computed",frame:solver.frame,product:product)
    camera.position=MeshVector3(0,1.6,5);camera.eulerAngles=MeshVector3Zero
    try await proof(scene,camera:camera,device:device,"curved-pouch-front",frame:solver.frame,product:product)
    camera.position=MeshVector3(0,1.6,-5);camera.eulerAngles=MeshVector3(0,Double.pi,0)
    key.position=MeshVector3(3,6,-5)
    try await proof(scene,camera:camera,device:device,"curved-pouch-back",frame:solver.frame,product:product)
  }
  private func proof(_ scene:MeshScene,camera:MeshNode,device:MTLDevice,_ name:String,frame:ClothFrame,product:PatternAssemblyProduct)async throws {
    let image=try await GeometryRenderingProof.capture(scene,camera:camera,size:.init(width:1300,height:1100)),bitmap=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation))),png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
    XCTAssertGreaterThan(png.count,10000)
    if let directory=ProcessInfo.processInfo.environment["FORM_ASSEMBLY_PROOF_DIR"] {
      let root=URL(fileURLWithPath:directory);try png.write(to:root.appendingPathComponent(name+".png"))
      if name=="curved-pouch-computed" {
        let report:[String:Any]=["positions_mm":try jsonObject(frame.positionsMm),"normals":try jsonObject(frame.normals),"diagnostics":try jsonObject(frame.diagnostics),"source_digest":product.sourceDigest,"runtime_persisted":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("curved-pouch-computed.json"))
      }
    }
  }
}

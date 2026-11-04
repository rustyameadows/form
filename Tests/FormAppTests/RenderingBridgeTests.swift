import AppKit
import FormGeometry
import XCTest
@testable import FormApp

@MainActor final class RenderingBridgeTests:XCTestCase {
  func testSamplerOnlyEditsReachRendererAndInvalidateMaterialsWithoutRebuildingPhysicalMesh()throws {
    let scene=MeshScene(),adapter=GeometryPayloadAdapter(),owner=MeshNode(),material=MeshMaterial()
    owner.name="object:"+UUID().uuidString
    let plane=MeshNode(geometry:MeshPlane(width:1,height:1));plane.geometry!.materials=[material];owner.addChildNode(plane);scene.rootNode.addChildNode(owner)
    let image=NSImage(size:.init(width:2,height:2));image.lockFocus();NSColor.red.setFill();NSRect(x:0,y:0,width:2,height:2).fill();image.unlockFocus()
    material.diffuse.contents=image;material.diffuse.minificationFilter = .nearest;material.diffuse.magnificationFilter = .nearest;material.diffuse.mipFilter = .none;material.diffuse.maxAnisotropy=4
    material.normal.contents=image;material.normal.maxAnisotropy=8
    let before=try XCTUnwrap(adapter.renderables(scene:scene).first),texture=try XCTUnwrap(before.materials[0].baseColorTexture)
    XCTAssertEqual(texture.sampling.minification,.nearest);XCTAssertEqual(texture.sampling.magnification,.nearest);XCTAssertEqual(texture.sampling.mip,.none);XCTAssertEqual(texture.sampling.maximumAnisotropy,4)
    XCTAssertEqual(before.materials[0].normalTexture?.sampling.maximumAnisotropy,8)
    material.diffuse.minificationFilter = .linear;material.diffuse.magnificationFilter = .linear;material.diffuse.mipFilter = .linear;material.diffuse.maxAnisotropy=16
    let after=try XCTUnwrap(adapter.renderables(scene:scene).first)
    XCTAssertEqual(after.mesh.id,before.mesh.id);XCTAssertEqual(after.mesh.revision,before.mesh.revision)
    XCTAssertEqual(after.materials[0].baseColorTexture?.revision,texture.revision)
    XCTAssertNotEqual(after.materials[0].revision,before.materials[0].revision,"A sampler-only edit must not retain a cached material with old filtering.")
    XCTAssertEqual(after.materials[0].baseColorTexture?.sampling.maximumAnisotropy,16)
  }
  func testDeletingUnrelatedObjectsAndChangingAppearanceKeepSemanticComponentsAndMeshResources()throws {
    let scene=MeshScene(),adapter=GeometryPayloadAdapter(),firstID=UUID(),survivorID=UUID()
    let first=MeshNode(),survivor=MeshNode(),material=MeshMaterial()
    first.name="object:"+firstID.uuidString;survivor.name="object:"+survivorID.uuidString
    let a=MeshNode(geometry:MeshBox(width:1,height:1,length:1,chamferRadius:0))
    let b=MeshNode(geometry:MeshBox(width:2,height:1,length:1,chamferRadius:0));b.name="Case shell"
    material.diffuse.contents=NSColor.red;b.geometry!.materials=[material]
    first.addChildNode(a);survivor.addChildNode(b);scene.rootNode.addChildNode(first);scene.rootNode.addChildNode(survivor)
    let initial=try XCTUnwrap(adapter.renderables(scene:scene).first{$0.objectID==survivorID})
    first.removeFromParentNode();survivor.position.x=3;material.diffuse.contents=NSColor.blue
    let next=try XCTUnwrap(adapter.renderables(scene:scene).first{$0.objectID==survivorID})
    XCTAssertEqual(next.componentID,initial.componentID)
    XCTAssertTrue(next.componentID.contains(survivorID.uuidString));XCTAssertTrue(next.componentID.contains("Case shell"))
    XCTAssertEqual(next.mesh.id,initial.mesh.id);XCTAssertEqual(next.mesh.revision,initial.mesh.revision)
    XCTAssertEqual(next.mesh.positionsMM,initial.mesh.positionsMM)
    XCTAssertNotEqual(next.materials[0].revision,initial.materials[0].revision)
    XCTAssertEqual(next.transform.translationMM.x,300,accuracy:1e-10)
    let detail=MeshNode(geometry:MeshPlane(width:0.2,height:0.2));detail.name="Additional detail"
    survivor.addChildNode(detail)
    let expanded=try XCTUnwrap(adapter.renderables(scene:scene).first{$0.componentID==next.componentID})
    XCTAssertEqual(expanded.mesh.revision,next.mesh.revision)
  }
}

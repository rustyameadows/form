import AppKit
import FormGeometry
import XCTest
@testable import FormApp

@MainActor final class RenderingBridgeTests:XCTestCase {
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

import AppKit
import CryptoKit
import ImageIO
import FormGeometry
import FormCore
import FormCADModel
import LabRendering
import simd
import XCTest
@testable import FormApp

@MainActor final class RenderingBridgeTests:XCTestCase {
  func testPhysicalSourceReuseAcrossSurfacesBacksAndLayersRevalidatesChangedOrMissingFiles()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("physical-resource-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
    func png(_ component:UInt8)throws->Data {
      let values=Data([component,component,component,255])
      let image=try XCTUnwrap(CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:CGDataProvider(data:values as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
      let data=NSMutableData(),writer=try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
      CGImageDestinationAddImage(writer,image,nil);XCTAssertTrue(CGImageDestinationFinalize(writer));return data as Data
    }
    let original=try png(64),path=root.appendingPathComponent("map.png"),alias=root.appendingPathComponent("equal.png")
    try original.write(to:path);try original.write(to:alias)
    let digest=SHA256.hash(data:original).map{String(format:"%02x",$0)}.joined()
    let scene=MeshScene(),adapter=GeometryPayloadAdapter()
    let texture=MeshPhysicalTexture(url:path,assetName:path.lastPathComponent,sha256:digest,encoding:.data,uvIndex:0,wrapS:.repeat,wrapT:.mirror,scale:.init(2,3),offset:.init(0.2,0.1),rotationDegrees:25)
    for index in 0..<3 {
      let material=MeshMaterial(),node=MeshNode(geometry:MeshPlane(width:1,height:1));node.name="surface-\(index)"
      var response=MeshPhysicalAppearance(),binding=texture
      binding.url=index==1 ? alias:path;binding.scale.x=Double(index+1)
      response.textures["roughness"]=binding;material.physicalAppearance=response;material.physicalThicknessMM=0.2
      let mask=MeshMaterialProperty();mask.contents=try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(original as CFData,nil)!,0,nil))
      material.physicalLayers=[.init(mask:mask,appearance:response)]
      node.geometry!.materials=[material];scene.rootNode.addChildNode(node)
    }
    let first=try adapter.pathTracingRenderables(scene:scene,assets:root)
    let maps=first.flatMap{$0.materials}.compactMap{$0.physicalAppearance?.textures[.roughness]}
    XCTAssertEqual(maps.count,6,"Three front/back pairs must share the source without losing their surfaces.")
    let shared=try XCTUnwrap(maps.first?.image)
    XCTAssertTrue(maps.allSatisfy{$0.image === shared});XCTAssertEqual(maps[2].scale.x,2)
    XCTAssertTrue(first.flatMap{$0.materials}.flatMap(\.physicalLayers).allSatisfy{$0.appearance?.textures[.roughness]?.image === shared})
    // A warm decoded cache is not proof that the pathname still contains the
    // saved bytes. Reject same-path replacement before preparing a new scene.
    let replacement=try png(192);try replacement.write(to:path)
    XCTAssertThrowsError(try adapter.pathTracingRenderables(scene:scene,assets:root))
    let changed=SHA256.hash(data:replacement).map{String(format:"%02x",$0)}.joined()
    var newAppearance=MeshPhysicalAppearance(),newTexture=texture;newTexture.sha256=changed;newAppearance.textures["roughness"]=newTexture
    let refreshed=try GeometryPayloadAdapter.physicalPayload(newAppearance,assets:root)
    XCTAssertFalse(try XCTUnwrap(refreshed.textures[.roughness]?.image) === shared)
    XCTAssertEqual(refreshed.textures[.roughness]?.revision,changed)
    try FileManager.default.removeItem(at:path)
    XCTAssertThrowsError(try GeometryPayloadAdapter.physicalPayload(newAppearance,assets:root))
  }
  func testPhysicalFinishMapsAndFactorsSurviveCopiesWithoutChangingFastChannels()throws {
    let scene=MeshScene(),owner=MeshNode(),adapter=GeometryPayloadAdapter(),material=MeshMaterial()
    owner.name="object:"+UUID().uuidString;scene.rootNode.addChildNode(owner)
    let node=MeshNode(geometry:MeshPlane(width:1,height:1));owner.addChildNode(node)
    let mask=MeshMaterialProperty();mask.contents=NSImage(size:.init(width:1,height:1),flipped:false){rect in NSColor.white.setFill();rect.fill();return true}
    material.roughness.contents=0.42;material.metalness.contents=0.6
    material.physicalRoughness.contents=0.8;material.physicalMetalness.contents=0.0
    material.physicalLayers=[.init(mask:mask,roughness:0.18,metallic:1)]
    let copy=try XCTUnwrap(material.copy() as? MeshMaterial);node.geometry!.materials=[copy]
    let fast=try XCTUnwrap(adapter.renderables(scene:scene).first?.materials.first)
    let physical=try XCTUnwrap(adapter.pathTracingRenderables(scene:scene,assets:FileManager.default.temporaryDirectory).first?.materials.first)
    XCTAssertEqual(fast.roughness,0.42,accuracy:1e-6);XCTAssertEqual(fast.metallic,0.6,accuracy:1e-6)
    XCTAssertEqual(physical.roughness,0.8,accuracy:1e-6);XCTAssertEqual(physical.metallic,0)
    let layer=try XCTUnwrap(physical.physicalLayers.first)
    XCTAssertNil(layer.appearance);XCTAssertEqual(layer.roughness,0.18);XCTAssertEqual(layer.metallic,1)
    XCTAssertFalse(copy.physicalRoughness === material.physicalRoughness)
    copy.physicalValidationIssue="The physical closure layer budget was exceeded."
    XCTAssertFalse(adapter.renderables(scene:scene).isEmpty)
    XCTAssertThrowsError(try adapter.pathTracingRenderables(scene:scene,assets:FileManager.default.temporaryDirectory))
  }
  func testPhysicalTexturesRetainIndependentMirroredMappingsAndDataEncoding()throws {
    let scene=MeshScene(),adapter=GeometryPayloadAdapter(),owner=MeshNode(),material=MeshMaterial()
    owner.name="object:"+UUID().uuidString;scene.rootNode.addChildNode(owner)
    let node=MeshNode(geometry:MeshPlane(width:1,height:1));owner.addChildNode(node)
    let image=NSImage(size:.init(width:4,height:4),flipped:false){rect in NSColor.red.setFill();rect.fill();return true}
    material.diffuse.contents=image;material.normal.contents=image
    var response=MeshPhysicalAppearance();response.normalStrength=0.35;material.physicalAppearance=response
    var colorMap=matrix_identity_double4x4;colorMap[0,0] = -2;colorMap[1,1]=3;colorMap[3,0]=0.25
    var normalMap=matrix_identity_double4x4;normalMap[0,0]=0;normalMap[0,1]=4;normalMap[1,0] = -5;normalMap[1,1]=0;normalMap[3,1]=0.1
    material.diffuse.contentsTransform = .init(colorMap);material.normal.contentsTransform = .init(normalMap)
    material.diffuse.minificationFilter = .nearest;material.normal.maxAnisotropy=8
    node.geometry!.materials=[material]
    let payload=try XCTUnwrap(adapter.pathTracingRenderables(scene:scene,assets:FileManager.default.temporaryDirectory).first)
    XCTAssertEqual(payload.materials.first?.physicalAppearance?.normalStrength,0.35)
    let color=try XCTUnwrap(payload.materials.first?.baseColorTexture),normal=try XCTUnwrap(payload.materials.first?.normalTexture)
    func point(_ p:SceneTexturePayload)->SIMD2<Double> {
      let uv=SIMD2<Double>(0.2,0.3)*p.scale,theta=p.rotationDegrees * .pi/180
      return .init(uv.x*cos(theta)-uv.y*sin(theta)+p.offset.x,uv.x*sin(theta)+uv.y*cos(theta)+p.offset.y)
    }
    XCTAssertEqual(point(color).x,-0.15,accuracy:1e-8);XCTAssertEqual(point(color).y,0.9,accuracy:1e-8)
    XCTAssertEqual(point(normal).x,-1.5,accuracy:1e-8);XCTAssertEqual(point(normal).y,0.9,accuracy:1e-8)
    XCTAssertEqual(color.encoding,.srgb);XCTAssertEqual(normal.encoding,.data)
    XCTAssertEqual(color.sampling.minification,.nearest);XCTAssertEqual(normal.sampling.maximumAnisotropy,8)
    XCTAssertEqual(material.diffuse.contentsTransform.raw,colorMap)
    var shear=colorMap;shear[1,0]=0.5;material.diffuse.contentsTransform = .init(shear)
    XCTAssertThrowsError(try adapter.pathTracingRenderables(scene:scene,assets:FileManager.default.temporaryDirectory))
  }
  func testIndependentPieceOpticsCalipersAndStudioPoseReachPhysicalSnapshot()async throws {
    _=NSApplication.shared
    func panel(_ id:String,_ x:Double)->PlanarPanelDefinition {
      .init(id:id,name:id,polygon:[.init(CADScalar(x),0),.init(CADScalar(x+20),0),.init(CADScalar(x+20),20),.init(CADScalar(x),20)])
    }
    func stock(_ thickness:Double,_ color:String,_ coat:Double,_ edge:Double)->PaperStock {
      var profile=PaperSurfaceProfile(texture:.smooth,color:color,textureDepthMM:0)
      profile.appearance=PhysicalAppearance();profile.appearance?.coat=coat
      profile.edgeAppearance=PhysicalAppearance();profile.edgeAppearance?.sheen=edge
      return .init(thicknessMM:thickness,profile:profile)
    }
    let definition=PlanarConstructionDefinition(name:"Independent optical surfaces",size:.init(50,20),stockThickness:2,
      panels:[panel("first",0),panel("second",30)],rootPanelID:"first",components:[
        .init(id:"thick",name:"Thick",rootPanelID:"first",anchor:.init(0,0),position:.init(0,1,0),rotationDegrees:.init(-90,0,0),groupID:"frame",stock:stock(2,"#AA3322",0.2,0.3)),
        .init(id:"thin",name:"Thin",rootPanelID:"second",anchor:.init(30,0),position:.init(30,0.2,0),rotationDegrees:.init(-90,0,0),groupID:"frame",stock:stock(0.4,"#2233AA",0.7,0.6))],
      groups:[.init(id:"frame",name:"Pose frame",position:.init("opening/2","explosion/3",0))])
    var owner=ProductObject(name:"Independent source",recipeID:"box",parameters:[:],materialID:"paper")
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:50,height:20,depth:2),stock:.init(thicknessMM:2),explosionPercent:0)
    paper.authored=definition;owner.paperConstruction=paper
    var project=Project(name:"Physical bridge integration");project.objects=[owner]
    let before=project,controller=TableSceneController(),assets=FileManager.default.temporaryDirectory
    controller.sync(project,selection:[],isolated:[],showGrid:false,studio:false,preset:"Paper",assets:assets)
    let original=try await controller.cyclesSnapshot(settings:.init())
    func face(_ snapshot:SceneSnapshot,_ id:String,_ ownerID:UUID)throws->SceneRenderablePayload {
      try XCTUnwrap(snapshot.renderables.first{$0.objectID==ownerID && $0.componentID.hasSuffix("/paper.panel:"+id)})
    }
    let first=try face(original,"first",owner.id),second=try face(original,"second",owner.id)
    XCTAssertEqual(first.materials[0].physicalAppearance?.coat,0.2)
    XCTAssertEqual(second.materials[0].physicalAppearance?.coat,0.7)
    XCTAssertEqual(first.materials[2].physicalAppearance?.sheen,0.3)
    XCTAssertEqual(second.materials[2].physicalAppearance?.sheen,0.6)
    for (payload,caliper) in [(first,2.0),(second,0.4)] {
      XCTAssertEqual(payload.mesh.positionsMM.map(\.z).max()!-payload.mesh.positionsMM.map(\.z).min()!,caliper,accuracy:1e-8)
      XCTAssertEqual(payload.materials[0].baseColorTexture?.encoding,.srgb)
      XCTAssertEqual(payload.materials[0].normalTexture?.encoding,.data)
      XCTAssertEqual(payload.materials[0].normalTexture?.sampling.maximumAnisotropy,8)
    }
    var composition=StudioComposition(name:"Independent presentation",camera:project.camera)
    var instance=StudioInstance(name:"Posed source",sourceObjectID:owner.id,positionMM:.init(100,0,0))
    instance.paperPose = .init(openingPercent:40,explosionPercent:60);composition.instances=[instance]
    let derived=try composition.resolved(in:project)
    controller.sync(derived.project,selection:[],isolated:derived.visible,showGrid:false,studio:true,preset:"Paper",assets:assets,renderObjectIDs:derived.visible)
    let posed=try await controller.cyclesSnapshot(settings:.init())
    let result=try face(posed,"first",instance.id)
    XCTAssertEqual(result.transform.translationMM.x-first.transform.translationMM.x,120,accuracy:1e-8)
    XCTAssertEqual(result.transform.translationMM.y-first.transform.translationMM.y,20,accuracy:1e-8)
    XCTAssertEqual(result.mesh.positionsMM,first.mesh.positionsMM)
    XCTAssertEqual(result.materials[0].physicalAppearance?.coat,0.2)
    XCTAssertFalse(posed.renderables.contains{$0.objectID==owner.id},"Studio lookup-only originals must not duplicate the physical instance.")
    XCTAssertTrue(project==before,"A scene pose must preserve its authored source document.")
  }
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

// Reproducible offscreen acceptance harness. Build with the actual MeshAssetSceneAdapter.swift,
// FormMeshAssets and LabRendering modules; see docs/mesh-interchange.md. No library writes or hardware.
import AppKit
import CoreText
import Foundation
import FormMeshAssets
import ImageIO
import LabRendering
import simd

@main struct BlenderFidelity {
  @MainActor static func main()async throws {
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    let directory=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true),url=directory.appendingPathComponent("LAB-Blender-flight-jacket.glb")
    let start=Date(),document=try await Task.detached{try GLTFImporter.importFile(url)}.value
    var reference=MeshAssetReference(document:document,sourceAsset:url.lastPathComponent,normalizedAsset:"acceptance.mesh.json",normalizedSHA256:document.provenance.sourceSHA256)
    let prepared=try await Task.detached{try MeshAssetSceneAdapter.prepare(document:document,reference:reference)}.value
    let renderer=try RealityKitSceneRenderer(frame:.init(x:0,y:0,width:1200,height:1000)),id=UUID(uuidString:"FBFBA5E4-AB6B-48A4-AECF-9DE8DF3FB819")!
    let offset=ModelAssetCoordinator.sourceToTableOffset(reference).simd
    let manifest=try JSONDecoder().decode(SourceManifest.self,from:Data(contentsOf:directory.appendingPathComponent("LAB-Blender-flight-jacket-manifest.json")))
    func point(_ v:[Double])throws->SIMD3<Double> {guard v.count==3 else{throw MeshAssetError.invalid("Source camera needs XYZ coordinates")};return .init(v[0],v[1],v[2])}
    let camera=SceneCameraPayload.looking(from:try point(manifest.camera.from)*1000+offset,at:try point(manifest.camera.target)*1000+offset,up:try point(manifest.camera.up),projection:.orthographic(verticalSpanMM:manifest.camera.height*1000))
    try renderer.setCamera(camera);try renderer.setLighting(.init(background:.init(0.45,0.46,0.48,1),keyIntensity:Float(ProcessInfo.processInfo.environment["LAB_FIDELITY_KEY"] ?? "3000") ?? 3000,fillIntensity:Float(ProcessInfo.processInfo.environment["LAB_FIDELITY_FILL"] ?? "600") ?? 600))
    func write(_ image:CGImage,_ name:String)throws {
      let path=directory.appendingPathComponent(name),destination=CGImageDestinationCreateWithURL(path as CFURL,"public.png" as CFString,1,nil)!
      CGImageDestinationAddImage(destination,image,nil);guard CGImageDestinationFinalize(destination) else{throw MeshAssetError.invalid("Could not save acceptance render.")}
    }
    func report()->[String:Any] {let d=renderer.diagnostics;return ["mesh_builds":d.meshBuilds,"material_builds":d.materialBuilds,"texture_uploads":d.textureUploads,"components":d.componentCount,"mesh_cache_bytes":d.meshCacheBytes,"texture_cache_bytes":d.textureCacheBytes,"capture_ms":d.lastCaptureMilliseconds,"warnings":d.warnings]}
    let source=try await Task.detached{try MeshAssetSceneAdapter.appearance(prepared,reference:reference)}.value
    let payloads=MeshAssetSceneAdapter.renderables(source,objectID:id)
    for payload in payloads {try await renderer.upsertAsync(payload)}
    try write(try await renderer.capture(width:1200,height:1000),"LAB-RealityKit-jacket-source.png")
    let baseline=report(),builds=renderer.diagnostics.meshBuilds
    let shell=try unwrap(reference.materials.first{$0.name.contains("midnight shell")})
    reference.materialOverrides=[.init(materialIndex:shell.index,colorHex:"#C56836",roughness:0.7)]
    let colorway=try await Task.detached{try MeshAssetSceneAdapter.appearance(prepared,reference:reference)}.value
    for payload in MeshAssetSceneAdapter.renderables(colorway,objectID:id) {try renderer.upsert(payload)}
    guard renderer.diagnostics.meshBuilds==builds else{throw MeshAssetError.invalid("Colorway unexpectedly rebuilt geometry.")}
    try write(try await renderer.capture(width:1200,height:1000),"LAB-RealityKit-jacket-colorway.png")
    let colorwayReport=report()
    reference.materialOverrides=[.init(materialIndex:shell.index,colorHex:"#32483B",roughness:0.7)]
    let green=try await Task.detached{try MeshAssetSceneAdapter.appearance(prepared,reference:reference)}.value
    for payload in MeshAssetSceneAdapter.renderables(green,objectID:id) {try renderer.upsert(payload)}
    guard renderer.diagnostics.meshBuilds==builds else{throw MeshAssetError.invalid("Green colorway unexpectedly rebuilt geometry.")}
    try write(try await renderer.capture(width:1200,height:1000),"LAB-RealityKit-jacket-colorway-green.png")
    let greenReport=report(),patch=try unwrap(reference.materials.first{$0.name.contains("orange woven patch")})
    reference.artworkBindings=[.init(materialIndex:patch.index)]
    let context=CGContext(data:nil,width:256,height:256,bitsPerComponent:8,bytesPerRow:1024,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed:0.96,green:0.89,blue:0.65,alpha:1));context.fill(.init(x:22,y:22,width:15,height:212));context.setStrokeColor(CGColor(srgbRed:0.96,green:0.89,blue:0.65,alpha:1));context.setLineWidth(6);context.strokeEllipse(in:.init(x:186,y:188,width:38,height:38))
    let artwork=context.makeImage()!,uv=try await Task.detached{try MeshAssetSceneAdapter.appearance(prepared,reference:reference,artwork:artwork,artworkRevision:"original-patch-design-v1")}.value
    let changed=zip(green.components,uv.components).filter{$0.material.revision != $1.material.revision}.map{$0.0.id}
    guard uv.components.filter({$0.material.baseColorTexture?.revision.contains("uv-composite")==true}).allSatisfy({component in reference.parts.first{$0.id==component.id}?.materialIndex==patch.index}) else{throw MeshAssetError.invalid("Patch artwork leaked to another material slot.")}
    for payload in MeshAssetSceneAdapter.renderables(uv,objectID:id) {try renderer.upsert(payload)}
    guard renderer.diagnostics.meshBuilds==builds else{throw MeshAssetError.invalid("UV artwork unexpectedly rebuilt geometry.")}
    try write(try await renderer.capture(width:1200,height:1000),"LAB-RealityKit-jacket-uv-patch.png")
    let uvReport=report()
    reference.materialOverrides=[];reference.artworkBindings=[]
    let restored=try await Task.detached{try MeshAssetSceneAdapter.appearance(prepared,reference:reference)}.value
    guard zip(source.components,restored.components).allSatisfy({$0.material.id==$1.material.id && $0.material.revision==$1.material.revision && $0.mesh.id==$1.mesh.id && $0.mesh.revision==$1.mesh.revision}) else{throw MeshAssetError.invalid("Clear did not restore exact source signatures.")}
    for payload in MeshAssetSceneAdapter.renderables(restored,objectID:id) {try renderer.upsert(payload)}
    try write(try await renderer.capture(width:1200,height:1000),"LAB-RealityKit-jacket-restored.png")
    var min=SIMD3<Double>(repeating:.infinity),max=SIMD3<Double>(repeating:-.infinity)
    for payload in payloads {for p in payload.mesh.positionsMM {let m=payload.transform.matrixMM,q=m*SIMD4<Double>(p,1);min=simd_min(min,.init(q.x,q.y,q.z));max=simd_max(max,.init(q.x,q.y,q.z))}}
    let summary:[String:Any]=["source_sha256":document.provenance.sourceSHA256,"vertices":document.vertexCount,"triangles":document.triangleCount,"parts":prepared.components.count,"materials":reference.materials.count,"textures":document.images.count,"display_bounds_mm":[[min.x,min.y,min.z],[max.x,max.y,max.z]],"source_bounds_size_mm":[reference.boundsMM.size.x,reference.boundsMM.size.y,reference.boundsMM.size.z],"baseline":baseline,"colorway":colorwayReport,"green_colorway":greenReport,"lighting_key":ProcessInfo.processInfo.environment["LAB_FIDELITY_KEY"] ?? "3000","lighting_fill":ProcessInfo.processInfo.environment["LAB_FIDELITY_FILL"] ?? "600","uv_patch":uvReport,"cleared":report(),"clear_restores_source_signatures":true,"uv_composite_parts":uv.components.filter{$0.material.baseColorTexture?.revision.contains("uv-composite")==true}.map(\.id),"material_revision_changes_for_patch":changed,"adapter_warnings":uv.warnings,"geometry_rebuilt_for_appearance":false,"total_seconds":Date().timeIntervalSince(start)]
    try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("LAB-RealityKit-jacket-fidelity.json"))
    print(String(decoding:try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
  }
  private struct SourceManifest:Decodable {
    struct Camera:Decodable {var from:[Double],target:[Double],up:[Double],height:Double;enum CodingKeys:String,CodingKey {case from,target,up;case height="orthographic_height_meter"}}
    var camera:Camera;enum CodingKeys:String,CodingKey {case camera="source_camera_gltf_meter"}
  }
  static func unwrap<T>(_ value:T?)throws->T {guard let value else{throw MeshAssetError.invalid("Expected fixture material missing")};return value}
}

// Pure anchoring shim only: the app coordinator is intentionally excluded from this isolated executable.
enum ModelAssetCoordinator {
  nonisolated static func sourceToTableOffset(_ reference:MeshAssetReference)->MeshPoint3 {.init(-(reference.boundsMM.minimum.x+reference.boundsMM.maximum.x)/2,-reference.boundsMM.minimum.y,-(reference.boundsMM.minimum.z+reference.boundsMM.maximum.z)/2)}
}

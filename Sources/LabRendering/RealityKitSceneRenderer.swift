import AppKit
import CoreGraphics
import Metal
import MetalKit
import RealityKit
import simd

/// RealityKit owns rendering. MetalKit supplies an AppKit viewport and explicit
/// render targets, allowing idle/demand drawing and exact-pixel Studio output.
@available(macOS 15.0, *)
@MainActor public final class RealityKitSceneRenderer: NSObject, FormSceneRenderer, MTKViewDelegate {
  public let viewport: MTKView
  public var nativeView: NSView {viewport}
  public private(set) var diagnostics=SceneRendererDiagnostics()
  public private(set) var camera=SceneCameraPayload()
  public private(set) var floatingOriginMM=SIMD3<Double>.zero
  private let device: any MTLDevice
  private let queue: any MTLCommandQueue
  private let rendered: RealityRenderer
  private let sceneRoot=Entity(),objectRoot=Entity(),cameraEntity=Entity()
  private let key=DirectionalLight(),fill=DirectionalLight(),environment=Entity()
  private static var studioEnvironment:EnvironmentResource?
  private let frameEvent: any MTLSharedEvent
  private var frameNumber:UInt64=0
  private var lighting=SceneLightingPayload()
  private struct MeshEntry {var resource:MeshResource;var originMM:SIMD3<Double>;var low:SIMD3<Double>;var high:SIMD3<Double>;var cost:Int}
  private struct Record {var payload:SceneRenderablePayload;var entity:ModelEntity;var mesh:MeshEntry;var materialKey:String;var selection:Entity?}
  private var records:[String:Record]=[:]
  private var meshCache:[String:MeshEntry]=[:],meshOrder:[String]=[]
  private var materialCache:[String:any RealityKit.Material]=[:],materialOrder:[String]=[]
  private var textureCache:[String:TextureResource]=[:],textureCosts:[String:Int]=[:],textureOrder:[String]=[]
  private var selection=Set<UUID>(),visibleObjects:Set<UUID>?
  private var epoch=UUID()
  private var pendingRequests:[String:UUID]=[:]
  public static let meshCacheLimit=128*1024*1024,textureCacheLimit=128*1024*1024
  public init(frame:CGRect = .init(x:0,y:0,width:800,height:600))throws {
    guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue(),let event=device.makeSharedEvent() else{throw SceneRendererError.unavailableMetal}
    self.device=device;self.queue=queue;self.frameEvent=event;self.rendered=try RealityRenderer()
    viewport=MTKView(frame:frame,device:device)
    super.init()
    viewport.colorPixelFormat = .bgra8Unorm_srgb
    viewport.colorspace = CGColorSpace(name:CGColorSpace.displayP3)
    viewport.framebufferOnly=false;viewport.enableSetNeedsDisplay=true;viewport.isPaused=true;viewport.preferredFramesPerSecond=60;viewport.delegate=self
    viewport.autoResizeDrawable=true;viewport.setAccessibilityLabel("RealityKit design viewport")
    sceneRoot.name="LAB scene";objectRoot.name="LAB objects";cameraEntity.name="LAB camera"
    sceneRoot.addChild(objectRoot);sceneRoot.addChild(cameraEntity);sceneRoot.addChild(key);sceneRoot.addChild(fill);sceneRoot.addChild(environment)
    environment.name="LAB environment"
    if Self.studioEnvironment==nil {Self.studioEnvironment=try EnvironmentResource(equirectangular:Self.softboxImage(),withName:"LAB neutral studio")}
    if let resource=Self.studioEnvironment {environment.components.set(ImageBasedLightComponent(source:.single(resource),intensityExponent:0))}
    rendered.entities.append(sceneRoot);rendered.activeCamera=cameraEntity
    rendered.cameraSettings.isToneMappingEnabled=true;rendered.cameraSettings.antialiasing = .multisample4X
    try setLighting(lighting);try setCamera(camera)
  }
  public func requestDraw(){viewport.needsDisplay=true}
  public func draw(in view:MTKView) {
    guard view.bounds.width>0,view.bounds.height>0,let drawable=view.currentDrawable else{return}
    let started=CFAbsoluteTimeGetCurrent()
    do {
      let output=try RealityRenderer.CameraOutput(.singleProjection(colorTexture:drawable.texture))
      frameNumber &+= 1
      try rendered.updateAndRender(deltaTime:1/60,cameraOutput:output,actionsAfterRender:[.signal(frameEvent,value:frameNumber)])
      guard let command=queue.makeCommandBuffer() else{return}
      command.encodeWaitForEvent(frameEvent,value:frameNumber);command.present(drawable);command.commit()
      diagnostics.frames+=1;diagnostics.lastFrameMilliseconds=(CFAbsoluteTimeGetCurrent()-started)*1000
    }catch{warn("Viewport render: \(error.localizedDescription)")}
  }
  public func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize){requestDraw()}
  public func upsert(_ payload:SceneRenderablePayload)throws {
    try payload.transform.validate()
    pendingRequests.removeValue(forKey:payload.componentID)
    guard !payload.materials.isEmpty,payload.mesh.parts.allSatisfy({$0.materialIndex>=0 && $0.materialIndex<payload.materials.count}) else{throw SceneRendererError.invalidMesh("Every mesh part needs an available material slot.")}
    let meshKey=payload.mesh.id+"|"+payload.mesh.revision
    let entry:MeshEntry
    if let active=records[payload.componentID],active.payload.mesh.id+"|"+active.payload.mesh.revision==meshKey {entry=active.mesh}
    else if let cached=meshCache[meshKey] {entry=cached;touch(meshKey,in:&meshOrder)}else {
      try payload.mesh.validate(materialCount:payload.materials.count)
      entry=try makeMesh(payload.mesh);meshCache[meshKey]=entry;meshOrder.append(meshKey);diagnostics.meshCacheBytes+=entry.cost;trimMeshes()
    }
    let materialKey=payload.materials.map{ $0.id+"|"+$0.revision }.joined(separator:";")
    let changedMaterials = records[payload.componentID]?.materialKey != materialKey
    let preparedMaterials = changedMaterials ? try payload.materials.map(makeMaterial) : nil
    if var record=records[payload.componentID] {
      if record.payload.mesh.id != payload.mesh.id || record.payload.mesh.revision != payload.mesh.revision {record.entity.model?.mesh=entry.resource;record.mesh=entry;record.selection?.removeFromParent();record.selection=nil}
      if let preparedMaterials {record.entity.model?.materials=preparedMaterials;record.materialKey=materialKey}
      if record.payload.transform != payload.transform || record.mesh.originMM != entry.originMM {diagnostics.transformUpdates+=1}
      record.payload=payload;record.mesh=entry;applyTransform(record);applyVisibility(record)
      records[payload.componentID]=record;refreshSelection(payload.componentID)
    }else {
      let entity=ModelEntity(mesh:entry.resource,materials:preparedMaterials ?? []);entity.name=payload.componentID
      entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight:environment))
      objectRoot.addChild(entity)
      let record=Record(payload:payload,entity:entity,mesh:entry,materialKey:materialKey,selection:nil)
      records[payload.componentID]=record;applyTransform(record);applyVisibility(record);refreshSelection(payload.componentID)
    }
    diagnostics.componentCount=records.count
    if !payload.mesh.uvs1.isEmpty{warn("\(payload.componentID): secondary UVs retained, but procedural UV1 upload needs a newer RealityKit API or explicit UV baking.")}
    if !payload.mesh.colors.isEmpty{warn("\(payload.componentID): vertex colors retained; the standard PBR backend currently needs an explicit color-texture bake.")}
    requestDraw()
  }
  /// The async generator is available for heavy imported meshes. A reset or newer
  /// revision prevents its late result from becoming the active component.
  public func upsertAsync(_ payload:SceneRenderablePayload)async throws {
    try payload.transform.validate();try payload.mesh.validate(materialCount:payload.materials.count)
    let token=epoch,request=UUID(),key=payload.mesh.id+"|"+payload.mesh.revision
    pendingRequests[payload.componentID]=request
    if meshCache[key]==nil {
      let info=descriptor(payload.mesh)
      // Keep the SDK coroutine in its own task. Directly awaiting it from a
      // short-lived capture renderer reproducibly corrupts the host SDK's async
      // allocation stack on the second capture; this isolated lifetime passes
      // repeated real-GPU captures and retains cancellation/epoch guards.
      let meshTask=Task { @MainActor in try await MeshResource(from:[info.descriptor]) }
      let resource=try await withTaskCancellationHandler(operation:{try await meshTask.value},onCancel:{meshTask.cancel()})
      try Task.checkCancellation();guard token==epoch,pendingRequests[payload.componentID]==request else{throw SceneRendererError.cancelled}
      let entry=MeshEntry(resource:resource,originMM:info.origin,low:info.low,high:info.high,cost:payload.mesh.approximateBytes)
      meshCache[key]=entry;meshOrder.append(key);diagnostics.meshCacheBytes+=entry.cost;diagnostics.meshBuilds+=1
    }
    guard token==epoch,pendingRequests[payload.componentID]==request else{throw SceneRendererError.cancelled}
    try upsert(payload);trimMeshes()
  }
  public func remove(componentID:String){pendingRequests.removeValue(forKey:componentID);records.removeValue(forKey:componentID)?.entity.removeFromParent();diagnostics.componentCount=records.count;requestDraw()}
  public func reset(){epoch=UUID();pendingRequests=[:];objectRoot.children.removeAll();records=[:];meshCache=[:];meshOrder=[];materialCache=[:];materialOrder=[];textureCache=[:];textureCosts=[:];textureOrder=[];selection=[];visibleObjects=nil;diagnostics.componentCount=0;diagnostics.meshCacheBytes=0;diagnostics.textureCacheBytes=0;diagnostics.warnings=[];requestDraw()}
  public func setTransform(_ transform:SceneTransformPayload,componentID:String)throws {
    try transform.validate();guard var record=records[componentID] else{return}
    guard record.payload.transform != transform else{return};record.payload.transform=transform;records[componentID]=record;applyTransform(record);diagnostics.transformUpdates+=1;requestDraw()
  }
  public func setMaterials(_ materials:[SceneMaterialPayload],componentID:String)throws {
    guard let record=records[componentID] else{return};var payload=record.payload;payload.materials=materials;try payload.mesh.validate(materialCount:materials.count);try upsert(payload)
  }
  public func setCamera(_ camera:SceneCameraPayload)throws {
    try camera.validate();self.camera=camera
    let p=camera.worldFromCameraMM.columns.3,eye=SIMD3(p.x,p.y,p.z)
    if simd_distance(eye,floatingOriginMM)>50_000 {floatingOriginMM=SIMD3((eye.x/10_000).rounded(),(eye.y/10_000).rounded(),(eye.z/10_000).rounded())*10_000;for record in records.values{applyTransform(record)}}
    applyCamera(camera,to:cameraEntity);requestDraw()
  }
  public func setLighting(_ lighting:SceneLightingPayload)throws {
    guard lighting.keyIntensity.isFinite,lighting.fillIntensity.isFinite,lighting.keyIntensity>=0,lighting.fillIntensity>=0,simd_length_squared(lighting.keyDirection)>1e-10 else{throw SceneRendererError.invalidCamera}
    self.lighting=lighting;rendered.cameraSettings.isToneMappingEnabled=lighting.toneMappingEnabled;rendered.cameraSettings.colorBackground = .color(color(lighting.background).cgColor)
    key.light.intensity=lighting.keyIntensity;key.light.color=NSColor(srgbRed:CGFloat(lighting.keyColor.x),green:CGFloat(lighting.keyColor.y),blue:CGFloat(lighting.keyColor.z),alpha:1)
    key.look(at:lighting.keyDirection,from:.zero,relativeTo:nil)
    key.shadow=lighting.shadows ? .init(shadowProjection:.automatic(maximumDistance:1000),depthBias:1):nil
    fill.light.intensity=lighting.fillIntensity;fill.light.color = .white;fill.look(at:SIMD3<Float>(0.6,-0.3,0.8),from:.zero,relativeTo:nil);fill.shadow=nil
    if var ibl=environment.components[ImageBasedLightComponent.self] {ibl.intensityExponent=log2(max(0.01,lighting.fillIntensity/600));environment.components.set(ibl)}
    requestDraw()
  }
  public func setSelection(_ ids:Set<UUID>){guard ids != selection else{return};selection=ids;for id in records.keys{refreshSelection(id)};requestDraw()}
  public func setVisibleObjects(_ ids:Set<UUID>?){visibleObjects=ids;for record in records.values{applyVisibility(record)};requestDraw()}
  public func ray(atTopLeft point:CGPoint,viewport:CGSize)->SceneRay? {SceneProjection.ray(camera:camera,atTopLeft:point,viewport:viewport)}
  public func pick(atTopLeft point:CGPoint,viewport:CGSize)->ScenePick? {picks(atTopLeft:point,viewport:viewport).first}
  public func picks(atTopLeft point:CGPoint,viewport:CGSize)->[ScenePick] {
    guard let ray=ray(atTopLeft:point,viewport:viewport) else{return []}
    return records.values.compactMap {r->ScenePick? in
      guard r.payload.visible,visibleObjects?.contains(r.payload.objectID) ?? true else{return nil}
      return SceneProjection.pick(ray:ray,in:r.payload,localBounds:(low:r.mesh.low,high:r.mesh.high))
    }.filter{$0.distanceMM>=camera.nearMM && $0.distanceMM<=camera.farMM}.sorted{$0.distanceMM<$1.distanceMM}
  }
  public func capture(width:Int,height:Int,transparent:Bool=false,camera override:SceneCameraPayload?=nil)async throws->CGImage {
    guard width>0,height>0,width<=8192,height<=8192,Double(width)*Double(height)<=32_000_000 else{throw SceneRendererError.invalidCapture}
    let token=epoch,started=CFAbsoluteTimeGetCurrent(),renderer=try RealityRenderer(),root=sceneRoot.clone(recursive:true)
    func removeAdornments(_ entity:Entity){for child in Array(entity.children){if child.name=="LAB selection" || child.name.hasSuffix("/paper.highlight"){child.removeFromParent()}else{removeAdornments(child)}}}
    removeAdornments(root)
    if let light=root.findEntity(named:"LAB environment") {
      func rebind(_ node:Entity){if node is ModelEntity {node.components.set(ImageBasedLightReceiverComponent(imageBasedLight:light))};for child in node.children {rebind(child)}}
      rebind(root)
    }
    renderer.entities.append(root)
    guard let lens=root.findEntity(named:"LAB camera") else{throw SceneRendererError.invalidCamera}
    if let override{try override.validate();applyCamera(override,to:lens)}
    renderer.activeCamera=lens;renderer.cameraSettings.isToneMappingEnabled=lighting.toneMappingEnabled;renderer.cameraSettings.antialiasing = .multisample4X
    renderer.cameraSettings.colorBackground = .color(color(transparent ? SIMD4(0,0,0,0):lighting.background).cgColor)
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:width,height:height,mipmapped:false)
    descriptor.usage=[.renderTarget,.shaderRead];descriptor.storageMode=device.hasUnifiedMemory ? .shared:.managed
    guard let texture=device.makeTexture(descriptor:descriptor) else{throw SceneRendererError.unavailableMetal}
    let output=try RealityRenderer.CameraOutput(.singleProjection(colorTexture:texture))
    try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
      do {try renderer.updateAndRender(deltaTime:1/60,cameraOutput:output,onComplete:{_ in continuation.resume()})}catch{continuation.resume(throwing:error)}
    }
    try Task.checkCancellation();guard token==epoch else{throw SceneRendererError.cancelled}
    if !device.hasUnifiedMemory,let command=queue.makeCommandBuffer(),let blit=command.makeBlitCommandEncoder(){
      blit.synchronize(resource:texture);blit.endEncoding()
      await withCheckedContinuation{(c:CheckedContinuation<Void,Never>) in command.addCompletedHandler{_ in c.resume()};command.commit()}
    }
    var bytes=[UInt8](repeating:0,count:width*height*4);texture.getBytes(&bytes,bytesPerRow:width*4,from:.init(origin:.init(x:0,y:0,z:0),size:.init(width:width,height:height,depth:1)),mipmapLevel:0)
    let data=Data(bytes)
    guard let provider=CGDataProvider(data:data as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.displayP3)!,bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{throw SceneRendererError.invalidCapture}
    guard let normalized=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw SceneRendererError.invalidCapture}
    normalized.draw(image,in:.init(x:0,y:0,width:width,height:height))
    guard let outputImage=normalized.makeImage() else{throw SceneRendererError.invalidCapture}
    diagnostics.offscreenCaptures+=1;diagnostics.lastCaptureMilliseconds=(CFAbsoluteTimeGetCurrent()-started)*1000;return outputImage
  }
  /// A small procedural neutral studio provides continuous metal reflections.
  /// It contains no external imagery and is shared across all viewport instances.
  private static func softboxImage()throws->CGImage {
    let width=256,height=128;var bytes=[UInt8](repeating:255,count:width*height*4)
    for y in 0..<height {for x in 0..<width {
      let u=Double(x)/Double(width),v=Double(y)/Double(height)
      let ceiling=max(0,cos(v * .pi)),softbox=exp(-pow((u-0.25)/0.10,8)-pow((v-0.32)/0.13,8)),rim=exp(-pow((u-0.72)/0.055,8)-pow((v-0.42)/0.21,8))
      let value=min(1,0.16+0.34*ceiling+0.48*softbox+0.38*rim),i=(y*width+x)*4
      bytes[i]=UInt8(value*255);bytes[i+1]=UInt8(value*255);bytes[i+2]=UInt8(value*255)
    }}
    guard let provider=CGDataProvider(data:Data(bytes) as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.linearSRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{throw SceneRendererError.invalidTexture("Could not create the neutral studio lighting map.")}
    return image
  }
  private func descriptor(_ mesh:SceneMeshPayload)->(descriptor:MeshDescriptor,origin:SIMD3<Double>,low:SIMD3<Double>,high:SIMD3<Double>) {
    var low=mesh.positionsMM[0],high=low
    for p in mesh.positionsMM.dropFirst(){low=simd_min(low,p);high=simd_max(high,p)}
    let origin=(low+high)/2
    var d=MeshDescriptor(name:mesh.id);d.positions = .init(mesh.positionsMM.map{SIMD3<Float>(($0-origin)/1000)})
    if !mesh.normals.isEmpty{d.normals = .init(mesh.normals)}
    if !mesh.uvs.isEmpty{d.textureCoordinates = .init(mesh.uvs)}
    if !mesh.tangents.isEmpty {
      d.tangents = .init(mesh.tangents.map{SIMD3($0.x,$0.y,$0.z)})
      if !mesh.normals.isEmpty{d.bitangents = .init(zip(mesh.normals,mesh.tangents).map{simd_cross($0.0,SIMD3($0.1.x,$0.1.y,$0.1.z))*$0.1.w})}
    }
    d.primitives = .triangles(mesh.parts.flatMap(\.triangleIndices));d.materials = .perFace(mesh.parts.flatMap{Array(repeating:UInt32($0.materialIndex),count:$0.triangleIndices.count/3)})
    return (d,origin,low,high)
  }
  private func makeMesh(_ mesh:SceneMeshPayload)throws->MeshEntry {let info=descriptor(mesh),resource=try MeshResource.generate(from:[info.descriptor]);diagnostics.meshBuilds+=1;return .init(resource:resource,originMM:info.origin,low:info.low,high:info.high,cost:mesh.approximateBytes)}
  private func applyTransform(_ record:Record) {
    var matrix=record.payload.transform.matrixMM
    let p=matrix*SIMD4(record.mesh.originMM,1);matrix.columns.3 = .init((p.x-floatingOriginMM.x)/1000,(p.y-floatingOriginMM.y)/1000,(p.z-floatingOriginMM.z)/1000,1)
    record.entity.transform=Transform(matrix:floatMatrix(matrix))
  }
  private func applyCamera(_ value:SceneCameraPayload,to entity:Entity) {
    var m=value.worldFromCameraMM;m.columns.3 = .init((m.columns.3.x-floatingOriginMM.x)/1000,(m.columns.3.y-floatingOriginMM.y)/1000,(m.columns.3.z-floatingOriginMM.z)/1000,1)
    entity.transform=Transform(matrix:floatMatrix(m))
    entity.components.remove(PerspectiveCameraComponent.self);entity.components.remove(OrthographicCameraComponent.self)
    switch value.projection {
    case .perspective(let fov):entity.components.set(PerspectiveCameraComponent(near:Float(value.nearMM/1000),far:Float(value.farMM/1000),fieldOfViewInDegrees:Float(fov),fieldOfViewOrientation:.vertical))
    case .orthographic(let span):var ortho=OrthographicCameraComponent();ortho.near=Float(value.nearMM/1000);ortho.far=Float(value.farMM/1000);ortho.scale=Float(span/2000);ortho.scaleDirection = .vertical;entity.components.set(ortho)
    }
  }
  private func applyVisibility(_ record:Record){record.entity.isEnabled=record.payload.visible && (visibleObjects?.contains(record.payload.objectID) ?? true)}
  private func refreshSelection(_ id:String) {
    guard var record=records[id] else{return}
    let selected=selection.contains(record.payload.objectID)
    if !selected{record.selection?.removeFromParent();record.selection=nil;records[id]=record;return}
    guard record.selection==nil else{return}
    let root=Entity(),lo=SIMD3<Float>((record.mesh.low-record.mesh.originMM)/1000),hi=SIMD3<Float>((record.mesh.high-record.mesh.originMM)/1000)
    let thickness:Float=0.00025
    var material=UnlitMaterial();material.color = .init(tint:NSColor(srgbRed:0.78,green:0.38,blue:0.25,alpha:1))
    for axis in 0..<3{let a=(axis+1)%3,b=(axis+2)%3;for sa in [lo[a],hi[a]]{for sb in [lo[b],hi[b]]{var size=SIMD3<Float>(repeating:thickness);size[axis]=max(thickness,hi[axis]-lo[axis]);let edge=ModelEntity(mesh:.generateBox(size:size),materials:[material]);var center=(lo+hi)/2;center[a]=sa;center[b]=sb;edge.position=center;root.addChild(edge)}}}
    root.name="LAB selection";record.entity.addChild(root);record.selection=root;records[id]=record
  }
  private func makeMaterial(_ payload:SceneMaterialPayload)throws->any RealityKit.Material {
    guard payload.baseColor.x.isFinite,payload.baseColor.y.isFinite,payload.baseColor.z.isFinite,payload.baseColor.w.isFinite,payload.metallic.isFinite,payload.roughness.isFinite else{throw SceneRendererError.invalidTexture("Use finite material colors and surface values.")}
    let cacheKey=payload.id+"|"+payload.revision
    if let cached=materialCache[cacheKey]{touch(cacheKey,in:&materialOrder);return cached}
    diagnostics.materialBuilds+=1
    if payload.unlit {
      var m=UnlitMaterial(applyPostProcessToneMap:false);m.color = .init(tint:color(payload.baseColor,encoding:payload.colorEncoding),texture:try payload.baseColorTexture.map{try texture($0,semantic:.color)})
      if payload.alphaMode == .blend{m.blending = .transparent(opacity:.init(scale:payload.baseColor.w))}
      if payload.alphaMode == .mask{m.opacityThreshold=payload.alphaCutoff}
      m.faceCulling=payload.doubleSided ? .none:.back;m.readsDepth=payload.readsDepth;m.writesDepth=payload.writesDepth
      cacheMaterial(m,key:cacheKey);return m
    }
    var m=PhysicallyBasedMaterial();m.baseColor = .init(tint:color(payload.baseColor,encoding:payload.colorEncoding),texture:try payload.baseColorTexture.map{try texture($0,semantic:.color)})
    m.metallic = .init(scale:payload.metallic,texture:try payload.metallicTexture.map{try texture($0,semantic:.scalar)})
    m.roughness = .init(scale:payload.roughness,texture:try payload.roughnessTexture.map{try texture($0,semantic:.scalar)})
    if var normal=payload.normalTexture {
      if payload.normalScale != 1 {normal.image=try SceneTextureProcessing.normalMap(normal.image,strength:payload.normalScale);normal.revision += "|normal-scale:\(payload.normalScale)"}
      m.normal = .init(texture:try texture(normal,semantic:.normal))
    }
    m.emissiveColor = .init(color:color(SIMD4(payload.emissiveColor,1),encoding:payload.colorEncoding),texture:try payload.emissiveTexture.map{try texture($0,semantic:.color)})
    m.emissiveIntensity=payload.emissiveIntensity
    m.ambientOcclusion = .init(texture:try payload.ambientOcclusionTexture.map{try texture($0,semantic:.scalar)})
    m.faceCulling=payload.doubleSided ? .none:.back;m.readsDepth=payload.readsDepth;m.writesDepth=payload.writesDepth
    if payload.alphaMode == .blend{m.blending = .transparent(opacity:.init(scale:payload.baseColor.w))}
    if payload.alphaMode == .mask{m.opacityThreshold=payload.alphaCutoff}
    cacheMaterial(m,key:cacheKey);return m
  }
  private func cacheMaterial(_ material:any RealityKit.Material,key:String){materialCache[key]=material;touch(key,in:&materialOrder);while materialOrder.count>512{materialCache.removeValue(forKey:materialOrder.removeFirst())}}
  private func texture(_ value:SceneTexturePayload,semantic:TextureResource.Semantic)throws->MaterialParameters.Texture {
    guard value.image.width<=8192,value.image.height<=8192,value.image.width*value.image.height<=16_000_000,!value.revision.isEmpty else{throw SceneRendererError.invalidTexture("Textures need an immutable revision and at most 16 MP / 8192 pixels per edge.")}
    guard value.uvIndex==0 else{throw SceneRendererError.invalidTexture("The current procedural renderer supports UV0. Bake the requested UV set explicitly; its source remains retained.")}
    let key=value.revision+"|"+String(describing:semantic)
    let resource:TextureResource
    if let cached=textureCache[key]{resource=cached;touch(key,in:&textureOrder)}else{resource=try TextureResource(image:try orientedTextureImage(value.image,semantic:semantic),withName:nil,options:.init(semantic:semantic));textureCache[key]=resource;textureOrder.append(key);let cost=value.image.width*value.image.height*4;textureCosts[key]=cost;diagnostics.textureCacheBytes+=cost;diagnostics.textureUploads+=1;trimTextures()}
    var output=MaterialParameters.Texture(resource);output.uvIndex=value.uvIndex
    output.sampler.modify {d in d.sAddressMode=address(value.wrapS);d.tAddressMode=address(value.wrapT);d.minFilter = .linear;d.magFilter = .linear;d.mipFilter = .linear}
    switch value.channel {
    case .rgba:break
    case .red:output.swizzle = .init(red:.red,green:.red,blue:.red,alpha:.one)
    case .green:output.swizzle = .init(red:.green,green:.green,blue:.green,alpha:.one)
    case .blue:output.swizzle = .init(red:.blue,green:.blue,blue:.blue,alpha:.one)
    case .alpha:output.swizzle = .init(red:.alpha,green:.alpha,blue:.alpha,alpha:.alpha)
    }
    return output
  }
  /// CGImage upload and glTF/native artwork UVs have opposite row origins.
  /// Flip decoded image rows once here, preserving source UV/tangent semantics.
  private func orientedTextureImage(_ source:CGImage,semantic:TextureResource.Semantic)throws->CGImage {
    let isColor=String(describing:semantic)==String(describing:TextureResource.Semantic.color)
    let space=CGColorSpace(name:isColor ? CGColorSpace.sRGB:CGColorSpace.linearSRGB)!
    guard let tagged=isColor ? source:source.copy(colorSpace:space) else{throw SceneRendererError.invalidTexture("Non-color maps require readable RGB data.")}
    guard let c=CGContext(data:nil,width:source.width,height:source.height,bitsPerComponent:8,bytesPerRow:source.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw SceneRendererError.invalidTexture("Could not normalize texture row orientation.")}
    c.translateBy(x:0,y:CGFloat(source.height));c.scaleBy(x:1,y:-1);c.draw(tagged,in:.init(x:0,y:0,width:source.width,height:source.height))
    guard let image=c.makeImage() else{throw SceneRendererError.invalidTexture("Could not read normalized texture pixels.")};return image
  }
  private func address(_ value:SceneTextureWrap)->MTLSamplerAddressMode {switch value{case .repeatMode:return .repeat;case .clamp:return .clampToEdge;case .mirror:return .mirrorRepeat}}
  private func floatMatrix(_ value:simd_double4x4)->simd_float4x4{.init(SIMD4<Float>(value.columns.0),SIMD4<Float>(value.columns.1),SIMD4<Float>(value.columns.2),SIMD4<Float>(value.columns.3))}
  private func color(_ value:SIMD4<Float>,encoding:SceneColorEncoding = .srgb)->NSColor{
    let components=[CGFloat(value.x),CGFloat(value.y),CGFloat(value.z),CGFloat(value.w)]
    let space=CGColorSpace(name:encoding == .linearSRGB ? CGColorSpace.extendedLinearSRGB:CGColorSpace.sRGB)!
    return NSColor(cgColor:CGColor(colorSpace:space,components:components)!)!
  }
  private func warn(_ text:String){if !diagnostics.warnings.contains(text){diagnostics.warnings.append(text);if diagnostics.warnings.count>100{diagnostics.warnings.removeFirst()}}}
  private func touch(_ key:String,in order:inout[String]){order.removeAll{$0==key};order.append(key)}
  private func trimMeshes(){while diagnostics.meshCacheBytes>Self.meshCacheLimit,!meshOrder.isEmpty{let key=meshOrder.removeFirst();if let removed=meshCache.removeValue(forKey:key){diagnostics.meshCacheBytes-=removed.cost}}}
  private func trimTextures(){while diagnostics.textureCacheBytes>Self.textureCacheLimit,!textureOrder.isEmpty{let key=textureOrder.removeFirst();textureCache.removeValue(forKey:key);materialCache=[:];materialOrder=[];diagnostics.textureCacheBytes-=textureCosts.removeValue(forKey:key) ?? 0}}
}

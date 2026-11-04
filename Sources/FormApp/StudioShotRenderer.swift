import AppKit
import CoreText
import CryptoKit
import Darwin
import FormCore
import FormGraphics
import ImageIO
import Metal
import FormGeometry
import LabRendering

@MainActor final class StudioShotRenderer {
  private var owner:UUID?
  private var controller:TableSceneController?
  private var physicalAssetGeneration:String?
  private static var physicalAssetGenerations:[String:String]=[:]
  private struct CaptureWaiter {let id:UUID;let continuation:CheckedContinuation<Bool,Never>}
  private var captureActive=false,captureWaiters:[CaptureWaiter]=[]
  // Tests may pause a verified external load before publishing its scene buffers.
  var externalPreparationCheckpoint:(()async->Void)?
  private func acquireCapture()async throws {
    try Task.checkCancellation()
    if !captureActive {captureActive=true;return}
    guard captureWaiters.count<8 else{throw FormError.invalid("Finish a pending Studio capture before queuing another.")}
    let id=UUID()
    let granted=await withTaskCancellationHandler(operation:{
      await withCheckedContinuation{continuation in captureWaiters.append(.init(id:id,continuation:continuation))}
    },onCancel:{Task { @MainActor [weak self] in self?.cancelCaptureWaiter(id)}})
    guard granted else{throw CancellationError()}
    if Task.isCancelled {releaseCapture();throw CancellationError()}
  }
  private func cancelCaptureWaiter(_ id:UUID) {
    guard let index=captureWaiters.firstIndex(where:{$0.id==id}) else{return}
    captureWaiters.remove(at:index).continuation.resume(returning:false)
  }
  private func releaseCapture() {
    if captureWaiters.isEmpty {captureActive=false}
    else {captureWaiters.removeFirst().continuation.resume(returning:true)}
  }
  private(set) var renders=0,maximumMilliseconds=0.0,maximumProcessRSSBytes:Int64=0
  private(set) var lastSourceSampling:[UUID:SourceTextureSamplingPlan]=[:]
  private(set) var lastPixelBytes=0
  private(set) var lastValidatedArtworkCount=0
  private(set) var framingWarnings:[[String:Any]]=[]
  func clear() {controller=nil;owner=nil;lastPixelBytes=0;lastSourceSampling=[:]}
  var geometryBuilds:Int {controller?.geometryBuilds ?? 0}
  var backendIdentifier:String {
    guard let renderer=controller?.renderer else{return "Native scene renderer"}
    return String(describing:type(of:renderer))
  }
  static func rss()->Int64 {var r=rusage();getrusage(RUSAGE_SELF,&r);return Int64(r.ru_maxrss)}
  struct RenderResult {var image:NSImage;var framingWarnings:[[String:Any]]}
  func render(project:Project,shot:StudioShot,assets:URL,preview:Bool,renderObjectIDs:Set<UUID>?=nil,textureLimit:Int?=nil,sampling:SceneCaptureSampling?=nil)async throws->NSImage {
    try await renderResult(project:project,shot:shot,assets:assets,preview:preview,renderObjectIDs:renderObjectIDs,textureLimit:textureLimit,sampling:sampling).image
  }
  func renderResult(project:Project,shot:StudioShot,assets:URL,preview:Bool,renderObjectIDs:Set<UUID>?=nil,textureLimit:Int?=nil,sampling:SceneCaptureSampling?=nil)async throws->RenderResult {
    try shot.validate();_ = try shot.visibility.resolved(in:project)
    // A capture owns this cached controller until the GPU has cloned/rendered
    // its complete composition, including any external-source preparation.
    // Waiting releases the UI actor; cancellation removes a queued preview.
    try await acquireCapture();defer{releaseCapture()}
    let prepared=try await prepareScene(project:project,shot:shot,assets:assets,preview:preview,
      renderObjectIDs:renderObjectIDs,textureLimit:textureLimit)
    let c=prepared.controller,outputCamera=prepared.camera
    var width=shot.pixels.width,height=shot.pixels.height
    if preview {let scale=min(1,1600/Double(max(width,height)),sqrt(2_000_000/Double(width*height)));width=max(1,Int(Double(width)*scale));height=max(1,Int(Double(height)*scale))}
    let capturedWarnings=framingWarnings
    let raw=try await c.snapshot(size:CGSize(width:width,height:height),camera:outputCamera,sampling:sampling ?? (preview ? .native:.still))
    // AppKit may attach a backing-scale representation to the snapshot. Return
    // one explicitly sized bitmap, independent of the test/app display scale.
    guard let source=raw.cgImage(forProposedRect:nil,context:nil,hints:nil),let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw FormError.invalid("Could not normalize Studio output pixels.")}
    context.interpolationQuality = .high;context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
    guard let pixels=context.makeImage() else{throw FormError.invalid("Could not read Studio output pixels.")}
    let bitmap=NSBitmapImageRep(cgImage:pixels);bitmap.size=NSSize(width:width,height:height)
    let image=NSImage(size:bitmap.size);image.addRepresentation(bitmap)
    lastPixelBytes=width*height*4;renders+=1;return .init(image:image,framingWarnings:capturedWarnings)
  }
  struct PreparedScene {
    let controller:TableSceneController
    let camera:SceneCameraPayload
    let visible:Set<UUID>
  }
  func cyclesSnapshot(project:Project,shot:StudioShot,assets:URL,settings:CyclesRenderSettings,preview:Bool=false,resources:[[String:String]]?=nil)async throws->SceneSnapshot {
    try shot.validate();try settings.validate()
    try await acquireCapture();defer{releaseCapture()}
    let dependencies=try resources ?? Self.resources(project:project,assets:assets)
    let generation=try preparePhysicalAssetGeneration(dependencies,assets:assets)
    let prepared=try await prepareScene(project:project,shot:shot,assets:assets,preview:preview,
      textureLimit:preview ? 2048:SourceTextureSampling.maximumEdge,pathTracing:true)
    var snapshot=try await prepared.controller.cyclesSnapshot(settings:settings,camera:prepared.camera)
    snapshot.revision=SHA256.hash(data:Data((snapshot.revision+":"+generation).utf8)).map{String(format:"%02x",$0)}.joined()
    return snapshot
  }
  private func preparePhysicalAssetGeneration(_ resources:[[String:String]],assets:URL)throws->String {
    let root=assets.standardizedFileURL.resolvingSymlinksInPath().path
    let generation=SHA256.hash(data:try JSONEncoder.form.encode(resources)).map{String(format:"%02x",$0)}.joined()
    let changed=Self.physicalAssetGenerations[root] != generation
    if changed {
      // Hashes already gathered for provenance define this boundary; ordinary
      // viewport frames never enumerate or hash a project's assets here.
      ArtworkRenderer.invalidateImageResources()
      GeometryFactory.invalidateRenderingResources()
      if Self.physicalAssetGenerations.count>=8 {Self.physicalAssetGenerations.removeAll()}
      Self.physicalAssetGenerations[root]=generation
    }
    if changed || physicalAssetGeneration != root+":"+generation {clear()}
    physicalAssetGeneration=root+":"+generation
    return generation
  }
  /// Table captures the displayed cloth pose once, then prepares full-quality
  /// source materials/static geometry without changing that live simulation.
  func cyclesTableSnapshot(project:Project,shot:StudioShot,assets:URL,settings:CyclesRenderSettings,live:TableSceneController,resources:[[String:String]]?=nil)async throws->SceneSnapshot {
    let camera=live.cameraPayload(size:CGSize(width:shot.pixels.width,height:shot.pixels.height))
    let displayed=try await live.cyclesSnapshot(settings:settings,camera:camera)
    guard displayed.projectID==project.id else{throw FormError.invalid("The displayed Table belongs to a different project.")}
    var result=try await cyclesSnapshot(project:project,shot:shot,assets:assets,settings:settings,resources:resources)
    let deformedIDs=Set(project.objects.filter{$0.cloth != nil || $0.patternAssembly != nil || $0.clothAttachment != nil || $0.patternAssemblyAttachment != nil || $0.textile?.attachment != nil}.map(\.id))
    let displayedComponents=Dictionary(uniqueKeysWithValues:displayed.renderables.map{($0.componentID,$0)})
    for index in result.renderables.indices where deformedIDs.contains(result.renderables[index].objectID) {
      guard let current=displayedComponents[result.renderables[index].componentID],
        current.mesh.parts.allSatisfy({$0.materialIndex<result.renderables[index].materials.count}) else {
        throw FormError.invalid("The displayed cloth changed while preparing its Table capture. Try again from the current view.")
      }
      result.renderables[index].mesh=current.mesh
      result.renderables[index].transform=current.transform
      result.renderables[index].visible=current.visible
    }
    // The live Table owns its presentation surface. The temporary full-source
    // controller may use a different Studio preset and must not recolor it.
    let physicalIDs=Set(project.objects.map(\.id))
    result.renderables.removeAll{!physicalIDs.contains($0.objectID)}
    result.renderables += displayed.renderables.filter{!physicalIDs.contains($0.objectID)}
    result.curves=displayed.curves
    result.camera=displayed.camera;result.lights=displayed.lights;result.environment=displayed.environment
    result.revision=SHA256.hash(data:Data((result.revision+":table-runtime:"+displayed.revision).utf8)).map{String(format:"%02x",$0)}.joined()
    return result
  }
  func cyclesPreview(project:Project,shot:StudioShot,assets:URL,onFrame:@escaping(NSImage)->Void)async throws->NSImage {
    let settings=shot.renderSettings ?? CyclesRenderSettings()
    let resources=try Self.resources(project:project,assets:assets)
    let snapshot=try await cyclesSnapshot(project:project,shot:shot,assets:assets,settings:settings,preview:true,resources:resources)
    guard resources == (try Self.resources(project:project,assets:assets)) else {
      throw FormError.invalid("A source image changed while preparing the preview. Render its current revision again.")
    }
    var configuration=LabCyclesRuntime.configuration(settings,pixels:shot.pixels,preview:true)
    configuration.purpose = .review
    let job=try await LabCyclesRuntime.service.start(snapshot:snapshot,settings:configuration,outputDirectory:LabCyclesRuntime.cacheURL)
    return try await withTaskCancellationHandler(operation:{
      do {
        for try await event in job.events {
          try Task.checkCancellation()
          switch event {
          case .progress:break
          case .frame(let frame):
            if frame.sourceRevision==snapshot.revision,let image=NSImage(data:try Data(contentsOf:frame.url)) {onFrame(image)}
          case .completed(let result):
            guard resources == (try Self.resources(project:project,assets:assets)),
              let image=NSImage(data:try Data(contentsOf:result.pngURL)) else {
              throw FormError.invalid("A source image changed during the preview, or the result could not be read.")
            }
            try? FileManager.default.removeItem(at:job.directory)
            return image
          }
        }
        throw FormError.invalid("Cycles ended without a preview image.")
      } catch {
        await LabCyclesRuntime.service.cancel(jobID:job.id)
        try? FileManager.default.removeItem(at:job.directory)
        throw error
      }
    },onCancel:{Task{await LabCyclesRuntime.service.cancel(jobID:job.id)}})
  }
  /// Called while the capture owner holds its lock. Both native and path-traced
  /// output share source validation, full geometry, cameras and artwork sampling.
  private func prepareScene(project:Project,shot:StudioShot,assets:URL,preview:Bool,
    renderObjectIDs:Set<UUID>?=nil,textureLimit:Int?=nil,pathTracing:Bool=false
  ) async throws -> PreparedScene {
    let ids=try shot.visibility.resolved(in:project)
    try validateCaptureArtwork(project:project,objectIDs:ids,assets:assets,validateImages:pathTracing)
    let started=Date();defer{maximumMilliseconds=max(maximumMilliseconds,Date().timeIntervalSince(started)*1000);maximumProcessRSSBytes=max(maximumProcessRSSBytes,Self.rss())}
    if owner != project.id {clear();owner=project.id;controller=TableSceneController()}
    let c=controller!;c.externalCapturePreparationCheckpoint=externalPreparationCheckpoint
    var copy=project;copy.camera=shot.camera;copy.camera.viewportAspect=shot.referenceAspect
    let visible=renderObjectIDs.map{ids.intersection($0)} ?? ids
    let explicitObjects=renderObjectIDs ?? (shot.visibility.mode == .objects ? ids:nil)
    let fullSolids=try await SolidRecipeGeometry.prepareFullSources(project:copy,objectIDs:visible)
    // Only this isolated capture controller receives a cheap geometry/bounds pass.
    // Ordinary editing and thumbnail sampling retain their established limits.
    let baseLimit=max(64,min(preview ? 2048:256,textureLimit ?? (preview ? 2048:256)))
    c.sync(copy,selection:[],isolated:ids,showGrid:false,studio:true,preset:shot.surface,assets:assets,
      textureLimit:baseLimit,renderObjectIDs:explicitObjects,solidSurfaces:fullSolids)
    try SheetAssemblyRenderValidation.scene(c.objectRoot,project:copy,objectIDs:visible)
    // sync intentionally restores a camera only on a new project. Explicit render
    // composition uses its own owner and never mutates the native editing scene.
    c.camera=copy.camera;c.updateCamera();c.applyShotLighting(shot.lighting,studio:true)
    var outputCamera=c.cameraPayload()
    switch outputCamera.projection {
    case .orthographic(let span):outputCamera.projection = .orthographic(verticalSpanMM:span*shot.expansion)
    case .perspective:outputCamera.projection = .perspective(verticalFieldOfViewDegrees:shot.outputFieldOfView)
    }
    if !preview || pathTracing {
      let plans=try StudioSourceSampling.plans(controller:c,project:copy,camera:outputCamera,
        viewport:CGSize(width:shot.pixels.width,height:shot.pixels.height),objectIDs:visible,
        maximumEdge:max(64,min(SourceTextureSampling.maximumEdge,textureLimit ?? SourceTextureSampling.maximumEdge)),
        includeIndirectSurfaces:pathTracing)
      c.sync(copy,selection:[],isolated:ids,showGrid:false,studio:true,preset:shot.surface,assets:assets,
        textureLimit:baseLimit,renderObjectIDs:explicitObjects,sourceSampling:plans,solidSurfaces:fullSolids)
      try SheetAssemblyRenderValidation.scene(c.objectRoot,project:copy,objectIDs:visible)
      lastSourceSampling=plans
    } else {lastSourceSampling=[:]}
    framingWarnings=[]
    for subject in c.objectRoot.childNodes {
      guard let name=subject.name,name.hasPrefix("object:"),let id=UUID(uuidString:String(name.dropFirst(7))),ids.contains(id) else{continue}
      let b=c.localBounds(for:id) ?? subject.boundingBox;var outside=false
      for x in [b.min.x,b.max.x] {for y in [b.min.y,b.max.y] {for z in [b.min.z,b.max.z] {
        let p=subject.convertPosition(.init(x,y,z),to:nil).simd*100
        if let point=SceneProjection.project(p,camera:outputCamera,viewport:.init(width:shot.pixels.width,height:shot.pixels.height)) {
          if point.x<0 || point.y<0 || point.x>Double(shot.pixels.width) || point.y>Double(shot.pixels.height){outside=true}
        } else {outside=true}
      }}}
      if outside {framingWarnings.append(["object_id":id.uuidString,"bounds_extend_outside_frame_or_clip_range":true])}
    }
    try await c.prepareExternalForCapture(project:copy,assets:assets)
    return .init(controller:c,camera:outputCamera,visible:visible)
  }
  /// Repeated presentation instances commonly share complete registered
  /// artwork. Validate each distinct resolved document once per capture; never
  /// carry a validation result across source revisions or explicit exports.
  func validateCaptureArtwork(project:Project,objectIDs:Set<UUID>,assets:URL,validateImages:Bool=false)throws {
    var validated:[Artwork]=[];lastValidatedArtworkCount=0
    var images=Set<String>()
    for object in project.objects where objectIDs.contains(object.id) {
      if object.sheetAssembly != nil {
        try SheetAssemblyRenderValidation.sources(object,project:project,assets:assets)
        continue
      }
      var artworks=PaperConstruction.isPaper(object) ? [project.paperArtwork(for:object,inside:false),project.paperArtwork(for:object,inside:true)].compactMap{$0}:[project.surfaceArtwork(object)].compactMap{$0}
      if validateImages {
        artworks += (object.surfaceArtworkBindings ?? []).compactMap{project.physicalSurfaceArtwork($0)}
        if let repeatDesign=try project.resolvedFabricPattern(materialID:object.materialID) {artworks.append(repeatDesign.artwork)}
        if let assembly=object.patternAssembly,let source=project.objects.first(where:{$0.id==assembly.sourceObjectID}),let art=source.artwork {
          artworks.append(try AssemblyMaterialRenderer.resolvedDecoration(art,project:project,sourceObjectID:source.id))
          for panel in assembly.panels where panel.material.fabric?.pattern != nil {
            var snapshot=project;snapshot.materials.removeAll{$0.id==panel.material.id};snapshot.materials.append(panel.material)
            if let repeatDesign=try snapshot.resolvedFabricPattern(materialID:panel.material.id) {artworks.append(repeatDesign.artwork)}
          }
        }
        if let asset=object.asset {images.insert(asset)}
      }
      for art in artworks where !validated.contains(art) {
        try ArtworkRenderer.validateGlyphOutput(art,assets:assets)
        if validateImages {images.formUnion(try ArtworkRenderer.requiredImageAssets(art,assets:assets))}
        validated.append(art);lastValidatedArtworkCount+=1
      }
    }
    for name in images {
      guard !name.isEmpty,name==URL(fileURLWithPath:name).lastPathComponent,name != ".",name != "..",!name.contains("\\") else {throw FormError.invalid("An image must reference an ordinary project asset filename.")}
      do {
        let url=assets.appendingPathComponent(name)
        let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile==true,values.isSymbolicLink != true,let size=values.fileSize,size>0,size<=536_870_912 else {throw FormError.invalid("The image is not a bounded portable asset file.")}
        // Validate actual bytes even if a prior image metadata cache is warm.
        if let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary) {
          guard CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:64] as CFDictionary) != nil else {throw FormError.invalid("The raster image cannot be decoded.")}
        } else {
          // NSImage supports the existing vector/PDF artwork fallback.
          guard let image=NSImage(contentsOf:url),image.isValid else {throw FormError.invalid("The image cannot be decoded.")}
        }
      }catch {throw FormError.invalid("Image asset ‘\(name)’ is missing or unreadable: \(error.localizedDescription)")}
    }
  }
  static func resources(project:Project,assets:URL)throws->[[String:String]] {
    var result=[[String:String]](),total:Int64=0
    let fm=FileManager.default,root=assets.standardizedFileURL.resolvingSymlinksInPath()
    if let enumerator=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey],options:[.skipsHiddenFiles]) {
      for case let file as URL in enumerator {
        let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isSymbolicLink != true else{throw FormError.invalid("Studio provenance does not follow asset symlinks.")}
        if values.isRegularFile==true {
          let resolved=file.standardizedFileURL.resolvingSymlinksInPath()
          guard resolved.path.hasPrefix(root.path+"/") else{throw FormError.invalid("A render resource resolves outside its asset directory.")}
          total+=Int64(values.fileSize ?? 0);guard result.count<4096,total<=2_147_483_648 else{throw FormError.invalid("Studio resource hashing exceeds its bounded project budget.")}
          result.append(["id":"asset:"+String(resolved.path.dropFirst(root.path.count+1)),"sha256":try fileHash(resolved)])
        }
      }
    }
    let names=Set(FontUsage.uses(in:project).map(\.fontName))
    for name in names.sorted() {
      guard let font=NSFont(name:name,size:12) else{throw FormError.invalid("Studio source requires unavailable font \(name). Resolve the assignment before rendering.")}
      guard let url=CTFontCopyAttribute(font as CTFont,kCTFontURLAttribute) as? URL else{throw FormError.invalid("The resolved font cannot be identified for render provenance.")}
      result.append(["id":"font:"+font.fontName,"sha256":try fileHash(url)])
    }
    return result.sorted{$0["id"]!<$1["id"]!}
  }
  private static func fileHash(_ url:URL)throws->String {
    let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()};var hash=SHA256(),count=0
    while let data=try handle.read(upToCount:65536),!data.isEmpty {count+=data.count;guard count<=536_870_912 else{throw FormError.invalid("A render dependency exceeds 512 MiB.")};hash.update(data:data)}
    return hash.finalize().map{String(format:"%02x",$0)}.joined()
  }
}
extension TableSceneController {
  func applyShotLighting(_ id:String,studio:Bool) {
    defer{updateRenderLighting()}
    let ambient=scene.rootNode.childNodes.first{$0.light?.type == .ambient},fill=scene.rootNode.childNodes.first{$0.light?.type == .omni}
    let classic=id=="classic-v1" || !studio
    ambient?.light?.intensity=classic ? 400:id=="soft-side-v1" ? 250:200
    ambient?.light?.color=NSColor(hex:studio ? "#F7F7F2":"#FFFFFF")
    keyLight.light?.intensity=classic ? (studio ? 850:800):id=="soft-side-v1" ? 900:650
    keyLight.position=classic ? MeshVector3(-6,12,7):id=="soft-side-v1" ? MeshVector3(-8,8,5):MeshVector3(-7,8,5)
    keyLight.look(at:MeshVector3Zero);keyLight.light?.color=NSColor(hex:studio ? (classic ? "#FFF5E7":"#F8F7F1"):"#FFFFFF")
    keyLight.light?.shadowRadius=studio ? 9:5
    fill?.light?.intensity=classic ? 100:id=="soft-side-v1" ? 180:400
    fill?.position=classic ? MeshVector3(8,7,-5):id=="soft-side-v1" ? MeshVector3(6,5,-2):MeshVector3(6,6,-6)
    fill?.light?.color=NSColor(hex:studio ? "#E2EAF6":"#FFFFFF")
  }
}

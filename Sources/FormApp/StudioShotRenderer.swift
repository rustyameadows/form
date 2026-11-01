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
  func render(project:Project,shot:StudioShot,assets:URL,preview:Bool,renderObjectIDs:Set<UUID>?=nil,textureLimit:Int?=nil)async throws->NSImage {
    try await renderResult(project:project,shot:shot,assets:assets,preview:preview,renderObjectIDs:renderObjectIDs,textureLimit:textureLimit).image
  }
  func renderResult(project:Project,shot:StudioShot,assets:URL,preview:Bool,renderObjectIDs:Set<UUID>?=nil,textureLimit:Int?=nil)async throws->RenderResult {
    try shot.validate();let ids=try shot.visibility.resolved(in:project)
    // A capture owns this cached controller until the GPU has cloned/rendered
    // its complete composition, including any external-source preparation.
    // Waiting releases the UI actor; cancellation removes a queued preview.
    try await acquireCapture();defer{releaseCapture()}
    try validateCaptureArtwork(project:project,objectIDs:ids,assets:assets)
    let started=Date();defer{maximumMilliseconds=max(maximumMilliseconds,Date().timeIntervalSince(started)*1000);maximumProcessRSSBytes=max(maximumProcessRSSBytes,Self.rss())}
    if owner != project.id {clear();owner=project.id;controller=TableSceneController()}
    let c=controller!;c.externalCapturePreparationCheckpoint=externalPreparationCheckpoint
    var copy=project;copy.camera=shot.camera;copy.camera.viewportAspect=shot.referenceAspect
    let visible=renderObjectIDs.map{ids.intersection($0)} ?? ids
    let fullSolids=try await SolidRecipeGeometry.prepareFullSources(project:copy,objectIDs:visible)
    // Only this isolated capture controller receives a cheap geometry/bounds pass.
    // Ordinary editing and thumbnail sampling retain their established limits.
    let baseLimit=max(64,min(preview ? 2048:256,textureLimit ?? (preview ? 2048:256)))
    c.sync(copy,selection:[],isolated:ids,showGrid:false,studio:true,preset:shot.surface,assets:assets,
      textureLimit:baseLimit,renderObjectIDs:renderObjectIDs,solidSurfaces:fullSolids)
    // sync intentionally restores a camera only on a new project. Explicit render
    // composition uses its own owner and never mutates the native editing scene.
    c.camera=copy.camera;c.updateCamera();c.applyShotLighting(shot.lighting,studio:true)
    var outputCamera=c.cameraPayload()
    switch outputCamera.projection {
    case .orthographic(let span):outputCamera.projection = .orthographic(verticalSpanMM:span*shot.expansion)
    case .perspective:outputCamera.projection = .perspective(verticalFieldOfViewDegrees:shot.outputFieldOfView)
    }
    if !preview {
      let plans=try StudioSourceSampling.plans(controller:c,project:copy,camera:outputCamera,
        viewport:CGSize(width:shot.pixels.width,height:shot.pixels.height),objectIDs:visible,
        maximumEdge:max(64,min(SourceTextureSampling.maximumEdge,textureLimit ?? SourceTextureSampling.maximumEdge)))
      c.sync(copy,selection:[],isolated:ids,showGrid:false,studio:true,preset:shot.surface,assets:assets,
        textureLimit:baseLimit,renderObjectIDs:renderObjectIDs,sourceSampling:plans,solidSurfaces:fullSolids)
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
    var width=shot.pixels.width,height=shot.pixels.height
    if preview {let scale=min(1,1600/Double(max(width,height)),sqrt(2_000_000/Double(width*height)));width=max(1,Int(Double(width)*scale));height=max(1,Int(Double(height)*scale))}
    let capturedWarnings=framingWarnings
    let raw=try await c.snapshot(size:CGSize(width:width,height:height),camera:outputCamera)
    // AppKit may attach a backing-scale representation to the snapshot. Return
    // one explicitly sized bitmap, independent of the test/app display scale.
    guard let source=raw.cgImage(forProposedRect:nil,context:nil,hints:nil),let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw FormError.invalid("Could not normalize Studio output pixels.")}
    context.interpolationQuality = .high;context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
    guard let pixels=context.makeImage() else{throw FormError.invalid("Could not read Studio output pixels.")}
    let bitmap=NSBitmapImageRep(cgImage:pixels);bitmap.size=NSSize(width:width,height:height)
    let image=NSImage(size:bitmap.size);image.addRepresentation(bitmap)
    lastPixelBytes=width*height*4;renders+=1;return .init(image:image,framingWarnings:capturedWarnings)
  }
  /// Repeated presentation instances commonly share complete registered
  /// artwork. Validate each distinct resolved document once per capture; never
  /// carry a validation result across source revisions or explicit exports.
  func validateCaptureArtwork(project:Project,objectIDs:Set<UUID>,assets:URL)throws {
    var validated:[Artwork]=[];lastValidatedArtworkCount=0
    for object in project.objects where objectIDs.contains(object.id) {
      let artworks=PaperConstruction.isPaper(object) ? [project.paperArtwork(for:object,inside:false),project.paperArtwork(for:object,inside:true)].compactMap{$0}:[project.surfaceArtwork(object)].compactMap{$0}
      for art in artworks where !validated.contains(art) {
        try ArtworkRenderer.validateGlyphOutput(art,assets:assets)
        validated.append(art);lastValidatedArtworkCount+=1
      }
    }
  }
  static func resources(project:Project,assets:URL)throws->[[String:String]] {
    var result=[[String:String]](),total:Int64=0
    let fm=FileManager.default
    if let enumerator=fm.enumerator(at:assets,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey],options:[.skipsHiddenFiles]) {
      for case let file as URL in enumerator {
        let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isSymbolicLink != true else{throw FormError.invalid("Studio provenance does not follow asset symlinks.")}
        if values.isRegularFile==true {total+=Int64(values.fileSize ?? 0);guard result.count<4096,total<=2_147_483_648 else{throw FormError.invalid("Studio resource hashing exceeds its bounded project budget.")};result.append(["id":"asset:"+String(file.path.dropFirst(assets.path.count+1)),"sha256":try fileHash(file)])}
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

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
  private(set) var renders=0,maximumMilliseconds=0.0,maximumProcessRSSBytes:Int64=0
  private(set) var lastPixelBytes=0
  private(set) var framingWarnings:[[String:Any]]=[]
  func clear() {controller=nil;owner=nil;lastPixelBytes=0}
  var geometryBuilds:Int {controller?.geometryBuilds ?? 0}
  static func rss()->Int64 {var r=rusage();getrusage(RUSAGE_SELF,&r);return Int64(r.ru_maxrss)}
  struct RenderResult {var image:NSImage;var framingWarnings:[[String:Any]]}
  func render(project:Project,shot:StudioShot,assets:URL,preview:Bool)async throws->NSImage {
    try await renderResult(project:project,shot:shot,assets:assets,preview:preview).image
  }
  func renderResult(project:Project,shot:StudioShot,assets:URL,preview:Bool)async throws->RenderResult {
    try shot.validate();let ids=try shot.visibility.resolved(in:project)
    for object in project.objects where ids.contains(object.id) {if let art=project.surfaceArtwork(object) {try ArtworkRenderer.validateGlyphOutput(art,assets:assets)}}
    let started=Date();defer{maximumMilliseconds=max(maximumMilliseconds,Date().timeIntervalSince(started)*1000);maximumProcessRSSBytes=max(maximumProcessRSSBytes,Self.rss())}
    if owner != project.id {clear();owner=project.id;controller=TableSceneController()}
    let c=controller!;var copy=project;copy.camera=shot.camera;copy.camera.viewportAspect=shot.referenceAspect
    c.sync(copy,selection:[],isolated:ids,showGrid:false,studio:true,preset:shot.surface,assets:assets)
    // sync intentionally restores a camera only on a new project. Explicit render
    // composition uses its own owner and never mutates the native editing scene.
    c.camera=copy.camera;c.updateCamera();c.applyShotLighting(shot.lighting,studio:true)
    var outputCamera=c.cameraPayload()
    switch outputCamera.projection {
    case .orthographic(let span):outputCamera.projection = .orthographic(verticalSpanMM:span*shot.expansion)
    case .perspective:outputCamera.projection = .perspective(verticalFieldOfViewDegrees:shot.outputFieldOfView)
    }
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
    ambient?.light?.color=NSColor(hex:"#F7F7F2")
    keyLight.light?.intensity=classic ? (studio ? 850:800):id=="soft-side-v1" ? 900:650
    keyLight.position=classic ? MeshVector3(-6,12,7):id=="soft-side-v1" ? MeshVector3(-8,8,5):MeshVector3(-7,8,5)
    keyLight.look(at:MeshVector3Zero);keyLight.light?.color=NSColor(hex:classic ? "#FFF5E7":"#F8F7F1")
    keyLight.light?.shadowRadius=studio ? 9:5
    fill?.light?.intensity=classic ? 100:id=="soft-side-v1" ? 180:400
    fill?.position=classic ? MeshVector3(8,7,-5):id=="soft-side-v1" ? MeshVector3(6,5,-2):MeshVector3(6,6,-6)
    fill?.light?.color=NSColor(hex:"#E2EAF6")
  }
}

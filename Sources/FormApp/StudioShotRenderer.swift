import AppKit
import CoreText
import CryptoKit
import Darwin
import FormCore
import FormGraphics
import ImageIO
import Metal
import SceneKit

@MainActor final class StudioShotRenderer {
  private var owner:UUID?
  private var controller:TableSceneController?
  private(set) var renders=0,maximumMilliseconds=0.0,maximumProcessRSSBytes:Int64=0
  private(set) var lastPixelBytes=0
  private(set) var framingWarnings:[[String:Any]]=[]
  func clear() {controller=nil;owner=nil;lastPixelBytes=0}
  var geometryBuilds:Int {controller?.geometryBuilds ?? 0}
  static func rss()->Int64 {var r=rusage();getrusage(RUSAGE_SELF,&r);return Int64(r.ru_maxrss)}
  func render(project:Project,shot:StudioShot,assets:URL,preview:Bool)throws->NSImage {
    try shot.validate();let ids=try shot.visibility.resolved(in:project)
    for object in project.objects where ids.contains(object.id) {if let art=project.surfaceArtwork(object) {try ArtworkRenderer.validateGlyphOutput(art,assets:assets)}}
    let started=Date();defer{maximumMilliseconds=max(maximumMilliseconds,Date().timeIntervalSince(started)*1000);maximumProcessRSSBytes=max(maximumProcessRSSBytes,Self.rss())}
    if owner != project.id {clear();owner=project.id;controller=TableSceneController()}
    let c=controller!;var copy=project;copy.camera=shot.camera;copy.camera.viewportAspect=shot.referenceAspect
    c.sync(copy,selection:[],isolated:ids,showGrid:false,studio:true,preset:shot.surface,assets:assets)
    // sync intentionally restores a camera only on a new project. Explicit render
    // composition uses its own owner and never mutates the native editing scene.
    c.camera=copy.camera;c.updateCamera();c.applyShotLighting(shot.lighting,studio:true)
    let renderer=SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil);renderer.scene=c.scene
    let node=c.cameraNode.clone(),lens=c.cameraNode.camera!.copy() as! SCNCamera;node.camera=lens
    if lens.usesOrthographicProjection {lens.orthographicScale *= shot.expansion} else {lens.fieldOfView=shot.outputFieldOfView}
    lens.projectionTransform=lens.projectionTransform(withViewportSize:CGSize(width:shot.pixels.width,height:shot.pixels.height))
    framingWarnings=[]
    for subject in c.objectRoot.childNodes {
      guard let name=subject.name,name.hasPrefix("object:"),let id=UUID(uuidString:String(name.dropFirst(7))),ids.contains(id) else{continue}
      let b=subject.boundingBox,m=lens.projectionTransform;var outside=false
      for x in [b.min.x,b.max.x] {for y in [b.min.y,b.max.y] {for z in [b.min.z,b.max.z] {
        let local=node.convertPosition(subject.convertPosition(.init(x,y,z),to:nil),from:nil)
        let w=m.m14*local.x+m.m24*local.y+m.m34*local.z+m.m44
        let px=(m.m11*local.x+m.m21*local.y+m.m31*local.z+m.m41)/w
        let py=(m.m12*local.x+m.m22*local.y+m.m32*local.z+m.m42)/w
        if !px.isFinite || !py.isFinite || w<=0 || abs(px)>1 || abs(py)>1 || -local.z<0.01 || -local.z>1500 {outside=true}
      }}}
      if outside {framingWarnings.append(["object_id":id.uuidString,"bounds_extend_outside_frame_or_clip_range":true])}
    }
    c.scene.rootNode.addChildNode(node);defer{node.removeFromParentNode()};renderer.pointOfView=node
    var width=shot.pixels.width,height=shot.pixels.height
    if preview {let scale=min(1,1600/Double(max(width,height)),sqrt(2_000_000/Double(width*height)));width=max(1,Int(Double(width)*scale));height=max(1,Int(Double(height)*scale))}
    let raw=renderer.snapshot(atTime:0,with:CGSize(width:width,height:height),antialiasingMode:.multisampling4X)
    // AppKit may attach a backing-scale representation to the snapshot. Return
    // one explicitly sized bitmap, independent of the test/app display scale.
    guard let source=raw.cgImage(forProposedRect:nil,context:nil,hints:nil),let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw FormError.invalid("Could not normalize Studio output pixels.")}
    context.interpolationQuality = .high;context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
    guard let pixels=context.makeImage() else{throw FormError.invalid("Could not read Studio output pixels.")}
    let bitmap=NSBitmapImageRep(cgImage:pixels);bitmap.size=NSSize(width:width,height:height)
    let image=NSImage(size:bitmap.size);image.addRepresentation(bitmap)
    lastPixelBytes=width*height*4;renders+=1;return image
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
    SCNTransaction.begin();SCNTransaction.disableActions=true;SCNTransaction.animationDuration=0
    defer{SCNTransaction.commit();view?.needsDisplay=true}
    let ambient=scene.rootNode.childNodes.first{$0.light?.type == .ambient},fill=scene.rootNode.childNodes.first{$0.light?.type == .omni}
    let classic=id=="classic-v1" || !studio
    ambient?.light?.intensity=classic ? 400:id=="soft-side-v1" ? 250:200
    ambient?.light?.color=NSColor(hex:"#F7F7F2")
    keyLight.light?.intensity=classic ? (studio ? 850:800):id=="soft-side-v1" ? 900:650
    keyLight.position=classic ? SCNVector3(-6,12,7):id=="soft-side-v1" ? SCNVector3(-8,8,5):SCNVector3(-7,8,5)
    keyLight.look(at:SCNVector3Zero);keyLight.light?.color=NSColor(hex:classic ? "#FFF5E7":"#F8F7F1")
    keyLight.light?.shadowRadius=studio ? 9:5
    fill?.light?.intensity=classic ? 100:id=="soft-side-v1" ? 180:400
    fill?.position=classic ? SCNVector3(8,7,-5):id=="soft-side-v1" ? SCNVector3(6,5,-2):SCNVector3(6,6,-6)
    fill?.light?.color=NSColor(hex:"#E2EAF6")
  }
}

import AppKit
import SceneKit
import CryptoKit
import FormCore
import FormGraphics

@MainActor final class ClothSceneSurface {
  let root=SCNNode()
  let surface:ClothSurface
  private let colliders:[ClothCollider]
  var geometricBounds:(min:SCNVector3,max:SCNVector3) {
    var points=[surface.bounds.minimumMm,surface.bounds.maximumMm]
    for c in colliders where c.kind == .sphere {points += [.init(c.centerMm.x-c.radiusMm,c.centerMm.y-c.radiusMm,c.centerMm.z-c.radiusMm),.init(c.centerMm.x+c.radiusMm,c.centerMm.y+c.radiusMm,c.centerMm.z+c.radiusMm)]}
    let b=try! ClothBounds(positionsMm:points)
    return (SCNVector3(b.minimumMm.x/100,b.minimumMm.y/100,b.minimumMm.z/100),SCNVector3(b.maximumMm.x/100,b.maximumMm.y/100,b.maximumMm.z/100))
  }
  init(object:ProductObject,project:Project,frame:ClothFrame? = nil,assets:URL,textureLimit:Int = 2048)throws {
    guard let study=object.cloth else {throw FormError.invalid("This object has no cloth study.")}
    colliders=study.colliders
    let initial=try frame ?? ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders).frame
    surface=try ClothSurface(mesh:study.mesh,frame:initial,material:Self.material(object:object,project:project,assets:assets,textureLimit:textureLimit))
    surface.node.name="cloth.surface";surface.node.categoryBitMask=2;root.addChildNode(surface.node)
    for collider in study.colliders where collider.kind == .sphere {
      let sphere=SCNSphere(radius:collider.radiusMm/100);sphere.segmentCount=64
      let material=SCNMaterial();material.lightingModel = .physicallyBased;material.diffuse.contents=NSColor(hex:"#66716E");material.roughness.contents=0.85;sphere.materials=[material]
      let node=SCNNode(geometry:sphere);node.name="cloth.static-support";node.categoryBitMask=4;node.position=SCNVector3(collider.centerMm.x/100,collider.centerMm.y/100,collider.centerMm.z/100);root.addChildNode(node)
    }
  }
  func update(_ frame:ClothFrame)throws {try surface.update(frame)}
  static func sourceIdentity(object:ProductObject,project:Project)->ClothSourceIdentity {
    var data=(try? JSONEncoder.form.encode(object.cloth)) ?? Data()
    data.append((try? JSONEncoder.form.encode(project.material(object.materialID))) ?? Data())
    data.append(Data((object.color ?? "").utf8))
    data.append(project.surfaceArtwork(object).flatMap {try? $0.renderCacheData()} ?? Data())
    if let pattern=try? project.resolvedFabricPattern(materialID:object.materialID) {data.append((try? JSONEncoder.form.encode(pattern.renderDefinition)) ?? Data())}
    data.append(Data("font:\(GeometryFactory.fontRevision)".utf8))
    let revision=SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
    return .init(projectID:project.id,objectID:object.id,revision:revision)
  }
  private static let images:NSCache<NSString,NSImage> = {let c=NSCache<NSString,NSImage>();c.countLimit=8;c.totalCostLimit=32_000_000;return c}()
  static func material(object:ProductObject,project:Project,assets:URL,textureLimit:Int)->SCNMaterial {
    let material=GeometryFactory.material(object,project:project),width=object.artworkSize.x,height=object.artworkSize.y
    let pattern=try? project.resolvedFabricPattern(materialID:object.materialID),art=project.surfaceArtwork(object)
    guard pattern != nil || art != nil else {return material}
    let limit=min(2048,max(128,textureLimit)),key="\(sourceIdentity(object:object,project:project).revision):\(assets.path):\(limit)" as NSString
    if let image=images.object(forKey:key) {material.diffuse.contents=image;return material}
    let density=Double(limit)/max(width,height),pixels=NSSize(width:max(1,ceil(width*density)),height:max(1,ceil(height*density)))
    guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(pixels.width),pixelsHigh:Int(pixels.height),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context=NSGraphicsContext(bitmapImageRep:bitmap) else {return material}
    bitmap.size=pixels
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
    NSColor(hex:object.color ?? project.material(object.materialID).color).setFill();NSRect(origin:.zero,size:pixels).fill()
    if let base=material.diffuse.contents as? NSImage {base.draw(in:NSRect(origin:.zero,size:pixels))}
    if let pattern,let texture=try? FabricPatternRenderer.image(pattern,assets:assets,width:width,height:height,pixelsPerMM:density) {texture.draw(in:NSRect(origin:.zero,size:pixels))}
    if let art {ArtworkDrawing.image(art,width:width,height:height,assets:assets,pixelsPerMM:density).draw(in:NSRect(origin:.zero,size:pixels),from:.zero,operation:.sourceOver,fraction:1)}
    NSGraphicsContext.restoreGraphicsState()
    let image=NSImage(size:pixels);image.addRepresentation(bitmap);images.setObject(image,forKey:key,cost:bitmap.bytesPerRow*bitmap.pixelsHigh)
    material.diffuse.contents=image;return material
  }
}

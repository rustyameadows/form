import AppKit
import FormGeometry
import CryptoKit
import simd
import FormCore
import FormGraphics

@MainActor final class ClothSceneSurface {
  let root=MeshNode()
  let surface:ClothSurface
  private let colliders:[ClothCollider]
  var geometricBounds:(min:MeshVector3,max:MeshVector3) {
    var points=[surface.bounds.minimumMm,surface.bounds.maximumMm]
    for c in colliders where c.kind == .sphere {points += [.init(c.centerMm.x-c.radiusMm,c.centerMm.y-c.radiusMm,c.centerMm.z-c.radiusMm),.init(c.centerMm.x+c.radiusMm,c.centerMm.y+c.radiusMm,c.centerMm.z+c.radiusMm)]}
    let b=try! ClothBounds(positionsMm:points)
    return (MeshVector3(b.minimumMm.x/100,b.minimumMm.y/100,b.minimumMm.z/100),MeshVector3(b.maximumMm.x/100,b.maximumMm.y/100,b.maximumMm.z/100))
  }
  init(object:ProductObject,project:Project,frame:ClothFrame? = nil,assets:URL,textureLimit:Int = 2048)throws {
    let assembly=try AssemblyProducts.product(for:object,in:project)
    guard let study=object.cloth ?? assembly?.study else {throw FormError.invalid("This object has no cloth study.")}
    colliders=study.colliders
    let initial=try frame ?? ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders,preparation:study.preparation).frame
    if let assembly,let source=object.patternAssembly.flatMap({id in project.objects.first(where:{$0.id==id.sourceObjectID})?.artwork}) {
      let materials=try Dictionary(uniqueKeysWithValues:assembly.panels.map {($0.panelIndex,try AssemblyMaterialRenderer.material(panel:$0,source:source,project:project,assets:assets,fontRevision:GeometryFactory.fontRevision,textureLimit:textureLimit))})
      surface=try ClothSurface(mesh:study.mesh,frame:initial,panelMaterials:materials,fallbackMaterial:GeometryFactory.material(object,project:project))
    } else {surface=try ClothSurface(mesh:study.mesh,frame:initial,material:Self.material(object:object,project:project,assets:assets,textureLimit:textureLimit))}
    surface.node.name="cloth.surface";surface.node.categoryBitMask=2;root.addChildNode(surface.node)
    for collider in study.colliders where collider.kind == .sphere {
      let sphere=MeshSphere(radius:collider.radiusMm/100);sphere.segmentCount=64
      let material=MeshMaterial();material.lightingModel = .physicallyBased;material.diffuse.contents=NSColor(hex:"#66716E");material.roughness.contents=0.85;sphere.materials=[material]
      let node=MeshNode(geometry:sphere);node.name="cloth.static-support";node.categoryBitMask=4;node.position=MeshVector3(collider.centerMm.x/100,collider.centerMm.y/100,collider.centerMm.z/100);root.addChildNode(node)
    }
  }
  /// Supports are declared opaque analytic spheres. Test the actual segment
  /// against those same physical shapes: SceneKit may not expose a primitive's
  /// CPU hit mesh before its first rendered frame.
  func supportOccludes(from startWorld:MeshVector3,to endWorld:MeshVector3)->Bool {
    let a=root.convertPosition(startWorld,from:nil),b=root.convertPosition(endWorld,from:nil)
    let start=SIMD3<Double>(Double(a.x)*100,Double(a.y)*100,Double(a.z)*100),end=SIMD3<Double>(Double(b.x)*100,Double(b.y)*100,Double(b.z)*100),direction=end-start,length=simd_length_squared(direction)
    guard length.isFinite,length>1e-12 else{return false}
    for shape in colliders where shape.kind == .sphere {
      let center=SIMD3<Double>(shape.centerMm.x,shape.centerMm.y,shape.centerMm.z),t=max(0,min(1,simd_dot(center-start,direction)/length)),closest=start+direction*t,radius=max(0,shape.radiusMm-1e-5)
      if simd_length_squared(closest-center)<radius*radius {return true}
    }
    return false
  }
  func update(_ frame:ClothFrame)throws {try surface.update(frame)}
  static func sourceIdentity(object:ProductObject,project:Project)->ClothSourceIdentity {
    var data=(try? JSONEncoder.form.encode(object.cloth)) ?? Data()
    if let assembly=object.patternAssembly {
      data.append((try? JSONEncoder.form.encode(assembly)) ?? Data())
      // Runtime geometry/pose identity alone ignores the two nonprinting page
      // guides. Authoritative generator/product/preparation digests stay exact.
      var physicalSource=project
      if let i=physicalSource.objects.firstIndex(where:{$0.id==assembly.sourceObjectID}) {
        physicalSource.objects[i].artwork?.bleed=0;physicalSource.objects[i].artwork?.safeInset=nil
      }
      data.append(Data("runtime-assembly-page-guides-v1".utf8))
      data.append(Data(((try? PatternAssemblyGenerator.sourceDigest(assembly,in:physicalSource)) ?? "invalid-source").utf8))
      if let source=project.objects.first(where:{$0.id==assembly.sourceObjectID})?.artwork,
        let printArt=try? AssemblyMaterialRenderer.resolvedDecoration(source,project:project,sourceObjectID:assembly.sourceObjectID) {data.append((try? printArt.renderCacheData()) ?? Data())}
      for panel in assembly.panels {var snapshot=project;snapshot.materials.removeAll{$0.id==panel.material.id};snapshot.materials.append(panel.material)
        if let repeatDesign=try? snapshot.resolvedFabricPattern(materialID:panel.material.id) {data.append((try? JSONEncoder.form.encode(repeatDesign.renderDefinition)) ?? Data())}
      }
    }
    data.append((try? JSONEncoder.form.encode(project.material(object.materialID))) ?? Data())
    data.append(Data((object.color ?? "").utf8))
    data.append(project.surfaceArtwork(object).flatMap {try? $0.renderCacheData()} ?? Data())
    if let pattern=try? project.resolvedFabricPattern(materialID:object.materialID) {data.append((try? JSONEncoder.form.encode(pattern.renderDefinition)) ?? Data())}
    data.append(Data("font:\(GeometryFactory.fontRevision)".utf8))
    let revision=SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
    return .init(projectID:project.id,objectID:object.id,revision:revision)
  }
  private static let images:NSCache<NSString,NSImage> = {let c=NSCache<NSString,NSImage>();c.countLimit=8;c.totalCostLimit=32_000_000;return c}()
  static func material(object:ProductObject,project:Project,assets:URL,textureLimit:Int)->MeshMaterial {
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

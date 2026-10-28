import AppKit
import CryptoKit
import SceneKit
import FormCore

/// Physical panel crops use the original source2D coordinates. Construction
/// shapes/annotations never become implicit ink; only printable content draws.
@MainActor public enum AssemblyMaterialRenderer {
  public nonisolated static let maximumTextureEdge=1024
  private static let cache:NSCache<NSString,NSImage> = {let c=NSCache<NSString,NSImage>();c.countLimit=8;c.totalCostLimit=32_000_000;return c}()
  public private(set) static var textureBuilds=0
  public static func invalidate() {cache.removeAllObjects()}
  public static func decoration(_ source:Artwork)throws -> Artwork {
    var input=source
    for i in input.elements.indices where input.elements[i].sewingPiece != nil {input.elements[i].productionRole="guide"}
    var art=try ArtworkProduction.filtered(input,roles:[.print]).artwork
    art.backgroundOpacity=0;art.boundary=nil;art.sewingSeams=nil;art.sewingLayout=nil
    for i in art.elements.indices {art.elements[i].sewingPiece=nil}
    return art
  }
  public static func resolvedDecoration(_ source:Artwork,project:Project,sourceObjectID:UUID?)throws -> Artwork {
    let stories=sourceObjectID.map{project.resolvingTextStories(in:source,objectID:$0)} ?? source
    let components=try project.resolvingComponents(in:stories)
    return try decoration(project.resolvingSwatches(in:components))
  }
  public static func material(panel:PatternAssemblyPanel,source:Artwork,project:Project,assets:URL,fontRevision:Int,textureLimit:Int = maximumTextureEdge)throws -> SCNMaterial {
    let image=try texture(panel:panel,source:source,project:project,assets:assets,fontRevision:fontRevision,textureLimit:textureLimit)
    let material=SCNMaterial();material.name="Assembly fabric / \(panel.material.id) / \(panel.id.key)";material.lightingModel = .physicallyBased;material.roughness.contents=panel.material.roughness;material.metalness.contents=panel.material.metallic;material.diffuse.contents=image;material.isDoubleSided=true;return material
  }
  public static func texture(panel:PatternAssemblyPanel,source:Artwork,project:Project,assets:URL,fontRevision:Int,textureLimit:Int = maximumTextureEdge)throws -> NSImage {
    let owner=project.objects.first(where:{$0.artwork?.elements.contains(where:{$0.id==panel.id.elementID})==true})
    let art=try resolvedDecoration(source,project:project,sourceObjectID:owner?.id),width=panel.materialSizeMm.x,height=panel.materialSizeMm.y,limit=min(maximumTextureEdge,max(64,textureLimit))
    guard width.isFinite,height.isFinite,(1...2000).contains(width),(1...2000).contains(height) else {throw FormError.invalid("Assembly material dimensions exceed their physical raster budget.")}
    var snapshot=project;snapshot.materials.removeAll{$0.id==panel.material.id};snapshot.materials.append(panel.material)
    var repeatDesign=try snapshot.resolvedFabricPattern(materialID:panel.material.id)
    if repeatDesign != nil {repeatDesign!.pattern.offset.x-=panel.textureOriginMm.x;repeatDesign!.pattern.offset.y-=panel.textureOriginMm.y}
    var data=try JSONEncoder.form.encode(panel.material);data.append(try art.renderCacheData())
    if let repeatDesign {data.append(try JSONEncoder.form.encode(repeatDesign.renderDefinition))}
    data.append(Data("\(width),\(height),\(panel.sourceOriginMm.x),\(panel.sourceOriginMm.y),\(panel.textureOriginMm.x),\(panel.textureOriginMm.y),\(fontRevision),\(limit),\(assets.path)".utf8))
    let key=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() as NSString
    if let cached=cache.object(forKey:key) {return cached}
    let density=Double(limit)/max(width,height),w=max(1,Int(ceil(width*density))),h=max(1,Int(ceil(height*density)))
    guard let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw FormError.invalid("The bounded assembly material image could not be allocated.")}
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
    context.translateBy(x:0,y:Double(h));context.scaleBy(x:density,y:-density)
    context.setFillColor(FormColor.color(panel.material.color).cgColor);context.fill(.init(x:0,y:0,width:width,height:height))
    // A bounded millimeter weave cue is appearance only, never constitutive data.
    if panel.material.fabric?.structure == .woven {
      context.setStrokeColor(FormColor.color(panel.material.color).blended(withFraction:0.12,of:.white)!.cgColor);context.setLineWidth(0.16)
      for x in stride(from:0.0,through:width,by:1.2) {context.move(to:.init(x:x,y:0));context.addLine(to:.init(x:x,y:height))}
      for y in stride(from:0.0,through:height,by:1.2) {context.move(to:.init(x:0,y:y));context.addLine(to:.init(x:width,y:y))};context.strokePath()
    }
    if let repeatDesign {
      FabricPatternRenderer.drawPreview(repeatDesign,assets:assets,width:width,height:height,textureLimit:limit,fontRevision:fontRevision)
    }
    context.saveGState();context.translateBy(x:-panel.sourceOriginMm.x,y:-panel.sourceOriginMm.y)
    ArtworkRenderer.draw(art,width:width,height:height,assets:assets,unbounded:true)
    context.restoreGState();NSGraphicsContext.restoreGraphicsState()
    guard let cg=context.makeImage() else {throw FormError.invalid("Assembly material rasterization failed.")}
    let bitmap=NSBitmapImageRep(cgImage:cg),image=NSImage(size:.init(width:w,height:h));image.addRepresentation(bitmap)
    textureBuilds+=1;cache.setObject(image,forKey:key,cost:bitmap.bytesPerRow*bitmap.pixelsHigh);return image
  }
}

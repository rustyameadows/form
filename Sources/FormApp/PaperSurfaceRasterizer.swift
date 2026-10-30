import AppKit
import CryptoKit
import FormCore
import FormGraphics
import simd

/// Derived, content-addressed viewing maps. The saved artwork and process
/// assignments stay editable; these maps are never production tooling.
@MainActor enum PaperSurfaceRasterizer {
  final class Maps: NSObject {
    let color: NSImage, normal: NSImage, roughness: NSImage, metallic: NSImage
    let width: Int, height: Int
    let rectMM: PaperBounds
    let revision: String
    var cost: Int { width * height * 16 }
    init(color: NSImage, normal: NSImage, roughness: NSImage, metallic: NSImage,
      width: Int, height: Int, rectMM: PaperBounds, revision: String) {
      self.color=color;self.normal=normal;self.roughness=roughness;self.metallic=metallic
      self.width=width;self.height=height;self.rectMM=rectMM;self.revision=revision
    }
  }
  private struct Key: Encodable {
    let version: Int, rect: PaperBounds, netSize: Point2, profile: PaperSurfaceProfile
    let color: String, grain: PaperStock.Grain, artwork: Artwork?, finishes: [PaperFinishAssignment]
    let width: Int, height: Int, fontRevision: Int, assets: String
  }
  private static let cache: NSCache<NSString, Maps> = {
    let cache=NSCache<NSString,Maps>();cache.countLimit=80;cache.totalCostLimit=192*1024*1024;return cache
  }()
  private final class StockField:NSObject {
    let heights:[Float],color:[UInt8],roughness:[UInt8],normal:NSImage,roughnessImage:NSImage
    init(heights:[Float],color:[UInt8],roughness:[UInt8],normal:NSImage,roughnessImage:NSImage){self.heights=heights;self.color=color;self.roughness=roughness;self.normal=normal;self.roughnessImage=roughnessImage}
    var cost:Int{heights.count*20}
  }
  private struct StockKey:Encodable {let rect:PaperBounds,profile:PaperSurfaceProfile,color:String,grain:PaperStock.Grain,width:Int,height:Int}
  private static let stockCache:NSCache<NSString,StockField>={let value=NSCache<NSString,StockField>();value.totalCostLimit=128*1024*1024;value.countLimit=80;return value}()
  private static let glyphCache:NSCache<NSString,NSObject>={let value=NSCache<NSString,NSObject>();value.countLimit=128;return value}()
  private static var blackMap:NSImage?
  private(set) static var builds = 0

  static func make(rect: PaperBounds, netSize: Point2, profile: PaperSurfaceProfile,
    color: String, grain: PaperStock.Grain, artwork: Artwork?, finishes: [PaperFinishAssignment],
    assets: URL, maximumEdge: Int, pixelBudget: Int) throws -> Maps {
    guard [rect.x,rect.y,rect.width,rect.height,netSize.x,netSize.y].allSatisfy(\.isFinite),rect.width>0,rect.height>0,netSize.x>0,netSize.y>0,pixelBudget>0 else{throw FormError.invalid("Paper viewing maps require finite positive physical bounds and a pixel budget.")}
    let edge=max(128,min(4096,maximumEdge)), area=rect.width*rect.height
    let density=min(Double(edge)/max(rect.width,rect.height),sqrt(Double(pixelBudget)/area))
    let width=max(1,Int(floor(rect.width*density))),height=max(1,Int(floor(rect.height*density)))
    guard width*height<=16_000_000 else { throw FormError.invalid("Paper viewing maps exceed their bounded pixel allocation.") }
    let key=Key(version:1,rect:rect,netSize:netSize,profile:profile,color:color,grain:grain,
      artwork:artwork,finishes:finishes,width:width,height:height,fontRevision:GeometryFactory.fontRevision,assets:assets.path)
    let revision=SHA256.hash(data:try JSONEncoder.form.encode(key)).map{String(format:"%02x",$0)}.joined()
    if let maps=cache.object(forKey:revision as NSString) { return maps }
    if let artwork {
      var bytes=try artwork.renderCacheData();bytes.append(Data("\(GeometryFactory.fontRevision):\(assets.path)".utf8))
      let key=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined() as NSString
      if glyphCache.object(forKey:key)==nil {try ArtworkRenderer.validateGlyphOutput(artwork,assets:assets);glyphCache.setObject(NSObject(),forKey:key)}
    }
    let count=width*height,dx=rect.width/Double(width),dy=rect.height/Double(height)
    let field=try stockField(rect:rect,profile:profile,color:color,grain:grain,width:width,height:height)
    var heights=field.heights,rgba=field.color,rough=field.roughness,metal=[UInt8](repeating:255,count:count*4)
    for i in 0..<count {for c in 0..<3{metal[i*4+c]=0}}
    var hasRelief=false,hasFinish=false
    if let artwork {
      let printArt=try ArtworkProduction.filtered(artwork,roles:[.print]).artwork
      let inkArt=try printArtwork(printArt,finishes:finishes)
      let pixels=try raster(inkArt,rect:rect,netSize:netSize,width:width,height:height,assets:assets)
      for i in 0..<count { let j=i*4,a=Double(pixels[j+3])/255
        for c in 0..<3 { rgba[j+c]=UInt8(min(255,Int((Double(pixels[j+c])+Double(field.color[j+c])*(1-a)).rounded()))) }
      }
      var priorFoil=false
      for finish in finishes where finish.enabled {
        let selected=try maskArtwork(printArt,elementIDs:Set(finish.elementIDs))
        guard !selected.elements.isEmpty else { continue }
        hasFinish=true
        let maskPixels=try raster(selected,rect:rect,netSize:netSize,width:width,height:height,assets:assets)
        let ink=finish.color.flatMap { FormColor.color($0).usingColorSpace(.sRGB) }
        let paintsConductor=finish.kind == .foil,restoresInk=priorFoil && isInk(finish.kind)
        let sourcePaint=paintsConductor ? printArt:inkArt
        let originalPixels=(paintsConductor || restoresInk) && ink==nil ? try raster(selectedArtwork(sourcePaint,elementIDs:Set(finish.elementIDs)),rect:rect,netSize:netSize,width:width,height:height,assets:assets):nil
        let targetR=finish.roughness ?? (finish.kind == .foil ? 0.18:finish.kind == .screenPrint ? 0.55:0.85)
        let targetM=finish.metallic ?? (finish.kind == .foil ? 1:0)
        let relief=finish.heightMM-finish.depthMM
        hasRelief = hasRelief || relief != 0
        var coverage=[Float](repeating:0,count:count)
        for i in 0..<count {
          let j=i*4,a=Double(maskPixels[j+3])/255*finish.opacity
          coverage[i]=Float(a)
          guard a>0 else { continue }
          heights[i]+=Float(relief*a)
          if paintsConductor || restoresInk {
            if let ink {
              let values=[ink.redComponent,ink.greenComponent,ink.blueComponent]
              for c in 0..<3 {rgba[j+c]=byte(Double(rgba[j+c])/255*(1-a)+values[c]*a)}
            } else if let originalPixels {
              let alpha=max(1,Double(originalPixels[j+3]))
              for c in 0..<3 {rgba[j+c]=byte(Double(rgba[j+c])/255*(1-a)+Double(originalPixels[j+c])/alpha*a)}
            }
          }
          for c in 0..<3 {
            rough[j+c]=byte(Double(rough[j+c])/255*(1-a)+targetR*a)
            metal[j+c]=byte(Double(metal[j+c])/255*(1-a)+targetM*a)
          }
        }
        // A physically sized shoulder avoids a single-texel vertical wall in
        // the normal field while the separate ink/foil mask remains crisp.
        if relief != 0 {
          let smoothed=blur(coverage,width:width,height:height,radius:min(6,max(1,Int((0.035/max(dx,dy)).rounded()))))
          for i in 0..<count { heights[i]+=Float(relief)*(smoothed[i]-coverage[i]) }
        }
        priorFoil = priorFoil || paintsConductor
      }
    }
    let normalImage=try hasRelief ? image(normals(heights,width:width,height:height,dx:dx,dy:dy),width:width,height:height,linear:true):field.normal
    if blackMap==nil {blackMap=try image([0,0,0,255],width:1,height:1,linear:true)}
    let maps=try Maps(color:image(rgba,width:width,height:height,linear:false),normal:normalImage,
      roughness:hasFinish ? image(rough,width:width,height:height,linear:true):field.roughnessImage,
      metallic:hasFinish ? image(metal,width:width,height:height,linear:true):blackMap!,
      width:width,height:height,rectMM:rect,revision:revision)
    builds+=1;cache.setObject(maps,forKey:revision as NSString,cost:maps.cost);return maps
  }
  private static func stockField(rect:PaperBounds,profile:PaperSurfaceProfile,color:String,grain:PaperStock.Grain,width:Int,height:Int)throws->StockField {
    let key=SHA256.hash(data:try JSONEncoder.form.encode(StockKey(rect:rect,profile:profile,color:color,grain:grain,width:width,height:height))).map{String(format:"%02x",$0)}.joined() as NSString
    if let field=stockCache.object(forKey:key){return field}
    let count=width*height,dx=rect.width/Double(width),dy=rect.height/Double(height)
    let base=FormColor.color(profile.color ?? color).usingColorSpace(.sRGB) ?? .white
    var heights=[Float](repeating:0,count:count),stock=[UInt8](repeating:255,count:count*4),rough=stock
    for y in 0..<height {for x in 0..<width {
      let i=y*width+x,px=rect.x+(Double(x)+0.5)*dx,py=rect.y+(Double(y)+0.5)*dy,tooth=toothHeight(x:px,y:py,profile:profile,grain:grain)
      heights[i]=Float(tooth)
      let texture=profile.textureDepthMM>0 ? tooth/profile.textureDepthMM:0
      let fleck=profile.texture == .recycled ? max(0,noise(px/0.14,py/0.38)-0.2)*0.13:0
      let shade=max(0.75,min(1.02,1+texture*0.035-fleck)),j=i*4
      stock[j]=byte(base.redComponent*shade);stock[j+1]=byte(base.greenComponent*shade);stock[j+2]=byte(base.blueComponent*shade)
      let r=byte(profile.roughness+texture*0.04);for c in 0..<3{rough[j+c]=r}
    }}
    let value=try StockField(heights:heights,color:stock,roughness:rough,normal:image(normals(heights,width:width,height:height,dx:dx,dy:dy),width:width,height:height,linear:true),roughnessImage:image(rough,width:width,height:height,linear:true))
    stockCache.setObject(value,forKey:key,cost:value.cost);return value
  }
  private static func normals(_ heights:[Float],width:Int,height:Int,dx:Double,dy:Double)->[UInt8] {
    var normal=[UInt8](repeating:255,count:width*height*4)
    for y in 0..<height { for x in 0..<width {
      let i=y*width+x,j=i*4
      let gx=Double(heights[y*width+min(width-1,x+1)]-heights[y*width+max(0,x-1)])/max(1e-12,Double(min(width-1,x+1)-max(0,x-1))*dx)
      let gy=Double(heights[min(height-1,y+1)*width+x]-heights[max(0,y-1)*width+x])/max(1e-12,Double(min(height-1,y+1)-max(0,y-1))*dy)
      let n=simd_normalize(SIMD3(-gx,-gy,1))
      normal[j]=byte(n.x*0.5+0.5);normal[j+1]=byte(n.y*0.5+0.5);normal[j+2]=byte(n.z*0.5+0.5)
    } }
    return normal
  }

  private static func isInk(_ kind:PaperFinishAssignment.Kind)->Bool {kind == .flatInk || kind == .letterpress || kind == .screenPrint}

  /// Ordinary RGB print appearance, shared with registered vector output.
  /// Foil and blind outlines do not silently become ink. An explicit ink
  /// assignment can retain ink beneath a separate finish on the same source.
  /// This is a display-color interpretation, not an inferred CMYK separation.
  static func printArtwork(_ artwork:Artwork,finishes:[PaperFinishAssignment])throws->Artwork {
    let source=try BooleanGeometry.materialized(ArtworkProduction.filtered(artwork,roles:[.print]).artwork)
    let active=finishes.filter(\.enabled),ink=active.filter{isInk($0.kind)}
    let explicit=source.descendants(of:Set(ink.flatMap(\.elementIDs)))
    let excluded=source.descendants(of:Set(active.filter{$0.kind == .foil || $0.kind == .emboss || $0.kind == .deboss}.flatMap(\.elementIDs))).subtracting(explicit)
    let masks=Set(source.elements.compactMap(\.clipID))
    let content=Set(source.elements.filter{$0.kind != "group" && !masks.contains($0.id) && !excluded.contains($0.id)}.map(\.id))
    var art=source;let keep=dependencies(in:source,ids:content)
    art.elements=art.elements.filter{keep.contains($0.id)}
    let baseline=Dictionary(uniqueKeysWithValues:source.elements.map{($0.id,$0)})
    for finish in ink {
      let selected=source.descendants(of:Set(finish.elementIDs)),roots=Set(source.selectionRoots(Set(finish.elementIDs)).map(\.id))
      for i in art.elements.indices where selected.contains(art.elements[i].id) && !masks.contains(art.elements[i].id) {
        if let color=finish.color {
          try validateColor(color)
          guard art.elements[i].kind != "image" else{throw FormError.invalid("A colored ink override on a bitmap needs a raster ink plate; retain its original image colors or use a vector mask.")}
          recolor(&art.elements[i],paintColor:color)
        }
        if roots.contains(art.elements[i].id){art.elements[i].opacity=(baseline[art.elements[i].id]?.opacity ?? 1)*finish.opacity}
      }
    }
    return art
  }

  /// Shared registered process-mask source. Callers first resolve project text
  /// styles, stories, components and swatches. Geometry, transforms, clipping
  /// and paint alpha survive; shadows/blur do not become physical tooling.
  /// Bitmap sources retain their alpha and require an alpha-mask raster plate.
  static func maskArtwork(_ artwork:Artwork,elementIDs:Set<UUID>,paintColor:String="#FFFFFF")throws->Artwork {
    try validateColor(paintColor)
    var art=try selectedArtwork(artwork,elementIDs:elementIDs)
    for i in art.elements.indices {recolor(&art.elements[i],paintColor:paintColor)}
    return art
  }
  private static func dependencies(in artwork:Artwork,ids:Set<UUID>)->Set<UUID> {
    var keep=ids
    let byID=Dictionary(uniqueKeysWithValues:artwork.elements.map{($0.id,$0)})
    for _ in 0...artwork.elements.count {
      let previous=keep
      for id in Array(keep) {
        var parent=byID[id]?.parentID,seen=Set<UUID>()
        while let id=parent,seen.insert(id).inserted {keep.insert(id);parent=byID[id]?.parentID}
        if let clip=byID[id]?.clipID {keep.formUnion(artwork.descendants(of:[clip]))}
      }
      if previous==keep{break}
    }
    return keep
  }
  private static func selectedArtwork(_ artwork:Artwork,elementIDs:Set<UUID>)throws->Artwork {
    var art=try BooleanGeometry.materialized(artwork)
    let keep=dependencies(in:art,ids:art.descendants(of:elementIDs))
    art.elements=art.elements.filter{keep.contains($0.id)}
    art.backgroundOpacity=0
    for i in art.elements.indices {art.elements[i].shadow=nil;art.elements[i].blur=nil}
    return art
  }
  private static func recolor(_ element:inout ArtworkElement,paintColor:String) {
    // Canonical colors are RGB. Their alpha is stored independently on the
    // element/group, stroke and gradient stops; never quantize or move it.
    element.color=paintColor;element.fillSwatchID=nil
    if var stroke=element.stroke {stroke.color=paintColor;stroke.swatchID=nil;element.stroke=stroke}
    if var gradient=element.gradient {for j in gradient.stops.indices{gradient.stops[j].color=paintColor;gradient.stops[j].swatchID=nil};element.gradient=gradient}
    if var runs=element.textRuns {for j in runs.indices{runs[j].color=paintColor;runs[j].swatchID=nil};element.textRuns=runs}
  }
  private static func raster(_ artwork: Artwork, rect: PaperBounds, netSize: Point2,
    width: Int, height: Int, assets: URL,excluding:Set<UUID>=[]) throws -> [UInt8] {
    var pixels=[UInt8](repeating:0,count:width*height*4)
    let succeeded=pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.translateBy(x:0,y:Double(height));context.scaleBy(x:Double(width)/rect.width,y:-Double(height)/rect.height)
      context.translateBy(x:-rect.x,y:-rect.y)
      NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
      ArtworkRenderer.draw(artwork,width:netSize.x,height:netSize.y,assets:assets,excluding:excluding)
      NSGraphicsContext.restoreGraphicsState();return true
    }
    guard succeeded else { throw FormError.invalid("Paper artwork viewing pixels could not be allocated.") };return pixels
  }
  private static func image(_ bytes:[UInt8],width:Int,height:Int,linear:Bool)throws->NSImage {
    guard let provider=CGDataProvider(data:Data(bytes) as CFData),let cg=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,
      bytesPerRow:width*4,space:CGColorSpace(name:linear ? CGColorSpace.linearSRGB:CGColorSpace.sRGB)!,
      bitmapInfo:.init(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    else { throw FormError.invalid("Paper viewing map could not be published.") }
    return NSImage(cgImage:cg,size:.init(width:width,height:height))
  }
  private static func byte(_ value:Double)->UInt8 { UInt8(max(0,min(255,Int((value*255).rounded())))) }
  private static func noise(_ x:Double,_ y:Double)->Double {
    func hash(_ x:Int,_ y:Int)->Double {var n=UInt64(bitPattern:Int64(x)) &* 0x9E3779B185EBCA87;n ^= UInt64(bitPattern:Int64(y)) &* 0xC2B2AE3D27D4EB4F;n ^= n>>29;n &*= 0x165667B19E3779F9;return Double(n&65535)/65535-0.5}
    let ix=Int(floor(x)),iy=Int(floor(y)),fx=x-floor(x),fy=y-floor(y),u=fx*fx*(3-2*fx),v=fy*fy*(3-2*fy)
    let a=hash(ix,iy)*(1-u)+hash(ix+1,iy)*u,b=hash(ix,iy+1)*(1-u)+hash(ix+1,iy+1)*u
    return a*(1-v)+b*v
  }
  static func toothHeight(x:Double,y:Double,profile:PaperSurfaceProfile,grain:PaperStock.Grain)->Double {
    let s=profile.textureScaleMM
    let x=x/s,y=y/s
    let directional=grain == .parallelHeight ? noise(x*3,y*0.7):grain == .parallelWidth ? noise(x*0.7,y*3):noise(x,y)
    let value:Double
    switch profile.texture {
    case .smooth:value=noise(x*5,y*5)*0.08
    case .coated:value=noise(x*7,y*7)*0.025
    case .cotton:value=directional*0.65+noise(x*4,y*4)*0.25+noise(x*12,y*12)*0.1
    case .laid:value=sin((grain == .parallelHeight ? x:y)*2 * .pi)*0.34+directional*0.18
    case .linen:value=(sin(x*2 * .pi)*sin(y*2 * .pi))*0.32+directional*0.2
    case .recycled:value=directional*0.65+noise(x*9,y*9)*0.28
    case .vellum:value=noise(x*2,y*2)*0.1
    }
    return value*profile.textureDepthMM
  }
  private static func blur(_ values:[Float],width:Int,height:Int,radius:Int)->[Float] {
    var horizontal=values,result=values
    for y in 0..<height { for x in 0..<width {
      var sum:Float=0;for d in -radius...radius {sum+=values[y*width+min(width-1,max(0,x+d))]}
      horizontal[y*width+x]=sum/Float(radius*2+1)
    } }
    for y in 0..<height { for x in 0..<width {
      var sum:Float=0;for d in -radius...radius {sum+=horizontal[min(height-1,max(0,y+d))*width+x]}
      result[y*width+x]=sum/Float(radius*2+1)
    } };return result
  }
}

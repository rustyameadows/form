import AppKit
import CryptoKit
import FormCore
import FormGeometry
import FormGraphics
import simd

/// Thin, independently folded paper panels. The canonical net and its artwork
/// stay in millimeters; only this legacy construction-graph boundary uses /100.
@MainActor enum PaperGeometry {
  static let constructionName="paper.construction",panelPrefix="paper.panel:",highlightName="paper.highlight"
  private final class Atlas:NSObject {
    let outside:NSImage,inside:NSImage,stock:NSImage,normal:NSImage,cost:Int
    init(outside:NSImage,inside:NSImage,stock:NSImage,normal:NSImage,cost:Int){self.outside=outside;self.inside=inside;self.stock=stock;self.normal=normal;self.cost=cost}
  }
  private static let atlasCache:NSCache<NSString,Atlas>={let cache=NSCache<NSString,Atlas>();cache.countLimit=8;cache.totalCostLimit=64*1024*1024;return cache}()
  private(set) static var textureBuilds=0
  private struct ToothTile {let color:CGImage;let normal:CGImage}
  private static var toothTiles:[String:ToothTile]=[:]
  /// Templates own only immutable buffers. Each appearance gets a new wrapper
  /// and material array, so sharing a physical shape cannot recolor a neighbor.
  private final class PhysicalTemplate:NSObject {
    let sources:[MeshGeometrySource],elements:[MeshGeometryElement],name:String,cost:Int
    init(_ geometry:MeshGeometry,name:String){sources=geometry.sources;elements=geometry.elements;self.name=name;cost=sources.reduce(0){$0+$1.data.count}+elements.reduce(0){$0+$1.data.count}}
    func instance()->MeshGeometry {let geometry=MeshGeometry(sources:sources,elements:elements);geometry.name=name;return geometry}
  }
  private struct PhysicalKey:Encodable {
    let version:Int,kind:String,polygon:[Point2],thicknessMM:Double,netSize:Point2,channels:[String]
  }
  private static let physicalCache:NSCache<NSString,PhysicalTemplate>={let cache=NSCache<NSString,PhysicalTemplate>();cache.countLimit=512;cache.totalCostLimit=32*1024*1024;return cache}()
  private(set) static var physicalMeshBuilds=0
  private static func physicalMesh(_ panel:PaperPanel,netSize:Point2,thicknessMM:Double,kind:String,channels:[String],build:()throws->MeshGeometry)throws->MeshGeometry {
    let bytes=try JSONEncoder.form.encode(PhysicalKey(version:1,kind:kind,polygon:panel.polygon,thicknessMM:thicknessMM,netSize:netSize,channels:channels))
    let name="paper.mesh:"+SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),key=name as NSString
    if let cached=physicalCache.object(forKey:key){return cached.instance()}
    let template=try PhysicalTemplate(build(),name:name);physicalMeshBuilds+=1;physicalCache.setObject(template,forKey:key,cost:template.cost);return template.instance()
  }

  static func geometryDefinition(_ value:PaperConstruction)->PaperConstruction {
    var copy=value;copy.foldPercent=0;copy.openingPercent=0;copy.annotations=[];copy.artworkReviewRequired=false
    return copy
  }
  static func sourceRevision(_ object:ProductObject,project:Project)->String? {
    guard PaperConstruction.isPaper(object),let definition=try? PaperConstruction.definition(for:object),let data=try? JSONEncoder.form.encode(geometryDefinition(definition)) else{return nil}
    var source=data
    if let inside=resolvedArtwork(object,project:project,inside:true),let bytes=try? inside.renderCacheData(){source.append(bytes)}
    source.append(Data("font:\(GeometryFactory.fontRevision)".utf8))
    return SHA256.hash(data:source).map{String(format:"%02x",$0)}.joined()
  }
  private static func resolvedArtwork(_ object:ProductObject,project:Project,inside:Bool)->Artwork? {
    guard let artwork=project.paperArtwork(for:object,inside:inside) else{return nil}
    let expanded=(try? project.resolvingComponents(in:artwork)) ?? artwork
    return project.resolvingSwatches(in:expanded)
  }
  static func make(_ object:ProductObject,project:Project,assets:URL,limit:Int,foldPercent:Double?=nil,selectedPanelID:String?=nil)throws->MeshNode {
    let definition=try PaperConstruction.definition(for:object),net=try definition.net()
    let outside=resolvedArtwork(object,project:project,inside:false),inside=resolvedArtwork(object,project:project,inside:true)
    let atlas=try textures(net:net,stock:definition.stock,color:object.color ?? project.material(object.materialID).color,outside:outside,inside:inside,assets:assets,limit:limit)
    let root=MeshNode();root.name=constructionName
    let normal=MeshMaterialProperty();normal.contents=atlas.normal;normal.wrapS = .clamp;normal.wrapT = .clamp
    let stockProperty=MeshMaterialProperty();stockProperty.contents=atlas.stock;stockProperty.wrapS = .clamp;stockProperty.wrapT = .clamp
    func colorProperty(_ image:NSImage)->MeshMaterialProperty {
      if image === atlas.stock{return stockProperty}
      let property=MeshMaterialProperty();property.contents=image;property.wrapS = .clamp;property.wrapT = .clamp;return property
    }
    func material(_ name:String,_ image:NSImage,edge:Bool=false)->MeshMaterial {
      let value=MeshMaterial();value.name=name;value.lightingModel = .physicallyBased
      value.diffuse=colorProperty(image);value.roughness.contents=edge ? 0.99:0.95;value.metalness.contents=0.0
      if !edge{value.normal=normal}
      return value
    }
    let materials=[material("Paper / outside",atlas.outside),material("Paper / inside",atlas.inside),material("Paper / cut fiber edge",atlas.stock,edge:true)]
    for panel in net.panels {
      let mesh=try panelMesh(panel,netSize:net.size,thicknessMM:definition.stock.thicknessMM)
      mesh.materials=materials
      let node=MeshNode(geometry:mesh);node.name=panelPrefix+panel.id;node.categoryBitMask=2
      node.addChildNode(try highlight(panel,netSize:net.size,thicknessMM:definition.stock.thicknessMM));root.addChildNode(node)
    }
    try updatePose(root,object:object,foldPercent:foldPercent,selectedPanelID:selectedPanelID)
    return root
  }
  static func updatePose(_ root:MeshNode,object:ProductObject,foldPercent:Double?=nil,selectedPanelID:String?=nil)throws {
    let definition=try PaperConstruction.definition(for:object)
    guard let construction=root.name==constructionName ? root:root.childNode(withName:constructionName,recursively:true) else{return}
    let panels=Dictionary(uniqueKeysWithValues:construction.childNodes.compactMap{node->(String,MeshNode)? in guard let name=node.name,name.hasPrefix(panelPrefix) else{return nil};return(String(name.dropFirst(panelPrefix.count)),node)})
    for resolved in try definition.resolvedPanels(foldPercent:foldPercent) {
      guard let node=panels[resolved.panelID],resolved.flatToWorld.count==16 else{continue}
      let m=resolved.flatToWorld
      var matrix=simd_double4x4(SIMD4(m[0],m[4],m[8],m[12]),SIMD4(m[1],m[5],m[9],m[13]),SIMD4(m[2],m[6],m[10],m[14]),SIMD4(m[3],m[7],m[11],m[15]))
      matrix.columns.3.x/=100;matrix.columns.3.y/=100;matrix.columns.3.z/=100
      node.transform=MeshMatrix4(matrix)
      node.childNode(withName:highlightName,recursively:false)?.isHidden=selectedPanelID != resolved.panelID
    }
  }
  static func panelID(from node:MeshNode)->String? {
    var current:MeshNode?=node
    while let value=current {if let name=value.name,name.hasPrefix(panelPrefix){return String(name.dropFirst(panelPrefix.count))};current=value.parent}
    return nil
  }
  static func panelMesh(_ panel:PaperPanel,netSize:Point2,thicknessMM:Double)throws->MeshGeometry {
    guard (3...128).contains(panel.polygon.count),panel.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}),netSize.x.isFinite,netSize.y.isFinite,netSize.x>0,netSize.y>0,thicknessMM.isFinite,thicknessMM>0 else{throw FormError.invalid("Paper panels require a polygon, physical net and positive caliper.")}
    return try physicalMesh(panel,netSize:netSize,thicknessMM:thicknessMM,kind:"beveled-panel",channels:["outside:+z","inside:-z","bevel-and-cut-edge"]){try buildPanelMesh(panel,netSize:netSize,thicknessMM:thicknessMM)}
  }
  private static func buildPanelMesh(_ panel:PaperPanel,netSize:Point2,thicknessMM:Double)throws->MeshGeometry {
    let path=NSBezierPath();path.move(to:.init(x:panel.polygon[0].x/100,y:-panel.polygon[0].y/100))
    for p in panel.polygon.dropFirst(){path.line(to:.init(x:p.x/100,y:-p.y/100))};path.close()
    let shape=MeshShape(path:path,extrusionDepth:thicknessMM/100);shape.chamferRadius=min(thicknessMM*0.22,0.06)/100;shape.prepare()
    let vertices=shape.sources(for:.vertex).first?.vectors ?? [],normals=shape.sources(for:.normal).first?.vectors ?? []
    guard !vertices.isEmpty,vertices.count==normals.count,shape.diagnostic==nil else{throw FormError.invalid(shape.diagnostic ?? "Paper panel geometry could not be prepared.")}
    var slots=[[UInt32]](repeating:[],count:3)
    for element in shape.elements where element.primitiveType == .triangles {
      let indices=element.indices
      for i in stride(from:0,to:indices.count,by:3) {
        let triangle=Array(indices[i..<i+3]),ns=triangle.map{normals[Int($0)].z}
        let slot=ns.allSatisfy{$0>0.999999} ? 0:ns.allSatisfy{$0 < -0.999999} ? 1:2
        slots[slot]+=triangle
      }
    }
    let uv=vertices.map{CGPoint(x:$0.x*100/netSize.x,y:-$0.y*100/netSize.y)}
    return MeshGeometry(sources:[.init(vertices:vertices),.init(normals:normals),.init(textureCoordinates:uv)],elements:slots.map{.init(indices:$0,primitiveType:.triangles)})
  }
  private static func highlight(_ panel:PaperPanel,netSize:Point2,thicknessMM:Double)throws->MeshNode {
    let geometry=try physicalMesh(panel,netSize:netSize,thicknessMM:thicknessMM,kind:"panel-highlight-tube-0.16mm",channels:["highlight"]){
      let points=panel.polygon.map{MeshVector3($0.x/100,-$0.y/100,(thicknessMM/2+0.035)/100)}
      let indices=panel.polygon.indices.flatMap{[Int32($0),Int32(($0+1)%panel.polygon.count)]}
      return MeshGeometry(sources:[.init(vertices:points)],elements:[.init(indices:indices,primitiveType:.line)])
    }
    let material=MeshMaterial();material.lightingModel = .constant;material.diffuse.contents=NSColor(hex:"#CC6C43");material.readsFromDepthBuffer=false;material.writesToDepthBuffer=false
    geometry.materials=[material]
    let node=MeshNode(geometry:geometry);node.name=highlightName;node.categoryBitMask=4;node.renderingOrder=110;node.isHidden=true;return node
  }
  private static func textures(net:PaperNet,stock:PaperStock,color:String,outside:Artwork?,inside:Artwork?,assets:URL,limit:Int)throws->Atlas {
    let edge=max(128,min(2048,limit)),density=Double(edge)/max(net.size.x,net.size.y)
    let width=max(1,Int(ceil(net.size.x*density))),height=max(1,Int(ceil(net.size.y*density)))
    guard width<=2048,height<=2048,width*height<=4_194_304 else{throw FormError.invalid("Paper material raster exceeds its bounded atlas budget.")}
    var signature=Data("paper-tooth-v1:\(net.size.x),\(net.size.y):\(color):\(stock.grain.rawValue):\(width),\(height):\(GeometryFactory.fontRevision):\(assets.path)".utf8)
    if let outside{signature.append(try outside.renderCacheData())};signature.append(0)
    if let inside{signature.append(try inside.renderCacheData())}
    let key=SHA256.hash(data:signature).map{String(format:"%02x",$0)}.joined() as NSString
    if let atlas=atlasCache.object(forKey:key){return atlas}
    let base=try image(width:width,height:height,base:color,artwork:nil,netSize:net.size,assets:assets,grain:stock.grain)
    let front=try outside.map{try image(width:width,height:height,base:color,artwork:$0,netSize:net.size,assets:assets,grain:stock.grain)} ?? base
    let back=try inside.map{try image(width:width,height:height,base:color,artwork:$0,netSize:net.size,assets:assets,grain:stock.grain)} ?? base
    let normal=try normalImage(width:width,height:height,netSize:net.size,grain:stock.grain)
    let cost=width*height*4*(2+(outside==nil ? 0:1)+(inside==nil ? 0:1))
    let atlas=Atlas(outside:front,inside:back,stock:base,normal:normal,cost:cost);textureBuilds+=1;atlasCache.setObject(atlas,forKey:key,cost:cost);return atlas
  }
  private static func noise(_ x:Int,_ y:Int,grain:PaperStock.Grain)->Double {
    func hash(_ a:Int,_ b:Int)->Double {var value=UInt64(bitPattern:Int64(a)) &* 0x9E3779B185EBCA87;value ^= UInt64(bitPattern:Int64(b)) &* 0xC2B2AE3D27D4EB4F;value ^= value>>29;value &*= 0x165667B19E3779F9;return Double(value&65535)/65535-0.5}
    let coarse=grain == .parallelHeight ? hash(x/2,y/5):grain == .parallelWidth ? hash(x/5,y/2):hash(x/3,y/3)
    return coarse*0.45+hash(x,y)*0.55
  }
  private static func image(width:Int,height:Int,base:String,artwork:Artwork?,netSize:Point2,assets:URL,grain:PaperStock.Grain)throws->NSImage {
    guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw FormError.invalid("Paper material pixels could not be allocated.")}
    context.setFillColor(NSColor(hex:base).cgColor);context.fill(.init(x:0,y:0,width:width,height:height))
    if let artwork {
      let art=try ArtworkProduction.filtered(artwork,roles:[.print]).artwork
      context.saveGState();NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
      context.translateBy(x:0,y:Double(height));context.scaleBy(x:Double(width)/netSize.x,y:-Double(height)/netSize.y)
      ArtworkRenderer.draw(art,width:netSize.x,height:netSize.y,assets:assets)
      NSGraphicsContext.restoreGraphicsState();context.restoreGState()
    }
    // Original deterministic, low-contrast fiber cue. It is a viewing material,
    // not a scan, measured stock property, ink separation or fabrication texture.
    context.saveGState();context.setBlendMode(.multiply);context.interpolationQuality = .high
    context.draw(try toothTile(grain).color,in:.init(x:0,y:0,width:8*Double(width)/netSize.x,height:8*Double(height)/netSize.y),byTiling:true)
    context.restoreGState()
    guard let cg=context.makeImage() else{throw FormError.invalid("Paper material image could not be read.")}
    return NSImage(cgImage:cg,size:.init(width:width,height:height))
  }
  private static func toothTile(_ grain:PaperStock.Grain)throws->ToothTile {
    if let cached=toothTiles[grain.rawValue]{return cached}
    let width=128,height=128;var normal=[UInt8](repeating:255,count:width*height*4),color=normal
    for y in 0..<height {for x in 0..<width {
      let nx=(noise(x+1,y,grain:grain)-noise(x-1,y,grain:grain))*0.035,ny = -(noise(x,y+1,grain:grain)-noise(x,y-1,grain:grain))*0.035,n=simd_normalize(SIMD3(nx,ny,1)),i=(y*width+x)*4
      normal[i]=UInt8(((n.x*0.5+0.5)*255).rounded());normal[i+1]=UInt8(((n.y*0.5+0.5)*255).rounded());normal[i+2]=UInt8(((n.z*0.5+0.5)*255).rounded())
      let value=UInt8(((0.993+noise(x,y,grain:grain)*0.012)*255).rounded());color[i]=value;color[i+1]=value;color[i+2]=value
    }}
    func image(_ bytes:[UInt8],linear:Bool)throws->CGImage {
      guard let provider=CGDataProvider(data:Data(bytes) as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:linear ? CGColorSpace.linearSRGB:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{throw FormError.invalid("Paper tooth pixels could not be created.")}
      return image
    }
    let tile=try ToothTile(color:image(color,linear:false),normal:image(normal,linear:true));toothTiles[grain.rawValue]=tile;return tile
  }
  private static func normalImage(width:Int,height:Int,netSize:Point2,grain:PaperStock.Grain)throws->NSImage {
    guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.linearSRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw FormError.invalid("Paper normal pixels could not be allocated.")}
    context.interpolationQuality = .high
    context.draw(try toothTile(grain).normal,in:.init(x:0,y:0,width:8*Double(width)/netSize.x,height:8*Double(height)/netSize.y),byTiling:true)
    guard let cg=context.makeImage() else{throw FormError.invalid("Paper normal image could not be read.")}
    return NSImage(cgImage:cg,size:.init(width:width,height:height))
  }
}

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
  private(set) static var textureBuilds=0
  /// Templates own only immutable buffers. Each appearance gets a new wrapper
  /// and material array, so sharing a physical shape cannot recolor a neighbor.
  private final class PhysicalTemplate:NSObject {
    let sources:[MeshGeometrySource],elements:[MeshGeometryElement],name:String,cost:Int
    init(_ geometry:MeshGeometry,name:String){sources=geometry.sources;elements=geometry.elements;self.name=name;cost=sources.reduce(0){$0+$1.data.count}+elements.reduce(0){$0+$1.data.count}}
    func instance()->MeshGeometry {let geometry=MeshGeometry(sources:sources,elements:elements);geometry.name=name;return geometry}
  }
  private struct PhysicalKey:Encodable {
    let version:Int,kind:String,polygon:[Point2],cutouts:[PaperPanelCutout],thicknessMM:Double,netSize:Point2,channels:[String]
  }
  private static let physicalCache:NSCache<NSString,PhysicalTemplate>={let cache=NSCache<NSString,PhysicalTemplate>();cache.countLimit=512;cache.totalCostLimit=32*1024*1024;return cache}()
  private(set) static var physicalMeshBuilds=0
  private final class TextureProperty:NSObject {let value:MeshMaterialProperty;init(_ value:MeshMaterialProperty){self.value=value}}
  private static let textureProperties:NSCache<NSString,TextureProperty>={let value=NSCache<NSString,TextureProperty>();value.countLimit=1024;value.totalCostLimit=256*1024*1024;return value}()
  private static func physicalMesh(_ panel:PaperPanel,netSize:Point2,thicknessMM:Double,kind:String,channels:[String],build:()throws->MeshGeometry)throws->MeshGeometry {
    let bytes=try JSONEncoder.form.encode(PhysicalKey(version:2,kind:kind,polygon:panel.polygon,cutouts:panel.cutouts ?? [],thicknessMM:thicknessMM,netSize:netSize,channels:channels))
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
  struct FaceAppearance {
    let profile:PaperSurfaceProfile
    let color:String
    var resolvedColor:String {profile.color ?? color}
  }
  /// One physical face's substrate, before authored print is composited over it.
  /// Bonded stock is back-to-front; its face ply colors take precedence over an
  /// inherited stock backdrop. Explicit face profile color and object tint win.
  static func faceAppearance(for object:ProductObject,stock:PaperStock,project:Project,inside:Bool)->FaceAppearance {
    let plies=stock.plies ?? [],ply=inside ? plies.first:plies.last
    let inherited=stock.profile ?? PaperSurfaceProfile(texture:.cotton,roughness:0.95,textureScaleMM:0.8,textureDepthMM:0.008)
    var profile=ply?.profile ?? inherited
    if !plies.isEmpty {profile.color=ply?.profile?.color}
    if let color=object.color {profile.color=color}
    return .init(profile:profile,color:object.color ?? ply?.color ?? project.material(object.materialID).color)
  }
  static func make(_ object:ProductObject,project:Project,assets:URL,limit:Int,foldPercent:Double?=nil,selectedPanelID:String?=nil,sampling:SourceTextureSamplingPlan?=nil)throws->MeshNode {
    let definition=try PaperConstruction.definition(for:object),net=try definition.net()
    let outside=resolvedArtwork(object,project:project,inside:false),inside=resolvedArtwork(object,project:project,inside:true)
    let outsideFinishes=(definition.finishes ?? []).filter{$0.side == .outside}
    let insideFinishes=(definition.finishes ?? []).filter{$0.side == .inside}
    let preparedOutside=try outside.map{try PaperSurfaceRasterizer.PreparedArtwork($0,finishes:outsideFinishes,assets:assets)}
    let preparedInside=try inside.map{try PaperSurfaceRasterizer.PreparedArtwork($0,finishes:insideFinishes,assets:assets)}
    let root=MeshNode();root.name=constructionName
    let stock=definition.stock,plies=stock.plies ?? []
    let legacyColor=object.color ?? project.material(object.materialID).color
    let defaultProfile=stock.profile ?? PaperSurfaceProfile(texture:.cotton,roughness:0.95,textureScaleMM:0.8,textureDepthMM:0.008)
    let frontAppearance=faceAppearance(for:object,stock:stock,project:project,inside:false)
    let backAppearance=faceAppearance(for:object,stock:stock,project:project,inside:true)
    let frontProfile=frontAppearance.profile,backProfile=backAppearance.profile
    let frontColor=frontAppearance.color,backColor=backAppearance.color
    let edge=max(128,min(4096,limit)),pool=min(12_000_000,edge*edge)
    let area=net.panels.reduce(0){$0+$1.bounds.width*$1.bounds.height}
    let minimum=min(16_384,pool/max(1,net.panels.count*2)),remaining=max(0,pool-minimum*net.panels.count*2)
    for panel in net.panels {
      let rect=panel.bounds,share=max(1,minimum+Int(Double(remaining)*rect.width*rect.height/max(area,1)/2))
      func allocation(inside:Bool)->SourceTextureRasterPlan? {
        guard let sampling else{return nil}
        return sampling.surfaces[SourceTextureSamplingPlan.paperFace(panel.id,inside:inside)]
          ?? .init(maximumEdge:sampling.raster.maximumEdge,
            maximumPixels:max(1,sampling.raster.maximumPixels/max(1,net.panels.count*2)))
      }
      let outsideSampling=allocation(inside:false),insideSampling=allocation(inside:true)
      let before=PaperSurfaceRasterizer.builds
      let front=try PaperSurfaceRasterizer.make(rect:rect,netSize:net.size,profile:frontProfile,color:frontColor,grain:stock.grain,artwork:outside,finishes:outsideFinishes,assets:assets,maximumEdge:outsideSampling?.maximumEdge ?? edge,pixelBudget:outsideSampling?.maximumPixels ?? share,preparedArtwork:preparedOutside)
      let back=try PaperSurfaceRasterizer.make(rect:rect,netSize:net.size,profile:backProfile,color:backColor,grain:stock.grain,artwork:inside,finishes:insideFinishes,assets:assets,maximumEdge:insideSampling?.maximumEdge ?? edge,pixelBudget:insideSampling?.maximumPixels ?? share,preparedArtwork:preparedInside)
      textureBuilds+=PaperSurfaceRasterizer.builds-before
      var materials=[surfaceMaterial("Paper / outside",maps:front,netSize:net.size,opacity:frontProfile.opacity),surfaceMaterial("Paper / inside",maps:back,netSize:net.size,opacity:backProfile.opacity)]
      var mesh:MeshGeometry
      if plies.isEmpty {
        materials.append(edgeMaterial("Paper / cut fiber edge",color:object.color ?? defaultProfile.color ?? legacyColor,roughness:defaultProfile.roughness))
        mesh=try panelMesh(panel,netSize:net.size,thicknessMM:stock.resolvedThicknessMM)
      } else {
        materials+=plies.map{edgeMaterial("Paper / ply / "+$0.name,color:$0.color,roughness:$0.profile?.roughness ?? defaultProfile.roughness)}
        mesh=try bondedPanelMesh(panel,netSize:net.size,plies:plies)
      }
      if sampling?.isFinalCapture == true {
        let budget=min(PaperReliefGeometry.maximumTrianglesPerFace,
          max(128,96_000/max(1,net.panels.count*2)))
        mesh=try PaperReliefGeometry.make(base:mesh,front:front,back:back,panel:panel,
          thicknessMM:stock.resolvedThicknessMM,triangleBudget:budget)
      }
      mesh.materials=materials
      let node=MeshNode(geometry:mesh);node.name=panelPrefix+panel.id;node.categoryBitMask=2
      node.addChildNode(try highlight(panel,netSize:net.size,thicknessMM:stock.resolvedThicknessMM));root.addChildNode(node)
    }
    try updatePose(root,object:object,foldPercent:foldPercent,selectedPanelID:selectedPanelID)
    return root
  }
  private static func surfaceMaterial(_ name:String,maps:PaperSurfaceRasterizer.Maps,netSize:Point2,opacity:Double)->MeshMaterial {
    let material=MeshMaterial();material.name=name;material.lightingModel = .physicallyBased;material.transparency=opacity
    var uv=matrix_identity_double4x4
    uv.columns.0.x=netSize.x/maps.rectMM.width;uv.columns.1.y=netSize.y/maps.rectMM.height
    uv.columns.3.x = -maps.rectMM.x/maps.rectMM.width;uv.columns.3.y = -maps.rectMM.y/maps.rectMM.height
    func property(_ image:NSImage)->MeshMaterialProperty {
      // Keep immutable image+UV resources stable across derived color edits.
      // The cached property owns its image, so an address cannot alias a later
      // image while the key is live. Front/back can share the same grain map.
      let key="\(ObjectIdentifier(image)):\(uv.columns.0.x),\(uv.columns.1.y),\(uv.columns.3.x),\(uv.columns.3.y)" as NSString
      if let cached=textureProperties.object(forKey:key){return cached.value}
      let property=MeshMaterialProperty();property.contents=image;property.contentsTransform=MeshMatrix4(uv);property.wrapS = .clamp;property.wrapT = .clamp
      textureProperties.setObject(TextureProperty(property),forKey:key,cost:max(1,Int(image.size.width*image.size.height*4)));return property
    }
    material.diffuse=property(maps.color);material.normal=property(maps.normal);material.roughness=property(maps.roughness);material.metalness=property(maps.metallic)
    material.writesToDepthBuffer=opacity>=0.999;return material
  }
  private static func edgeMaterial(_ name:String,color:String,roughness:Double)->MeshMaterial {
    let material=MeshMaterial();material.name=name;material.lightingModel = .physicallyBased;material.diffuse.contents=FormColor.color(color);material.roughness.contents=max(0.9,roughness);material.metalness.contents=0.0;return material
  }
  private static func bondedPanelMesh(_ panel:PaperPanel,netSize:Point2,plies:[PaperPly])throws->MeshGeometry {
    let thickness=plies.reduce(0){$0+$1.thicknessMM}
    return try physicalMesh(panel,netSize:netSize,thicknessMM:thickness,kind:"bonded-ply-panel",channels:["outside:+z","inside:-z"]+plies.map{"ply:\($0.thicknessMM)"}){
      var vertices=[MeshVector3](),normals=[MeshVector3](),uv=[CGPoint](),slots=[[UInt32]](repeating:[],count:2+plies.count),z = -thickness/2
      for (index,ply) in plies.enumerated() {
        // Internal bonds have no facing caps and no chamfered air groove.
        // Consecutive edge bands meet at the same physical cross section.
        let source=try physicalMesh(panel,netSize:netSize,thicknessMM:ply.thicknessMM,kind:"bonded-ply-slab",channels:["outside:+z","inside:-z","cut-edge"]){try buildPanelMesh(panel,netSize:netSize,thicknessMM:ply.thicknessMM,beveled:false)}
        let offset=UInt32(vertices.count),center=(z+ply.thicknessMM/2)/100
        vertices+=(source.sources(for:.vertex).first?.vectors ?? []).map{.init($0.x,$0.y,$0.z+center)}
        normals+=source.sources(for:.normal).first?.vectors ?? [];uv+=source.sources(for:.texcoord).first?.points ?? []
        if index==plies.count-1 {slots[0]+=source.elements[0].indices.map{$0+offset}}
        if index==0 {slots[1]+=source.elements[1].indices.map{$0+offset}}
        slots[2+index]+=source.elements[2].indices.map{$0+offset};z+=ply.thicknessMM
      }
      return MeshGeometry(sources:[.init(vertices:vertices),.init(normals:normals),.init(textureCoordinates:uv)],elements:slots.map{.init(indices:$0,primitiveType:.triangles)})
    }
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
  private static func buildPanelMesh(_ panel:PaperPanel,netSize:Point2,thicknessMM:Double,beveled:Bool=true)throws->MeshGeometry {
    let path=NSBezierPath();path.windingRule = .evenOdd
    for ring in [panel.polygon]+(panel.cutouts ?? []).map(\.polygon) {
      guard ring.count>=3 else{continue};path.move(to:.init(x:ring[0].x/100,y:-ring[0].y/100))
      for p in ring.dropFirst(){path.line(to:.init(x:p.x/100,y:-p.y/100))};path.close()
    }
    let shape=MeshShape(path:path,extrusionDepth:thicknessMM/100);shape.chamferRadius=beveled ? min(thicknessMM*0.22,0.06)/100:0;shape.prepare()
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
      var points=[MeshVector3](),indices=[Int32]()
      for ring in [panel.polygon]+(panel.cutouts ?? []).map(\.polygon) {
        let offset=points.count;points+=ring.map{MeshVector3($0.x/100,-$0.y/100,(thicknessMM/2+0.035)/100)}
        indices+=ring.indices.flatMap{[Int32(offset+$0),Int32(offset+($0+1)%ring.count)]}
      }
      return MeshGeometry(sources:[.init(vertices:points)],elements:[.init(indices:indices,primitiveType:.line)])
    }
    let material=MeshMaterial();material.lightingModel = .constant;material.diffuse.contents=NSColor(hex:"#CC6C43");material.readsFromDepthBuffer=false;material.writesToDepthBuffer=false
    geometry.materials=[material]
    let node=MeshNode(geometry:geometry);node.name=highlightName;node.categoryBitMask=4;node.renderingOrder=110;node.isHidden=true;return node
  }
}

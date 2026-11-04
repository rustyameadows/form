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
  private struct Pose:Equatable {var fold:Double,opening:Double,explosion:Double}
  private struct Highlight:Equatable {var panelIDs:Set<String>,fastenerID:String?,fastenerDefinitionID:String?}
  private final class PoseState:NSObject {
    let key:ProductObject,definition:PaperConstruction,net:PaperNet,context:PlanarAssemblySourceContext?,closedPanels:[PaperResolvedPanel],staples:[ResolvedPlanarStaple],ground:Vector3
    var pose:Pose?,highlight:Highlight?
    init(key:ProductObject,definition:PaperConstruction,net:PaperNet,context:PlanarAssemblySourceContext?,closedPanels:[PaperResolvedPanel],staples:[ResolvedPlanarStaple],ground:Vector3) {
      self.key=key;self.definition=definition;self.net=net;self.context=context;self.closedPanels=closedPanels;self.staples=staples;self.ground=ground
    }
  }
  /// Weak keys cannot retain an obsolete scene or one of its render roots.
  private static let poseCache=NSMapTable<MeshNode,PoseState>(keyOptions:.weakMemory,valueOptions:.strongMemory)
  private(set) static var poseSourceBuilds=0,poseResolutions=0,closedEnvelopeBuilds=0
  struct RenderSource {var definition:PaperConstruction;let net:PaperNet,context:PlanarAssemblySourceContext?}
  private struct AcceptedSource {let key:ProductObject,source:RenderSource}
  private static var acceptedSources=[AcceptedSource]()
  private(set) static var sourceValidations=0
  /// Reuse only a previously validated exact physical input. Camera, Canvas
  /// placement and ordinary rigid poses are separate from the source; changed
  /// stock, controls, contours, crops or finishes still take full validation.
  static func renderDefinition(for object:ProductObject)throws->PaperConstruction {try renderSource(for:object).definition}
  static func renderSource(for object:ProductObject)throws->RenderSource {
    var key=GeometryFactory.paperSourceKey(object)
    key.canvasProjectionPositions=nil;key.artwork?.canvasPosition=nil;key.paperConstruction?.insideArtwork?.canvasPosition=nil
    let accepted:RenderSource
    if let index=acceptedSources.firstIndex(where:{$0.key==key}) {
      let item=acceptedSources.remove(at:index);acceptedSources.insert(item,at:0);accepted=item.source
    }else {
      let definition=try PaperConstruction.definition(for:object),net=try definition.net()
      let context=try definition.authored.map{try PlanarAssemblySourceContext($0,fallbackStock:definition.stock)}
      accepted=RenderSource(definition:definition,net:net,context:context);sourceValidations+=1
      acceptedSources.insert(.init(key:key,source:accepted),at:0)
      if acceptedSources.count>32 {acceptedSources.removeLast()}
    }
    var result=accepted
    if let saved=object.paperConstruction {result.definition.foldPercent=saved.foldPercent;result.definition.openingPercent=saved.openingPercent;result.definition.explosionPercent=saved.explosionPercent}
    result.definition=PaperConstructionEngine.applying(object.parameters,to:result.definition)
    guard [result.definition.foldPercent,result.definition.openingPercent,result.definition.explosionPercent ?? 0].allSatisfy({$0.isFinite && (0...100).contains($0)}) else {
      throw FormError.invalid("Paper presentation poses must be finite percentages from zero to100.")
    }
    return result
  }
  private final class TextureProperty:NSObject {let value:MeshMaterialProperty;init(_ value:MeshMaterialProperty){self.value=value}}
  private static let textureProperties:NSCache<NSString,TextureProperty>={let value=NSCache<NSString,TextureProperty>();value.countLimit=1024;value.totalCostLimit=256*1024*1024;return value}()
  private static func physicalMesh(_ panel:PaperPanel,netSize:Point2,thicknessMM:Double,kind:String,channels:[String],build:()throws->MeshGeometry)throws->MeshGeometry {
    let bytes=try JSONEncoder.form.encode(PhysicalKey(version:2,kind:kind,polygon:panel.polygon,cutouts:panel.cutouts ?? [],thicknessMM:thicknessMM,netSize:netSize,channels:channels))
    let name="paper.mesh:"+SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),key=name as NSString
    if let cached=physicalCache.object(forKey:key){return cached.instance()}
    let template=try PhysicalTemplate(build(),name:name);physicalMeshBuilds+=1;physicalCache.setObject(template,forKey:key,cost:template.cost);return template.instance()
  }

  static func geometryDefinition(_ value:PaperConstruction)->PaperConstruction {
    var copy=value
    if value.authored?.panels.contains(where:{$0.features != nil}) != true {
      copy.foldPercent=0;copy.openingPercent=0
      if copy.explosionPercent != nil {copy.explosionPercent=0}
    }
    copy.annotations=[];copy.artworkReviewRequired=false
    return copy
  }
  static func sourceRevision(_ object:ProductObject,project:Project)->String? {
    guard PaperConstruction.isPaper(object),let prepared=try? renderSource(for:object),let data=try? JSONEncoder.form.encode(geometryDefinition(prepared.definition)) else{return nil}
    let definition=prepared.definition
    var source=data
    for inside in [false,true] {if let art=resolvedArtwork(object,project:project,inside:inside),let bytes=try? art.renderCacheData(){source.append(bytes)}}
    let inserted=definition.authored?.panels.flatMap{$0.features?.recesses?.compactMap{$0.insert?.face} ?? []} ?? []
    let componentFaces=(definition.authored?.components ?? []).filter{prepared.context?.enabledIDs.contains($0.id) ?? true}.flatMap{[$0.front,$0.back].compactMap{$0}}
    var checked=Set<String>()
    for face in (inserted+componentFaces).sorted(by:{($0.sourceObjectID.uuidString+$0.sourceSide.rawValue)<($1.sourceObjectID.uuidString+$1.sourceSide.rawValue)}) {
      source.append((try? JSONEncoder.form.encode(face)) ?? Data())
      guard checked.insert(face.sourceObjectID.uuidString+":"+face.sourceSide.rawValue).inserted else{continue}
      guard let owner=project.objects.first(where:{$0.id==face.sourceObjectID}) else{continue}
      source.append((try? JSONEncoder.form.encode(owner.paperConstruction.map(geometryDefinition))) ?? Data())
      let art=PaperConstruction.isPaper(owner) ? resolvedArtwork(owner,project:project,inside:face.sourceSide == .inside):project.surfaceArtwork(owner)
      if let bytes=try? art?.renderCacheData(){source.append(bytes)}
    }
    source.append(Data("font:\(GeometryFactory.fontRevision)".utf8))
    return SHA256.hash(data:source).map{String(format:"%02x",$0)}.joined()
  }
  private static func resolvedArtwork(_ object:ProductObject,project:Project,inside:Bool)->Artwork? {
    let artwork:Artwork?
    if inside,let source=try? renderDefinition(for:object) {
      if let id=source.insideArtworkSourceID,let owner=project.objects.first(where:{$0.id==id}) {artwork=project.surfaceArtwork(owner)}
      else{artwork=source.insideArtwork}
    }else{artwork=project.surfaceArtwork(object)}
    guard let artwork else{return nil}
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
  struct FaceArtworkSources {var outside:Artwork?,inside:Artwork?}
  struct PanelArtworkSources {
    var outside:Artwork?,inside:Artwork?
    var outsideFinishes:[PaperFinishAssignment],insideFinishes:[PaperFinishAssignment]
  }
  /// Component faces are physical crops in a piece-local atlas. Raster maps and
  /// mesh UVs use canonical net coordinates, so only this derived artwork gets
  /// translated back into that frame. Saved source artwork is never moved.
  static func panelArtwork(_ panel:PaperPanel,definition:PaperConstruction,project:Project,outside:Artwork?,inside:Artwork?)throws->PanelArtworkSources {
    func face(_ source:ResolvedSheetAssemblyFace?,inside:Bool,fallback:Artwork?)throws->Artwork? {
      guard var source else{return fallback}
      if inside,let componentID=panel.componentID,let authored=definition.authored,
        let owner=project.objects.first(where:{$0.id==source.sourceObjectID}),
        !(PaperConstruction.isPaper(owner) && source.sourceSide == .inside) {
        let bounds=try authored.componentBounds(componentID:componentID)
        // The reverse of a connected cut piece has one continuous mirror axis.
        // Flip the crop's position within that whole piece before preparing the
        // local face, rather than independently mirroring every panel's source.
        source.originMM.x += bounds.width-2*(panel.bounds.x-bounds.x)-panel.bounds.width
      }
      guard let local=SheetAssemblyGeometry.prepared(source,size:.init(panel.bounds.width,panel.bounds.height),inside:inside,project:project) else {
        throw FormError.invalid("A cut-piece face cannot find its canonical artwork source.")
      }
      let expanded=(try? project.resolvingComponents(in:local)) ?? local
      return SheetAssemblyGeometry.transformed(project.resolvingSwatches(in:expanded),by:.translation(panel.bounds.x,panel.bounds.y))
    }
    let front=panel.finishes ?? (panel.front==nil ? definition.finishes ?? []:[])
    let back=panel.finishes ?? (panel.back==nil ? definition.finishes ?? []:[])
    return try .init(outside:face(panel.front,inside:false,fallback:outside),inside:face(panel.back,inside:true,fallback:inside),
      outsideFinishes:front.filter{$0.side == .outside},insideFinishes:back.filter{$0.side == .inside})
  }
  static func make(_ object:ProductObject,project:Project,assets:URL,limit:Int,foldPercent:Double?=nil,selectedPanelID:String?=nil,sampling:SourceTextureSamplingPlan?=nil,artworkSources:FaceArtworkSources?=nil)throws->MeshNode {
    let source=try renderSource(for:object),definition=source.definition,net=source.net
    if sampling?.isFinalCapture == true {try SheetAssemblyRenderValidation.panelSources(object,project:project,assets:assets)}
    let outside=artworkSources == nil ? resolvedArtwork(object,project:project,inside:false):artworkSources!.outside
    let inside=artworkSources == nil ? resolvedArtwork(object,project:project,inside:true):artworkSources!.inside
    let outsideFinishes=(definition.finishes ?? []).filter{$0.side == .outside}
    let insideFinishes=(definition.finishes ?? []).filter{$0.side == .inside}
    let preparedOutside=try outside.map{try PaperSurfaceRasterizer.PreparedArtwork($0,finishes:outsideFinishes,assets:assets)}
    let preparedInside=try inside.map{try PaperSurfaceRasterizer.PreparedArtwork($0,finishes:insideFinishes,assets:assets)}
    var componentPrepared=[String:PaperSurfaceRasterizer.PreparedArtwork]()
    func prepared(_ artwork:Artwork?,finishes:[PaperFinishAssignment],componentID:String?,inside:Bool)throws->PaperSurfaceRasterizer.PreparedArtwork? {
      guard let artwork else{return nil}
      let inherited=inside ? preparedInside:preparedOutside
      if let inherited,inherited.matches(artwork,finishes:finishes,assets:assets) {return inherited}
      let key=(componentID ?? "owner")+(inside ? ":inside":":outside")
      if let cached=componentPrepared[key],cached.matches(artwork,finishes:finishes,assets:assets) {return cached}
      let value=try PaperSurfaceRasterizer.PreparedArtwork(artwork,finishes:finishes,assets:assets)
      componentPrepared[key]=value;return value
    }
    let root=MeshNode();root.name=constructionName
    let legacyColor=object.color ?? project.material(object.materialID).color
    let edge=max(128,min(4096,limit)),pool=min(12_000_000,edge*edge)
    let area=net.panels.reduce(0){$0+$1.bounds.width*$1.bounds.height}
    let minimum=min(16_384,pool/max(1,net.panels.count*2)),remaining=max(0,pool-minimum*net.panels.count*2)
    for panel in net.panels {
      let rect=panel.bounds,share=max(1,minimum+Int(Double(remaining)*rect.width*rect.height/max(area,1)/2))
      let stock=try panel.resolvedStock(fallback:definition.stock),plies=stock.plies ?? []
      let defaultProfile=stock.profile ?? PaperSurfaceProfile(texture:.cotton,roughness:0.95,textureScaleMM:0.8,textureDepthMM:0.008)
      let frontAppearance=faceAppearance(for:object,stock:stock,project:project,inside:false)
      let backAppearance=faceAppearance(for:object,stock:stock,project:project,inside:true)
      let frontProfile=frontAppearance.profile,backProfile=backAppearance.profile
      let frontColor=frontAppearance.color,backColor=backAppearance.color
      func allocation(inside:Bool)->SourceTextureRasterPlan? {
        guard let sampling else{return nil}
        return sampling.surfaces[SourceTextureSamplingPlan.paperFace(panel.id,inside:inside)]
          ?? .init(maximumEdge:sampling.raster.maximumEdge,
            maximumPixels:max(1,sampling.raster.maximumPixels/max(1,net.panels.count*2)))
      }
      let outsideSampling=allocation(inside:false),insideSampling=allocation(inside:true)
      if panel.features != nil {
        let front=outsideSampling ?? .init(maximumEdge:edge,maximumPixels:share),back=insideSampling ?? .init(maximumEdge:edge,maximumPixels:share)
        let plan=SourceTextureSamplingPlan(raster:.init(maximumEdge:max(front.maximumEdge,back.maximumEdge),maximumPixels:front.maximumPixels+back.maximumPixels),isFinalCapture:sampling?.isFinalCapture ?? false)
        root.addChildNode(try SheetPanelMaterialGeometry.make(object:object,panel:panel,definition:definition,project:project,assets:assets,
          outside:outside,inside:inside,limit:limit,sampling:plan))
        continue
      }
      let before=PaperSurfaceRasterizer.builds
      let panelSources=try panelArtwork(panel,definition:definition,project:project,outside:outside,inside:inside)
      let preparedFront=try prepared(panelSources.outside,finishes:panelSources.outsideFinishes,componentID:panel.componentID,inside:false)
      let preparedBack=try prepared(panelSources.inside,finishes:panelSources.insideFinishes,componentID:panel.componentID,inside:true)
      let front=try PaperSurfaceRasterizer.make(rect:rect,netSize:net.size,profile:frontProfile,color:frontColor,grain:stock.grain,artwork:panelSources.outside,finishes:panelSources.outsideFinishes,assets:assets,maximumEdge:outsideSampling?.maximumEdge ?? edge,pixelBudget:outsideSampling?.maximumPixels ?? share,preparedArtwork:preparedFront)
      let back=try PaperSurfaceRasterizer.make(rect:rect,netSize:net.size,profile:backProfile,color:backColor,grain:stock.grain,artwork:panelSources.inside,finishes:panelSources.insideFinishes,assets:assets,maximumEdge:insideSampling?.maximumEdge ?? edge,pixelBudget:insideSampling?.maximumPixels ?? share,preparedArtwork:preparedBack)
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
    try updatePose(root,object:object,foldPercent:foldPercent,selectedPanelID:selectedPanelID,sourceDefinition:definition)
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
      let property=MeshMaterialProperty();property.contents=image;property.contentsTransform=MeshMatrix4(uv);property.wrapS = .clamp;property.wrapT = .clamp;property.maxAnisotropy=8
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
  static func updatePose(_ root:MeshNode,object:ProductObject,foldPercent:Double?=nil,selectedPanelID:String?=nil,sourceDefinition:PaperConstruction?=nil,
    selectedPanelIDs:Set<String>?=nil,selectedFastenerID:String?=nil,selectedFastenerDefinitionID:String?=nil)throws {
    guard let construction=root.name==constructionName ? root:root.childNode(withName:constructionName,recursively:true) else{return}
    var key=GeometryFactory.paperSourceKey(object)
    key.canvasProjectionPositions=nil;key.artwork?.canvasPosition=nil;key.paperConstruction?.insideArtwork?.canvasPosition=nil
    let state:PoseState
    if let cached=poseCache.object(forKey:construction),cached.key==key {state=cached}
    else {
      let prepared=try renderSource(for:object),definition=sourceDefinition ?? prepared.definition
      let isIndependent=(definition.authored?.version ?? 0)>=4 && definition.authored?.components?.isEmpty == false
      var closed=definition;closed.foldPercent=100;closed.openingPercent=0;closed.explosionPercent=nil
      let hasFasteners=definition.authored?.jointAttachments?.contains{$0.staples?.isEmpty == false} == true
      let rest=try hasFasteners ? PaperConstructionEngine.resolvedPanels(closed,validatedNet:prepared.net,sourceContext:prepared.context):[]
      let staples=try hasFasteners ? definition.authored!.resolveJointAttachments(stock:definition.stock).staples:[]
      let ground=try isIndependent ? PlanarAssemblyEnvelope.resolve(definition).groundOffsetMM:Vector3()
      if isIndependent {closedEnvelopeBuilds+=1}
      state=PoseState(key:key,definition:definition,net:prepared.net,context:prepared.context,closedPanels:rest,staples:staples,ground:ground)
      if poseCache.count>=256 {poseCache.removeAllObjects()}
      poseCache.setObject(state,forKey:construction);poseSourceBuilds+=1
      try PlanarFastenerGeometry.install(construction,staples:staples)
    }
    var definition=state.definition
    if let saved=object.paperConstruction {definition.foldPercent=saved.foldPercent;definition.openingPercent=saved.openingPercent;definition.explosionPercent=saved.explosionPercent}
    definition=PaperConstructionEngine.applying(object.parameters,to:definition)
    let pose=Pose(fold:foldPercent ?? definition.foldPercent,opening:definition.openingPercent,explosion:definition.explosionPercent ?? 0)
    let highlight=Highlight(panelIDs:selectedPanelIDs ?? Set([selectedPanelID].compactMap{$0}),fastenerID:selectedFastenerID,fastenerDefinitionID:selectedFastenerDefinitionID)
    func updateHighlights() {
      for node in construction.childNodes {
        guard let name=node.name,name.hasPrefix(panelPrefix) else{continue}
        let id=String(name.dropFirst(panelPrefix.count))
        node.childNode(withName:highlightName,recursively:false)?.isHidden = !highlight.panelIDs.contains(id)
      }
      PlanarFastenerGeometry.highlight(construction,staples:state.staples,instanceID:highlight.fastenerID,definitionID:highlight.fastenerDefinitionID)
      state.highlight=highlight
    }
    if state.pose==pose {
      if state.highlight != highlight {updateHighlights()}
      return
    }
    let panels=Dictionary(uniqueKeysWithValues:construction.childNodes.compactMap{node->(String,MeshNode)? in guard let name=node.name,name.hasPrefix(panelPrefix) else{return nil};return(String(name.dropFirst(panelPrefix.count)),node)})
    let resolvedPanels=try PaperConstructionEngine.resolvedPanels(definition,validatedNet:state.net,foldPercent:foldPercent,sourceContext:state.context);poseResolutions+=1
    for resolved in resolvedPanels {
      guard let node=panels[resolved.panelID],resolved.flatToWorld.count==16 else{continue}
      let m=resolved.flatToWorld
      var matrix=simd_double4x4(SIMD4(m[0],m[4],m[8],m[12]),SIMD4(m[1],m[5],m[9],m[13]),SIMD4(m[2],m[6],m[10],m[14]),SIMD4(m[3],m[7],m[11],m[15]))
      matrix.columns.3.x/=100;matrix.columns.3.y/=100;matrix.columns.3.z/=100
      node.transform=MeshMatrix4(matrix)
    }
    try PlanarFastenerGeometry.updatePose(construction,staples:state.staples,restPanels:state.closedPanels,posedPanels:resolvedPanels)
    construction.position = .init(state.ground.x/100,state.ground.y/100,state.ground.z/100)
    updateHighlights();state.pose=pose
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

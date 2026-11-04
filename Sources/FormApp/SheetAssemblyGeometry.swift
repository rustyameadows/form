import AppKit
import CryptoKit
import FormCore
import FormGeometry
import FormGraphics
import FormCADModel
import simd

/// Derived physical sheet instances. Saved pages, story frames, cover wraps and
/// finish assignments remain canonical source objects, never copied documents.
@MainActor enum SheetAssemblyGeometry {
  static let rootName="sheet.assembly"
  static func leafName(_ id:UUID)->String{"sheet.leaf:"+id.uuidString}
  static func planeName(_ id:String)->String{"sheet.enclosure:"+id}
  static func surfaceKey(_ part:String,inside:Bool)->String{SourceTextureSamplingPlan.paperFace(part,inside:inside)}
  struct Surface {
    var key:String,node:MeshNode,size:Point2,inside:Bool,visible:Bool,opacity:Double,samplingWeight:Double
  }
  private struct Part {
    var key:String,name:String,size:Point2,stock:PaperStock
    var front:ResolvedSheetAssemblyFace?,back:ResolvedSheetAssemblyFace?
    var finishes:[PaperFinishAssignment]
    var frontVisible:Bool,backVisible:Bool
    var frontSamplingWeight:Double,backSamplingWeight:Double
    var bendMM:Double,stackOffsetMM:Double
    var sideFlex:SheetSideFlexProfile?
    var parentName:String? = nil
    var polygon:[Point2]? = nil,cutouts:[PaperPanelCutout] = []
    var localPosition:SIMD3<Double> = .zero,localRotation:SIMD3<Double> = .zero
    var panelFlex:ResolvedSheetPanelFlex? = nil
    var frontMapping:Affine2? = nil
    var leafFlexAngle:Double? = nil,leafFlexWidth:Double=0,leafFlexRise:Double=0
    var reverseArtwork:Bool=false
  }
  private static func parts(_ source:ResolvedSheetAssembly)throws->[Part] {
    try source.leaves.map { leaf in
      let pasted=leaf.attachment?.planeID != nil && leaf.attachment?.widthMM==0
      let flex:SheetSideFlexProfile?
      if !pasted,let binding=source.binding?.definition,binding.style == .sideStaple,source.openingDegrees != 0 {
        flex=try SheetSideFlexProfile(binding:binding,leaf:leaf,stackThicknessMM:source.stackThicknessMM,
          openingDegrees:source.openingDegrees,bendMM:source.bendMM)
      }else{flex=nil}
      let bonded=source.binding?.definition.style == .adhesive || source.binding?.definition.style == .sewn
      let hinge=source.openingDegrees != 0 && !pasted && (bonded || leaf.attachment != nil)
      let width=min(leaf.size.x*0.45,max(0.01,leaf.attachment?.widthMM ?? (bonded ? source.bindingFlexWidth:source.binding?.definition.flexWidthMM ?? 8)))
      return Part(key:"leaf:"+leaf.id.uuidString,name:leafName(leaf.id),size:leaf.size,stock:leaf.stock,
        front:leaf.front,back:leaf.back,finishes:leaf.finishes,frontVisible:leaf.frontVisible,
        backVisible:leaf.backVisible,frontSamplingWeight:leaf.frontSamplingWeight,backSamplingWeight:leaf.backSamplingWeight,
        bendMM:source.openingDegrees==0 || hinge || pasted ? 0:(leaf.turned ? -source.bendMM:source.bendMM),
        stackOffsetMM:leaf.stackOffsetMM,sideFlex:flex,
        leafFlexAngle:hinge ? (leaf.turned ? source.openingDegrees:0):nil,leafFlexWidth:width,
        leafFlexRise:hinge ? (leaf.turned ? -source.bendMM:source.bendMM):0)
    } + source.enclosure.flatMap { plane in
      try SheetPanelLayerGeometry.layers(plane).map { layer in
        Part(key:plane.features == nil ? "enclosure:"+plane.id:"enclosure:"+plane.id+":"+layer.id,name:plane.features == nil ? planeName(plane.id):planeName(plane.id)+":"+layer.id,
          size:layer.size,stock:layer.stock,front:layer.front,back:layer.back,finishes:layer.finishes,
          frontVisible:true,backVisible:true,frontSamplingWeight:layer.front == nil || layer.reverseArtwork ? 0.02:1,
          backSamplingWeight:layer.back == nil && !layer.reverseArtwork ? 0.02:1,bendMM:0,stackOffsetMM:0,sideFlex:nil,
          parentName:plane.features == nil ? nil:planeName(plane.id),polygon:layer.polygon,cutouts:layer.cutouts,
          localPosition:layer.position,localRotation:layer.rotation,panelFlex:plane.features?.flex,frontMapping:layer.frontMapping,reverseArtwork:layer.reverseArtwork)
      }
    }
  }
  private static func sourcePanelSize(_ part:Part,source:ResolvedSheetAssembly)->Point2 {
    guard let parent=part.parentName,let plane=source.enclosure.first(where:{planeName($0.id)==parent}) else{return part.size}
    return plane.size
  }
  /// Source identities exclude continuous pose but include logical visibility,
  /// physical dimensions/crops, stock, finishes, fonts and each story only once.
  static func sourceRevision(_ object:ProductObject,project:Project)->String? {
    guard var definition=object.sheetAssembly,let resolved=try? project.resolvedSheetAssembly(object) else{return nil}
    guard let resolvedParts=try? parts(resolved) else{return nil}
    let closed=definition.openingDegrees==0
    if definition.binding?.style != .sideStaple && definition.binding?.style != .adhesive && definition.binding?.style != .sewn && definition.auxiliaryLeaves?.contains(where:{$0.attachment != nil}) != true {definition.openingDegrees=0}
    var data=(try? JSONEncoder.form.encode(definition)) ?? Data()
    var stories=[UUID:ResolvedTextStory]()
    struct Shape:Encodable {var key:String,size:Point2,stock:PaperStock,front:ResolvedSheetAssemblyFace?,back:ResolvedSheetAssemblyFace?,frontVisible:Bool,backVisible:Bool}
    for part in resolvedParts {
      data.append((try? JSONEncoder.form.encode(Shape(key:part.key,size:part.size,stock:part.stock,
        front:part.front,back:part.back,frontVisible:part.frontVisible,backVisible:part.backVisible))) ?? Data())
    }
    data.append((try? JSONEncoder.form.encode(resolved.enclosure.map(\.features))) ?? Data())
    for id in resolved.sourceObjectIDs.sorted(by:{$0.uuidString<$1.uuidString}) {
      guard let source=project.objects.first(where:{$0.id==id}) else{continue}
      data.append(Data(id.uuidString.utf8))
      data.append((try? JSONEncoder.form.encode(source.paperConstruction)) ?? Data())
      for artwork in [project.surfaceArtwork(source),PaperConstruction.isPaper(source) ? project.paperArtwork(for:source,inside:true):nil].compactMap({$0}) {
        data.append((try? JSONEncoder.form.encode(artwork.renderDefinition)) ?? Data())
        for element in artwork.elements {if let story=element.storyFrame?.resolved{stories[story.story.id]=story}}
      }
    }
    for id in stories.keys.sorted(by:{$0.uuidString<$1.uuidString}){data.append((try? JSONEncoder.form.encode(stories[id]!)) ?? Data())}
    data.append(Data("closed:\(closed):font:\(GeometryFactory.fontRevision)".utf8))
    return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
  }
  static func surfaces(root:MeshNode,object:ProductObject,project:Project)throws->[Surface] {
    let resolved=try project.resolvedSheetAssembly(object)
    let faces=try parts(resolved).flatMap { part -> [Surface] in
      guard let wrapper=root.childNode(withName:part.name,recursively:true),
        let node=wrapper.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true) else{return []}
      return [false,true].map { inside in
        Surface(key:surfaceKey(part.key,inside:inside),node:node,size:part.size,inside:inside,
          visible:inside ? part.backVisible:part.frontVisible,opacity:part.stock.sheetFaceOpacity(inside:inside),
          samplingWeight:inside ? part.backSamplingWeight:part.frontSamplingWeight)
      }
    }
    return faces + SheetEdgeArtworkGeometry.sources(resolved).compactMap { source in
      guard let node=root.childNode(withName:SheetEdgeArtworkGeometry.displayPrefix+source.edge,recursively:true) else{return nil}
      return Surface(key:source.key,node:node,size:source.size,inside:false,visible:true,opacity:1,samplingWeight:1)
    }
  }
  static func make(_ object:ProductObject,project:Project,assets:URL,limit:Int,
    sampling:SourceTextureSamplingPlan?=nil)throws->MeshNode {
    let resolved=try project.resolvedSheetAssembly(object),all=try parts(resolved)
    let root=MeshNode();root.name=rootName
    let editingEdge=min(2048,max(128,limit))
    let edge=sampling?.raster.maximumEdge ?? editingEdge
    let total=sampling?.raster.maximumPixels ?? min(SourceTextureSampling.maximumPixels,editingEdge*editingEdge)
    let edgeSources=SheetEdgeArtworkGeometry.sources(resolved)
    let keys=Set(all.flatMap{[surfaceKey($0.key,inside:false),surfaceKey($0.key,inside:true)]}+edgeSources.map(\.key))
    let explicit=sampling?.surfaces.filter{keys.contains($0.key)} ?? [:]
    let used=explicit.values.reduce(0){$0+$1.maximumPixels}
    guard total>0,total<=SourceTextureSampling.maximumPixels,used<=total else {
      throw FormError.invalid("Sheet material sources exceed the shared capture allocation.")
    }
    var targets=all.flatMap { part in [false,true].compactMap { inside -> SourceTextureSamplingTarget? in
      let key=surfaceKey(part.key,inside:inside)
      guard explicit[key]==nil else{return nil}
      return SourceTextureSamplingTarget(id:key,sourceWidth:part.size.x,sourceHeight:part.size.y,
        projectedEdgePixels:Double(edge),visibleWeight:part.size.x*part.size.y*(inside ? part.backSamplingWeight:part.frontSamplingWeight))
    }}
    targets += edgeSources.filter{explicit[$0.key]==nil}.map{.init(id:$0.key,sourceWidth:$0.size.x,sourceHeight:$0.size.y,
      projectedEdgePixels:Double(edge),visibleWeight:$0.size.x*$0.size.y)}
    let fallback:[String:SourceTextureRasterPlan]=try targets.isEmpty ? [:]:SourceTextureSampling.allocate(targets,maximumEdge:edge,pixelBudget:total-used)
    var edgeMaterials=[String:MeshMaterial](),bodyDepths=[UUID:Double](),bodyDepth=0.0
    for leaf in resolved.leaves where leaf.auxiliaryID==nil {bodyDepths[leaf.id]=bodyDepth;bodyDepth+=leaf.stock.resolvedThicknessMM}
    for source in edgeSources {
      let plan=explicit[source.key] ?? fallback[source.key] ?? .init(maximumEdge:8,maximumPixels:64)
      edgeMaterials[source.edge]=try SheetEdgeArtworkGeometry.material(source,project:project,assets:assets,plan:plan)
    }
    for part in all {
      let frontKey=surfaceKey(part.key,inside:false),backKey=surfaceKey(part.key,inside:true)
      let front=sampling?.surfaces[frontKey] ?? fallback[frontKey] ?? .init(maximumEdge:8,maximumPixels:64)
      let back=sampling?.surfaces[backKey] ?? fallback[backKey] ?? .init(maximumEdge:8,maximumPixels:64)
      let plan=SourceTextureSamplingPlan(raster:.init(maximumEdge:max(front.maximumEdge,back.maximumEdge),
        maximumPixels:min(SourceTextureSampling.maximumPixels,front.maximumPixels+back.maximumPixels)),
        surfaces:[SourceTextureSamplingPlan.paperFace("face",inside:false):front,
          SourceTextureSamplingPlan.paperFace("face",inside:true):back],isFinalCapture:sampling?.isFinalCapture ?? false)
      var outside=part.frontVisible ? prepared(part.front,size:part.size,inside:false,project:project):nil
      if let mapping=part.frontMapping,let artwork=outside {outside=transformed(artwork,by:mapping)}
      var inside=part.backVisible ? prepared(part.back,size:part.size,inside:true,project:project):nil
      if part.reverseArtwork {swap(&outside,&inside)}
      let sourceID=part.front?.sourceObjectID ?? stableID(part.key)
      var virtual=ProductObject(name:part.name,recipeID:object.recipeID,parameters:[:],materialID:object.materialID)
      virtual.id=sourceID;virtual.color=object.color
      virtual.artwork=outside ?? Artwork(background:"#FFFFFF",elements:[])
      if outside==nil{virtual.artwork?.backgroundOpacity=0}
      let polygon=part.polygon ?? SheetPanelLayerGeometry.rectangle(part.size)
      let shape=PlanarConstructionDefinition(name:"Linked sheet face",size:.init(CADScalar(part.size.x),CADScalar(part.size.y)),
        stockThickness:CADScalar(part.stock.resolvedThicknessMM),
        panels:[.init(id:"face",name:"Physical sheet",polygon:polygon.map{.init(CADScalar($0.x),CADScalar($0.y))},
          cutouts:part.cutouts.map{.init(id:$0.id,polygon:$0.polygon.map{.init(CADScalar($0.x),CADScalar($0.y))},kind:$0.kind)})],rootPanelID:"face")
      var paper=PaperConstruction(kind:.authored,dimensions:.init(width:part.size.x,height:part.size.y,depth:part.stock.resolvedThicknessMM),
        stock:part.stock,foldPercent:0,insideArtwork:inside)
      paper.authored=shape
      paper.finishes=finishAssignments(part,project:project).map { original in
        var finish=original;if part.reverseArtwork {finish.side=finish.side == .outside ? .inside:.outside};return finish
      }
      virtual.paperConstruction=paper
      let wrapper=try PaperGeometry.make(virtual,project:project,assets:assets,limit:min(2048,max(128,limit)),sampling:plan,artworkSources:.init(outside:outside,inside:inside))
      wrapper.name=part.name
      if let node=wrapper.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true) {
        node.transform = .init()
        func deformed(_ mesh:MeshGeometry)throws->MeshGeometry {
          if let angle=part.leafFlexAngle {return try SheetPanelFlexGeometry.make(mesh,size:part.size,edge:"left",widthMM:part.leafFlexWidth,
            angleDegrees:angle,final:sampling?.isFinalCapture == true,tailRiseMM:part.leafFlexRise)}
          if let profile=part.sideFlex {return try sideFlexed(mesh,profile:profile,final:sampling?.isFinalCapture == true)}
          if part.bendMM != 0 {return try bent(mesh,widthMM:part.size.x,riseMM:part.bendMM,
            normalOffsetMM:part.stackOffsetMM,segments:sampling?.isFinalCapture == true ? 64:32)}
          return mesh
        }
        if let mesh=node.geometry {
          if part.key.hasPrefix("leaf:"),let id=UUID(uuidString:String(part.key.dropFirst(5))),let depth=bodyDepths[id] {
            for source in edgeSources {
              guard let material=edgeMaterials[source.edge],let registered=try SheetEdgeArtworkGeometry.register(mesh,size:part.size,
                thickness:part.stock.resolvedThicknessMM,depthOffset:depth,totalDepth:resolved.textBlockThickness,edge:source.edge,material:material) else{continue}
              let template=MeshNode(geometry:try deformed(registered));template.name=SheetEdgeArtworkGeometry.templatePrefix+source.edge
              template.isHidden=true;wrapper.addChildNode(template)
            }
          }
          node.geometry=try deformed(mesh)
        }
      }
      wrapper.position = .init(part.localPosition/100)
      wrapper.eulerAngles = .init(part.localRotation)
      if let flex=part.panelFlex,let node=wrapper.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true),let mesh=node.geometry {
        let posed=SheetPanelMeshTransform.apply(mesh,matrix:wrapper.transform.raw)
        node.geometry=try SheetPanelFlexGeometry.make(posed,size:sourcePanelSize(part,source:resolved),edge:flex.edge.rawValue,
          widthMM:flex.widthMM,angleDegrees:flex.angleDegrees,final:sampling?.isFinalCapture == true,curve:flex.curve)
        wrapper.transform = .init()
      }
      if let parentName=part.parentName {
        let parent=root.childNode(withName:parentName,recursively:false) ?? {let node=MeshNode();node.name=parentName;root.addChildNode(node);return node}()
        parent.addChildNode(wrapper)
      }else{root.addChildNode(wrapper)}
    }
    try updatePose(root,object:object,project:project)
    return root
  }
  static func updatePose(_ root:MeshNode,object:ProductObject,project:Project)throws {
    let source=try project.resolvedSheetAssembly(object),angle=source.openingDegrees * .pi/180
    let base=source.stackThicknessMM*(1+cos(angle))/2
    for leaf in source.leaves {
      guard let wrapper=root.childNode(withName:leafName(leaf.id),recursively:true) else{continue}
      let theta=leaf.turned ? angle:0,offset=leaf.stackOffsetMM
      if let attachment=leaf.attachment,let planeID=attachment.planeID,attachment.widthMM==0,
        let plane=source.enclosure.first(where:{$0.id==planeID}),let parent=root.childNode(withName:planeName(planeID),recursively:true) {
        parent.addChildNode(wrapper);wrapper.eulerAngles = .init()
        let turnIn=plane.features?.wrap?.stock.resolvedThicknessMM ?? 0
        wrapper.position = .init((plane.size.x-leaf.size.x)/200,-(plane.size.y-leaf.size.y)/200,
          -(plane.stock.resolvedThicknessMM/2+turnIn+leaf.stock.resolvedThicknessMM/2)/100)
        continue
      }
      if source.openingDegrees != 0 && (source.binding?.definition.style == .adhesive || source.binding?.definition.style == .sewn || leaf.attachment != nil) {
        wrapper.eulerAngles = .init(-.pi/2,0,0)
        wrapper.position = .init(-offset*sin(theta)/100,((leaf.turned ? base:0)+offset*cos(theta))/100,-leaf.size.y/200);continue
      }
      if source.binding?.definition.style == .sideStaple,source.openingDegrees != 0 {
        wrapper.eulerAngles = .init(-.pi/2,0,0)
        wrapper.position = .init(0,0,-leaf.size.y/200)
        continue
      }
      let bent=source.openingDegrees != 0 && source.bendMM != 0
      wrapper.eulerAngles = .init(-.pi/2,0,theta)
      wrapper.position = .init(bent ? 0:-offset*sin(theta)/100,
        ((leaf.turned ? base:0)+(bent ? 0:offset*cos(theta)))/100,-leaf.size.y/200)
    }
    root.childNode(withName:SheetBindingGeometry.name,recursively:false)?.removeFromParentNode()
    if let binding=try SheetBindingGeometry.make(source,leafRoot:root) {root.addChildNode(binding)}
    for plane in source.enclosure {
      guard let node=root.childNode(withName:planeName(plane.id),recursively:true) else{continue}
      node.eulerAngles = .init(plane.rotationDegrees.x * .pi/180,plane.rotationDegrees.y * .pi/180,plane.rotationDegrees.z * .pi/180)
      node.position = .init(plane.positionMM.x/100,plane.positionMM.y/100,plane.positionMM.z/100)
    }
    SheetEdgeArtworkGeometry.updatePose(root)
  }
  static func prepared(_ face:ResolvedSheetAssemblyFace?,size:Point2,inside:Bool,project:Project)->Artwork? {
    guard let face,let owner=project.objects.first(where:{$0.id==face.sourceObjectID}),
      var artwork=PaperConstruction.isPaper(owner) ? project.paperArtwork(for:owner,inside:face.sourceSide == .inside):project.surfaceArtwork(owner) else{return nil}
    let crop=Affine2.translation(-face.originMM.x,-face.originMM.y)
    // Independent logical back pages are readable source planes. Registration
    // reverses only their derived physical projection, never the saved artwork.
    let mirror=inside && !(PaperConstruction.isPaper(owner) && face.sourceSide == .inside)
    let transform=(mirror ? Affine2(a:-1,b:0,c:0,d:1,tx:size.x,ty:0):.init()).followed(by:crop)
    for index in artwork.elements.indices where artwork.elements[index].parentID==nil {
      artwork.elements[index].affine=transform.followed(by:artwork.elements[index].affine ?? .init())
    }
    if var boundary=artwork.boundary {
      for index in boundary.contours.indices {boundary.contours[index].nodes=boundary.contours[index].nodes.map{PathCommands.transformed($0,by:transform)}}
      artwork.boundary=boundary
    }
    return artwork
  }
  static func transformed(_ original:Artwork,by transform:Affine2)->Artwork {
    var artwork=original
    for index in artwork.elements.indices where artwork.elements[index].parentID==nil {
      artwork.elements[index].affine=transform.followed(by:artwork.elements[index].affine ?? .init())
    }
    if var boundary=artwork.boundary {
      for index in boundary.contours.indices {boundary.contours[index].nodes=boundary.contours[index].nodes.map{PathCommands.transformed($0,by:transform)}}
      artwork.boundary=boundary
    };return artwork
  }
  private static func finishAssignments(_ part:Part,project:Project)->[PaperFinishAssignment] {
    var result=part.finishes
    for (inside,face,visible) in [(false,part.front,part.frontVisible),(true,part.back,part.backVisible)] {
      guard visible,let face,let owner=project.objects.first(where:{$0.id==face.sourceObjectID}),
        let paper=try? PaperConstruction.definition(for:owner) else{continue}
      result += (paper.finishes ?? []).filter{$0.side==face.sourceSide}.map { original in
        var finish=original;finish.id=stableID(part.key+":"+original.id.uuidString+":\(inside)")
        finish.side=inside ? .inside:.outside;return finish
      }
    }
    return result
  }
  private static func stableID(_ value:String)->UUID {
    let h=SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined()
    return UUID(uuidString:"\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20).prefix(12))")!
  }

  private struct Vertex {
    var p:MeshVector3,n:MeshVector3,uv:CGPoint
    func interpolated(_ b:Vertex,_ t:Double)->Vertex {
      .init(p:.init(p.x+(b.p.x-p.x)*t,p.y+(b.p.y-p.y)*t,p.z+(b.p.z-p.z)*t),
        n:.init(n.x+(b.n.x-n.x)*t,n.y+(b.n.y-n.y)*t,n.z+(b.n.z-n.z)*t),
        uv:.init(x:uv.x+(b.uv.x-uv.x)*t,y:uv.y+(b.uv.y-uv.y)*t))
    }
  }
  /// Subdivide at the pinned edge and through the margin flex separately, so
  /// a narrow 180-degree transition never receives one giant page-wide facet.
  static func sideFlexed(_ base:MeshGeometry,profile:SheetSideFlexProfile,final:Bool)throws->MeshGeometry {
    let positions=base.sources(for:.vertex).first?.vectors ?? [],normals=base.sources(for:.normal).first?.vectors ?? []
    let uv=base.sources(for:.texcoord).first?.points ?? []
    guard !positions.isEmpty,positions.count==normals.count,positions.count==uv.count else{throw FormError.invalid("Sheet margin flex needs matched physical mesh buffers.")}
    let transitionCount=final ? 24:12,tailCount=final ? 64:32
    var cuts=[0.0,profile.pinnedWidthMM]
    cuts += (1...transitionCount).map{profile.pinnedWidthMM+profile.transitionLengthMM*Double($0)/Double(transitionCount)}
    cuts += (1...tailCount).map{profile.pinnedWidthMM+profile.transitionLengthMM+profile.tailLengthMM*Double($0)/Double(tailCount)}
    cuts=cuts.map{$0/100}
    var outputPositions=[MeshVector3](),outputNormals=[MeshVector3](),outputUV=[CGPoint](),elements=[MeshGeometryElement]()
    func clipped(_ polygon:[Vertex],x:Double,lower:Bool)->[Vertex] {
      guard let last=polygon.last else{return []}
      var result=[Vertex](),prior=last,priorInside=lower ? last.p.x>=x-1e-12:last.p.x<=x+1e-12
      for vertex in polygon {
        let inside=lower ? vertex.p.x>=x-1e-12:vertex.p.x<=x+1e-12
        if inside != priorInside {result.append(prior.interpolated(vertex,(x-prior.p.x)/(vertex.p.x-prior.p.x)))}
        if inside{result.append(vertex)};prior=vertex;priorInside=inside
      }
      return result
    }
    func append(_ vertex:Vertex)throws->UInt32 {
      let sample=profile.sample(atMM:vertex.p.x*100),z=vertex.p.z*100
      let c=cos(sample.angleRadians),s=sin(sample.angleRadians),scale=1-sample.curvaturePerMM*z
      guard scale>0,scale.isFinite,outputPositions.count<500_000 else{throw FormError.invalid("The derived side flex exceeds its caliper or bounded geometry allocation.")}
      let index=UInt32(outputPositions.count),nx=vertex.n.x/scale
      outputPositions.append(.init((sample.xMM-s*z)/100,vertex.p.y,(sample.yMM+c*z)/100))
      outputNormals.append(.init(simd_normalize(SIMD3(nx*c-vertex.n.z*s,vertex.n.y,nx*s+vertex.n.z*c))))
      outputUV.append(vertex.uv);return index
    }
    for element in base.elements {
      guard element.primitiveType == .triangles else{throw FormError.invalid("Sheet margin flex supports physical triangle surfaces only.")}
      let source=element.indices;var indices=[UInt32]()
      for offset in stride(from:0,to:source.count,by:3) where offset+2<source.count {
        let ids=[Int(source[offset]),Int(source[offset+1]),Int(source[offset+2])]
        guard ids.allSatisfy({positions.indices.contains($0)}) else{throw FormError.invalid("Sheet margin flex encountered an invalid physical index.")}
        let triangle=ids.map{Vertex(p:positions[$0],n:normals[$0],uv:uv[$0])}
        let minX=triangle.map{$0.p.x}.min()!,maxX=triangle.map{$0.p.x}.max()!
        for strip in 0..<(cuts.count-1) where cuts[strip]<=maxX+1e-12 && cuts[strip+1]>=minX-1e-12 {
          let polygon=clipped(clipped(triangle,x:cuts[strip],lower:true),x:cuts[strip+1],lower:false)
          guard polygon.count>=3 else{continue}
          let vertices=try polygon.map(append)
          for index in 1..<(vertices.count-1) {
            let a=polygon[0].p.simd,b=polygon[index].p.simd,c=polygon[index+1].p.simd
            if simd_length_squared(simd_cross(b-a,c-a))>1e-24 {indices += [vertices[0],vertices[index],vertices[index+1]]}
          }
        }
      }
      elements.append(.init(indices:indices,primitiveType:.triangles))
    }
    let mesh=MeshGeometry(sources:[.init(vertices:outputPositions),.init(normals:outputNormals),.init(textureCoordinates:outputUV)],elements:elements)
    mesh.materials=base.materials;mesh.name="sheet.side-flex:\(base.name ?? ""):\(profile.openingRadians):\(profile.normalOffsetMM):\(final)"
    return mesh
  }
  /// Strip subdivision preserves existing cap, bevel and independent ply slots.
  /// Arc length stays physical width; it is not an XY stretch with a height map.
  static func bent(_ base:MeshGeometry,widthMM:Double,riseMM:Double,normalOffsetMM:Double,segments:Int)throws->MeshGeometry {
    guard widthMM>0,widthMM.isFinite,riseMM.isFinite,abs(riseMM)<=widthMM/2,(1...64).contains(segments) else {
      throw FormError.invalid("Sheet bending requires finite physical width/rise and a bounded strip count.")
    }
    let positions=base.sources(for:.vertex).first?.vectors ?? [],normals=base.sources(for:.normal).first?.vectors ?? []
    let uv=base.sources(for:.texcoord).first?.points ?? []
    guard !positions.isEmpty,positions.count==normals.count,positions.count==uv.count else{throw FormError.invalid("Sheet bending needs matched physical mesh buffers.")}
    if riseMM==0{return base}
    var low=0.0,high=Double.pi/2
    for _ in 0..<40 {let mid=(low+high)/2;if widthMM*(1-cos(mid))/mid<abs(riseMM){low=mid}else{high=mid}}
    let angle=(low+high)/2*(riseMM<0 ? -1:1),radius=widthMM/angle
    let halfExtent=positions.map{abs($0.z*100)}.max() ?? 0
    guard abs(radius)>abs(normalOffsetMM)+halfExtent else{throw FormError.invalid("The sheet bend radius must exceed its physical stack offset and surface caliper.")}
    var outputPositions=[MeshVector3](),outputNormals=[MeshVector3](),outputUV=[CGPoint](),elements=[MeshGeometryElement]()
    func clipped(_ polygon:[Vertex],x:Double,lower:Bool)->[Vertex] {
      guard let last=polygon.last else{return []}
      var result=[Vertex](),prior=last,priorInside=lower ? last.p.x>=x-1e-12:last.p.x<=x+1e-12
      for vertex in polygon {
        let inside=lower ? vertex.p.x>=x-1e-12:vertex.p.x<=x+1e-12
        if inside != priorInside {result.append(prior.interpolated(vertex,(x-prior.p.x)/(vertex.p.x-prior.p.x)))}
        if inside{result.append(vertex)};prior=vertex;priorInside=inside
      }
      return result
    }
    func append(_ vertex:Vertex)->UInt32 {
      // Every neutral leaf retains its authored material arc length. The
      // concentric stack changes its radius, therefore also its end angle.
      let x=vertex.p.x*100,z=vertex.p.z*100+normalOffsetMM
      let t=x/(radius-normalOffsetMM),c=cos(t),s=sin(t)
      let index=UInt32(outputPositions.count)
      outputPositions.append(.init((radius-z)*s/100,vertex.p.y,(radius*(1-c)+z*c)/100))
      // Inverse-transpose of rotation*diag(radialScale,1,1), including
      // independent caliper/bevel normals rather than rotating them only.
      let radialScale=(radius-z)/(radius-normalOffsetMM)
      let nx=vertex.n.x/radialScale
      let normal=SIMD3(nx*c-vertex.n.z*s,vertex.n.y,nx*s+vertex.n.z*c)
      outputNormals.append(.init(simd_normalize(normal)))
      outputUV.append(vertex.uv);return index
    }
    let step=widthMM/Double(segments)/100
    for element in base.elements {
      guard element.primitiveType == .triangles else{throw FormError.invalid("Sheet bending supports physical triangle surfaces only.")}
      let source=element.indices;var indices=[UInt32]()
      for offset in stride(from:0,to:source.count,by:3) where offset+2<source.count {
        let ids=[Int(source[offset]),Int(source[offset+1]),Int(source[offset+2])]
        guard ids.allSatisfy({positions.indices.contains($0)}) else{throw FormError.invalid("Sheet bending encountered an invalid physical index.")}
        let triangle=ids.map{Vertex(p:positions[$0],n:normals[$0],uv:uv[$0])}
        let first=max(0,min(segments-1,Int(floor((triangle.map{$0.p.x}.min() ?? 0)/step))))
        let last=max(0,min(segments-1,Int(floor((triangle.map{$0.p.x}.max() ?? 0)/step))))
        for strip in first...last {
          let polygon=clipped(clipped(triangle,x:Double(strip)*step,lower:true),x:Double(strip+1)*step,lower:false)
          guard polygon.count>=3 else{continue}
          let vertices=polygon.map(append)
          for index in 1..<(vertices.count-1) {
            let a=polygon[0].p.simd,b=polygon[index].p.simd,c=polygon[index+1].p.simd
            if simd_length_squared(simd_cross(b-a,c-a))>1e-24 {indices += [vertices[0],vertices[index],vertices[index+1]]}
          }
        }
      }
      elements.append(.init(indices:indices,primitiveType:.triangles))
    }
    guard outputPositions.count<=500_000 else{throw FormError.invalid("Derived sheet bend exceeded its bounded geometry budget.")}
    let mesh=MeshGeometry(sources:[.init(vertices:outputPositions),.init(normals:outputNormals),.init(textureCoordinates:outputUV)],elements:elements)
    mesh.materials=base.materials;mesh.name="sheet.bend:\(base.name ?? ""):\(widthMM):\(riseMM):\(normalOffsetMM):\(segments)"
    return mesh
  }
}

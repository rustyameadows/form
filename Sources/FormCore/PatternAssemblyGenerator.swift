import Foundation
import CryptoKit
import simd

public enum PatternAssemblyGenerator {
  private struct Source {
    var element:ArtworkElement
    var geometry:SewingPieceGeometry
    var boundaries:[SewingBoundary]
    var edges:[SewingBoundaryEdge] {boundaries.flatMap(\.edges)}
    func edge(_ end:SewingSeamEnd)throws -> SewingBoundaryEdge {
      guard let id=end.edgeID,let ending=end.endID,let edge=edges.first(where:{$0.id==id && $0.endID==ending}) else {throw FormError.invalid("Assembly seam/pin references a removed, split or reversed source edge. Reassign it explicitly.")};return edge
    }
  }
  private struct ResolvedSeam {var seam:SewingSeam,first:PatternPanelID,second:PatternPanelID,a:SewingBoundaryEdge,b:SewingBoundaryEdge,fractions:[Double]}
  private struct Pair:Hashable {var a:Int,b:Int;init(_ x:Int,_ y:Int){a=min(x,y);b=max(x,y)}}
  public static func sourceDigest(_ definition:PatternAssemblyDefinition,in project:Project)throws -> String {
    guard let art=project.objects.first(where:{$0.id==definition.sourceObjectID})?.artwork else {throw FormError.invalid("The assembly's source artwork is missing.")}
    var data=try JSONEncoder.form.encode(definition);data.append(try JSONEncoder.form.encode(art))
    return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
  }
  public static func generate(_ definition:PatternAssemblyDefinition,in project:Project)throws -> PatternAssemblyProduct {
    try definition.validateDeclarations()
    guard let owner=project.objects.first(where:{$0.id==definition.sourceObjectID}),owner.artworkSourceID==nil,let art=owner.artwork else {throw FormError.invalid("The assembly's independent source pattern owner is missing.")}
    try validateArtwork(art)
    var budget=AssemblyBuildBudget(limit:definition.maximumMeshingOperations),sources:[UUID:Source]=[:]
    let requested=Set(definition.panels.map{ $0.panel.elementID })
    for id in requested.sorted(by:{$0.uuidString<$1.uuidString}) {
      guard let e=art.elements.first(where:{$0.id==id}),let piece=e.sewingPiece,e.kind=="path",piece.onFoldEdge==nil,piece.onFoldEdgeID==nil else {throw FormError.invalid("Assembly consumes prepared complete path pieces. Unfold half-patterns explicitly and retain original edge identities first.")}
      let geometry=try SewingPatterns.geometry(e,in:art),boundaries=try SewingCurves.boundaries(e,in:art)
      sources[id] = .init(element:e,geometry:geometry,boundaries:boundaries)
    }
    let panels=definition.panels.sorted{$0.panel<$1.panel},panelIDs=Set(panels.map(\.panel))
    for panel in panels {guard let source=sources[panel.panel.elementID],panel.panel.copy<=source.geometry.piece.cutQuantity else {throw FormError.invalid("Assembly references an unavailable declared piece copy.")}}
    var required:[PatternPanelID:[UUID:[Double]]]=[:],resolved:[ResolvedSeam]=[],sampleCount=0
    func append(_ panel:PatternPanelID,_ edge:UUID,_ f:Double,to values:inout [PatternPanelID:[UUID:[Double]]]) {var edges=values[panel] ?? [:];edges[edge,default:[]].append(f);values[panel]=edges}
    for id in definition.seamIDs {
      guard let seam=art.sewingSeams?.first(where:{$0.id==id}),let firstSource=sources[seam.first.elementID],let secondSource=sources[seam.second.elementID] else {throw FormError.invalid("A selected source seam or its pattern piece is missing.")}
      let first=PatternPanelID(elementID:seam.first.elementID,copy:seam.first.copy),second=PatternPanelID(elementID:seam.second.elementID,copy:seam.second.copy)
      guard first != second,panelIDs.contains(first),panelIDs.contains(second),seam.tolerance.isFinite,(0...25).contains(seam.tolerance) else {throw FormError.invalid("Pair two explicitly arranged panel copies with a finite seam tolerance.")}
      let a=try firstSource.edge(seam.first),b=try secondSource.edge(seam.second)
      guard abs(a.length-b.length)+a.lengthError+b.lengthError<=seam.tolerance+1e-8 else {throw FormError.invalid("Seam '\(seam.name)' does not certify matching physical arc lengths. The assembly will not stretch or rescale its source to fit.")}
      let count=max(1,Int(ceil(max(a.length,b.length)/definition.maximumEdgeMm)))
      guard count<=512,sampleCount<=2048-(count+1) else {throw FormError.invalid("Assembly seam sampling exceeds 2048 declared pairs. Use larger spacing or fewer seams.")};sampleCount+=count+1
      for i in 0...count {let f=Double(i)/Double(count);append(first,a.id!,f,to:&required);append(second,b.id!,seam.reversed ? 1-f:f,to:&required)}
      resolved.append(.init(seam:seam,first:first,second:second,a:a,b:b,fractions:(0...count).map{Double($0)/Double(count)}))
    }
    for pin in definition.pins {
      guard let source=sources[pin.panel.elementID],source.edges.contains(where:{$0.id==pin.edgeID && $0.endID==pin.endID}) else {throw FormError.invalid("An assembly pin references a changed source edge. Reassign it explicitly.")}
      append(pin.panel,pin.edgeID,pin.fraction,to:&required)
    }
    // One shared arc plan stitches every adaptive boundary vertex, not only
    // sparse coarse samples. Otherwise high-curvature free points can zigzag
    // between sewn anchors despite an apparently small sampled seam gap.
    func unique(_ values:[Double])->[Double] {
      var seen=Set<Int64>();return values.filter{seen.insert(Int64(($0*1e12).rounded())).inserted}.sorted()
    }
    var stable=resolved.isEmpty
    for _ in 0...resolved.count {
      var changed=false
      for seam in resolved {
        let first=required[seam.first]?[seam.a.id!] ?? [],second=required[seam.second]?[seam.b.id!] ?? []
        let shared=unique(first+second.map{seam.seam.reversed ? 1-$0:$0})
        let af=try AssemblyBoundarySampling.arcFractions(seam.a,spacing:definition.maximumEdgeMm,tolerance:definition.boundaryToleranceMm,required:shared,budget:&budget)
        let bf=try AssemblyBoundarySampling.arcFractions(seam.b,spacing:definition.maximumEdgeMm,tolerance:definition.boundaryToleranceMm,required:shared.map{seam.seam.reversed ? 1-$0:$0},budget:&budget)
        let complete=unique(shared+af+bf.map{seam.seam.reversed ? 1-$0:$0}),other=complete.map{seam.seam.reversed ? 1-$0:$0}.sorted()
        if complete.count != unique(first).count || other.count != unique(second).count {changed=true}
        required[seam.first,default:[:]][seam.a.id!]=complete;required[seam.second,default:[:]][seam.b.id!]=other
      }
      if !changed {stable=true;break}
    }
    guard stable else{throw FormError.invalid("The shared sewing-boundary refinement did not converge within its declared source-seam budget.")}
    sampleCount=0
    for i in resolved.indices {
      let seam=resolved[i],fractions=unique(required[seam.first]?[seam.a.id!] ?? [])
      guard fractions.count<=512,sampleCount<=2048-fractions.count else{throw FormError.invalid("Adaptive sewn boundaries exceed 2048 actual pairs. Simplify curves or use a declared coarser boundary tolerance.")}
      sampleCount+=fractions.count;resolved[i].fractions=fractions
    }
    var positions:[Vector3]=[],masses:[Double]=[],triangles:[ClothTriangle]=[],uv:[Point2]=[],links:[ClothLink]=[],materialPoints:[Point2]=[],panelNumbers:[Int]=[],reports:[PatternAssemblyPanel]=[],vertexMaps:[PatternPanelID:[AssemblyEdgePoint:Int]]=[:],areaBound=0.0
    for (index,panel) in panels.enumerated() {
      let source=sources[panel.panel.elementID]!,sampled=try AssemblyBoundarySampling.make(source.boundaries,spacing:definition.maximumEdgeMm,tolerance:definition.boundaryToleranceMm,required:required[panel.panel] ?? [:],budget:&budget)
      let available=definition.maximumVertices-positions.count
      guard available>=3,budget.remaining>=1000 else {throw FormError.invalid("The complete assembly exceeds its vertex/work budget. Use larger spacing or fewer panels.")}
      let flat=try AssemblyMesher.mesh(contours:sampled.rings,maximumEdgeMm:definition.maximumEdgeMm,maximumVertices:available,workLimit:budget.remaining)
      try budget.charge(flat.operations)
      let offset=positions.count,panelPositions=flat.points.map(panel.pose.point),panelMass=try ClothMesh.masses(positionsMm:panelPositions,triangles:flat.triangles,areaDensityKgPerM2:panel.densityGSM/1000)
      guard triangles.count+flat.triangles.count<=ClothMesh.maximumTriangles else {throw FormError.invalid("The assembled source exceeds its triangle budget.")}
      positions+=panelPositions;masses+=panelMass;materialPoints+=flat.points;panelNumbers += [Int](repeating:index,count:flat.points.count)
      uv += flat.points.map{.init($0.x/sampled.materialSize.x,$0.y/sampled.materialSize.y)}
      triangles += flat.triangles.map{t in panel.pose.materialFront==1 ? .init(t.a+offset,t.b+offset,t.c+offset):.init(t.a+offset,t.c+offset,t.b+offset)}
      vertexMaps[panel.panel]=sampled.vertexForSample.mapValues{$0+offset}
      var edges:[Pair:[Int]]=[:]
      for t in flat.triangles {for (a,b,c) in [(t.a,t.b,t.c),(t.b,t.c,t.a),(t.c,t.a,t.b)] {try budget.charge();edges[Pair(a,b),default:[]].append(c)}}
      var bend=Set<Pair>()
      for edge in edges.keys.sorted(by:{$0.a==$1.a ? $0.b<$1.b:$0.a<$1.a}) {
        let a=flat.points[edge.a],b=flat.points[edge.b],dx=b.x-a.x,dy=b.y-a.y,length=hypot(dx,dy),grain=source.geometry.grainDirection,along=abs((dx*grain.x+dy*grain.y)/length),across=abs((dx*grain.y-dy*grain.x)/length)
        // Direction buckets are declared distance proxies, not measured warp,
        // weft/shear constitutive properties or calibrated fabric mechanics.
        let kind:ClothLinkKind=min(along,across)<0.38 ? (along>across ? .warp:.weft):.shear
        links.append(.init(offset+edge.a,offset+edge.b,kind:kind,restLengthMm:length))
        if let adjacent=edges[edge],adjacent.count==2 {let pair=Pair(adjacent[0],adjacent[1]);if pair.a != pair.b,bend.insert(pair).inserted {let p=flat.points[pair.a],q=flat.points[pair.b];links.append(.init(offset+pair.a,offset+pair.b,kind:.bendDistance,restLengthMm:hypot(q.x-p.x,q.y-p.y)))}}
      }
      let perimeter=source.edges.reduce(0){$0+$1.length},bound=perimeter*(definition.boundaryToleranceMm+SewingCurveLimits.contourToleranceMM)
      guard abs(flat.areaMm2-sampled.sourceArea)<=bound+1e-6 else {throw FormError.invalid("Generated material area exceeds the declared source-curve approximation bound.")};areaBound+=bound
      reports.append(.init(id:panel.panel,panelIndex:index,name:source.geometry.piece.name,sourceOriginMm:sampled.sourceOrigin,materialSizeMm:sampled.materialSize,material:panel.material,densityGSM:panel.densityGSM,textureOriginMm:panel.textureOriginMm,vertexIndices:Array(offset..<positions.count),sourceAreaMm2:sampled.sourceArea,meshAreaMm2:flat.areaMm2))
    }
    var samples:[PatternAssemblySeamSample]=[],seamPairs=Set<Pair>()
    for seam in resolved {for f in seam.fractions {
      try budget.charge();let g=seam.seam.reversed ? 1-f:f
      guard let a=vertexMaps[seam.first]?[.init(seam.a.id!,f)],let b=vertexMaps[seam.second]?[.init(seam.b.id!,g)] else {throw FormError.invalid("A required physical seam sample did not survive the mesh boundary.")}
      if seamPairs.insert(Pair(a,b)).inserted {links.append(.init(a,b,kind:.seam,restLengthMm:0))}
      samples.append(.init(seamID:seam.seam.id,firstEdgeID:seam.a.id!,secondEdgeID:seam.b.id!,firstFraction:f,secondFraction:g,firstDistanceMm:seam.a.length*f,secondDistanceMm:seam.b.length*g,firstVertex:a,secondVertex:b))
    }}
    var pinByVertex:[Int:Vector3]=[:]
    for pin in definition.pins {
      guard let index=vertexMaps[pin.panel]?[.init(pin.edgeID,pin.fraction)] else {throw FormError.invalid("A required source pin did not survive the mesh boundary.")}
      let target=pin.targetMm ?? positions[index]
      if let previous=pinByVertex[index],previous != target {throw FormError.invalid("Two source pins declare incompatible targets on the same material vertex.")};pinByVertex[index]=target
    }
    var mesh=ClothMesh(restPositionsMm:positions,massesKg:masses,triangles:triangles,uv:uv,links:links,pins:pinByVertex.keys.sorted().map{.init($0,targetMm:pinByVertex[$0]!)})
    mesh.panelIDs=panelNumbers
    let study=ClothStudy(mesh:mesh,settings:definition.settings,colliders:definition.colliders,preparation:definition.preparation ?? .init());try study.validate()
    let digest=try sourceDigest(definition,in:project),definitionDigest=SHA256.hash(data:try JSONEncoder.form.encode(study)).map{String(format:"%02x",$0)}.joined()
    return .init(study:study,panels:reports,materialPointsMm:materialPoints,seamSamples:samples,sourceDigest:digest,definitionDigest:definitionDigest,operations:budget.used,sourceAreaErrorBoundMm2:areaBound)
  }
}

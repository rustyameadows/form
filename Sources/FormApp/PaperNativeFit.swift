import AppKit
import CoreFoundation
import CryptoKit
import FormCore
import FormGeometry
import simd

/// Read-only fit of actual modeled bounds against an explicitly authored cavity.
@MainActor enum PaperNativeFit {
  static func preflight(store:StudioStore,args:[String:Any])throws->Any {
    guard let project=store.project,
      let sourceRaw=args["object_id"] as? String,let sourceID=UUID(uuidString:sourceRaw),
      let source=project.objects.first(where:{$0.id==sourceID}),PaperConstruction.isPaper(source),
      let targetRaw=args["contents_object_id"] as? String,let targetID=UUID(uuidString:targetRaw),targetID != sourceID,
      let target=project.objects.first(where:{$0.id==targetID && $0.hasTablePresentation}),
      let interiorID=args["interior_id"] as? String,!interiorID.isEmpty else {
      throw FormError.invalid("Modeled contents preflight needs distinct construction/contents object IDs and a declared interior_id.")
    }
    guard !target.isFlexibleSurface,target.clothAttachment==nil,target.patternAssemblyAttachment==nil else {
      throw FormError.invalid("This fit adapter supports rigid modeled contents. Freeze or explicitly model flexible contents before checking a cavity.")
    }
    let clearance:Double
    if let raw=args["clearance_mm"] {guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,(0...100).contains(n.doubleValue) else{throw FormError.invalid("Use0–100mm finite contents clearance.")};clearance=n.doubleValue}else{clearance=0}
    let definition=try PaperConstruction.definition(for:source)
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    let geometry=GeometryFactory.object(target,project:project,assets:assets,textureLimit:64)
    guard !allNodes(geometry).contains(where:{$0.name?.hasPrefix("paper.invalid:")==true}),
      allNodes(geometry).contains(where:{$0.geometry?.sources(for:.vertex).first?.vectors.isEmpty == false}) else {
      throw FormError.invalid("Contents geometry could not be resolved; no fit result was fabricated.")
    }
    let bounds=try physicalBounds(geometry)
    let targetPose=pose(target,in:project),sourceInverse=pose(source,in:project).inverse
    var corners:[Vector3]=[]
    for x in [bounds.min.x,bounds.max.x] {for y in [bounds.min.y,bounds.max.y] {for z in [bounds.min.z,bounds.max.z] {
      let point=sourceInverse * targetPose * SIMD4<Double>(x*100,y*100,z*100,1)
      corners.append(.init(point.x,point.y,point.z))
    }}}
    let sourceRevision=digest(try JSONEncoder.form.encode(definition)),targetRevision=digest(try JSONEncoder.form.encode(target))
    let result=try PaperConstructionEngine.fitContents(definition,interiorID:interiorID,
      contents:.init(objectID:targetID,revision:targetRevision,corners:corners),clearanceMM:clearance,
      sourceObjectID:sourceID,sourceRevision:sourceRevision)
    return ["object_id":sourceID.uuidString,"preflight":try jsonObject(definition.preflight()),
      "contents_fit":try jsonObject(result),"geometry_evidence":"Eight corners of the actual native contents mesh bounds, transformed through its Table placement into construction-local millimeters.",
      "limitations":["Only the declared cavity and opening cross-section are checked; continuous insertion, flexibility, adhesive and closure retention are not verified."]]
  }
  private static func physicalBounds(_ root:MeshNode)throws->(min:MeshVector3,max:MeshVector3) {
    var points:[MeshVector3]=[]
    func collect(_ node:MeshNode) {
      guard !node.isHidden,node.name != PaperGeometry.highlightName else{return}
      for point in node.geometry?.sources(for:.vertex).flatMap(\.vectors) ?? [] {points.append(node.convertPosition(point,to:root))}
      for child in node.childNodes {collect(child)}
    }
    collect(root)
    guard let first=points.first else{throw FormError.invalid("Contents has no physical mesh bounds.")}
    var lo=first,hi=first
    for point in points {lo = .init(min(lo.x,point.x),min(lo.y,point.y),min(lo.z,point.z));hi = .init(max(hi.x,point.x),max(hi.y,point.y),max(hi.z,point.z))}
    return(lo,hi)
  }
  private static func allNodes(_ node:MeshNode)->[MeshNode] {[node]+node.childNodes.flatMap(allNodes)}
  private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  private static func pose(_ object:ProductObject,in project:Project)->simd_double4x4 {
    let p=project.textilePlacement(object),node=MeshNode()
    if let right=p.basisRight,let down=p.basisDown {
      let n=p.normal
      node.simdOrientation=simd_quatf(simd_float3x3(columns:(SIMD3(Float(right.x),Float(right.y),Float(right.z)),SIMD3(Float(n.x),Float(n.y),Float(n.z)),SIMD3(Float(down.x),Float(down.y),Float(down.z)))))
    } else {node.eulerAngles = .init(p.underside ? .pi:0,p.rotation * .pi/180,0)}
    node.position = .init(p.position.x,p.position.y,p.position.z)
    return node.transform.raw
  }
}

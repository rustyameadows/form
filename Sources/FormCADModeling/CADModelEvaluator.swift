import Foundation
import CryptoKit
import FormCADModel
import FormCADKernel

public struct CADFeatureEvaluation: Sendable {
  public var id:UUID,name:String,kind:CADFeatureKind,fingerprint:String,fromCache:Bool,suppressed:Bool,info:CADShapeInfo
  public var durationMS:Double=0
}
public struct CADModelEvaluation: Sendable {
  public var modelID:UUID,modelRevision:Int,revisionHash:String,definition:CADModelDefinition
  public var outputs:[UUID:CADShape],features:[CADFeatureEvaluation],rebuiltFeatureIDs:[UUID]
  public var durationMS:Double=0
  public var checks:[CADGeometryCheckResult]=[]
  public var surfaces:[CADResolvedPlanarSurface]=[]
  public var surfaceIssues:[CADSurfaceResolutionIssue]=[]
  public var outputOrder:[UUID]{definition.outputs}
}
public struct CADModelEvaluationFailure: LocalizedError, Sendable {
  public let featureID:UUID?,message:String,previousValidRevisionHash:String?
  public var category:String="evaluation"
  public var requirementID:String?
  public var parameterValues:[String:Double]=[:]
  public var resolvedValues:[String:Double]=[:]
  public var inputFeatureIDs:[UUID]=[]
  public var errorDescription:String?{message}
}
public struct CADFeatureTopology: Sendable {
  public var featureID:UUID,fingerprint:String,modelRevisionHash:String,info:CADShapeInfo,faces:[CADFaceInfo],edges:[CADEdgeInfo]
}
public struct CADModelStageManifest: Codable, Sendable {
  public struct Output:Codable,Sendable{public var featureID:UUID,fingerprint:String,brep:String,step:String?,mesh:String,info:CADShapeInfo}
  public var formatVersion:Int=1
  public var kernelVersion:String,modelID:UUID,modelRevision:Int,revisionHash:String
  public var units:String="mm"
  public var upAxis:String="Y"
  public var outputs:[Output],files:[String:String]
}
private struct CachedFeature:Sendable{var fingerprint:String,shape:CADShape}

public actor CADModelEvaluator {
  public let kernel:CADKernel
  private var cache:[UUID:[UUID:CachedFeature]]=[:],accepted:[UUID:CADModelEvaluation]=[:],generations:[UUID:UUID]=[:]
  private var modelOrder:[UUID]=[],modelCosts:[UUID:Int]=[:],modelBytes=0,cacheEvictions=0,activeModels=Set<UUID>()
  public let maximumCachedModels:Int,topologyCacheBudgetBytes:Int
  private var meshCache:[String:CADMesh]=[:],meshOrder:[String]=[],meshCosts:[String:Int]=[:],meshBytes=0
  public init(kernel:CADKernel=CADKernel(),maximumCachedModels:Int=8,topologyCacheBudgetBytes:Int=256*1024*1024){self.kernel=kernel;self.maximumCachedModels=max(1,min(32,maximumCachedModels));self.topologyCacheBudgetBytes=max(4096,min(512*1024*1024,topologyCacheBudgetBytes))}
  public func lastValid(modelID:UUID)->CADModelEvaluation?{accepted[modelID]}
  public func featureShape(modelID:UUID,featureID:UUID,modelRevisionHash:String)throws->CADShape {
    guard accepted[modelID]?.revisionHash==modelRevisionHash,let feature=cache[modelID]?[featureID] else{throw CADModelError("The exact feature revision is unavailable or stale.")};return feature.shape
  }
  public func featureTopology(modelID:UUID,featureID:UUID,modelRevisionHash:String) async throws->CADFeatureTopology {
    let shape=try featureShape(modelID:modelID,featureID:featureID,modelRevisionHash:modelRevisionHash)
    guard let fingerprint=cache[modelID]?[featureID]?.fingerprint else{throw CADModelError("Exact feature fingerprint is unavailable.")}
    let faces=try await kernel.faces(shape),edges=try await kernel.edges(shape)
    _ = try featureShape(modelID:modelID,featureID:featureID,modelRevisionHash:modelRevisionHash)
    return .init(featureID:featureID,fingerprint:fingerprint,modelRevisionHash:modelRevisionHash,info:shape.info,faces:faces,edges:edges)
  }
  public func clear(){cache=[:];accepted=[:];generations=[:];modelOrder=[];modelCosts=[:];modelBytes=0;cacheEvictions=0;activeModels=[];meshCache=[:];meshOrder=[];meshCosts=[:];meshBytes=0}
  public var diagnostics:[String:Int]{["models":accepted.count,"model_cache_limit":maximumCachedModels,"feature_cache_estimated_bytes":modelBytes,"feature_cache_budget_bytes":topologyCacheBudgetBytes,"model_cache_evictions":cacheEvictions,"active_evaluations":activeModels.count,"cached_features":cache.values.reduce(0){$0+$1.count},"mesh_cache_bytes":meshBytes,"mesh_cache_limit_bytes":64*1024*1024,"mesh_cache_count":meshCache.count]}
  /// Forget a closed review/model and invalidate any late worker publication for it.
  public func forget(modelID:UUID){generations.removeValue(forKey:modelID);activeModels.remove(modelID);evict(modelID,count:false)}
  private static func estimatedBytes(_ shape:CADShape)->Int{2048+shape.info.faces*2048+shape.info.edges*256+shape.info.vertices*128}
  private func evict(_ id:UUID,count:Bool=true){cache.removeValue(forKey:id);accepted.removeValue(forKey:id);modelBytes-=modelCosts.removeValue(forKey:id) ?? 0;modelOrder.removeAll{$0==id};if count{cacheEvictions+=1}}
  private func makeRoom(for id:UUID,bytes:Int)throws {
    let replacing=accepted[id] != nil,old=modelCosts[id] ?? 0
    while accepted.count+(replacing ? 0:1)>maximumCachedModels || modelBytes-old+bytes>topologyCacheBudgetBytes {
      guard let victim=modelOrder.first(where:{$0 != id && !activeModels.contains($0)}) else{throw CADModelError("Active exact models exceed the bounded cache budget. Finish or cancel another evaluation before retrying; prior valid geometry is retained.")}
      evict(victim)
    }
  }
  public static func revisionHash(_ model:CADModelDefinition)throws->String{try digest(model)}
  private static func digest<T:Encodable>(_ value:T)throws->String{let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return SHA256.hash(data:try encoder.encode(value)).map{String(format:"%02x",$0)}.joined()}
  private func current(_ id:UUID,_ token:UUID)throws{try Task.checkCancellation();guard generations[id]==token else{throw CancellationError()}}
  public func evaluate(_ model:CADModelDefinition,resourcesAt root:URL?=nil,expectedRevisionHash:String?=nil) async throws->CADModelEvaluation {
    let evaluationStarted=ProcessInfo.processInfo.systemUptime
    let token=UUID();generations[model.id]=token;activeModels.insert(model.id);defer{if generations[model.id]==token{activeModels.remove(model.id)}};let previous=accepted[model.id]?.revisionHash
    var featureID:UUID?,resolvedValues:[String:Double]=[:],inputFeatureIDs:[UUID]=[]
    do {
      let revision=try Self.revisionHash(model)
      if let expectedRevisionHash,accepted[model.id]?.revisionHash != expectedRevisionHash{throw CADModelError("Stale CAD edit: the accepted model changed. Reinspect its revision before submitting.")}
      let order=try model.validatedOrder(),parameters=model.parameterValues
      for assembly in model.importedAssemblies ?? []{guard assembly.kernelVersion==CADKernel.version else{throw CADModelError("STEP occurrence selectors belong to another kernel version. Reinspect/reimport this source rather than silently changing part identity.")}}
      var verifiedSources:[String:URL]=[:],verifiedHashes:[String:String]=[:]
      for node in order{if let source=node.operation.source{if let hash=verifiedHashes[source.path]{guard hash==source.sha256.lowercased() else{throw CADModelError("Two features pin different source hashes to the same resource path.")}}else{verifiedSources[source.path]=try sourceURL(source,root:root);verifiedHashes[source.path]=source.sha256.lowercased()}}}
      var pending:[UUID:CachedFeature]=[:],reports:[CADFeatureEvaluation]=[],rebuilt:[UUID]=[],shapeIDs=Set<UUID>(),pendingBytes=0
      for node in order {
        let featureStarted=ProcessInfo.processInfo.systemUptime
        try current(model.id,token);featureID=node.id
        var count=0;let operation=try node.operation.resolved(using:parameters,count:&count)
        resolvedValues=try operation.values.mapValues{try CADExpression.evaluate($0.expression,variables:[:])};inputFeatureIDs=operation.inputs
        let inputs=try operation.inputs.map {id->CADShape in guard let input=pending[id]?.shape else{throw CADModelError("A dependent feature has no valid exact output.")};return input}
        let dependencyHashes=try operation.inputs.map{id->String in guard let value=pending[id]?.fingerprint else{throw CADModelError("A source feature fingerprint is missing.")};return value}
        struct Signature:Encodable{var version:Int=1,kernelVersion:String=CADKernel.version,operation:CADFeatureOperation,dependencies:[String],suppressed:Bool}
        let fingerprint=try Self.digest(Signature(operation:operation,dependencies:dependencyHashes,suppressed:node.suppressed))
        let shape:CADShape,hit:Bool
        if let saved=cache[model.id]?[node.id],saved.fingerprint==fingerprint{
          if operation.kind == .importedBRep || operation.kind == .importedSTEP{guard operation.source.flatMap({verifiedSources[$0.path]}) != nil else{throw CADModelError("Pinned source verification is missing.")}}
          shape=saved.shape;hit=true
        }
        else if node.suppressed {
          guard operation.kind.canSuppressToFirstInput,let first=inputs.first else{throw CADModelError("This feature cannot be suppressed to an existing body; remove its dependents or choose another output explicitly.")}
          shape=first;hit=false
        }else{shape=try await build(operation,inputs:inputs,dependencyHashes:dependencyHashes,resourcesAt:root,verifiedSources:verifiedSources);try current(model.id,token);hit=false;rebuilt.append(node.id)}
        if shapeIDs.insert(shape.id).inserted{pendingBytes+=Self.estimatedBytes(shape);guard pendingBytes<=topologyCacheBudgetBytes else{throw CADModelError("This exact model exceeds the conservative topology memory budget (\(topologyCacheBudgetBytes) bytes). Reduce feature/part complexity; the prior valid model is retained.")}}
        pending[node.id] = .init(fingerprint:fingerprint,shape:shape)
        reports.append(.init(id:node.id,name:node.name,kind:operation.kind,fingerprint:fingerprint,fromCache:hit,suppressed:node.suppressed,info:shape.info,durationMS:(ProcessInfo.processInfo.systemUptime-featureStarted)*1000))
      }
      try current(model.id,token)
      let outputs=try Dictionary(uniqueKeysWithValues:model.outputs.map{id->(UUID,CADShape) in guard let shape=pending[id]?.shape,shape.info.valid,shape.info.closed,shape.info.solids>0 else{throw CADModelError("A committed CAD output must be a valid closed solid. Profiles remain source features.")};return(id,shape)})
      var checks:[CADGeometryCheckResult]=[]
      for check in model.outputRequirements ?? [] {
        try current(model.id,token);featureID=check.outputID
        inputFeatureIDs=[check.outputID]+[check.otherOutputID].compactMap{$0}
        let measured=try await measure(check,outputs:outputs),expected=try CADExpression.evaluate(check.value.expression,variables:parameters)
        try current(model.id,token);resolvedValues=["measured":measured,"required":expected]
        try check.validate(measured:measured,values:parameters)
        checks.append(.init(id:check.id,outputID:check.outputID,otherOutputID:check.otherOutputID,metric:check.metric,measured:measured,expected:expected,relation:check.relation,tolerance:check.tolerance))
      }
      var result=CADModelEvaluation(modelID:model.id,modelRevision:model.revision,revisionHash:revision,definition:model,outputs:outputs,features:reports,rebuiltFeatureIDs:rebuilt,durationMS:0,checks:checks)
      let surfaceResults=try await resolvePlanarSurfaces(result,previous:accepted[model.id]?.definition.surfaces ?? [])
      try current(model.id,token)
      result.surfaces=surfaceResults.surfaces;result.surfaceIssues=surfaceResults.issues
      result.durationMS=(ProcessInfo.processInfo.systemUptime-evaluationStarted)*1000
      try makeRoom(for:model.id,bytes:pendingBytes)
      modelBytes-=modelCosts[model.id] ?? 0;modelCosts[model.id]=pendingBytes;modelBytes+=pendingBytes;modelOrder.removeAll{$0==model.id};modelOrder.append(model.id)
      cache[model.id]=pending;accepted[model.id]=result;return result
    }catch is CancellationError{throw CancellationError()}
    catch{
      let label=featureID.flatMap{id in model.features.first{$0.id==id}}.map{"Feature '\($0.name)' (\($0.operation.kind.rawValue)): "} ?? ""
      let requirement=error as? CADRequirementFailure
      let category=requirement != nil ? "requirement":(error as? CADKernelError).map{"kernel.\($0.code.rawValue)"} ?? "validation"
      throw CADModelEvaluationFailure(featureID:featureID,message:label+error.localizedDescription,previousValidRevisionHash:previous,category:category,requirementID:requirement?.requirementID,parameterValues:model.parameterValues,resolvedValues:resolvedValues,inputFeatureIDs:inputFeatureIDs)
    }
  }
  private func measure(_ check:CADOutputRequirement,outputs:[UUID:CADShape]) async throws->Double {
    guard let shape=outputs[check.outputID] else{throw CADModelError("Geometry requirement output is unavailable.")}
    switch check.metric {
    case .width:return shape.info.size.x
    case .height:return shape.info.size.y
    case .depth:return shape.info.size.z
    case .volume:return shape.info.volumeMM3
    case .area:return shape.info.areaMM2
    case .solids:return Double(shape.info.solids)
    case .clearance,.interference:
      guard let id=check.otherOutputID,let other=outputs[id] else{throw CADModelError("Geometry requirement's second output is unavailable.")}
      let measured=try await kernel.clearance(shape,other)
      return check.metric == .clearance ? measured.distanceMM:measured.interferenceVolumeMM3
    }
  }
  private func number(_ value:CADScalar)throws->Double{try CADExpression.evaluate(value.expression,variables:[:])}
  private func point(_ p:CADExpressionPoint)throws->CADPoint3{.init(try number(p.x),try number(p.y),try number(p.z))}
  private func point(_ p:CADExpressionPoint2)throws->CADPoint2{.init(try number(p.x),try number(p.y))}
  private func vector(_ p:CADModelVector)->CADPoint3{.init(p.x,p.y,p.z)}
  private func unit(_ p:CADModelVector)throws->CADPoint3{let n=sqrt(p.x*p.x+p.y*p.y+p.z*p.z);guard n.isFinite,n>1e-12 else{throw CADModelError("Choose a finite non-zero CAD direction.")};return .init(p.x/n,p.y/n,p.z/n)}
  private func plane(_ p:CADPlaneDefinition?)throws->CADPlane{let p=p ?? .xz;return .init(origin:try point(p.origin),u:vector(p.u),v:vector(p.v))}
  private func selected(_ selection:CADTopologySelection?,source:CADShape,hash:String,faces:Bool) async throws->[UInt32]{
    guard let selection else{if faces{throw CADModelError("Choose removed shell faces explicitly.")};return []}
    switch selection {
    case .allEdges:guard !faces else{throw CADModelError("Shell requires faces, not all edges.")};return []
    case let .edges(revisionHash,indices):guard !faces,revisionHash==hash else{throw CADModelError("Selected CAD edges belong to another revision; reinspection is required instead of silently remapping topology.")};return indices
    case let .faces(revisionHash,indices):guard faces,revisionHash==hash else{throw CADModelError("Selected CAD faces belong to another revision; reinspection is required instead of silently remapping topology.")};return indices
    case let .faceAtCenter(datum,tolerance):
      guard faces,tolerance.isFinite,tolerance>0,tolerance<=1 else{throw CADModelError("Face center selection requires a finite positive tolerance at most 1 mm.")}
      let p=try point(datum),list=try await kernel.faces(source)
      let matches=list.filter{hypot(hypot($0.center.x-p.x,$0.center.y-p.y),$0.center.z-p.z)<=tolerance}
      guard matches.count==1 else{throw CADModelError("The authored face center maps to \(matches.count) faces. Review this reference rather than silently choosing another surface.")}
      return [matches[0].index]
    case .straightEdgesAtMaximum(let axis),.straightEdgesAtMinimum(let axis):
      guard !faces,["x","y","z"].contains(axis) else{throw CADModelError("Use a straight-edge selector with x, y or z axis.")}
      func coordinate(_ p:CADPoint3)->Double{axis=="x" ? p.x:axis=="y" ? p.y:p.z}
      let maximum:Bool;if case .straightEdgesAtMaximum=selection{maximum=true}else{maximum=false}
      let bound=coordinate(maximum ? source.info.maximum:source.info.minimum),list=try await kernel.edges(source)
      let matches=list.filter{$0.curveType==0&&abs(coordinate($0.start)-bound)<=1e-6&&abs(coordinate($0.end)-bound)<=1e-6}
      guard !matches.isEmpty else{throw CADModelError("No straight edges remain on the authored bounding plane. Inspect this reference before applying the feature.")}
      return matches.map(\.index)
    case .facesAtExtrema(let axis):
      guard faces,["x","y","z"].contains(axis) else{throw CADModelError("Use a face selector with x, y or z axis.")}
      let low=try await selected(.faceAtMinimum(axis:axis),source:source,hash:hash,faces:true),high=try await selected(.faceAtMaximum(axis:axis),source:source,hash:hash,faces:true)
      guard Set(low+high).count==2 else{throw CADModelError("The opening faces are ambiguous; inspect before shelling.")};return low+high
    case .faceAtMaximum(let axis),.faceAtMinimum(let axis):
      guard faces,["x","y","z"].contains(axis) else{throw CADModelError("Use a face selector with x, y or z axis.")}
      func coordinate(_ p:CADPoint3)->Double{axis=="x" ? p.x:axis=="y" ? p.y:p.z}
      let maximum:Bool;if case .faceAtMaximum=selection{maximum=true}else{maximum=false}
      let bound=coordinate(maximum ? source.info.maximum:source.info.minimum)
      let list=try await kernel.faces(source),matches=list.filter{abs(coordinate($0.minimum)-bound)<=1e-6&&abs(coordinate($0.maximum)-bound)<=1e-6}
      guard matches.count==1 else{throw CADModelError("The semantic face anchor maps to \(matches.count) faces. Review this topology change before applying the feature.")};return [matches[0].index]
    }
  }
  func surfaceFaceIndex(_ selection:CADTopologySelection,source:CADShape,fingerprint:String) async throws->UInt32 {
    let faces=try await selected(selection,source:source,hash:fingerprint,faces:true)
    guard faces.count==1 else{throw CADModelError("A physical artwork surface must resolve to exactly one face; this selector matched \(faces.count).")}
    return faces[0]
  }
  private func build(_ op:CADFeatureOperation,inputs:[CADShape],dependencyHashes:[String],resourcesAt root:URL?,verifiedSources:[String:URL]) async throws->CADShape {
    func v(_ key:String,_ fallback:Double?=nil)throws->Double{if let raw=op.values[key]{return try number(raw)};if let fallback{return fallback};throw CADModelError("Missing scalar '\(key)' for \(op.kind.rawValue).")}
    func first()throws->CADShape{guard let shape=inputs.first else{throw CADModelError("CAD feature has no source.")};return shape}
    let axis=try unit(op.direction ?? .yAxis)
    switch op.kind {
    case .copy:return try await kernel.transform(first(),rowMajorMatrix:[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])
    case .join:return try await kernel.boolean(.union,inputs[0],inputs[1])
    case .offsetProfile:return try await kernel.offsetProfile(first(),distance:v("distance"))
    case .hole:
      let frame=try plane(op.plane),profile=try await kernel.circleProfile(radius:v("radius"),plane:frame),normal=try op.direction.map(unit) ?? frame.normal
      let tool=try await kernel.extrude(profile,vector:normal * v("depth"));return try await kernel.boolean(.subtract,first(),tool)
    case .slot:
      let length=try v("length"),width=try v("width"),radius=width/2,straight=length/2-radius,frame=try plane(op.plane)
      guard width>0,length>width else{throw CADModelError("A slot needs positive width and length greater than width.")}
      func p(_ x:Double,_ y:Double)->CADPoint3{frame.point(.init(x,y))}
      let curves:[CADCurveSegment]=[.init(.line,start:p(-straight,-radius),end:p(straight,-radius)),.init(.circularArc,start:p(straight,-radius),control1:p(straight+radius,0),end:p(straight,radius)),.init(.line,start:p(straight,radius),end:p(-straight,radius)),.init(.circularArc,start:p(-straight,radius),control1:p(-straight-radius,0),end:p(-straight,-radius))]
      let profile=try await kernel.curveProfile(curves),normal=try op.direction.map(unit) ?? frame.normal,tool=try await kernel.extrude(profile,vector:normal * v("depth"));return try await kernel.boolean(.subtract,first(),tool)
    case .pocket,.boss:
      let tool=try await kernel.extrude(inputs[1],vector:axis * v("distance"));return try await kernel.boolean(op.kind == .boss ? .union:.subtract,inputs[0],tool)
    case .box:return try await kernel.box(width:v("width"),height:v("height"),depth:v("depth"))
    case .cylinder:return try await kernel.cylinder(radius:v("radius"),height:v("height"))
    case .cone:return try await kernel.cone(bottomRadius:v("bottomRadius"),topRadius:v("topRadius"),height:v("height"))
    case .sphere:return try await kernel.sphere(radius:v("radius"))
    case .torus:return try await kernel.torus(majorRadius:v("majorRadius"),minorRadius:v("minorRadius"))
    case .profile:return try await kernel.profile(outer:(op.points ?? []).map(point),holes:(op.holes ?? []).map{try $0.map(point)},plane:plane(op.plane))
    case .circleProfile:return try await kernel.circleProfile(radius:v("radius"),plane:plane(op.plane))
    case .curveProfile:
      let frame=try plane(op.plane),segments=try (op.curves ?? []).map {s->CADCurveSegment in
        let kind:CADCurveSegment.Kind;switch s.kind{case .line:kind = .line;case .quadraticBezier:kind = .quadraticBezier;case .cubicBezier:kind = .cubicBezier;case .circularArc:kind = .circularArc}
        return .init(kind,start:frame.point(try point(s.start)),control1:try s.control1.map{frame.point(try point($0))} ?? .init(),control2:try s.control2.map{frame.point(try point($0))} ?? .init(),end:frame.point(try point(s.end)))
      };return try await kernel.curveProfile(segments)
    case .extrude:return try await kernel.extrude(first(),vector:axis * v("distance"))
    case .extrudeCut:let tool=try await kernel.extrude(inputs[1],vector:axis * v("distance"));return try await kernel.boolean(.subtract,inputs[0],tool)
    case .revolve:return try await kernel.revolve(first(),axisOrigin:point(op.origin ?? .init()),axisDirection:axis,radians:v("angleDegrees",360)*Double.pi/180)
    case .revolveCut:let tool=try await kernel.revolve(inputs[1],axisOrigin:point(op.origin ?? .init()),axisDirection:axis,radians:v("angleDegrees",360)*Double.pi/180);return try await kernel.boolean(.subtract,inputs[0],tool)
    case .union:return try await kernel.boolean(.union,inputs[0],inputs[1])
    case .subtract:return try await kernel.boolean(.subtract,inputs[0],inputs[1])
    case .intersect:return try await kernel.boolean(.intersection,inputs[0],inputs[1])
    case .fillet:let ids=try await selected(op.selection,source:first(),hash:dependencyHashes[0],faces:false);return try await kernel.fillet(first(),edges:ids,radius:v("radius"))
    case .chamfer:let ids=try await selected(op.selection,source:first(),hash:dependencyHashes[0],faces:false);return try await kernel.chamfer(first(),edges:ids,distance:v("distance"))
    case .shell:let ids=try await selected(op.selection,source:first(),hash:dependencyHashes[0],faces:true);return try await kernel.shell(first(),removingFaces:ids,thickness:v("thickness"))
    case .sweep:return try await kernel.sweep(first(),path:(op.path ?? []).map(point))
    case .loft:return try await kernel.loft(inputs,ruled:op.ruled ?? false)
    case .transform:return try await kernel.transform(first(),rowMajorMatrix:(op.matrix ?? []).map(number))
    case .linearPattern:
      let n=try v("count");guard n.rounded()==n,n>=1,n<=512 else{throw CADModelError("Pattern count must be an integer between 1 and 512.")};let step=try point(op.vector ?? .init());var shapes:[CADShape]=[]
      for i in 0..<Int(n){try Task.checkCancellation();shapes.append(try await kernel.translated(first(),by:step*Double(i)))};return try await kernel.compound(shapes)
    case .circularPattern:
      let n=try v("count");guard n.rounded()==n,n>=1,n<=512 else{throw CADModelError("Pattern count must be an integer between 1 and 512.")};let step=try v("angleStepDegrees")*Double.pi/180,origin=try point(op.origin ?? .init());var shapes:[CADShape]=[]
      for i in 0..<Int(n){try Task.checkCancellation();let a=step*Double(i),c=cos(a),s=sin(a),t=1-c,x=axis.x,y=axis.y,z=axis.z,r=[t*x*x+c,t*x*y-s*z,t*x*z+s*y,t*x*y+s*z,t*y*y+c,t*y*z-s*x,t*x*z-s*y,t*y*z+s*x,t*z*z+c];let tx=origin.x-r[0]*origin.x-r[1]*origin.y-r[2]*origin.z,ty=origin.y-r[3]*origin.x-r[4]*origin.y-r[5]*origin.z,tz=origin.z-r[6]*origin.x-r[7]*origin.y-r[8]*origin.z
        shapes.append(try await kernel.transform(first(),rowMajorMatrix:[r[0],r[1],r[2],tx,r[3],r[4],r[5],ty,r[6],r[7],r[8],tz,0,0,0,1]))
      };return try await kernel.compound(shapes)
    case .mirror:
      let p=try plane(op.plane),n=p.normal,o=p.origin,x=n.x,y=n.y,z=n.z,d=2*(o.x*x+o.y*y+o.z*z)
      return try await kernel.transform(first(),rowMajorMatrix:[1-2*x*x,-2*x*y,-2*x*z,d*x,-2*y*x,1-2*y*y,-2*y*z,d*y,-2*z*x,-2*z*y,1-2*z*z,d*z,0,0,0,1])
    case .assembly:return try await kernel.compound(inputs)
    case .importedBRep,.importedSTEP:
      let file:URL;if let source=op.source,let verified=verifiedSources[source.path]{file=verified}else{file=try sourceURL(op.source,root:root)}
      if op.kind == .importedBRep{return try await kernel.readBRep(from:file)}
      if let partPath=op.source?.partPath{return try await kernel.readSTEP(from:file,partPath:partPath,verifiedSourceSHA256:op.source?.sha256.lowercased())}
      return try await kernel.readSTEP(from:file)
    }
  }
  private func sourceURL(_ source:CADSourceReference?,root:URL?)throws->URL {
    guard let source,let root else{throw CADModelError("The exact source asset root is unavailable.")}
      let directory=root.standardizedFileURL.resolvingSymlinksInPath(),file=directory.appendingPathComponent(source.path).standardizedFileURL.resolvingSymlinksInPath()
      guard file.path.hasPrefix(directory.path+"/"),(try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])).isRegularFile==true else{throw CADModelError("Exact source escapes its resource root or is not a regular file.")}
      let size=try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size>0,size<=256*1024*1024 else{throw CADModelError("Exact source exceeds the 256 MiB import bound.")}
      let hash=SHA256.hash(data:try Data(contentsOf:file,options:.mappedIfSafe)).map{String(format:"%02x",$0)}.joined();guard hash==source.sha256.lowercased() else{throw CADModelError("Exact source digest changed; import a new revision rather than silently replacing it.")}
    return file
  }
  public func mesh(for evaluation:CADModelEvaluation,outputID:UUID,quality:CADTessellation = .inspection) async throws->CADMesh {
    guard let shape=evaluation.outputs[outputID],let feature=evaluation.features.first(where:{$0.id==outputID}) else{throw CADModelError("No exact output shape for display tessellation.")}
    let key=feature.fingerprint+"|"+(try Self.digest(quality))
    if let mesh=meshCache[key]{meshOrder.removeAll{$0==key};meshOrder.append(key);return mesh}
    let mesh=try await kernel.tessellate(shape,quality:quality),cost=mesh.positions.count*8*8+mesh.indices.count*4+mesh.faceIndices.count*4
    if cost<=64*1024*1024{while meshBytes+cost>64*1024*1024 || meshOrder.count>=64{guard let old=meshOrder.first else{break};meshOrder.removeFirst();meshCache.removeValue(forKey:old);meshBytes-=meshCosts.removeValue(forKey:old) ?? 0};meshCache[key]=mesh;meshCosts[key]=cost;meshOrder.append(key);meshBytes+=cost}
    return mesh
  }
  /// Publishes a new immutable artifact directory only after every output succeeds.
  /// Root still validates the native project revision before referencing this stage.
  public func stageSources(_ evaluation:CADModelEvaluation,to destination:URL,includeSTEP:Bool=true,quality:CADTessellation = .fabrication) async throws->CADModelStageManifest {
    guard destination.isFileURL,!FileManager.default.fileExists(atPath:destination.path) else{throw CADModelError("Choose a new CAD revision destination; existing outputs remain immutable.")}
    func fresh()throws{try Task.checkCancellation();guard accepted[evaluation.modelID]?.revisionHash==evaluation.revisionHash else{throw CADModelError("The CAD revision changed while exact sources were staging; no files were published.")}}
    try fresh();let stage=destination.deletingLastPathComponent().appendingPathComponent(".lab-cad-stage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false);defer{try? FileManager.default.removeItem(at:stage)}
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];try encoder.encode(evaluation.definition).write(to:stage.appendingPathComponent("Model.json"),options:.atomic)
    var outputs:[CADModelStageManifest.Output]=[]
    for id in evaluation.outputOrder {
      try fresh();guard let shape=evaluation.outputs[id],let report=evaluation.features.first(where:{$0.id==id}) else{throw CADModelError("Staged CAD output is missing.")}
      let name=id.uuidString.lowercased(),brep=name+".brep",step=includeSTEP ? name+".step":nil,meshName=name+".mesh"
      try await kernel.writeBRep(shape,to:stage.appendingPathComponent(brep));try fresh()
      if let step{try await kernel.writeSTEP(shape,to:stage.appendingPathComponent(step));try fresh()}
      let mesh=try await mesh(for:evaluation,outputID:id,quality:quality);try fresh();try CADMeshArchive.encode(mesh).write(to:stage.appendingPathComponent(meshName),options:.atomic)
      outputs.append(.init(featureID:id,fingerprint:report.fingerprint,brep:brep,step:step,mesh:meshName,info:shape.info))
    }
    var files:[String:String]=[:];for file in try FileManager.default.contentsOfDirectory(at:stage,includingPropertiesForKeys:nil){files[file.lastPathComponent]=SHA256.hash(data:try Data(contentsOf:file,options:.mappedIfSafe)).map{String(format:"%02x",$0)}.joined()}
    let manifest=CADModelStageManifest(kernelVersion:CADKernel.version,modelID:evaluation.modelID,modelRevision:evaluation.modelRevision,revisionHash:evaluation.revisionHash,outputs:outputs,files:files)
    try encoder.encode(manifest).write(to:stage.appendingPathComponent("Manifest.json"),options:.atomic);try fresh();try FileManager.default.moveItem(at:stage,to:destination);return manifest
  }
}

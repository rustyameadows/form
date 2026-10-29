import AppKit
import CoreFoundation
import Foundation
import FormCore
import FormCADModel
import FormCADKernel
import FormCADModeling

/// Evidence has its own lifetime. Reading topology or rendering a view never
/// replaces an evaluation task, another inspection result, or project state.
@MainActor final class CADEvidenceRequest {
  let id=UUID(),jobID:UUID,revision:String,token:UUID
  var state="pending",results:[[String:Any]]=[],issue:String?
  var elapsedMS=0.0
  init(job:CADModelReview,revision:String){jobID=job.id;self.revision=revision;token=job.token}
  var response:[String:Any] {
    var value:[String:Any] = ["request_id":id.uuidString,"job_id":jobID.uuidString,"revision":revision,"kernel_version":CADKernel.version,"state":state,"units":"mm","results":results,"elapsed_ms":elapsedMS]
    if let issue{value["error"]=issue};return value
  }
}

enum CADLoopInput {
  static func object(_ value:Any,keys:Set<String>,label:String)throws->[String:Any] {
    guard let result=value as? [String:Any],Set(result.keys).isSubset(of:keys) else{throw FormError.invalid("Unsupported fields in \(label).")};return result
  }
  static func number(_ value:Any?,label:String,default fallback:Double?=nil)throws->Double {
    if value==nil,let fallback{return fallback}
    guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{throw FormError.invalid("\(label) must be a finite number.")};return n.doubleValue
  }
  static func id(_ value:Any?,label:String)throws->UUID {
    guard let text=value as? String,let id=UUID(uuidString:text) else{throw FormError.invalid("Provide a valid \(label).")};return id
  }
  static func boolean(_ value:Any?,label:String,default fallback:Bool=false)throws->Bool {
    if value==nil{return fallback};guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{throw FormError.invalid("\(label) must be boolean.")};return n.boolValue
  }
}

extension CADModelCoordinator {
  func suppliedEvidence(_ args:[String:Any])throws->[[String:Any]]? {
    guard let raw=args["evidence"] else{return nil}
    guard let requests=raw as? [[String:Any]] else{throw FormError.invalid("evidence must be an array of evidence requests.")}
    try validateEvidence(requests);return requests
  }

  func loopCall(_ command:String,_ args:[String:Any])throws->Any {
    let fields:[String:Set<String>] = ["patch":["job_id","expected_revision","patches","evidence","quality"],"evidence":["job_id","requests"],"evidence_status":["request_id"],"validation_status":["request_id"],"evidence_cancel":["request_id"],"validate":["job_id","cases","include_extrema","maximum_cases","maximum_duration_seconds"]]
    guard let allowed=fields[command] else{throw FormError.invalid("Unknown CAD loop command.")}
    _ = try CADLoopInput.object(args,keys:allowed.union(["command"]),label:"CAD loop command")
    if ["evidence_status","validation_status","evidence_cancel"].contains(command) {
      let id=try CADLoopInput.id(args["request_id"],label:"request_id")
      guard let request=evidenceRequests[id] else{throw FormError.missing("CAD evidence request is unavailable.")}
      if command=="evidence_cancel",request.state=="pending"{jobs[request.jobID]?.evidenceTasks[id]?.cancel();request.state="cancelled"}
      return request.response
    }
    let id=try CADLoopInput.id(args["job_id"],label:"job_id")
    guard let job=jobs[id] else{throw FormError.missing("CAD job is unavailable.")}
    switch command {
    case "patch":
      guard let revision=args["expected_revision"] as? String,let patches=args["patches"] as? [[String:Any]] else{throw FormError.invalid("Provide expected_revision and an array of patches.")}
      if let quality=args["quality"]{guard let value=quality as? String,["preview","inspection","fabrication"].contains(value) else{throw FormError.invalid("Choose preview, inspection or fabrication quality.")}}
      let requests=try suppliedEvidence(args),oldQuality=job.quality
      if let quality=args["quality"] as? String{job.quality=quality}
      do{try patch(job,expectedRevision:revision,patches:patches,evidence:requests)}catch{job.quality=oldQuality;throw error}
      return status(job)
    case "evidence":
      guard let requests=args["requests"] as? [[String:Any]] else{throw FormError.invalid("Provide an array of evidence requests.")}
      return try startEvidence(job,requests:requests).response
    case "validate":return try startParameterValidation(job,args:args).response
    default:throw FormError.invalid("Unknown CAD loop command.")
    }
  }

  func startParameterValidation(_ job:CADModelReview,args:[String:Any])throws->CADEvidenceRequest {
    guard matches(job),!["cancelled","committed","publishing"].contains(job.state) else{throw FormError.invalid("Choose a current CAD draft for parameter validation.")}
    let raw=args["cases"] ?? []
    guard let casesJSON=raw as? [[String:Any]],casesJSON.count<=128 else{throw FormError.invalid("Provide bounded named parameter cases.")}
    for item in casesJSON{_ = try CADLoopInput.object(item,keys:["name","values"],label:"parameter case");guard let values=item["values"] as? [String:Any] else{throw FormError.invalid("Each parameter case needs a values map.")};for (key,value) in values{_ = try CADLoopInput.number(value,label:key)}}
    let cases=try JSONDecoder().decode([CADParameterCase].self,from:JSONSerialization.data(withJSONObject:casesJSON))
    let extrema=try CADLoopInput.boolean(args["include_extrema"],label:"include_extrema"),budget=try CADLoopInput.number(args["maximum_cases"],label:"maximum_cases",default:64),duration=try CADLoopInput.number(args["maximum_duration_seconds"],label:"maximum_duration_seconds",default:60)
    guard budget.rounded()==budget,(1...128).contains(budget),(0.01...300).contains(duration) else{throw FormError.invalid("Use 1–128 whole cases and a 0.01–300 second validation budget.")}
    _ = try CADParameterValidation.expandedCases(model:job.definition,cases:cases,includeExtrema:extrema,maximumCases:Int(budget))
    guard evidenceRequests.values.filter({$0.state=="pending"}).count<8 else{throw FormError.invalid("Finish a CAD evidence request before starting another.")}
    while evidenceRequests.count>=64,let old=evidenceRequests.values.first(where:{$0.state != "pending"}){evidenceRequests.removeValue(forKey:old.id)}
    let definition=job.definition,request=CADEvidenceRequest(job:job,revision:try CADModelEvaluator.revisionHash(definition)),resources=job.prepared?.stage.appendingPathComponent("Sources",isDirectory:true) ?? store!.repository.url(for:job.projectID).appendingPathComponent("Assets"),started=ProcessInfo.processInfo.systemUptime
    evidenceRequests[request.id]=request
    let worker=Task.detached(priority:.userInitiated){try await CADParameterValidation.run(model:definition,cases:cases,includeExtrema:extrema,maximumCases:Int(budget),resourcesAt:resources,maximumDurationSeconds:duration)}
    job.evidenceTasks[request.id]=Task{[weak self,weak job] in
      guard let self,let job else{worker.cancel();return}
      defer{job.evidenceTasks.removeValue(forKey:request.id)}
      do {
        let report=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
        guard !Task.isCancelled,job.token==request.token,self.matches(job) else{throw CancellationError()}
        request.results=[["kind":"validation","revision":request.revision,"state":"complete","report":try jsonObject(report)]];request.state="complete"
      } catch let interrupted as CADParameterValidationInterrupted {
        request.state=interrupted.reason == .cancelled ? "cancelled":"failed"
        request.issue=interrupted.localizedDescription
        do {
          request.results=[["kind":"validation","revision":request.revision,"state":request.state,
            "report":try jsonObject(interrupted.report)]]
        } catch {
          request.state="failed";request.issue=error.localizedDescription
          request.results=[["kind":"validation","state":"failed",
            "diagnostic":self.diagnostic(error,job:job,category:"validation_report")]]
        }
      }catch{request.state=error is CancellationError ? "cancelled":"failed";request.issue=error.localizedDescription;request.results=[["kind":"validation","state":request.state,"diagnostic":self.diagnostic(error,job:job,category:"validation")]]}
      request.elapsedMS=(ProcessInfo.processInfo.systemUptime-started)*1000
    }
    return request
  }

  func diagnostic(_ error:Error,job:CADModelReview,category:String="evaluation")->[String:Any] {
    var result:[String:Any] = ["category":category,"model_id":job.definition.id.uuidString,"kernel_version":CADKernel.version,"draft_revision":(try? CADModelEvaluator.revisionHash(job.definition)) as Any? ?? NSNull(),"message":error.localizedDescription,"parameters":job.definition.parameterValues]
    if let failure=error as? CADModelEvaluationFailure {
      result["category"]=failure.category;result["requirement_id"]=failure.requirementID as Any? ?? NSNull();result["resolved_values"]=failure.resolvedValues;result["input_ids"]=failure.inputFeatureIDs.map(\.uuidString)
      result["previous_valid_revision"]=failure.previousValidRevisionHash as Any? ?? NSNull()
      if let id=failure.featureID,let feature=job.definition.features.first(where:{$0.id==id}) {
        result["feature_id"]=id.uuidString;result["feature_name"]=feature.name;result["operation"]=feature.operation.kind.rawValue;result["input_ids"]=feature.operation.inputs.map(\.uuidString)
        var count=0
        if let resolved=try? feature.operation.resolved(using:job.definition.parameterValues,count:&count){result["resolved_operation"]=try? jsonObject(resolved)}
      }
    }
    if let failure=error as? CADRequirementFailure {
      result["category"]="requirement";result["requirement_id"]=failure.requirementID
      result["lhs"]=failure.lhs;result["rhs"]=failure.rhs;result["relation"]=failure.relation.rawValue
    }
    return result
  }

  /// Validate the whole batch against a private copy before changing the draft.
  /// The job survives failed kernel evaluation so the next patch can repair it.
  func patch(_ job:CADModelReview,expectedRevision:String,patches:[[String:Any]],evidence:[[String:Any]]?=nil)throws {
    guard !["publishing","committed","cancelled"].contains(job.state),matches(job) else{throw FormError.invalid("Choose a current editable CAD draft.")}
    guard try CADModelEvaluator.revisionHash(job.definition)==expectedRevision else{throw FormError.invalid("Stale CAD draft revision. Inspect the draft before applying this patch.")}
    guard !patches.isEmpty,patches.count<=256 else{throw FormError.invalid("Use 1–256 atomic CAD patches.")}
    if let evidence{try validateEvidence(evidence)}
    var next=job.definition
    for raw in patches {
      guard let action=raw["action"] as? String else{throw FormError.invalid("A CAD patch needs an action.")}
      let fields:[String:Set<String>] = ["parameters":["values"],"append":["feature"],"replace":["feature_id","operation"],"remove":["feature_id"],"suppress":["feature_id","suppressed"],"outputs":["outputs"],"requirements":["requirements"],"output_requirements":["requirements"],"surfaces":["surfaces"]]
      guard let allowed=fields[action] else{throw FormError.invalid("Unknown CAD patch action '\(action)'.")}
      _ = try CADLoopInput.object(raw,keys:allowed.union(["action"]),label:"CAD patch")
      switch action {
      case "parameters":
        guard let values=raw["values"] as? [String:Any],!values.isEmpty else{throw FormError.invalid("Provide a nonempty parameter values map.")}
        for (name,value) in values{try next.setParameter(name,value:CADLoopInput.number(value,label:name))}
      case "append":
        guard let feature=raw["feature"] else{throw FormError.invalid("Provide the appended feature.")}
        try Self.validateFeatureJSON(feature);next.features.append(try JSONDecoder().decode(CADFeatureNode.self,from:JSONSerialization.data(withJSONObject:feature)))
      case "replace","remove","suppress":
        let id=try CADLoopInput.id(raw["feature_id"],label:"feature_id")
        guard let index=next.features.firstIndex(where:{$0.id==id}) else{throw FormError.missing("The patched CAD feature is unavailable.")}
        if action=="remove"{next.features.remove(at:index)}
        else if action=="suppress"{next.features[index].suppressed=try CADLoopInput.boolean(raw["suppressed"],label:"suppressed")}
        else{guard let operation=raw["operation"] else{throw FormError.invalid("Provide the replacement operation.")};try Self.validateOperationJSON(operation);next.features[index].operation=try JSONDecoder().decode(CADFeatureOperation.self,from:JSONSerialization.data(withJSONObject:operation))}
      case "outputs":
        guard let values=raw["outputs"] as? [String] else{throw FormError.invalid("Provide output feature IDs.")};next.outputs=try values.map{try CADLoopInput.id($0,label:"output ID")}
      case "requirements":
        guard let values=raw["requirements"] as? [[String:Any]] else{throw FormError.invalid("Provide authored CAD requirements.")}
        for value in values{try Self.validateRequirementJSON(value,output:false)}
        next.requirements=try JSONDecoder().decode([CADModelRequirement].self,from:JSONSerialization.data(withJSONObject:values));next.version=2
      case "output_requirements":
        guard let values=raw["requirements"] as? [[String:Any]] else{throw FormError.invalid("Provide authored CAD output requirements.")}
        for value in values{try Self.validateRequirementJSON(value,output:true)}
        next.outputRequirements=try JSONDecoder().decode([CADOutputRequirement].self,from:JSONSerialization.data(withJSONObject:values));next.version=2
      case "surfaces":
        guard let values=raw["surfaces"] as? [[String:Any]] else{throw FormError.invalid("Provide authored CAD surfaces.")};for value in values{try Self.validateSurfaceJSON(value)}
        next.surfaces=try JSONDecoder().decode([CADPlanarSurface].self,from:JSONSerialization.data(withJSONObject:values));next.version=2
      default:break
      }
    }
    next.revision=job.definition.revision+1
    _ = try next.validatedOrder(checkRequirements:false)
    job.definition=next;job.pendingEvidence=evidence;preview(job)
  }

  func cancelEvidence(for job:CADModelReview) {
    for (id,task) in job.evidenceTasks {task.cancel();if let request=evidenceRequests[id],request.state=="pending"{request.state="cancelled"}}
    job.evidenceTasks=[:]
  }

  func validateEvidence(_ requests:[[String:Any]])throws {
    guard !requests.isEmpty,requests.count<=16 else{throw FormError.invalid("Request 1–16 bounded CAD evidence items.")}
    var totalPixels=0
    for raw in requests {
      guard let kind=raw["kind"] as? String else{throw FormError.invalid("CAD evidence needs a kind.")}
      let fields:[String:Set<String>] = ["summary":[],"topology":["feature_id","limit"],"clearance":["first_output_id","second_output_id"],"render":["path","view","width","height","transparent"],"export":["output_id","path","format"]]
      guard let allowed=fields[kind] else{throw FormError.invalid("Unknown CAD evidence kind '\(kind)'.")}
      _ = try CADLoopInput.object(raw,keys:allowed.union(["kind"]),label:"CAD evidence")
      for key in ["feature_id","first_output_id","second_output_id","output_id"] where raw[key] != nil{_ = try CADLoopInput.id(raw[key],label:key)}
      if kind=="topology"{_ = try CADLoopInput.id(raw["feature_id"],label:"feature_id");let limit=try CADLoopInput.number(raw["limit"],label:"limit",default:512);guard limit.rounded()==limit,(1...4096).contains(limit) else{throw FormError.invalid("Topology evidence limit must be 1–4096.")}}
      if kind=="clearance"{for key in ["first_output_id","second_output_id"]{_ = try CADLoopInput.id(raw[key],label:key)}}
      if kind=="render" || kind=="export" {
        guard let path=raw["path"] as? String,path.hasPrefix("/"),!FileManager.default.fileExists(atPath:path) else{throw FormError.invalid("CAD evidence needs a new absolute destination path.")}
        if kind=="render" {
          let width=try CADLoopInput.number(raw["width"],label:"width",default:1200),height=try CADLoopInput.number(raw["height"],label:"height",default:900),view=raw["view"] as? String ?? "perspective"
          guard URL(fileURLWithPath:path).pathExtension.lowercased()=="png",["perspective","front","top"].contains(view),width>=1,height>=1,width<=8192,height<=8192,width.rounded()==width,height.rounded()==height,width*height<=32_000_000 else{throw FormError.invalid("Use perspective/front/top, PNG, and 1–8192 integer pixels per edge (32 megapixels per image).")}
          totalPixels+=Int(width*height);_ = try CADLoopInput.boolean(raw["transparent"],label:"transparent")
        }else{_ = try CADLoopInput.id(raw["output_id"],label:"output_id");guard ["step","brep"].contains(raw["format"] as? String ?? "step") else{throw FormError.invalid("Exact export supports STEP or BRep.")}}
      }
    }
    guard totalPixels<=64_000_000 else{throw FormError.invalid("One evidence request is limited to 64 megapixels.")}
  }

  @discardableResult func startEvidence(_ job:CADModelReview,requests:[[String:Any]],legacy:Bool=false)throws->CADEvidenceRequest {
    try validateEvidence(requests)
    guard job.state=="ready",let prepared=job.prepared,matches(job),try CADModelEvaluator.revisionHash(job.definition)==prepared.evaluation.revisionHash else{throw FormError.invalid("Evidence requires a current evaluated CAD revision.")}
    guard evidenceRequests.values.filter({$0.state=="pending"}).count<8 else{throw FormError.invalid("Finish or cancel a CAD evidence request before starting another.")}
    while evidenceRequests.count>=64,let old=evidenceRequests.values.first(where:{$0.state != "pending"}){evidenceRequests.removeValue(forKey:old.id)}
    let request=CADEvidenceRequest(job:job,revision:prepared.evaluation.revisionHash),evaluator=self.evaluator,started=ProcessInfo.processInfo.systemUptime
    evidenceRequests[request.id]=request
    if legacy{job.result=["pending":true,"request_id":request.id.uuidString,"revision":request.revision]}
    job.evidenceTasks[request.id]=Task{[weak self,weak job] in
      guard let self,let job else{return}
      defer{job.evidenceTasks.removeValue(forKey:request.id)}
      var created:[URL]=[]
      do {
        for raw in requests {
          try Task.checkCancellation()
          guard job.token==request.token,self.matches(job),job.prepared?.evaluation.revisionHash==request.revision else{throw CancellationError()}
          let kind=raw["kind"] as! String,itemStart=ProcessInfo.processInfo.systemUptime
          var result:[String:Any] = ["kind":kind,"revision":request.revision]
          do {
            switch kind {
            case "summary":
              result["kernel_version"]=CADKernel.version;result["numeric_metadata"]=Self.numericMetadataProvenance(prepared.representation,saved:false)
              result["outputs"]=try prepared.evaluation.outputOrder.map{id->[String:Any] in guard let output=prepared.evaluation.outputs[id] else{throw FormError.missing("Exact output is unavailable.")};return ["output_id":id.uuidString,"info":try jsonObject(output.info)]}
              result["features"]=prepared.evaluation.features.map{["feature_id":$0.id.uuidString,"name":$0.name,"operation":$0.kind.rawValue,"fingerprint":$0.fingerprint,"from_cache":$0.fromCache] as [String:Any]}
              result["checks"]=try jsonObject(prepared.evaluation.checks)
              result["surfaces"]=try jsonObject(prepared.evaluation.surfaces);result["surface_issues"]=try jsonObject(prepared.evaluation.surfaceIssues)
              result["surface_artwork_issues"]=try jsonObject(self.surfacePlacementIssues(job))
              result["timings_ms"]=prepared.timings;result["cache"]=await evaluator.diagnostics
            case "topology":
              let id=try CADLoopInput.id(raw["feature_id"],label:"feature_id"),topology=try await evaluator.featureTopology(modelID:prepared.definition.id,featureID:id,modelRevisionHash:request.revision)
              let limit=Int(try CADLoopInput.number(raw["limit"],label:"limit",default:512))
              result["feature_id"]=id.uuidString;result["fingerprint"]=topology.fingerprint;result["info"]=try jsonObject(topology.info);result["faces"]=try jsonObject(Array(topology.faces.prefix(limit)));result["edges"]=try jsonObject(Array(topology.edges.prefix(limit)));result["face_count"]=topology.faces.count;result["edge_count"]=topology.edges.count;result["truncated"]=topology.faces.count>limit || topology.edges.count>limit
            case "clearance":
              let a=try CADLoopInput.id(raw["first_output_id"],label:"first_output_id"),b=try CADLoopInput.id(raw["second_output_id"],label:"second_output_id")
              guard let first=prepared.evaluation.outputs[a],let second=prepared.evaluation.outputs[b] else{throw FormError.missing("Choose two evaluated output IDs.")}
              let measured=try await evaluator.kernel.clearance(first,second)
              result["first_output_id"]=a.uuidString;result["second_output_id"]=b.uuidString;result["distance_mm"]=measured.distanceMM;result["interference_volume_mm3"]=measured.interferenceVolumeMM3
            case "render":
              let destination=URL(fileURLWithPath:raw["path"] as! String),width=Int(try CADLoopInput.number(raw["width"],label:"width",default:1200)),height=Int(try CADLoopInput.number(raw["height"],label:"height",default:900)),view=raw["view"] as? String ?? "perspective",transparent=try CADLoopInput.boolean(raw["transparent"],label:"transparent")
              let image=try await CADReviewRenderer.render(scene:prepared.scene,view:view,width:width,height:height,transparent:transparent)
              try Task.checkCancellation();guard job.token==request.token,self.matches(job) else{throw CancellationError()}
              guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else{throw FormError.invalid("CAD evidence capture did not produce pixels.")}
              let worker=Task.detached(priority:.userInitiated){()throws->Void in guard let data=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else{throw FormError.invalid("CAD review PNG encoding failed.")};try Self.writeExclusive(data,to:destination)}
              try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()});created.append(destination)
              result["path"]=destination.path;result["view"]=view;result["width"]=width;result["height"]=height;result["transparent"]=transparent
            case "export":
              let id=try CADLoopInput.id(raw["output_id"],label:"output_id"),destination=URL(fileURLWithPath:raw["path"] as! String),format=raw["format"] as? String ?? "step"
              guard let output=prepared.evaluation.outputs[id] else{throw FormError.missing("Choose an evaluated output.")}
              if format=="step"{try await evaluator.kernel.writeSTEP(output,to:destination)}else{try await evaluator.kernel.writeBRep(output,to:destination)}
              created.append(destination);result["path"]=destination.path;result["format"]=format;result["output_id"]=id.uuidString
            default:break
            }
            try Task.checkCancellation();guard job.token==request.token,self.matches(job) else{throw CancellationError()}
            result["state"]="complete"
          }catch is CancellationError{throw CancellationError()}
          catch{result["state"]="failed";result["diagnostic"]=self.diagnostic(error,job:job,category:"evidence");result["error"]=error.localizedDescription}
          result["elapsed_ms"]=(ProcessInfo.processInfo.systemUptime-itemStart)*1000;request.results.append(result)
        }
        request.state=request.results.contains(where:{$0["state"] as? String=="failed"}) ? "failed":"complete"
        if legacy,let result=request.results.first{job.result=result.merging(["pending":false,"request_id":request.id.uuidString]){_,new in new}}
      }catch {
        request.state="cancelled";request.issue=error.localizedDescription
        let files=created;Task.detached(priority:.utility){for file in files{try? FileManager.default.removeItem(at:file)}}
        if legacy,job.token==request.token{job.result=["pending":false,"request_id":request.id.uuidString,"error":error.localizedDescription]}
      }
      request.elapsedMS=(ProcessInfo.processInfo.systemUptime-started)*1000
    }
    return request
  }
}

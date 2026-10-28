import AppKit
import FormCore
import FormGraphics

struct CollectionPlanning {
  var source:CollectionSource
  var report:CollectionPreflight
}
extension StudioStore {
  func collectionDefinition(_ args:[String:Any])throws->CollectionProductionPlan {
    guard let project else{throw FormError.missing("Open a project for collection production.")}
    if let raw=args["definition"] {
      guard let value=raw as? [String:Any] else{throw FormError.invalid("Provide a complete collection plan definition.")}
      guard Set(value.keys).isSubset(of:["id","name","runs","rules","extras","layouts","processes","notes"]) else{throw FormError.invalid("Unknown collection plan property; use the documented original field names.")}
      let childKeys:[String:Set<String>]=[
        "runs":["id","objectID","garmentBlockID","sizeID","quantity","includeAttachments"],
        "rules":["rowID","costBasis","costSourceRowID","quantity","unit","unitPrice","currency","stock","excludedReason","notes"],
        "extras":["id","name","runID","quantity","unit","unitPrice","currency","supplier","sku","notes"],
        "layouts":["runID","objectID"],"processes":["jobID","kind"]]
      for(key,allowed)in childKeys {if let raw=value[key] {guard let children=raw as? [[String:Any]],children.allSatisfy({Set($0.keys).isSubset(of:allowed)}) else{throw FormError.invalid("Unknown or invalid collection "+key+" record fields.")}}}
      var plan=try JSONDecoder.form.decode(CollectionProductionPlan.self,from:JSONSerialization.data(withJSONObject:value))
      if let raw=args["plan_id"] {guard let text=raw as? String,let id=UUID(uuidString:text),value["id"].map({($0 as? String).flatMap(UUID.init(uuidString:))==id}) ?? true else{throw FormError.invalid("plan_id must be a valid UUID matching the supplied definition identity.")};plan.id=id}
      try plan.validate();return plan
    }
    guard let raw=args["plan_id"] as? String,let id=UUID(uuidString:raw),let plan=project.collectionProduction?.plans.first(where:{$0.id==id}) else{throw FormError.missing("Choose an existing plan_id or explicit definition.")};return plan
  }
  func collectionPlanning(_ args:[String:Any])throws->CollectionPlanning {
    guard let project else{throw FormError.missing("Open a project first.")}
    let plan=try collectionDefinition(args),source=try CollectionSource(project:project,plan:plan),scope=try CollectionQuantities.scope(plan,project:project)
    let originalAssets=try collectionOriginalAssetMetadata(source)
    var processRows:[CollectionLine]=[]
    // Count source archive bytes before decoding any process payloads.
    var metadataBytes=try source.data().count+originalAssets.reduce(0){$0+$1.bytes}
    guard metadataBytes<=CollectionLimits.totalBytes else{throw FormError.invalid("Original source/assets exceed the aggregate process budget before reads.")}
    for binding in plan.processes {
      if binding.kind=="embroidery" {
        guard let job=project.productionJobs?.first(where:{$0.id==binding.jobID}) else{throw FormError.missing("A selected archived embroidery job is missing.")}
        for (hash,kind) in [(job.programDigest,"program"),(job.revisionDigest,"revision")] {
          let url=ProductionAssets.folder(repository:repository,projectID:project.id).appendingPathComponent(hash+"."+kind+".json"),info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
          guard ProductionJob.validDigest(hash),info.isRegularFile==true,info.isSymbolicLink != true,let bytes=info.fileSize,(1...CollectionLimits.fileBytes).contains(bytes),metadataBytes<=CollectionLimits.totalBytes-bytes else{throw FormError.invalid("Process source archives exceed the aggregate read budget or are invalid.")};metadataBytes+=bytes
        }
      } else {
        guard let job=project.decorationPreparations?.first(where:{$0.id==binding.jobID}) else{throw FormError.missing("A selected archived decoration job is missing.")}
        let url=try DecorationPacketAssets.url(job.revisionDigest,repository:repository,projectID:project.id),info=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
        guard info.isRegularFile==true,info.isSymbolicLink != true,let bytes=info.fileSize,(1...CollectionLimits.fileBytes).contains(bytes),metadataBytes<=CollectionLimits.totalBytes-bytes else{throw FormError.invalid("Decoration specifications exceed the aggregate process budget.")};metadataBytes+=bytes
      }
    }
    for binding in plan.processes {
      if binding.kind=="embroidery" {
        let job=project.productionJobs!.first{$0.id==binding.jobID}!,revision=try productionRevision(job:job),program=try productionProgram(job:job)
        guard revision.object.textile?.embroidery==program.design,revision.usage==ThreadNeedleUsage.measure(program),revision.threadSequence==program.threadOrder else{throw FormError.invalid("Archived program/specification disagree; live source was not substituted.")}
        let quantity=scope.occurrences.filter{$0.objectID==job.objectID}.reduce(0){$0+$1.quantity}
        var contribution=try CollectionEstimate.embroideryLines(job:job,revision:revision,expectedQuantity:quantity)
        if let occurrence=scope.occurrences.first(where:{$0.objectID==job.objectID}),scope.lines.first(where:{$0.id==occurrence.id})?.costBasis == .purchased {
          for i in contribution.indices where ["thread","labor"].contains(contribution[i].role) {contribution[i].excludedReason="Complete component is purchased; manufacturing files/figures are reference only, without a second cost/stock charge.";contribution[i].requiredCost=false}
        }
        processRows += contribution
      } else {
        let job=project.decorationPreparations!.first{$0.id==binding.jobID}!,revision=try decorationRevision(job)
        let payload=revision.files.reduce(0){$0+$1.bytes}
        guard metadataBytes<=CollectionLimits.totalBytes-payload else{throw FormError.invalid("Decoration payload descriptors exceed aggregate source/process caps before file reads.")};metadataBytes+=payload
        let quantity=scope.occurrences.filter{$0.objectID==job.objectID}.reduce(0){$0+$1.quantity}
        guard quantity==job.quantity,quantity==revision.quantity else{throw FormError.invalid("Archived transfer quantity differs from its exact collection occurrences; it was not multiplied again.")}
        processRows.append(.init(id:"process/"+job.id.uuidString+"/transfer",name:job.name+" / transfer allocation",role:"consumable",unit:.m2,quantity:nil,evidence:.unknown,formula:"Archived delivery \(job.width)×\(job.height)mm, \(quantity) transfers. Declare charged sheet/film allocation; geometry is not ink/powder/white-channel consumption."))
      }
    }
    return .init(source:source,report:try CollectionEstimate.evaluate(plan,scope:scope,processRows:processRows))
  }
  func preflightCollectionHandoff(_ name:String,_ args:[String:Any])throws {
    if name=="form_batch",let operations=args["operations"] as? [[String:Any]],operations.contains(where:{op in op["name"] as? String=="form_production_job" && (op["arguments"] as? [String:Any])?["kind"] as? String=="collection"}) {throw FormError.invalid("Save one complete collection definition atomically. Collection capture/stock/file operations do not run inside object batches.")}
    guard name=="form_production_job",args["kind"] as? String=="collection" else{return}
    let command=args["command"] as? String ?? "list"
    if ["save_plan","create"].contains(command) {
      guard artworkSession.canvas?.hasMarkedTextInput != true else{throw FormError.invalid("Finish the marked text input before changing collection records.")}
      let input=try collectionPlanning(args)
      if command=="create" {
        guard project?.collectionProduction?.plans.contains(where:{$0==input.source.plan})==true else{throw FormError.invalid("Save the exact reviewed plan before capture.")}
        if let raw=args["supersedes_job_id"] {guard let text=raw as? String,let id=UUID(uuidString:text),project?.collectionProduction?.captures.contains(where:{$0.id==id && $0.planID==input.source.plan.id})==true else{throw FormError.invalid("Collection lineage must refer to a capture for this same plan.")}}
      }
    } else if ["remove_plan","remove"].contains(command) {
      guard let project else{throw FormError.missing("Open a project first.")}
      let key=command=="remove" ? "job_id":"plan_id"
      guard let raw=args[key] as? String,let id=UUID(uuidString:raw),command=="remove" ? project.collectionProduction?.captures.contains(where:{$0.id==id})==true:project.collectionProduction?.plans.contains(where:{$0.id==id})==true else{throw FormError.missing("Collection reference not found.")}
      if command=="remove",let raw=args["job_id"] as? String,let id=UUID(uuidString:raw),project.collectionProduction?.captures.contains(where:{$0.supersedesID==id})==true {throw FormError.invalid("Keep a collection capture referenced by later lineage.")}
    } else if !["list","get","preflight","export"].contains(command) {throw FormError.invalid("Unsupported collection command.")}
  }
  func collectionNativeMutation(_ args:[String:Any])throws->Any {
    try preflightCollectionHandoff("form_production_job",args);finishArtworkEditing();return try collectionCall(args,source:"Studio")
  }
  func collectionCall(_ args:[String:Any],source:String="Codex")throws->Any {
    guard let project else{throw FormError.missing("Open a project for collection production.")}
    let command=args["command"] as? String ?? "list"
    if command=="list" {return ["kind":"collection","plans":try jsonObject(project.collectionProduction?.plans ?? []),"jobs":try jsonObject(project.collectionProduction?.captures ?? [])]}
    if command=="preflight" || command=="save_plan" || command=="create" {
      let input=try collectionPlanning(args)
      if command=="preflight" {return ["kind":"collection","plan":try jsonObject(input.source.plan),"preflight":try jsonObject(input.report),"inventory_deducted":false,"machine_contacted":false]}
      if command=="create" {
        guard project.collectionProduction?.plans.contains(where:{$0.id==input.source.plan.id && $0==input.source.plan})==true else{throw FormError.invalid("Save the reviewed plan before capturing its immutable revision.")}
        return try captureCollection(input,args:args,source:source)
      }
      try engine.edit("Saved collection production plan",source:source){p in
        var value=p.collectionProduction ?? .init();if let i=value.plans.firstIndex(where:{$0.id==input.source.plan.id}) {value.plans[i]=input.source.plan}else{value.plans.append(input.source.plan)};try value.validate();p.collectionProduction=value
      };metadataRecordsChanged();return ["kind":"collection","plan":try jsonObject(input.source.plan),"preflight":try jsonObject(input.report)]
    }
    if command=="remove_plan" {
      guard let raw=args["plan_id"] as? String,let id=UUID(uuidString:raw),project.collectionProduction?.plans.contains(where:{$0.id==id})==true else{throw FormError.missing("Collection plan not found.")}
      try engine.edit("Removed collection plan",source:source){p in p.collectionProduction?.plans.removeAll{$0.id==id}};metadataRecordsChanged();return ["removed":true,"captures_preserved":true]
    }
    guard let raw=args["job_id"] as? String,let id=UUID(uuidString:raw),let job=project.collectionProduction?.captures.first(where:{$0.id==id}) else{throw FormError.missing("Choose an archived collection job_id.")}
    if command=="remove" {
      guard project.collectionProduction?.captures.contains(where:{$0.supersedesID==id}) != true else{throw FormError.invalid("Keep a capture referenced by later collection lineage.")}
      try engine.edit("Removed collection capture",source:source){p in p.collectionProduction?.captures.removeAll{$0.id==id}};metadataRecordsChanged();return ["removed":true,"immutable_assets_preserved":true]
    }
    let loaded=try collectionArchive(job)
    if command=="export" {return try exportCollection(job,loaded:loaded,args:args)}
    guard command=="get" else{throw FormError.invalid("Collection commands: list, save_plan, remove_plan, preflight, create, get, remove, export.")}
    let comparison=collectionCurrentState(loaded.revision,sourceDigest:job.sourceDigest)
    var result:[String:Any]=["kind":"collection","job":try jsonObject(job),"revision":try jsonObject(loaded.revision),"current_source":comparison.source,"current_plan":comparison.plan,"machine_contacted":false,"inventory_deducted":false]
    if args["include_source"] as? Bool==true,let file=loaded.revision.artifacts.first(where:{$0.name=="Source.json"}) {guard file.bytes<=1_000_000 else{throw FormError.invalid("Export the packet to inspect source above1 MB.")};result["source"]=try JSONSerialization.jsonObject(with:CollectionPacketAssets.read(file.digest,repository:repository,projectID:project.id,expected:file.bytes))}
    return result
  }
  func collectionCurrentState(_ revision:CollectionRevision,sourceDigest:String)->(source:String,plan:String) {
    guard let project else{return("missing","missing")}
    let live=project.collectionProduction?.plans.first{$0.id==revision.plan.id},plan=live.map{$0==revision.plan ? "matches":"changed"} ?? "missing"
    let missing=revision.plan.runs.contains{r in r.objectID.map{id in !project.objects.contains{$0.id==id}} ?? !(project.garmentBlocks?.contains{$0.id==r.garmentBlockID} ?? false)}
    if missing {return("missing",plan)}
    guard let data=try? CollectionSource(project:project,plan:revision.plan).data() else{return("unavailable",plan)}
    return(CollectionSource.digest(data)==sourceDigest ? "matches":"changed",plan)
  }

}

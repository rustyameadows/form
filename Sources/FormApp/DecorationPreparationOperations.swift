import AppKit
import FormCore
import FormGraphics

extension StudioStore {
  func decorationPlanning(_ args:[String:Any])throws -> (plan:DecorationGeometry,name:String,quantity:Int,notes:String?) {
    guard artworkSession.canvas?.hasMarkedTextInput != true else{throw FormError.invalid("Finish the current text input before reviewing or capturing physical decoration output.")}
    guard let project,let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),let object=project.objects.first(where:{$0.id==id}),
      let rawOptions=args["preparation"] as? [String:Any] else{throw FormError.invalid("Choose an artwork object and explicit preparation options including process htv or dtf.")}
    let options=try JSONDecoder.form.decode(DecorationPreparationOptions.self,from:JSONSerialization.data(withJSONObject:rawOptions));try options.validate()
    let quantity:Int
    if let value=args["quantity"] {
      guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite,number.doubleValue==number.doubleValue.rounded(),(1...100000).contains(number.intValue) else{throw FormError.invalid("Use an integer decoration quantity from 1 to 100,000.")};quantity=number.intValue
    }else{quantity=1}
    let name=(args["name"] as? String ?? object.name+" / "+options.process.rawValue.uppercased()).trimmingCharacters(in:.whitespacesAndNewlines),notes=args["notes"] as? String
    guard !name.isEmpty,name.count<=160,(notes?.count ?? 0)<=4000 else{throw FormError.invalid("Use a preparation name up to 160 characters and optional notes up to 4,000 characters.")}
    let plan=try DecorationGeometry(project:project,objectID:id,options:options,assets:repository.url(for:project.id).appendingPathComponent("Assets"))
    return(plan,name,quantity,notes)
  }
  func preflightDecorationHandoff(_ name:String,_ args:[String:Any]) throws {
    guard name=="form_production_job",let raw=args["kind"] else{return}
    guard let kind=raw as? String,["embroidery","decoration","collection"].contains(kind) else{throw FormError.invalid("Production job kind must be embroidery, decoration or collection.")}
    guard kind=="decoration",artworkSession.editingText else{return}
    let command=args["command"] as? String ?? "list"
    if command=="remove" {
      guard let raw=args["job_id"] as? String,let id=UUID(uuidString:raw),project?.decorationPreparations?.contains(where:{$0.id==id})==true else{throw FormError.missing("Choose an archived decoration job_id.")};return
    }
    guard command=="create" else{throw FormError.invalid("Decoration jobs support list, preflight, create, get, remove and export.")}
    let value=try decorationPlanning(args)
    guard value.plan.canExport else{throw FormError.invalid(value.plan.issues.filter{$0.severity=="error"}.map(\.message).joined(separator:"\n"))}
  }
  func decorationCall(_ args:[String:Any],source:String="Codex") throws -> Any {
    guard let project else{throw FormError.missing("Open a project for decoration preparation.")}
    let command=args["command"] as? String ?? "list"
    if command=="list" {return ["kind":"decoration","jobs":try jsonObject(project.decorationPreparations ?? [])]}
    if command=="preflight" || command=="create" {
      let input=try decorationPlanning(args)
      if command=="preflight" {var report=input.plan.report;report["name"]=input.name;report["quantity"]=input.quantity;return report}
      return try captureDecoration(input.plan,name:input.name,quantity:input.quantity,notes:input.notes,source:source)
    }
    guard let raw=args["job_id"] as? String,let id=UUID(uuidString:raw),let job=project.decorationPreparations?.first(where:{$0.id==id}) else{throw FormError.missing("Choose an archived decoration job_id.")}
    if command=="remove" {
      try engine.edit("Removed decoration preparation",source:source){p in p.decorationPreparations?.removeAll{$0.id==id}}
      changed();return ["removed":true,"immutable_assets_preserved":true]
    }
    let revision=try decorationRevision(job)
    if command=="export" {return try exportDecorationPacket(job,revision:revision,arguments:args)}
    guard command=="get" else{throw FormError.invalid("Decoration jobs support list, preflight, create, get, remove and export. Existing embroidery commands keep their default kind.")}
    var result:[String:Any]=["kind":"decoration","job":try jsonObject(job),"revision":try jsonObject(revision),"current_source":"missing",
      "comparison_scope":"Original editable records; archived files never depend on the current font installation.","application_compatibility":"unverified","machine_contacted":false]
    if project.objects.contains(where:{$0.id==job.objectID}) {
      if let current=try? project.decorationSourceSnapshot(objectID:job.objectID),let data=try? JSONEncoder.form.encode(current) {result["current_source"]=DecorationPacketAssets.digest(data)==job.sourceDigest ? "matches":"changed"}
      else {result["current_source"]="unavailable"}
    }
    if let value=args["include_source"] {
      guard let number=value as? NSNumber,CFGetTypeID(number)==CFBooleanGetTypeID() else{throw FormError.invalid("include_source must be a Boolean.")}
      if number.boolValue {
        let file=try sourceArtifact(revision),data=try DecorationPacketAssets.read(file.digest,repository:repository,projectID:project.id,expectedBytes:file.bytes)
        guard data.count<=1_000_000 else{throw FormError.invalid("Export the packet to inspect its source snapshot above 1 MB.")}
        result["source"]=try jsonObject(JSONDecoder.form.decode(DecorationSourceSnapshot.self,from:data))
      }
    }
    return result
  }
  private func sourceArtifact(_ revision:DecorationPreparationRevision)throws->DecorationArtifact {
    guard let file=revision.files.first(where:{$0.name=="Source.json" && $0.digest==revision.sourceDigest}) else{throw FormError.invalid("The immutable source record is missing.")};return file
  }
  func decorationRevision(_ job:DecorationPreparation)throws->DecorationPreparationRevision {
    guard let project else{throw FormError.missing("Open a project first.")}
    try job.validate()
    let data=try DecorationPacketAssets.read(job.revisionDigest,repository:repository,projectID:project.id),revision=try JSONDecoder.form.decode(DecorationPreparationRevision.self,from:data);try revision.validate()
    guard revision.jobID==job.id,revision.name==job.name,revision.createdAt==job.createdAt,revision.sourceDigest==job.sourceDigest,revision.objectID==job.objectID,
      revision.width==job.width,revision.height==job.height,revision.quantity==job.quantity,revision.options.process==job.process else{throw FormError.invalid("Decoration metadata differs from its immutable revision; source was not regenerated.")}
    let file=try sourceArtifact(revision),sourceData=try DecorationPacketAssets.read(file.digest,repository:repository,projectID:project.id,expectedBytes:file.bytes)
    let snapshot=try JSONDecoder.form.decode(DecorationSourceSnapshot.self,from:sourceData);try snapshot.validate()
    guard snapshot.objectID==job.objectID,snapshot.width==job.width,snapshot.height==job.height else{throw FormError.invalid("The archived source and physical preparation dimensions differ.")}
    return revision
  }
  func captureDecoration(_ plan:DecorationGeometry,name:String,quantity:Int,notes:String?,source:String="Studio") throws -> Any {
    guard let project,project.id==plan.source.projectID else{throw FormError.invalid("This preparation belongs to a different project. Refresh it from the current artwork.")}
    let current=try project.decorationSourceSnapshot(objectID:plan.source.objectID)
    guard try JSONEncoder.form.encode(current)==JSONEncoder.form.encode(plan.source) else{throw FormError.invalid("The editable source or target changed. Refresh this preparation before capturing it.")}
    let output=try DecorationOutput.generate(plan,project:project,assets:repository.url(for:project.id).appendingPathComponent("Assets"),specification:.init(name:name,quantity:quantity,notes:notes))
    let sourceData=try JSONEncoder.form.encode(plan.source),sourceDigest=DecorationPacketAssets.digest(sourceData)
    var files=output.files;files.append(.init(name:"Source.json",role:"source",mediaType:"application/json",data:sourceData))
    let knownBytes=files.reduce(0,{$0+$1.data.count})
    guard sourceData.count<=64_000_000,knownBytes<=128_000_000,files.count<=128 else{throw FormError.invalid("The generated files and source exceed the bounded decoration packet.")}
    files.append(contentsOf:try decorationOriginalAssets(plan.source,byteBudget:128_000_000-knownBytes,maximumFiles:128-files.count))
    let descriptors=files.map{DecorationArtifact(name:$0.name,role:$0.role,mediaType:$0.mediaType,digest:DecorationPacketAssets.digest($0.data),bytes:$0.data.count)}
    let revision=DecorationPreparationRevision(name:name,sourceDigest:sourceDigest,objectID:plan.source.objectID,width:plan.width,height:plan.height,options:plan.options,quantity:quantity,notes:notes,
      findings:plan.issues.filter{$0.severity=="warning"},files:descriptors);try revision.validate()
    let revisionData=try JSONEncoder.form.encode(revision),revisionDigest=DecorationPacketAssets.digest(revisionData)
    var job=DecorationPreparation(name:name,objectID:plan.source.objectID,process:plan.options.process,width:plan.width,height:plan.height,quantity:quantity,sourceDigest:sourceDigest,revisionDigest:revisionDigest)
    job.id=revision.jobID;job.createdAt=revision.createdAt;try job.validate()
    var packet=Dictionary(uniqueKeysWithValues:files.map{($0.name,$0.data)})
    packet["Revision.json"]=revisionData;packet["Job.json"]=try JSONEncoder.form.encode(job)
    _ = try decorationManifest(job,revision:revision,files:packet) // Exact final bound before any archive writes.
    for file in files {_ = try DecorationPacketAssets.store(file.data,repository:repository,projectID:project.id)}
    _ = try DecorationPacketAssets.store(revisionData,repository:repository,projectID:project.id)
    try engine.edit("Captured "+plan.options.process.rawValue.uppercased()+" decoration preparation",source:source) {p in
      var values=p.decorationPreparations ?? [];values.append(job);p.decorationPreparations=values
    };changed()
    return ["kind":"decoration","job":try jsonObject(job),"revision":try jsonObject(revision),"preflight":output.report,"source_unchanged":true,"machine_contacted":false,"inventory_deducted":false]
  }
  private func decorationOriginalAssets(_ source:DecorationSourceSnapshot,byteBudget:Int,maximumFiles:Int)throws->[DecorationOutputFile] {
    let art=source.objects.compactMap(\.artwork)+[source.artwork]
    let profiles=art.compactMap(\.outputColorProfile)+source.swatches.compactMap{$0.printInk?.profile}
    var values:[String:DecorationOutputFile]=[:],bytesRead=0
    func checkBudget(_ count:Int)throws {
      guard values.count<maximumFiles,count>0,count<=byteBudget-bytesRead else{throw FormError.invalid("Original assets exceed the remaining 128 MB decoration packet or file-count budget; split this source before capture.")}
    }
    let root=repository.url(for:source.projectID).appendingPathComponent("Assets")
    for reference in profiles {
      let name="Assets/"+reference.asset;if values[name] != nil {continue}
      let sourceURL=root.appendingPathComponent(reference.asset),info=try sourceURL.resourceValues(forKeys:[.fileSizeKey])
      guard let size=info.fileSize else{throw FormError.invalid("The original ICC asset size is unavailable.")};try checkBudget(size)
      let profile=try ICCOutputProfile(reference:reference,assets:root);try checkBudget(profile.data.count)
      values[name] = .init(name:name,role:"profile",mediaType:"application/vnd.iccprofile",data:profile.data);bytesRead+=profile.data.count
    }
    var names=Set<String>()
    for value in art {names.formUnion(Array(value.renderedAssetNames));names.formUnion(value.imports?.map(\.asset) ?? [])}
    let types=["png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg","gif":"image/gif","tif":"image/tiff","tiff":"image/tiff","heic":"image/heic","webp":"image/webp","svg":"image/svg+xml"]
    for asset in names.sorted() {
      let name="Assets/"+asset;if values[name] != nil {continue}
      let url=try repository.assetURL(asset,in:source.projectID),info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
      guard info.isRegularFile==true,info.isSymbolicLink != true,let bytes=info.fileSize,(1...64_000_000).contains(bytes) else{throw FormError.invalid("A captured original asset is missing, linked, empty or above 64 MB.")}
      try checkBudget(bytes)
      let data=try Data(contentsOf:url);guard data.count==bytes else{throw FormError.invalid("A source asset changed while preparing its immutable snapshot.")}
      values[name] = .init(name:name,role:"source",mediaType:types[url.pathExtension.lowercased()] ?? "application/octet-stream",data:data);bytesRead+=data.count
    }
    return values.keys.sorted().compactMap{values[$0]}
  }
}

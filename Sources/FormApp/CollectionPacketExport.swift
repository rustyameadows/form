import AppKit
import FormCore
import FormGraphics

struct CollectionOriginalAsset {var name:String,url:URL,bytes:Int,profile:ArtworkOutputProfile?}
struct CollectionArchive {
  var revision:CollectionRevision
  var revisionData:Data,manifestData:Data
  var files:[String:Data]
}
extension StudioStore {
  func collectionOriginalAssetMetadata(_ source:CollectionSource)throws->[CollectionOriginalAsset] {
    let project=source.project,arts=project.objects.compactMap(\.artwork),profiles=arts.compactMap(\.outputColorProfile)+(project.swatches ?? []).compactMap{$0.printInk?.profile}
    var byName:[String:ArtworkOutputProfile]=[:];for p in profiles {if let old=byName[p.asset],old.sha256 != p.sha256 {throw FormError.invalid("Original profiles have conflicting asset identities.")};byName[p.asset]=p}
    let names=Set(arts.flatMap{($0.elements.compactMap(\.asset))+($0.imports?.map(\.asset) ?? [])}).union(byName.keys)
    guard names.count<=CollectionLimits.files-12 else{throw FormError.invalid("Too many original assets before reading any source file.")}
    var result:[CollectionOriginalAsset]=[],total=0
    for name in names.sorted() {
      let url=try repository.assetURL(name,in:project.id),info=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
      guard info.isRegularFile==true,info.isSymbolicLink != true,let size=info.fileSize,(1...CollectionLimits.fileBytes).contains(size),total<=CollectionLimits.totalBytes-size else{throw FormError.invalid("Original asset sizes exceed the early collection read budget, or a file is invalid.")}
      total+=size;result.append(.init(name:"Sources/Assets/"+name,url:url,bytes:size,profile:byName[name]))
    }
    return result
  }
  func captureCollection(_ input:CollectionPlanning,args:[String:Any],source:String)throws->Any {
    guard let project,project.id==input.source.project.id,input.report.canCapture else{throw FormError.invalid("Refresh the collection review for the current project.")}
    let current=try CollectionSource(project:project,plan:input.source.plan).data(),sourceData=try input.source.data()
    guard current==sourceData else{throw FormError.invalid("Collection source changed before capture; refresh it.")}
    let originals=try collectionOriginalAssetMetadata(input.source)
    let sourceHash=CollectionSource.digest(sourceData)
    var files=CollectionFiles()
    try files.add("Source.json",sourceData,role:"source",provenance:"Original canonical project/source and portable declarations; camera/runtime/history excluded.")
    try files.add("Collection.json",JSONEncoder.form.encode(input.source.plan),role:"specification",provenance:"Exact reviewed collection plan.")
    try files.add("BOM.json",JSONEncoder.form.encode(input.report),role:"specification",provenance:"Resolved quantities, exact decimal inputs/results and explicit unknowns.")
    try files.add("BOM.csv",CollectionEstimate.csv(input.report),role:"reference",provenance:"Human text formula-neutralized; original text remains unchanged in JSON.")
    try files.add("Assumptions.json",JSONEncoder.form.encode(input.source.plan.rules),role:"specification",provenance:"Explicit portable row declarations; additional lines remain in Collection.json.")
    try files.add("Stock.json",JSONEncoder.form.encode(input.report.stock),role:"reference",provenance:"Captured shared-stock comparison only; not a reservation/deduction.")
    try files.add("Findings.json",JSONEncoder.form.encode(input.report.findings),role:"reference",provenance:"Explicit source/process limitations.")
    // Source asset totals are checked before report/physical output generation.
    let assetBytes=originals.reduce(0){$0+$1.bytes}
    var processFileCount=0
    for binding in input.source.plan.processes {
      if binding.kind=="embroidery" {
        guard let job=project.productionJobs?.first(where:{$0.id==binding.jobID}) else{throw FormError.missing("Missing embroidery archive.")}
        let r=try productionRevision(job:job);processFileCount+=3+(r.outputs.contains("dst") ? 2:0)+(r.outputs.contains("svg") ? 1:0)
      } else {
        guard let job=project.decorationPreparations?.first(where:{$0.id==binding.jobID}) else{throw FormError.missing("Missing decoration archive.")}
        processFileCount += try decorationRevision(job).files.count+1
      }
    }
    guard originals.count+files.data.count+processFileCount+input.source.plan.layouts.count*2+3<=CollectionLimits.files,files.bytes<=CollectionLimits.totalBytes-assetBytes else{throw FormError.invalid("Original source and required output envelope exceed collection caps before rendering.")}
    let review=try CollectionReviewPDF.data(source:input.source,report:input.report)
    try files.add("Review.pdf",review,role:"review",provenance:"Derived at collection capture; all subsequent exports copy these frozen review bytes.")
    for binding in input.source.plan.processes {
      let prefix="Processes/"+binding.jobID.uuidString+"/"
      if binding.kind=="decoration" {
        guard let job=project.decorationPreparations?.first(where:{$0.id==binding.jobID}) else{throw FormError.missing("Archived decoration reference is missing.")}
        let revisionData=try DecorationPacketAssets.read(job.revisionDigest,repository:repository,projectID:project.id),revision=try JSONDecoder.form.decode(DecorationPreparationRevision.self,from:revisionData);try revision.validate()
        let declared=revision.files.reduce(0){$0+$1.bytes}
        guard revision.files.count+files.data.count+originals.count+3<=CollectionLimits.files,files.bytes<=CollectionLimits.totalBytes-assetBytes-declared-revisionData.count else{throw FormError.invalid("Referenced decoration files exceed aggregate collection caps before payload reads.")}
        try files.add(prefix+"Revision.original.json",revisionData,role:"source",provenance:"Original38 revision bytes / SHA256 "+job.revisionDigest)
        for file in revision.files {
          let bytes=try DecorationPacketAssets.read(file.digest,repository:repository,projectID:project.id,expectedBytes:file.bytes)
          try files.add(prefix+file.name,bytes,role:file.role=="delivery" ? "delivery":"source",provenance:"Copied byte-for-byte from38 archive / "+file.digest)
        }
      } else {
        guard let job=project.productionJobs?.first(where:{$0.id==binding.jobID}) else{throw FormError.missing("Archived embroidery reference is missing.")}
        let originalProgram=try ProductionAssets.read(job.programDigest,kind:"program",repository:repository,projectID:project.id),originalRevision=try ProductionAssets.read(job.revisionDigest,kind:"revision",repository:repository,projectID:project.id)
        let revision=try productionRevision(job:job),program=try productionProgram(job:job)
        guard revision.usage==ThreadNeedleUsage.measure(program),revision.object.textile?.embroidery==program.design else{throw FormError.invalid("Verified legacy archive specification/program differ.")}
        guard program.commands.count<=100000,job.records.reduce(0,{$0+$1.notes.utf8.count})<=20000 else{throw FormError.invalid("Legacy reference output exceeds the early collection command/history rendering bound; split this process.")}
        try files.add(prefix+"Program.original.json",originalProgram,role:"source",provenance:"Original29 program bytes / "+job.programDigest)
        try files.add(prefix+"Revision.original.json",originalRevision,role:"source",provenance:"Original29 revision bytes / "+job.revisionDigest)
        let derived="Derived once at collection capture from verified29 program "+job.programDigest+" and revision "+job.revisionDigest+"; not original29 delivery bytes. No live source/digitizing."
        if revision.outputs.contains("dst") {
          let needle=try EmbroideryDST.data(program)
          try files.add(prefix+"Needle.derived.dst",needle,role:"delivery",provenance:derived)
          let sequence=program.threadOrder.enumerated().map{order,index -> [String:Any] in
            let thread=program.design.threads[index]
            var item:[String:Any]=["order":order,"thread_index":index,"name":thread.name,"color":thread.color]
            if let brand=thread.stock?.brand ?? thread.brand {item["brand"]=brand}
            if let sku=thread.stock?.sku ?? thread.catalog {item["catalog"]=sku}
            if let stock=thread.stock {item["stock_snapshot"]=try? jsonObject(stock)}
            return item
          }
          let sidecar=try JSONSerialization.data(withJSONObject:["source_digest":program.sourceDigest,"bounds_mm":["x":program.bounds.x,"y":program.bounds.y,"width":program.bounds.width,"height":program.bounds.height],"source_program_digest":job.programDigest,"source_revision_digest":job.revisionDigest,"dst_sha256":CollectionSource.digest(needle),"thread_sequence":sequence,"coordinate_unit_mm":0.1,"quantity":job.quantity,"hoop_width_mm":program.design.hoopWidth,"hoop_height_mm":program.design.hoopHeight,"verified_sew_out":false],options:[.prettyPrinted,.sortedKeys])
          try files.add(prefix+"Needle.derived.threads.json",sidecar,role:"specification",provenance:derived)
        }
        if revision.outputs.contains("svg") {try files.add(prefix+"Needle.derived.svg",Data(try EmbroideryRenderer.svg(program,showJumps:false).utf8),role:"delivery",provenance:derived)}
        try files.add(prefix+"Review.derived.pdf",ProductionPacketPDF.data(job:job,revision:revision,program:program),role:"reference",provenance:derived)
      }
    }
    for allocation in input.source.plan.layouts {
      guard let owner=project.objects.first(where:{$0.id==allocation.objectID}),let art=owner.artwork,let layout=art.sewingLayout else{throw FormError.invalid("Actual cutting layout disappeared before capture.")}
      let drawing=try SewingLayoutOutput(layout:layout,source:art),prefix="Patterns/"+allocation.runID.uuidString+"/"+layout.id.uuidString
      let assets=repository.url(for:project.id).appendingPathComponent("Assets")
      try files.add(prefix+".svg",Data(try drawing.svg(assets:assets).utf8),role:"delivery",provenance:"Actual-size technical cutting layout only; no source artwork/ink flatten. Per-unit repeated allocation.")
      try files.add(prefix+".pdf",drawing.pdf(assets:assets),role:"delivery",provenance:"Actual-size physical cutting document; no source artwork/ink flatten. Print calibration independently.")
    }
    guard files.bytes<=CollectionLimits.totalBytes-assetBytes,files.data.count+originals.count+2<=CollectionLimits.files else{throw FormError.invalid("Generated outputs leave insufficient budget for original assets.")}
    for original in originals {
      try files.reserve(original.bytes)
      let data=try Data(contentsOf:original.url);guard data.count==original.bytes else{throw FormError.invalid("An original asset changed during collection capture.")}
      if let profile=original.profile {guard CollectionSource.digest(data)==profile.sha256 else{throw FormError.invalid("Original profile bytes differ from their portable identity.")}}
      try files.add(original.name,data,role:"source",provenance:"Exact original source asset; no conversion/replacement.")
    }
    let revision=CollectionRevision(plan:input.source.plan,sourceDigest:sourceHash,report:input.report,artifacts:files.descriptors.sorted{$0.name<$1.name});try revision.validate()
    let revisionData=try JSONEncoder.form.encode(revision),revisionHash=CollectionSource.digest(revisionData)
    var job=CollectionCapture(plan:input.source.plan,sourceDigest:sourceHash,revisionDigest:revisionHash,manifestDigest:String(repeating:"0",count:64))
    if let raw=args["supersedes_job_id"] {
      guard let raw=raw as? String,let id=UUID(uuidString:raw),project.collectionProduction?.captures.contains(where:{$0.id==id && $0.planID==job.planID})==true else{throw FormError.invalid("Collection lineage must reference an existing capture for this same plan.")};job.supersedesID=id
    }
    var entries=Dictionary(uniqueKeysWithValues:revision.artifacts.map{($0.name,["sha256":$0.digest,"bytes":$0.bytes,"role":$0.role,"provenance":$0.provenance] as [String:Any])})
    entries["Revision.json"]=["sha256":revisionHash,"bytes":revisionData.count,"role":"specification","provenance":"Frozen collection revision."]
    let manifest=try JSONSerialization.data(withJSONObject:["packet_version":1,"schema":45,"capture_id":job.id.uuidString,"plan_id":job.planID.uuidString,"source_digest":sourceHash,"revision_digest":revisionHash,"files":entries,"inventory_deducted":false,"machine_contacted":false,"physical_production_verified":false],options:[.prettyPrinted,.sortedKeys])
    job.manifestDigest=CollectionSource.digest(manifest);try job.validate()
    guard revisionData.count<=CollectionLimits.fileBytes,manifest.count<=CollectionLimits.fileBytes,files.bytes+revisionData.count+manifest.count<=CollectionLimits.totalBytes else{throw FormError.invalid("Final immutable collection envelope exceeds128 MB; no references were published.")}
    // Last source-generation check before any persistent archive publication.
    guard let live=self.project,live.id==project.id,try CollectionSource(project:live,plan:input.source.plan).data()==sourceData else{throw FormError.invalid("Collection source changed while preparing outputs.")}
    for data in files.data.values {_ = try CollectionPacketAssets.store(data,repository:repository,projectID:project.id)}
    _ = try CollectionPacketAssets.store(revisionData,repository:repository,projectID:project.id);_ = try CollectionPacketAssets.store(manifest,repository:repository,projectID:project.id)
    try engine.edit("Captured collection technical packet",source:source){p in var value=p.collectionProduction ?? .init();value.captures.append(job);try value.validate();p.collectionProduction=value};metadataRecordsChanged()
    return ["kind":"collection","job":try jsonObject(job),"preflight":try jsonObject(input.report),"machine_contacted":false,"inventory_deducted":false]
  }
  func collectionArchive(_ job:CollectionCapture)throws->CollectionArchive {
    guard let project else{throw FormError.missing("Open a project first.")};try job.validate()
    let revisionData=try CollectionPacketAssets.read(job.revisionDigest,repository:repository,projectID:project.id),revision=try JSONDecoder.form.decode(CollectionRevision.self,from:revisionData);try revision.validate()
    guard revision.plan.id==job.planID,revision.sourceDigest==job.sourceDigest else{throw FormError.invalid("Collection capture identity differs from its immutable revision.")}
    let manifest=try CollectionPacketAssets.read(job.manifestDigest,repository:repository,projectID:project.id)
    guard let raw=try JSONSerialization.jsonObject(with:manifest) as? [String:Any],raw["capture_id"] as? String==job.id.uuidString,raw["revision_digest"] as? String==job.revisionDigest,let entries=raw["files"] as? [String:[String:Any]],entries.count==revision.artifacts.count+1 else{throw FormError.invalid("Collection manifest identity differs from the captured reference.")}
    var total=revisionData.count+manifest.count
    for artifact in revision.artifacts {
      guard entries[artifact.name]?["sha256"] as? String==artifact.digest,(entries[artifact.name]?["bytes"] as? Int)==artifact.bytes,total<=CollectionLimits.totalBytes-artifact.bytes else{throw FormError.invalid("Collection manifest/file envelope differs or exceeds its cap.")};total+=artifact.bytes
      guard try CollectionPacketAssets.size(artifact.digest,repository:repository,projectID:project.id)==artifact.bytes else{throw FormError.invalid("Collection payload length differs before reading.")}
    }
    guard entries["Revision.json"]?["sha256"] as? String==job.revisionDigest,entries["Revision.json"]?["bytes"] as? Int==revisionData.count else{throw FormError.invalid("Frozen collection revision is absent from manifest.")}
    var files:[String:Data]=["Revision.json":revisionData,"Manifest.json":manifest]
    for artifact in revision.artifacts {files[artifact.name]=try CollectionPacketAssets.read(artifact.digest,repository:repository,projectID:project.id,expected:artifact.bytes)}
    return .init(revision:revision,revisionData:revisionData,manifestData:manifest,files:files)
  }
  func exportCollection(_ job:CollectionCapture,loaded:CollectionArchive,args:[String:Any])throws->Any {
    guard let project else{throw FormError.missing("Open a project first.")}
    guard args["format"].map({$0 is String}) ?? true,args["path"].map({$0 is String}) ?? true else{throw FormError.invalid("Collection format/path must be strings when provided.")}
    let format=args["format"] as? String ?? "zip";guard ["zip","folder"].contains(format) else{throw FormError.invalid("Collection packets export as zip or folder.")}
    let output:URL
    if let path=args["path"] as? String {guard path.hasPrefix("/") else{throw FormError.invalid("Choose an absolute collection output path.")};output=URL(fileURLWithPath:path)}else{let parent=repository.url(for:project.id).appendingPathComponent("Exports");try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true);output=parent.appendingPathComponent("Collection-"+job.id.uuidString+(format=="zip" ? ".zip":""))}
    let fm=FileManager.default;var directory:ObjCBool=false
    if fm.fileExists(atPath:output.path,isDirectory:&directory),format=="folder" || directory.boolValue {throw FormError.invalid("Choose a new folder or a ZIP file path; existing directories are preserved.")}
    let stage=output.deletingLastPathComponent().appendingPathComponent(".form-collection-"+UUID().uuidString,isDirectory:true),content=stage.appendingPathComponent("Collection",isDirectory:true)
    try fm.createDirectory(at:content,withIntermediateDirectories:true);defer{try? fm.removeItem(at:stage)}
    for name in loaded.files.keys.sorted() {let url=content.appendingPathComponent(name);try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try loaded.files[name]!.write(to:url,options:.atomic)}
    if format=="folder" {try fm.moveItem(at:content,to:output)}else{
      let archive=stage.appendingPathComponent("packet.zip"),process=Process(),errors=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");process.arguments=["-c","-k","--keepParent","--norsrc","--noextattr","--noqtn",content.path,archive.path];process.standardError=errors;process.standardOutput=FileHandle.nullDevice;try process.run();let message=errors.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();guard process.terminationStatus==0 else{throw FormError.invalid("Local collection packaging failed: "+String(decoding:message.prefix(1000),as:UTF8.self))}
      let info=try archive.resourceValues(forKeys:[.fileSizeKey]);guard let bytes=info.fileSize,bytes<=CollectionLimits.totalBytes else{throw FormError.invalid("Collection ZIP exceeds its bound; destination preserved.")};try Data(contentsOf:archive).write(to:output,options:.atomic)
    }
    return ["kind":"collection","path":output.path,"manifest_digest":job.manifestDigest,"revision_digest":job.revisionDigest,"source_digest":job.sourceDigest,"files":loaded.files.keys.sorted(),"inventory_deducted":false,"machine_contacted":false]
  }
}

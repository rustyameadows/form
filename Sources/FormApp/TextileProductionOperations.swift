import AppKit
import CryptoKit
import FormCore
import FormGraphics

@MainActor enum ProductionAssets {
  static func digest(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
  static func folder(repository:ProjectRepository,projectID:UUID)->URL {repository.url(for:projectID).appendingPathComponent("Production",isDirectory:true)}
  static func write(_ data:Data,kind:String,repository:ProjectRepository,projectID:UUID)throws -> String {
    guard data.count<=64_000_000 else {throw FormError.invalid("The immutable production asset exceeds 64 MB. Split this job's source.")}
    let hash=digest(data),directory=folder(repository:repository,projectID:projectID)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let url=directory.appendingPathComponent(hash+"."+kind+".json")
    if FileManager.default.fileExists(atPath:url.path) {
      guard digest(try Data(contentsOf:url))==hash else {throw FormError.invalid("An existing immutable production asset is corrupt; it was preserved for review.")}
    } else {try data.write(to:url,options:.atomic)}
    return hash
  }
  static func read(_ hash:String,kind:String,repository:ProjectRepository,projectID:UUID)throws -> Data {
    guard ProductionJob.validDigest(hash),["program","revision"].contains(kind) else {throw FormError.invalid("Invalid production asset identity.")}
    let url=folder(repository:repository,projectID:projectID).appendingPathComponent(hash+"."+kind+".json")
    let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
    guard (attributes[.size] as? Int ?? 0)<=64_000_000 else {throw FormError.invalid("Production asset exceeds its 64 MB read bound.")}
    let data=try Data(contentsOf:url)
    guard digest(data)==hash else {throw FormError.invalid("The archived production asset differs from its revision digest. It was not regenerated or overwritten.")}
    return data
  }
}
extension StudioStore {
  func productionCall(_ name:String,arguments:[String:Any],source:String = "Codex")throws -> Any {
    let command=arguments["command"] as? String ?? "list"
    func uuid(_ key:String)throws -> UUID {
      guard let string=arguments[key] as? String,let id=UUID(uuidString:string) else {throw FormError.invalid("Provide a valid \(key) UUID.")};return id
    }
    func decode<T:Decodable>(_ type:T.Type,_ raw:Any)throws -> T {try JSONDecoder.form.decode(type,from:JSONSerialization.data(withJSONObject:raw))}
    if name=="form_textile_stock" {
      var next=library,value=library.textileProduction ?? .init()
      switch command {
      case "list":return try jsonObject(value)
      case "save_thread":
        guard let raw=arguments["thread"] as? [String:Any] else {throw FormError.invalid("Provide a thread stock record.")}
        var thread=try decode(StudioThread.self,raw);thread.updatedAt=Date();try thread.validate()
        if let index=value.threads.firstIndex(where:{$0.id==thread.id}) {value.threads[index]=thread} else {value.threads.append(thread)}
        try value.validate();next.textileProduction=value;try next.save(to:repository.root);library=next;revision+=1
        return try jsonObject(thread)
      case "save_equipment":
        guard let raw=arguments["equipment"] as? [String:Any] else {throw FormError.invalid("Provide an embroidery equipment declaration.")}
        let equipment=try decode(EmbroideryEquipment.self,raw);try equipment.validate()
        if let index=value.equipment.firstIndex(where:{$0.id==equipment.id}) {value.equipment[index]=equipment} else {value.equipment.append(equipment)}
        try value.validate();next.textileProduction=value;try next.save(to:repository.root);library=next;revision+=1
        return try jsonObject(equipment)
      case "remove_thread","remove_equipment":
        let id=try uuid(command=="remove_thread" ? "stock_id":"equipment_id")
        if command=="remove_thread" {guard value.threads.contains(where:{$0.id==id}) else {throw FormError.missing("Thread stock not found.")};value.threads.removeAll {$0.id==id}}
        else {guard value.equipment.contains(where:{$0.id==id}) else {throw FormError.missing("Equipment declaration not found.")};value.equipment.removeAll {$0.id==id}}
        try value.validate();next.textileProduction=value;try next.save(to:repository.root);library=next;revision+=1
        return ["removed":true,"portable_assignments_preserved":true]
      case "assign_thread":
        let objectID=try uuid("object_id"),stockID=try uuid("stock_id")
        guard let thread=value.threads.first(where:{$0.id==stockID}),let n=arguments["thread_index"] as? NSNumber,
          CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue==n.doubleValue.rounded(),(0...31).contains(n.intValue) else {throw FormError.invalid("Choose existing stock and an integer thread_index.")}
        let index=n.intValue
        try engine.edit("Assigned portable thread stock",source:source) {p in
          guard let object=p.objects.firstIndex(where:{$0.id==objectID}),!p.objects[object].locked,var design=p.objects[object].textile?.embroidery,design.threads.indices.contains(index) else {throw FormError.invalid("Choose an unlocked configured decoration and an existing thread index.")}
          design.threads[index] = .init(stock:thread);try design.validate();p.objects[object].textile?.embroidery=design
        };changed()
        return ["object_id":objectID.uuidString,"thread_index":index,"stock":try jsonObject(thread)]
      default:throw FormError.invalid("Stock commands: list, save_thread, remove_thread, save_equipment, remove_equipment, assign_thread.")
      }
    }
    guard name=="form_production_job",let project else {throw FormError.missing("Open a project for production jobs.")}
    if command=="list" {return ["jobs":try jsonObject(project.productionJobs ?? [])]}
    if command=="create" {
      let objectID=try uuid("object_id")
      guard let object=project.objects.first(where:{$0.id==objectID}),let art=project.surfaceArtwork(object) else {throw FormError.missing("Choose a configured embroidery decoration.")}
      let quantity:Int
      if let raw=arguments["quantity"] {guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue==n.doubleValue.rounded(),(1...100000).contains(n.intValue) else {throw FormError.invalid("Use an integer quantity from 1 to 100,000.")};quantity=n.intValue} else {quantity=1}
      let outputs:[String]
      if let raw=arguments["outputs"] {guard let values=raw as? [String] else {throw FormError.invalid("Outputs must be an array of dst, svg, or json.")};outputs=values} else {outputs=["dst","svg","json"]}
      let assumptions=try arguments["assumptions"].map {try decode(ProductionAssumptions.self,$0)} ?? .init()
      let equipment:EmbroideryEquipment?
      if arguments["equipment_id"] != nil {
        let id=try uuid("equipment_id");guard let found=library.textileProduction?.equipment.first(where:{$0.id==id}) else {throw FormError.missing("Equipment declaration not found.")};equipment=found
      } else {equipment=nil}
      let supersedes=try arguments["supersedes_job_id"].map {_ in try uuid("supersedes_job_id")}
      if let supersedes {guard project.productionJobs?.contains(where:{$0.id==supersedes && $0.objectID==objectID})==true else {throw FormError.invalid("A prior revision must be a job for this same object.")}}
      let program=try EmbroideryDigitizer.generate(object:object,project:project)
      var snapshot=object;snapshot.artwork=art;snapshot.artworkSourceID=nil;snapshot.artworkFit=nil;snapshot.artwork?.imports=nil
      let programData=try JSONEncoder.form.encode(program),programHash=ProductionAssets.digest(programData)
      var immutable=ProductionJobRevision(object:snapshot,material:project.material(object.materialID).withoutFabricPattern,quantity:quantity,outputs:outputs,assumptions:assumptions,program:program,programDigest:programHash,equipment:equipment)
      if let garmentID=object.textile?.attachment?.garmentID,let garment=project.objects.first(where:{$0.id==garmentID}) {immutable.garment=garment;immutable.garmentMaterial=project.material(garment.materialID).withoutFabricPattern}
      try immutable.validate()
      let revisionData=try JSONEncoder.form.encode(immutable),revisionHash=ProductionAssets.digest(revisionData)
      var job=ProductionJob(name:arguments["name"] as? String ?? object.name+" / production",objectID:objectID,sourceDigest:program.sourceDigest,revisionDigest:revisionHash,programDigest:programHash,quantity:quantity);job.supersedesJobID=supersedes;try job.validate()
      var candidate=project
      if candidate.productionJobs==nil {candidate.productionJobs=[]};candidate.productionJobs!.append(job)
      try candidate.validateProductionJobs()
      // Publishing references is one undoable project edit. Immutable staged
      // assets may remain unreferenced after Undo, like existing object revisions.
      _ = try ProductionAssets.write(programData,kind:"program",repository:repository,projectID:project.id)
      _ = try ProductionAssets.write(revisionData,kind:"revision",repository:repository,projectID:project.id)
      try engine.edit("Captured production revision",source:source) {p in if p.productionJobs==nil {p.productionJobs=[]};p.productionJobs!.append(job)}
      changed();return ["job":try jsonObject(job),"revision":try jsonObject(immutable),"estimate":try jsonObject(ProductionCostEstimate.estimate(immutable))]
    }
    let id=try uuid("job_id")
    guard let job=project.productionJobs?.first(where:{$0.id==id}) else {throw FormError.missing("Production job not found.")}
    if command=="event" {
      guard var raw=arguments["record"] as? [String:Any] else {throw FormError.invalid("Provide a user-recorded sample, quality, status, or note record.")}
      if raw["sourceDigest"]==nil {raw["sourceDigest"]=job.sourceDigest}
      let record=try decode(ProductionRecord.self,raw);try record.validate(source:job.sourceDigest)
      try engine.edit("Recorded production \(record.kind.rawValue)",source:source) {p in
        guard let index=p.productionJobs?.firstIndex(where:{$0.id==id}) else {throw FormError.missing("Production job not found.")};p.productionJobs![index].records.append(record)
      };changed();return try jsonObject(engine.project!.productionJobs!.first {$0.id==id}!)
    }
    if command=="export" {return try exportProductionPacket(job:job,arguments:arguments)}
    if command=="get" {
      let archived=try productionRevision(job:job)
      let current:String
      if let object=project.objects.first(where:{$0.id==job.objectID}) {
        if let program=try? EmbroideryDigitizer.generate(object:object,project:project) {current=program.sourceDigest==job.sourceDigest ? "matches":"changed"} else {current="unavailable"}
      } else {current="missing"}
      return ["job":try jsonObject(job),"revision":try jsonObject(archived),"estimate":try jsonObject(ProductionCostEstimate.estimate(archived)),"current_source":current]
    }
    throw FormError.invalid("Job commands: list, create, get, event, export.")
  }
  func productionRevision(job:ProductionJob)throws -> ProductionJobRevision {
    guard let project else {throw FormError.missing("Open a project first.")}
    let data=try ProductionAssets.read(job.revisionDigest,kind:"revision",repository:repository,projectID:project.id)
    let value=try JSONDecoder.form.decode(ProductionJobRevision.self,from:data);try value.validate()
    guard value.sourceDigest==job.sourceDigest,value.programDigest==job.programDigest,value.object.id==job.objectID,value.quantity==job.quantity else {throw FormError.invalid("Production job metadata differs from its immutable revision.")};return value
  }
  func productionProgram(job:ProductionJob)throws -> EmbroideryProgram {
    guard let project else {throw FormError.missing("Open a project first.")}
    let data=try ProductionAssets.read(job.programDigest,kind:"program",repository:repository,projectID:project.id)
    let program=try JSONDecoder.form.decode(EmbroideryProgram.self,from:data);try program.validate()
    guard program.sourceDigest==job.sourceDigest else {throw FormError.invalid("Archived needle program belongs to a different source revision.")};return program
  }
}

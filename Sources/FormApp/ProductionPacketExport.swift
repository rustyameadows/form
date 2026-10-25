import AppKit
import FormCore
import FormGraphics

extension StudioStore {
  func exportProductionPacket(job:ProductionJob,arguments:[String:Any])throws -> Any {
    guard let project else {throw FormError.missing("Open a project first.")}
    let format=arguments["format"] as? String ?? "zip"
    guard ["zip","folder"].contains(format) else {throw FormError.invalid("Production packets export as zip or folder.")}
    let revision=try productionRevision(job:job),program=try productionProgram(job:job)
    guard revision.object.textile?.embroidery==program.design,revision.usage==ThreadNeedleUsage.measure(program),revision.threadSequence==program.threadOrder else {throw FormError.invalid("Archived program and production specification differ.")}
    let estimate=ProductionCostEstimate.estimate(revision)
    var files:[String:Data]=["Job.json":try JSONEncoder.form.encode(job),"Revision.json":try JSONEncoder.form.encode(revision),"Estimate.json":try JSONEncoder.form.encode(estimate),"Review.pdf":try ProductionPacketPDF.data(job:job,revision:revision,program:program)]
    if revision.outputs.contains("json") {files["Program.json"]=try JSONEncoder.form.encode(program)}
    if revision.outputs.contains("svg") {files["Needle.svg"]=Data(try EmbroideryRenderer.svg(program,showJumps:false).utf8)}
    if revision.outputs.contains("dst") {
      files["Needle.dst"]=try EmbroideryDST.data(program)
      let bounds=program.bounds
      let sequence:[[String:Any]]=program.threadOrder.enumerated().map {order,index in
        let thread=program.design.threads[index]
        var item:[String:Any]=["order":order,"thread_index":index,"name":thread.name,"color":thread.color]
        if let brand=thread.stock?.brand ?? thread.brand {item["brand"]=brand};if let sku=thread.stock?.sku ?? thread.catalog {item["catalog"]=sku}
        if let stock=thread.stock {item["stock_snapshot"]=try? jsonObject(stock)}
        return item
      }
      files["Needle.threads.json"]=try JSONSerialization.data(withJSONObject:["source_digest":program.sourceDigest,"revision_digest":job.revisionDigest,
        "job_id":job.id.uuidString,"thread_sequence":sequence,"hoop_width_mm":program.design.hoopWidth,"hoop_height_mm":program.design.hoopHeight,
        "bounds_mm":["x":bounds.x,"y":bounds.y,"width":bounds.width,"height":bounds.height],"coordinate_unit_mm":0.1,"verified_sew_out":false],options:[.prettyPrinted,.sortedKeys])
    }
    guard files.values.reduce(0,{$0+$1.count})<=128_000_000 else {throw FormError.invalid("This packet exceeds 128 MB. Select fewer reference outputs or split the source.")}
    let entries:[String:[String:Any]]=files.mapValues {["sha256":ProductionAssets.digest($0),"bytes":$0.count]}
    var manifest:[String:Any]=["application":"FORM","packet_version":1,"job_id":job.id.uuidString,"source_digest":job.sourceDigest,"revision_digest":job.revisionDigest,
      "program_digest":job.programDigest,"quantity":job.quantity,"user_record_count":job.records.count,"outputs":revision.outputs,"files":entries,
      "inventory_deducted":false,"machine_contacted":false,"automatically_verified_sew_out":false]
    let packetDigest=ProductionAssets.digest(try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys))
    manifest["packet_digest"]=packetDigest
    files["Manifest.json"]=try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys])
    let output:URL
    if let path=arguments["path"] as? String {
      guard path.hasPrefix("/") else {throw FormError.invalid("Packet path must be absolute.")};output=URL(fileURLWithPath:path)
    } else {
      let exports=repository.url(for:project.id).appendingPathComponent("Exports")
      try FileManager.default.createDirectory(at:exports,withIntermediateDirectories:true)
      output=exports.appendingPathComponent("Production-"+job.id.uuidString+"-"+String(packetDigest.prefix(10))+(format=="zip" ? ".zip":""))
    }
    let fm=FileManager.default,parent=output.deletingLastPathComponent()
    var directory:ObjCBool=false
    if fm.fileExists(atPath:output.path,isDirectory:&directory),format=="folder" || directory.boolValue {throw FormError.invalid("Choose a new packet folder or a ZIP file output path.")}
    let stage=parent.appendingPathComponent(".form-production-"+UUID().uuidString,isDirectory:true),content=stage.appendingPathComponent("Production",isDirectory:true)
    try fm.createDirectory(at:content,withIntermediateDirectories:true);defer {try? fm.removeItem(at:stage)}
    for name in files.keys.sorted() {try files[name]!.write(to:content.appendingPathComponent(name),options:.atomic)}
    if format=="folder" {try fm.moveItem(at:content,to:output)}
    else {
      let archive=stage.appendingPathComponent("packet.zip"),process=Process(),errors=Pipe()
      process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
      process.arguments=["-c","-k","--keepParent","--norsrc","--noextattr","--noqtn",content.path,archive.path];process.standardError=errors;process.standardOutput=FileHandle.nullDevice
      try process.run();let message=errors.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
      guard process.terminationStatus==0 else {throw FormError.invalid("Could not package local production files: "+String(decoding:message.prefix(2000),as:UTF8.self))}
      let size=(try fm.attributesOfItem(atPath:archive.path)[.size] as? Int) ?? 0
      guard size<=128_000_000 else {throw FormError.invalid("The packet archive exceeds 128 MB.")}
      try Data(contentsOf:archive).write(to:output,options:.atomic)
    }
    return ["path":output.path,"format":format,"packet_digest":packetDigest,"source_digest":job.sourceDigest,"revision_digest":job.revisionDigest,"files":entries,
      "equipment_compatibility":try jsonObject(revision.compatibility),"estimate":try jsonObject(estimate),"machine_contacted":false,"inventory_deducted":false] as [String:Any]
  }
}

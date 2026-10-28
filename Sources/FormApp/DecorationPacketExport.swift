import Foundation
import FormCore

extension StudioStore {
  func decorationManifest(_ job:DecorationPreparation,revision:DecorationPreparationRevision,files:[String:Data])throws -> (data:Data,digest:String) {
    guard files.count<=132,files.values.allSatisfy({!$0.isEmpty && $0.count<=64_000_000}) else{throw FormError.invalid("The decoration packet exceeds its file count or per-file bound.")}
    let entries=files.mapValues{["sha256":DecorationPacketAssets.digest($0),"bytes":$0.count] as [String:Any]}
    var value:[String:Any]=["application":"LAB","packet_version":1,"kind":"decoration","process":job.process.rawValue,"job_id":job.id.uuidString,
      "source_digest":job.sourceDigest,"revision_digest":job.revisionDigest,"quantity":job.quantity,"files":entries,
      "delivery_files":revision.files.filter{$0.role=="delivery"}.map(\.name),"reference_files":revision.files.filter{$0.role=="reference"}.map(\.name),
      "source_files":revision.files.filter{$0.role=="source" || $0.role=="profile"}.map(\.name),
      "white_channel_generated":false,"screening_generated":false,"thermal_recipe_generated":false,"equipment_compatibility":"unverified","machine_contacted":false,"inventory_deducted":false]
    let digest=DecorationPacketAssets.digest(try JSONSerialization.data(withJSONObject:value,options:.sortedKeys));value["packet_digest"]=digest
    let data=try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
    guard files.values.reduce(0,{$0+$1.count})+data.count<=128_000_000 else{throw FormError.invalid("The complete decoration packet exceeds 128 MB; split the source or reduce raster size.")}
    return(data,digest)
  }
  func exportDecorationPacket(_ job:DecorationPreparation,revision:DecorationPreparationRevision,arguments:[String:Any])throws -> Any {
    guard let project else{throw FormError.missing("Open a project first.")}
    let format=arguments["format"] as? String ?? "zip"
    guard ["zip","folder"].contains(format) else{throw FormError.invalid("Decoration packets export as a local ZIP or new folder.")}
    var files:[String:Data]=[:]
    for file in revision.files {files[file.name]=try DecorationPacketAssets.read(file.digest,repository:repository,projectID:project.id,expectedBytes:file.bytes)}
    files["Revision.json"]=try DecorationPacketAssets.read(job.revisionDigest,repository:repository,projectID:project.id)
    files["Job.json"]=try JSONEncoder.form.encode(job)
    let manifest=try decorationManifest(job,revision:revision,files:files);files["Manifest.json"]=manifest.data
    let output:URL
    if let path=arguments["path"] as? String {
      guard path.hasPrefix("/"),format != "zip" || URL(fileURLWithPath:path).pathExtension.lowercased()=="zip" else{throw FormError.invalid("Choose an absolute new folder or .zip file path.")};output=URL(fileURLWithPath:path)
    }else {
      let root=repository.url(for:project.id).appendingPathComponent("Exports");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
      output=root.appendingPathComponent("Decoration-"+job.id.uuidString+"-"+String(manifest.digest.prefix(10))+(format=="zip" ? ".zip":""))
    }
    let fm=FileManager.default,parent=output.deletingLastPathComponent();var directory:ObjCBool=false
    if fm.fileExists(atPath:output.path,isDirectory:&directory),format=="folder" || directory.boolValue {throw FormError.invalid("Choose a new decoration packet folder or a ZIP file destination.")}
    let stage=parent.appendingPathComponent(".form-decoration-"+UUID().uuidString,isDirectory:true),content=stage.appendingPathComponent("Decoration",isDirectory:true)
    try fm.createDirectory(at:content,withIntermediateDirectories:true);defer{try? fm.removeItem(at:stage)}
    for name in files.keys.sorted() {
      let target=content.appendingPathComponent(name)
      try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true);try files[name]!.write(to:target,options:.atomic)
    }
    if format=="folder" {try fm.moveItem(at:content,to:output)}
    else {
      let archive=stage.appendingPathComponent("packet.zip"),process=Process(),errors=Pipe()
      process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");process.arguments=["-c","-k","--keepParent","--norsrc","--noextattr","--noqtn",content.path,archive.path]
      process.standardError=errors;process.standardOutput=FileHandle.nullDevice
      try process.run();let message=errors.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
      guard process.terminationStatus==0 else{throw FormError.invalid("Could not package decoration files: "+String(decoding:message.prefix(2000),as:UTF8.self))}
      let size=(try fm.attributesOfItem(atPath:archive.path)[.size] as? Int) ?? 0
      guard size<=128_000_000 else{throw FormError.invalid("The compressed decoration packet exceeds 128 MB.")}
      try Data(contentsOf:archive).write(to:output,options:.atomic)
    }
    return ["path":output.path,"format":format,"kind":"decoration","job_id":job.id.uuidString,"packet_digest":manifest.digest,"source_digest":job.sourceDigest,
      "revision_digest":job.revisionDigest,"files":try jsonObject(revision.files),"machine_contacted":false,"inventory_deducted":false,"white_channel_generated":false]
  }
}

import CryptoKit
import Darwin
import Foundation
import FormCore

/// Portable identities of the actual runtime files, separate from the upstream
/// Cycles revision. No development path or process identifier is exported.
enum CyclesExportProvenance {
  struct Locations:Sendable {
    var executable:URL
    var helper:URL
    var build:URL?
    var engine:URL?
    var display:URL?
    init(executable:URL,helper:URL) {
      self.executable=executable;self.helper=helper
      func contents(_ executable:URL,directory:String)->URL? {
        let parent=executable.deletingLastPathComponent()
        return parent.lastPathComponent==directory && parent.deletingLastPathComponent().lastPathComponent=="Contents" ? parent.deletingLastPathComponent():nil
      }
      build=contents(executable,directory:"MacOS")?.appendingPathComponent("Resources/LABBuild.json")
      let renderer=contents(helper,directory:"Helpers")
      engine=renderer?.appendingPathComponent("Resources/ThirdPartyNotices/Cycles/LAB-CYCLES-PROVENANCE.json")
      display=renderer?.appendingPathComponent("Resources/Cycles/LAB-sRGB-v1.json")
    }
  }
  struct Limits:Sendable {
    var binaryBytes=1_073_741_824
    var metadataBytes=2_097_152
  }
  struct Capture:Sendable,Equatable {
    let data:Data
    let engineRevision:String?
    func record(engineRevision actual:String)throws->[String:Any] {
      guard engineRevision==nil || engineRevision==actual else {throw FormError.invalid("The rendered Cycles revision differs from its captured engine provenance.")}
      guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw FormError.invalid("Invalid captured rendering provenance.")}
      return value
    }
    func requireUnchanged(_ current:Self)throws {
      guard self==current else {throw FormError.invalid("The LAB executable, renderer or bundled metadata changed during rendering. No output was delivered.")}
    }
  }
  private struct File {
    let digest:String,size:Int,data:Data
    var identity:[String:Any] {["sha256":digest,"size_bytes":size]}
  }
  static func capture(_ locations:Locations,limits:Limits = .init())async throws->Capture {
    try Task.checkCancellation()
    let worker=Task.detached(priority:.utility){try read(locations,limits:limits)}
    let result=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
    try Task.checkCancellation();return result
  }
  private static func file(_ url:URL,maximum:Int,retain:Bool)throws->File {
    try Task.checkCancellation()
    let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
    var before=stat(),after=stat()
    guard fstat(handle.fileDescriptor,&before)==0,(before.st_mode & S_IFMT)==S_IFREG,
      before.st_size>=0,before.st_size<=maximum else {throw FormError.invalid("A rendering runtime file is not regular or exceeds its provenance size budget.")}
    var hash=SHA256(),data=Data(),count=0
    while true {
      try Task.checkCancellation()
      let block=try handle.read(upToCount:1_048_576) ?? Data()
      if block.isEmpty {break}
      count+=block.count
      guard count<=maximum else {throw FormError.invalid("A rendering runtime file exceeds its provenance size budget.")}
      hash.update(data:block);if retain {data.append(block)}
    }
    guard fstat(handle.fileDescriptor,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,
      before.st_size==after.st_size,count==after.st_size,
      before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec,before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec else {
      throw FormError.invalid("A rendering runtime file changed while its provenance was being read.")
    }
    return .init(digest:hash.finalize().map{String(format:"%02x",$0)}.joined(),size:count,data:data)
  }
  private static func optional(_ url:URL?,maximum:Int)throws->File? {
    guard let url else{return nil}
    do {return try file(url,maximum:maximum,retain:true)}catch {
      let value=error as NSError
      if value.domain==NSCocoaErrorDomain,[NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(value.code) {return nil}
      throw error
    }
  }
  private static func object(_ file:File)throws->[String:Any] {
    guard let result=try JSONSerialization.jsonObject(with:file.data) as? [String:Any] else {throw FormError.invalid("Bundled rendering provenance must be a JSON object.")}
    return result
  }
  private static func read(_ locations:Locations,limits:Limits)throws->Capture {
    guard (1...1_073_741_824).contains(limits.binaryBytes),(1...2_097_152).contains(limits.metadataBytes) else {throw FormError.invalid("Invalid rendering provenance size limits.")}
    let executable=try file(locations.executable,maximum:limits.binaryBytes,retain:false),helper=try file(locations.helper,maximum:limits.binaryBytes,retain:false)
    let build=try optional(locations.build,maximum:min(65_536,limits.metadataBytes)),engine=try optional(locations.engine,maximum:limits.metadataBytes),display=try optional(locations.display,maximum:min(65_536,limits.metadataBytes))
    let unavailable:[String:Any]=["status":"unavailable","reason":"metadata_not_present_in_runtime_layout"]
    var buildRecord=unavailable,engineRecord=unavailable,displayRecord=unavailable,revision:String?
    if let build {
      let value=try object(build)
      guard value["format_version"] as? Int==1,let id=value["build_id"] as? String,!id.isEmpty else {throw FormError.invalid("The packaged LAB build metadata is malformed.")}
      buildRecord=build.identity;buildRecord["status"]="available";buildRecord["metadata"]=value
    }
    if let engine {
      let value=try object(engine)
      guard let commit=value["source_commit"] as? String,!commit.isEmpty,let dependency=value["dependency_commit"] as? String,!dependency.isEmpty,
        value["display_transform"] as? String=="LAB-sRGB-v1",value["protocol_version"] as? Int==1 else {throw FormError.invalid("The bundled Cycles provenance is malformed or unsupported.")}
      revision=commit;engineRecord=engine.identity;engineRecord["status"]="available"
      engineRecord["source_commit"]=commit;engineRecord["dependency_commit"]=dependency;engineRecord["protocol_version"]=1
      guard let display,let sources=value["source_inputs"] as? [String:String],sources["Native/LabCycles/LAB-sRGB-v1.json"]==display.digest else {throw FormError.invalid("The bundled display transform does not match the engine provenance.")}
    }
    if let display {
      let value=try object(display)
      guard value["id"] as? String=="LAB-sRGB-v1",value["loadedByRenderer"] as? Bool==false else {throw FormError.invalid("The bundled display-transform description is malformed or unsupported.")}
      displayRecord=display.identity;displayRecord["status"]="available";displayRecord["id"]="LAB-sRGB-v1"
    }
    // A packaged application promises these resources. An unbundled test or
    // development executable still records exact binaries and explicit absence.
    if build != nil,engine==nil || display==nil {throw FormError.invalid("The packaged application is missing its rendering provenance resources.")}
    let value:[String:Any]=["version":1,"application":["executable":executable.identity,"packaged_build":buildRecord],
      "renderer":["helper":helper.identity,"engine_provenance":engineRecord,"display_transform":displayRecord]]
    return .init(data:try JSONSerialization.data(withJSONObject:value,options:.sortedKeys),engineRevision:revision)
  }
}

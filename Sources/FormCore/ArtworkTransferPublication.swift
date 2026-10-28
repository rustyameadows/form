import Darwin
import Foundation

public struct ArtworkTransferRetainedAsset:Codable,Equatable,Sendable {
  public var name:String,sha256:String
  public var bytes:Int
}
public struct ArtworkTransferPublicationFailure:LocalizedError,Sendable {
  public let message:String,retained:[ArtworkTransferRetainedAsset],changedPublishedPaths:[String],journal:String
  public var errorDescription:String? {
    message+(retained.isEmpty ? "":"\nUnreferenced recovery assets retained: "+retained.map{"\($0.name) (\($0.bytes) bytes)"}.joined(separator:", "))+(changedPublishedPaths.isEmpty ? "":"\nPublished paths changed externally and were not removed: "+changedPublishedPaths.joined(separator:", "))+"\nTransfer journal: \(journal)"
  }
}

/// Single-owner transaction. No published pathname is ever removed or replaced.
/// Journals are immutable, append-only records in a private retained directory.
public final class ArtworkTransferPublication:@unchecked Sendable {
  public let directory:URL,stageName:String
  private let journalPrefix:String
  private let assetsFD:Int32,stageFD:Int32
  private var entries=[String:Data](),stagedNames=[String](),record=0,finished=false
  private var terminalFailure:ArtworkTransferPublicationFailure?
  public private(set) var published=[ArtworkTransferRetainedAsset](),reused=[String]()
  public var journal:String {journalPrefix+"/"+stageName}
  private init(directory:URL,assetsFD:Int32,stageName:String,stageFD:Int32,journalPrefix:String) {self.journalPrefix=journalPrefix;self.directory=directory;self.assetsFD=assetsFD;self.stageName=stageName;self.stageFD=stageFD}
  deinit {close(stageFD);close(assetsFD)}
  private func descriptor(_ name:String)throws->Int32 {
    let fd=name.withCString{openat(stageFD,$0,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)}
    guard fd>=0 else{throw CocoaError(.fileWriteUnknown)};return fd
  }
  private func write(_ bytes:Data,to fd:Int32,cancellable:Bool=true)throws {
    try bytes.withUnsafeBytes { buffer in
      var offset=0
      while offset<buffer.count {
        if cancellable {try Task.checkCancellation()}
        let count=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
        if count<0,errno==EINTR {continue}
        guard count>0 else{throw CocoaError(.fileWriteUnknown)};offset+=count
      }
    }
    guard fsync(fd)==0 else{throw CocoaError(.fileWriteUnknown)}
  }
  private func log(_ phase:String,_ detail:String?=nil)throws {
    struct Event:Codable {var phase:String,detail:String?,published:[ArtworkTransferRetainedAsset],reused:[String]}
    let name=String(format:"journal-%03d.json",record);record+=1
    let fd=try descriptor(name);defer{close(fd)}
    try write(JSONEncoder.form.encode(Event(phase:phase,detail:detail,published:published,reused:reused)),to:fd,cancellable:false)
    guard fsync(stageFD)==0 else{throw CocoaError(.fileWriteUnknown)}
  }
  public static func prepare(directory:URL,blobs:[String:Data],limits:ArtworkTransferLimits = .init(),journalPrefix:String="Assets",
    beforeStage:((String)throws->Void)?=nil)throws->ArtworkTransferPublication {
    guard blobs.count<=limits.assets,blobs.values.reduce(0,{$0+$1.count})<=limits.totalAssetBytes,
      blobs.allSatisfy({ArtworkTransferBundle.safeName($0.key) && !$0.value.isEmpty && $0.value.count<=limits.individualAssetBytes}) else{throw FormError.invalid("Staging exceeds the portable asset budget.")}
    let fd=directory.path.withCString{open($0,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)}
    guard fd>=0 else{throw CocoaError(.fileWriteUnknown)}
    let name=".form-transfer-"+UUID().uuidString
    guard name.withCString({mkdirat(fd,$0,0o700)})==0 else{close(fd);throw CocoaError(.fileWriteUnknown)}
    let stage=name.withCString{openat(fd,$0,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)}
    guard stage>=0 else{close(fd);throw CocoaError(.fileWriteUnknown)}
    let transaction=ArtworkTransferPublication(directory:directory,assetsFD:fd,stageName:name,stageFD:stage,journalPrefix:journalPrefix)
    do {
      transaction.entries=blobs
      struct Intent:Codable {var files:[ArtworkTransferRetainedAsset]}
      let intent=blobs.keys.sorted().map{ArtworkTransferRetainedAsset(name:$0,sha256:ArtworkTransferBundle.digest(blobs[$0]!),bytes:blobs[$0]!.count)}
      let intentFD=try transaction.descriptor("intent.json");defer{close(intentFD)}
      try transaction.write(JSONEncoder.form.encode(Intent(files:intent)),to:intentFD)
      for asset in blobs.keys.sorted() {
        try Task.checkCancellation();try beforeStage?(asset)
        let file=try transaction.descriptor(asset);transaction.stagedNames.append(asset)
        do {try transaction.write(blobs[asset]!,to:file);close(file)}catch{close(file);throw error}
      }
      try transaction.log("prepared");return transaction
    }catch {transaction.finish("staging_failed",detail:error.localizedDescription);throw error}
  }
  private func verifyDirectory()throws {
    let current=directory.path.withCString{open($0,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)}
    guard current>=0 else{throw FormError.invalid("The destination asset directory changed.")};defer{close(current)}
    var expected=stat(),actual=stat()
    guard fstat(assetsFD,&expected)==0,fstat(current,&actual)==0,expected.st_ino==actual.st_ino,expected.st_dev==actual.st_dev else{throw FormError.invalid("The destination asset directory changed.")}
  }
  /// Call on the document's serial executor immediately before its single edit.
  public func publish(_ writes:[String:Data],reuseExisting:Bool=true,beforeEach:((String,Int)throws->Void)?=nil)throws {
    guard !finished else{throw FormError.invalid("This transfer publication is finished.")}
    do {
      try verifyDirectory()
      for (index,name) in writes.keys.sorted().enumerated() {
        guard let bytes=entries[name],bytes==writes[name] else{throw FormError.invalid("The replanned transfer requests an unstaged resource.")}
        try Task.checkCancellation();try beforeEach?(name,index);try verifyDirectory()
        guard try ArtworkTransferIO.readAsset(directoryDescriptor:stageFD,name:name,limit:bytes.count)==bytes else{throw FormError.invalid("An owned staged resource changed before publication.")}
        let result=name.withCString{source in name.withCString{target in linkat(stageFD,source,assetsFD,target,0)}}
        if result==0 {
          published.append(.init(name:name,sha256:ArtworkTransferBundle.digest(bytes),bytes:bytes.count));guard try ArtworkTransferIO.readAsset(directoryDescriptor:assetsFD,name:name,limit:bytes.count)==bytes else{throw FormError.invalid("A newly published resource changed before verification.")};try log("published",name)
        }else if errno==EEXIST {
          guard reuseExisting else{throw FormError.invalid("The export destination already exists; no file was replaced.")}
          guard try ArtworkTransferIO.readAsset(directoryDescriptor:assetsFD,name:name,limit:bytes.count)==bytes else{throw FormError.invalid("A destination asset appeared with different bytes: \(name).")}
          reused.append(name);try log("reused",name)
        }else {throw CocoaError(.fileWriteUnknown)}
      }
      try verifyDirectory();guard fsync(assetsFD)==0 else{throw CocoaError(.fileWriteUnknown)}
    }catch {throw failure(error)}
  }
  public func failure(_ error:Error)->ArtworkTransferPublicationFailure {
    if let terminalFailure {return terminalFailure}
    var retained=[ArtworkTransferRetainedAsset](),changed=[String]()
    for asset in published {
      if let expected=entries[asset.name],let current=try? ArtworkTransferIO.readAsset(directoryDescriptor:assetsFD,name:asset.name,limit:asset.bytes),current==expected {retained.append(asset)}else{changed.append(asset.name)}
    }
    finish("failed",detail:error.localizedDescription+" | verified retained: "+retained.map(\.name).joined(separator:", ")+" | externally changed: "+changed.joined(separator:", "))
    let result=ArtworkTransferPublicationFailure(message:error.localizedDescription,retained:retained,changedPublishedPaths:changed,journal:journal);terminalFailure=result;return result
  }
  /// Only private unpublished links are removed through the retained staging FD.
  /// Published names and the parent directory name are never unlinked.
  public func finish(_ phase:String,detail:String?=nil) {
    guard !finished else{return};finished=true
    try? log(phase,detail)
    for name in stagedNames {name.withCString{_ = unlinkat(stageFD,$0,0)}}
    stagedNames=[];entries=[:]
  }
}

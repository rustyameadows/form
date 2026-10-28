import CryptoKit
import Foundation
import FormCore

/// Immutable preparation files are separate from live project Assets. Source or
/// font changes cannot regenerate these bytes during export or archive reopen.
@MainActor enum DecorationPacketAssets {
  static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  static func folder(_ repository:ProjectRepository,_ projectID:UUID)->URL {repository.url(for:projectID).appendingPathComponent("Production/Decorations",isDirectory:true)}
  static func url(_ digest:String,repository:ProjectRepository,projectID:UUID)throws->URL {
    guard ProductionJob.validDigest(digest) else{throw FormError.invalid("Invalid immutable decoration digest.")}
    return folder(repository,projectID).appendingPathComponent(digest+".asset")
  }
  static func store(_ data:Data,repository:ProjectRepository,projectID:UUID)throws->String {
    guard !data.isEmpty,data.count<=64_000_000 else{throw FormError.invalid("A decoration archive file supports 1–64 MB. Split this preparation.")}
    let hash=digest(data),target=try url(hash,repository:repository,projectID:projectID)
    try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
    if FileManager.default.fileExists(atPath:target.path) {
      guard digest(try read(hash,repository:repository,projectID:projectID))==hash else{throw FormError.invalid("An existing immutable decoration file is corrupt; it was not overwritten.")}
    } else {try data.write(to:target,options:.atomic)}
    return hash
  }
  static func read(_ hash:String,repository:ProjectRepository,projectID:UUID,expectedBytes:Int?=nil)throws->Data {
    let target=try url(hash,repository:repository,projectID:projectID),values=try target.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
    guard values.isRegularFile==true,values.isSymbolicLink != true,let bytes=values.fileSize,(1...64_000_000).contains(bytes),expectedBytes.map({$0==bytes}) ?? true else{throw FormError.invalid("The archived decoration file type or bounded length is invalid.")}
    let data=try Data(contentsOf:target)
    guard data.count==bytes,digest(data)==hash else{throw FormError.invalid("An archived decoration file differs from its immutable digest; current source was not substituted.")}
    return data
  }
}

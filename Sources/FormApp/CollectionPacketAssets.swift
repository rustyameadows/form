import Foundation
import FormCore

struct CollectionFiles {
  var data:[String:Data]=[:]
  var descriptors:[CollectionArtifact]=[]
  var bytes=0
  mutating func reserve(_ count:Int,_ additionalFiles:Int=1)throws {
    guard count>0,count<=CollectionLimits.fileBytes,bytes<=CollectionLimits.totalBytes-count,data.count+additionalFiles<=CollectionLimits.files-2 else{throw FormError.invalid("Collection source/assets exceed the early64 MB/file,128 MB aggregate or256-file envelope. Split this collection.")}
  }
  mutating func add(_ name:String,_ value:Data,role:String,provenance:String)throws {
    guard data[name]==nil else{throw FormError.invalid("A collection artifact path is duplicated.")};try reserve(value.count)
    let descriptor=CollectionArtifact(name:name,data:value,role:role,provenance:provenance);try descriptor.validate();data[name]=value;descriptors.append(descriptor);bytes+=value.count
  }
}
@MainActor enum CollectionPacketAssets {
  static func url(_ hash:String,repository:ProjectRepository,projectID:UUID)throws->URL {
    guard hash.utf8.count==64,ProductionJob.validDigest(hash) else{throw FormError.invalid("Invalid immutable collection hash.")}
    return repository.url(for:projectID).appendingPathComponent("Production/Collections",isDirectory:true).appendingPathComponent(hash+".asset")
  }
  static func size(_ hash:String,repository:ProjectRepository,projectID:UUID)throws->Int {
    let u=try url(hash,repository:repository,projectID:projectID),v=try u.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
    guard v.isRegularFile==true,v.isSymbolicLink != true,let bytes=v.fileSize,(1...CollectionLimits.fileBytes).contains(bytes) else{throw FormError.invalid("Collection archive is missing, linked or outside its read bound.")};return bytes
  }
  static func read(_ hash:String,repository:ProjectRepository,projectID:UUID,expected:Int?=nil)throws->Data {
    let bytes=try size(hash,repository:repository,projectID:projectID);guard expected.map({$0==bytes}) ?? true else{throw FormError.invalid("Archived collection length differs.")}
    let data=try Data(contentsOf:url(hash,repository:repository,projectID:projectID));guard data.count==bytes,CollectionSource.digest(data)==hash else{throw FormError.invalid("Collection archive bytes are corrupt; source/deliveries were not regenerated.")};return data
  }
  @discardableResult static func store(_ value:Data,repository:ProjectRepository,projectID:UUID)throws->String {
    guard !value.isEmpty,value.count<=CollectionLimits.fileBytes else{throw FormError.invalid("Collection asset exceeds64 MB.")}
    let hash=CollectionSource.digest(value),u=try url(hash,repository:repository,projectID:projectID)
    try FileManager.default.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true)
    if FileManager.default.fileExists(atPath:u.path) {guard try read(hash,repository:repository,projectID:projectID)==value else{throw FormError.invalid("Existing collection bytes were preserved for review.")}}
    else {try value.write(to:u,options:.atomic)};return hash
  }
}

import Foundation

public struct DecorationPreflightIssue:Codable,Equatable,Sendable {
  public var severity:String,message:String
  public var elementID:UUID?
  public init(severity:String,message:String,elementID:UUID?=nil) {self.severity=severity;self.message=message;self.elementID=elementID}
}
public struct DecorationArtifact:Codable,Equatable,Sendable {
  public var name:String,role:String,mediaType:String,digest:String
  public var bytes:Int
  public init(name:String,role:String,mediaType:String,digest:String,bytes:Int) {self.name=name;self.role=role;self.mediaType=mediaType;self.digest=digest;self.bytes=bytes}
  public func validate()throws {
    let parts=name.split(separator:"/",omittingEmptySubsequences:false)
    let expected=["json":"application/json","pdf":"application/pdf","svg":"image/svg+xml","png":"image/png","icc":"application/vnd.iccprofile"]
    let typed=expected[(name as NSString).pathExtension.lowercased()]==mediaType
    guard (typed || role=="source"),!name.isEmpty,name.utf8.count<=512,!name.hasPrefix("/"),parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}),
      !name.contains("\\"),!name.contains(":"),!name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),
      ["source","delivery","reference","profile"].contains(role),!mediaType.isEmpty,mediaType.count<=100,
      ProductionJob.validDigest(digest),(1...64_000_000).contains(bytes) else{throw FormError.invalid("Decoration files require safe relative names, known roles/formats, bounded lengths and immutable digests.")}
  }
}
public struct DecorationPreparationRevision:Codable,Equatable,Sendable {
  public var jobID:UUID
  public var name:String
  public var createdAt:Date
  public var sourceDigest:String
  public var objectID:UUID
  public var width:Double,height:Double
  public var options:DecorationPreparationOptions
  public var quantity:Int
  public var notes:String?
  public var findings:[DecorationPreflightIssue]
  public var files:[DecorationArtifact]
  public init(jobID:UUID=UUID(),name:String,createdAt:Date=Date(timeIntervalSince1970:floor(Date().timeIntervalSince1970)),sourceDigest:String,objectID:UUID,width:Double,height:Double,options:DecorationPreparationOptions,quantity:Int,notes:String?,findings:[DecorationPreflightIssue],files:[DecorationArtifact]) {
    self.jobID=jobID;self.name=name;self.createdAt=createdAt;self.sourceDigest=sourceDigest;self.objectID=objectID;self.width=width;self.height=height;self.options=options;self.quantity=quantity;self.notes=notes;self.findings=findings;self.files=files
  }
  public func validate()throws {
    try options.validate()
    guard files.count<=128 else{throw FormError.invalid("A decoration revision supports at most 128 files.")}
    for value in files {try value.validate()}
    guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=160,createdAt.timeIntervalSinceReferenceDate.isFinite,
      ProductionJob.validDigest(sourceDigest),[width,height].allSatisfy({$0.isFinite && (0.1...10000).contains($0)}),
      (1...100000).contains(quantity),(notes?.count ?? 0)<=4000,!files.isEmpty,files.count<=128,Set(files.map(\.name)).count==files.count,
      files.reduce(0,{$0+$1.bytes})<=128_000_000,files.contains(where:{$0.name=="Source.json" && $0.role=="source" && $0.digest==sourceDigest && $0.mediaType=="application/json"}),
      files.contains(where:{$0.role=="delivery"}),findings.count<=256,findings.allSatisfy({$0.severity=="warning" && !$0.message.isEmpty && $0.message.count<=4000}) else{throw FormError.invalid("A captured decoration revision requires complete bounded source/delivery files, explicit options and non-error findings.")}
  }
}
public struct DecorationPreparation:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var name:String
  public var createdAt=Date()
  public var objectID:UUID
  public var process:DecorationProcess
  public var width:Double,height:Double
  public var quantity:Int
  public var sourceDigest:String
  public var revisionDigest:String
  public init(name:String,objectID:UUID,process:DecorationProcess,width:Double,height:Double,quantity:Int,sourceDigest:String,revisionDigest:String) {
    self.name=name;self.objectID=objectID;self.process=process;self.width=width;self.height=height;self.quantity=quantity;self.sourceDigest=sourceDigest;self.revisionDigest=revisionDigest
  }
  public func validate()throws {
    guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=160,createdAt.timeIntervalSinceReferenceDate.isFinite,
      [width,height].allSatisfy({$0.isFinite && (0.1...10000).contains($0)}),(1...100000).contains(quantity),
      ProductionJob.validDigest(sourceDigest),ProductionJob.validDigest(revisionDigest) else{throw FormError.invalid("A decoration preparation needs a name, physical dimensions, quantity and immutable source/revision identities.")}
  }
}

extension Project {
  public func validateDecorationPreparations() throws {
    let values=decorationPreparations ?? []
    guard values.count<=500,Set(values.map(\.id)).count==values.count else{throw FormError.invalid("A project supports 500 uniquely identified archived decoration preparations.")}
    for value in values {try value.validate()}
    // Source deletion is allowed: an accepted archive is independently readable.
  }
}

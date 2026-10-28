import Foundation

public enum CollectionUnit:String,Codable,CaseIterable,Sendable {case piece,m,m2;case minute="min"}
public enum CollectionEvidence:String,Codable,Sendable {case computed,declared,reported,unknown}
public enum CollectionCostBasis:String,Codable,CaseIterable,Sendable {case unresolved,purchased,made}
public enum CollectionLimits {
  public static let runs=100,rows=2000,objects=256,files=256,fileBytes=64_000_000,totalBytes=128_000_000,pages=100
}
public struct StudioSupply:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var name:String
  public var category:String
  public var unit:CollectionUnit
  public var available:String?
  public var widthMM:String?,sheetLengthMM:String?
  public var unitPrice:String?
  public var currency:String?
  public var manufacturer:String?,sku:String?,supplier:String?,location:String?,notes:String?
  public init(name:String,category:String="trim",unit:CollectionUnit = .piece) {self.name=name;self.category=category;self.unit=unit}
  public func validate()throws {
    guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=160,["blank","trim","consumable"].contains(category),unit != .minute,
      [manufacturer,sku,supplier,location].allSatisfy({($0?.count ?? 0)<=500}),(notes?.count ?? 0)<=4000 else{throw FormError.invalid("Supplies need a bounded name, blank/trim/consumable category and physical unit.")}
    for (text,maximum) in [(widthMM,10000),(sheetLengthMM,100000)] {if let text {let value=try CollectionDecimal.parse(text);guard value>0,value<=Decimal(maximum) else{throw FormError.invalid("Known stock width supports up to10,000mm and sheet length up to100,000mm; unknown dimensions stay blank.")}}}
    if let available {_ = try CollectionDecimal.parse(available)}
    if let unitPrice {_ = try CollectionDecimal.parse(unitPrice);guard currency != nil else{throw FormError.invalid("A supply price needs its currency.")}}
    try CollectionDecimal.currency(currency)
  }
}
public struct CollectionStockSnapshot:Codable,Equatable,Sendable {
  public var thread:StudioThread?
  public var fabric:Material?
  public var supply:StudioSupply?
  public init(thread:StudioThread) {self.thread=thread}
  public init(fabric:Material) {self.fabric=fabric}
  public init(supply:StudioSupply) {self.supply=supply}
  public var key:String {thread.map{"thread/"+$0.id.uuidString} ?? fabric.map{"fabric/"+$0.id} ?? supply.map{"supply/"+$0.id.uuidString} ?? "invalid"}
  public var name:String {thread?.name ?? fabric?.name ?? supply?.name ?? "Unknown"}
  public var unit:CollectionUnit {supply?.unit ?? .m}
  public var available:String? {get throws {if let supply {return supply.available};if let v=thread?.availableMeters ?? fabric?.fabric?.inventoryMeters {return try CollectionDecimal.computed(v)};return nil}}
  public func validate()throws {
    guard [thread != nil,fabric != nil,supply != nil].filter({$0}).count==1 else{throw FormError.invalid("Assign exactly one original stock snapshot.")}
    try thread?.validate();try fabric?.fabric?.validate();try supply?.validate()
    if let fabric {guard fabric.fabric != nil,!fabric.id.isEmpty else{throw FormError.invalid("A fabric snapshot needs its original material identity/specification.")}}
  }
}
public struct CollectionRun:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var objectID:UUID?
  public var garmentBlockID:UUID?
  public var sizeID:UUID?
  public var quantity:Int
  public var includeAttachments:Bool
  public init(objectID:UUID,quantity:Int=1,includeAttachments:Bool=true) {self.objectID=objectID;self.quantity=quantity;self.includeAttachments=includeAttachments}
  public init(blockID:UUID,sizeID:UUID,quantity:Int=1) {garmentBlockID=blockID;self.sizeID=sizeID;self.quantity=quantity;includeAttachments=false}
  private enum CodingKeys:String,CodingKey {case id,objectID,garmentBlockID,sizeID,quantity,includeAttachments}
  public init(from d:Decoder)throws {let c=try d.container(keyedBy:CodingKeys.self);id=try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID();objectID=try c.decodeIfPresent(UUID.self,forKey:.objectID);garmentBlockID=try c.decodeIfPresent(UUID.self,forKey:.garmentBlockID);sizeID=try c.decodeIfPresent(UUID.self,forKey:.sizeID);quantity=try c.decode(Int.self,forKey:.quantity);includeAttachments=try c.decode(Bool.self,forKey:.includeAttachments)}
  public func validate()throws {guard (1...100000).contains(quantity),(objectID != nil && garmentBlockID==nil && sizeID==nil) || (objectID==nil && garmentBlockID != nil && sizeID != nil && !includeAttachments) else{throw FormError.invalid("A run needs one physical object or managed block/size, an integer quantity and explicit attachment inclusion.")}}
}
public struct CollectionLineRule:Codable,Equatable,Sendable {
  public var rowID:String
  public var costBasis:CollectionCostBasis?
  public var costSourceRowID:String?
  public var quantity:String?
  public var unit:CollectionUnit?
  public var unitPrice:String?
  public var currency:String?
  public var stock:CollectionStockSnapshot?
  public var excludedReason:String?
  public var notes:String?
  public init(rowID:String) {self.rowID=rowID}
  public func validate()throws {
    guard !rowID.isEmpty,rowID.count<=300,costSourceRowID.map({!$0.isEmpty && $0.count<=300}) ?? true,(notes?.count ?? 0)<=4000,excludedReason.map({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.count<=1000}) ?? true else{throw FormError.invalid("Use a known bounded row identity and an explicit reason for exclusion.")}
    if let quantity {_ = try CollectionDecimal.parse(quantity);guard unit != nil else{throw FormError.invalid("A declared quantity needs its unit.")}}
    if let unitPrice {_ = try CollectionDecimal.parse(unitPrice);guard currency != nil else{throw FormError.invalid("A rate needs its explicit currency.")}}
    try CollectionDecimal.currency(currency);try stock?.validate()
  }
}
public struct CollectionExtraLine:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var name:String
  public var runID:UUID?
  public var quantity:String?
  public var unit:CollectionUnit
  public var unitPrice:String?,currency:String?,supplier:String?,sku:String?,notes:String?
  public init(name:String,unit:CollectionUnit = .piece) {self.name=name;self.unit=unit}
  public func validate()throws {guard !name.isEmpty,name.count<=160,[supplier,sku].allSatisfy({($0?.count ?? 0)<=500}),(notes?.count ?? 0)<=4000 else{throw FormError.invalid("Name the declared additional material/process and keep notes bounded.")};if let quantity {_ = try CollectionDecimal.parse(quantity)};if let unitPrice {_ = try CollectionDecimal.parse(unitPrice);guard currency != nil else{throw FormError.invalid("A rate requires currency.")}};try CollectionDecimal.currency(currency)}
}
public struct CollectionLayoutAllocation:Codable,Equatable,Sendable {
  public var runID:UUID,objectID:UUID
  public init(runID:UUID,objectID:UUID) {self.runID=runID;self.objectID=objectID}
}
public struct CollectionProcessBinding:Codable,Equatable,Sendable {
  public var jobID:UUID
  public var kind:String
  public init(jobID:UUID,kind:String) {self.jobID=jobID;self.kind=kind}
}
public struct CollectionProductionPlan:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var name:String
  public var runs:[CollectionRun]
  public var rules:[CollectionLineRule]=[]
  public var extras:[CollectionExtraLine]=[]
  public var layouts:[CollectionLayoutAllocation]=[]
  public var processes:[CollectionProcessBinding]=[]
  public var notes:String?
  public init(name:String,runs:[CollectionRun]) {self.name=name;self.runs=runs}
  private enum CodingKeys:String,CodingKey {case id,name,runs,rules,extras,layouts,processes,notes}
  public init(from d:Decoder)throws {let c=try d.container(keyedBy:CodingKeys.self);id=try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID();name=try c.decode(String.self,forKey:.name);runs=try c.decode([CollectionRun].self,forKey:.runs);rules=try c.decodeIfPresent([CollectionLineRule].self,forKey:.rules) ?? [];extras=try c.decodeIfPresent([CollectionExtraLine].self,forKey:.extras) ?? [];layouts=try c.decodeIfPresent([CollectionLayoutAllocation].self,forKey:.layouts) ?? [];processes=try c.decodeIfPresent([CollectionProcessBinding].self,forKey:.processes) ?? [];notes=try c.decodeIfPresent(String.self,forKey:.notes)}
  public func validate()throws {
    guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=160,(1...CollectionLimits.runs).contains(runs.count),Set(runs.map(\.id)).count==runs.count,
      rules.count+extras.count<=CollectionLimits.rows,Set(rules.map(\.rowID)).count==rules.count,Set(extras.map(\.id)).count==extras.count,
      layouts.count<=100,processes.count<=100,Set(processes.map(\.jobID)).count==processes.count,(notes?.count ?? 0)<=4000 else{throw FormError.invalid("A collection plan needs 1–100 unique runs, bounded unique rows and at most100 process/layout bindings.")}
    for r in runs {try r.validate()};for r in rules {try r.validate()};for e in extras {try e.validate();guard e.runID.map({id in runs.contains{$0.id==id}}) ?? true else{throw FormError.invalid("An extra line refers to a missing run.")}}
    guard processes.allSatisfy({["embroidery","decoration"].contains($0.kind)}),layouts.allSatisfy({v in runs.contains{$0.id==v.runID}}),Set(layouts.map{$0.runID.uuidString+"/"+$0.objectID.uuidString}).count==layouts.count else{throw FormError.invalid("Layout/process scope is missing or duplicated.")}
  }
}
public struct CollectionCapture:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID(),planID:UUID
  public var name:String
  public var createdAt=Date(timeIntervalSince1970:floor(Date().timeIntervalSince1970))
  public var sourceDigest:String,revisionDigest:String,manifestDigest:String
  public var supersedesID:UUID?
  public init(plan:CollectionProductionPlan,sourceDigest:String,revisionDigest:String,manifestDigest:String) {planID=plan.id;name=plan.name;self.sourceDigest=sourceDigest;self.revisionDigest=revisionDigest;self.manifestDigest=manifestDigest}
  public func validate()throws {guard !name.isEmpty,name.count<=160,createdAt.timeIntervalSinceReferenceDate.isFinite,[sourceDigest,revisionDigest,manifestDigest].allSatisfy({$0.utf8.count==64 && ProductionJob.validDigest($0)}) else{throw FormError.invalid("Invalid immutable collection capture identity.")}}
}
public struct CollectionProduction:Codable,Equatable,Sendable {
  public var plans:[CollectionProductionPlan]=[]
  public var captures:[CollectionCapture]=[]
  public init() {}
  public func validate()throws {guard plans.count<=100,captures.count<=500,Set(plans.map(\.id)).count==plans.count,Set(captures.map(\.id)).count==captures.count else{throw FormError.invalid("Collections support100 plans and500 uniquely identified captures.")};for p in plans {try p.validate()};for c in captures {try c.validate();var visited=Set<UUID>();var current:CollectionCapture?=c;while let value=current {guard visited.insert(value.id).inserted else{throw FormError.invalid("Collection revision lineage cannot cycle.")};if let prior=value.supersedesID {guard let found=captures.first(where:{$0.id==prior}),found.planID==c.planID else{throw FormError.invalid("Collection lineage must refer to the same plan identity.")};current=found}else{current=nil}}}}
}
extension Project {public func validateCollectionProduction()throws {try collectionProduction?.validate()}}

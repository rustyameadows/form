import Foundation

public struct ProductionBOMItem:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var name:String
  public var quantityPerItem:Double
  public var unit:String
  public var unitCost:Double?
  public var currency:String?
  public var supplier:String?
  public var sku:String?
  public init(name:String,quantityPerItem:Double,unit:String) {self.name=name;self.quantityPerItem=quantityPerItem;self.unit=unit}
  private enum CodingKeys:String,CodingKey {case id,name,quantityPerItem,unit,unitCost,currency,supplier,sku}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    id=try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID();name=try c.decode(String.self,forKey:.name)
    quantityPerItem=try c.decode(Double.self,forKey:.quantityPerItem);unit=try c.decode(String.self,forKey:.unit)
    unitCost=try c.decodeIfPresent(Double.self,forKey:.unitCost);currency=try c.decodeIfPresent(String.self,forKey:.currency)
    supplier=try c.decodeIfPresent(String.self,forKey:.supplier);sku=try c.decodeIfPresent(String.self,forKey:.sku)
  }
  public func validate()throws {
    guard !name.isEmpty,name.count<=160,!unit.isEmpty,unit.count<=40,quantityPerItem.isFinite,(0...1_000_000).contains(quantityPerItem),
      unitCost.map({$0.isFinite && (0...100_000_000).contains($0)}) ?? true,
      currency.map({$0.range(of:"^[A-Z]{3}$",options:.regularExpression) != nil}) ?? true,
      unitCost==nil || currency != nil,[supplier,sku].allSatisfy({($0?.count ?? 0)<=500}) else {throw FormError.invalid("BOM lines need bounded names/units, finite nonnegative quantities/costs, and a currency when priced.")}
  }
}
public struct ProductionAssumptions:Codable,Equatable,Sendable {
  public var upperThreadFactor:Double?
  public var allowanceMetersPerThreadPerItem:Double?
  public var baseUnitCost:Double?
  public var baseCurrency:String?
  public var laborMinutesPerItem:Double?
  public var hourlyLaborRate:Double?
  public var laborCurrency:String?
  public var extraBOM:[ProductionBOMItem]=[]
  public var notes:String?
  public init() {}
  private enum CodingKeys:String,CodingKey {case upperThreadFactor,allowanceMetersPerThreadPerItem,baseUnitCost,baseCurrency,laborMinutesPerItem,hourlyLaborRate,laborCurrency,extraBOM,notes}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    upperThreadFactor=try c.decodeIfPresent(Double.self,forKey:.upperThreadFactor);allowanceMetersPerThreadPerItem=try c.decodeIfPresent(Double.self,forKey:.allowanceMetersPerThreadPerItem)
    baseUnitCost=try c.decodeIfPresent(Double.self,forKey:.baseUnitCost);baseCurrency=try c.decodeIfPresent(String.self,forKey:.baseCurrency)
    laborMinutesPerItem=try c.decodeIfPresent(Double.self,forKey:.laborMinutesPerItem);hourlyLaborRate=try c.decodeIfPresent(Double.self,forKey:.hourlyLaborRate);laborCurrency=try c.decodeIfPresent(String.self,forKey:.laborCurrency)
    extraBOM=try c.decodeIfPresent([ProductionBOMItem].self,forKey:.extraBOM) ?? [];notes=try c.decodeIfPresent(String.self,forKey:.notes)
  }
  public func validate()throws {
    guard upperThreadFactor.map({$0.isFinite && (1...20).contains($0)}) ?? true,
      allowanceMetersPerThreadPerItem.map({$0.isFinite && (0...100).contains($0)}) ?? true,
      [baseUnitCost,laborMinutesPerItem,hourlyLaborRate].allSatisfy({$0.map {$0.isFinite && (0...100_000_000).contains($0)} ?? true}),
      [baseCurrency,laborCurrency].allSatisfy({$0.map {$0.range(of:"^[A-Z]{3}$",options:.regularExpression) != nil} ?? true}),
      baseUnitCost==nil || baseCurrency != nil,hourlyLaborRate==nil || laborCurrency != nil,
      extraBOM.count<=100,Set(extraBOM.map(\.id)).count==extraBOM.count,(notes?.count ?? 0)<=4000 else {throw FormError.invalid("Use explicit finite production assumptions. Known costs require a currency; leave unknown consumption, prices, and labor blank.")}
    for item in extraBOM {try item.validate()}
  }
}
public struct ThreadNeedleUsage:Codable,Equatable,Sendable {
  public var threadIndex:Int
  public var needleMeters=0.0
  public var underlayMeters=0.0
  public var tieMeters=0.0
  public var stitches=0
  public init(threadIndex:Int) {self.threadIndex=threadIndex}
  public static func measure(_ program:EmbroideryProgram)->[Self] {
    var values:[Int:Self]=[:],previous=Point2()
    for command in program.commands {
      if command.action == .stitch {
        var item=values[command.threadIndex] ?? .init(threadIndex:command.threadIndex)
        let meters=hypot(command.point.x-previous.x,command.point.y-previous.y)/1000
        item.needleMeters+=meters;item.stitches+=1
        if command.purpose == .underlay {item.underlayMeters+=meters}
        if command.purpose == .tieIn || command.purpose == .tieOff {item.tieMeters+=meters}
        values[command.threadIndex]=item
      }
      previous=command.point
    }
    return values.values.sorted {$0.threadIndex<$1.threadIndex}
  }
}
public struct ProductionJobRevision:Codable,Equatable,Sendable {
  public var object:ProductObject
  public var material:Material
  public var garment:ProductObject?
  public var garmentMaterial:Material?
  public var equipment:EmbroideryEquipment?
  public var quantity:Int
  public var outputs:[String]
  public var assumptions:ProductionAssumptions
  public var sourceDigest:String
  public var programDigest:String
  /// Self-contained ordinary artwork captured with this immutable revision.
  /// Nil on historical revisions, whose saved source remains readable.
  public var sourceArtworkSVG:String?=nil
  public var threadSequence:[Int]
  public var usage:[ThreadNeedleUsage]
  public var compatibility:EmbroideryCompatibility
  public init(object:ProductObject,material:Material,quantity:Int,outputs:[String],assumptions:ProductionAssumptions,program:EmbroideryProgram,programDigest:String,equipment:EmbroideryEquipment?) {
    self.object=object;self.material=material;self.quantity=quantity;self.outputs=outputs;self.assumptions=assumptions;self.sourceDigest=program.sourceDigest;self.programDigest=programDigest;self.threadSequence=program.threadOrder;self.usage=ThreadNeedleUsage.measure(program);self.equipment=equipment
    compatibility = .check(design:program.design,equipment:equipment,outputs:outputs)
  }
  public func validate()throws {
    guard (1...100000).contains(quantity),!outputs.isEmpty,outputs.count<=3,Set(outputs).count==outputs.count,Set(outputs).isSubset(of:["dst","svg","json"]),
      ProductionJob.validDigest(sourceDigest),ProductionJob.validDigest(programDigest),object.artworkSourceID==nil,
      let design=object.textile?.embroidery,usage.count<=32,Set(usage.map(\.threadIndex)).count==usage.count,
      !threadSequence.isEmpty,threadSequence.count<=128,threadSequence.allSatisfy({design.threads.indices.contains($0)}),
      usage.allSatisfy({design.threads.indices.contains($0.threadIndex) && $0.stitches>0 && $0.stitches<=100000 && [$0.needleMeters,$0.underlayMeters,$0.tieMeters].allSatisfy {$0.isFinite && (0...10000).contains($0)}}) else {throw FormError.invalid("Invalid immutable production revision or thread schedule.")}
    if let sourceArtworkSVG {
      guard !sourceArtworkSVG.isEmpty,sourceArtworkSVG.utf8.count<=32_000_000,sourceArtworkSVG.hasPrefix("<?xml"),sourceArtworkSVG.contains("<svg ") else {throw FormError.invalid("The archived ordinary artwork must be a bounded self-contained SVG.")}
    }
    try design.validate();try assumptions.validate();try equipment?.validate()
    guard compatibility == .check(design:design,equipment:equipment,outputs:outputs) else {throw FormError.invalid("Production equipment assessment does not match its saved declarations.")}
  }
}
public struct ProductionRecord:Codable,Equatable,Identifiable,Sendable {
  public enum Kind:String,Codable,CaseIterable,Sendable {case note,sample,quality,status}
  public enum Outcome:String,Codable,CaseIterable,Sendable {case pass,needsChanges,fail}
  public enum Status:String,Codable,CaseIterable,Sendable {case planned,sampling,approved,held,completed}
  public var id=UUID()
  public var date=Date()
  public var kind:Kind
  public var sourceDigest:String
  public var notes:String
  public var recordedBy:String?
  public var outcome:Outcome?
  public var status:Status?
  public var reportedMeters:Double?
  public init(kind:Kind,sourceDigest:String,notes:String) {self.kind=kind;self.sourceDigest=sourceDigest;self.notes=notes}
  private enum CodingKeys:String,CodingKey {case id,date,kind,sourceDigest,notes,recordedBy,outcome,status,reportedMeters}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    id=try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID();date=try c.decodeIfPresent(Date.self,forKey:.date) ?? Date()
    kind=try c.decode(Kind.self,forKey:.kind);sourceDigest=try c.decode(String.self,forKey:.sourceDigest);notes=try c.decode(String.self,forKey:.notes)
    recordedBy=try c.decodeIfPresent(String.self,forKey:.recordedBy);outcome=try c.decodeIfPresent(Outcome.self,forKey:.outcome)
    status=try c.decodeIfPresent(Status.self,forKey:.status);reportedMeters=try c.decodeIfPresent(Double.self,forKey:.reportedMeters)
  }
  public func validate(source:String)throws {
    guard sourceDigest==source,!notes.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,notes.count<=4000,(recordedBy?.count ?? 0)<=160,
      date.timeIntervalSinceReferenceDate.isFinite,reportedMeters.map({$0.isFinite && (0...1_000_000).contains($0)}) ?? true,
      kind != .status || status != nil,kind == .status || status==nil,
      kind == .sample || kind == .quality || (outcome==nil && reportedMeters==nil) else {throw FormError.invalid("Record a bounded user note/result tied to this job's source revision. Status records require a status; outcomes and reported use belong to sample/quality records.")}
  }
}
public struct ProductionJob:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var name:String
  public var createdAt=Date()
  public var objectID:UUID
  public var sourceDigest:String
  public var revisionDigest:String
  public var programDigest:String
  public var quantity:Int
  public var supersedesJobID:UUID?
  public var records:[ProductionRecord]=[]
  public init(name:String,objectID:UUID,sourceDigest:String,revisionDigest:String,programDigest:String,quantity:Int) {self.name=name;self.objectID=objectID;self.sourceDigest=sourceDigest;self.revisionDigest=revisionDigest;self.programDigest=programDigest;self.quantity=quantity}
  public var status:ProductionRecord.Status {records.last(where:{$0.kind == .status})?.status ?? .planned}
  public static func validDigest(_ value:String)->Bool {value.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}
  public func validate()throws {
    guard !name.isEmpty,name.count<=160,(1...100000).contains(quantity),Self.validDigest(sourceDigest),Self.validDigest(revisionDigest),Self.validDigest(programDigest),createdAt.timeIntervalSinceReferenceDate.isFinite,
      records.count<=200,Set(records.map(\.id)).count==records.count else {throw FormError.invalid("Invalid production job identity, source digest, quantity, or bounded records.")}
    for record in records {try record.validate(source:sourceDigest)}
  }
}
extension Project {
  public func validateProductionJobs()throws {
    let jobs=productionJobs ?? []
    guard jobs.count<=200,Set(jobs.map(\.id)).count==jobs.count else {throw FormError.invalid("Use at most 200 distinct revision-linked production jobs in one project.")}
    let byID=Dictionary(uniqueKeysWithValues:jobs.map {($0.id,$0)})
    for job in jobs {
      try job.validate()
      var cursor=job.supersedesJobID,seen:Set<UUID>=[job.id]
      while let id=cursor {
        guard seen.insert(id).inserted,let ancestor=byID[id],ancestor.objectID==job.objectID else {throw FormError.invalid("Production revision lineage must refer to existing jobs for the same object without cycles.")}
        cursor=ancestor.supersedesJobID
      }
    }
  }
}
public struct ProductionCostEstimate:Codable,Equatable,Sendable {
  public struct ThreadLine:Codable,Equatable,Sendable {
    public var threadIndex:Int
    public var measuredNeedleMeters:Double
    public var estimatedMeters:Double?
    public var estimatedCost:Double?
    public var currency:String?
    public var stockAvailableMeters:Double?
    public var stockSufficient:Bool?
  }
  public var threads:[ThreadLine]
  public var knownSubtotals:[String:Double]
  public var total:Double?
  public var currency:String?
  public var unknowns:[String]
  public var inventoryNotes:[String]
  public static func estimate(_ revision:ProductionJobRevision)->Self {
    let assumptions=revision.assumptions,quantity=Double(revision.quantity),palette=revision.object.textile?.embroidery?.threads ?? []
    var threads:[ThreadLine]=[],subtotals:[String:Double]=[:],unknowns:[String]=[],inventoryNotes:[String]=[]
    func add(_ value:Double?,currency:String?,missing:String) {
      if let value,let currency {subtotals[currency,default:0]+=value} else {unknowns.append(missing)}
    }
    for usage in revision.usage {
      guard palette.indices.contains(usage.threadIndex) else {unknowns.append("A thread schedule entry has no palette identity.");continue}
      let thread=palette[usage.threadIndex],meters:Double?
      if let factor=assumptions.upperThreadFactor,let allowance=assumptions.allowanceMetersPerThreadPerItem {meters=(usage.needleMeters*factor+allowance)*quantity}
      else {meters=nil;unknowns.append("Thread \(usage.threadIndex+1) consumption: both multiplier and per-thread/item allowance are required.")}
      let cost=meters.flatMap {meters in thread.stock?.pricePerMeter.map {$0*meters}}
      add(cost,currency:thread.stock?.currency,missing:"Thread \(usage.threadIndex+1) cost is unknown.")
      threads.append(.init(threadIndex:usage.threadIndex,measuredNeedleMeters:usage.needleMeters*quantity,estimatedMeters:meters,estimatedCost:cost,currency:thread.stock?.currency,stockAvailableMeters:thread.stock?.availableMeters,stockSufficient:meters.flatMap {needed in thread.stock?.availableMeters.map {$0>=needed}}))
    }
    add(assumptions.baseUnitCost.map {$0*quantity},currency:assumptions.baseCurrency,missing:"Blank/component unit cost is unknown.")
    for item in assumptions.extraBOM {add(item.unitCost.map {$0*item.quantityPerItem*quantity},currency:item.currency,missing:"BOM cost for \(item.name) is unknown.")}
    let labor=assumptions.laborMinutesPerItem.flatMap {minutes in assumptions.hourlyLaborRate.map {minutes/60*$0*quantity}}
    add(labor,currency:assumptions.laborCurrency,missing:"Labor minutes/rate/currency are unknown.")
    // A spool can serve several palette entries. Compare their combined need,
    // rather than incorrectly treating every assignment as a fresh inventory.
    let assigned=threads.indices.filter {palette[threads[$0].threadIndex].stock != nil}
    let groups=Dictionary(grouping:assigned,by:{palette[threads[$0].threadIndex].stock!.id})
    for indices in groups.values.sorted(by:{($0.min() ?? 0)<($1.min() ?? 0)}) {
      let records=indices.map {palette[threads[$0].threadIndex].stock!},first=records[0]
      let consistent=records.allSatisfy {$0.color.uppercased()==first.color.uppercased() && $0.sku==first.sku && $0.availableMeters==first.availableMeters}
      let needed=indices.compactMap {threads[$0].estimatedMeters}
      let sufficient:Bool?
      if consistent,needed.count==indices.count,let available=first.availableMeters {sufficient=needed.reduce(0,+)<=available}
      else {sufficient=nil}
      for index in indices {threads[index].stockSufficient=sufficient}
      if !consistent {inventoryNotes.append("Stock \(first.name) has conflicting assigned snapshots; combined availability is unknown.")}
      else if sufficient==false {inventoryNotes.append("Recorded stock for \(first.name) is below the combined estimated need. Nothing has been deducted or reserved.")}
      else if sufficient==nil {inventoryNotes.append("Combined stock sufficiency for \(first.name) is unknown.")}
    }
    if subtotals.count>1 {unknowns.append("Mixed currencies are retained separately; no exchange rate is assumed.")}
    let currency=subtotals.count==1 ? subtotals.keys.first:nil
    return .init(threads:threads,knownSubtotals:subtotals,total:unknowns.isEmpty ? currency.flatMap {subtotals[$0]}:nil,currency:currency,unknowns:unknowns,inventoryNotes:inventoryNotes)
  }
}

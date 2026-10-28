import Foundation

public struct StudioThread:Codable,Equatable,Identifiable,Sendable {
  public var id:UUID
  public var name:String
  public var color:String
  public var brand:String?
  public var sku:String?
  public var supplier:String?
  public var fiber:String?
  public var location:String?
  public var availableMeters:Double?
  public var spoolMeters:Double?
  public var spoolPrice:Double?
  public var currency:String?
  public var notes:String?
  public var updatedAt:Date
  public init(name:String,color:String) {id=UUID();self.name=name;self.color=color;updatedAt=Date()}
  private enum CodingKeys:String,CodingKey {case id,name,color,brand,sku,supplier,fiber,location,availableMeters,spoolMeters,spoolPrice,currency,notes,updatedAt}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    id=try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID();name=try c.decode(String.self,forKey:.name);color=try c.decode(String.self,forKey:.color)
    brand=try c.decodeIfPresent(String.self,forKey:.brand);sku=try c.decodeIfPresent(String.self,forKey:.sku);supplier=try c.decodeIfPresent(String.self,forKey:.supplier)
    fiber=try c.decodeIfPresent(String.self,forKey:.fiber);location=try c.decodeIfPresent(String.self,forKey:.location);notes=try c.decodeIfPresent(String.self,forKey:.notes)
    availableMeters=try c.decodeIfPresent(Double.self,forKey:.availableMeters);spoolMeters=try c.decodeIfPresent(Double.self,forKey:.spoolMeters)
    spoolPrice=try c.decodeIfPresent(Double.self,forKey:.spoolPrice);currency=try c.decodeIfPresent(String.self,forKey:.currency)
    updatedAt=try c.decodeIfPresent(Date.self,forKey:.updatedAt) ?? Date()
  }
  public var pricePerMeter:Double? {guard let price=spoolPrice,let meters=spoolMeters,meters>0,currency != nil else {return nil};return price/meters}
  public func validate()throws {
    try validateColor(color)
    guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=160,
      [brand,sku,supplier,fiber,location].allSatisfy({($0?.count ?? 0)<=500}),(notes?.count ?? 0)<=4000,
      [availableMeters,spoolMeters,spoolPrice].allSatisfy({$0.map {$0.isFinite && $0>=0 && $0<=100_000_000} ?? true}),
      spoolMeters == nil || spoolMeters!>0,
      currency == nil || currency!.range(of:"^[A-Z]{3}$",options:.regularExpression) != nil,
      spoolPrice == nil || currency != nil,updatedAt.timeIntervalSinceReferenceDate.isFinite else {throw FormError.invalid("Thread stock needs a bounded name, finite nonnegative stock/price, positive known spool length, and a three-letter currency when priced. Leave unknowns blank.")}
  }
}
public struct EmbroideryHoop:Codable,Equatable,Sendable {
  public var name:String
  public var width:Double
  public var height:Double
  public init(name:String,width:Double,height:Double) {self.name=name;self.width=width;self.height=height}
}
public struct EmbroideryEquipment:Codable,Equatable,Identifiable,Sendable {
  public var id:UUID
  public var name:String
  public var manufacturer:String?
  public var model:String?
  public var hoops:[EmbroideryHoop]
  public var formats:[String]
  public var needleCount:Int?
  public var declarationsVerified:Bool
  public var notes:String?
  public init(name:String) {id=UUID();self.name=name;hoops=[];formats=[];declarationsVerified=false}
  private enum CodingKeys:String,CodingKey {case id,name,manufacturer,model,hoops,formats,needleCount,declarationsVerified,notes}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    id=try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID();name=try c.decode(String.self,forKey:.name)
    manufacturer=try c.decodeIfPresent(String.self,forKey:.manufacturer);model=try c.decodeIfPresent(String.self,forKey:.model)
    hoops=try c.decodeIfPresent([EmbroideryHoop].self,forKey:.hoops) ?? [];formats=try c.decodeIfPresent([String].self,forKey:.formats) ?? []
    needleCount=try c.decodeIfPresent(Int.self,forKey:.needleCount);declarationsVerified=try c.decodeIfPresent(Bool.self,forKey:.declarationsVerified) ?? false;notes=try c.decodeIfPresent(String.self,forKey:.notes)
  }
  public func validate()throws {
    guard !name.isEmpty,name.count<=160,[manufacturer,model].allSatisfy({($0?.count ?? 0)<=500}),(notes?.count ?? 0)<=4000,
      hoops.count<=64,formats.count<=32,Set(formats).count==formats.count,
      formats.allSatisfy({$0.range(of:"^[a-z0-9]{1,12}$",options:.regularExpression) != nil}),
      needleCount.map({(1...100).contains($0)}) ?? true,
      hoops.allSatisfy({!$0.name.isEmpty && $0.name.count<=160 && $0.width.isFinite && $0.height.isFinite && (10...1000).contains($0.width) && (10...1000).contains($0.height)}) else {throw FormError.invalid("Equipment needs a name, bounded hoop/format declarations, and a positive known needle count. Unknown capabilities may remain empty.")}
  }
}
public struct TextileProductionLibrary:Codable,Equatable,Sendable {
  public var supplies:[StudioSupply]?
  public var threads:[StudioThread]=[]
  public var equipment:[EmbroideryEquipment]=[]
  public init() {}
  public func validate()throws {
    guard threads.count<=1000,equipment.count<=100,Set(threads.map(\.id)).count==threads.count,Set(equipment.map(\.id)).count==equipment.count else {throw FormError.invalid("Use at most 1,000 unique thread records and 100 embroidery equipment profiles.")}
    guard (supplies?.count ?? 0)<=1000,Set((supplies ?? []).map(\.id)).count==(supplies?.count ?? 0) else{throw FormError.invalid("Use at most1,000 uniquely identified supply declarations.")}
    for item in supplies ?? [] {try item.validate()}
    for item in threads {try item.validate()};for item in equipment {try item.validate()}
  }
}
extension EmbroideryThread {
  public init(stock:StudioThread) {self.init(name:stock.name,color:stock.color);brand=stock.brand;catalog=stock.sku;self.stock=stock}
}
public struct EmbroideryCompatibility:Codable,Equatable,Sendable {
  public enum Status:String,Codable,Sendable {
    case declaredCompatible,incompatible,unknown
    public var displayName:String {
      switch self {
      case .declaredCompatible:return "Within declared limits"
      case .incompatible:return "Outside declared limits"
      case .unknown:return "Compatibility unknown"
      }
    }
  }
  public var status:Status
  public var messages:[String]
  public static func check(design:EmbroideryDesign,equipment:EmbroideryEquipment?,outputs:[String])->Self {
    guard let equipment else {return .init(status:.unknown,messages:["No equipment profile selected. No connection or machine capability is implied."])}
    var issues:[String]=[],unknown:[String]=[]
    if equipment.hoops.isEmpty {unknown.append("Supported hoop sizes are unknown.")}
    else if !equipment.hoops.contains(where:{$0.width>=design.hoopWidth && $0.height>=design.hoopHeight}) {issues.append("Selected hoop exceeds the declared width/height; automatic rotation is not assumed.")}
    if outputs.contains("dst") {
      if equipment.formats.isEmpty {unknown.append("Machine file formats are unknown.")}
      else if !equipment.formats.contains("dst") {issues.append("DST is absent from the declared machine formats.")}
    } else {unknown.append("No machine-format output is selected; reference outputs do not establish compatibility.")}
    if !issues.isEmpty {return .init(status:.incompatible,messages:issues+unknown)}
    if !unknown.isEmpty {return .init(status:.unknown,messages:unknown)}
    return .init(status:.declaredCompatible,messages:[equipment.declarationsVerified ? "Recorded declarations cover this hoop and DST format.":"Unverified user declarations cover this hoop and DST format.","Needle count is descriptive; sequential color changes do not establish machine scheduling, sewability, or connectivity."])
  }
}

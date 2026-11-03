import Foundation

public enum PublicationPageSide:String,Codable,CaseIterable,Sendable {case recto,verso}
public struct PublicationLayout:Codable,Equatable,Sendable {
  public var facingPages:Bool
  public var firstPageSide:PublicationPageSide
  public var innerMargin:Double?
  public var outerMargin:Double?
  public init(facingPages:Bool=true,firstPageSide:PublicationPageSide = .recto,innerMargin:Double?=nil,outerMargin:Double?=nil) {
    self.facingPages=facingPages;self.firstPageSide=firstPageSide;self.innerMargin=innerMargin;self.outerMargin=outerMargin
  }
  private enum CodingKeys:String,CodingKey {case facingPages,firstPageSide,innerMargin,outerMargin}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    facingPages=try c.decodeIfPresent(Bool.self,forKey:.facingPages) ?? true
    firstPageSide=try c.decodeIfPresent(PublicationPageSide.self,forKey:.firstPageSide) ?? .recto
    innerMargin=try c.decodeIfPresent(Double.self,forKey:.innerMargin);outerMargin=try c.decodeIfPresent(Double.self,forKey:.outerMargin)
  }
  public var valid:Bool {[innerMargin,outerMargin].compactMap{$0}.allSatisfy{$0.isFinite && (0...1000).contains($0)}}
}
public enum PublicationNumberStyle:String,Codable,CaseIterable,Sendable {case arabic,lowerRoman,upperRoman,lowerAlpha,upperAlpha}
public struct PublicationNumbering:Codable,Equatable,Sendable {
  public var start:Int
  public var style:PublicationNumberStyle
  public var prefix:String
  public var suffix:String
  public init(start:Int=1,style:PublicationNumberStyle = .arabic,prefix:String="",suffix:String="") {self.start=start;self.style=style;self.prefix=prefix;self.suffix=suffix}
  private enum CodingKeys:String,CodingKey {case start,style,prefix,suffix}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    start=try c.decodeIfPresent(Int.self,forKey:.start) ?? 1;style=try c.decodeIfPresent(PublicationNumberStyle.self,forKey:.style) ?? .arabic
    prefix=try c.decodeIfPresent(String.self,forKey:.prefix) ?? "";suffix=try c.decodeIfPresent(String.self,forKey:.suffix) ?? ""
  }
  public var valid:Bool {(1...999_999).contains(start) && prefix.count<=100 && suffix.count<=100}
  public func formatted(_ value:Int)->String {
    guard (1...1_000_200).contains(value) else{return ""}
    var digits:String
    switch style {
    case .arabic:digits=String(value)
    case .lowerAlpha,.upperAlpha:
      var n=value;digits=""
      while n>0 {n-=1;digits=String(UnicodeScalar(65+n%26)!)+digits;n/=26}
      if style == .lowerAlpha {digits=digits.lowercased()}
    case .lowerRoman,.upperRoman:
      guard value<=3999 else{return prefix+String(value)+suffix}
      var n=value;digits=""
      for (amount,symbol) in [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")] {
        while n>=amount {digits+=symbol;n-=amount}
      }
      if style == .lowerRoman {digits=digits.lowercased()}
    }
    return prefix+digits+suffix
  }
}
public enum PublicationMasterSide:String,Codable,CaseIterable,Sendable {case all,recto,verso}
/// The source remains ordinary editable artwork. Placement is physical mm,
/// without fitting/stretching it when a publication page has a different size.
public struct PublicationMaster:Codable,Equatable,Identifiable,Sendable {
  public var id=UUID()
  public var name:String
  public var sourceObjectID:UUID
  public var x:Double
  public var y:Double
  public var side:PublicationMasterSide
  public var behind:Bool
  public init(name:String="Master",sourceObjectID:UUID,x:Double=0,y:Double=0,side:PublicationMasterSide = .all,behind:Bool=false) {
    self.name=name;self.sourceObjectID=sourceObjectID;self.x=x;self.y=y;self.side=side;self.behind=behind
  }
  private enum CodingKeys:String,CodingKey {case id,name,sourceObjectID,x,y,side,behind}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    id=try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID();name=try c.decodeIfPresent(String.self,forKey:.name) ?? "Master"
    sourceObjectID=try c.decode(UUID.self,forKey:.sourceObjectID);x=try c.decodeIfPresent(Double.self,forKey:.x) ?? 0;y=try c.decodeIfPresent(Double.self,forKey:.y) ?? 0
    side=try c.decodeIfPresent(PublicationMasterSide.self,forKey:.side) ?? .all;behind=try c.decodeIfPresent(Bool.self,forKey:.behind) ?? false
  }
}
public struct PublicationSpread:Codable,Equatable,Identifiable,Sendable {
  public var id:UUID
  public var pages:[PublicationPage]
  public var left:PublicationPage?
  public var right:PublicationPage?
}
public struct PublicationLeafPair:Codable,Equatable,Identifiable,Sendable {
  public var id:UUID
  public var front:PublicationPage?
  public var back:PublicationPage?
}

extension PublicationDocument {
  public var requiresExtendedPublicationSchema:Bool {
    layout != nil || numbering != nil || masters != nil || pages.contains{$0.spreadID != nil || $0.numberOverride != nil || $0.chapterTitle != nil || $0.masterIDs != nil}
  }
  public func side(of objectID:UUID)->PublicationPageSide? {
    guard let index=pages.firstIndex(where:{$0.objectID==objectID}) else{return nil}
    return (index+(layout?.firstPageSide == .verso ? 1:0))%2==0 ? .recto:.verso
  }
  public func spreads()->[PublicationSpread] {
    var result:[PublicationSpread]=[],i=0
    while i<pages.count {
      let first=pages[i];var group=[first]
      if layout?.facingPages==true {
        if let explicit=first.spreadID {
          while i+group.count<pages.count,pages[i+group.count].spreadID==explicit {group.append(pages[i+group.count])}
        }else if side(of:first.objectID) == .verso,i+1<pages.count,pages[i+1].spreadID==nil {group.append(pages[i+1])}
      }
      result.append(.init(id:first.spreadID ?? ComponentCommands.derivedID(id,first.id),pages:group,
        left:group.first{side(of:$0.objectID) == .verso},right:group.first{side(of:$0.objectID) == .recto}))
      i+=group.count
    }
    return result
  }
  public func leafPairs()->[PublicationLeafPair] {
    var result:[PublicationLeafPair]=[],front:PublicationPage?
    for page in pages {
      if side(of:page.objectID) == .recto {front=page}
      else {result.append(.init(id:ComponentCommands.derivedID(id,front?.id ?? page.id),front:front,back:page));front=nil}
    }
    if let front {result.append(.init(id:ComponentCommands.derivedID(id,front.id),front:front,back:nil))}
    return result
  }
  public func resolvedMargins(for objectID:UUID)->PublicationMargins {
    guard let page=pages.first(where:{$0.objectID==objectID}) else{return margins}
    if let explicit=page.margins {return explicit}
    guard let layout,layout.facingPages else{return margins}
    var value=margins
    if side(of:objectID) == .recto {value.left=layout.innerMargin ?? value.left;value.right=layout.outerMargin ?? value.right}
    else{value.left=layout.outerMargin ?? value.left;value.right=layout.innerMargin ?? value.right}
    return value
  }
  public func pageNumber(for objectID:UUID)->String? {
    var number=numbering?.start ?? 1
    for page in pages {
      if let explicit=page.numberOverride {number=explicit}
      if page.objectID==objectID {return (numbering ?? .init()).formatted(number)}
      number+=1
    }
    return nil
  }
  public func pageLabel(for objectID:UUID)->String? {pages.first{$0.objectID==objectID}?.label ?? pageNumber(for:objectID)}
  public func chapterTitle(for objectID:UUID)->String? {
    var current:String?
    for page in pages {if let title=page.chapterTitle {current=title};if page.objectID==objectID {return current}}
    return nil
  }
  public func appliedMasters(for objectID:UUID)->[PublicationMaster] {
    guard let page=pages.first(where:{$0.objectID==objectID}) else{return []}
    return (masters ?? []).filter{master in
      if let ids=page.masterIDs {return ids.contains(master.id)}
      return master.side == .all || master.side.rawValue==side(of:objectID)?.rawValue
    }
  }
  public func validateLayout()throws {
    guard layout?.valid != false,numbering?.valid != false,(masters?.count ?? 0)<=32,
      Set((masters ?? []).map(\.id)).count==(masters?.count ?? 0) else{throw FormError.invalid("Use finite publication margins, bounded numbering and up to 32 distinct master sources.")}
    let masterIDs=Set((masters ?? []).map(\.id))
    for page in pages {
      guard page.numberOverride.map({(1...999_999).contains($0)}) != false,(page.chapterTitle?.count ?? 0)<=500,
        page.masterIDs.map({Set($0).count==$0.count && Set($0).isSubset(of:masterIDs)}) != false else{throw FormError.invalid("Use a bounded page number/chapter title and distinct existing master IDs.")}
    }
    if pages.contains(where:{$0.spreadID != nil}) {
      guard layout?.facingPages==true else{throw FormError.invalid("Explicit spread groups require facing pages.")}
      var seen=Set<UUID>()
      for spread in spreads() where spread.pages.first?.spreadID != nil {
        guard seen.insert(spread.id).inserted,spread.pages.count<=2,
          spread.pages.count==1 || (side(of:spread.pages[0].objectID) == .verso && side(of:spread.pages[1].objectID) == .recto) else{
          throw FormError.invalid("A spread groups one page or consecutive verso/recto pages; a group cannot recur later in the sequence.")
        }
      }
    }
  }
}

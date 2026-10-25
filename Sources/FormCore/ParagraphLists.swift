import Foundation

/// Paragraph identity and list structure belong to source text, not a character style.
public struct ParagraphListItem: Codable, Equatable, Identifiable, Sendable {
  public enum Marker: String, Codable, CaseIterable, Sendable { case bullet, decimal }
  public var id: UUID
  public var location: Int
  public var listID: UUID
  public var marker: Marker
  public var level: Int
  public var restart: Int?
  public var fontName: String?
  /// Derived within a document for rendering; never saved as paragraph structure.
  public var resolvedNumber: Int? = nil
  private enum CodingKeys:String,CodingKey {case id,location,listID,marker,level,restart,fontName}
  public init(id:UUID=UUID(),location:Int,listID:UUID=UUID(),marker:Marker = .bullet,level:Int=0,restart:Int?=nil,fontName:String?=nil) {
    self.id=id;self.location=location;self.listID=listID;self.marker=marker;self.level=level;self.restart=restart;self.fontName=fontName
  }
  public var indent:Double {24+Double(level)*18}
}

extension Artwork {
  public var resolvingLists:Self {
    guard elements.contains(where:{$0.listItems?.isEmpty == false}) else{return self}
    let values=ParagraphLists.numbers(elements.flatMap{($0.listItems ?? []).sorted{$0.location<$1.location}})
    var result=self
    for i in result.elements.indices {for j in result.elements[i].listItems?.indices ?? 0..<0 {
      let id=result.elements[i].listItems![j].id
      result.elements[i].listItems![j].resolvedNumber=values[id]
    }}
    return result
  }
}
extension ArtworkElement {
  public var withBakedListNumbers:Self {
    var result=self
    for i in result.listItems?.indices ?? 0..<0 {
      if let number=result.listItems![i].resolvedNumber {result.listItems![i].restart=number;result.listItems![i].resolvedNumber=nil}
    }
    return result
  }
}

public enum ListCommands {
  public static func edit(_ art:inout Artwork,ids:Set<UUID>,arguments:[String:Any]) throws {
    let targets=art.swatchPaintTargets(for:ids)
    let indices=art.elements.indices.filter{targets.contains(art.elements[$0].id) && art.elements[$0].kind=="text"}
    guard !indices.isEmpty,indices.allSatisfy({!art.isLocked(art.elements[$0])}),
      (arguments["location"]==nil)==(arguments["length"]==nil),
      arguments["location"]==nil || (indices.count==1 && arguments["location"] is Int && arguments["length"] is Int) else {
      throw FormError.invalid("Choose unlocked text; a list paragraph range requires one text object.")
    }
    let rawMarker=arguments["marker"] as? String ?? "bullet"
    for name in ["marker","list_action","marker_font"] where arguments[name] != nil {
      guard arguments[name] is String else{throw FormError.invalid("\(name) must be text.")}
    }
    for name in ["level","restart"] where arguments[name] != nil {
      guard arguments[name] is Int else{throw FormError.invalid("\(name) must be an integer.")}
    }
    guard let marker=ParagraphListItem.Marker(rawValue:rawMarker) else {throw FormError.invalid("Supported list markers are bullet and decimal.")}
    var identity:UUID?
    if let raw=arguments["list_id"] {
      guard let value=raw as? String,let uuid=UUID(uuidString:value) else{throw FormError.invalid("Use a valid list_id UUID for continuation.")};identity=uuid
    }
    let action=arguments["list_action"] as? String ?? "set"
    if identity==nil,action=="set" {identity=indices.compactMap{art.elements[$0].listItems?.first?.listID}.first ?? UUID()}
    let range=(arguments["location"] as? Int).map{NSRange(location:$0,length:arguments["length"] as! Int)}
    for i in indices {
      var e=art.elements[i]
      try ParagraphLists.edit(&e.listItems,text:e.text,range:range,action:action,marker:marker,listID:identity,
        level:arguments["level"] as? Int,restart:arguments["restart"] as? Int,fontName:arguments["marker_font"] as? String)
      art.elements[i]=e
    }
  }
}

public enum ParagraphLists {
  public static func ranges(in text:String)->[NSRange] {
    let string=text as NSString
    if string.length==0 {return [NSRange(location:0,length:0)]}
    var result:[NSRange]=[],offset=0
    while offset<string.length {
      let range=string.paragraphRange(for:NSRange(location:offset,length:0))
      guard range.length>0 else{break}
      result.append(range);offset=NSMaxRange(range)
    }
    if let last=text.unicodeScalars.last,CharacterSet.newlines.contains(last) {result.append(NSRange(location:string.length,length:0))}
    return result
  }
  public static func selectedParagraphs(in text:String,range:NSRange?)->[NSRange] {
    let all=ranges(in:text);guard let range else{return all}
    if range.length==0 {return all.filter{$0.location<=range.location && (NSMaxRange($0)>range.location || $0.length==0 && $0.location==range.location)}}
    return all.filter{NSIntersectionRange($0,range).length>0}
  }
  public static func validate(_ items:[ParagraphListItem]?,text:String) throws {
    guard let items else{return}
    let starts=Set(ranges(in:text).map(\.location))
    guard items.count<=10000,Set(items.map(\.id)).count==items.count,Set(items.map(\.location)).count==items.count,
      items.allSatisfy({starts.contains($0.location) && (0...5).contains($0.level)
        && ($0.restart == nil || (1...999999).contains($0.restart!))
        && ($0.fontName == nil || (!$0.fontName!.isEmpty && $0.fontName!.count<=300))}) else {
      throw FormError.invalid("Lists need unique paragraph identities at paragraph starts, nesting levels 0–5, and restart values 1–999999.")
    }
  }
  public static func edit(_ items:inout [ParagraphListItem]?,text:String,range:NSRange?=nil,
    action:String="set",marker:ParagraphListItem.Marker = .bullet,listID:UUID?=nil,level:Int?=nil,restart:Int?=nil,fontName:String?=nil) throws {
    if let range {
      let count=text.utf16.count
      guard range.location>=0,range.length>=0,range.location<=count,range.length<=count-range.location,Range(range,in:text) != nil else {
        throw FormError.invalid("Choose a valid UTF-16 paragraph range.")
      }
    }
    guard ["set","remove","indent","outdent","restart","continue"].contains(action),
      level == nil || (0...5).contains(level!),restart == nil || (1...999999).contains(restart!) else {
      throw FormError.invalid("Use list set/remove/indent/outdent/restart/continue with a level from 0 through 5.")
    }
    let selected=selectedParagraphs(in:text,range:range),starts=Set(selected.map(\.location))
    var result=items ?? []
    if action=="remove" {result.removeAll{starts.contains($0.location)}}
    else {
      let identity=listID ?? result.first(where:{starts.contains($0.location)})?.listID ?? UUID()
      for (offset,paragraph) in selected.enumerated() {
        let existing=result.firstIndex{$0.location==paragraph.location}
        if action != "set",existing==nil {throw FormError.invalid("Choose existing list paragraphs for \(action).")}
        var item=existing.map{result[$0]} ?? ParagraphListItem(location:paragraph.location,listID:identity,marker:marker)
        switch action {
        case "indent":item.level=min(5,item.level+1)
        case "outdent":item.level=max(0,item.level-1)
        case "restart":item.restart=offset==0 ? (restart ?? 1):nil
        case "continue":item.listID=identity;item.restart=nil
        default:
          item.marker=marker;item.listID=identity;item.level=level ?? item.level
          if offset==0,let restart {item.restart=restart}
          if let fontName {item.fontName=fontName.isEmpty ? nil:fontName}
        }
        if let existing {result[existing]=item}else{result.append(item)}
      }
    }
    result.sort{$0.location<$1.location};try validate(result,text:text);items=result.isEmpty ? nil:result
  }
  /// Pass paragraphs in declared artwork element order, then source order.
  /// Counters are shared by list identity and nesting level across text objects.
  public static func numbers(_ items:[ParagraphListItem])->[UUID:Int] {
    struct Counter:Hashable {var list:UUID;var level:Int}
    var counts:[Counter:Int]=[:],result:[UUID:Int]=[:]
    for item in items where item.marker == .decimal {
      let key=Counter(list:item.listID,level:item.level)
      let number=item.restart ?? (counts[key].map{$0+1} ?? 1)
      counts[key]=number;result[item.id]=number
      for nested in counts.keys where nested.list==item.listID && nested.level>item.level {counts[nested]=nil}
    }
    return result
  }
}

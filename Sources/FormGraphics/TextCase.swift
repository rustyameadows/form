import AppKit
import FormCore

/// One shared provenance record avoids splitting glyph runs or ligatures.
/// It exists only in native attributed text; documents persist source words.
@MainActor public enum TextCase {
  public static let sourceKey=NSAttributedString.Key("studio.form.caseSource")
  private static func converted(_ text:String,_ treatment:String,locale:Locale?=nil)->String {
    if let locale {return treatment=="uppercase" ? text.uppercased(with:locale):text.lowercased(with:locale)}
    return treatment=="uppercase" ? (text as NSString).uppercased : (text as NSString).lowercased
  }
  public struct Piece:Codable,Equatable {public var source:NSRange,display:NSRange}
  private struct Record:Codable {var source:String,display:String,pieces:[Piece];var sourceArchive:Data?}
  public struct Source {
    public let text:NSAttributedString
    public let pieces:[Piece]
    public func sourceRange(_ range:NSRange)->NSRange {mapped(range,forward:false)}
    public func displayRange(_ range:NSRange)->NSRange {mapped(range,forward:true)}
    private func mapped(_ range:NSRange,forward:Bool)->NSRange {
      func offset(_ position:Int,upper:Bool)->Int {
        for piece in pieces {
          let from=forward ? piece.source : piece.display,to=forward ? piece.display : piece.source
          if position>=from.location && position<=NSMaxRange(from) {
            if from.length==to.length {return to.location+position-from.location}
            if position==from.location {return to.location}
            if position==NSMaxRange(from) {return NSMaxRange(to)}
            return upper ? NSMaxRange(to) : to.location
          }
        }
        return forward ? (pieces.last.map{NSMaxRange($0.display)} ?? 0) : text.length
      }
      if range.length==0 {return NSRange(location:offset(range.location,upper:true),length:0)}
      let start=offset(range.location,upper:false),end=offset(NSMaxRange(range),upper:true)
      return NSRange(location:start,length:max(0,end-start))
    }
  }
  private static func record(_ data:Any?)->Record? {
    guard let data=data as? Data,data.count<=4_000_000,let record=try? JSONDecoder().decode(Record.self,from:data),
      (record.sourceArchive?.count ?? 0)<=2_000_000 else{return nil}
    let sourceLength=record.source.utf16.count,displayLength=record.display.utf16.count
    var source=0,display=0
    for piece in record.pieces {
      guard piece.source.location==source,piece.display.location==display,
        piece.source.length>0,piece.display.length>0,
        piece.source.length<=sourceLength-source,
        piece.display.length<=displayLength-display else{return nil}
      source+=piece.source.length;display+=piece.display.length
    }
    return source==sourceLength && display==displayLength ? record : nil
  }
  public static func source(_ input:NSAttributedString,reference:NSAttributedString?=nil,editedRange:NSRange?=nil)->Source {
    var records:[Record]=[]
    var completeRecord:Record?
    input.enumerateAttribute(sourceKey,in:NSRange(location:0,length:input.length)) {data,range,_ in
      if range.length==input.length,let value=record(data),value.display==input.string {completeRecord=value}
      if let value=record(data) {records.append(value)}
    }
    let oldReference=reference.flatMap{ref in ref.length>0 ? record(ref.attribute(sourceKey,at:0,effectiveRange:nil)) : nil}
    let root=completeRecord
      ?? oldReference.flatMap{old in records.first{$0.source==old.source && $0.display==old.display}}
      ?? records.max{$0.display.utf16.count<$1.display.utf16.count}
    let result=NSMutableAttributedString(string:"")
    var pieces:[Piece]=[]
    @MainActor func raw(_ range:NSRange) {
      guard range.length>0 else{return}
      let copy=NSMutableAttributedString(attributedString:input.attributedSubstring(from:range))
      copy.removeAttribute(sourceKey,range:NSRange(location:0,length:copy.length))
      pieces.append(.init(source:NSRange(location:result.length,length:copy.length),display:range));result.append(copy)
    }
    guard let root else {raw(NSRange(location:0,length:input.length));return Source(text:result,pieces:pieces)}
    let original=root.source as NSString,old=root.display as NSString,current=input.string as NSString
    let archived=root.sourceArchive.flatMap{try? NSKeyedUnarchiver.unarchivedObject(ofClass:NSAttributedString.self,from:$0)}
    @MainActor func characterAttributes(_ at:Int)->NSDictionary {
      var attrs=input.attributes(at:at,effectiveRange:nil)
      let spacing=(attrs[TypographyEngine.spacingKey] as? NSNumber)?.doubleValue ?? 0
      let key:NSAttributedString.Key=attrs[.tracking] != nil ? .tracking : .kern
      attrs[key]=((attrs[key] as? NSNumber)?.doubleValue ?? 0)-spacing
      attrs.removeValue(forKey:TypographyEngine.spacingKey);attrs.removeValue(forKey:TypographyEngine.pairKey)
      return attrs as NSDictionary
    }
    @MainActor func restored(_ range:NSRange,shift:Int) {
      for piece in root.pieces {
        let part=NSIntersectionRange(range,piece.display)
        guard part.length>0 else{continue}
        let displayed=NSRange(location:part.location+shift,length:part.length)
        if piece.source.length==piece.display.length {
          let sourceRange=NSRange(location:piece.source.location+part.location-piece.display.location,length:part.length)
          let copy=NSMutableAttributedString(string:original.substring(with:sourceRange))
          input.enumerateAttributes(in:displayed) {attrs,sub,_ in
            var attrs=attrs;attrs.removeValue(forKey:sourceKey)
            copy.setAttributes(attrs,range:NSRange(location:sub.location-displayed.location,length:sub.length))
          }
          pieces.append(.init(source:NSRange(location:result.length,length:copy.length),display:displayed));result.append(copy)
        } else if part==piece.display {
          let uniform=(displayed.location..<NSMaxRange(displayed)).allSatisfy{characterAttributes($0).isEqual(characterAttributes(displayed.location))}
          guard uniform else {raw(displayed);continue}
          var attrs=input.attributes(at:displayed.location,effectiveRange:nil);attrs.removeValue(forKey:sourceKey)
          for key in [TypographyEngine.pairKey,TypographyEngine.spacingKey,.kern,.tracking] {
            attrs[key]=input.attribute(key,at:NSMaxRange(displayed)-1,effectiveRange:nil)
          }
          let start=result.length
          if let archived,NSMaxRange(piece.source)<=archived.length {
            let recovered=NSMutableAttributedString(attributedString:archived.attributedSubstring(from:piece.source))
            let base=recovered.attributes(at:0,effectiveRange:nil)
            for key in Set(base.keys).union(attrs.keys) where key != sourceKey {
              let a=base[key] as? NSObject,b=attrs[key] as? NSObject
              guard !(a==nil && b==nil),a?.isEqual(b) != true else {continue}
              if key == NSAttributedString.Key("studio.form.typography"),let old=base[key] as? Data,let new=attrs[key] as? Data,
                let oldJSON=try? JSONSerialization.jsonObject(with:old) as? [String:Any],let newJSON=try? JSONSerialization.jsonObject(with:new) as? [String:Any] {
                let changed=Set(oldJSON.keys).union(newJSON.keys).filter {name in
                  let x=oldJSON[name] as? NSObject,y=newJSON[name] as? NSObject
                  return !(x==nil && y==nil) && x?.isEqual(y) != true
                }
                var updates:[(NSRange,Data)]=[]
                recovered.enumerateAttribute(key,in:NSRange(location:0,length:recovered.length)) {raw,range,_ in
                  guard let raw=raw as? Data,var values=try? JSONSerialization.jsonObject(with:raw) as? [String:Any] else{return}
                  for name in changed {values[name]=newJSON[name]}
                  if let json=try? JSONSerialization.data(withJSONObject:values),
                    let style=try? JSONDecoder.form.decode(Typography.self,from:json),
                    let data=try? JSONEncoder.form.encode(style) {updates.append((range,data))}
                }
                for (range,data) in updates {recovered.addAttribute(key,value:data,range:range)}
              } else if let value=attrs[key] {recovered.addAttribute(key,value:value,range:NSRange(location:0,length:recovered.length))}
              else {recovered.removeAttribute(key,range:NSRange(location:0,length:recovered.length))}
            }
            result.append(recovered)
          } else {result.append(NSAttributedString(string:original.substring(with:piece.source),attributes:attrs))}
          pieces.append(.init(source:NSRange(location:start,length:piece.source.length),display:displayed))
        } else {raw(displayed)}
      }
    }
    if old.isEqual(to:input.string) {restored(NSRange(location:0,length:old.length),shift:0);return Source(text:result,pieces:pieces)}
    var prefix=0,oldEnd=old.length
    if let editedRange,editedRange.location<=old.length,editedRange.length<=old.length-editedRange.location {
      prefix=editedRange.location;oldEnd=NSMaxRange(editedRange)
    } else {
      while prefix<min(old.length,current.length) && old.character(at:prefix)==current.character(at:prefix) {prefix+=1}
      var suffix=0
      while suffix<min(old.length-prefix,current.length-prefix) && old.character(at:old.length-1-suffix)==current.character(at:current.length-1-suffix) {suffix+=1}
      oldEnd=old.length-suffix
    }
    for piece in root.pieces where piece.source.length != piece.display.length {
      if prefix>piece.display.location && prefix<NSMaxRange(piece.display) {prefix=piece.display.location}
      if oldEnd>piece.display.location && oldEnd<NSMaxRange(piece.display) {oldEnd=NSMaxRange(piece.display)}
    }
    // NSString edits can expose one half of a scalar while calculating the diff.
    if prefix>0 && prefix<old.length && (0xDC00...0xDFFF).contains(old.character(at:prefix)) {prefix-=1}
    if oldEnd<old.length && (0xDC00...0xDFFF).contains(old.character(at:oldEnd)) {oldEnd+=1}
    let shift=current.length-old.length,newEnd=oldEnd+shift
    restored(NSRange(location:0,length:prefix),shift:0)
    if newEnd>prefix {
      input.enumerateAttribute(sourceKey,in:NSRange(location:prefix,length:newEnd-prefix)) {data,range,_ in
        if let inserted=record(data),inserted.display==(current.substring(with:range)) {
          let decoded=source(input.attributedSubstring(from:range))
          let start=result.length;result.append(decoded.text)
          for part in decoded.pieces {pieces.append(.init(source:NSRange(location:start+part.source.location,length:part.source.length),display:NSRange(location:range.location+part.display.location,length:part.display.length)))}
        } else {raw(range)}
      }
    }
    restored(NSRange(location:oldEnd,length:old.length-oldEnd),shift:shift)
    return Source(text:result,pieces:pieces)
  }
  public static func expandedDisplayRange(_ range:NSRange,in text:NSAttributedString)->NSRange {
    let recovered=source(text);return recovered.displayRange(recovered.sourceRange(range))
  }
  public static func displaying(_ source:NSAttributedString,preservingSource:Bool=true,
    localeAt:((Int)->Locale?)?=nil,caseAt:(Int)->String)->NSAttributedString {
    if !preservingSource,source.length>0 {
      var range=NSRange()
      var attrs=source.attributes(at:0,effectiveRange:&range)
      if range.length==source.length,attrs[TypographyEngine.pairKey]==nil {
        let treatment=caseAt(0)
        attrs.removeValue(forKey:sourceKey)
        return NSAttributedString(string:treatment=="uppercase" || treatment=="lowercase" ? converted(source.string,treatment,locale:localeAt?(0)) : source.string,attributes:attrs)
      }
    }
    let output=NSMutableAttributedString(string:"")
    let string=source.string as NSString
    var pieces:[Piece]=[],start=0,needsArchive=false
    @MainActor func append(_ text:NSAttributedString,_ range:NSRange) {
      let display=NSRange(location:output.length,length:text.length)
      output.append(text)
      guard preservingSource else{return}
      if let last=pieces.last,last.source.length==last.display.length,range.length==display.length,
        NSMaxRange(last.source)==range.location {
        pieces[pieces.count-1].source.length+=range.length;pieces[pieces.count-1].display.length+=display.length
      } else {pieces.append(.init(source:range,display:display))}
    }
    while start<source.length {
      let treatment=caseAt(start)
      let locale=localeAt?(start)
      var end=start+1
      while end<source.length && caseAt(end)==treatment && localeAt?(end)==locale {end+=1}
      let range=NSRange(location:start,length:end-start)
      guard treatment=="uppercase" || treatment=="lowercase" else {append(source.attributedSubstring(from:range),range);start=end;continue}
      let original=string.substring(with:range)
      let converted=converted(original,treatment,locale:locale)
      var scalars=original.unicodeScalars.map(String.init)
      var lengths=scalars.map{Self.converted($0,treatment,locale:locale).utf16.count}
      if lengths.reduce(0,+) != converted.utf16.count {
        needsArchive=true
        scalars=original.map(String.init);lengths=scalars.map{Self.converted($0,treatment,locale:locale).utf16.count}
        if lengths.reduce(0,+) != converted.utf16.count {scalars=[original];lengths=[converted.utf16.count]}
      }
      let contextual=converted as NSString,useContext=lengths.reduce(0,+)==contextual.length
      var sourceIndex=start,displayIndex=0
      for (scalar,length) in zip(scalars,lengths) {
        let rendered=useContext ? contextual.substring(with:NSRange(location:displayIndex,length:length)) : Self.converted(scalar,treatment,locale:locale)
        let range=NSRange(location:sourceIndex,length:scalar.utf16.count)
        if scalar==rendered {append(source.attributedSubstring(from:range),range)}
        else {
          var attrs=source.attributes(at:sourceIndex,effectiveRange:nil);attrs.removeValue(forKey:sourceKey)
          for key in [TypographyEngine.pairKey,TypographyEngine.spacingKey,.kern,.tracking] {attrs[key]=source.attribute(key,at:NSMaxRange(range)-1,effectiveRange:nil)}
          let pair=attrs.removeValue(forKey:TypographyEngine.pairKey),spacing=attrs[TypographyEngine.spacingKey]
          let key:NSAttributedString.Key=attrs[.tracking] != nil ? .tracking : .kern,tracking=attrs[key]
          if let amount=(pair as? NSNumber)?.doubleValue {attrs[key]=((tracking as? NSNumber)?.doubleValue ?? 0)-amount;attrs[TypographyEngine.spacingKey]=((spacing as? NSNumber)?.doubleValue ?? 0)-amount}
          let part=NSMutableAttributedString(string:rendered,attributes:attrs)
          if let pair,!rendered.isEmpty {
            let last=NSRange(location:part.length-1,length:1);part.addAttribute(TypographyEngine.pairKey,value:pair,range:last)
            if let spacing {part.addAttribute(TypographyEngine.spacingKey,value:spacing,range:last)}
            if let tracking {part.addAttribute(key,value:tracking,range:last)}
          }
          append(part,range)
        }
        sourceIndex+=scalar.utf16.count;displayIndex+=length
      }
      start=end
    }
    output.removeAttribute(sourceKey,range:NSRange(location:0,length:output.length))
    if preservingSource,source.string != output.string {
      let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
      let archive=needsArchive ? try? NSKeyedArchiver.archivedData(withRootObject:source,requiringSecureCoding:true):nil
      if let data=try? encoder.encode(Record(source:source.string,display:output.string,pieces:pieces,sourceArchive:archive)) {
        output.addAttribute(sourceKey,value:data,range:NSRange(location:0,length:output.length))
      }
    }
    return output
  }
}

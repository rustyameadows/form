import AppKit
import CoreText
import CryptoKit
import FormCore

public struct GlyphOption: Identifiable, Sendable {
  public var id:Int {glyph.glyphID}
  public var glyph:FontGlyph
  public var label:String
  public var featureType:Int?
  public var selector:Int?
  public var current:Bool=false
  public var advance:Double
  public var bounds:CGRect
  public var outlineAvailable:Bool
  public var json:[String:Any] {
    var value:[String:Any]=["glyph":(try? jsonObject(glyph)) ?? [:],"label":label,"current":current,
      "advance_em":advance,"bounds_em":["x":bounds.minX,"y":bounds.minY,"width":bounds.width,"height":bounds.height],"outline_available":outlineAvailable]
    if let featureType {value["feature_type"]=featureType}
    if let selector {value["selector"]=selector}
    return value
  }
}

public struct GlyphPage {
  public var fontName:String, signature:String
  public var glyphCount:Int, total:Int, offset:Int, limit:Int
  public var options:[GlyphOption]
  public var json:[String:Any] {
    ["font_name":fontName,"font_signature":signature,"glyph_count":glyphCount,"total":total,
      "offset":offset,"limit":limit,"glyphs":options.map(\.json)]
  }
}

@MainActor public enum GlyphCatalog {
  private final class Face {
    let font:NSFont,count:Int,signature:String
    var names:[Int:String]=[:]
    init(_ font:NSFont) {
      self.font=font;count=min(65536,CTFontGetGlyphCount(font as CTFont))
      var hash=SHA256();hash.update(data:Data(font.fontName.utf8))
      // Core Text returns unboxed integer tags, not CFNumber objects.
      let tables = CTFontCopyAvailableTables(font as CTFont, [])
      let tags: [UInt32] = tables.map { table in
        (0..<CFArrayGetCount(table)).map { UInt32(UInt(bitPattern: CFArrayGetValueAtIndex(table, $0))) }.sorted()
      } ?? []
      for tag in tags {
        if let table=CTFontCopyTable(font as CTFont,tag,[]) {
          var label=tag.bigEndian;withUnsafeBytes(of:&label){hash.update(data:Data($0))};hash.update(data:table as Data)
        }
      }
      signature=hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    func name(_ id:Int)->String? {
      if let name=names[id] {return name.isEmpty ? nil : name}
      let name=CTFontCopyNameForGlyph(font as CTFont,CGGlyph(id)) as String? ?? ""
      names[id]=name;return name.isEmpty ? nil : name
    }
  }
  private final class Alternatives {let value:[GlyphOption];init(_ value:[GlyphOption]){self.value=value}}
  private static let faces:NSCache<NSString,Face> = {let c=NSCache<NSString,Face>();c.countLimit=32;c.totalCostLimit=16_000_000;return c}()
  private static let alternatives:NSCache<NSString,Alternatives> = {let c=NSCache<NSString,Alternatives>();c.countLimit=128;c.totalCostLimit=4_000_000;return c}()
  private static let aliases:NSCache<NSString,NSString> = {let c=NSCache<NSString,NSString>();c.countLimit=256;c.totalCostLimit=64_000;return c}()
  private static let baseNames:NSCache<NSString,NSString> = {let c=NSCache<NSString,NSString>();c.countLimit=128;c.totalCostLimit=64_000;return c}()
  private static var builds=0,hits=0
  public static func invalidate(){faces.removeAllObjects();alternatives.removeAllObjects();aliases.removeAllObjects();baseNames.removeAllObjects();GlyphEngine.invalidate()}
  /// Variable instances synthesize PostScript names. Pin glyph IDs to the file's default face.
  public static func canonicalName(_ font:NSFont)->String {
    if let name=aliases.object(forKey:font.fontName as NSString) {return name as String}
    let ct=font as CTFont
    guard let axes=CTFontCopyVariationAxes(ct) as? [[String:Any]],!axes.isEmpty,
      let unique=CTFontCopyName(ct,kCTFontUniqueNameKey) as String?,
      let url=CTFontCopyAttribute(ct,kCTFontURLAttribute) as? URL else {
      aliases.setObject(font.fontName as NSString,forKey:font.fontName as NSString,cost:160+font.fontName.utf16.count*4)
      return font.fontName
    }
    let key="\(url.path)|\(unique)" as NSString
    let base:String
    if let cached=baseNames.object(forKey:key) {base=cached as String}
    else {
      let defaults=axes.compactMap { axis -> (Int,Double,Double)? in
        guard let id=axis[kCTFontVariationAxisIdentifierKey as String] as? Int,
          let value=axis[kCTFontVariationAxisDefaultValueKey as String] as? Double,
          let low=axis[kCTFontVariationAxisMinimumValueKey as String] as? Double,
          let high=axis[kCTFontVariationAxisMaximumValueKey as String] as? Double else {return nil}
        return(id,value,max(1e-8,high-low))
      }
      let descriptors=CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
      var found:(String,Double)?
      for descriptor in descriptors {
        let candidate=CTFontCreateWithFontDescriptor(descriptor,12,nil)
        guard CTFontCopyName(candidate,kCTFontUniqueNameKey) as String? == unique else {continue}
        let values=CTFontCopyVariation(candidate) as? [Int:Double] ?? [:]
        let score=defaults.reduce(0.0) { $0+abs((values[$1.0] ?? $1.1)-$1.1)/$1.2 }
        if found==nil || score<found!.1 {found=(CTFontCopyPostScriptName(candidate) as String,score)}
      }
      base=found?.0 ?? font.fontName
      baseNames.setObject(base as NSString,forKey:key,cost:key.length*2+base.utf16.count*2)
    }
    aliases.setObject(base as NSString,forKey:font.fontName as NSString,cost:160+font.fontName.utf16.count*2)
    return base
  }
  public static var diagnostics:[String:Any]{["glyph_catalog_builds":builds,"glyph_catalog_hits":hits,"glyph_face_limit":32,"glyph_alternate_limit":128]}
  private static func face(_ name:String)throws->Face {
    if let cached=faces.object(forKey:name as NSString){hits+=1;return cached}
    guard let font=NSFont(name:name,size:12) else{throw FormError.invalid("The font is not installed: \(name).")}
    let canonical=canonicalName(font)
    if let cached=faces.object(forKey:canonical as NSString){hits+=1;return cached}
    let base=NSFont(name:canonical,size:12) ?? font
    let value=Face(base)
    guard value.count > 1 else { throw FormError.invalid("This font has no usable glyph repertoire.") }
    faces.setObject(value,forKey:canonical as NSString,cost:max(1000,value.count*96));builds+=1;return value
  }
  public static func signature(_ name:String)throws->String {try face(name).signature}
  public static func glyph(fontName:String,id:Int)throws->FontGlyph {
    let entry=try face(fontName)
    guard id>0,id<entry.count else{throw FormError.invalid("Choose a glyph available in \(entry.font.fontName).")}
    let name=entry.name(id).flatMap{CTFontGetGlyphWithName(entry.font as CTFont,$0 as CFString)==id ? $0 : nil}
    return FontGlyph(fontName:entry.font.fontName,glyphID:id,glyphName:name,fontSignature:entry.signature)
  }
  public static func resolve(_ glyph:FontGlyph,font:NSFont)throws->CGGlyph {
    try GlyphCommands.validate(glyph)
    guard canonicalName(font)==glyph.fontName else{throw FormError.invalid("Glyph \(glyph.glyphName ?? String(glyph.glyphID)) belongs to \(glyph.fontName). Restore that face or clear the glyph choice.")}
    let entry=try face(glyph.fontName)
    if let name=glyph.glyphName {
      let resolved=CTFontGetGlyphWithName(font as CTFont,name as CFString)
      guard resolved>0 else{throw FormError.invalid("The selected glyph \(name) is unavailable in \(font.fontName).")}
      guard entry.signature != glyph.fontSignature || resolved==glyph.glyphID else{throw FormError.invalid("Glyph name and ID do not match this font.")}
      return resolved
    }
    guard entry.signature==glyph.fontSignature,glyph.glyphID<entry.count else{throw FormError.invalid("The font changed and this unnamed glyph needs review. Choose it again in the glyph palette.")}
    return CGGlyph(glyph.glyphID)
  }
  public static func option(font:NSFont,id:Int,label:String?=nil)throws->GlyphOption {
    let value=try glyph(fontName:font.fontName,id:id)
    var glyph=CGGlyph(id),bounds=CGRect.zero,advance=CGSize.zero
    CTFontGetBoundingRectsForGlyphs(font as CTFont,.default,&glyph,&bounds,1)
    CTFontGetAdvancesForGlyphs(font as CTFont,.default,&glyph,&advance,1)
    let size=font.pointSize
    let vector=CTFontCreatePathForGlyph(font as CTFont,glyph,nil) != nil || bounds.isEmpty
    return GlyphOption(glyph:value,label:label ?? value.glyphName ?? "Glyph \(id)",advance:advance.width/size,
      bounds:CGRect(x:bounds.minX/size,y:bounds.minY/size,width:bounds.width/size,height:bounds.height/size),outlineAvailable:vector)
  }
  public static func repertoire(fontName:String,query:String="",offset:Int=0,limit:Int=64)throws->[String:Any] {
    try page(fontName:fontName,query:query,offset:offset,limit:limit).json
  }
  public static func page(fontName:String,query:String="",offset:Int=0,limit:Int=64)throws->GlyphPage {
    let entry=try face(fontName)
    guard offset>=0,(1...128).contains(limit),query.count<=100 else{throw FormError.invalid("Use a nonnegative glyph offset, 1–128 results, and a search of at most 100 characters.")}
    let search=query.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
    var ids:[Int]
    if search.isEmpty {ids=Array(1..<entry.count)}
    else if let numeric=Int(search.hasPrefix("gid:") ? String(search.dropFirst(4)) : search) {ids=(1..<entry.count).contains(numeric) ? [numeric] : []}
    else {
      var unicodeID:Int?
      if search.hasPrefix("u+"),let scalar=UInt32(search.dropFirst(2),radix:16).flatMap(UnicodeScalar.init) {
        let code=Array(String(scalar).utf16);var mapped=[CGGlyph](repeating:0,count:code.count)
        CTFontGetGlyphsForCharacters(entry.font as CTFont,code,&mapped,code.count);unicodeID=mapped.first(where:{$0>0}).map(Int.init)
      }
      ids=(1..<entry.count).filter{$0==unicodeID || entry.name($0)?.localizedCaseInsensitiveContains(search)==true}
    }
    let page=ids.dropFirst(min(offset,ids.count)).prefix(limit)
    let displayFont=NSFont(name:fontName,size:12) ?? entry.font
    return GlyphPage(fontName:entry.font.fontName,signature:entry.signature,glyphCount:entry.count,
      total:ids.count,offset:offset,limit:limit,options:try page.map{try option(font:displayFont,id:$0)})
  }
  public static func alternates(fontName:String,text:String,range:NSRange,typography:Typography=Typography())throws->[GlyphOption] {
    _=try face(fontName)
    let source=text as NSString
    func boundary(_ i:Int)->Bool {
      i==0 || i==source.length || !(0xD800...0xDBFF).contains(source.character(at:i-1)) || !(0xDC00...0xDFFF).contains(source.character(at:i))
    }
    guard text.count<=10000,range.location>=0,range.length>0,range.length<=64,
      range.location<=source.length,range.length<=source.length-range.location,
      boundary(range.location),boundary(NSMaxRange(range)),
      Range(range,in:text) != nil,
      !source.substring(with:range).unicodeScalars.contains(where:{[0,9,10,11,12,13,0x85,0x2028,0x2029].contains($0.value)}) else{throw FormError.invalid("Select 1–64 UTF-16 units in the font's source text.")}
    var style=typography;style.fontName=fontName;try validateTypography(style)
    let before=source.substring(to:range.location).suffix(64),after=source.substring(from:NSMaxRange(range)).prefix(64)
    let context=String(before)+source.substring(with:range)+String(after),selected=NSRange(location:before.utf16.count,length:range.length)
    let keyData=try JSONSerialization.data(withJSONObject:["font":fontName,"signature":try signature(fontName),"text":context,"location":selected.location,"length":selected.length,"typography":try jsonObject(style)],options:.sortedKeys)
    let key=SHA256.hash(data:keyData).map{String(format:"%02x",$0)}.joined() as NSString
    if let value=alternatives.object(forKey:key){hits+=1;return value.value}
    func shaped(_ type:Typography)->(Int,NSFont)? {
      let source=NSAttributedString(string:context,attributes:TypographyEngine.attributes(type,size:48,color:"#000000",millimeters:false))
      let displayed=TypographyEngine.displayingCase(source),mapped=TextCase.source(displayed).displayRange(selected)
      let line=CTLineCreateWithAttributedString(displayed)
      var found:[(Int,NSFont)]=[]
      for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count=CTRunGetGlyphCount(run);var ids=[CGGlyph](repeating:0,count:count),positions=[CFIndex](repeating:0,count:count)
        CTRunGetGlyphs(run,CFRange(),&ids);CTRunGetStringIndices(run,CFRange(),&positions)
        let font=(CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as? NSFont ?? TypographyEngine.font(type,size:48)
        let runRange = CTRunGetStringRange(run)
        let boundaries = Array(Set(positions + [runRange.location + runRange.length])).sorted()
        for i in 0..<count where NSLocationInRange(positions[i],mapped) {
          let end = boundaries.first { $0 > positions[i] } ?? context.utf16.count
          // A ligature extending outside the selection is not an alternate for it.
          guard positions[i] == mapped.location, end == NSMaxRange(mapped) else { return nil }
          found.append((Int(ids[i]),font))
        }
      }
      guard found.count==1,found[0].0>0,found[0].1.fontName==TypographyEngine.font(type,size:48).fontName else{return nil}
      return found[0]
    }
    var result:[GlyphOption]=[],seen=Set<Int>()
    if let (id,font)=shaped(style) {var current=try option(font:font,id:id,label:"Current shaping");current.current=true;result.append(current);seen.insert(id)}
    let details=FontCatalog.details(fontName)
    for feature in details["features"] as? [[String:Any]] ?? [] {
      guard let type=feature["id"] as? Int else{continue}
      for selector in feature["selectors"] as? [[String:Any]] ?? [] {
        guard let id=selector["id"] as? Int else{continue}
        var changed=style
        if feature["exclusive"] as? Bool==true {changed.resetFeature(type);changed.features[type]=id}
        else {changed.setIndependentFeature(type,selector:id,value:id%2==0)}
        if let (glyph,font)=shaped(changed),seen.insert(glyph).inserted {
          var choice=try option(font:font,id:glyph,label:"\(feature["name"] as? String ?? "Feature") · \(selector["name"] as? String ?? "Alternate")")
          choice.featureType=type;choice.selector=id;result.append(choice)
        }
      }
    }
    alternatives.setObject(Alternatives(result),forKey:key,cost:max(500,result.count*500));builds+=1;return result
  }
}

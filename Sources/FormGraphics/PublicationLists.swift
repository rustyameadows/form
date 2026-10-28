import AppKit
import CoreText
import FormCore

/// Native interchange uses NSTextList; generated markers stay outside raw source.
public enum PublicationLists {
  public static let key=NSAttributedString.Key("studio.form.paragraphList")
  private final class MarkerKey:NSObject {
    let font:NSFont,text:String
    init(_ font:NSFont,_ text:String) {self.font=font;self.text=text}
    override var hash:Int {font.hash ^ text.hashValue}
    override func isEqual(_ object:Any?)->Bool {guard let other=object as? MarkerKey else{return false};return text==other.text && font.isEqual(other.font)}
  }
  private final class MarkerShape {let path:CGPath,width:Double;init(_ path:CGPath,_ width:Double){self.path=path;self.width=width}}
  private static let markerCache:NSCache<MarkerKey,MarkerShape> = {let value=NSCache<MarkerKey,MarkerShape>();value.countLimit=2048;return value}()
  public static func invalidateFonts() {markerCache.removeAllObjects()}
  private static func shape(_ text:String,font:NSFont)->MarkerShape {
    let key=MarkerKey(font,text);if let value=markerCache.object(forKey:key){return value}
    let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[.font:font])),path=CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
      let count=CTRunGetGlyphCount(run),raw=CTRunGetAttributes(run) as NSDictionary
      let face=raw[kCTFontAttributeName] as! CTFont
      var glyphs=[CGGlyph](repeating:0,count:count),positions=[CGPoint](repeating:.zero,count:count)
      CTRunGetGlyphs(run,CFRange(),&glyphs);CTRunGetPositions(run,CFRange(),&positions)
      for i in 0..<count {if let outline=CTFontCreatePathForGlyph(face,glyphs[i],nil) {
        path.addPath(outline,transform:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:positions[i].x,ty:-positions[i].y))
      }}
    }
    let value=MarkerShape(path,CTLineGetTypographicBounds(line,nil,nil,nil));markerCache.setObject(value,forKey:key);return value
  }
  public struct Record:Codable,Equatable {
    public var item:ParagraphListItem
    public var number:Int
    public init(_ item:ParagraphListItem,number:Int) {self.item=item;self.number=number}
  }
  public struct Ink {
    public var path:CGPath
    public var color:String
    public var swatchID:UUID?
    public var character:Int
  }
  public static func record(_ value:Any?)->Record? {
    (value as? Data).flatMap{try? JSONDecoder.form.decode(Record.self,from:$0)}
  }
  public static func data(_ record:Record)->Data? {try? JSONEncoder.form.encode(record)}
  public static func clear(in source:NSMutableAttributedString) {
    for range in ParagraphLists.ranges(in:source.string) where range.length>0 {
      guard source.attribute(key,at:range.location,effectiveRange:nil) != nil else{continue}
      let base=source.attribute(.paragraphStyle,at:range.location,effectiveRange:nil) as? NSParagraphStyle ?? .default
      let style=base.mutableCopy() as! NSMutableParagraphStyle
      let type=(source.attribute(NSAttributedString.Key("studio.form.typography"),at:range.location,effectiveRange:nil) as? Data)
        .flatMap{try? JSONDecoder.form.decode(Typography.self,from:$0)} ?? .init()
      style.headIndent=type.leftIndent;style.firstLineHeadIndent=type.firstLineIndent;style.tailIndent = -type.rightIndent;style.textLists=[]
      style.alignment=["left":NSTextAlignment.left,"right":.right,"center":.center,"justified":.justified][type.alignment] ?? .left
      source.addAttribute(.paragraphStyle,value:style,range:range)
    }
    source.removeAttribute(key,range:NSRange(location:0,length:source.length))
  }
  public static func nativeList(_ item:ParagraphListItem,number:Int)->NSTextList {
    let list=NSTextList(markerFormat:item.marker == .bullet ? .disc:.decimal,options:0)
    list.startingItemNumber=number;return list
  }
  public static func apply(_ items:[ParagraphListItem],to source:NSMutableAttributedString) {
    let local=ParagraphLists.numbers(items.sorted{$0.location<$1.location})
    for item in items where item.location>=0 && item.location<source.length {
      let range=(source.string as NSString).paragraphRange(for:NSRange(location:item.location,length:0))
      let number=item.resolvedNumber ?? local[item.id] ?? 1
      let record=Record(item,number:number)
      if let data=data(record) {source.addAttribute(key,value:data,range:range)}
      paragraphStyle(record,in:source,range:range)
    }
  }
  public static func paragraphStyle(_ record:Record,in source:NSMutableAttributedString,range:NSRange) {
    guard range.length>0,NSMaxRange(range)<=source.length else{return}
    let base=source.attribute(.paragraphStyle,at:range.location,effectiveRange:nil) as? NSParagraphStyle ?? .default
    let bodyFont=(source.attribute(CharacterTypography.markerFontKey,at:range.location,effectiveRange:nil) ?? source.attribute(.font,at:range.location,effectiveRange:nil)) as? NSFont ?? .systemFont(ofSize:14)
    let font=record.item.fontName.flatMap{NSFont(name:$0,size:bodyFont.pointSize)} ?? bodyFont
    let width=shape(marker(record),font:font).width
    let indent=max(record.item.indent,width+12+Double(record.item.level)*18)
    let type=(source.attribute(NSAttributedString.Key("studio.form.typography"),at:range.location,effectiveRange:nil) as? Data)
      .flatMap{try? JSONDecoder.form.decode(Typography.self,from:$0)} ?? .init()
    let rtl=base.baseWritingDirection == .rightToLeft || (base.baseWritingDirection == .natural && naturalRTL((source.string as NSString).substring(with:range)))
    let head=type.leftIndent+indent
    let first=head
    let tail = -type.rightIndent
    let alignment=rtl && type.alignment=="left" ? NSTextAlignment.right:(["left":NSTextAlignment.left,"right":.right,"center":.center,"justified":.justified][type.alignment] ?? base.alignment)
    let format:NSTextList.MarkerFormat=record.item.marker == .bullet ? .disc:.decimal
    if base.headIndent==head,base.firstLineHeadIndent==first,base.tailIndent==tail,base.alignment==alignment,base.textLists.count==1,
      base.textLists[0].markerFormat==format,base.textLists[0].startingItemNumber==record.number {return}
    let style=base.mutableCopy() as! NSMutableParagraphStyle
    style.headIndent=head;style.firstLineHeadIndent=first;style.tailIndent=tail;style.alignment=alignment
    style.textLists=[nativeList(record.item,number:record.number)]
    source.addAttribute(.paragraphStyle,value:style,range:range)
  }
  public static func items(from source:NSAttributedString,trailingAttributes:[NSAttributedString.Key:Any]?=nil)->[ParagraphListItem]? {
    var result:[ParagraphListItem]=[],seen=Set<UUID>()
    for range in ParagraphLists.ranges(in:source.string) {
      let attributes=range.location<source.length ? source.attributes(at:range.location,effectiveRange:nil):(trailingAttributes ?? [:])
      guard var record=record(attributes[key]) else{continue}
      if !seen.insert(record.item.id).inserted {record.item.id=UUID();seen.insert(record.item.id);record.item.restart=nil}
      record.item.location=range.location;record.item.resolvedNumber=nil;result.append(record.item)
    }
    return result.isEmpty ? nil:result
  }
  /// Canonicalize metadata after Return, deletion, paste, and reordering.
  /// Existing identities survive; a duplicated identity becomes a distinct item.
  public static func normalized(_ source:NSAttributedString)->NSAttributedString {
    let result=NSMutableAttributedString(attributedString:source)
    var items=items(from:source) ?? [],previous:[UUID:Int]=[:]
    source.enumerateAttribute(key,in:NSRange(location:0,length:source.length)) {value,_,_ in
      if let record=record(value) {previous[record.item.id]=record.number}
    }
    var counters:[String:Int]=[:]
    for i in items.indices where items[i].marker == .decimal {
      let group="\(items[i].listID)/\(items[i].level)"
      let number=items[i].restart ?? counters[group].map{$0+1} ?? previous[items[i].id] ?? 1
      items[i].resolvedNumber=number;counters[group]=number
      for nested in counters.keys.filter({$0.hasPrefix("\(items[i].listID)/") && (Int($0.split(separator:"/").last!) ?? 0)>items[i].level}) {counters[nested]=nil}
    }
    apply(items,to:result);return result
  }
  public static func marker(_ record:Record)->String {record.item.marker == .bullet ? "•":"\(record.number)."}

  /// Actual marker outlines in TextKit's flipped point coordinate space.
  public static func ink(layout:NSLayoutManager,glyphRange:NSRange)->[Ink] {
    guard let storage=layout.textStorage,storage.length>0 else{return []}
    var result:[Ink]=[],seen=Set<UUID>()
    storage.enumerateAttribute(key,in:NSRange(location:0,length:storage.length)) {value,range,_ in
      guard let record=record(value),seen.insert(record.item.id).inserted else{return}
      let paragraph=(storage.string as NSString).paragraphRange(for:NSRange(location:range.location,length:0))
      let glyph=layout.glyphIndexForCharacter(at:paragraph.location)
      guard glyph<layout.numberOfGlyphs,NSLocationInRange(glyph,glyphRange),let container=layout.textContainer(forGlyphAt:glyph,effectiveRange:nil) else{return}
      let attrs=storage.attributes(at:paragraph.location,effectiveRange:nil)
      let bodyFont=(attrs[CharacterTypography.markerFontKey] ?? attrs[.font]) as? NSFont ?? .systemFont(ofSize:14)
      let font=record.item.fontName.flatMap{NSFont(name:$0,size:bodyFont.pointSize)} ?? bodyFont
      let shape=shape(marker(record),font:font),width=shape.width
      let rect=layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil),position=layout.location(forGlyphAt:glyph)
      let baseline=rect.minY+position.y+((attrs[CharacterTypography.markerBaselineKey] as? NSNumber)?.doubleValue ?? 0)
      let style=attrs[.paragraphStyle] as? NSParagraphStyle ?? .default
      let rtl=style.baseWritingDirection == .rightToLeft || (style.baseWritingDirection == .natural && naturalRTL((storage.string as NSString).substring(with:paragraph)))
      let x=rtl ? container.size.width-style.headIndent+6:style.headIndent-6-width
      let path=CGMutablePath()
      path.addPath(shape.path,transform:CGAffineTransform(translationX:x,y:baseline))
      if !path.isEmpty {result.append(Ink(path:path,color:FormColor.hex(attrs[.foregroundColor] as? NSColor ?? .black),
        swatchID:(attrs[TypographyEngine.swatchKey] as? String).flatMap(UUID.init(uuidString:)),character:paragraph.location))}
    }
    return result
  }
  private static func naturalRTL(_ string:String)->Bool {
    for scalar in string.unicodeScalars where CharacterSet.letters.contains(scalar) {
      return (0x590...0x8ff).contains(scalar.value) || (0xfb1d...0xfdff).contains(scalar.value) || (0xfe70...0xfeff).contains(scalar.value)
    }
    return false
  }
}

public final class PublicationLayoutManager:NSLayoutManager {
  private struct GeneratedFont {
    var glyph:CGGlyph,property:NSLayoutManager.GlyphProperty,font:NSFont
  }
  private var generatedFonts:[Int:[GeneratedFont]]=[:]
  private var ambiguousCharacters=Set<Int>()
  private func resolvedGeneratedFont(_ index:Int)->(font:NSFont?,ambiguous:Bool) {
    guard index>=0,index<numberOfGlyphs else{return(nil,false)}
    let character=characterIndexForGlyph(at:index)
    guard !ambiguousCharacters.contains(character),let records=generatedFonts[character],!records.isEmpty else{return(nil,ambiguousCharacters.contains(character))}
    let currentGlyph=glyph(at:index),property=propertyForGlyph(at:index)
    let matching=records.filter{UInt($0.glyph)==currentGlyph && $0.property==property}
    let candidates=matching.isEmpty ? records:matching
    let first=candidates[0].font
    guard candidates.allSatisfy({$0.font.isEqual(first)}) else{return(nil,true)}
    return(first,false)
  }
  public func fontForGeneratedGlyph(_ index:Int)->NSFont? {resolvedGeneratedFont(index).font}
  /// Physical output must not guess if one source character was observed with
  /// conflicting font/glyph identities. Same-face multi-glyph shaping is safe.
  public func outlineFont(forGlyphAt index:Int,authored:NSFont?)throws->NSFont {
    let result=resolvedGeneratedFont(index)
    guard !result.ambiguous else{throw FormError.invalid("TextKit produced conflicting font identities for a shaped character. Its physical outline cannot be resolved safely; source text remains unchanged.")}
    guard let font=result.font else{throw FormError.invalid("TextKit did not establish a font identity for this shaped glyph. Its physical outline cannot be resolved safely; source text remains unchanged.")}
    return font
  }
  public override func setGlyphs(_ glyphs:UnsafePointer<CGGlyph>,properties:UnsafePointer<NSLayoutManager.GlyphProperty>,characterIndexes:UnsafePointer<Int>,font:NSFont,forGlyphRange range:NSRange) {
    // TextKit inserts/removes glyphs during complex-script shaping. Index by
    // supplied source identity, then retain actual glyph/property/font evidence.
    for offset in 0..<range.length {
      let character=characterIndexes[offset],record=GeneratedFont(glyph:glyphs[offset],property:properties[offset],font:font)
      var records=generatedFonts[character] ?? []
      if !records.contains(where:{$0.glyph==record.glyph && $0.property==record.property && $0.font.isEqual(font)}) {
        if records.count<16 {records.append(record);generatedFonts[character]=records}
        else {ambiguousCharacters.insert(character)}
      }
    }
    super.setGlyphs(glyphs,properties:properties,characterIndexes:characterIndexes,font:font,forGlyphRange:range)
  }
  public override func drawGlyphs(forGlyphRange glyphsToShow:NSRange,at origin:CGPoint) {
    super.drawGlyphs(forGlyphRange:glyphsToShow,at:origin)
    guard let context=NSGraphicsContext.current?.cgContext else{return}
    context.saveGState();context.translateBy(x:origin.x,y:origin.y)
    for ink in PublicationLists.ink(layout:self,glyphRange:glyphsToShow) {
      context.setFillColor(FormColor.color(ink.color).cgColor);context.addPath(ink.path);context.fillPath()
    }
    context.restoreGState()
  }
}

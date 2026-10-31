import AppKit
import CoreText
import FormCore

/// A line is accepted only when its reserved height fits the bounded frame.
public final class StoryTextContainer:NSTextContainer {
  public override func lineFragmentRect(forProposedRect proposed:CGRect,at character:Int,writingDirection:NSWritingDirection,remaining:UnsafeMutablePointer<CGRect>?)->CGRect {
    var height=proposed.height
    if let storage=layoutManager?.textStorage,character<storage.length,
      let style=storage.attribute(.paragraphStyle,at:character,effectiveRange:nil) as? NSParagraphStyle {
      height=max(height,style.minimumLineHeight,style.maximumLineHeight)
    }
    guard proposed.minY+height<=size.height+1e-7 else{remaining?.pointee = .zero;return .zero}
    return super.lineFragmentRect(forProposedRect:proposed,at:character,writingDirection:writingDirection,remaining:remaining)
  }
}

/// Mutable only for a native editing session; cached production instances are immutable.
@MainActor public final class StoryComposition:NSObject,@preconcurrency NSLayoutManagerDelegate {
  public nonisolated static let gridKey=NSAttributedString.Key("studio.form.baselineGrid")
  public let context:ResolvedTextStory
  public let storage=PublicationTextStorage()
  public let layout=PublicationLayoutManager()
  public private(set) var containers:[StoryTextContainer]=[]
  public let overflow:StoryTextContainer
  public private(set) var topOffsets:[Double]=[]
  private var origins:[ObjectIdentifier:Double]=[:]
  private let baseAscent:Double
  private var usesGrid:Bool
  public init(_ context:ResolvedTextStory) {
    self.context=context
    let source=context.story.sourceElement.inheritingLanguage(context.language)
    let attributed=TypographyEngine.attributed(source,preservingSource:true)
    let type=context.story.typography ?? .init()
    usesGrid=context.baselineGrid != nil && (type.alignToBaselineGrid==true || context.story.textRuns?.contains(where:{$0.typography.alignToBaselineGrid==true})==true)
    baseAscent=Double(TypographyEngine.font(type,size:context.story.fontSize).ascender)
    overflow=StoryTextContainer(size:.init(width:max(100,(context.frames.last?.width ?? 100)*TypographyEngine.pointsPerMM),height:100_000_000_000))
    super.init()
    layout.delegate=self;layout.allowsNonContiguousLayout=false
    storage.addLayoutManager(layout)
    for frame in context.frames {
      let padding=topPadding(pageY:frame.pageY)
      let box=StoryTextContainer(size:.init(width:frame.width*TypographyEngine.pointsPerMM,height:max(0,frame.height*TypographyEngine.pointsPerMM-padding)))
      box.lineFragmentPadding=0;layout.addTextContainer(box)
      topOffsets.append(padding);containers.append(box);origins[ObjectIdentifier(box)]=frame.pageY+padding
    }
    overflow.lineFragmentPadding=0;layout.addTextContainer(overflow)
    origins[ObjectIdentifier(overflow)]=(context.baselineGrid?.origin ?? 0)-baseAscent
    storage.setAttributedString(preparing(attributed))
    layout.ensureLayout(for:overflow)
  }
  private func topPadding(pageY:Double)->Double {
    guard usesGrid,let grid=context.baselineGrid else{return 0}
    let phase=grid.origin-baseAscent
    return ((phase-pageY).truncatingRemainder(dividingBy:grid.spacing)+grid.spacing).truncatingRemainder(dividingBy:grid.spacing)
  }
  /// Derive grid geometry from raw formatting metadata; no derived line heights persist.
  public func preparing(_ source:NSAttributedString)->NSAttributedString {
    let result=NSMutableAttributedString(attributedString:source)
    result.removeAttribute(Self.gridKey,range:NSRange(location:0,length:result.length))
    guard let grid=context.baselineGrid else{return result}
    var active=false
    result.enumerateAttribute(NSAttributedString.Key("studio.form.typography"),in:NSRange(location:0,length:result.length)) { value,_,stop in
      if let data=value as? Data,let raw=try? JSONDecoder.form.decode(Typography.self,from:data),raw.alignToBaselineGrid==true {active=true;stop.pointee=true}
    }
    if result.length>0,active != usesGrid {
      usesGrid=active
      for (index,frame) in context.frames.enumerated() {
        let padding=topPadding(pageY:frame.pageY),box=containers[index]
        topOffsets[index]=padding
        box.size.height=max(0,frame.height*TypographyEngine.pointsPerMM-padding)
        origins[ObjectIdentifier(box)]=frame.pageY+padding
        layout.textContainerChangedGeometry(box)
      }
    }
    for range in ParagraphLists.ranges(in:result.string) where range.length>0 {
      let attrs=result.attributes(at:range.location,effectiveRange:nil)
      let raw=(attrs[NSAttributedString.Key("studio.form.typography")] as? Data).flatMap{try? JSONDecoder.form.decode(Typography.self,from:$0)} ?? .init()
      let base=attrs[.paragraphStyle] as? NSParagraphStyle ?? .default
      let p=base.mutableCopy() as! NSMutableParagraphStyle
      p.minimumLineHeight=raw.leading;p.maximumLineHeight=raw.leading
      p.paragraphSpacingBefore=raw.paragraphBefore;p.paragraphSpacing=raw.paragraphAfter
      if raw.alignToBaselineGrid==true {
        let line=CTLineCreateWithAttributedString(result.attributedSubstring(from:range))
        var ascent=0.0,descent=0.0
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
          let attributes=CTRunGetAttributes(run) as NSDictionary
          let font=attributes[kCTFontAttributeName] as! CTFont
          let offset=(attributes[NSAttributedString.Key.baselineOffset] as? NSNumber)?.doubleValue ?? 0
          ascent=max(ascent,CTFontGetAscent(font)+offset);descent=max(descent,CTFontGetDescent(font)-offset)
        }
        let baseline=ceil((ascent-baseAscent)/grid.spacing)*grid.spacing+baseAscent
        let leading=ceil(max(raw.leading,baseline+descent)/grid.spacing)*grid.spacing
        p.minimumLineHeight=leading;p.maximumLineHeight=leading
        result.addAttribute(Self.gridKey,value:true,range:range)
      }
      result.addAttribute(.paragraphStyle,value:p,range:range)
    }
    return result
  }
  public func layoutManager(_ manager:NSLayoutManager,paragraphSpacingBeforeGlyphAt glyph:Int,withProposedLineFragmentRect rect:NSRect)->CGFloat {
    guard storage.length>0,manager.textStorage === storage else{return 0}
    let character=manager.characterIndexForGlyph(at:glyph)
    guard character<storage.length else{return 0}
    let attrs=storage.attributes(at:character,effectiveRange:nil)
    let before=(attrs[.paragraphStyle] as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
    guard attrs[Self.gridKey] as? Bool==true,let grid=context.baselineGrid,let box=manager.typesetter.currentTextContainer else{return before}
    let y=(origins[ObjectIdentifier(box)] ?? 0)+rect.minY+before
    let target=grid.origin-baseAscent
    let padding=((target-y).truncatingRemainder(dividingBy:grid.spacing)+grid.spacing).truncatingRemainder(dividingBy:grid.spacing)
    return before+padding
  }
  public func layoutManager(_ manager:NSLayoutManager,shouldSetLineFragmentRect rect:UnsafeMutablePointer<NSRect>,lineFragmentUsedRect used:UnsafeMutablePointer<NSRect>,baselineOffset baseline:UnsafeMutablePointer<CGFloat>,in box:NSTextContainer,forGlyphRange range:NSRange)->Bool {
    guard storage.length>0,range.length>0,manager.textStorage === storage else{return false}
    let character=manager.characterIndexForGlyph(at:range.location)
    guard character<storage.length else{return false}
    guard storage.attribute(Self.gridKey,at:character,effectiveRange:nil) as? Bool==true,let grid=context.baselineGrid else{return false}
    let characters=manager.characterRange(forGlyphRange:range,actualGlyphRange:nil)
    var ascent=0.0
    for index in range.location..<NSMaxRange(range) {
      let char=manager.characterIndexForGlyph(at:index)
      let attrs=storage.attributes(at:char,effectiveRange:nil)
      let font=layout.fontForGeneratedGlyph(index) ?? attrs[.font] as? NSFont ?? .systemFont(ofSize:context.story.fontSize)
      ascent=max(ascent,Double(font.ascender)+((attrs[.baselineOffset] as? NSNumber)?.doubleValue ?? 0))
    }
    if characters.length==0 {return false}
    let y=(origins[ObjectIdentifier(box)] ?? 0)+rect.pointee.minY
    baseline.pointee=ceil((y+ascent-grid.origin-1e-7)/grid.spacing)*grid.spacing+grid.origin-y
    return true
  }
  public func index(_ frame:StoryFrameID)->Int? {context.frames.firstIndex{$0.frame==frame}}
  public func glyphRange(_ index:Int)->NSRange {layout.glyphRange(for:containers[index])}
  public func displayRange(_ index:Int)->NSRange {layout.characterRange(forGlyphRange:glyphRange(index),actualGlyphRange:nil)}
  public func sourceRange(_ index:Int)->NSRange {TextCase.source(storage).sourceRange(displayRange(index))}
  public var oversetRange:NSRange {
    let first=containers.last.map{NSMaxRange(layout.characterRange(forGlyphRange:layout.glyphRange(for:$0),actualGlyphRange:nil))} ?? 0
    return TextCase.source(storage).sourceRange(NSRange(location:first,length:max(0,storage.length-first)))
  }
  public func offset(_ index:Int,verticalAlignment:String="top")->Double {
    let padding=topOffsets[index]
    guard !usesGrid else{return padding}
    let remaining=max(0,context.frames[index].height*TypographyEngine.pointsPerMM-padding-layout.usedRect(for:containers[index]).height)
    return padding+(verticalAlignment=="bottom" ? remaining:verticalAlignment=="middle" ? remaining/2:0)
  }
}

@MainActor public enum PublicationStoryLayout {
  @MainActor private final class Entry {
    let signature:ResolvedTextStory,composition:StoryComposition
    init(_ context:ResolvedTextStory) {signature=context;composition=StoryComposition(context)}
  }
  private static let cache:NSCache<NSUUID,Entry> = {let value=NSCache<NSUUID,Entry>();value.countLimit=64;value.totalCostLimit=32_000_000;return value}()
  private static var builds=0,hits=0
  public static var diagnostics:[String:Any] {["story_layout_builds":builds,"story_layout_hits":hits,"story_layout_cache_limit":64]}
  public static func invalidate() {cache.removeAllObjects()}
  public static func composition(_ context:ResolvedTextStory)->StoryComposition {
    if let entry=cache.object(forKey:context.story.id as NSUUID),entry.signature==context {hits+=1;return entry.composition}
    let entry=Entry(context);cache.setObject(entry,forKey:context.story.id as NSUUID,cost:max(1000,context.story.text.utf16.count*250));builds+=1
    return entry.composition
  }
  private static func frame(_ element:ArtworkElement)->(StoryComposition,Int)? {
    guard let ref=element.storyFrame,let context=ref.resolved,let id=ref.frame else{return nil}
    let value=composition(context);guard let index=value.index(id) else{return nil};return(value,index)
  }
  public static func measured(_ element:ArtworkElement,points:Bool)->CGSize {
    guard let(value,index)=frame(element) else{return .zero}
    let rect=value.layout.usedRect(for:value.containers[index]),factor=points ? 1:1/TypographyEngine.pointsPerMM
    return .init(width:rect.width*factor,height:rect.height*factor)
  }
  public static func overflows(_ element:ArtworkElement)->Bool {
    guard let(value,index)=frame(element) else{return true}
    return value.layout.usedRect(for:value.containers[index]).width>value.containers[index].size.width+0.01 || (index==value.containers.count-1 && value.oversetRange.length>0)
  }
  public static func verticalOffset(_ element:ArtworkElement,points:Bool)->Double {
    guard let(value,index)=frame(element) else{return 0}
    return value.offset(index,verticalAlignment:element.typography?.verticalAlignment ?? "top")/(points ? 1:TypographyEngine.pointsPerMM)
  }
  public static func firstBaseline(_ element:ArtworkElement)->Double {
    guard let(value,index)=frame(element) else{return 0};let range=value.glyphRange(index);guard range.length>0 else{return 0}
    return (value.layout.lineFragmentRect(forGlyphAt:range.location,effectiveRange:nil).minY+value.layout.location(forGlyphAt:range.location).y+value.offset(index,verticalAlignment:element.typography?.verticalAlignment ?? "top"))/TypographyEngine.pointsPerMM
  }
  public static func draw(_ element:ArtworkElement,in context:CGContext) {
    guard let(value,index)=frame(element) else{return}
    context.saveGState();context.scaleBy(x:1/TypographyEngine.pointsPerMM,y:1/TypographyEngine.pointsPerMM)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
    value.layout.drawGlyphs(forGlyphRange:value.glyphRange(index),at:.init(x:0,y:value.offset(index,verticalAlignment:element.typography?.verticalAlignment ?? "top")))
    NSGraphicsContext.restoreGraphicsState();context.restoreGState()
  }
  static func drawPaintGroup(_ element: ArtworkElement, stack: [ArtworkPaintLayer]?, in context: CGContext) {
    guard let (value, index) = frame(element) else { return }
    let range = value.glyphRange(index), offset = value.offset(index, verticalAlignment: element.typography?.verticalAlignment ?? "top")
    context.saveGState(); context.scaleBy(x: 1 / TypographyEngine.pointsPerMM, y: 1 / TypographyEngine.pointsPerMM)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    var start: Int?
    func flush(_ end: Int) {
      if let begin = start { value.layout.drawGlyphs(forGlyphRange: .init(location: begin, length: end - begin), at: .init(x: 0, y: offset)) }
      start = nil
    }
    for glyph in range.location..<NSMaxRange(range) {
      let character = value.layout.characterIndexForGlyph(at: glyph)
      let data = character < value.storage.length ? value.storage.attribute(TypographyEngine.paintStackKey, at: character, effectiveRange: nil) as? Data : nil
      if TypographyEngine.matchesPaint(data, element: element, stack: stack) { if start == nil { start = glyph } }
      else { flush(glyph) }
    }
    flush(NSMaxRange(range)); NSGraphicsContext.restoreGraphicsState(); context.restoreGState()
  }
  public static func outlines(_ element:ArtworkElement, matchingPaintStack: [ArtworkPaintLayer]? = nil, filtering: Bool = false) throws -> [(path:CGPath,color:String,swatchID:UUID?)] {
    guard let(value,index)=frame(element) else{throw FormError.invalid("Resolve the linked text story before converting its frame to paths.")}
    let range=value.glyphRange(index),factor=1/TypographyEngine.pointsPerMM,offset=value.offset(index,verticalAlignment:element.typography?.verticalAlignment ?? "top")
    var result:[(path:CGPath,color:String,swatchID:UUID?)]=[]
    for glyph in range.location..<NSMaxRange(range) where !value.layout.propertyForGlyph(at:glyph).contains(.controlCharacter) && !value.layout.notShownAttribute(forGlyphAt:glyph) {
      let character=value.layout.characterIndexForGlyph(at:glyph),attrs=value.storage.attributes(at:character,effectiveRange:nil)
      if filtering && !TypographyEngine.matchesPaint(attrs[TypographyEngine.paintStackKey] as? Data, element: element, stack: matchingPaintStack) { continue }
      let font=try value.layout.outlineFont(forGlyphAt:glyph,authored:attrs[.font] as? NSFont)
      let path=CGMutablePath(),line=value.layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil),position=value.layout.location(forGlyphAt:glyph)
      let baseline=line.minY+position.y+offset
      let native=value.layout.glyph(at:glyph)
      guard native<=UInt16.max else{throw FormError.invalid("A story contains a glyph without a supported vector outline.")}
      let cg=CGGlyph(native)
      if let outline=CTFontCreatePathForGlyph(font as CTFont,cg,nil) {
        let stretch=exp((attrs[.expansion] as? NSNumber)?.doubleValue ?? 0)
        path.addPath(outline,transform:CGAffineTransform(a:stretch*factor,b:0,c:0,d:-factor,tx:(line.minX+position.x)*factor,ty:baseline*factor))
      } else {
        let scalar=UnicodeScalar((value.storage.string as NSString).character(at:character))
        if scalar.map({!CharacterSet.whitespacesAndNewlines.contains($0)}) ?? true {throw FormError.invalid("A story glyph has no vector outline; choose a different font.")}
      }
      let rect=value.layout.boundingRect(forGlyphRange:NSRange(location:glyph,length:1),in:value.containers[index])
      let thickness=max(0.05,CTFontGetUnderlineThickness(font as CTFont))
      if ((attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0)>0 {path.addRect(.init(x:rect.minX*factor,y:(baseline-CTFontGetUnderlinePosition(font as CTFont)-thickness/2)*factor,width:rect.width*factor,height:thickness*factor))}
      if ((attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0)>0 {path.addRect(.init(x:rect.minX*factor,y:(baseline-CTFontGetXHeight(font as CTFont)/2-thickness/2)*factor,width:rect.width*factor,height:thickness*factor))}
      if !path.isEmpty {result.append((path,FormColor.hex(attrs[.foregroundColor] as? NSColor ?? .black),(attrs[TypographyEngine.swatchKey] as? String).flatMap(UUID.init(uuidString:))))}
    }
    for ink in PublicationLists.ink(layout:value.layout,glyphRange:range) where !filtering || matchingPaintStack == element.paintStack {
      let path=CGMutablePath();path.addPath(ink.path,transform:CGAffineTransform(a:factor,b:0,c:0,d:factor,tx:0,ty:offset*factor));result.append((path,ink.color,ink.swatchID))
    }
    return result
  }
}

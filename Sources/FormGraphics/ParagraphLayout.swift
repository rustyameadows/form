import AppKit
import CoreText
import FormCore

/// TextKit performs real hyphenation; the same cached glyphs drive every output.
@MainActor enum ParagraphLayout {
  private struct Signature: Equatable {
    var text: String, width: Double, height: Double, size: Double, color: String
    var type: Typography?, runs: [TextSpan]?
    var glyphs: [GlyphOverride]?
    init(_ e: ArtworkElement) {
      text=e.text; width=e.width; height=e.height; size=e.fontSize; color=e.color
      type=e.typography; runs=e.textRuns; glyphs=e.glyphOverrides
    }
  }
  @MainActor private final class Entry {
    let signature: Signature, storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer
    let size: CGSize, offset: Double, visible: NSRange
    var ink: [(path:CGPath,color:String,swatchID:UUID?)]?
    init(_ e: ArtworkElement) {
      signature=Signature(e)
      storage=NSTextStorage(attributedString:TypographyEngine.attributed(e))
      layout=NSLayoutManager()
      container=NSTextContainer(size:.init(width:e.typography?.frameMode == "point" ? 100000 : e.width*TypographyEngine.pointsPerMM,height:100000))
      container.lineFragmentPadding=0
      layout.addTextContainer(container);storage.addLayoutManager(layout)
      layout.ensureLayout(for:container)
      size=layout.usedRect(for:container).size
      let height=e.height*TypographyEngine.pointsPerMM
      offset=e.typography?.verticalAlignment == "middle" ? max(0,(height-size.height)/2)
        : e.typography?.verticalAlignment == "bottom" ? max(0,height-size.height) : 0
      var end=0
      layout.enumerateLineFragments(forGlyphRange:layout.glyphRange(for:container)) { rect, _, _, range, _ in
        if rect.maxY <= height+1e-7 { end=NSMaxRange(range) }
      }
      visible=NSRange(location:0,length:end)
    }
  }
  private static let cache: NSCache<NSUUID,Entry> = {
    let c=NSCache<NSUUID,Entry>();c.countLimit=256;c.totalCostLimit=16_000_000;return c
  }()
  private static var builds=0,hits=0
  static var diagnostics:[String:Any] { ["paragraph_layout_builds":builds,"paragraph_layout_hits":hits,"paragraph_layout_cache_limit":256] }
  static func invalidate() { cache.removeAllObjects() }
  private static func entry(_ e:ArtworkElement)->Entry {
    if let value=cache.object(forKey:e.id as NSUUID),value.signature==Signature(e) { hits+=1;return value }
    let value=Entry(e);cache.setObject(value,forKey:e.id as NSUUID,cost:max(500,e.text.utf16.count*180));builds+=1;return value
  }
  static func measured(_ e:ArtworkElement,points:Bool)->CGSize {
    let size=entry(e).size,f=points ? 1 : 1/TypographyEngine.pointsPerMM
    return .init(width:size.width*f,height:size.height*f)
  }
  static func verticalOffset(_ e:ArtworkElement,points:Bool)->Double { entry(e).offset/(points ? 1 : TypographyEngine.pointsPerMM) }
  static func firstBaseline(_ e:ArtworkElement)->Double {
    let value=entry(e);guard value.layout.numberOfGlyphs>0 else { return 0 }
    return (value.layout.lineFragmentRect(forGlyphAt:0,effectiveRange:nil).minY
      + value.layout.location(forGlyphAt:0).y + value.offset)/TypographyEngine.pointsPerMM
  }
  static func overflows(_ e:ArtworkElement)->Bool {
    let value=entry(e)
    return value.size.height > e.height*TypographyEngine.pointsPerMM+1e-7
      || value.size.width > e.width*TypographyEngine.pointsPerMM+1e-7
  }
  static func draw(_ e:ArtworkElement,in context:CGContext) {
    let value=entry(e)
    context.saveGState()
    context.scaleBy(x:1/TypographyEngine.pointsPerMM,y:1/TypographyEngine.pointsPerMM)
    context.setAllowsFontSubpixelPositioning(true)
    context.setShouldSubpixelPositionFonts(true)
    context.setAllowsFontSubpixelQuantization(false)
    context.setShouldSubpixelQuantizeFonts(false)
    context.setAllowsFontSmoothing(false)
    context.setShouldSmoothFonts(false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
    value.layout.drawGlyphs(forGlyphRange:value.visible,at:.init(x:0,y:value.offset))
    NSGraphicsContext.restoreGraphicsState()
    context.restoreGState()
  }
  static func outlines(_ e:ArtworkElement) throws -> [(path:CGPath,color:String,swatchID:UUID?)] {
    let value=entry(e);if let ink=value.ink { return ink }
    var result:[(path:CGPath,color:String,swatchID:UUID?)]=[]
    let factor=1/TypographyEngine.pointsPerMM
    for index in value.visible.location..<NSMaxRange(value.visible) {
      if value.layout.propertyForGlyph(at:index).contains(.controlCharacter) { continue }
      let character=value.layout.characterIndexForGlyph(at:index)
      guard character<value.storage.length else { continue }
      let attrs=value.storage.attributes(at:character,effectiveRange:nil)
      let font=attrs[.font] as? NSFont ?? .systemFont(ofSize:e.fontSize)
      let glyph=value.layout.glyph(at:index)
      let path=CGMutablePath()
      let line=value.layout.lineFragmentRect(forGlyphAt:index,effectiveRange:nil)
      let position=value.layout.location(forGlyphAt:index)
      let baseline=line.minY+position.y+value.offset
      if glyph<=UInt16.max,let outline=CTFontCreatePathForGlyph(font as CTFont,CGGlyph(glyph),nil) {
        let stretch=exp((attrs[.expansion] as? NSNumber)?.doubleValue ?? 0)
        let matrix=CGAffineTransform(a:stretch*factor,b:0,c:0,d:-factor,
          tx:(line.minX+position.x)*factor,ty:baseline*factor)
        path.addPath(outline,transform:matrix)
      } else {
        let scalar=UnicodeScalar((value.storage.string as NSString).character(at:character))
        if scalar.map({!CharacterSet.whitespacesAndNewlines.contains($0)}) == true {
          throw FormError.invalid("This font contains a glyph without a vector outline. Use a different font for hyphenated vector text.")
        }
      }
      let rect=value.layout.boundingRect(forGlyphRange:NSRange(location:index,length:1),in:value.container)
      let thickness=max(0.05,CTFontGetUnderlineThickness(font as CTFont))
      if ((attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0)>0 {
        path.addRect(.init(x:rect.minX*factor,y:(baseline-CTFontGetUnderlinePosition(font as CTFont)-thickness/2)*factor,width:rect.width*factor,height:thickness*factor))
      }
      if ((attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0)>0 {
        path.addRect(.init(x:rect.minX*factor,y:(baseline-CTFontGetXHeight(font as CTFont)/2-thickness/2)*factor,width:rect.width*factor,height:thickness*factor))
      }
      if !path.isEmpty {
        let color=FormColor.hex(attrs[.foregroundColor] as? NSColor ?? FormColor.color(e.color))
        let swatch=(attrs[TypographyEngine.swatchKey] as? String).flatMap(UUID.init(uuidString:))
        if let last=result.last,last.color==color,last.swatchID==swatch {
          let combined=CGMutablePath();combined.addPath(last.path);combined.addPath(path)
          result[result.count-1]=(combined,color,swatch)
        } else { result.append((path,color,swatch)) }
      }
    }
    value.ink=result;return result
  }
}

import AppKit
import CoreText
import FormCore

/// Source ranges persist in the model; native glyph-info attributes are derived.
@MainActor public enum GlyphEngine {
  public static let overrideKey = NSAttributedString.Key("studio.form.glyphOverride")
  public static let renderKey = NSAttributedString.Key("studio.form.glyphRender")
  private final class InfoKey: NSObject {
    let font: NSFont, glyph: CGGlyph, base: String
    init(font: NSFont, glyph: CGGlyph, base: String) { self.font=font;self.glyph=glyph;self.base=base }
    override var hash: Int { font.hash ^ Int(glyph) ^ base.hashValue }
    override func isEqual(_ object: Any?) -> Bool {
      guard let other=object as? InfoKey else { return false }
      return glyph==other.glyph && base==other.base && font.isEqual(other.font)
    }
  }
  private final class InfoEntry { let value: CTGlyphInfo; init(_ value: CTGlyphInfo) { self.value=value } }
  private static let infos: NSCache<InfoKey,InfoEntry> = {
    let cache=NSCache<InfoKey,InfoEntry>();cache.countLimit=2048;cache.totalCostLimit=1_000_000;return cache
  }()
  public static func invalidate() { infos.removeAllObjects() }
  /// Font activation and cache eviction may replace a derived glyph-info object.
  public static func nativeEqual(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
    if a.isEqual(to:b) { return true }
    guard a.length==b.length,(a.string as NSString).isEqual(to:b.string) else { return false }
    let left=NSMutableAttributedString(attributedString:a),right=NSMutableAttributedString(attributedString:b)
    a.enumerateAttribute(overrideKey,in:NSRange(location:0,length:a.length)) { value,range,_ in
      guard value != nil else { return }
      for i in range.location..<NSMaxRange(range)
        where a.attribute(.glyphInfo,at:i,effectiveRange:nil) != nil && b.attribute(.glyphInfo,at:i,effectiveRange:nil) != nil {
        let part=NSRange(location:i,length:1)
        left.removeAttribute(.glyphInfo,range:part);right.removeAttribute(.glyphInfo,range:part)
      }
    }
    return left.isEqual(to:right)
  }
  private static func glyphInfo(_ glyph: CGGlyph, font: NSFont, base: String) -> CTGlyphInfo? {
    let key=InfoKey(font:font,glyph:glyph,base:base)
    if let cached=infos.object(forKey:key) { return cached.value }
    guard let info=CTGlyphInfoCreateWithGlyph(glyph,font as CTFont,base as CFString) else { return nil }
    infos.setObject(InfoEntry(info),forKey:key,cost:128+base.utf16.count*2)
    return info
  }
  private static let uniformKeys: [NSAttributedString.Key] = [
    .font, .foregroundColor, .baselineOffset, .expansion, .tracking, .kern,
    .underlineStyle, .strikethroughStyle, TypographyEngine.swatchKey,
    TypographyEngine.paintStackKey, TypographyEngine.inheritedPaintStackKey,
  ]

  public static func validateSelection(_ element: ArtworkElement, choice: GlyphOverride) throws {
    try GlyphCommands.validate([choice], text: element.text)
    _ = try resolved(choice, in: TypographyEngine.sourceAttributed(element))
  }
  private static func resolved(_ choice: GlyphOverride, in source: NSAttributedString) throws -> (CGGlyph, NSFont) {
    guard choice.range.location >= 0, choice.length > 0,
      NSMaxRange(choice.range) <= source.length,
      ((source.string as NSString).substring(with: choice.range) as NSString).isEqual(to:choice.sourceText) else {
      throw FormError.invalid("The source characters for this glyph changed. Select them again.")
    }
    let positioned=CharacterTypography.resolved(source,exactRanges:[choice.range])
    let first = positioned.attributes(at: choice.location, effectiveRange: nil)
    guard let font = first[.font] as? NSFont else { throw FormError.invalid("Choose a font for the glyph.") }
    var uniform = true
    positioned.enumerateAttributes(in: choice.range) { attrs, _, _ in
      for key in uniformKeys {
        let a = first[key] as? NSObject, b = attrs[key] as? NSObject
        if a == nil ? b != nil : b == nil || !a!.isEqual(b!) { uniform = false }
      }
    }
    guard uniform else {
      throw FormError.invalid("A single glyph needs matching font, size, color, and spacing across its source characters.")
    }
    let type=TypographyEngine.assignedTypography(in:first)
    return (try GlyphCatalog.resolve(choice.glyph,font:font,sourceFace:(type?.opticalSizing != nil || type?.characterPosition != nil) ? type?.fontName:nil),font)
  }
  public static func issues(_ element: ArtworkElement) -> [String] {
    let source = TypographyEngine.sourceAttributed(element)
    return (element.glyphOverrides ?? []).compactMap { choice in
      do { _ = try resolved(choice, in: source); return nil }
      catch { return error.localizedDescription }
    }
  }
  public static func validateOutput(_ element: ArtworkElement, outlines: Bool = false) throws {
    guard let choices = element.glyphOverrides, !choices.isEmpty else { return }
    try GlyphCommands.validate(choices, text: element.text)
    let source = TypographyEngine.sourceAttributed(element)
    for choice in choices {
      let (glyph, font) = try resolved(choice, in: source)
      if outlines {
        var id = glyph, bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font as CTFont, .default, &id, &bounds, 1)
        guard CTFontCreatePathForGlyph(font as CTFont, glyph, nil) != nil || bounds.isEmpty else {
          throw FormError.invalid("The selected glyph has no vector outline. Keep it in a PDF or raster output, or choose another glyph.")
        }
      }
    }
  }
  public static func composed(_ source: NSAttributedString, choices: [GlyphOverride], preservingSource: Bool) -> NSAttributedString {
    let source=CharacterTypography.authored(source)
    guard !choices.isEmpty else {
      let displayed=CharacterTypography.resolved(TypographyEngine.displayingCase(source,preservingSource:preservingSource))
      return preservingSource ? displayed:CharacterTypography.withoutRuntime(displayed)
    }
    // Production shaping needs the case map, but never serializes native source metadata.
    let display=TypographyEngine.displayingCase(source)
    let mapping=TextCase.source(display)
    let result=NSMutableAttributedString(attributedString:CharacterTypography.resolved(display,exactRanges:choices.map{mapping.displayRange($0.range)}))
    for choice in choices {
      guard choice.location >= 0,NSMaxRange(choice.range)<=source.length else {continue}
      let range = mapping.displayRange(choice.range)
      guard range.length > 0, NSMaxRange(range) <= result.length else { continue }
      if preservingSource,let data=try? JSONEncoder.form.encode(choice) {
        result.addAttribute(overrideKey,value:data,range:range)
      }
      guard let (glyph, font) = try? resolved(choice, in: source) else { continue }
      let base = (result.string as NSString).substring(with: range)
      // Attributed-string equality requires identical glyph-info objects even when CFEqual succeeds.
      if let info = glyphInfo(glyph, font: font, base: base) {
        result.addAttribute(.glyphInfo, value: info, range: range)
        if preservingSource, let signature=try? GlyphCatalog.signature(font.fontName) {
          result.addAttribute(renderKey,value:"\(signature):\(glyph)",range:range)
        }
      }
    }
    if !preservingSource {
      result.removeAttribute(TextCase.sourceKey, range: NSRange(location: 0, length: result.length))
      result.removeAttribute(overrideKey, range: NSRange(location: 0, length: result.length))
    }
    return preservingSource ? result:CharacterTypography.withoutRuntime(result)
  }
  public static func overrides(from source: NSAttributedString) -> [GlyphOverride] {
    var values: [GlyphOverride] = [], seen = Set<UUID>()
    source.enumerateAttribute(overrideKey, in: NSRange(location: 0, length: source.length)) { raw, range, _ in
      guard let data = raw as? Data, var choice = try? JSONDecoder.form.decode(GlyphOverride.self, from: data),
        choice.length > 0, range.length % choice.length == 0 else { return }
      var parts: [GlyphOverride] = []
      for offset in stride(from: range.location, to: NSMaxRange(range), by: choice.length) {
        let part = NSRange(location: offset, length: choice.length)
        guard ((source.string as NSString).substring(with: part) as NSString).isEqual(to:choice.sourceText) else { return }
        choice.location = offset
        if seen.contains(choice.id) { choice.id = UUID() }
        seen.insert(choice.id); parts.append(choice)
      }
      values += parts
    }
    // Native attributed paste can bring malformed or overlapping records.
    return (try? GlyphCommands.validate(values, text: source.string)) != nil ? values.sorted { $0.location < $1.location } : []
  }
  public static func normalizedNative(_ source: NSAttributedString) -> NSAttributedString {
    let choices = overrides(from: source)
    let cleaned = NSMutableAttributedString(attributedString: source)
    for key in [overrideKey, .glyphInfo, renderKey] { cleaned.removeAttribute(key, range: NSRange(location: 0, length: cleaned.length)) }
    return composed(cleaned, choices: choices, preservingSource: true)
  }
  public static func applying(_ glyph: FontGlyph?, range: NSRange, to source: NSAttributedString) throws -> NSAttributedString {
    let selected = try GlyphCommands.sourceText(in:source.string,range:range)
    var choices = overrides(from: source)
    let previous = choices.first { $0.range == range }
    choices.removeAll { NSIntersectionRange($0.range, range).length > 0 }
    if let glyph {
      var choice = GlyphOverride(location: range.location,
        sourceText: selected, glyph: glyph)
      if let previous, previous.glyph == glyph, previous.sourceText == choice.sourceText { choice.id = previous.id }
      try GlyphCommands.validate([choice], text: source.string)
      _ = try resolved(choice, in: source)
      choices.append(choice)
    }
    try GlyphCommands.validate(choices, text: source.string)
    let cleaned = NSMutableAttributedString(attributedString: source)
    for key in [overrideKey, .glyphInfo, renderKey] { cleaned.removeAttribute(key, range: NSRange(location: 0, length: cleaned.length)) }
    return composed(cleaned, choices: choices, preservingSource: true)
  }
  public static func expandedDisplayRange(_ selection: NSRange, in text: NSAttributedString) -> NSRange {
    var range = TextCase.expandedDisplayRange(selection, in: text)
    guard range.length > 0 else { return range }
    text.enumerateAttribute(overrideKey, in: NSRange(location: 0, length: text.length)) { raw, part, _ in
      if raw != nil, NSIntersectionRange(range, part).length > 0 { range = NSUnionRange(range, part) }
    }
    return range
  }
}

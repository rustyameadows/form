import AppKit
import CoreText
import FormCore

public enum FormColor {
  public static func color(_ hex: String) -> NSColor {
    let n = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return NSColor(
      srgbRed: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255,
      blue: Double(n & 255) / 255, alpha: 1)
  }
  public static func hex(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB) ?? .black
    return String(
      format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
  }
}

@MainActor public enum TypographyEngine {
  public static let pointsPerMM = 72.0 / 25.4
  private static let styleKey = NSAttributedString.Key("studio.form.typography")
  public static let swatchKey = NSAttributedString.Key("studio.form.swatch")
  public static let textStyleKey = NSAttributedString.Key("studio.form.textStyle")
  public static let paragraphStyleKey = NSAttributedString.Key("studio.form.paragraphTextStyle")
  public static let spacingKey = NSAttributedString.Key("studio.form.spacingAdjustment")
  public static let pairKey = NSAttributedString.Key("studio.form.pairAdjustment")
  private struct Signature: Equatable {
    var text: String, size: Double, color: String, width: Double, height: Double,
      style: Typography?, runs: [TextSpan]?
    var fillSwatchID: UUID?
    init(_ e: ArtworkElement) {
      text = e.text
      size = e.fontSize
      color = e.color
      width = e.width
      height = e.height
      style = e.typography
      runs = e.textRuns
      fillSwatchID = e.fillSwatchID
    }
  }
  private final class LayoutEntry {
    let signature: Signature, frame: CTFrame, drawingFrame: CTFrame, offset: Double, size: CGSize,
      text: NSAttributedString
    let decorations: [(CGPath, String)]
    init(
      _ signature: Signature, frame: CTFrame, drawingFrame: CTFrame, offset: Double, size: CGSize,
      text: NSAttributedString, decorations: [(CGPath, String)]
    ) {
      self.signature = signature
      self.frame = frame
      self.drawingFrame = drawingFrame
      self.decorations = decorations
      self.offset = offset
      self.size = size
      self.text = text
    }
  }
  private static let cache: NSCache<NSUUID, LayoutEntry> = {
    let c = NSCache<NSUUID, LayoutEntry>()
    c.countLimit = 800
    c.totalCostLimit = 8_000_000
    return c
  }()
  private static var builds = 0, hits = 0
  public static func invalidateFonts() {
    cache.removeAllObjects()
    FontCatalog.invalidate()
    AppearanceRenderer.invalidateFonts()
  }
  public static var diagnostics: [String: Any] {
    ["layout_builds": builds, "layout_cache_hits": hits, "layout_cache_limit": 800]
  }
  public static func font(_ style: Typography, size: Double) -> NSFont {
    let base =
      NSFont(name: style.fontName, size: size) ?? NSFont.systemFont(ofSize: size, weight: .medium)
    var attrs: [NSFontDescriptor.AttributeName: Any] = [:]
    if !style.resolvedFeatureSelections.isEmpty {
      attrs[.featureSettings] = style.resolvedFeatureSelections.map {
        [
          NSFontDescriptor.FeatureKey.typeIdentifier: $0.type,
          NSFontDescriptor.FeatureKey.selectorIdentifier: $0.selector,
        ]
      }
    }
    if !style.variations.isEmpty {
      attrs[.variation] = Dictionary(
        uniqueKeysWithValues: style.variations.map {
          (NSNumber(value: $0.key), NSNumber(value: $0.value))
        })
    }
    return NSFont(descriptor: base.fontDescriptor.addingAttributes(attrs), size: size) ?? base
  }
  public static func attributes(_ style: Typography, size: Double, color: String, millimeters: Bool,
    swatchID: UUID? = nil, textStyle: TextStyleReference? = nil, paragraphStyle: TextStyleReference? = nil)
    -> [NSAttributedString.Key: Any]
  {
    let f = millimeters ? 1 / pointsPerMM : 1
    let p = NSMutableParagraphStyle()
    p.alignment =
      ["center": NSTextAlignment.center, "right": .right, "justified": .justified][style.alignment]
      ?? .left
    if style.leading > 0 {
      p.minimumLineHeight = style.leading * f
      p.maximumLineHeight = style.leading * f
    }
    p.paragraphSpacingBefore = style.paragraphBefore * f
    p.paragraphSpacing = style.paragraphAfter * f
    p.headIndent = style.leftIndent * f
    p.tailIndent = -style.rightIndent * f
    p.firstLineHeadIndent = style.firstLineIndent * f
    p.hyphenationFactor = Float(style.hyphenation)
    p.baseWritingDirection =
      style.direction == "rtl" ? .rightToLeft : style.direction == "ltr" ? .leftToRight : .natural
    p.lineBreakMode = .byWordWrapping
    var result: [NSAttributedString.Key: Any] = [
      styleKey: (try? JSONEncoder.form.encode(style)) ?? Data(),
      .font: font(style, size: size * f), .foregroundColor: FormColor.color(color),
      .paragraphStyle: p, .kern: style.tracking * f, .baselineOffset: style.baseline * f,
      .ligature: style.ligatures,
      .underlineStyle: style.underline ? NSUnderlineStyle.single.rawValue : 0,
      .strikethroughStyle: style.strikethrough ? NSUnderlineStyle.single.rawValue : 0,
      .expansion: log(style.horizontalScale / 100),
    ]
    if let swatchID { result[swatchKey] = swatchID.uuidString }
    if let textStyle { result[textStyleKey] = try? JSONEncoder.form.encode(textStyle) }
    if let paragraphStyle { result[paragraphStyleKey] = try? JSONEncoder.form.encode(paragraphStyle) }
    return result
  }
  public static func attributed(_ element: ArtworkElement, millimeters: Bool = false)
    -> NSAttributedString
  {
    let base = element.typography ?? .init()
    func caseText(_ s: String) -> String {
      base.caseTreatment == "uppercase"
        ? s.uppercased() : base.caseTreatment == "lowercase" ? s.lowercased() : s
    }
    let text = caseText(element.text)
    let result = NSMutableAttributedString(
      string: text,
      attributes: attributes(
        base, size: element.fontSize, color: element.color, millimeters: millimeters,
        swatchID: element.fillSwatchID, textStyle: element.textStyle, paragraphStyle: element.paragraphStyle))
    for run in element.textRuns ?? [] {
      let original = element.text as NSString
      guard run.location + run.length <= original.length else { continue }
      let start = caseText(original.substring(to: run.location)).utf16.count
      let length = caseText(
        original.substring(with: NSRange(location: run.location, length: run.length))
      ).utf16.count
      guard start + length <= result.length else { continue }
      result.setAttributes(
        attributes(run.typography, size: run.fontSize, color: run.color, millimeters: millimeters,
          swatchID: run.swatchID, textStyle: run.textStyle, paragraphStyle: run.paragraphStyle),
        range: .init(location: start, length: length))
    }
    updateSpacing(result, millimeters: millimeters, fallbackPairs: base.pairKerning)
    return result
  }
  /// Keep tracking separate from word/pair additions through native text edits.
  public static func updateSpacing(_ text: NSMutableAttributedString, range: NSRange? = nil,
    millimeters: Bool = false, fallbackPairs: [Int: Double] = [:]) {
    let full = range ?? NSRange(location: 0, length: text.length)
    let factor = millimeters ? 1 / pointsPerMM : 1
    var runs: [(NSRange, Typography)] = []
    text.enumerateAttribute(styleKey, in: full) { raw, part, _ in
      if let data = raw as? Data, let type = try? JSONDecoder.form.decode(Typography.self, from: data) { runs.append((part, type)) }
    }
    let string = text.string as NSString
    text.beginEditing()
    for (part, type) in runs {
      text.removeAttribute(pairKey, range: part)
      for i in part.location..<NSMaxRange(part) {
        let pair = type.pairKerning[i] ?? fallbackPairs[i]
        let adjustment = pair ?? (string.character(at: i) == 32 ? type.wordSpacing : 0)
        let one = NSRange(location: i, length: 1)
        text.addAttribute(.kern, value: (type.tracking + adjustment) * factor, range: one)
        text.addAttribute(spacingKey, value: adjustment * factor, range: one)
        if let pair { text.addAttribute(pairKey, value: pair * factor, range: one) }
      }
    }
    text.endEditing()
  }
  public static func refreshNativeMetadata(_ spans: [TextSpan], in text: NSMutableAttributedString) {
    text.beginEditing()
    for run in spans {
      let range = NSRange(location: run.location, length: run.length)
      if let data = try? JSONEncoder.form.encode(run.typography) { text.addAttribute(styleKey, value: data, range: range) }
      text.removeAttribute(textStyleKey, range: range)
      if let ref = run.textStyle, let data = try? JSONEncoder.form.encode(ref) { text.addAttribute(textStyleKey, value: data, range: range) }
      text.removeAttribute(paragraphStyleKey, range: range)
      if let ref = run.paragraphStyle, let data = try? JSONEncoder.form.encode(ref) { text.addAttribute(paragraphStyleKey, value: data, range: range) }
    }
    updateSpacing(text)
    text.endEditing()
  }
  public static func measured(_ element: ArtworkElement, points: Bool = false) -> CGSize {
    let size = cachedLayout(element).size
    let factor = points ? pointsPerMM : 1
    return .init(width: size.width * factor, height: size.height * factor)
  }
  private static func layout(_ element: ArtworkElement) -> (CTFrame, Double) {
    let entry = cachedLayout(element)
    return (entry.frame, entry.offset)
  }
  private static func decoration(_ run: CTRun, origin: CGPoint, height: Double, offset: Double)
    -> CGPath
  {
    let attrs = CTRunGetAttributes(run) as NSDictionary
    let path = CGMutablePath()
    guard CTRunGetGlyphCount(run) > 0, let raw = attrs[kCTFontAttributeName] else { return path }
    let font = raw as! CTFont
    var position = CGPoint.zero
    CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
    let baseline = height + offset - origin.y - position.y
    let thickness = max(0.05, CTFontGetUnderlineThickness(font))
    let width = CTRunGetTypographicBounds(run, CFRange(), nil, nil, nil)
    if ((attrs[NSAttributedString.Key.underlineStyle] as? NSNumber)?.intValue ?? 0) > 0 {
      path.addRect(
        .init(
          x: origin.x + position.x, y: baseline - CTFontGetUnderlinePosition(font) - thickness / 2,
          width: width, height: thickness))
    }
    if ((attrs[NSAttributedString.Key.strikethroughStyle] as? NSNumber)?.intValue ?? 0) > 0 {
      path.addRect(
        .init(
          x: origin.x + position.x, y: baseline - CTFontGetXHeight(font) / 2 - thickness / 2,
          width: width, height: thickness))
    }
    return path
  }
  private static func cachedLayout(_ element: ArtworkElement) -> LayoutEntry {
    let signature = Signature(element)
    if let found = cache.object(forKey: element.id as NSUUID), found.signature == signature {
      hits += 1
      return found
    }
    let text = attributed(element, millimeters: false)
    let setter = CTFramesetterCreateWithAttributedString(text)
    let width = element.width * pointsPerMM
    let height = element.height * pointsPerMM
    let size = CTFramesetterSuggestFrameSizeWithConstraints(
      setter, CFRange(), nil,
      .init(width: element.typography?.frameMode == "point" ? 100000 : width, height: 100000), nil)
    let offset =
      element.typography?.verticalAlignment == "middle"
      ? max(0, (height - size.height) / 2)
      : element.typography?.verticalAlignment == "bottom" ? max(0, height - size.height) : 0
    let box = CGPath(rect: .init(x: 0, y: 0, width: width, height: height), transform: nil)
    let frame = CTFramesetterCreateFrame(setter, CFRange(), box, nil)
    let lines = CTFrameGetLines(frame) as! [CTLine]
    var origins = [CGPoint](repeating: .zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRange(), &origins)
    var decorations: [(CGPath, String)] = []
    var mm = CGAffineTransform(scaleX: 1 / pointsPerMM, y: 1 / pointsPerMM)
    for (i, line) in lines.enumerated() {
      for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let path = decoration(run, origin: origins[i], height: height, offset: offset)
        if !path.isEmpty {
          let attrs = CTRunGetAttributes(run) as NSDictionary
          decorations.append(
            (
              path.copy(using: &mm)!,
              FormColor.hex(
                attrs[NSAttributedString.Key.foregroundColor] as? NSColor
                  ?? FormColor.color(element.color))
            ))
        }
      }
    }
    var drawingFrame = frame
    if !decorations.isEmpty {
      let plain = NSMutableAttributedString(attributedString: text)
      plain.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: plain.length))
      plain.removeAttribute(.strikethroughStyle, range: NSRange(location: 0, length: plain.length))
      drawingFrame = CTFramesetterCreateFrame(
        CTFramesetterCreateWithAttributedString(plain), CFRange(), box, nil)
    }
    let entry = LayoutEntry(
      signature, frame: frame, drawingFrame: drawingFrame, offset: offset,
      size: .init(width: size.width / pointsPerMM, height: size.height / pointsPerMM), text: text,
      decorations: decorations)
    cache.setObject(entry, forKey: element.id as NSUUID, cost: max(300, text.length * 100))
    builds += 1
    return entry
  }
  public static func overflows(_ element: ArtworkElement) -> Bool {
    let frame = layout(element).0
    let range = CTFrameGetVisibleStringRange(frame)
    return range.location + range.length < cachedLayout(element).text.length
  }
  public static func firstBaseline(_ element: ArtworkElement) -> Double {
    let entry = cachedLayout(element)
    guard CFArrayGetCount(CTFrameGetLines(entry.frame)) > 0 else { return 0 }
    var origin = CGPoint.zero
    CTFrameGetLineOrigins(entry.frame, CFRange(location: 0, length: 1), &origin)
    return element.height + entry.offset / pointsPerMM - origin.y / pointsPerMM
  }
  public static func verticalOffset(_ element: ArtworkElement, points: Bool = false) -> Double {
    cachedLayout(element).offset / (points ? 1 : pointsPerMM)
  }
  public static func draw(_ element: ArtworkElement, in context: CGContext) {
    let entry = cachedLayout(element)
    context.saveGState()
    context.clip(to: .init(x: 0, y: 0, width: element.width, height: element.height))
    context.saveGState()
    context.scaleBy(x: 1 / pointsPerMM, y: 1 / pointsPerMM)
    context.translateBy(x: 0, y: element.height * pointsPerMM + entry.offset)
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = .identity
    context.setAllowsFontSubpixelPositioning(true)
    context.setShouldSubpixelPositionFonts(true)
    context.setAllowsFontSubpixelQuantization(false)
    context.setShouldSubpixelQuantizeFonts(false)
    context.setAllowsFontSmoothing(false)
    context.setShouldSmoothFonts(false)
    CTFrameDraw(entry.drawingFrame, context)
    context.restoreGState()
    for (path, color) in entry.decorations {
      context.setFillColor(FormColor.color(color).cgColor)
      context.addPath(path)
      context.fillPath()
    }
    context.restoreGState()
  }
  public static func outlines(_ element: ArtworkElement) throws -> CGPath {
    let result = CGMutablePath()
    for (path, _) in try outlineRuns(element) { result.addPath(path) }
    return result
  }
  public static func outlineRuns(_ element: ArtworkElement) throws -> [(CGPath, String)] {
    try outlinePaintRuns(element).map { ($0.path, $0.color) }
  }
  public static func outlinePaintRuns(_ element: ArtworkElement) throws
    -> [(path: CGPath, color: String, swatchID: UUID?)] {
    let (frame, offset) = layout(element)
    let lines = CTFrameGetLines(frame) as! [CTLine]
    var origins = [CGPoint](repeating: .zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRange(), &origins)
    var result: [(path: CGPath, color: String, swatchID: UUID?)] = []
    let text = cachedLayout(element).text.string as NSString
    for (i, line) in lines.enumerated() {
      for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let path = CGMutablePath()
        let count = CTRunGetGlyphCount(run)
        let attrs = CTRunGetAttributes(run) as NSDictionary
        guard let font = attrs[kCTFontAttributeName] else { continue }
        let ct = font as! CTFont
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetPositions(run, CFRange(), &positions)
        CTRunGetStringIndices(run, CFRange(), &indices)
        for j in 0..<count {
          if let glyph = CTFontCreatePathForGlyph(ct, glyphs[j], nil) {
            let p = positions[j]
            let origin = origins[i]
            var transform = CGAffineTransform(
              a: 1, b: 0, c: 0, d: -1, tx: origin.x + p.x,
              ty: element.height * pointsPerMM + offset - origin.y - p.y)
            transform = CTRunGetTextMatrix(run).concatenating(transform)
            path.addPath(glyph, transform: transform)
          } else if indices[j] < text.length,
            let scalar = UnicodeScalar(text.character(at: indices[j])),
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
          {
            throw FormError.invalid(
              "This font contains a glyph without a vector outline. Keep it as live text or use a different font."
            )
          }
        }
        var ink: CGPath = path
        let decoration = decoration(
          run, origin: origins[i], height: element.height * pointsPerMM, offset: offset)
        if !decoration.isEmpty { ink = ink.union(decoration) }
        let frameRect = CGRect(
          x: 0, y: 0, width: element.width * pointsPerMM, height: element.height * pointsPerMM)
        if !frameRect.contains(ink.boundingBoxOfPath) {
          ink = ink.intersection(CGPath(rect: frameRect, transform: nil))
        }
        var mm = CGAffineTransform(scaleX: 1 / pointsPerMM, y: 1 / pointsPerMM)
        ink = ink.copy(using: &mm)!
        if !ink.isEmpty {
          result.append(
            (
              ink,
              FormColor.hex(
                attrs[NSAttributedString.Key.foregroundColor] as? NSColor
                  ?? FormColor.color(element.color)),
              (attrs[swatchKey] as? String).flatMap(UUID.init(uuidString:))
            ))
        }
      }
    }
    return result
  }
  public static func spans(from attributed: NSAttributedString, fallback: Typography,
    utf16Offset: Int = 0) -> [TextSpan]
  {
    var result: [TextSpan] = []
    attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) {
      attrs, range, _ in
      var style =
        (attrs[styleKey] as? Data).flatMap {
          try? JSONDecoder.form.decode(Typography.self, from: $0)
        } ?? fallback
      let font = attrs[.font] as? NSFont ?? self.font(fallback, size: 14)
      let assignedFont = self.font(style, size: font.pointSize)
      // AppKit can omit explicit selectors that currently equal a face's
      // defaults. Retain our assignment when the native font is unchanged;
      // otherwise a later font/default change would silently lose that intent.
      let assignedFeatures = assignedFont.fontDescriptor.object(forKey: .featureSettings) as? NSArray ?? []
      let actualFeatures = font.fontDescriptor.object(forKey: .featureSettings) as? NSArray ?? []
      let preserveFeatures = attrs[styleKey] != nil && assignedFont.fontName == font.fontName
        && assignedFeatures.isEqual(actualFeatures)
      let preserveAssignedName = attrs[styleKey] != nil && assignedFont.fontName == font.fontName
      if !preserveAssignedName { style.fontName = font.fontName }
      if let values = font.fontDescriptor.object(forKey: .variation) as? [NSNumber: NSNumber] {
        style.variations = Dictionary(
          uniqueKeysWithValues: values.map { ($0.key.intValue, $0.value.doubleValue) })
      }
      if !preserveFeatures, let values = font.fontDescriptor.object(forKey: .featureSettings)
        as? [[NSFontDescriptor.FeatureKey: Any]]
      {
        let selections: [(Int, Int)] = values.compactMap { v in
          guard let type = v[.typeIdentifier] as? Int,
            let selector = v[.selectorIdentifier] as? Int
          else { return nil }
          return (type, selector)
        }
        let independent = FontCatalog.independentFeatureTypes(font.fontName)
        let grouped = Dictionary(grouping: selections, by: { $0.0 })
        let previous = style.featureSelections
        style.features = [:]
        style.featureSelections = nil
        for (type, values) in grouped {
          let selectors = Array(Set(values.map { $0.1 })).sorted()
          if independent.contains(type) || selectors.count > 1 || previous?[type] != nil {
            if style.featureSelections == nil { style.featureSelections = [:] }
            style.featureSelections?[type] = selectors
          } else { style.features[type] = selectors.first }
        }
      } else if !preserveFeatures {
        style.features = [:]
        style.featureSelections = nil
      }
      let adjustment = (attrs[spacingKey] as? NSNumber)?.doubleValue ?? 0
      style.tracking = ((attrs[.kern] as? NSNumber)?.doubleValue ?? 0) - adjustment
      if attrs[spacingKey] != nil {
        style.pairKerning = [:]
        if let pair = (attrs[pairKey] as? NSNumber)?.doubleValue {
          for i in range.location..<NSMaxRange(range) { style.pairKerning[i + utf16Offset] = pair }
        }
      }
      style.baseline = (attrs[.baselineOffset] as? NSNumber)?.doubleValue ?? 0
      style.ligatures = (attrs[.ligature] as? NSNumber)?.intValue ?? 1
      style.underline = ((attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0) > 0
      style.strikethrough = ((attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) > 0
      if let p = attrs[.paragraphStyle] as? NSParagraphStyle {
        style.alignment =
          [NSTextAlignment.center: "center", .right: "right", .justified: "justified"][p.alignment]
          ?? "left"
        style.leading = p.maximumLineHeight
        style.paragraphBefore = p.paragraphSpacingBefore
        style.paragraphAfter = p.paragraphSpacing
        style.leftIndent = p.headIndent
        style.rightIndent = -p.tailIndent
        style.firstLineIndent = p.firstLineHeadIndent
      }
      var span = TextSpan(
          location: range.location + utf16Offset, length: range.length, typography: style,
          fontSize: font.pointSize,
          color: FormColor.hex(attrs[.foregroundColor] as? NSColor ?? .black))
      span.swatchID = (attrs[swatchKey] as? String).flatMap(UUID.init(uuidString:))
      span.textStyle = (attrs[textStyleKey] as? Data).flatMap { try? JSONDecoder.form.decode(TextStyleReference.self, from: $0) }
      span.paragraphStyle = (attrs[paragraphStyleKey] as? Data).flatMap { try? JSONDecoder.form.decode(TextStyleReference.self, from: $0) }
      result.append(span)
    }
    return result
  }
}

@MainActor public enum FontCatalog {
  private static let detailCache: NSCache<NSString, NSDictionary> = {
    let value = NSCache<NSString, NSDictionary>()
    value.countLimit = 256
    return value
  }()
  public static func invalidate() { detailCache.removeAllObjects() }
  public static func independentFeatureTypes(_ name: String) -> Set<Int> {
    Set((details(name)["features"] as? [[String: Any]] ?? []).compactMap {
      ($0["exclusive"] as? Bool) == false ? $0["id"] as? Int : nil
    })
  }
  public static var families: [String] { NSFontManager.shared.availableFontFamilies.sorted() }
  public static func faces(_ family: String) -> [(name: String, style: String)] {
    (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { v in
      guard v.count >= 2, let name = v[0] as? String, let style = v[1] as? String else {
        return nil
      }
      return (name, style)
    }
  }
  public static func details(_ name: String) -> [String: Any] {
    if let value = detailCache.object(forKey: name as NSString) { return value as! [String: Any] }
    guard let font = NSFont(name: name, size: 16) else {
      return ["font_name": name, "missing": true]
    }
    let ct = font as CTFont
    let axes = (CTFontCopyVariationAxes(ct) as? [[String: Any]] ?? []).map { axis in
      [
        "id": axis[kCTFontVariationAxisIdentifierKey as String] ?? 0,
        "name": axis[kCTFontVariationAxisNameKey as String] ?? "Axis",
        "minimum": axis[kCTFontVariationAxisMinimumValueKey as String] ?? 0,
        "maximum": axis[kCTFontVariationAxisMaximumValueKey as String] ?? 1,
        "default": axis[kCTFontVariationAxisDefaultValueKey as String] ?? 0,
      ]
    }
    let features = (CTFontCopyFeatures(ct) as? [[String: Any]] ?? []).map { feature in
      [
        "id": feature[kCTFontFeatureTypeIdentifierKey as String] ?? 0,
        "name": feature[kCTFontFeatureTypeNameKey as String] ?? "Feature",
        "exclusive": feature[kCTFontFeatureTypeExclusiveKey as String] ?? false,
        "selectors": (feature[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] ?? [])
          .map {
            [
              "id": $0[kCTFontFeatureSelectorIdentifierKey as String] ?? 0,
              "name": $0[kCTFontFeatureSelectorNameKey as String] ?? "Option",
              "default": $0[kCTFontFeatureSelectorDefaultKey as String] ?? false,
            ]
          },
      ]
    }
    let result: [String: Any] = [
      "font_name": font.fontName, "family": font.familyName ?? "",
      "display_name": font.displayName ?? name, "missing": false, "axes": axes,
      "features": features,
    ]
    detailCache.setObject(result as NSDictionary, forKey: name as NSString)
    return result
  }
  public static func missing(in art: Artwork) -> [String] {
    Set(
      art.elements.filter { $0.kind == "text" }.flatMap { e in
        [e.typography?.fontName ?? Typography().fontName]
          + (e.textRuns ?? []).map { $0.typography.fontName }
      }
    ).filter { NSFont(name: $0, size: 12) == nil }.sorted()
  }
}

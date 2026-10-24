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
  private struct Signature: Equatable {
    var text: String, size: Double, color: String, width: Double, height: Double,
      style: Typography?, runs: [TextSpan]?
    init(_ e: ArtworkElement) {
      text = e.text
      size = e.fontSize
      color = e.color
      width = e.width
      height = e.height
      style = e.typography
      runs = e.textRuns
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
  public static func invalidateFonts() { cache.removeAllObjects() }
  public static var diagnostics: [String: Any] {
    ["layout_builds": builds, "layout_cache_hits": hits, "layout_cache_limit": 800]
  }
  public static func font(_ style: Typography, size: Double) -> NSFont {
    let base =
      NSFont(name: style.fontName, size: size) ?? NSFont.systemFont(ofSize: size, weight: .medium)
    var attrs: [NSFontDescriptor.AttributeName: Any] = [:]
    if !style.features.isEmpty {
      attrs[.featureSettings] = style.features.map {
        [
          NSFontDescriptor.FeatureKey.typeIdentifier: $0.key,
          NSFontDescriptor.FeatureKey.selectorIdentifier: $0.value,
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
  public static func attributes(_ style: Typography, size: Double, color: String, millimeters: Bool)
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
    return [
      styleKey: (try? JSONEncoder.form.encode(style)) ?? Data(),
      .font: font(style, size: size * f), .foregroundColor: FormColor.color(color),
      .paragraphStyle: p, .kern: style.tracking * f, .baselineOffset: style.baseline * f,
      .ligature: style.ligatures,
      .underlineStyle: style.underline ? NSUnderlineStyle.single.rawValue : 0,
      .strikethroughStyle: style.strikethrough ? NSUnderlineStyle.single.rawValue : 0,
      .expansion: log(style.horizontalScale / 100),
    ]
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
        base, size: element.fontSize, color: element.color, millimeters: millimeters))
    for run in element.textRuns ?? [] {
      let original = element.text as NSString
      guard run.location + run.length <= original.length else { continue }
      let start = caseText(original.substring(to: run.location)).utf16.count
      let length = caseText(
        original.substring(with: NSRange(location: run.location, length: run.length))
      ).utf16.count
      guard start + length <= result.length else { continue }
      result.setAttributes(
        attributes(run.typography, size: run.fontSize, color: run.color, millimeters: millimeters),
        range: .init(location: start, length: length))
    }
    let factor = millimeters ? 1 / pointsPerMM : 1
    let nsText = result.string as NSString
    if base.wordSpacing != 0 {
      for i in 0..<nsText.length where nsText.character(at: i) == 32 {
        result.addAttribute(
          .kern, value: (base.tracking + base.wordSpacing) * factor,
          range: .init(location: i, length: 1))
      }
    }
    for (i, value) in base.pairKerning where i >= 0 && i < result.length {
      result.addAttribute(
        .kern, value: (base.tracking + value) * factor, range: .init(location: i, length: 1))
    }
    return result
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
    let baseline = height - offset - origin.y - position.y
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
  public static func draw(_ element: ArtworkElement, in context: CGContext) {
    let entry = cachedLayout(element)
    context.saveGState()
    context.clip(to: .init(x: 0, y: 0, width: element.width, height: element.height))
    context.saveGState()
    context.scaleBy(x: 1 / pointsPerMM, y: 1 / pointsPerMM)
    context.translateBy(x: 0, y: element.height * pointsPerMM - entry.offset)
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
    let (frame, offset) = layout(element)
    let lines = CTFrameGetLines(frame) as! [CTLine]
    var origins = [CGPoint](repeating: .zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRange(), &origins)
    var result: [(CGPath, String)] = []
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
              ty: element.height * pointsPerMM - offset - origin.y - p.y)
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
                  ?? FormColor.color(element.color))
            ))
        }
      }
    }
    return result
  }
  public static func spans(from attributed: NSAttributedString, fallback: Typography) -> [TextSpan]
  {
    var result: [TextSpan] = []
    attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) {
      attrs, range, _ in
      var style =
        (attrs[styleKey] as? Data).flatMap {
          try? JSONDecoder.form.decode(Typography.self, from: $0)
        } ?? fallback
      let font = attrs[.font] as? NSFont ?? self.font(fallback, size: 14)
      let preserveMissing =
        NSFont(name: style.fontName, size: font.pointSize) == nil
        && self.font(style, size: font.pointSize).fontName == font.fontName
      if !preserveMissing { style.fontName = font.fontName }
      if let values = font.fontDescriptor.object(forKey: .variation) as? [NSNumber: NSNumber] {
        style.variations = Dictionary(
          uniqueKeysWithValues: values.map { ($0.key.intValue, $0.value.doubleValue) })
      }
      if let values = font.fontDescriptor.object(forKey: .featureSettings)
        as? [[NSFontDescriptor.FeatureKey: Any]]
      {
        let selections: [(Int, Int)] = values.compactMap { v in
          guard let type = v[.typeIdentifier] as? Int,
            let selector = v[.selectorIdentifier] as? Int
          else { return nil }
          return (type, selector)
        }
        style.features = selections.reduce(into: [:]) { $0[$1.0] = $1.1 }
      }
      style.tracking = (attrs[.kern] as? NSNumber)?.doubleValue ?? 0
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
      result.append(
        .init(
          location: range.location, length: range.length, typography: style,
          fontSize: font.pointSize,
          color: FormColor.hex(attrs[.foregroundColor] as? NSColor ?? .black)))
    }
    return result
  }
}

@MainActor public enum FontCatalog {
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
    return [
      "font_name": font.fontName, "family": font.familyName ?? "",
      "display_name": font.displayName ?? name, "missing": false, "axes": axes,
      "features": features,
    ]
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

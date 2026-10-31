import CoreText
import Foundation
import FormCore

/// Converts decoded native NodeChange text, without passing through outlines or SVG.
/// Wire field semantics were inspected in OpenPencil e9aa2b0, fig.kiwi and
/// node-change/text/values.ts, style/runs.ts, and text/lines.ts. Source layout and
/// descriptors remain in the importer's source metadata; this is editable text.
public enum FigmaTypography {
  private struct Style {
    var typography: Typography
    var size: Double
    var color: String
    var paintStack: [ArtworkPaintLayer]?
    var caseFeatures: Set<Int> = []
  }

  public static func apply(node: FigmaValue, to element: inout ArtworkElement,
    scale: Double = 25.4 / 96,
    paints: ((FigmaValue) throws -> [ArtworkPaintLayer])? = nil) throws -> [FigmaImportIssue] {
    try Task.checkCancellation()
    guard scale.isFinite, scale > 0, scale <= 100 else { throw FormError.invalid("Invalid Figma text scale.") }
    guard let data = node["textData"], let text = data["characters"]?.stringValue else {
      throw FormError.invalid("Figma text is missing its native character data.")
    }
    let units = Array(text.utf16)
    guard units.count <= 200_000 else { throw FormError.invalid("Figma text exceeds the character budget.") }
    let id = FigmaArtworkImporter.sourceID(node["guid"]) ?? "text"
    let points = scale / (25.4 / 96) * 0.75
    var issues: [FigmaImportIssue] = []
    func issue(_ feature: String, _ message: String, severity: String = "warning") {
      issues.append(.init(id, feature, message, severity: severity))
    }
    let table = data["styleOverrideTable"]?.arrayValue ?? []
    guard table.count <= 4096 else { throw FormError.invalid("Figma text exceeds the style budget.") }
    var overrides: [Int: FigmaValue] = [:]
    for value in table {
      guard let key = value["styleID"]?.integerValue, key >= 0, overrides[key] == nil else {
        throw FormError.invalid("Figma text contains missing or duplicate style identities.")
      }
      overrides[key] = value
    }
    var paintCache: [Data: [ArtworkPaintLayer]] = [:]
    let cachedPaints: ((FigmaValue) throws -> [ArtworkPaintLayer])?
    if let paints {
      cachedPaints = { effective in
        let fields = ["fillPaints", "strokePaints", "strokeWeight", "strokeAlign", "strokeCap", "strokeJoin", "miterLimit", "dashPattern", "borderStrokeWeightsIndependent", "colorProfile"]
        var values: [String: FigmaValue] = [:]
        for field in fields { values[field] = effective[field] }
        let key = try FigmaValue.object(values).encodedJSON()
        if let existing = paintCache[key] { return existing }
        let stack = try paints(effective); paintCache[key] = stack; return stack
      }
    } else { cachedPaints = nil }
    var base = try style(node, inherited: nil, documentNode: node, points: points,
      color: element.color, id: id, issues: &issues, paints: cachedPaints)
    switch node["textAutoResize"]?.stringValue ?? "NONE" {
    case "WIDTH_AND_HEIGHT": base.typography.frameMode = "point"
    case "HEIGHT":
      base.typography.frameMode = "area"
      issue("textAutoResize", "Auto-height text keeps its copied frame size; LAB does not retain automatic frame growth.", severity: "info")
    case "NONE": base.typography.frameMode = "area"
    default: issue("textAutoResize", "Unknown text sizing mode uses the copied area frame.")
    }
    var styles = [0: base]
    for (key, override) in overrides where key != 0 {
      try Task.checkCancellation()
      styles[key] = try style(override, inherited: base, documentNode: node, points: points,
        color: element.color, id: id, issues: &issues, paints: cachedPaints)
    }
    let rawIDs = data["characterStyleIDs"]?.arrayValue ?? []
    guard rawIDs.count <= units.count else { throw FormError.invalid("Figma style ranges exceed the UTF-16 text length.") }
    var ids: [Int] = []
    ids.reserveCapacity(units.count)
    for value in rawIDs {
      guard let value = value.integerValue, value >= 0, styles[value] != nil else {
        throw FormError.invalid("Figma character style references a missing override.")
      }
      ids.append(value)
    }
    ids += repeatElement(0, count: units.count - ids.count)
    // Native offsets are UTF-16, not Swift Character counts. Never split a
    // surrogate pair, even when a malformed producer changes style mid-scalar.
    for index in units.indices.dropFirst() where (0xD800...0xDBFF).contains(units[index - 1])
      && (0xDC00...0xDFFF).contains(units[index]) {
      guard ids[index] == ids[index - 1] else { throw FormError.invalid("A Figma style boundary splits a Unicode scalar.") }
    }

    let paragraphs = paragraphRanges(units)
    let lines = data["lines"]?.arrayValue ?? []
    if lines.count > paragraphs.count { issue("paragraphs", "Extra source paragraph records have no corresponding characters.") }
    var runs: [TextSpan] = []
    for (paragraphIndex, range) in paragraphs.enumerated() where range.length > 0 {
      try Task.checkCancellation()
      let line = paragraphIndex < lines.count ? lines[paragraphIndex] : nil
      let paragraphID = line?["styleId"]?.integerValue ?? 0
      guard paragraphID == 0 || overrides[paragraphID] != nil else {
        throw FormError.invalid("Figma paragraph references a missing style override.")
      }
      if let kind = line?["lineType"]?.stringValue, kind != "PLAIN" {
        issue("paragraphList", "Source \(kind) paragraph markers/numbering remain metadata; characters stay editable.")
      }
      if (line?["indentationLevel"]?.integerValue ?? 0) != 0 {
        issue("paragraphIndentation", "List nesting levels do not map to a physical indent without source layout metrics.")
      }
      var start = range.location
      while start < NSMaxRange(range) {
        var end = start + 1
        while end < NSMaxRange(range), ids[end] == ids[start] { end += 1 }
        var value = styles[ids[start]]!
        if let override = overrides[paragraphID], paragraphID != 0 {
          try paragraph(override, to: &value.typography, points: points, id: id, issues: &issues)
        }
        if let direction = line?["sourceDirectionality"]?.stringValue {
          switch direction {
          case "LTR": value.typography.direction = "ltr"
          case "RTL": value.typography.direction = "rtl"
          case "AUTO": value.typography.direction = "natural"
          default: issue("textDirection", "Unknown source text direction uses Unicode natural direction.")
          }
        } else if line?["directionalityIntent"]?.stringValue == "EXPLICIT" {
          value.typography.direction = line?["directionality"]?.stringValue == "RTL" ? "rtl" : "ltr"
        }
        let stack = value.paintStack == base.paintStack ? nil : value.paintStack
        if let last = runs.last, last.paintStack == stack, last.typography == value.typography, last.fontSize == value.size,
          last.color == value.color, last.location + last.length == start {
          runs[runs.count - 1].length += end - start
        } else {
          guard runs.count < 8192 else { throw FormError.invalid("Figma text exceeds the rich-span budget.") }
          var span = TextSpan(location: start, length: end - start, typography: value.typography,
            fontSize: value.size, color: value.color)
          span.paintStack = stack; runs.append(span)
        }
        start = end
      }
    }
    if let truncation = node["textTruncation"]?.stringValue, truncation != "DISABLED" {
      issue("textTruncation", "Source truncation is not retained; the full editable text is preserved.")
    }
    if (node["maxLines"]?.integerValue ?? 0) > 0 { issue("maxLines", "Source maximum-line constraints are not retained.") }
    if data["glyphs"]?.arrayValue?.isEmpty == false || node["derivedTextData"]?["glyphs"]?.arrayValue?.isEmpty == false {
      issue("textLayout", "LAB reshapes editable text with local fonts. Source glyph positions and baselines are retained as provenance for comparison.")
    }
    try validateTypography(base.typography)
    for run in runs { try validateTypography(run.typography) }
    // Publish only after every character/range/style has passed validation.
    element.kind = "text"; element.text = text; element.typography = base.typography
    element.fontSize = base.size; element.color = base.color; element.paintStack = base.paintStack
    element.textRuns = runs.count == 1 && runs[0].typography == base.typography
      && runs[0].fontSize == base.size && runs[0].color == base.color && runs[0].paintStack == nil ? nil : (runs.isEmpty ? nil : runs)
    var seen = Set<String>()
    return issues.filter { seen.insert($0.feature + "|" + $0.message).inserted }
  }

  private static func style(_ value: FigmaValue, inherited: Style?, documentNode: FigmaValue,
    points: Double, color: String, id: String, issues: inout [FigmaImportIssue],
    paints: ((FigmaValue) throws -> [ArtworkPaintLayer])?) throws -> Style {
    var result = inherited ?? Style(typography: Typography(), size: 12, color: color, paintStack: nil)
    if inherited == nil { result.typography.kerningMode = "metrics"; result.typography.direction = "natural" }
    if let size = value["fontSize"] {
      result.size = try number(size, label: "font size") * points
      guard (0.1...10000).contains(result.size) else { throw FormError.invalid("Figma font size is outside the supported point range.") }
    } else if inherited == nil {
      issues.append(.init(id, "fontSize", "Text has no explicit source font size; the 12-point fallback requires review."))
    }
    if let name = value["fontName"] {
      result.typography.fontName = try resolveFont(name, documentNode: documentNode, id: id, issues: &issues)
    } else if inherited == nil {
      issues.append(.init(id, "font", "Text has no font descriptor; LAB uses its default font."))
    }
    if let spacing = value["letterSpacing"] {
      result.typography.tracking = try length(spacing, size: result.size, points: points, lineHeight: false)
    }
    if let leading = value["lineHeight"] {
      result.typography.leading = try length(leading, size: result.size, points: points, lineHeight: true)
    } else if inherited != nil, value["fontSize"] != nil, let leading = documentNode["lineHeight"] {
      result.typography.leading = try length(leading, size: result.size, points: points, lineHeight: true)
    }
    if inherited != nil, value["fontSize"] != nil, value["letterSpacing"] == nil, let spacing = documentNode["letterSpacing"] {
      result.typography.tracking = try length(spacing, size: result.size, points: points, lineHeight: false)
    }
    try paragraph(value, to: &result.typography, points: points, id: id, issues: &issues)
    if let alignment = value["textAlignVertical"]?.stringValue {
      if let mapped = ["TOP": "top", "CENTER": "middle", "BOTTOM": "bottom"][alignment] { result.typography.verticalAlignment = mapped }
      else { issues.append(.init(id, "textAlignment", "Unknown vertical text alignment is not applied.")) }
    }
    if let decoration = value["textDecoration"]?.stringValue {
      result.typography.underline = decoration == "UNDERLINE"
      result.typography.strikethrough = decoration == "STRIKETHROUGH"
      if !["NONE", "UNDERLINE", "STRIKETHROUGH"].contains(decoration) { issues.append(.init(id, "textDecoration", "Unknown text decoration is not applied.")) }
    }
    if let textCase = value["textCase"]?.stringValue {
      for feature in result.caseFeatures { result.typography.resetFeature(feature) }
      result.caseFeatures = []
      switch textCase {
      case "ORIGINAL": result.typography.caseTreatment = "original"
      case "UPPER": result.typography.caseTreatment = "uppercase"
      case "LOWER": result.typography.caseTreatment = "lowercase"
      case "SMALL_CAPS": result.typography.caseTreatment = "original"; result.typography.features[37] = 1; result.caseFeatures = [37]
      case "SMALL_CAPS_FORCED": result.typography.caseTreatment = "original"; result.typography.features[37] = 1; result.typography.features[38] = 1; result.caseFeatures = [37,38]
      default: issues.append(.init(id, "textCase", "Source case treatment \(textCase) is retained in metadata; original characters are preserved."))
      }
    }
    if let variations = value["fontVariations"]?.arrayValue {
      guard variations.count <= 64 else { throw FormError.invalid("Too many Figma font variation axes.") }
      for axis in variations {
        guard let tag = axis["axisTag"]?.integerValue, tag > 0, UInt64(tag) <= UInt32.max,
          let amount = axis["value"] else { throw FormError.invalid("Invalid Figma font variation axis.") }
        result.typography.variations[tag] = try number(amount, label: "font variation")
      }
    }
    applyFeatures(value, to: &result.typography, id: id, issues: &issues)
    if value["fontVariantCaps"] != nil { result.caseFeatures = [] }
    for key in ["textAutoResize", "textCase", "textAlignHorizontal", "textAlignVertical", "textDecoration", "leadingTrim", "textDecorationStyle", "textTruncation", "fontVariantNumericFigure", "fontVariantNumericSpacing", "fontVariantNumericFraction", "fontVariantPosition", "fontVariantCaps"] where value[key] != nil && value[key]?.stringValue == nil {
      issues.append(.init(id, key, "Unknown numeric source enum for \(key) is retained as metadata."))
    }
    if let paints, inherited == nil || ["fillPaints", "strokePaints", "strokeWeight", "strokeAlign", "strokeCap", "strokeJoin", "dashPattern"].contains(where: { value[$0] != nil }) {
      var effective = documentNode.objectValue ?? [:]
      for (key, child) in value.objectValue ?? [:] { effective[key] = child }
      result.paintStack = try paints(.object(effective))
    }
    if let rawPaints = value["fillPaints"]?.arrayValue {
      let active = rawPaints.filter { $0["visible"]?.boolValue != false }
      if active.count == 1, active[0]["type"]?.stringValue == "SOLID", let c = active[0]["color"] {
        let profile = value["colorProfile"]?.stringValue ?? documentNode["colorProfile"]?.stringValue ?? "SRGB"
        let converted = try FigmaColor.convert(c, profile: profile)
        result.color = converted.hex
        let colorAlpha = converted.alpha
        let paintAlpha = try number(active[0]["opacity"] ?? .double(1), label: "text opacity")
        guard (0...1).contains(colorAlpha), (0...1).contains(paintAlpha) else { throw FormError.invalid("Invalid Figma text opacity.") }
        let alpha = colorAlpha * paintAlpha
        if paints == nil, inherited != nil, abs(alpha - 1) > 1e-8 { issues.append(.init(id, "textRunOpacity", "Per-range paint opacity cannot be represented by a native text span.")) }
      } else if paints == nil, inherited != nil {
        issues.append(.init(id, "textRunPaint", "Per-range paint stacks, gradients or invisible fills retain the base text color; source paints remain in metadata."))
      }
    }
    for key in ["textDecorationFillPaints", "textUnderlineOffset", "textDecorationThickness", "hyperlink", "mention", "responsiveTextStyleVariants", "parameterConsumptionMap"] where value[key] != nil {
      issues.append(.init(id, key, "Source \(key) is retained as metadata but is not mapped to editable LAB typography."))
    }
    if let trim = value["leadingTrim"]?.stringValue, trim != "NONE" { issues.append(.init(id, "leadingTrim", "Cap-height trimming requires layout review.")) }
    if let decoration = value["textDecorationStyle"]?.stringValue, decoration != "SOLID" { issues.append(.init(id, "textDecorationStyle", "Decorations use native solid strokes.")) }
    if value["detachOpticalSizeFromFontSize"]?.boolValue == false {
      issues.append(.init(id, "opticalSizing", "Copied optical-size axes are retained as values; automatic optical sizing is not linked to future font-size changes."))
    }
    if !result.typography.variations.isEmpty {
      let font = CTFontCreateWithName(result.typography.fontName as CFString, 12, nil)
      let axes = CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []
      for (tag, amount) in result.typography.variations {
        if let axis = axes.first(where: { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue == tag }) {
          let minimum = (axis[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue ?? -.infinity
          let maximum = (axis[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue ?? .infinity
          if !(minimum...maximum).contains(amount) { issues.append(.init(id, "fontVariation", "Axis \(tag) is outside the local font's supported range; its source value is retained.")) }
        } else { issues.append(.init(id, "fontVariation", "Axis \(tag) is unavailable in the local font; its source value is retained.")) }
      }
    }
    return result
  }

  private static func paragraph(_ value: FigmaValue, to typography: inout Typography, points: Double,
    id: String, issues: inout [FigmaImportIssue]) throws {
    if let alignment = value["textAlignHorizontal"]?.stringValue {
      if let mapped = ["LEFT": "left", "CENTER": "center", "RIGHT": "right", "JUSTIFIED": "justified"][alignment] { typography.alignment = mapped }
      else { issues.append(.init(id, "textAlignment", "Unknown horizontal text alignment is not applied.")) }
    }
    if let indent = value["paragraphIndent"] { typography.firstLineIndent = try number(indent, label: "paragraph indent") * points }
    if let spacing = value["paragraphSpacing"] { typography.paragraphAfter = try number(spacing, label: "paragraph spacing") * points }
  }

  private static func number(_ value: FigmaValue, label: String) throws -> Double {
    guard let number = value.numberValue, number.isFinite, abs(number) <= 1_000_000 else { throw FormError.invalid("Invalid or excessive Figma \(label).") }
    return number
  }
  private static func length(_ value: FigmaValue, size: Double, points: Double, lineHeight: Bool) throws -> Double {
    guard let raw = value["value"], let unit = value["units"]?.stringValue else { throw FormError.invalid("Invalid Figma text spacing.") }
    let n = try number(raw, label: "text spacing")
    let result: Double
    switch unit {
    case "PIXELS": result = n * points
    case "PERCENT": result = lineHeight && n == 100 ? 0 : size * n / 100
    case "RAW": result = lineHeight ? size * n : size * n / 100
    default: throw FormError.invalid("Unsupported Figma text spacing units.")
    }
    guard result.isFinite, abs(result) <= 10000, !lineHeight || result >= 0 else { throw FormError.invalid("Figma text spacing exceeds its supported range.") }
    return result
  }

  private static func paragraphRanges(_ units: [UInt16]) -> [NSRange] {
    var ranges: [NSRange] = [], start = 0, index = 0
    while index < units.count {
      let unit = units[index]; index += 1
      if unit == 13 || unit == 10 || unit == 0x2029 {
        if unit == 13, index < units.count, units[index] == 10 { index += 1 }
        ranges.append(.init(location: start, length: index - start)); start = index
      }
    }
    ranges.append(.init(location: start, length: units.count - start))
    return ranges
  }

  private static func resolveFont(_ descriptor: FigmaValue, documentNode: FigmaValue,
    id: String, issues: inout [FigmaImportIssue]) throws -> String {
    let family = descriptor["family"]?.stringValue ?? "", style = descriptor["style"]?.stringValue ?? "Regular"
    let postscript = descriptor["postscript"]?.stringValue ?? ""
    guard !family.isEmpty || !postscript.isEmpty, family.count <= 250, style.count <= 250,
      postscript.count <= 250 else { throw FormError.invalid("Invalid Figma font descriptor.") }
    if !postscript.isEmpty {
      let font = CTFontCreateWithName(postscript as CFString, 12, nil)
      if CTFontCopyPostScriptName(font) as String == postscript { return postscript }
    }
    var attributes: [String: Any] = [kCTFontFamilyNameAttribute as String: family, kCTFontStyleNameAttribute as String: style]
    let metadata = (documentNode["derivedTextData"]?["fontMetaData"]?.arrayValue ?? [])
      + (documentNode["textData"]?["fontMetaData"]?.arrayValue ?? [])
    if let face = metadata.first(where: { $0["key"]?["family"]?.stringValue == family && $0["key"]?["style"]?.stringValue == style }),
      let weight = face["fontWeight"]?.numberValue, weight.isFinite {
      attributes[kCTFontTraitsAttribute as String] = [kCTFontWeightTrait as String: min(1, max(-1, (weight - 400) / 500))]
    }
    let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), 12, nil)
    func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
    if !family.isEmpty, normalized(CTFontCopyFamilyName(font) as String) == normalized(family) {
      let actualStyle = CTFontCopyName(font, kCTFontStyleNameKey).map { $0 as String } ?? ""
      if normalized(actualStyle) != normalized(style) || !postscript.isEmpty {
        issues.append(.init(id, "fontSubstitution", "Font '\(family) \(style)' resolves to '\(CTFontCopyPostScriptName(font))'; compare metrics with the source."))
      }
      return CTFontCopyPostScriptName(font) as String
    }
    let requested = !postscript.isEmpty ? postscript : family + (style.isEmpty ? "" : "-" + style.replacingOccurrences(of: " ", with: ""))
    issues.append(.init(id, "missingFont", "Font '\(family) \(style)' is unavailable. Its assignment is preserved; LAB will display a fallback."))
    return requested.isEmpty ? "HelveticaNeue-Medium" : requested
  }

  private static func applyFeatures(_ value: FigmaValue, to typography: inout Typography,
    id: String, issues: inout [FigmaImportIssue]) {
    let independent: [String: (Int, Int)] = ["LIGA": (1, 2), "RLIG": (1, 0), "DLIG": (1, 4),
      "CLIG": (1, 18), "HLIG": (1, 20), "CALT": (36, 0), "ZERO": (14, 4)]
    let boolFields = ["fontVariantCommonLigatures": "LIGA", "fontVariantContextualLigatures": "CLIG",
      "fontVariantDiscretionaryLigatures": "DLIG", "fontVariantHistoricalLigatures": "HLIG", "fontVariantSlashedZero": "ZERO"]
    for (field, tag) in boolFields {
      if let enabled = value[field]?.boolValue, let (type, selector) = independent[tag] {
        typography.setIndependentFeature(type, selector: selector, value: enabled)
        if tag == "LIGA" { typography.ligatures = enabled ? 1 : 0 }
      }
    }
    for (field, enabled) in [("toggledOnOTFeatures", true), ("toggledOffOTFeatures", false)] {
      for feature in value[field]?.arrayValue ?? [] {
        let tag = feature.stringValue ?? "unknown"
        if let (type, selector) = independent[tag] {
          typography.setIndependentFeature(type, selector: selector, value: enabled)
          if tag == "LIGA" { typography.ligatures = enabled ? 1 : 0 }
        } else if tag == "KERN" { typography.kerningMode = enabled ? "metrics" : "none" }
        else { issues.append(.init(id, "fontFeature", "OpenType feature \(tag) is retained as metadata but has no verified native mapping.")) }
      }
    }
    let exclusive: [(String, Int, [String: Int])] = [
      ("fontVariantNumericFigure", 21, ["OLDSTYLE": 0, "LINING": 1]),
      ("fontVariantNumericSpacing", 6, ["TABULAR": 0, "PROPORTIONAL": 1]),
      ("fontVariantNumericFraction", 11, ["NORMAL": 0, "DIAGONAL": 2, "STACKED": 1]),
      ("fontVariantPosition", 10, ["NORMAL": 0, "SUB": 2, "SUPER": 1])]
    for (field, type, map) in exclusive {
      if let name = value[field]?.stringValue {
        if let selector = map[name] { typography.features[type] = selector }
        else if name == "NORMAL" { typography.resetFeature(type) }
        else { issues.append(.init(id, "fontFeature", "Unknown \(field) value \(name) is not applied.")) }
      }
    }
    if let enabled = value["fontVariantOrdinal"]?.boolValue { typography.features[10] = enabled ? 3 : 0 }
    if let caps = value["fontVariantCaps"]?.stringValue {
      switch caps {
      case "NORMAL": typography.resetFeature(37); typography.resetFeature(38)
      case "SMALL": typography.features[37] = 1
      case "ALL_SMALL": typography.features[37] = 1; typography.features[38] = 1
      case "PETITE": typography.features[37] = 2
      case "ALL_PETITE": typography.features[37] = 2; typography.features[38] = 2
      default: issues.append(.init(id, "fontFeature", "Source caps feature \(caps) is retained in metadata."))
      }
    }
  }
}

import AppKit
import CoreText
import FormCore

extension SVGImportBuilder {
  func text(_ node: SVGNode, style: [String: String], context: SVGContext) throws -> ArtworkElement?
  {
    struct Part {
      var text: String
      let style: [String: String]
    }
    var parts: [Part] = []
    var created: [ArtworkElement] = []
    var x = 0.0
    var y = 0.0
    var chunkStyle = style
    let preserve = node["xml:space"] == "preserve" || style["white-space"] == "pre"
    func coordinate(_ item: SVGNode, _ key: String, _ computed: [String: String], _ axis: String)
      throws -> Double?
    {
      guard let raw = item[key] else { return nil }
      let fields = raw.split(whereSeparator: { $0.isWhitespace || $0 == "," })
      guard let first = fields.first else { return nil }
      if fields.count > 1 {
        issue(item, "Per-character \(key) lists use their first position; review text placement.")
      }
      return try SVGLength.value(
        String(first), reference: axis == "x" ? context.width : context.height,
        font: Double(computed["font-size"] ?? "16") ?? 16)
    }
    func flush() throws {
      if parts.isEmpty { return }
      if !preserve {
        while parts.first?.text.first == " " {
          parts[0].text.removeFirst()
          if parts[0].text.isEmpty { parts.removeFirst() }
        }
        while parts.last?.text.last == " " {
          parts[parts.count - 1].text.removeLast()
          if parts.last!.text.isEmpty { parts.removeLast() }
        }
      }
      guard !parts.isEmpty else { return }
      var runs: [TextSpan] = []
      var value = ""
      let baseFill = chunkStyle["fill"] ?? "black"
      let baseColor = try SVGColor.parse(
        baseFill == "none" || baseFill.hasPrefix("url(") ? "black" : baseFill,
        current: chunkStyle["color"] ?? "black")
      let alpha = baseColor.alpha * (try SVGLength.opacity(chunkStyle["fill-opacity"]))
      for part in parts where !part.text.isEmpty {
        let typography = try textStyle(part.style, node: node, context: context)
        let rawFill = part.style["fill"] ?? "black"
        if rawFill.hasPrefix("url(") {
          issue(
            node,
            "Gradient text fills use a solid fallback; outline the text to retain gradient painting."
          )
        }
        let color = try SVGColor.parse(
          rawFill == "none" || rawFill.hasPrefix("url(") ? "black" : rawFill,
          current: part.style["color"] ?? "black")
        let runAlpha = color.alpha * (try SVGLength.opacity(part.style["fill-opacity"]))
        if abs(runAlpha - alpha) > 1e-8 {
          issue(node, "Different opacity within one text chunk uses the chunk's opacity.")
        }
        runs.append(
          .init(
            location: value.utf16.count, length: part.text.utf16.count, typography: typography,
            fontSize: (Double(part.style["font-size"] ?? "16") ?? 16) * context.scale
              * TypographyEngine.pointsPerMM, color: color.hex))
        value += part.text
      }
      guard !value.isEmpty else {
        parts = []
        return
      }
      let base = try textStyle(chunkStyle, node: node, context: context)
      let size =
        (Double(chunkStyle["font-size"] ?? "16") ?? 16) * context.scale
        * TypographyEngine.pointsPerMM
      guard size >= 0.1, size <= 10000 else {
        throw FormError.invalid("SVG text size is outside 0.1–10000 points.")
      }
      var e = ArtworkElement(
        kind: "text", x: x * context.scale, y: y * context.scale, width: 1000, height: 1000,
        text: value, color: baseColor.hex, fontSize: size)
      e.typography = base
      e.textRuns =
        runs.count == 1 && runs[0].typography == base && runs[0].fontSize == size
          && runs[0].color == e.color ? nil : runs
      e.fillEnabled = baseFill != "none"
      e.fillOpacity = alpha
      let measured = TypographyEngine.measured(e)
      let attributed = TypographyEngine.attributed(e)
      let advance =
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
        / TypographyEngine.pointsPerMM
      e.width = max(0.1, measured.width + 0.2)
      e.height = max(0.1, measured.height + 0.2)
      let baseline = TypographyEngine.firstBaseline(e)
      let anchor = chunkStyle["text-anchor"] ?? "start"
      let reverse = chunkStyle["direction"] == "rtl"
      let ratio = anchor == "middle" ? 0.5 : (anchor == "end") != reverse ? 1.0 : 0.0
      e.x -= advance * ratio
      e.y -= baseline
      if let dominant = chunkStyle["dominant-baseline"], !["auto", "alphabetic"].contains(dominant)
      {
        issue(node, "Baseline '\(dominant)' uses alphabetic placement; review text alignment.")
      }
      if chunkStyle["stroke"] != nil && chunkStyle["stroke"] != "none" {
        issue(node, "Text strokes are omitted; text remains editable.")
      }
      e.name = String(value.prefix(500))
      created.append(e)
      x += advance / context.scale
      parts = []
    }
    func gather(_ item: SVGNode, _ computed: [String: String], root: Bool = false) throws {
      let positioned = root || ["x", "y", "dx", "dy"].contains(where: { item[$0] != nil })
      if positioned {
        try flush()
        if let v = try coordinate(item, "x", computed, "x") { x = v }
        if let v = try coordinate(item, "y", computed, "y") { y = v }
        x += try coordinate(item, "dx", computed, "x") ?? 0
        y += try coordinate(item, "dy", computed, "y") ?? 0
        chunkStyle = computed
      }
      if item["rotate"] != nil {
        issue(item, "Per-character rotation is omitted; object transforms remain supported.")
      }
      if !root
        && (item["transform"] != nil || computed["opacity"] != nil || computed["clip-path"] != nil)
      {
        issue(
          item,
          "Transforms, opacity, and clips on individual text spans require review; the text remains editable."
        )
      }
      for content in item.content {
        switch content {
        case .text(let raw):
          var value =
            preserve
            ? raw : raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
          if !preserve && parts.last?.text.last == " " && value.first == " " { value.removeFirst() }
          if !value.isEmpty { parts.append(.init(text: value, style: computed)) }
        case .node(let child):
          if child.name == "tspan" {
            let local = try self.style(child, parent: computed)
            if local["display"] != "none" && local["visibility"] != "hidden" {
              try gather(child, local)
            }
          } else if !["title", "desc"].contains(child.name) {
            issue(child, "Text on paths and unsupported text children are omitted.")
          }
        }
      }
    }
    try gather(node, style, root: true)
    try flush()
    guard !created.isEmpty else { return nil }
    if created.count == 1 { return created[0] }
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 1, height: 1)
    group.name = "Positioned text"
    for var e in created {
      e.parentID = group.id
      try append(e)
    }
    return group
  }

  func textStyle(_ style: [String: String], node: SVGNode, context: SVGContext) throws -> Typography
  {
    var t = Typography()
    t.frameMode = "point"
    t.kerningMode = style["font-kerning"] == "none" ? "none" : "metrics"
    if let value = style["font-kerning"], !["auto", "normal", "none"].contains(value) {
      issue(node, "Unsupported font-kerning '\(value)'; font metrics are used.")
    }
    t.fontName = "Times-Roman"
    t.direction = style["direction"] == "rtl" ? "rtl" : "ltr"
    let families = (style["font-family"] ?? "serif").split(separator: ",").map {
      $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
    }
    let weight = style["font-weight"] ?? "normal"
    let italic = ["italic", "oblique"].contains(style["font-style"] ?? "normal")
    let bold = weight == "bold" || weight == "bolder" || (Double(weight) ?? 400) >= 600
    let cacheKey = families.joined(separator: ",") + "|\(bold)|\(italic)"
    var found: NSFont?
    if let cached = fontCache[cacheKey] { found = NSFont(name: cached, size: 16) }
    for raw in families where found == nil {
      let family =
        [
          "sans-serif": "Arial", "serif": "Times", "monospace": "Courier",
          "system-ui": "Helvetica Neue",
        ][raw] ?? raw
      found =
        NSFont(name: family, size: 16)
        ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 16)
      if found != nil { break }
    }
    if let base = found {
      var traits = NSFontTraitMask()
      if bold { traits.insert(.boldFontMask) }
      if italic { traits.insert(.italicFontMask) }
      let styled = NSFontManager.shared.convert(base, toHaveTrait: traits)
      t.fontName = styled.fontName
      fontCache[cacheKey] = t.fontName
    } else {
      t.fontName = String((families.first ?? "Times-Roman").prefix(250))
      issue(
        node,
        "Font '\(t.fontName)' is missing. The assignment is preserved and FORM uses its fallback.")
    }
    if let stretch = style["font-stretch"], stretch != "normal" {
      issue(node, "Font stretch is omitted; use the native typography scale after import.")
    }
    let font = Double(style["font-size"] ?? "16") ?? 16
    if let value = style["letter-spacing"], value != "normal" {
      t.tracking =
        try SVGLength.value(value, font: font) * context.scale * TypographyEngine.pointsPerMM
    }
    if let value = style["word-spacing"], value != "normal" {
      t.wordSpacing =
        try SVGLength.value(value, font: font) * context.scale * TypographyEngine.pointsPerMM
    }
    t.underline = (style["text-decoration"] ?? "").contains("underline")
    t.strikethrough = (style["text-decoration"] ?? "").contains("line-through")
    return t
  }
}

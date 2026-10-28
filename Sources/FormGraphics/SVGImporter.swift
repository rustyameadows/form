import AppKit
import FormCore
import Foundation

public struct SVGImportResult: Sendable {
  public var artwork: Artwork
  public var width: Double
  public var height: Double
  public var assets: [String: Data]
  public var issues: [SVGImportIssue]
  public var hasWarnings: Bool { issues.contains { $0.severity == "warning" } }
  public var report: [String: Any] {
    [
      "width_mm": width, "height_mm": height, "elements": artwork.elements.count,
      "paths": artwork.elements.filter { $0.kind == "path" }.count,
      "text_objects": artwork.elements.filter { $0.kind == "text" }.count,
      "embedded_images": assets.count, "requires_review": hasWarnings,
      "issues": issues.map {
        ["severity": $0.severity, "element": $0.element, "message": $0.message]
      },
    ]
  }
}

@MainActor public enum SVGImporter {
  public static func read(_ data: Data, name: String = "Imported SVG") throws -> SVGImportResult {
    try SVGImportBuilder(document: SVGDocument.read(data)).build(name: name)
  }
}

struct SVGContext {
  var width: Double, height: Double, scale: Double
  var diagonal: Double { hypot(width, height) / sqrt(2) }
}

@MainActor final class SVGImportBuilder {
  let document: SVGDocument
  var sheet = SVGStyleSheet()
  var elements: [ArtworkElement] = []
  var assets: [String: Data] = [:]
  var issues: [SVGImportIssue] = []
  var issueKeys = Set<String>()
  var expandedNodes = 0
  var fontCache: [String: String] = [:]
  init(document: SVGDocument) { self.document = document }

  func issue(_ node: SVGNode, _ message: String, severity: String = "warning") {
    let message = String(message.prefix(1600))
    let key = node.label + message
    guard issues.count < 500, issueKeys.insert(key).inserted else { return }
    issues.append(.init(severity: severity, element: node.label, message: message))
  }
  func build(name: String) throws -> SVGImportResult {
    let root = document.root!
    for message in document.warnings { issue(root, message) }
    func styles(_ node: SVGNode) {
      if node.name == "style" {
        if node["type"] == nil || node["type"] == "text/css" {
          sheet.add(node.text) { self.issue(node, $0) }
        } else {
          self.issue(node, "Only CSS stylesheets are supported.")
        }
      }
      for child in node.children { styles(child) }
    }
    styles(root)
    let box = try viewBox(root)
    func dimension(_ key: String) throws -> Double? {
      guard let raw = root[key], raw != "auto" else { return nil }
      if raw.contains("%") {
        issue(root, "Percentage viewport dimensions use the viewBox size at 96 pixels per inch.")
        return nil
      }
      return try SVGLength.value(raw) * SVGLength.mmPerPixel
    }
    var width = try dimension("width")
    var height = try dimension("height")
    if let box {
      if width == nil && height != nil { width = height! * box.width / box.height }
      if height == nil && width != nil { height = width! * box.height / box.width }
      if width == nil { width = box.width * SVGLength.mmPerPixel }
      if height == nil { height = box.height * SVGLength.mmPerPixel }
    }
    if width == nil || height == nil {
      issue(
        root, "Missing viewport dimensions use the SVG default of 300 × 150 CSS pixels.",
        severity: "info")
    }
    let w = ((width ?? 300 * SVGLength.mmPerPixel) * 1e9).rounded() / 1e9
    let h = ((height ?? 150 * SVGLength.mmPerPixel) * 1e9).rounded() / 1e9
    guard w.isFinite, h.isFinite, (1...1000).contains(w), (1...1000).contains(h) else {
      throw FormError.invalid("SVG physical dimensions must be between 1 and 1000 mm per edge.")
    }
    let viewport = box ?? .init(0, 0, w / SVGLength.mmPerPixel, h / SVGLength.mmPerPixel)
    let mapping = try viewportTransform(
      box: viewport, width: w, height: h, aspect: root["preserveAspectRatio"])
    let base = abs(mapping.d)
    let context = SVGContext(width: viewport.width, height: viewport.height, scale: base)
    var wrapper = ArtworkElement(kind: "group", x: 0, y: 0, width: w, height: h)
    wrapper.name = String(name.prefix(500))
    wrapper.contentSize = .init(w, h)
    elements.append(wrapper)
    let content = try walk(root, parent: wrapper.id, inherited: [:], context: context, visiting: [])
    if let id = content, let i = elements.firstIndex(where: { $0.id == id }) {
      let previous = elements[i].affine ?? .init()
      let outer = try transform(root, scale: SVGLength.mmPerPixel)
      elements[i].affine = outer.followed(by: mapping).followed(by: .scale(1 / base, 1 / base))
      elements[i].name = "SVG contents"
      if let clipID = elements[i].clipID, let mask = elements.firstIndex(where: { $0.id == clipID })
      {
        elements[mask].affine = elements[i].affine!.followed(by: previous.inverse!).followed(
          by: elements[mask].affine ?? .init())
      }
    }
    if try style(root, parent: [:])["overflow"] != "visible" {
      var mask = ArtworkElement(
        kind: "rectangle", x: 0, y: 0, width: w, height: h, color: "#000000")
      mask.name = "SVG viewport"
      mask.hidden = true
      elements[0].clipID = mask.id
      elements.append(mask)
    }
    guard elements.contains(where: { $0.kind != "group" && $0.hidden != true }) else {
      throw FormError.invalid("SVG contains no supported visible artwork.")
    }
    var art = Artwork(background: "#FFFFFF", elements: elements, bleed: 0)
    art.backgroundOpacity = 0
    art.unit = .mm
    try validateArtwork(art)
    return .init(artwork: art, width: w, height: h, assets: assets, issues: issues)
  }

  func viewBox(_ node: SVGNode) throws -> Rect2? {
    guard let raw = node["viewBox"] else { return nil }
    let v = try SVGScanner.numbers(raw)
    guard v.count == 4, v[2] > 0, v[3] > 0 else { throw FormError.invalid("Invalid SVG viewBox.") }
    return .init(v[0], v[1], v[2], v[3])
  }
  func viewportTransform(box: Rect2, width: Double, height: Double, aspect: String?) throws
    -> Affine2
  {
    var tokens = (aspect ?? "xMidYMid meet").split(whereSeparator: \.isWhitespace).map(String.init)
    if tokens.first == "defer" { tokens.removeFirst() }
    let align = tokens.first ?? "xMidYMid"
    let mode = tokens.count > 1 ? tokens[1] : "meet"
    guard
      [
        "none", "xMinYMin", "xMidYMin", "xMaxYMin", "xMinYMid", "xMidYMid", "xMaxYMid", "xMinYMax",
        "xMidYMax", "xMaxYMax",
      ].contains(align), ["meet", "slice"].contains(mode)
    else { throw FormError.invalid("Invalid SVG preserveAspectRatio.") }
    var sx = width / box.width
    var sy = height / box.height
    if align != "none" {
      let s = mode == "slice" ? max(sx, sy) : min(sx, sy)
      sx = s
      sy = s
    }
    var x = -box.x * sx
    var y = -box.y * sy
    if align.contains("xMid") { x += (width - box.width * sx) / 2 }
    if align.contains("xMax") { x += width - box.width * sx }
    if align.contains("YMid") { y += (height - box.height * sy) / 2 }
    if align.contains("YMax") { y += height - box.height * sy }
    return .init(a: sx, d: sy, tx: x, ty: y)
  }
  func transform(_ node: SVGNode, scale: Double) throws -> Affine2 {
    let t = try SVGGeometry.transform(node["transform"] ?? "")
    return .init(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx * scale, ty: t.ty * scale)
  }
  func style(_ node: SVGNode, parent: [String: String]) throws -> [String: String] {
    var result = sheet.style(node, inherited: parent)
    let inheritedSize = Double(parent["font-size"] ?? "16") ?? 16
    if let value = result["font-size"] {
      result["font-size"] = String(
        try SVGLength.value(value, reference: inheritedSize, font: inheritedSize))
    } else {
      result["font-size"] = String(inheritedSize)
    }
    for key in SVGStyleSheet.declarations(node["style"] ?? "").keys
    where !SVGStyleSheet.supported.contains(key) {
      issue(node, "CSS property '\(key)' is not supported.")
    }
    for key in [
      "filter", "mask", "marker-start", "marker-mid", "marker-end", "vector-effect", "paint-order",
      "mix-blend-mode", "isolation", "font-variant", "font-feature-settings",
      "font-variation-settings",
      "baseline-shift", "alignment-baseline", "writing-mode", "unicode-bidi", "text-orientation",
      "textLength", "lengthAdjust", "pathLength",
    ] where node[key] != nil { issue(node, "Attribute '\(key)' is not supported.") }
    if node.attributes.keys.contains(where: { $0.lowercased().hasPrefix("on") }) {
      issue(node, "Event handlers are ignored; SVG import does not execute scripts.")
    }
    return result
  }
  func length(
    _ node: SVGNode, _ key: String, _ context: SVGContext, _ style: [String: String],
    fallback: Double = 0, axis: String = "x"
  ) throws -> Double {
    guard let raw = node[key] else { return fallback }
    return try SVGLength.value(
      raw, reference: axis == "x" ? context.width : axis == "y" ? context.height : context.diagonal,
      font: Double(style["font-size"] ?? "16") ?? 16)
  }
  func append(_ element: ArtworkElement) throws {
    guard elements.count < 5000 else {
      throw FormError.invalid("SVG exceeds 5,000 editable elements after expansion.")
    }
    elements.append(element)
  }
  @discardableResult func walk(
    _ node: SVGNode, parent: UUID?, inherited: [String: String], context: SVGContext,
    visiting: Set<String>
  ) throws -> UUID? {
    expandedNodes += 1
    guard expandedNodes <= 20_000 else {
      throw FormError.invalid("SVG reference expansion is too large.")
    }
    if [
      "defs", "style", "title", "desc", "metadata", "lineargradient", "radialgradient", "clippath",
      "symbol",
    ].contains(node.name) {
      return nil
    }
    let computed = try style(node, parent: inherited)
    for child in node.children
    where ["animate", "animatetransform", "animatemotion", "set"].contains(child.name) {
      issue(child, "Animation is omitted; the initial artwork attributes are imported.")
    }
    if computed["display"] == "none" { return nil }
    var element: ArtworkElement
    let group = ["svg", "g", "a", "use"].contains(node.name)
    if group {
      element = .init(kind: "group", x: 0, y: 0, width: 1, height: 1)
    } else if node.name == "text" {
      if (Double(computed["font-size"] ?? "16") ?? 16) == 0 { return nil }
      guard let text = try text(node, style: computed, context: context) else { return nil }
      element = text
    } else if node.name == "image" {
      guard let image = try image(node, style: computed, context: context) else { return nil }
      element = image
    } else if let path = try shape(node, style: computed, context: context) {
      if path.isEmpty { return nil }
      var t = CGAffineTransform(scaleX: context.scale, y: context.scale)
      element = try VectorGeometry.element(from: path.copy(using: &t)!, color: "#000000")
      element.path?.evenOdd = computed["fill-rule"] == "evenodd"
      try paint(&element, node: node, style: computed, context: context)
    } else {
      issue(node, "Element is omitted because it has no native equivalent.")
      return nil
    }
    element.name = String(
      (node["inkscape:label"] ?? node["id"]
        ?? (node.name == "text" ? element.text : node.name.capitalized)).prefix(500))
    element.parentID = parent
    if let clipID = element.clipID, let mask = elements.firstIndex(where: { $0.id == clipID }) {
      elements[mask].parentID = parent
    }
    element.affine = try transform(node, scale: context.scale)
    element.opacity = try SVGLength.opacity(computed["opacity"])
    if !group && ["hidden", "collapse"].contains(computed["visibility"] ?? "") {
      element.hidden = true
    }
    let id = element.id
    try append(element)
    if group {
      if node.name == "use" {
        try expandUse(node, parent: id, style: computed, context: context, visiting: visiting)
      } else if node.name == "svg", node !== document.root {
        try nestedSVG(node, parent: id, style: computed, context: context, visiting: visiting)
      } else {
        if node.name == "a" {
          issue(
            node, "Hyperlink actions are omitted; their artwork stays editable.", severity: "info")
        }
        for child in node.children {
          try walk(child, parent: id, inherited: computed, context: context, visiting: visiting)
        }
      }
      normalizeGroup(id)
    }
    if !group && element.kind == "group" { normalizeGroup(id) }
    if let reference = computed["clip-path"], reference != "none" {
      try clip(node, id: id, reference: reference, style: computed, context: context)
    }
    return id
  }
  func normalizeGroup(_ id: UUID) {
    guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
    let masks = Set(elements.compactMap(\.clipID))
    let children = elements.filter { $0.parentID == id && !masks.contains($0.id) }
    guard let first = children.first else {
      elements[index].contentSize = .init(1, 1)
      return
    }
    func bounds(_ e: ArtworkElement) -> Rect2 {
      e.localTransform.bounds(.init(0, 0, e.width, e.height))
    }
    let b = children.dropFirst().reduce(bounds(first)) { $0.union(bounds($1)) }
    elements[index].x = b.x
    elements[index].y = b.y
    elements[index].width = max(0.001, b.width)
    elements[index].height = max(0.001, b.height)
    elements[index].contentSize = .init(elements[index].width, elements[index].height)
    for i in elements.indices where elements[i].parentID == id {
      elements[i].affine = Affine2.translation(-b.x, -b.y).followed(
        by: elements[i].affine ?? .init())
    }
  }
}

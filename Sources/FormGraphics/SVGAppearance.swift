import AppKit
import FormCore

extension SVGImportBuilder {
  func paint(
    _ element: inout ArtworkElement, node: SVGNode, style: [String: String], context: SVGContext
  ) throws {
    let fill = style["fill"] ?? "black"
    element.fillEnabled = fill != "none"
    element.fillOpacity = try SVGLength.opacity(style["fill-opacity"])
    if fill.hasPrefix("url(") {
      if let gradient = try gradient(fill, element: element, node: node, context: context) {
        element.gradient = gradient
      } else {
        element.fillEnabled = false
      }
    } else if fill != "none" {
      let c = try SVGColor.parse(fill, current: style["color"] ?? "black")
      element.color = c.hex
      element.fillOpacity = c.alpha * (element.fillOpacity ?? 1)
    }
    if let raw = style["stroke"], raw != "none" {
      if raw.hasPrefix("url(") {
        issue(node, "Gradient strokes are omitted; solid strokes and gradient fills are supported.")
      } else {
        let color = try SVGColor.parse(raw, current: style["color"] ?? "black")
        let font = Double(style["font-size"] ?? "16") ?? 16
        var stroke = ArtworkStroke(
          color: color.hex,
          width: try SVGLength.value(
            style["stroke-width"] ?? "1", reference: context.diagonal, font: font) * context.scale)
        stroke.opacity = color.alpha * (try SVGLength.opacity(style["stroke-opacity"]))
        stroke.cap = style["stroke-linecap"] ?? "butt"
        stroke.join = style["stroke-linejoin"] ?? "miter"
        stroke.miter = try SVGLength.value(style["stroke-miterlimit"] ?? "4")
        if let dash = style["stroke-dasharray"], dash != "none" {
          let tokens = dash.split(whereSeparator: { $0.isWhitespace || $0 == "," })
          var lengths = try tokens.map {
            try SVGLength.value(String($0), reference: context.diagonal, font: font) * context.scale
          }
          if lengths.count % 2 == 1 { lengths += lengths }
          if lengths.reduce(0, +) > 0 { stroke.dash = lengths }
          stroke.dashOffset =
            try SVGLength.value(
              style["stroke-dashoffset"] ?? "0", reference: context.diagonal, font: font)
            * context.scale
        }
        element.stroke = stroke
      }
    }
  }

  func reference(_ raw: String) -> String? {
    guard raw.hasPrefix("url("), let end = raw.firstIndex(of: ")") else { return nil }
    let value = raw.dropFirst(4).prefix(upTo: end).trimmingCharacters(
      in: CharacterSet(charactersIn: " \t\r\n\"'"))
    guard value.hasPrefix("#"), !value.dropFirst().isEmpty else { return nil }
    return String(value.dropFirst())
  }
  func ancestorStyle(_ node: SVGNode) throws -> [String: String] {
    var ancestors: [SVGNode] = []
    var current: SVGNode? = node
    while let value = current {
      ancestors.append(value)
      current = value.parent
    }
    var result: [String: String] = [:]
    for value in ancestors.reversed() { result = try style(value, parent: result) }
    return result
  }
  func gradient(_ raw: String, element: ArtworkElement, node: SVGNode, context: SVGContext) throws
    -> ArtworkGradient?
  {
    guard let id = reference(raw), let definition = document.ids[id],
      ["lineargradient", "radialgradient"].contains(definition.name)
    else {
      issue(node, "Missing or external paint reference is omitted.")
      return nil
    }
    var chain: [SVGNode] = []
    var current: SVGNode? = definition
    var seen = Set<String>()
    while let value = current {
      guard chain.count < 32, seen.insert(value["id"] ?? "").inserted else {
        throw FormError.invalid("Cyclic SVG gradient reference.")
      }
      chain.append(value)
      if let href = value["href"] ?? value["xlink:href"] {
        guard href.hasPrefix("#"), let next = document.ids[String(href.dropFirst())],
          ["lineargradient", "radialgradient"].contains(next.name)
        else {
          issue(value, "Missing or external gradient inheritance is omitted.")
          break
        }
        current = next
      } else {
        current = nil
      }
    }
    var attrs: [String: String] = [:]
    var stopNodes: [SVGNode] = []
    for value in chain.reversed() {
      attrs.merge(value.attributes) { _, new in new }
      let localStops = value.children.filter { $0.name == "stop" }
      if !localStops.isEmpty { stopNodes = localStops }
    }
    guard !stopNodes.isEmpty else {
      issue(definition, "Gradient has no color stops; fill is omitted.")
      return nil
    }
    guard stopNodes.count <= 32 else {
      throw FormError.invalid("SVG gradients support at most 32 editable stops.")
    }
    var stops: [GradientStop] = []
    var last = 0.0
    for stop in stopNodes {
      let style = try ancestorStyle(stop)
      let color = try SVGColor.parse(
        style["stop-color"] ?? "black", current: style["color"] ?? "black")
      let offset = max(
        last, min(1, max(0, try SVGLength.value(stop["offset"] ?? "0", reference: 1))))
      var item = GradientStop(offset, color.hex)
      item.opacity = color.alpha * (try SVGLength.opacity(style["stop-opacity"]))
      stops.append(item)
      last = offset
    }
    if stops.count == 1 {
      var duplicate = stops[0]
      duplicate.id = UUID()
      duplicate.offset = 1
      stops.append(duplicate)
    }
    if let spread = attrs["spreadMethod"], spread != "pad" {
      issue(definition, "Gradient repeat/reflect spread is displayed using pad.")
    }
    let bounding = attrs["gradientUnits"] != "userSpaceOnUse"
    let box =
      bounding
      ? Affine2.translation(element.x, element.y).followed(
        by: .scale(element.width, element.height)) : .scale(context.scale, context.scale)
    let gradT = try SVGGeometry.transform(attrs["gradientTransform"] ?? "")
    func coordinate(_ key: String, _ fallback: String, _ axis: String) throws -> Double {
      try SVGLength.value(
        attrs[key] ?? fallback,
        reference: bounding
          ? 1 : axis == "x" ? context.width : axis == "y" ? context.height : context.diagonal)
    }
    var gradient: ArtworkGradient
    let native: Affine2
    if definition.name == "lineargradient" {
      let x1 = try coordinate("x1", "0%", "x")
      let y1 = try coordinate("y1", "0%", "y")
      let x2 = try coordinate("x2", "100%", "x")
      let y2 = try coordinate("y2", "0%", "y")
      let dx = x2 - x1
      let dy = y2 - y1
      if hypot(dx, dy) < 1e-12 {
        issue(definition, "Zero-length gradient imported as its last color.", severity: "info")
        return solidGradient(stops)
      }
      gradient = .init(start: .init(0, 0), end: .init(1, 0), stops: stops)
      native = .init(
        a: dx / element.width, b: dy / element.width, c: -dy / element.width, d: dx / element.width,
        tx: x1, ty: y1)
    } else {
      let x = try coordinate("cx", "50%", "x")
      let y = try coordinate("cy", "50%", "y")
      let radius = try coordinate("r", "50%", "diagonal")
      if let fx = attrs["fx"], try SVGLength.value(fx, reference: bounding ? 1 : context.width) != x
      {
        issue(definition, "Offset radial-gradient focal points are displayed at the center.")
      }
      if let fy = attrs["fy"],
        try SVGLength.value(fy, reference: bounding ? 1 : context.height) != y
      {
        issue(definition, "Offset radial-gradient focal points are displayed at the center.")
      }
      if let fr = attrs["fr"], try SVGLength.value(fr) != 0 {
        issue(definition, "Radial-gradient focal radius is displayed as zero.")
      }
      guard radius >= 0 else { throw FormError.invalid("Negative SVG gradient radius.") }
      let r = max(radius, 1e-8)
      if radius == 0 {
        issue(definition, "Zero-radius gradient imported as its last color.", severity: "info")
        return solidGradient(stops)
      }
      gradient = .init(kind: "radial", start: .init(0.5, 0.5), end: .init(1, 0.5), stops: stops)
      native = Affine2.translation(x, y).followed(
        by: .scale(2 * r / element.width, 2 * r / element.width)
      ).followed(by: .translation(-element.width / 2, -element.height / 2))
    }
    gradient.transform = Affine2.translation(-element.x, -element.y).followed(by: box).followed(
      by: gradT
    ).followed(by: native)
    return gradient
  }
  private func solidGradient(_ stops: [GradientStop]) -> ArtworkGradient {
    let last = stops.last!
    return .init(
      stops: stops.map { original in
        var stop = original
        stop.color = last.color
        stop.opacity = last.opacity
        return stop
      })
  }

  func clip(
    _ node: SVGNode, id: UUID, reference raw: String, style: [String: String], context: SVGContext
  ) throws {
    guard let key = reference(raw), let definition = document.ids[key],
      definition.name == "clippath", let index = elements.firstIndex(where: { $0.id == id })
    else {
      issue(node, "Missing or external clip reference is omitted.")
      return
    }
    let owner = elements[index]
    let bounding = definition["clipPathUnits"] == "objectBoundingBox"
    let units =
      bounding
      ? Affine2.translation(owner.x, owner.y).followed(by: .scale(owner.width, owner.height))
      : .scale(context.scale, context.scale)
    var paths: [CGPath] = []
    var unsupported = false
    func collect(
      _ n: SVGNode, _ parent: Affine2, _ inherited: [String: String], _ references: Set<String>
    ) throws {
      let computed = try self.style(n, parent: inherited)
      if computed["display"] == "none" || computed["visibility"] == "hidden" { return }
      if computed["clip-path"] != nil {
        self.issue(n, "Nested clip references inside clipPath are not supported.")
        unsupported = true
        return
      }
      let matrix = parent.followed(by: try SVGGeometry.transform(n["transform"] ?? ""))
      if ["g", "clippath"].contains(n.name) {
        for child in n.children { try collect(child, matrix, computed, references) }
      } else if n.name == "use" {
        let href = n["href"] ?? n["xlink:href"] ?? ""
        guard href.hasPrefix("#"), let target = document.ids[String(href.dropFirst())],
          !references.contains(href), references.count < 32
        else { throw FormError.invalid("Invalid or cyclic SVG clip reference.") }
        var next = references
        next.insert(href)
        let x = try length(n, "x", context, computed)
        let y = try length(n, "y", context, computed, axis: "y")
        try collect(target, matrix.followed(by: .translation(x, y)), computed, next)
      } else if let path = try shape(n, style: computed, context: context) {
        var t = matrix.cg
        let transformed = path.copy(using: &t)!.normalized(
          using: computed["clip-rule"] == "evenodd" ? .evenOdd : .winding)
        paths.append(transformed)
      } else if !["title", "desc", "metadata"].contains(n.name) {
        self.issue(n, "This clipPath content is omitted; native shape clips are supported.")
        unsupported = true
      }
    }
    try collect(definition, .init(), try ancestorStyle(definition.parent ?? definition), [])
    if unsupported {
      issue(node, "Clip contains unsupported content; only its supported shapes are used.")
    }
    var result = CGMutablePath() as CGPath
    for p in paths { result = result.union(p, using: .winding) }
    if result.isEmpty {
      // An empty SVG clip paints nothing, unlike an absent clip.
      elements[index].hidden = true
      return
    }
    var map = (owner.affine ?? .init()).followed(by: units).cg
    result = result.copy(using: &map)!
    if let previousID = owner.clipID, let previous = elements.first(where: { $0.id == previousID })
    {
      var t = previous.localTransform.cg
      result = result.intersection(VectorGeometry.path(previous).copy(using: &t)!, using: .winding)
      if result.isEmpty {
        elements[index].hidden = true
        return
      }
    }
    var mask = try VectorGeometry.element(
      from: result, color: "#000000", name: "Clip · \(key)", parentID: owner.parentID)
    mask.hidden = true
    mask.path?.evenOdd = false
    elements[index].clipID = mask.id
    try append(mask)
  }
}

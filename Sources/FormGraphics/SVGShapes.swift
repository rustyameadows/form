import AppKit
import FormCore
import ImageIO

extension SVGImportBuilder {
  func shape(_ node: SVGNode, style: [String: String], context: SVGContext) throws -> CGPath? {
    func value(_ key: String, _ axis: String = "x", _ fallback: Double = 0) throws -> Double {
      try length(node, key, context, style, fallback: fallback, axis: axis)
    }
    let p = CGMutablePath()
    switch node.name {
    case "path": return try SVGGeometry.path(node["d"] ?? "")
    case "rect":
      let x = try value("x")
      let y = try value("y", "y")
      let w = try value("width")
      let h = try value("height", "y")
      guard w >= 0, h >= 0 else { throw FormError.invalid("Negative SVG rectangle size.") }
      if w == 0 || h == 0 { return p }
      let rx = try value("rx", "x", node["ry"] == nil ? 0 : value("ry", "y"))
      let ry = try value("ry", "y", rx)
      guard rx >= 0, ry >= 0 else { throw FormError.invalid("Negative SVG corner radius.") }
      return CGPath(
        roundedRect: .init(x: x, y: y, width: w, height: h), cornerWidth: min(rx, w / 2),
        cornerHeight: min(ry, h / 2), transform: nil)
    case "circle", "ellipse":
      let x = try value("cx")
      let y = try value("cy", "y")
      let rx = try node.name == "circle" ? value("r", "diagonal") : value("rx")
      let ry = try node.name == "circle" ? rx : value("ry", "y")
      guard rx >= 0, ry >= 0 else { throw FormError.invalid("Negative SVG ellipse radius.") }
      if rx == 0 || ry == 0 { return p }
      return CGPath(
        ellipseIn: .init(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2), transform: nil)
    case "line":
      p.move(to: .init(x: try value("x1"), y: try value("y1", "y")))
      p.addLine(to: .init(x: try value("x2"), y: try value("y2", "y")))
    case "polygon", "polyline":
      let points = try SVGScanner.numbers(node["points"] ?? "")
      guard points.count % 2 == 0 else { throw FormError.invalid("SVG points need x/y pairs.") }
      for i in stride(from: 0, to: points.count, by: 2) {
        let v = CGPoint(x: points[i], y: points[i + 1])
        if i == 0 { p.move(to: v) } else { p.addLine(to: v) }
      }
      if node.name == "polygon", !points.isEmpty { p.closeSubpath() }
    default: return nil
    }
    return p
  }

  func nestedSVG(
    _ node: SVGNode, parent: UUID, style: [String: String], context: SVGContext,
    visiting: Set<String>
  ) throws {
    let x = try length(node, "x", context, style) * context.scale
    let y = try length(node, "y", context, style, axis: "y") * context.scale
    let w = try length(node, "width", context, style, fallback: context.width) * context.scale
    let h =
      try length(node, "height", context, style, fallback: context.height, axis: "y")
      * context.scale
    guard w > 0, h > 0 else { return }
    let box = try viewBox(node) ?? .init(0, 0, w / context.scale, h / context.scale)
    let map = try viewportTransform(
      box: box, width: w, height: h, aspect: node["preserveAspectRatio"])
    let scale = abs(map.d)
    var content = ArtworkElement(kind: "group", x: 0, y: 0, width: 1, height: 1)
    content.parentID = parent
    content.name = "Viewport contents"
    content.affine = Affine2.translation(x, y).followed(by: map).followed(
      by: .scale(1 / scale, 1 / scale))
    try append(content)
    let local = SVGContext(width: box.width, height: box.height, scale: scale)
    for child in node.children {
      try walk(child, parent: content.id, inherited: style, context: local, visiting: visiting)
    }
    normalizeGroup(content.id)
    if style["overflow"] != "visible" {
      try viewportClip(content.id, parent: parent, x: x, y: y, width: w, height: h)
    }
  }

  func expandUse(
    _ node: SVGNode, parent: UUID, style: [String: String], context: SVGContext,
    visiting: Set<String>
  ) throws {
    let href = node["href"] ?? node["xlink:href"] ?? ""
    guard href.hasPrefix("#"), let target = document.ids[String(href.dropFirst())] else {
      issue(
        node,
        "Only references to IDs inside this SVG are imported; external or missing references are omitted."
      )
      return
    }
    guard !visiting.contains(href), visiting.count < 32 else {
      throw FormError.invalid("Cyclic or excessively nested SVG use reference.")
    }
    var next = visiting
    next.insert(href)
    let x = try length(node, "x", context, style) * context.scale
    let y = try length(node, "y", context, style, axis: "y") * context.scale
    var instance = ArtworkElement(kind: "group", x: 0, y: 0, width: 1, height: 1)
    instance.parentID = parent
    instance.affine = .translation(x, y)
    instance.name = "Instance of \(href)"
    try append(instance)
    if target.name == "symbol" {
      let symbolStyle = try self.style(target, parent: style)
      let box = try viewBox(target) ?? .init(0, 0, context.width, context.height)
      let w = try length(node, "width", context, style, fallback: box.width) * context.scale
      let h =
        try length(node, "height", context, style, fallback: box.height, axis: "y") * context.scale
      if w > 0, h > 0 {
        let map = try viewportTransform(
          box: box, width: w, height: h, aspect: target["preserveAspectRatio"])
        let scale = abs(map.d)
        if let i = elements.firstIndex(where: { $0.id == instance.id }) {
          elements[i].affine = Affine2.translation(x, y).followed(by: map).followed(
            by: .scale(1 / scale, 1 / scale))
        }
        let local = SVGContext(width: box.width, height: box.height, scale: scale)
        for child in target.children {
          try walk(
            child, parent: instance.id, inherited: symbolStyle, context: local, visiting: next)
        }
        normalizeGroup(instance.id)
        if symbolStyle["overflow"] != "visible" {
          try viewportClip(instance.id, parent: parent, x: x, y: y, width: w, height: h)
        }
        if target["transform"] != nil {
          issue(target, "Symbol transforms are omitted; its geometry and viewport are imported.")
        }
      }
    } else {
      try walk(target, parent: instance.id, inherited: style, context: context, visiting: next)
      normalizeGroup(instance.id)
    }
    issue(node, "Use reference expanded into an independent editable group.", severity: "info")
  }

  func viewportClip(_ id: UUID, parent: UUID, x: Double, y: Double, width: Double, height: Double)
    throws
  {
    var mask = ArtworkElement(
      kind: "rectangle", x: x, y: y, width: width, height: height, color: "#000000")
    mask.parentID = parent
    mask.name = "Viewport clip"
    mask.hidden = true
    if let i = elements.firstIndex(where: { $0.id == id }) { elements[i].clipID = mask.id }
    try append(mask)
  }

  func image(_ node: SVGNode, style: [String: String], context: SVGContext) throws
    -> ArtworkElement?
  {
    let href = node["href"] ?? node["xlink:href"] ?? ""
    guard href.hasPrefix("data:image/png;base64,") || href.hasPrefix("data:image/jpeg;base64,")
    else {
      issue(
        node,
        "Only embedded PNG and JPEG images are imported; file, network, and nested SVG images are omitted."
      )
      return nil
    }
    guard let comma = href.firstIndex(of: ","),
      let data = Data(
        base64Encoded: String(href[href.index(after: comma)...]), options: .ignoreUnknownCharacters),
      data.count <= 8_000_000,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let imageType = CGImageSourceGetType(source),
      ["public.png", "public.jpeg"].contains(imageType as String),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let pixelW = properties[kCGImagePropertyPixelWidth] as? Int,
      let pixelH = properties[kCGImagePropertyPixelHeight] as? Int,
      pixelW > 0, pixelH > 0, pixelW <= 16000, pixelH <= 16000, pixelW * pixelH <= 40_000_000
    else {
      throw FormError.invalid("Embedded SVG image is invalid or exceeds 8 MB / 40 megapixels.")
    }
    let x = try length(node, "x", context, style) * context.scale
    let y = try length(node, "y", context, style, axis: "y") * context.scale
    let w = try length(node, "width", context, style) * context.scale
    let h = try length(node, "height", context, style, axis: "y") * context.scale
    guard w > 0, h > 0 else { return nil }
    let mapping = try viewportTransform(
      box: .init(0, 0, Double(pixelW), Double(pixelH)), width: w, height: h,
      aspect: node["preserveAspectRatio"])
    let asset = UUID().uuidString + (imageType as String == "public.png" ? ".png" : ".jpg")
    assets[asset] = data
    var e = ArtworkElement(
      kind: "image", x: x + mapping.tx, y: y + mapping.ty, width: Double(pixelW) * mapping.a,
      height: Double(pixelH) * mapping.d, asset: asset)
    if (node["preserveAspectRatio"] ?? "").contains("slice") {
      // The image needs its own viewport clip, outside its placement transform.
      var mask = ArtworkElement(
        kind: "rectangle", x: x, y: y, width: w, height: h, color: "#000000")
      mask.affine = try transform(node, scale: context.scale)
      mask.name = "Image crop"
      mask.hidden = true
      // walk assigns the image's parent after this helper returns.
      mask.parentID = nil
      e.clipID = mask.id
      try append(mask)
    }
    return e
  }
}

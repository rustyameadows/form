import AppKit
import CoreText
import FormCore

@MainActor public enum SVGRenderer {
  public static func xml(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
  public static func data(_ path: CGPath) -> String {
    var output = ""
    func p(_ point: CGPoint) -> String { String(format: "%.8g %.8g", point.x, point.y) }
    path.applyWithBlock { ptr in
      let e = ptr.pointee
      switch e.type {
      case .moveToPoint: output += "M" + p(e.points[0])
      case .addLineToPoint: output += "L" + p(e.points[0])
      case .addQuadCurveToPoint: output += "Q" + p(e.points[0]) + " " + p(e.points[1])
      case .addCurveToPoint:
        output += "C" + p(e.points[0]) + " " + p(e.points[1]) + " " + p(e.points[2])
      case .closeSubpath: output += "Z"
      @unknown default: break
      }
    }
    return output
  }
  public static func fragment(
    _ art: Artwork, width: Double, height: Double, assets: URL, outlineText: Bool = true
  ) throws -> String {
    var definitions = ""
    var body =
      "<rect width=\"\(width)\" height=\"\(height)\" fill=\"\(art.background)\" fill-opacity=\"\(art.backgroundOpacity ?? 1)\"/>"
    let masks = Set(art.elements.compactMap(\.clipID))
    func transform(_ t: Affine2) -> String { "matrix(\(t.a) \(t.b) \(t.c) \(t.d) \(t.tx) \(t.ty))" }
    func children(_ parent: UUID?) throws -> String {
      var output = ""
      for e in art.elements
      where e.parentID == parent && e.hidden != true && !masks.contains(e.id)
        && (e.productionRole == nil || e.productionRole == "artwork")
      {
        let id = e.id.uuidString
        if let clip = e.clipID, let mask = art.elements.first(where: { $0.id == clip }) {
          definitions +=
            "<clipPath id=\"clip-\(id)\"><path d=\"\(data(VectorGeometry.path(mask)))\" transform=\"\(transform(mask.localTransform))\" clip-rule=\"\(mask.path?.evenOdd == true ? "evenodd":"nonzero")\"/></clipPath>"
          output += "<g clip-path=\"url(#clip-\(id))\">"
        }
        output +=
          "<g id=\"layer-\(id)\" transform=\"\(transform(e.localTransform))\" opacity=\"\(e.opacity ?? 1)\"><title>\(xml(e.title))</title>"
        if e.kind == "group" {
          output += try children(e.id)
        } else if e.kind == "text" {
          if e.fillEnabled == false { /* invisible text retains its editable source */
          } else if outlineText {
            for (path, color) in try TypographyEngine.outlineRuns(e) {
              output +=
                "<path d=\"\(data(path))\" fill=\"\(color)\" fill-opacity=\"\(e.fillOpacity ?? 1)\"/>"
            }
          } else {
            output += liveText(e)
          }
        } else if e.kind == "image" {
          if let asset = e.asset, !asset.contains("/"),
            let raw = try? Data(contentsOf: assets.appendingPathComponent(asset))
          {
            let ext = URL(fileURLWithPath: asset).pathExtension.lowercased()
            var bytes = raw
            var mime =
              ext == "svg"
              ? "image/svg+xml" : ["jpg", "jpeg"].contains(ext) ? "image/jpeg" : "image/png"
            if !["svg", "png", "jpg", "jpeg"].contains(ext), let image = NSImage(data: raw),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
            {
              bytes = png
              mime = "image/png"
            }
            output +=
              "<image width=\"\(e.width)\" height=\"\(e.height)\" href=\"data:\(mime);base64,\(bytes.base64EncodedString())\" preserveAspectRatio=\"none\"/>"
          }
        } else {
          var fill = e.fillEnabled == false || e.kind == "line" ? "none" : e.color
          if let g = e.gradient, e.fillEnabled != false {
            let stops = g.stops.map {
              "<stop offset=\"\($0.offset)\" stop-color=\"\($0.color)\" stop-opacity=\"\($0.opacity ?? 1)\"/>"
            }
            .joined()
            let gradientTransform =
              g.transform.map { " gradientTransform=\"\(transform($0))\"" } ?? ""
            if g.kind == "radial" {
              definitions +=
                "<radialGradient id=\"gradient-\(id)\" gradientUnits=\"userSpaceOnUse\"\(gradientTransform) cx=\"\(g.start.x*e.width)\" cy=\"\(g.start.y*e.height)\" r=\"\(hypot((g.end.x-g.start.x)*e.width,(g.end.y-g.start.y)*e.height))\">\(stops)</radialGradient>"
            } else {
              definitions +=
                "<linearGradient id=\"gradient-\(id)\" gradientUnits=\"userSpaceOnUse\"\(gradientTransform) x1=\"\(g.start.x*e.width)\" y1=\"\(g.start.y*e.height)\" x2=\"\(g.end.x*e.width)\" y2=\"\(g.end.y*e.height)\">\(stops)</linearGradient>"
            }
            fill = "url(#gradient-\(id))"
          }
          var stroke = ""
          if let s = e.stroke ?? (e.kind == "line" ? .init(color: e.color) : nil) {
            stroke =
              " stroke=\"\(s.color)\" stroke-width=\"\(s.width)\" stroke-opacity=\"\(s.opacity ?? 1)\" stroke-linecap=\"\(s.cap ?? "butt")\" stroke-linejoin=\"\(s.join ?? "miter")\" stroke-miterlimit=\"\(s.miter ?? 10)\""
            if let dash = s.dash, !dash.isEmpty {
              stroke +=
                " stroke-dasharray=\"\(dash.map{String($0)}.joined(separator:" "))\" stroke-dashoffset=\"\(s.dashOffset ?? 0)\""
            }
          }
          output +=
            "<path d=\"\(data(VectorGeometry.path(e)))\" fill=\"\(fill)\" fill-opacity=\"\(e.fillOpacity ?? 1)\" fill-rule=\"\(e.path?.evenOdd == true ? "evenodd":"nonzero")\"\(stroke)/>"
        }
        output += "</g>"
        if e.clipID != nil { output += "</g>" }
      }
      return output
    }
    body += try children(nil)
    if let boundary = art.boundary {
      var shape = ArtworkElement(
        kind: "path", x: 0, y: 0, width: boundary.width, height: boundary.height)
      shape.path = boundary
      definitions +=
        "<clipPath id=\"surface-boundary\"><path d=\"\(data(VectorGeometry.path(shape)))\" clip-rule=\"\(boundary.evenOdd ? "evenodd":"nonzero")\"/></clipPath>"
      body = "<g clip-path=\"url(#surface-boundary)\">" + body + "</g>"
    }
    return "<defs>\(definitions)</defs>" + body
  }
  public static func document(
    _ art: Artwork, width: Double, height: Double, assets: URL, outlineText: Bool = true
  ) throws -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)mm\" height=\"\(height)mm\" viewBox=\"0 0 \(width) \(height)\"><desc>FORM artwork. Physical units are millimeters. \(outlineText ? "Typography is outlined for portability.":"Live text requires the assigned fonts; verify shaping in the receiving application.")</desc>\(try fragment(art,width:width,height:height,assets:assets,outlineText:outlineText))</svg>"
  }
  private static func liveText(_ element: ArtworkElement) -> String {
    let attributed = TypographyEngine.attributed(element)
    let setter = CTFramesetterCreateWithAttributedString(attributed)
    let box = CGPath(
      rect: .init(
        x: 0, y: 0, width: element.width * TypographyEngine.pointsPerMM,
        height: element.height * TypographyEngine.pointsPerMM), transform: nil)
    let frame = CTFramesetterCreateFrame(setter, CFRange(), box, nil)
    let lines = CTFrameGetLines(frame) as! [CTLine]
    var origins = [CGPoint](repeating: .zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRange(), &origins)
    let measured = TypographyEngine.measured(element)
    let alignment = element.typography?.verticalAlignment
    let offset =
      alignment == "middle"
      ? max(0, (element.height - measured.height) / 2)
      : alignment == "bottom" ? max(0, element.height - measured.height) : 0
    var result = ""
    for (i, line) in lines.enumerated() {
      for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let range = CTRunGetStringRange(run)
        let attrs = CTRunGetAttributes(run) as NSDictionary
        let text = (attributed.string as NSString).substring(
          with: .init(location: range.location, length: range.length))
        let font =
          attrs[NSAttributedString.Key.font] as? NSFont
          ?? .systemFont(ofSize: element.fontSize)
        var p = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &p)
        result +=
          "<text xml:space=\"preserve\" x=\"\((origins[i].x+p.x)/TypographyEngine.pointsPerMM)\" y=\"\(element.height+offset-(origins[i].y+p.y)/TypographyEngine.pointsPerMM)\" font-family=\"\(xml(font.fontName))\" font-size=\"\(font.pointSize/TypographyEngine.pointsPerMM)\" letter-spacing=\"\(((attrs[NSAttributedString.Key.kern] as? NSNumber)?.doubleValue ?? 0)/TypographyEngine.pointsPerMM)\" fill=\"\(FormColor.hex(attrs[NSAttributedString.Key.foregroundColor] as? NSColor ?? .black))\" fill-opacity=\"\(element.fillOpacity ?? 1)\">\(xml(text))</text>"
      }
    }
    return result
  }
}

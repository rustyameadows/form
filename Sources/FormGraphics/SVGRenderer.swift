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
    _ source: Artwork, width: Double, height: Double, assets: URL, outlineText: Bool = true
  ) throws -> String {
    let art = try BooleanGeometry.materialized(source)
    let tree = ArtworkRenderTree(art, assets: assets, production: true, excluding: [])
    for e in art.elements where tree.displayed(e) && e.visibleStroke?.dash?.isEmpty == false {
      _ = try StrokeGeometry.path(e)
    }
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
        var effect = ""
        if e.hasActiveEffects {
          let bounds = tree.localBounds(e)
          var primitives = ""
          var input = "SourceGraphic"
          if let blur = e.blur, blur.enabled, blur.radius > 0 {
            primitives += "<feGaussianBlur in=\"SourceGraphic\" stdDeviation=\"\(blur.radius)\" result=\"blurred\"/>"
            input = "blurred"
          }
          if let shadow = e.shadow, shadow.enabled, shadow.opacity > 0 {
            primitives += "<feDropShadow in=\"\(input)\" dx=\"\(shadow.offset.x)\" dy=\"\(shadow.offset.y)\" stdDeviation=\"\(shadow.blur)\" flood-color=\"\(shadow.color)\" flood-opacity=\"\(shadow.opacity)\"/>"
          }
          definitions += "<filter id=\"effect-\(id)\" filterUnits=\"userSpaceOnUse\" primitiveUnits=\"userSpaceOnUse\" color-interpolation-filters=\"sRGB\" x=\"\(bounds.minX)\" y=\"\(bounds.minY)\" width=\"\(bounds.width)\" height=\"\(bounds.height)\">\(primitives)</filter>"
          effect = " filter=\"url(#effect-\(id))\""
        }
        if let clip = e.clipID, let mask = art.elements.first(where: { $0.id == clip }) {
          definitions +=
            "<clipPath id=\"clip-\(id)\"><path d=\"\(data(VectorGeometry.path(mask)))\" transform=\"\(transform(mask.localTransform))\" clip-rule=\"\(mask.path?.evenOdd == true ? "evenodd":"nonzero")\"/></clipPath>"
          output += "<g clip-path=\"url(#clip-\(id))\">"
        }
        let isolated = e.isolatedBlending == true || e.hasActiveEffects || (e.opacity ?? 1) < 1
          || (e.blendMode ?? "normal") != "normal"
        output +=
          "<g id=\"layer-\(id)\" transform=\"\(transform(e.localTransform))\" opacity=\"\(e.opacity ?? 1)\" style=\"isolation:\(isolated ? "isolate" : "auto");mix-blend-mode:\(e.blendMode ?? "normal")\"\(effect)><title>\(xml(e.title))</title>"
        if e.kind == "group" {
          output += try children(e.id)
        } else if e.kind == "text" {
          if e.fillEnabled == false { /* invisible text retains its editable source */
          } else if outlineText {
            output += "<g opacity=\"\(e.fillOpacity ?? 1)\">"
            for (path, color) in try TypographyEngine.outlineRuns(e) {
              output +=
                "<path d=\"\(data(path))\" fill=\"\(color)\"/>"
            }
            output += "</g>"
          } else {
            var text = e
            text.fillOpacity = nil
            output += "<g opacity=\"\(e.fillOpacity ?? 1)\">" + liveText(text) + "</g>"
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
            if !["svg", "png", "jpg", "jpeg"].contains(ext) {
              let url = assets.appendingPathComponent(asset)
              if let info = try? ImageRenderer.info(url) {
                guard max(info.width,info.height) <= ImageRenderer.maximumEdge,
                  info.width * info.height <= ImageRenderer.maximumPixels else {
                  throw FormError.invalid("This image is too large for lossless SVG conversion. Use a PNG/JPEG original or raster export at a chosen DPI.")
                }
                let bitmap = NSBitmapImageRep(cgImage: try ImageRenderer.bitmap(url, requestedEdge: Double(max(info.width,info.height))))
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw FormError.invalid("Could not encode the SVG image.") }
                bytes = png
              } else if let image = NSImage(data: raw), let tiff = image.tiffRepresentation,
                let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                bytes = png
              }
              mime = "image/png"
            }
            let crop = e.imageCrop ?? .full
            var adjustment = ""
            if let a = e.imageAdjustments, !a.isIdentity {
              let matrix = a.colorMatrix.flatMap{$0}.map{String($0)}.joined(separator:" ")
              definitions += "<filter id=\"image-color-\(id)\" color-interpolation-filters=\"sRGB\" x=\"0\" y=\"0\" width=\"1\" height=\"1\"><feColorMatrix type=\"matrix\" values=\"\(matrix)\"/></filter>"
              adjustment = " filter=\"url(#image-color-\(id))\""
            }
            output += "<svg width=\"\(e.width)\" height=\"\(e.height)\" viewBox=\"\(crop.x) \(crop.y) \(crop.width) \(crop.height)\" preserveAspectRatio=\"none\" overflow=\"hidden\"><image width=\"1\" height=\"1\" href=\"data:\(mime);base64,\(bytes.base64EncodedString())\" preserveAspectRatio=\"none\"\(adjustment)/></svg>"
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
          if let s = e.visibleStroke, (s.alignment ?? "center") == "center" {
            stroke =
              " stroke=\"\(s.color)\" stroke-width=\"\(s.width)\" stroke-opacity=\"\(s.opacity ?? 1)\" stroke-linecap=\"\(s.cap ?? "butt")\" stroke-linejoin=\"\(s.join ?? "miter")\" stroke-miterlimit=\"\(s.miter ?? 10)\""
            if let dash = s.dash, !dash.isEmpty {
              stroke +=
                " stroke-dasharray=\"\(dash.map{String($0)}.joined(separator:" "))\" stroke-dashoffset=\"\(s.dashOffset ?? 0)\""
            }
          }
          output +=
            "<path d=\"\(data(VectorGeometry.path(e)))\" fill=\"\(fill)\" fill-opacity=\"\(e.fillOpacity ?? 1)\" fill-rule=\"\(e.path?.evenOdd == true ? "evenodd":"nonzero")\"\(stroke)/>"
          if let stroke = e.visibleStroke, (stroke.alignment ?? "center") != "center" {
            let outline = try VectorGeometry.expandedStroke(e)
            output += "<path d=\"\(data(outline))\" fill=\"\(stroke.color)\" fill-opacity=\"\(stroke.opacity ?? 1)\"/>"
          }
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
    let frameID = "frame-\(art.elements.first?.id.uuidString ?? "empty")-\(Int(width * 1000))-\(Int(height * 1000))"
    definitions += "<clipPath id=\"\(frameID)\"><rect width=\"\(width)\" height=\"\(height)\"/></clipPath>"
    return "<defs>\(definitions)</defs><g style=\"isolation:isolate\" clip-path=\"url(#\(frameID))\">" + body + "</g>"
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
        let kern = attrs[NSAttributedString.Key.kern] as? NSNumber
        let spacing = (attrs[NSAttributedString.Key.tracking] as? NSNumber)?.doubleValue ?? kern?.doubleValue ?? 0
        let kerning = kern?.doubleValue == 0 ? "none" : "normal"
        result +=
          "<text xml:space=\"preserve\" x=\"\((origins[i].x+p.x)/TypographyEngine.pointsPerMM)\" y=\"\(element.height+offset-(origins[i].y+p.y)/TypographyEngine.pointsPerMM)\" font-family=\"\(xml(font.fontName))\" font-size=\"\(font.pointSize/TypographyEngine.pointsPerMM)\" font-kerning=\"\(kerning)\" letter-spacing=\"\(spacing/TypographyEngine.pointsPerMM)\" fill=\"\(FormColor.hex(attrs[NSAttributedString.Key.foregroundColor] as? NSColor ?? .black))\" fill-opacity=\"\(element.fillOpacity ?? 1)\">\(xml(text))</text>"
      }
    }
    return result
  }
}

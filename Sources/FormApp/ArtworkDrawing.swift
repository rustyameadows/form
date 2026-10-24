import AppKit
import FormCore

@MainActor enum ArtworkDrawing {
  static func image(_ artwork: Artwork, width: Double, height: Double, assets: URL) -> NSImage {
    let scale = min(5, 2048 / max(width, height))
    let pixelWidth = max(1, Int(width * scale))
    let pixelHeight = max(1, Int(height * scale))
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.cgContext.scaleBy(x: scale, y: -scale)
    draw(artwork, width: width, height: height, assets: assets)
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: NSSize(width: pixelWidth, height: pixelHeight))
    image.addRepresentation(rep)
    return image
  }
  static func draw(_ artwork: Artwork, width: Double, height: Double, assets: URL) {
    NSColor(hex: artwork.background).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).addClip()
    for element in artwork.elements { draw(element, assets: assets) }
    NSGraphicsContext.restoreGraphicsState()
  }
  static func draw(_ element: ArtworkElement, assets: URL) {
    let rect = NSRect(x: element.x, y: element.y, width: element.width, height: element.height)
    let color = NSColor(hex: element.color)
    color.setFill()
    color.setStroke()
    switch element.kind {
    case "text":
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byWordWrapping
      let font = NSFont.systemFont(ofSize: element.fontSize * 25.4 / 72, weight: .medium)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .paragraphStyle: paragraph, .kern: 0.05,
      ]
      // Use a flipped AppKit context so the same coordinates serve the editor, texture, and PDF.
      NSGraphicsContext.saveGraphicsState()
      if let cg = NSGraphicsContext.current?.cgContext {
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
      }
      (element.text as NSString).draw(in: rect, withAttributes: attributes)
      NSGraphicsContext.restoreGraphicsState()
    case "ellipse": NSBezierPath(ovalIn: rect).fill()
    case "line":
      let line = NSBezierPath()
      line.move(to: rect.origin)
      line.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
      line.lineWidth = 0.5
      line.stroke()
    case "image":
      if let asset = element.asset, !asset.contains("/"),
        let image = NSImage(contentsOf: assets.appendingPathComponent(asset))
      {
        image.draw(
          in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
          hints: nil)
      }
    default: NSBezierPath(rect: rect).fill()
    }
  }
  static func dimensions(_ object: ProductObject) -> (width: Double, height: Double) {
    (max(object["width"], 10), max(object["depth"], 10))
  }
}

public enum Dieline {
  static func dimensions(_ object: ProductObject) -> (Double, Double) {
    (2 * object["width"] + 2 * object["height"] + object["tab"], object["depth"])
  }
  static func scores(_ object: ProductObject) -> [Double] {
    let w = object["width"]
    let s = object["height"]
    return [w, w + s, 2 * w + s, 2 * w + 2 * s]
  }
  static func svg(_ object: ProductObject, assets: URL? = nil) -> String {
    let (width, height) = dimensions(object)
    let w = object["width"]
    let spine = object["height"]
    var body = ""
    if let artwork = object.artwork {
      body +=
        "<defs><clipPath id=\"face\"><rect width=\"\(w)\" height=\"\(height)\"/></clipPath></defs><g transform=\"translate(\(w+spine),0)\" clip-path=\"url(#face)\"><rect width=\"\(w)\" height=\"\(height)\" fill=\"\(artwork.background)\"/>\n"
      for e in artwork.elements {
        switch e.kind {
        case "text":
          body +=
            "<text x=\"\(e.x)\" y=\"\(e.y+e.fontSize*25.4/72*0.82)\" font-family=\"Helvetica,Arial,sans-serif\" font-size=\"\(e.fontSize*25.4/72)\" fill=\"\(e.color)\">"
          for (i, line) in e.text.components(separatedBy: "\n").enumerated() {
            body +=
              "<tspan x=\"\(e.x)\" dy=\"\(i == 0 ? 0 : e.fontSize*25.4/72*1.2)\">\(xml(line))</tspan>"
          }
          body += "</text>\n"
        case "ellipse":
          body +=
            "<ellipse cx=\"\(e.x+e.width/2)\" cy=\"\(e.y+e.height/2)\" rx=\"\(e.width/2)\" ry=\"\(e.height/2)\" fill=\"\(e.color)\"/>\n"
        case "rectangle":
          body +=
            "<rect x=\"\(e.x)\" y=\"\(e.y)\" width=\"\(e.width)\" height=\"\(e.height)\" fill=\"\(e.color)\"/>\n"
        case "line":
          body +=
            "<path d=\"M \(e.x),\(e.y) l \(e.width),\(e.height)\" stroke=\"\(e.color)\" stroke-width=\"0.5\"/>\n"
        case "image":
          if let name = e.asset, !name.contains("/"), let assets,
            var data = try? Data(contentsOf: assets.appendingPathComponent(name))
          {
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            let mime =
              ext == "svg"
              ? "image/svg+xml" : ["jpg", "jpeg"].contains(ext) ? "image/jpeg" : "image/png"
            if !["svg", "png", "jpg", "jpeg"].contains(ext),
              let converted = NSImage(contentsOf: assets.appendingPathComponent(name))?.pngData()
            {
              data = converted
            }
            body +=
              "<image x=\"\(e.x)\" y=\"\(e.y)\" width=\"\(e.width)\" height=\"\(e.height)\" href=\"data:\(mime);base64,\(data.base64EncodedString())\"/>\n"
          }
        default: break
        }
      }
      body += "</g>\n"
    }
    // Emit each production line exactly once, above the artwork.
    for x in scores(object) {
      body +=
        "<path d=\"M \(x),0 V \(height)\" fill=\"none\" stroke=\"#4589B0\" stroke-width=\"0.2\" stroke-dasharray=\"3 2\"/>\n"
    }
    body +=
      "<rect x=\"0\" y=\"0\" width=\"\(width)\" height=\"\(height)\" fill=\"none\" stroke=\"#D45A37\" stroke-width=\"0.2\"/>\n"
    return
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)mm\" height=\"\(height)mm\" viewBox=\"0 0 \(width) \(height)\"><title>\(xml(object.name)) — cut and score dieline</title><desc>Millimeter scale. Red: cut. Blue dashed: score. Stock: \(object["stock"]) mm. Verify fit with your physical material.</desc>\n\(body)</svg>\n"
  }
  private static func xml(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
}

import AppKit
import FormCore
import FormGraphics

@MainActor enum ArtworkDrawing {
  static func image(
    _ artwork: Artwork, width: Double, height: Double, assets: URL, pixelsPerMM: Double? = nil
  ) -> NSImage {
    ArtworkRenderer.image(
      artwork, width: width, height: height, assets: assets, pixelsPerMM: pixelsPerMM)
  }
  static func draw(_ artwork: Artwork, width: Double, height: Double, assets: URL) {
    ArtworkRenderer.draw(artwork, width: width, height: height, assets: assets)
  }
  static func draw(_ element: ArtworkElement, assets: URL) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.concatenate(element.localTransform.cg)
    ArtworkRenderer.drawElement(element, assets: assets, context: context)
    context.restoreGState()
  }
  static func dimensions(_ object: ProductObject) -> (width: Double, height: Double) {
    (object.artworkSize.x, object.artworkSize.y)
  }
}

@MainActor public enum Dieline {
  static func dimensions(_ object: ProductObject) -> (Double, Double) {
    (2 * object["width"] + 2 * object["height"] + object["tab"], object["depth"])
  }
  static func scores(_ object: ProductObject) -> [Double] {
    let w = object["width"]
    let s = object["height"]
    return [w, w + s, 2 * w + s, 2 * w + 2 * s]
  }
  static func svg(_ object: ProductObject, assets: URL? = nil) throws -> String {
    let (width, height) = dimensions(object)
    let w = object["width"]
    let spine = object["height"]
    var body = ""
    if let artwork = object.artwork {
      body +=
        "<defs><clipPath id=\"face\"><rect width=\"\(w)\" height=\"\(height)\"/></clipPath></defs><g transform=\"translate(\(w+spine),0)\" clip-path=\"url(#face)\">\n"
      body += try SVGRenderer.fragment(
        artwork, width: w, height: height, assets: assets ?? URL(fileURLWithPath: "/"))
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

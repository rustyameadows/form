import CoreFoundation
import Foundation

/// A normalized, top-left-oriented window into the unchanged original asset.
public struct ImageCrop: Codable, Equatable, Sendable {
  public var x: Double, y: Double, width: Double, height: Double
  public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }
  enum CodingKeys: String, CodingKey { case x,y,width,height }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    x = try c.decodeIfPresent(Double.self,forKey:.x) ?? 0
    y = try c.decodeIfPresent(Double.self,forKey:.y) ?? 0
    width = try c.decodeIfPresent(Double.self,forKey:.width) ?? 1
    height = try c.decodeIfPresent(Double.self,forKey:.height) ?? 1
  }
  public static let full = ImageCrop()
  public static func filling(pixelWidth: Double, pixelHeight: Double, width: Double, height: Double) -> Self {
    let source = pixelWidth / pixelHeight, target = width / height
    if source > target {
      let w = target / source
      return .init(x: (1 - w) / 2, width: w)
    }
    let h = source / target
    return .init(y: (1 - h) / 2, height: h)
  }
  public func moved(dx: Double, dy: Double) -> Self {
    .init(x: max(0, min(1 - width, x + dx)), y: max(0, min(1 - height, y + dy)), width: width, height: height)
  }
  public func zoomed(_ factor: Double, anchor: Point2 = .init(0.5, 0.5)) -> Self {
    guard factor.isFinite, factor > 0 else { return self }
    let bounded = max(max(0.01/width,0.01/height),min(min(1/width,1/height),factor))
    let w = width * bounded, h = height * bounded
    return .init(x: max(0, min(1 - w, x + (width - w) * anchor.x)),
      y: max(0, min(1 - h, y + (height - h) * anchor.y)), width: w, height: h)
  }
}

public struct ImageAdjustments: Codable, Equatable, Sendable {
  public var brightness: Double = 0
  public var contrast: Double = 1
  public var saturation: Double = 1
  public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) {
    self.brightness = brightness; self.contrast = contrast; self.saturation = saturation
  }
  enum CodingKeys: String, CodingKey { case brightness,contrast,saturation }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    brightness = try c.decodeIfPresent(Double.self,forKey:.brightness) ?? 0
    contrast = try c.decodeIfPresent(Double.self,forKey:.contrast) ?? 1
    saturation = try c.decodeIfPresent(Double.self,forKey:.saturation) ?? 1
  }
  public var isIdentity: Bool { brightness == 0 && contrast == 1 && saturation == 1 }
  /// SVG saturation luminance weights, composed with contrast and brightness
  /// before the final clamp. Shared by Core Image and portable SVG output.
  public var colorMatrix: [[Double]] {
    let luminance = [0.213,0.715,0.072]
    let offset = 0.5 * (1 - contrast) + brightness
    return (0..<3).map { row in
      (0..<3).map { column in contrast * ((row == column ? saturation : 0) + (1-saturation)*luminance[column]) } + [0,offset]
    } + [[0,0,0,1,0]]
  }
}

public enum ImageCommands {
  public static func validate(_ e: ArtworkElement) throws {
    guard e.imageCrop == nil && e.imageAdjustments == nil || e.kind == "image" else {
      throw FormError.invalid("Image settings belong to image layers.")
    }
    if let c = e.imageCrop {
      guard [c.x,c.y,c.width,c.height].allSatisfy(\.isFinite), c.x >= 0, c.y >= 0,
        c.width >= 0.01, c.height >= 0.01, c.x + c.width <= 1.000000001,
        c.y + c.height <= 1.000000001 else {
        throw FormError.invalid("Crop must stay inside the original image, with at least 1% in each dimension.")
      }
    }
    if let a = e.imageAdjustments {
      guard !["pdf", "svg"].contains(URL(fileURLWithPath: e.asset ?? "").pathExtension.lowercased()) || a.isIdentity else {
        throw FormError.invalid("Color adjustments require a raster image; PDF/SVG references retain their vector appearance.")
      }
      guard a.brightness.isFinite, a.contrast.isFinite, a.saturation.isFinite,
        (-1...1).contains(a.brightness), (0...4).contains(a.contrast), (0...2).contains(a.saturation) else {
        throw FormError.invalid("Use brightness −1–1, contrast 0–4, and saturation 0–2.")
      }
    }
  }
  public static func apply(in project: inout Project, objectID: UUID, ids: Set<UUID>,
    crop: Any? = nil, adjustments: Any? = nil, reset: Bool = false) throws {
    guard let object = project.objects.first(where: { $0.id == objectID }),
      !project.artworkOwner(object).locked, var art = project.editableArtwork(object), !ids.isEmpty,
      ids.isSubset(of: Set(art.elements.map(\.id))) else { throw FormError.invalid("Choose image layers.") }
    func number(_ input: Any?, _ old: Double) throws -> Double {
      guard let input else { return old }
      guard let n = input as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
        throw FormError.invalid("Image settings must be finite numbers.")
      }
      return n.doubleValue
    }
    for i in art.elements.indices where ids.contains(art.elements[i].id) {
      guard art.elements[i].kind == "image", !art.isLocked(art.elements[i]) else {
        throw FormError.invalid("Choose unlocked image layers.")
      }
      if reset { art.elements[i].imageCrop = nil; art.elements[i].imageAdjustments = nil; continue }
      if let crop {
        if crop is NSNull { art.elements[i].imageCrop = nil }
        else {
          guard let v = crop as? [String: Any], Set(v.keys).isSubset(of: ["x","y","width","height"]) else {
            throw FormError.invalid("Crop accepts normalized x, y, width, and height.")
          }
          let old = art.elements[i].imageCrop ?? .full
          let c = ImageCrop(x: try number(v["x"],old.x), y: try number(v["y"],old.y),
            width: try number(v["width"],old.width), height: try number(v["height"],old.height))
          art.elements[i].imageCrop = c == .full ? nil : c
        }
      }
      if let adjustments {
        if adjustments is NSNull { art.elements[i].imageAdjustments = nil }
        else {
          guard let v = adjustments as? [String: Any], Set(v.keys).isSubset(of: ["brightness","contrast","saturation"]) else {
            throw FormError.invalid("Image adjustments accept brightness, contrast, and saturation.")
          }
          let old = art.elements[i].imageAdjustments ?? .init()
          let a = ImageAdjustments(brightness: try number(v["brightness"],old.brightness),
            contrast: try number(v["contrast"],old.contrast), saturation: try number(v["saturation"],old.saturation))
          art.elements[i].imageAdjustments = a.isIdentity ? nil : a
        }
      }
    }
    var candidate = project
    try candidate.setArtwork(art, for: objectID)
    project = candidate
  }
}

extension Artwork { public var requiresSchemaNine: Bool { elements.contains { $0.imageCrop != nil || $0.imageAdjustments != nil } } }

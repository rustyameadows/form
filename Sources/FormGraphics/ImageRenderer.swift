import AppKit
import CoreImage
import FormCore
import ImageIO

public struct ImageAssetInfo: Codable, Sendable {
  public var width: Int, height: Int, frames: Int
  public var format: String
  public var oriented: Bool
  public var aspect: Double { Double(width) / Double(height) }
  /// Conservative minimum DPI, including crop, ancestors, scale and shear.
  public func effectiveDPI(_ e: ArtworkElement, transform: Affine2) -> Double {
    let crop = e.imageCrop ?? .full
    let map = transform.followed(by: .scale(e.width / (Double(width) * crop.width),
      e.height / (Double(height) * crop.height)))
    let p = map.a * map.a + map.b * map.b, q = map.c * map.c + map.d * map.d
    let r = map.a * map.c + map.b * map.d
    let largest = sqrt(max(0, (p + q + sqrt((p - q) * (p - q) + 4*r*r)) / 2))
    return 25.4 / max(1e-12, largest)
  }
}

@MainActor public enum ImageRenderer {
  public static let maximumPixels = 16_000_000, maximumEdge = 8192
  private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
  private static let ci = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space,
    .cacheIntermediates: false])
  private final class InfoBox { let identity = UUID(); let value: ImageAssetInfo; init(_ value: ImageAssetInfo) { self.value = value } }
  private final class Bitmap { let image: CGImage; init(_ image: CGImage) { self.image = image } }
  private static let infoCache: NSCache<NSString, InfoBox> = { let c = NSCache<NSString, InfoBox>(); c.countLimit = 500; return c }()
  private static let cache: NSCache<NSString, Bitmap> = {
    let c = NSCache<NSString, Bitmap>(); c.totalCostLimit = 64_000_000; c.countLimit = 200; return c
  }()
  private static var builds = 0, hits = 0, limited = 0
  private static var lastMS = 0.0
  public static var diagnostics: [String: Any] {
    ["builds": builds, "cache_hits": hits, "preview_scale_limits": limited,
      "cache_limit_bytes": 64_000_000, "last_build_ms": lastMS]
  }
  public static func invalidate(_ url: URL) { infoCache.removeObject(forKey:url.path as NSString) }
  public static func info(_ url: URL) throws -> ImageAssetInfo {
    if let cached = infoCache.object(forKey: url.path as NSString) { return cached.value }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let w = properties[kCGImagePropertyPixelWidth] as? Int,
      let h = properties[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0,
      Double(w) * Double(h) <= 100_000_000, max(w,h) <= 65535 else {
      throw FormError.invalid("Choose a readable raster image, up to 100 megapixels. PDF/SVG references have no fixed pixel resolution.")
    }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    let swap = (5...8).contains(orientation)
    let result = ImageAssetInfo(width: swap ? h : w, height: swap ? w : h,
      frames: CGImageSourceGetCount(source), format: (CGImageSourceGetType(source) as String?) ?? url.pathExtension,
      oriented: orientation != 1)
    infoCache.setObject(InfoBox(result), forKey: url.path as NSString)
    return result
  }
  public static func requestedEdge(_ e: ArtworkElement, transform: CGAffineTransform, metadata: ImageAssetInfo) -> Double {
    let map = Affine2(a: transform.a, b: transform.b, c: transform.c, d: transform.d)
    return Double(max(metadata.width,metadata.height)) * 25.4 / metadata.effectiveDPI(e, transform: map)
  }
  public static func validateOutput(_ e: ArtworkElement, assets: URL, pixelsPerMM: Double, transform: Affine2) throws {
    guard let name = e.asset, !name.contains("/"), let metadata = try? info(assets.appendingPathComponent(name)) else { return }
    let requested = min(Double(max(metadata.width,metadata.height)), requestedEdge(e,
      transform: transform.followed(by: .scale(pixelsPerMM,pixelsPerMM)).cg, metadata: metadata))
    let pixels = requested * requested / max(metadata.aspect, 1 / metadata.aspect)
    guard requested <= Double(maximumEdge), pixels <= Double(maximumPixels) else {
      throw FormError.invalid("A cropped image needs too much raster data at this resolution. Lower the export DPI or reduce its physical size.")
    }
  }
  public static func bitmap(_ url: URL, adjustments: ImageAdjustments? = nil, requestedEdge: Double) throws -> CGImage {
    let metadata = try info(url)
    let original = Double(max(metadata.width,metadata.height))
    let cap = min(Double(maximumEdge), sqrt(Double(maximumPixels) * max(metadata.aspect,1/metadata.aspect)))
    let edge = min(original, cap, max(64, ceil(requestedEdge / 64) * 64))
    if requestedEdge > cap && original > cap { limited += 1 }
    let adjustment = adjustments ?? .init()
    let revision = infoCache.object(forKey:url.path as NSString)?.identity.uuidString ?? ""
    let key = "\(url.path)|\(revision)|\(Int(edge))|\(adjustment.brightness)|\(adjustment.contrast)|\(adjustment.saturation)" as NSString
    if let cached = cache.object(forKey: key) { hits += 1; return cached.image }
    let start = CFAbsoluteTimeGetCurrent()
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(edge), kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary) else { throw FormError.invalid("This image could not be decoded.") }
    var result = image
    if !adjustment.isIdentity {
      let m = adjustment.colorMatrix
      let adjusted = CIImage(cgImage: image).applyingFilter("CIColorMatrix",parameters:[
        "inputRVector": CIVector(x:m[0][0],y:m[0][1],z:m[0][2],w:m[0][3]),
        "inputGVector": CIVector(x:m[1][0],y:m[1][1],z:m[1][2],w:m[1][3]),
        "inputBVector": CIVector(x:m[2][0],y:m[2][1],z:m[2][2],w:m[2][3]),
        "inputAVector": CIVector(x:0,y:0,z:0,w:1),
        "inputBiasVector": CIVector(x:m[0][4],y:m[1][4],z:m[2][4],w:0),
      ])
      guard let output = ci.createCGImage(adjusted, from: adjusted.extent, format: .RGBA8, colorSpace: space) else {
        throw FormError.invalid("The image adjustments could not be rendered.")
      }
      result = output
    }
    cache.setObject(Bitmap(result), forKey: key, cost: result.bytesPerRow * result.height)
    builds += 1; lastMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
    return result
  }
  public static func draw(_ e: ArtworkElement, assets: URL, context: CGContext) -> Bool {
    guard let name = e.asset, !name.contains("/") else { return false }
    let url = assets.appendingPathComponent(name)
    let crop = e.imageCrop ?? .full
    guard let metadata = try? info(url) else { return false }
    let cropMap = CGAffineTransform(scaleX: AppearanceRenderer.scale(context), y: AppearanceRenderer.scale(context))
    let requested = requestedEdge(e, transform: cropMap, metadata: metadata)
    guard let image = try? bitmap(url, adjustments: e.imageAdjustments, requestedEdge: requested) else { return false }
    context.saveGState()
    context.clip(to: CGRect(x: 0,y: 0,width: e.width,height: e.height))
    context.scaleBy(x: e.width / crop.width, y: e.height / crop.height)
    context.translateBy(x: -crop.x, y: -crop.y)
    NSImage(cgImage: image, size: .init(width: image.width,height: image.height)).draw(
      in: .init(x: 0,y: 0,width: 1,height: 1), from: .zero, operation: .sourceOver,
      fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    context.restoreGState()
    return true
  }
}

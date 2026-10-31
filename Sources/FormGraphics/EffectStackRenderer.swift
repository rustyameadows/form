import AppKit
import CoreImage
import FormCore

public struct EffectStackLayer {
  public let image: CGImage
  public let blendMode: String?
}
public struct EffectStackRaster {
  public let behind: [EffectStackLayer]
  public let content: CGImage
  public let above: [EffectStackLayer]
  public var byteCost: Int { content.width * content.height * 4 * (1 + behind.count + above.count) }
}

/// Pure, bounded effect rasterization. The caller owns caching and draws each
/// returned shadow with its blend mode against the actual destination. A layer
/// blur is an explicit isolation boundary and blurs the complete composition.
@MainActor public enum EffectStackRenderer {
  public static let maximumEdge = 8192
  private static let maximumWorkingPixels = 32_000_000
  private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private static let context = CIContext(options: [.workingColorSpace: colorSpace,
    .outputColorSpace: colorSpace, .cacheIntermediates: false])
  public static func maximumPixelsPerRender(_ stack: ArtworkEffectStack) -> Int {
    // Include source, two silhouettes, inverse/filter intermediates and output.
    maximumWorkingPixels / (6 + stack.activeEffects.filter { $0.kind != "blur" }.count)
  }
  public static func render(source: CGImage, casting: CGImage? = nil, knockout: CGImage? = nil,
    stack: ArtworkEffectStack, density: Double,
    spreadCoverage: ((ArtworkEffect) -> CGImage?)? = nil) throws -> EffectStackRaster {
    try stack.validate()
    try Task.checkCancellation()
    let width = source.width, height = source.height
    guard density.isFinite, density > 0, width > 0, height > 0,
      width <= maximumEdge, height <= maximumEdge,
      width * height <= maximumPixelsPerRender(stack),
      [casting, knockout].compactMap({ $0 }).allSatisfy({ $0.width == width && $0.height == height }) else {
      throw FormError.invalid("The effect raster exceeds its bounded layer budget or has inconsistent silhouettes.")
    }
    if stack.coverage == "paint-outline", casting == nil || knockout == nil {
      throw FormError.invalid("Paint-outline effects require both casting and knockout silhouettes.")
    }
    let extent = CGRect(x: 0, y: 0, width: width, height: height)
    let cast = CIImage(cgImage: stack.coverage == "paint-outline" ? casting! : source)
    let cutout = CIImage(cgImage: stack.coverage == "paint-outline" ? knockout! : source)
    let white = CIImage(color: .init(red: 1, green: 1, blue: 1, alpha: 1))
    var behind: [EffectStackLayer] = [], above: [EffectStackLayer] = []
    for effect in stack.activeEffects where effect.kind != "blur" {
      try Task.checkCancellation()
      let dx = effect.offset.x * density, dy = -effect.offset.y * density
      let spread = effect.spread * density, sigma = effect.blur * density
      guard [dx, dy, spread, sigma].allSatisfy(\.isFinite),
        abs(dx) <= Double(maximumEdge)*2, abs(dy) <= Double(maximumEdge)*2,
        abs(spread) <= Double(maximumEdge), sigma <= Double(maximumEdge) else {
        throw FormError.invalid("Effect distances exceed the raster coordinate range.")
      }
      let prepared = effect.spread != 0 && stack.coverage == "paint-outline" ? spreadCoverage?(effect) : nil
      if let prepared, prepared.width != width || prepared.height != height {
        throw FormError.invalid("Analytic shadow coverage has inconsistent raster dimensions.")
      }
      let spreadCast = prepared.map { CIImage(cgImage: $0) } ?? cast
      var alpha: CIImage
      if effect.kind == "inner-shadow" {
        // Keep the inverse infinite until after translation and blur. Cropping
        // it first would invent transparent edges at the raster's boundary.
        alpha = white.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: spreadCast])
        if prepared == nil { alpha = morphology(alpha, spread: spread) }
      } else {
        alpha = white.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: spreadCast])
        if prepared == nil { alpha = morphology(alpha, spread: spread) }
      }
      if sigma > 0 { alpha = alpha.applyingGaussianBlur(sigma: sigma) }
      alpha = alpha.transformed(by: .init(translationX: dx, y: dy))
      if effect.kind == "inner-shadow" {
        alpha = alpha.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: cast])
      } else if effect.knockout {
        alpha = alpha.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: cutout])
      }
      let color = FormColor.color(effect.color).usingColorSpace(.sRGB)!
      let ink = CIImage(color: .init(red: color.redComponent, green: color.greenComponent,
        blue: color.blueComponent, alpha: effect.opacity))
      let tinted = ink.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: alpha]).cropped(to: extent)
      let layer = EffectStackLayer(image: try raster(tinted, extent: extent), blendMode: effect.blendMode)
      if effect.kind == "inner-shadow" { above.append(layer) } else { behind.append(layer) }
    }
    let sigma = sqrt(stack.activeEffects.filter { $0.kind == "blur" }.reduce(0) { $0 + $1.blur * $1.blur }) * density
    guard sigma > 0 else { return .init(behind: behind, content: source, above: above) }
    guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      throw FormError.invalid("Could not allocate the isolated layer blur.")
    }
    for layer in behind { bitmap.setBlendMode(AppearanceRenderer.blend(layer.blendMode)); bitmap.draw(layer.image, in: extent) }
    bitmap.setBlendMode(.normal); bitmap.draw(source, in: extent)
    for layer in above { bitmap.setBlendMode(AppearanceRenderer.blend(layer.blendMode)); bitmap.draw(layer.image, in: extent) }
    guard let merged = bitmap.makeImage() else { throw FormError.invalid("Could not compose the layer blur.") }
    try Task.checkCancellation()
    let image = try raster(CIImage(cgImage: merged).applyingGaussianBlur(sigma: sigma).cropped(to: extent), extent: extent)
    return .init(behind: [], content: image, above: [])
  }
  private static func morphology(_ image: CIImage, spread: Double) -> CIImage {
    guard spread != 0 else { return image }
    // Independent horizontal/vertical morphology follows rectangular spread;
    // the importer omits spread for source kinds that do not apply it.
    let size = 2 * abs(spread) + 1
    return image.applyingFilter(spread > 0 ? "CIMorphologyRectangleMaximum" : "CIMorphologyRectangleMinimum",
      parameters: ["inputWidth": size, "inputHeight": size])
  }
  private static func raster(_ image: CIImage, extent: CGRect) throws -> CGImage {
    guard let result = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace) else {
      throw FormError.invalid("Could not render the ordered appearance effects.")
    }
    return result
  }
}

import Foundation

/// A resolution-independent ink source. Image coordinates and transforms are
/// normalized to the element frame; image bytes remain ordinary portable assets.
public struct ArtworkPaint: Codable, Equatable, Sendable {
  public var kind: String
  public var color: String
  public var opacity: Double
  public var blendMode: String?
  public var gradient: ArtworkGradient?
  public var asset: String?
  public var imageTransform: Affine2?
  public var imageAdjustments: ImageAdjustments?
  public var imageRepeat: Bool?
  public init(kind: String = "solid", color: String = "#000000", opacity: Double = 1,
    blendMode: String? = nil, gradient: ArtworkGradient? = nil, asset: String? = nil,
    imageTransform: Affine2? = nil, imageAdjustments: ImageAdjustments? = nil,
    imageRepeat: Bool? = nil) {
    self.kind = kind; self.color = color; self.opacity = opacity; self.blendMode = blendMode
    self.gradient = gradient; self.asset = asset; self.imageTransform = imageTransform
    self.imageAdjustments = imageAdjustments; self.imageRepeat = imageRepeat
  }
}

/// Ordered fill/stroke paint. A nil stroke paints glyph/shape interiors;
/// otherwise the stroke describes coverage and `paint` supplies its ink.
public struct ArtworkPaintLayer: Codable, Equatable, Sendable {
  public var paint: ArtworkPaint
  public var stroke: ArtworkStroke?
  public var enabled: Bool
  public init(_ paint: ArtworkPaint, stroke: ArtworkStroke? = nil, enabled: Bool = true) {
    self.paint = paint; self.stroke = stroke; self.enabled = enabled
  }
}

extension ArtworkPaintLayer {
  public var effectivePaint:ArtworkPaint {
    var ink=paint;ink.opacity *= stroke?.opacity ?? 1;return ink
  }
  /// A color edit replaces fill ink, preserving opacity, ordering, blend modes,
  /// and stroke appearance. Font/content edits never call this operation.
  public static func recoloringFills(_ layers: [Self], color: String) -> [Self] {
    var result = layers
    var found = false
    for index in result.indices where result[index].stroke == nil {
      found = true
      result[index].paint.kind = "solid"
      result[index].paint.color = color
      result[index].paint.gradient = nil
      result[index].paint.asset = nil
      result[index].paint.imageTransform = nil
      result[index].paint.imageAdjustments = nil
      result[index].paint.imageRepeat = nil
    }
    if !found { result.insert(.init(.init(color: color)), at: 0) }
    return result
  }
}

extension ArtworkElement {
  /// Updates whole-element text fill intent, including explicit rich-span paints.
  /// Ordinary solid text retains its compact legacy representation.
  public mutating func recolorTextFill(_ color: String) {
    self.color = color; fillSwatchID = nil
    if let stack = paintStack { paintStack = ArtworkPaintLayer.recoloringFills(stack, color: color) }
    gradient = nil; fillEnabled = true
    for index in textRuns?.indices ?? 0..<0 {
      textRuns![index].color = color; textRuns![index].swatchID = nil
      if let stack = textRuns![index].paintStack {
        textRuns![index].paintStack = ArtworkPaintLayer.recoloringFills(stack, color: color)
      }
    }
  }
}

import Foundation

/// Ordered native appearance effects. All distances, including Gaussian sigma,
/// are millimeters; source-format sliders are normalized by their importer.
public struct ArtworkEffect: Codable, Equatable, Sendable {
  public var kind: String
  public var enabled: Bool
  public var offset: Point2
  public var blur: Double
  public var spread: Double
  public var color: String
  public var opacity: Double
  public var blendMode: String?
  public var knockout: Bool
  public var swatchID: UUID?
  public init(kind: String, enabled: Bool = true, offset: Point2 = .init(), blur: Double = 0,
    spread: Double = 0, color: String = "#000000", opacity: Double = 1,
    blendMode: String? = nil, knockout: Bool = false, swatchID: UUID? = nil) {
    self.kind=kind;self.enabled=enabled;self.offset=offset;self.blur=blur;self.spread=spread
    self.color=color;self.opacity=opacity;self.blendMode=blendMode;self.knockout=knockout;self.swatchID=swatchID
  }
  public var isActive: Bool { enabled && (kind == "blur" ? blur > 0 : opacity > 0) }
  enum CodingKeys:String,CodingKey {case kind,enabled,offset,blur,spread,color,opacity,blendMode,knockout,swatchID}
  public init(from decoder:Decoder)throws {
    let value=try decoder.container(keyedBy:CodingKeys.self)
    kind=try value.decode(String.self,forKey:.kind)
    enabled=try value.decodeIfPresent(Bool.self,forKey:.enabled) ?? true
    offset=try value.decodeIfPresent(Point2.self,forKey:.offset) ?? .init()
    blur=try value.decodeIfPresent(Double.self,forKey:.blur) ?? 0
    spread=try value.decodeIfPresent(Double.self,forKey:.spread) ?? 0
    color=try value.decodeIfPresent(String.self,forKey:.color) ?? "#000000"
    opacity=try value.decodeIfPresent(Double.self,forKey:.opacity) ?? 1
    blendMode=try value.decodeIfPresent(String.self,forKey:.blendMode)
    knockout=try value.decodeIfPresent(Bool.self,forKey:.knockout) ?? false
    swatchID=try value.decodeIfPresent(UUID.self,forKey:.swatchID)
  }
}

/// `paint-alpha` uses actual rendered alpha. `paint-outline` uses separately
/// rendered full-strength casting/knockout silhouettes, keeping that semantic
/// distinction explicit instead of altering the artwork's editable paints.
public struct ArtworkEffectStack: Codable, Equatable, Sendable {
  public var coverage: String
  public var effects: [ArtworkEffect]
  public init(coverage: String = "paint-alpha", effects: [ArtworkEffect] = []) {
    self.coverage=coverage;self.effects=effects
  }
  enum CodingKeys:String,CodingKey {case coverage,effects}
  public init(from decoder:Decoder)throws {
    let value=try decoder.container(keyedBy:CodingKeys.self)
    coverage=try value.decodeIfPresent(String.self,forKey:.coverage) ?? "paint-alpha"
    effects=try value.decode([ArtworkEffect].self,forKey:.effects)
  }
  public var hasActiveEffects: Bool { effects.contains(where: \.isActive) }
  public var activeEffects: [ArtworkEffect] { effects.filter(\.isActive) }
  public func validate() throws {
    guard ["paint-alpha","paint-outline"].contains(coverage),effects.count<=16 else {
      throw FormError.invalid("An appearance stack supports at most 16 effects and an explicit alpha source.")
    }
    for effect in effects {
      try validateColor(effect.color)
      guard ["drop-shadow","inner-shadow","blur"].contains(effect.kind),
        [effect.offset.x,effect.offset.y].allSatisfy({$0.isFinite && abs($0)<=100}),
        effect.blur.isFinite,(0...50).contains(effect.blur),effect.spread.isFinite,abs(effect.spread)<=50,
        effect.opacity.isFinite,(0...1).contains(effect.opacity),
        AppearanceCommands.blendModes.contains(effect.blendMode ?? "normal") else {
        throw FormError.invalid("Check effect kind, offsets (±100 mm), blur (0–50 mm), spread (±50 mm), opacity and blend mode.")
      }
      if effect.kind == "blur", effect.spread != 0 || effect.offset != .init() || effect.knockout || effect.blendMode != nil {
        throw FormError.invalid("Layer blur uses only its Gaussian sigma and enabled setting.")
      }
    }
  }
  /// Shadows are independently cast from the original layer, never from a
  /// preceding shadow. Inner shadows cannot expand the layer's visible bounds.
  public func expandedBounds(_ source: Rect2) -> Rect2 {
    var result=source
    for effect in activeEffects where effect.kind == "drop-shadow" {
      result=result.union(source.expanded(max(0,effect.spread)+effect.blur*4).translated(effect.offset))
    }
    let sigma=sqrt(activeEffects.filter{$0.kind == "blur"}.reduce(0){$0+$1.blur*$1.blur})
    return sigma>0 ? result.expanded(sigma*4):result
  }
}

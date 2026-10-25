import CoreFoundation
import Foundation

public struct ArtworkBlur: Codable, Equatable, Sendable {
  public var enabled = true
  public var radius = 1.0
  public init() {}
  enum CodingKeys: String, CodingKey { case enabled, radius }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 1
  }
}

public struct ArtworkShadow: Codable, Equatable, Sendable {
  public var enabled = true
  public var offset = Point2(2, 2)
  public var blur = 1.0
  public var color = "#292D2C"
  public var opacity = 0.35
  public var swatchID: UUID?
  public init() {}
  enum CodingKeys: String, CodingKey { case enabled, offset, blur, color, opacity, swatchID }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    offset = try c.decodeIfPresent(Point2.self, forKey: .offset) ?? .init(2, 2)
    blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 1
    color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#292D2C"
    opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.35
    swatchID = try c.decodeIfPresent(UUID.self, forKey: .swatchID)
  }
}

extension ArtworkElement {
  public var hasActiveEffects: Bool {
    (blur?.enabled == true && (blur?.radius ?? 0) > 0)
      || (shadow?.enabled == true && (shadow?.opacity ?? 0) > 0)
  }
}

public enum AppearanceCommands {
  public static let blendModes = ["normal", "multiply", "screen", "overlay", "darken", "lighten",
    "color-dodge", "color-burn", "hard-light", "soft-light", "difference", "exclusion",
    "hue", "saturation", "color", "luminosity"]

  public static func apply(in project: inout Project, objectID: UUID, ids: Set<UUID>,
    values: [String: Any], reset: Bool = false) throws {
    guard let object = project.objects.first(where: { $0.id == objectID }),
      var art = project.editableArtwork(object), !ids.isEmpty,
      ids.isSubset(of: Set(art.elements.map(\.id)))
    else { throw FormError.invalid("Choose artwork layers to edit their appearance.") }
    let roots = art.selectionRoots(ids)
    let masks = Set(art.elements.compactMap(\.clipID))
    guard roots.allSatisfy({ !art.isLocked($0) && !masks.contains($0.id) }) else {
      throw FormError.invalid("Choose unlocked artwork; clipping masks use geometry only.")
    }
    guard Set(values.keys).isSubset(of: ["opacity", "blend_mode", "isolate", "blur", "shadow"]) else {
      throw FormError.invalid("Unknown appearance property.")
    }
    func number(_ value: Any?, _ old: Double) throws -> Double {
      guard let value else { return old }
      guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
        throw FormError.invalid("Appearance values must be finite numbers.")
      }
      return n.doubleValue
    }
    for root in roots {
      let i = art.elements.firstIndex { $0.id == root.id }!
      if reset {
        art.elements[i].opacity = nil
        art.elements[i].blendMode = nil
        art.elements[i].isolatedBlending = nil
        art.elements[i].blur = nil
        art.elements[i].shadow = nil
        continue
      }
      if let value = values["opacity"] { art.elements[i].opacity = try number(value, 1) }
      if let value = values["blend_mode"] {
        guard let mode = value as? String else { throw FormError.invalid("Choose a blend mode.") }
        art.elements[i].blendMode = mode == "normal" ? nil : mode
      }
      if let value = values["isolate"] {
        guard root.kind == "group", let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
          throw FormError.invalid("Group isolation must be a boolean on a group.")
        }
        art.elements[i].isolatedBlending = n.boolValue ? true : nil
      }
      if let value = values["blur"] {
        if value is NSNull { art.elements[i].blur = nil }
        else {
          guard let input = value as? [String: Any], Set(input.keys).isSubset(of: ["enabled", "radius"]) else {
            throw FormError.invalid("Blur accepts enabled and radius in millimeters.")
          }
          var blur = art.elements[i].blur ?? .init()
          if let enabled = input["enabled"] {
            guard let enabled = enabled as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID() else { throw FormError.invalid("Blur enabled must be a boolean.") }
            blur.enabled = enabled.boolValue
          }
          blur.radius = try number(input["radius"], blur.radius)
          art.elements[i].blur = blur
        }
      }
      if let value = values["shadow"] {
        if value is NSNull { art.elements[i].shadow = nil }
        else {
          guard let input = value as? [String: Any], Set(input.keys).isSubset(of: ["enabled", "x", "y", "blur", "color", "opacity"]) else {
            throw FormError.invalid("Shadow accepts enabled, x/y offset, blur, color, and opacity.")
          }
          var shadow = art.elements[i].shadow ?? .init()
          if let enabled = input["enabled"] {
            guard let enabled = enabled as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID() else { throw FormError.invalid("Shadow enabled must be a boolean.") }
            shadow.enabled = enabled.boolValue
          }
          shadow.offset.x = try number(input["x"], shadow.offset.x)
          shadow.offset.y = try number(input["y"], shadow.offset.y)
          shadow.blur = try number(input["blur"], shadow.blur)
          shadow.opacity = try number(input["opacity"], shadow.opacity)
          if let color = input["color"] {
            guard let color = color as? String else { throw FormError.invalid("Use a six-digit shadow color.") }
            shadow.color = color
            shadow.swatchID = nil
          }
          art.elements[i].shadow = shadow
        }
      }
    }
    var candidate = project
    try candidate.setArtwork(art, for: objectID)
    project = candidate
  }
}

extension Rect2 {
  public func expanded(_ amount: Double) -> Rect2 {
    .init(x - amount, y - amount, width + 2 * amount, height + 2 * amount)
  }
  public func translated(_ point: Point2) -> Rect2 { .init(x + point.x, y + point.y, width, height) }
  public func intersection(_ other: Rect2) -> Rect2 {
    let left = max(x, other.x), top = max(y, other.y)
    return .init(left, top, max(0, min(maxX, other.maxX) - left), max(0, min(maxY, other.maxY) - top))
  }
}

extension Artwork {
  public var requiresSchemaEight: Bool {
    elements.contains { $0.blendMode != nil || $0.isolatedBlending != nil || $0.blur != nil || $0.shadow != nil }
  }

  /// Conservative visual bounds in the layer's local coordinates. Geometric
  /// selection handles stay independent from appearance and manufacturing paths.
  public func localVisualBounds(of element: ArtworkElement) -> Rect2 {
    let children = Dictionary(grouping: elements, by: \.parentID)
    let byID = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
    let masks = Set(elements.compactMap(\.clipID))
    func local(_ e: ArtworkElement) -> Rect2 {
      var bounds = Rect2(0, 0, e.paintSize.x, e.paintSize.y)
      if e.kind == "group", e.booleanOperation == nil {
        let parts = (children[e.id] ?? []).filter { $0.hidden != true && !masks.contains($0.id) }
        if let first = parts.first { bounds = parts.dropFirst().reduce(parent(first)) { $0.union(parent($1)) } }
      } else {
        if let path = e.path {
          let points = path.contours.flatMap(\.nodes).flatMap { [$0.anchor, $0.incoming ?? $0.anchor, $0.outgoing ?? $0.anchor] }
          if let first = points.first {
            let box = points.dropFirst().reduce(Rect2(first.x, first.y, 0, 0)) { $0.union(.init($1.x, $1.y, 0, 0)) }
            bounds = Affine2.scale(e.width / path.width, e.height / path.height).bounds(box)
          }
        }
        if let stroke = e.stroke, stroke.width > 0 {
          bounds = bounds.expanded(stroke.width / 2 * (stroke.join == "miter" || stroke.join == nil ? stroke.miter ?? 10 : 1))
        } else if e.kind == "line" { bounds = bounds.expanded(0.2) }
      }
      if let blur = e.blur, blur.enabled { bounds = bounds.expanded(blur.radius * 4) }
      if let shadow = e.shadow, shadow.enabled, shadow.opacity > 0 {
        bounds = bounds.union(bounds.expanded(shadow.blur * 4).translated(shadow.offset))
      }
      return bounds
    }
    func parent(_ e: ArtworkElement) -> Rect2 {
      let value = e.localTransform.bounds(local(e))
      guard let id = e.clipID, let mask = byID[id] else { return value }
      return value.intersection(mask.localTransform.bounds(.init(0, 0, mask.width, mask.height)))
    }
    return local(element)
  }

  public func visualBounds(of element: ArtworkElement) -> Rect2 {
    worldTransform(element).bounds(localVisualBounds(of: element))
  }
}

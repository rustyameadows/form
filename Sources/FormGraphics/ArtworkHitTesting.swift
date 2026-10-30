import CoreGraphics
import FormCore
import Foundation

/// Picking uses painted geometry in artwork coordinates. Expanding that geometry
/// after its world transform keeps the pointer allowance constant on screen,
/// including inside scaled, rotated and sheared groups.
@MainActor public enum ArtworkHitTesting {
  public static func hit(
    at point: CGPoint, in artwork: Artwork, scope: UUID? = nil, tolerance: Double = 0,
    excluding: Set<UUID> = [], editingMask: UUID? = nil, renderedArtwork: Artwork? = nil
  ) -> ArtworkElement? {
    Picker(in: artwork, scope: scope, excluding: excluding, editingMask: editingMask,
      renderedArtwork: renderedArtwork).hit(at: point, tolerance: tolerance)
  }

  /// An immutable artwork snapshot with lazy geometry caches for continuous
  /// pointer hover. Replace it when artwork, isolation scope or visibility changes;
  /// zoom changes only require a different per-call tolerance.
  @MainActor public final class Picker {
    private let context: Context
    private let candidates: [ArtworkElement]
    private let editingMask: UUID?

    public init(in artwork: Artwork, scope: UUID? = nil, excluding: Set<UUID> = [],
      editingMask: UUID? = nil, renderedArtwork: Artwork? = nil) {
      let context = Context(renderedArtwork ?? artwork, excluding: excluding)
      self.context = context
      self.editingMask = editingMask
      candidates = artwork.elements.reversed().filter { element in
        guard element.parentID == scope, !excluding.contains(element.id) else { return false }
        if let editingMask { return element.id == editingMask && !artwork.isLocked(element) }
        return artwork.editable(element) && !context.masks.contains(element.id)
      }
    }

    public func hit(at point: CGPoint, tolerance: Double = 0) -> ArtworkElement? {
      guard point.x.isFinite, point.y.isFinite else { return nil }
      // A direct click on painted content takes precedence over another object's
      // nearby edge. Only use the generous pointer allowance after exact hits.
      for allowance in tolerance.isFinite && tolerance > 0 ? [0, tolerance] : [0] {
        for source in candidates {
          let element = context.byID[source.id] ?? source
          if let editingMask, element.id == editingMask {
            if context.shapeContains(element, point: point, tolerance: allowance, mask: true) { return source }
          } else if context.ancestorsAllow(element, point: point),
            context.contains(element, point: point, tolerance: allowance) {
            return source
          }
        }
      }
      return nil
    }
  }

  @MainActor private final class Context {
    let artwork: Artwork
    let byID: [UUID: ArtworkElement]
    let children: [UUID?: [ArtworkElement]]
    let masks: Set<UUID>
    let excluding: Set<UUID>
    private var transforms: [UUID: Affine2] = [:]
    private var fillPaths: [UUID: CGPath] = [:]
    private var strokePaths: [UUID: CGPath] = [:]
    private var clipPaths: [UUID: CGPath] = [:]
    private var booleanProxies: [UUID: ArtworkElement] = [:]
    private var invalidBooleans = Set<UUID>()
    private struct PaintKey: Hashable { var id: UUID; var stroke: Bool; var mask: Bool }
    private var proximityPaths: [PaintKey: CGPath] = [:]

    init(_ artwork: Artwork, excluding: Set<UUID>) {
      self.artwork = artwork
      self.excluding = excluding
      byID = Dictionary(uniqueKeysWithValues: artwork.elements.map { ($0.id, $0) })
      children = Dictionary(grouping: artwork.elements, by: \.parentID)
      masks = Set(artwork.elements.compactMap(\.clipID))
    }

    private func visible(_ element: ArtworkElement) -> Bool {
      element.hidden != true && (element.opacity ?? 1) > 0
        && !excluding.contains(element.id) && !masks.contains(element.id)
    }

    private func clipAllows(_ element: ArtworkElement, point: CGPoint) -> Bool {
      guard let id = element.clipID, let mask = byID[id] else { return true }
      // Mask paint/visibility does not affect the clip; it is geometry only.
      return worldPath(mask).contains(point, using: mask.path?.evenOdd == true ? .evenOdd : .winding)
    }

    func ancestorsAllow(_ element: ArtworkElement, point: CGPoint) -> Bool {
      var parent = element.parentID, seen = Set<UUID>()
      while let id = parent, let ancestor = byID[id], seen.insert(id).inserted {
        guard visible(ancestor), clipAllows(ancestor, point: point) else { return false }
        parent = ancestor.parentID
      }
      return true
    }

    func contains(_ element: ArtworkElement, point: CGPoint, tolerance: Double, depth: Int = 0) -> Bool {
      guard depth <= 32, visible(element), clipAllows(element, point: point) else { return false }
      if element.booleanOperation != nil {
        let proxy: ArtworkElement
        if let cached = booleanProxies[element.id] { proxy = cached }
        else {
          guard !invalidBooleans.contains(element.id),
            let resolved = try? BooleanGeometry.proxy(element, in: artwork) else {
            invalidBooleans.insert(element.id)
            return false
          }
          booleanProxies[element.id] = resolved; proxy = resolved
        }
        return shapeContains(proxy, point: point, tolerance: tolerance)
      }
      if element.kind == "group" {
        return (children[element.id] ?? []).reversed().contains {
          contains($0, point: point, tolerance: tolerance, depth: depth + 1)
        }
      }
      return shapeContains(element, point: point, tolerance: tolerance)
    }

    private func worldPath(_ element: ArtworkElement) -> CGPath {
      if let cached = fillPaths[element.id] { return cached }
      var transform = worldTransform(element).cg
      let local = VectorGeometry.path(element)
      let path = local.copy(using: &transform) ?? local
      fillPaths[element.id] = path
      return path
    }

    private func worldTransform(_ element: ArtworkElement) -> Affine2 {
      if let cached = transforms[element.id] { return cached }
      var transform = element.localTransform
      var parent = element.parentID, seen: Set<UUID> = [element.id]
      while let id = parent, let ancestor = byID[id], seen.insert(id).inserted {
        if let cached = transforms[id] {
          transform = cached.followed(by: transform)
          break
        }
        transform = ancestor.localTransform.followed(by: transform)
        parent = ancestor.parentID
      }
      transforms[element.id] = transform
      return transform
    }

    private func clips(for element: ArtworkElement) -> [CGPath] {
      var result: [CGPath] = [], current: ArtworkElement? = element, seen = Set<UUID>()
      while let item = current, seen.insert(item.id).inserted {
        if let id = item.clipID, let mask = byID[id] {
          if let cached = clipPaths[id] { result.append(cached) }
          else {
            let path = worldPath(mask).normalized(using: mask.path?.evenOdd == true ? .evenOdd : .winding)
            clipPaths[id] = path; result.append(path)
          }
        }
        current = item.parentID.flatMap { byID[$0] }
      }
      return result
    }

    private func proximityPath(_ path: CGPath, for element: ArtworkElement, rule: CGPathFillRule,
      stroke: Bool = false, mask: Bool = false) -> CGPath {
      let key = PaintKey(id: element.id, stroke: stroke, mask: mask)
      if let cached = proximityPaths[key] { return cached }
      // Normalize to the painted area before growing its boundary. Raw compound
      // contours can cancel one another; their invisible edges are not targets.
      var painted = path.normalized(using: rule)
      // Growing unclipped geometry can resurrect a fully hidden shape just
      // beyond a mask edge. Grow only the area actually painted through every
      // ancestor clip; exact hits above already passed those clips at the point.
      if !mask { for clip in clips(for: element) { painted = painted.intersection(clip) } }
      proximityPaths[key] = painted
      return painted
    }

    private func includes(_ point: CGPoint, path: CGPath, rule: CGPathFillRule, tolerance: Double,
      proximity: () -> CGPath) -> Bool {
      guard !path.isEmpty,
        path.boundingBoxOfPath.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
      if path.contains(point, using: rule) { return true }
      guard tolerance > 0 else { return false }
      return proximity().copy(strokingWithWidth: tolerance * 2, lineCap: .round,
        lineJoin: .round, miterLimit: 10).contains(point)
    }

    func shapeContains(_ element: ArtworkElement, point: CGPoint, tolerance: Double, mask: Bool = false) -> Bool {
      guard worldTransform(element).inverse != nil else { return false }
      let hasFill = mask || element.kind == "image" || (element.kind != "line"
        && element.fillEnabled != false && (element.fillOpacity ?? 1) > 0
        && (element.kind == "text" || (element.gradient?.stops.contains { ($0.opacity ?? 1) > 0 } ?? true)))
      if hasFill {
        let path = worldPath(element), rule: CGPathFillRule = element.path?.evenOdd == true ? .evenOdd : .winding
        if includes(point, path: path, rule: rule, tolerance: tolerance,
          proximity: { self.proximityPath(path, for: element, rule: rule, mask: mask) }) { return true }
      }
      guard !mask, let stroke = element.visibleStroke, (stroke.opacity ?? 1) > 0 else { return false }
      let path: CGPath
      if let cached = strokePaths[element.id] { path = cached }
      else {
        guard let outline = try? StrokeGeometry.path(element) else { return false }
        var transform = worldTransform(element).cg
        path = outline.copy(using: &transform) ?? outline
        strokePaths[element.id] = path
      }
      return includes(point, path: path, rule: .winding, tolerance: tolerance,
        proximity: { self.proximityPath(path, for: element, rule: .winding, stroke: true) })
    }
  }
}

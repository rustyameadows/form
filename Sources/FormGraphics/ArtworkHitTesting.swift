import CoreGraphics
import FormCore
import Foundation

/// Picking uses painted geometry in artwork coordinates. Expanding that geometry
/// after its world transform keeps the pointer allowance constant on screen,
/// including inside scaled, rotated and sheared groups.
@MainActor public enum ArtworkHitTesting {
  public static func hit(
    at point: CGPoint, in artwork: Artwork, scope: UUID? = nil, tolerance: Double = 0,
    excluding: Set<UUID> = [], editingMask: UUID? = nil, renderedArtwork: Artwork? = nil,
    outerClip: CGPath? = nil, assets: URL? = nil
  ) -> ArtworkElement? {
    Picker(in: artwork, scope: scope, excluding: excluding, editingMask: editingMask,
      renderedArtwork: renderedArtwork, outerClip: outerClip, assets: assets).hit(at: point, tolerance: tolerance)
  }

  /// Front-to-back painted layers for a context-menu probe, including editable
  /// descendants beneath ordinary groups. Locked layers remain inspectable;
  /// masks, hidden content and derived component children are never returned.
  public static func layers(at point: CGPoint, in artwork: Artwork, tolerance: Double = 0,
    excluding: Set<UUID> = [], renderedArtwork: Artwork? = nil, outerClip: CGPath? = nil, assets: URL? = nil) -> [ArtworkElement] {
    guard point.x.isFinite, point.y.isFinite else { return [] }
    let context = Context(renderedArtwork ?? artwork, excluding: excluding, outerClip: outerClip, assets: assets)
    guard context.allows(point) else { return [] }
    let children = Dictionary(grouping: artwork.elements, by: \.parentID)
    var candidates: [ArtworkElement] = [], visited = Set<UUID>()
    func visit(_ element: ArtworkElement) {
      guard visited.insert(element.id).inserted else { return }
      if element.component == nil {
        for child in (children[element.id] ?? []).reversed() { visit(child) }
      }
      candidates.append(element)
    }
    for root in (children[nil] ?? []).reversed() { visit(root) }
    var result: [ArtworkElement] = [], found = Set<UUID>()
    for allowance in tolerance.isFinite && tolerance > 0 ? [0, tolerance] : [0] {
      for source in candidates where !found.contains(source.id) {
        let element = context.byID[source.id] ?? source
        guard context.ancestorsAllow(element, point: point),
          context.booleanAncestorsAllow(element, point: point, tolerance: allowance),
          context.contains(element, point: point, tolerance: allowance) else { continue }
        result.append(source); found.insert(source.id)
      }
    }
    return result
  }

  /// An immutable artwork snapshot with lazy geometry caches for continuous
  /// pointer hover. Replace it when artwork, isolation scope or visibility changes;
  /// zoom changes only require a different per-call tolerance.
  @MainActor public final class Picker {
    private let context: Context
    private let candidates: [ArtworkElement]
    private let editingMask: UUID?

    public init(in artwork: Artwork, scope: UUID? = nil, excluding: Set<UUID> = [],
      editingMask: UUID? = nil, renderedArtwork: Artwork? = nil, outerClip: CGPath? = nil, assets: URL? = nil) {
      let editingIDs=editingMask.map{artwork.editableMaskElementIDs(rootID:$0)}
      let context = Context(renderedArtwork ?? artwork, excluding: excluding, outerClip: outerClip, assets: assets,
        editingMask:editingMask,editingIDs:editingIDs ?? [])
      self.context = context
      self.editingMask = editingMask
      candidates = artwork.elements.reversed().filter { element in
        guard element.parentID == scope, !excluding.contains(element.id) else { return false }
        if let editingIDs { return editingIDs.contains(element.id) }
        return artwork.editable(element) && !context.masks.contains(element.id)
      }
    }

    public func hit(at point: CGPoint, tolerance: Double = 0) -> ArtworkElement? {
      guard point.x.isFinite, point.y.isFinite, context.allows(point) else { return nil }
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
    let outerClip: CGPath?
    private let editingMask:UUID?
    private let editingIDs:Set<UUID>
    private let assets: URL
    private lazy var renderTree: ArtworkRenderTree? = {
      guard let resolved = try? BooleanGeometry.materialized(artwork) else { return nil }
      return ArtworkRenderTree(resolved, assets: assets, production: false, excluding: [])
    }()
    private struct CoverageKey: Hashable { var id: UUID; var mode: String }
    private var maskCoverages: [CoverageKey: ArtworkMaskRenderer.Coverage] = [:]
    private var failedCoverages = Set<CoverageKey>()
    private var transforms: [UUID: Affine2] = [:]
    private var fillPaths: [UUID: CGPath] = [:]
    private var strokePaths: [UUID: CGPath] = [:]
    private var stackedPaths: [UUID: CGPath] = [:]
    private var clipPaths: [UUID: CGPath] = [:]
    private var booleanProxies: [UUID: ArtworkElement] = [:]
    private var invalidBooleans = Set<UUID>()
    private struct PaintKey: Hashable { var id: UUID; var stroke: Bool; var mask: Bool }
    private var proximityPaths: [PaintKey: CGPath] = [:]

    init(_ artwork: Artwork, excluding: Set<UUID>, outerClip: CGPath?, assets: URL?,editingMask:UUID?=nil,editingIDs:Set<UUID>=[]) {
      self.assets = assets ?? URL(fileURLWithPath: "/__lab_no_mask_assets__", isDirectory: true)
      self.artwork = artwork
      self.excluding = excluding
      self.editingMask=editingMask;self.editingIDs=editingIDs
      self.outerClip = outerClip?.normalized(using: .winding)
      byID = Dictionary(uniqueKeysWithValues: artwork.elements.map { ($0.id, $0) })
      children = Dictionary(grouping: artwork.elements, by: \.parentID)
      masks = Set(artwork.elements.compactMap(\.clipID))
    }

    func allows(_ point: CGPoint) -> Bool { outerClip?.contains(point) ?? true }

    private func visible(_ element: ArtworkElement) -> Bool {
      if editingIDs.contains(element.id) {return !excluding.contains(element.id) && (element.id==editingMask || element.hidden != true)}
      return element.hidden != true && (element.opacity ?? 1) > 0
        && !excluding.contains(element.id) && !masks.contains(element.id)
    }

    private func clipAllows(_ element: ArtworkElement, point: CGPoint) -> Bool {
      guard let id = element.clipID, let mask = byID[id] else { return true }
      guard ArtworkMasks.isCoverage(element.clipMode), let mode = element.clipMode else {
        return worldPath(mask).contains(point, using: mask.path?.evenOdd == true ? .evenOdd : .winding)
      }
      let parent = mask.parentID.flatMap { byID[$0] }.map(worldTransform) ?? .init()
      guard let inverse = parent.inverse else { return false }
      let key = CoverageKey(id: id, mode: mode)
      let coverage: ArtworkMaskRenderer.Coverage
      if let cached = maskCoverages[key] { coverage = cached }
      else {
        guard !failedCoverages.contains(key), let tree = renderTree, let resolvedMask = tree.byID[id],
          let built = tree.maskCoverage(resolvedMask, mode: mode, density: max(1, 4 * AppearanceRenderer.scale(parent.cg))) else {
          failedCoverages.insert(key); return false
        }
        maskCoverages[key] = built; coverage = built
      }
      return coverage.sample(atParentPoint: point.applying(inverse.cg)) > 0
    }

    func ancestorsAllow(_ element: ArtworkElement, point: CGPoint) -> Bool {
      var parent = element.parentID, seen = Set<UUID>()
      while let id = parent, let ancestor = byID[id], seen.insert(id).inserted {
        guard visible(ancestor), clipAllows(ancestor, point: point) else { return false }
        parent = ancestor.parentID
      }
      return true
    }

    func booleanAncestorsAllow(_ element: ArtworkElement, point: CGPoint, tolerance: Double) -> Bool {
      var parent = element.parentID, seen = Set<UUID>()
      while let id = parent, let ancestor = byID[id], seen.insert(id).inserted {
        if ancestor.booleanOperation != nil, !contains(ancestor, point: point, tolerance: tolerance) { return false }
        parent = ancestor.parentID
      }
      return true
    }

    func contains(_ element: ArtworkElement, point: CGPoint, tolerance: Double, depth: Int = 0) -> Bool {
      guard depth <= 64, visible(element), clipAllows(element, point: point) else { return false }
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
      return shapeContains(element, point: point, tolerance: tolerance,mask:editingIDs.contains(element.id))
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
        if !ArtworkMasks.isCoverage(item.clipMode), let id = item.clipID, let mask = byID[id] {
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
      // The physical surface is an outer display clip, rather than a source
      // mask. Intersect before growing so removed stock or another panel's
      // hidden artwork cannot become a nearby pointer target.
      if let outerClip { painted = painted.intersection(outerClip) }
      // Growing unclipped geometry can resurrect a fully hidden shape just
      // beyond a mask edge. Grow only the area actually painted through every
      // ancestor clip; exact hits above already passed those clips at the point.
      if !mask { for clip in clips(for: element) { painted = painted.intersection(clip) } }
      proximityPaths[key] = painted
      return painted
    }

    private func coverageClips(for element: ArtworkElement) -> [ArtworkElement] {
      var result: [ArtworkElement] = [], current: ArtworkElement? = element, seen = Set<UUID>()
      while let item = current, seen.insert(item.id).inserted {
        if item.clipID != nil, ArtworkMasks.isCoverage(item.clipMode) { result.append(item) }
        current = item.parentID.flatMap { byID[$0] }
      }
      return result
    }

    private func includes(_ point: CGPoint, path: CGPath, rule: CGPathFillRule, tolerance: Double,
      element: ArtworkElement? = nil, proximity: () -> CGPath) -> Bool {
      guard !path.isEmpty,
        path.boundingBoxOfPath.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
      if path.contains(point, using: rule) { return true }
      guard tolerance > 0 else { return false }
      let painted = proximity()
      guard painted.copy(strokingWithWidth: tolerance * 2, lineCap: .round,
        lineJoin: .round, miterLimit: 10).contains(point) else { return false }
      let coverage = element.map(coverageClips) ?? []
      guard !coverage.isEmpty else { return true }
      // A nearby edge is selectable only when that nearby ink survives all
      // soft masks. Growing an unmasked path would resurrect invisible shapes.
      for ring in 1...3 { for index in 0..<24 {
        let angle = Double(index) * 2 * Double.pi / 24, radius = tolerance * Double(ring) / 3
        let candidate = CGPoint(x: point.x + cos(angle) * radius, y: point.y + sin(angle) * radius)
        if painted.contains(candidate), coverage.allSatisfy({ clipAllows($0, point: candidate) }) { return true }
      } }
      return false
    }

    private func stackedPath(_ element: ArtworkElement) -> CGPath {
      if let cached = stackedPaths[element.id] { return cached }
      func visiblePaint(_ paint: ArtworkPaint) -> Bool {
        paint.opacity > 0 && (paint.kind != "gradient" || paint.gradient?.stops.contains { ($0.opacity ?? 1) > 0 } == true)
      }
      var local: CGPath = CGMutablePath()
      func include(_ path: CGPath, paint: ArtworkPaint, rule: CGPathFillRule = .winding) {
        guard visiblePaint(paint) else { return }
        var ink = path.normalized(using: rule)
        if paint.kind == "image", paint.imageRepeat != true {
          var imageMap = Affine2.scale(element.width, element.height).followed(by: paint.imageTransform ?? .init()).cg
          let imageBounds = CGPath(rect: .init(x: 0, y: 0, width: 1, height: 1), transform: &imageMap)
          ink = ink.intersection(imageBounds)
        }
        local = local.union(ink)
      }
      if element.kind == "text" {
        if let layers = try? TextPaintRenderer.vectorLayers(element) {
          for (path, paint) in layers { include(path, paint: paint) }
        } else if element.paintLayers.contains(where: { $0.enabled && $0.stroke == nil && visiblePaint($0.paint) }) {
          // Bitmap-only fonts retain their established text-frame hit surface.
          local = VectorGeometry.path(element)
        }
      } else {
        let fill = VectorGeometry.path(element)
        for layer in element.paintStack ?? [] where layer.enabled && visiblePaint(layer.effectivePaint) {
          if let stroke = layer.stroke {
            guard stroke.enabled != false, stroke.width > 0 else { continue }
            var proxy = element; proxy.paintStack = nil; proxy.stroke = stroke
            if let outline = try? VectorGeometry.expandedStroke(proxy) { include(outline, paint: layer.effectivePaint) }
          } else if element.kind != "line" { include(fill, paint: layer.effectivePaint, rule: element.path?.evenOdd == true ? .evenOdd : .winding) }
        }
      }
      var map = worldTransform(element).cg
      let world = local.copy(using: &map) ?? local
      stackedPaths[element.id] = world; return world
    }
    func shapeContains(_ element: ArtworkElement, point: CGPoint, tolerance: Double, mask: Bool = false) -> Bool {
      guard worldTransform(element).inverse != nil else { return false }
      if !mask, element.paintStack != nil || element.textRuns?.contains(where: { $0.paintStack != nil }) == true {
        let path = stackedPath(element)
        return includes(point, path: path, rule: .winding, tolerance: tolerance, element: element,
          proximity: { self.proximityPath(path, for: element, rule: .winding) })
      }
      let hasFill = mask || element.kind == "image" || (element.kind != "line"
        && element.fillEnabled != false && (element.fillOpacity ?? 1) > 0
        && (element.kind == "text" || (element.gradient?.stops.contains { ($0.opacity ?? 1) > 0 } ?? true)))
      if hasFill {
        let path = worldPath(element), rule: CGPathFillRule = element.path?.evenOdd == true ? .evenOdd : .winding
        if includes(point, path: path, rule: rule, tolerance: tolerance, element: mask ? nil : element,
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
      return includes(point, path: path, rule: .winding, tolerance: tolerance, element: element,
        proximity: { self.proximityPath(path, for: element, rule: .winding, stroke: true) })
    }
  }
}

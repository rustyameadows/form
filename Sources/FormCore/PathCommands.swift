import Foundation

/// Deterministic Bézier editing in path coordinates. Numeric transforms are in
/// physical artwork coordinates, including every ancestor transform.
public enum PathCommands {
  @discardableResult public static func refreshNodeIDs(in element: inout ArtworkElement)->[UUID:UUID] {
    guard var path=element.path else{return [:]}
    var mapping:[UUID:UUID]=[:]
    for c in path.contours.indices {
      if path.contours[c].id != nil {path.contours[c].id=UUID()}
      for n in path.contours[c].nodes.indices {
        let old=path.contours[c].nodes[n].id,new=UUID();mapping[old]=new;path.contours[c].nodes[n].id=new
      }
    }
    element.path=path
    if var piece=element.sewingPiece {
      piece.onFoldEdgeID=piece.onFoldEdgeID.flatMap{mapping[$0] ?? $0}
      piece.onFoldEndID=piece.onFoldEndID.flatMap{mapping[$0] ?? $0}
      for i in piece.notches.indices {
        piece.notches[i].edgeID=piece.notches[i].edgeID.flatMap{mapping[$0] ?? $0}
        piece.notches[i].endID=piece.notches[i].endID.flatMap{mapping[$0] ?? $0}
      };element.sewingPiece=piece
    }
    return mapping
  }
  public static let names = [
    "insert", "delete", "split", "join", "reverse", "open", "close", "corner", "smooth",
    "symmetric", "transform", "combine", "release",
  ]
  @discardableResult public static func apply(
    _ command: String, to element: inout ArtworkElement, nodes ids: Set<UUID>,
    arguments: [String: Any] = [:], world: Affine2
  ) throws -> Set<UUID> {
    guard var path = element.path, element.kind == "path" else {
      throw FormError.invalid("Select an editable vector path.")
    }
    let all = Set(path.contours.flatMap(\.nodes).map(\.id))
    guard ids.isSubset(of: all) else { throw FormError.invalid("Unknown path node ID.") }
    var selection = ids
    func location(_ id: UUID) -> (Int, Int)? {
      for c in path.contours.indices {
        if let n = path.contours[c].nodes.firstIndex(where: { $0.id == id }) { return (c, n) }
      }
      return nil
    }
    switch command {
    case "insert":
      guard ids.count == 1, let (c, i) = location(ids.first!) else {
        throw FormError.invalid("Select the node preceding the segment to subdivide.")
      }
      let t = arguments["t"] as? Double ?? 0.5
      guard t.isFinite, t > 0, t < 1,
        path.contours[c].closed || i < path.contours[c].nodes.count - 1
      else {
        throw FormError.invalid("Choose a segment and a subdivision fraction between 0 and 1.")
      }
      let j = (i + 1) % path.contours[c].nodes.count
      let a = path.contours[c].nodes[i]
      let b = path.contours[c].nodes[j]
      var node: BezierNode
      if a.outgoing == nil && b.incoming == nil {
        node = .init(lerp(a.anchor, b.anchor, t))
      } else {
        let p = lerp(a.anchor, a.outgoing ?? a.anchor, t)
        let q = lerp(a.outgoing ?? a.anchor, b.incoming ?? b.anchor, t)
        let r = lerp(b.incoming ?? b.anchor, b.anchor, t)
        let s = lerp(p, q, t)
        let u = lerp(q, r, t)
        path.contours[c].nodes[i].outgoing = p
        path.contours[c].nodes[j].incoming = r
        node = .init(lerp(s, u, t), incoming: s, outgoing: u)
        node.mode = "smooth"
      }
      path.contours[c].nodes.insert(node, at: i + 1)
      selection = [node.id]
    case "delete":
      guard !ids.isEmpty else { throw FormError.invalid("Select nodes to delete.") }
      for c in path.contours.indices { path.contours[c].nodes.removeAll { ids.contains($0.id) } }
      path.contours.removeAll { $0.nodes.count < 2 }
      selection = []
    case "reverse", "open", "close":
      for c in path.contours.indices
      where ids.isEmpty || path.contours[c].nodes.contains(where: { ids.contains($0.id) }) {
        if command == "reverse" {
          path.contours[c] = reversed(path.contours[c])
        } else {
          path.contours[c].closed = command == "close"
        }
      }
    case "split":
      guard ids.count == 1, let (c, i) = location(ids.first!) else {
        throw FormError.invalid("Select one interior node or a node on a closed contour.")
      }
      let contour = path.contours[c]
      var copy = contour.nodes[i]
      copy.id = UUID()
      if contour.closed {
        var nodes = Array(contour.nodes[i...]) + Array(contour.nodes[..<i]) + [copy]
        nodes[0].incoming = nil
        nodes[nodes.count - 1].outgoing = nil
        path.contours[c] = .init(nodes, closed: false)
      } else {
        guard i > 0 && i < contour.nodes.count - 1 else {
          throw FormError.invalid("An open contour must be split at an interior node.")
        }
        var left = Array(contour.nodes[...i])
        var right = Array(contour.nodes[i...])
        left[left.count - 1].outgoing = nil
        right[0] = copy
        right[0].incoming = nil
        path.contours[c] = .init(left, closed: false)
        path.contours.insert(.init(right, closed: false), at: c + 1)
      }
      selection = [contour.nodes[i].id, copy.id]
    case "join":
      let ordered = path.contours.flatMap(\.nodes).filter { ids.contains($0.id) }
      guard ordered.count == 2, let (c1, i1) = location(ordered[0].id),
        let (c2, i2) = location(ordered[1].id),
        !path.contours[c1].closed, !path.contours[c2].closed,
        [0, path.contours[c1].nodes.count - 1].contains(i1),
        [0, path.contours[c2].nodes.count - 1].contains(i2)
      else { throw FormError.invalid("Select two open endpoints to join.") }
      if c1 == c2 {
        guard i1 != i2 else { throw FormError.invalid("Choose distinct endpoints.") }
        var nodes = path.contours[c1].nodes
        if distance(nodes[0].anchor, nodes[nodes.count - 1].anchor) < 1e-9 {
          nodes[0].incoming = nodes[nodes.count - 1].incoming
          selection = [nodes[0].id]
          nodes.removeLast()
        }
        path.contours[c1] = .init(nodes, closed: true)
      } else {
        let first = i1 == 0 ? reversed(path.contours[c1]) : path.contours[c1]
        let second = i2 == 0 ? path.contours[c2] : reversed(path.contours[c2])
        var joined = first.nodes
        if distance(joined.last!.anchor, second.nodes[0].anchor) < 1e-9 {
          joined[joined.count - 1].outgoing = second.nodes[0].outgoing
          selection = [joined.last!.id]
          joined += second.nodes.dropFirst()
        } else {
          joined += second.nodes
        }
        path.contours[c1] = .init(joined, closed: false)
        path.contours.remove(at: c2)
      }
    case "corner", "smooth", "symmetric":
      guard !ids.isEmpty else { throw FormError.invalid("Select path nodes first.") }
      for c in path.contours.indices {
        let nodes = path.contours[c].nodes
        for i in nodes.indices where ids.contains(nodes[i].id) {
          var node = nodes[i]
          node.mode = command
          if command == "corner" {
            node.incoming = nil
            node.outgoing = nil
          } else {
            let before =
              i > 0
              ? nodes[i - 1].anchor : path.contours[c].closed ? nodes.last!.anchor : node.anchor
            let after =
              i + 1 < nodes.count
              ? nodes[i + 1].anchor : path.contours[c].closed ? nodes[0].anchor : node.anchor
            let dx = (after.x - before.x) / 6
            let dy = (after.y - before.y) / 6
            node.incoming = .init(node.anchor.x - dx, node.anchor.y - dy)
            node.outgoing = .init(node.anchor.x + dx, node.anchor.y + dy)
          }
          path.contours[c].nodes[i] = node
        }
      }
    case "transform":
      guard !ids.isEmpty, let raw = arguments["matrix"] as? [String: Double] else {
        throw FormError.invalid("Provide selected nodes and an artwork-space affine matrix.")
      }
      guard raw.values.allSatisfy({ $0.isFinite && abs($0) <= 100000 }) else {
        throw FormError.invalid("Node transforms must be finite and within physical limits.")
      }
      let delta = Affine2(
        a: raw["a"] ?? 1, b: raw["b"] ?? 0, c: raw["c"] ?? 0,
        d: raw["d"] ?? 1, tx: raw["tx"] ?? 0, ty: raw["ty"] ?? 0)
      let map = world.followed(by: .scale(element.width / path.width, element.height / path.height))
      guard let inverse = map.inverse else {
        throw FormError.invalid("The path transform is singular.")
      }
      let transform = inverse.followed(by: delta).followed(by: map)
      for c in path.contours.indices {
        for i in path.contours[c].nodes.indices where ids.contains(path.contours[c].nodes[i].id) {
          path.contours[c].nodes[i] = transformed(path.contours[c].nodes[i], by: transform)
        }
      }
    default: throw FormError.invalid("Unknown path operation.")
    }
    element.path = path
    normalize(&element)
    return selection
  }

  public static func transformed(_ node: BezierNode, by t: Affine2) -> BezierNode {
    var result = node
    result.anchor = t.apply(node.anchor)
    result.incoming = node.incoming.map(t.apply)
    result.outgoing = node.outgoing.map(t.apply)
    return result
  }
  public static func nearestSegment(_ path: VectorPath, to point: Point2, map: Affine2)
    -> (nodeID: UUID, t: Double, distance: Double)?
  {
    var best: (UUID, Double, Double)?
    for contour in path.contours where contour.nodes.count >= 2 {
      let count = contour.closed ? contour.nodes.count : contour.nodes.count - 1
      for i in 0..<count {
        let a = contour.nodes[i]
        let b = contour.nodes[(i + 1) % contour.nodes.count]
        let p = map.apply(a.anchor)
        let q = map.apply(a.outgoing ?? a.anchor)
        let r = map.apply(b.incoming ?? b.anchor)
        let s = map.apply(b.anchor)
        func at(_ t: Double) -> Point2 {
          let u = 1 - t
          return .init(
            u * u * u * p.x + 3 * u * u * t * q.x + 3 * u * t * t * r.x + t * t * t * s.x,
            u * u * u * p.y + 3 * u * u * t * q.y + 3 * u * t * t * r.y + t * t * t * s.y)
        }
        var t = 0.0
        var distance = Double.infinity
        for n in 0...32 {
          let f = Double(n) / 32
          let d = self.distance(at(f), point)
          if d < distance {
            t = f
            distance = d
          }
        }
        for _ in 0..<8 {
          let u = 1 - t
          let value = at(t)
          let dx = 3 * (u * u * (q.x - p.x) + 2 * u * t * (r.x - q.x) + t * t * (s.x - r.x))
          let dy = 3 * (u * u * (q.y - p.y) + 2 * u * t * (r.y - q.y) + t * t * (s.y - r.y))
          let ddx = 6 * (u * (r.x - 2 * q.x + p.x) + t * (s.x - 2 * r.x + q.x))
          let ddy = 6 * (u * (r.y - 2 * q.y + p.y) + t * (s.y - 2 * r.y + q.y))
          let denominator =
            dx * dx + dy * dy + (value.x - point.x) * ddx + (value.y - point.y) * ddy
          if abs(denominator) < 1e-12 { break }
          t = min(
            1, max(0, t - ((value.x - point.x) * dx + (value.y - point.y) * dy) / denominator))
        }
        distance = self.distance(at(t), point)
        if best == nil || distance < best!.2 { best = (a.id, t, distance) }
      }
    }
    return best.map { (nodeID: $0.0, t: $0.1, distance: $0.2) }
  }
  public static func movingHandle(
    _ node: BezierNode, incoming: Bool, to point: Point2,
    independent: Bool
  ) -> BezierNode {
    var result = node
    let opposite = incoming ? node.outgoing : node.incoming
    if incoming { result.incoming = point } else { result.outgoing = point }
    if independent {
      result.mode = "corner"
      return result
    }
    if node.effectiveMode != "corner" {
      let dx = point.x - node.anchor.x
      let dy = point.y - node.anchor.y
      let length = hypot(dx, dy)
      let otherLength =
        node.effectiveMode == "symmetric"
        ? length : opposite.map { distance($0, node.anchor) } ?? length
      if length > 1e-12 {
        let other = Point2(
          node.anchor.x - dx * otherLength / length, node.anchor.y - dy * otherLength / length)
        if incoming { result.outgoing = other } else { result.incoming = other }
      }
    }
    return result
  }
  private static func reversed(_ contour: VectorContour) -> VectorContour {
    var result=VectorContour(contour.nodes.reversed().map { node in
      var n=node;n.incoming=node.outgoing;n.outgoing=node.incoming;return n
    },closed:contour.closed)
    result.id=contour.id;return result
  }
  private static func lerp(_ a: Point2, _ b: Point2, _ t: Double) -> Point2 {
    .init(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
  }
  private static func distance(_ a: Point2, _ b: Point2) -> Double { hypot(a.x - b.x, a.y - b.y) }

  /// Refit the editable viewport to exact cubic extrema while retaining the same
  /// parent-space geometry. This keeps object handles correct after node edits.
  public static func normalize(_ element: inout ArtworkElement, preservingPaint: Bool = false) {
    guard var path = element.path, !path.contours.isEmpty else { return }
    let oldTransform = element.localTransform
    let scale = Affine2.scale(element.width / path.width, element.height / path.height)
    for c in path.contours.indices {
      path.contours[c].nodes = path.contours[c].nodes.map { transformed($0, by: scale) }
    }
    let points = extrema(path)
    guard let first = points.first else { return }
    let box = points.dropFirst().reduce(Rect2(first.x, first.y, 0, 0)) {
      $0.union(.init($1.x, $1.y, 0, 0))
    }
    let shift = Affine2.translation(-box.x, -box.y)
    for c in path.contours.indices {
      path.contours[c].nodes = path.contours[c].nodes.map { transformed($0, by: shift) }
    }
    path.width = max(0.001, box.width)
    path.height = max(0.001, box.height)
    if preservingPaint, var gradient = element.gradient {
      gradient.start = .init(
        gradient.start.x * element.width / path.width,
        gradient.start.y * element.height / path.height)
      gradient.end = .init(
        gradient.end.x * element.width / path.width,
        gradient.end.y * element.height / path.height)
      gradient.transform = shift.followed(by: gradient.transform ?? .init())
      element.gradient = gradient
    }
    element.width = path.width
    element.height = path.height
    element.path = path
    element.affine = nil
    if let inverse = element.localTransform.inverse {
      element.affine = oldTransform.followed(by: .translation(box.x, box.y)).followed(by: inverse)
    }
  }
  private static func extrema(_ path: VectorPath) -> [Point2] {
    var points: [Point2] = []
    for contour in path.contours {
      points += contour.nodes.map(\.anchor)
      guard contour.nodes.count >= 2 else { continue }
      let count = contour.closed ? contour.nodes.count : contour.nodes.count - 1
      for i in 0..<count {
        let a = contour.nodes[i]
        let b = contour.nodes[(i + 1) % contour.nodes.count]
        let p = a.anchor
        let q = a.outgoing ?? p
        let s = b.anchor
        let r = b.incoming ?? s
        var times: [Double] = []
        for v in [[p.x, q.x, r.x, s.x], [p.y, q.y, r.y, s.y]] {
          let aa = -v[0] + 3 * v[1] - 3 * v[2] + v[3]
          let bb = 2 * (v[0] - 2 * v[1] + v[2])
          let cc = v[1] - v[0]
          if abs(aa) < 1e-12 {
            if abs(bb) > 1e-12 { times.append(-cc / bb) }
          } else {
            let d = bb * bb - 4 * aa * cc
            if d >= 0 { times += [(-bb + sqrt(d)) / (2 * aa), (-bb - sqrt(d)) / (2 * aa)] }
          }
        }
        for t in times where t > 0 && t < 1 {
          let u = 1 - t
          points.append(
            .init(
              u * u * u * p.x + 3 * u * u * t * q.x + 3 * u * t * t * r.x + t * t * t * s.x,
              u * u * u * p.y + 3 * u * u * t * q.y + 3 * u * t * t * r.y + t * t * t * s.y))
        }
      }
    }
    return points
  }
}

extension BezierNode {
  public var effectiveMode: String {
    if let mode { return mode }
    guard let a = incoming, let b = outgoing else { return "corner" }
    let ux = a.x - anchor.x
    let uy = a.y - anchor.y
    let vx = b.x - anchor.x
    let vy = b.y - anchor.y
    let u = hypot(ux, uy)
    let v = hypot(vx, vy)
    guard u * v > 1e-12, ux * vx + uy * vy < 0, abs(ux * vy - uy * vx) <= u * v * 1e-6 else {
      return "corner"
    }
    return abs(u - v) <= max(u, v) * 1e-6 ? "symmetric" : "smooth"
  }
}

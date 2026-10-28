import CoreGraphics
import FormCore
import Foundation

extension Affine2 {
  public var cg: CGAffineTransform { .init(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}
public enum VectorGeometry {
  public static func path(_ e: ArtworkElement) -> CGPath {
    let rect = CGRect(x: 0, y: 0, width: e.width, height: e.height)
    switch e.kind {
    case "ellipse": return CGPath(ellipseIn: rect, transform: nil)
    case "rectangle":
      return CGPath(
        roundedRect: rect, cornerWidth: min(e.cornerRadius ?? 0, e.width / 2, e.height / 2),
        cornerHeight: min(e.cornerRadius ?? 0, e.width / 2, e.height / 2), transform: nil)
    case "line":
      let p = CGMutablePath()
      p.move(to: .zero)
      p.addLine(to: .init(x: e.width, y: e.height))
      return p
    case "polygon", "star":
      let p = CGMutablePath()
      let star = e.kind == "star"
      let sides = e.sides ?? 5
      let count = star ? sides * 2 : sides
      for i in 0..<count {
        let angle = Double(i) * 2 * .pi / Double(count) - .pi / 2
        let radius = star && i % 2 == 1 ? e.starInset ?? 0.45 : 1
        let point = CGPoint(
          x: e.width / 2 + cos(angle) * e.width / 2 * radius,
          y: e.height / 2 + sin(angle) * e.height / 2 * radius)
        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
      }
      p.closeSubpath()
      return p
    case "path":
      guard let path = e.path else { return CGMutablePath() }
      let p = CGMutablePath()
      let sx = e.width / path.width
      let sy = e.height / path.height
      func point(_ v: Point2) -> CGPoint { .init(x: v.x * sx, y: v.y * sy) }
      for contour in path.contours {
        guard let first = contour.nodes.first else { continue }
        p.move(to: point(first.anchor))
        for i in 1..<contour.nodes.count {
          let previous = contour.nodes[i - 1]
          let next = contour.nodes[i]
          if previous.outgoing != nil || next.incoming != nil {
            p.addCurve(
              to: point(next.anchor), control1: point(previous.outgoing ?? previous.anchor),
              control2: point(next.incoming ?? next.anchor))
          } else {
            p.addLine(to: point(next.anchor))
          }
        }
        if contour.closed, let last = contour.nodes.last {
          if last.outgoing != nil || first.incoming != nil {
            p.addCurve(
              to: point(first.anchor), control1: point(last.outgoing ?? last.anchor),
              control2: point(first.incoming ?? first.anchor))
          }
          p.closeSubpath()
        }
      }
      return p
    default: return CGPath(rect: rect, transform: nil)
    }
  }
  public static func worldPath(_ e: ArtworkElement, in art: Artwork) -> CGPath {
    var transform = art.worldTransform(e).cg
    return path(e).copy(using: &transform) ?? path(e)
  }
  public static func element(
    from path: CGPath, color: String, name: String = "Path", parentID: UUID? = nil
  ) throws -> ArtworkElement {
    let bounds = path.boundingBoxOfPath
    guard !path.isEmpty, !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite else {
      throw FormError.invalid("The result has no vector geometry.")
    }
    var contours: [VectorContour] = []
    var nodes: [BezierNode] = []
    var closed = false
    func point(_ p: CGPoint) -> Point2 { .init(p.x - bounds.minX, p.y - bounds.minY) }
    func finish() {
      if !nodes.isEmpty { contours.append(.init(nodes, closed: closed)) }
      nodes = []
      closed = false
    }
    path.applyWithBlock { ptr in
      let e = ptr.pointee
      switch e.type {
      case .moveToPoint:
        finish()
        nodes = [.init(point(e.points[0]))]
      case .addLineToPoint: nodes.append(.init(point(e.points[0])))
      case .addQuadCurveToPoint:
        guard let last = nodes.last else { return }
        let control = point(e.points[0])
        let end = point(e.points[1])
        nodes[nodes.count - 1].outgoing = .init(
          last.anchor.x + (control.x - last.anchor.x) * 2 / 3,
          last.anchor.y + (control.y - last.anchor.y) * 2 / 3)
        nodes.append(
          .init(
            end,
            incoming: .init(
              end.x + (control.x - end.x) * 2 / 3, end.y + (control.y - end.y) * 2 / 3)))
      case .addCurveToPoint:
        if !nodes.isEmpty { nodes[nodes.count - 1].outgoing = point(e.points[0]) }
        nodes.append(.init(point(e.points[2]), incoming: point(e.points[1])))
      case .closeSubpath:
        if nodes.count > 1, let first = nodes.first, let last = nodes.last,
          abs(first.anchor.x - last.anchor.x) < 1e-8, abs(first.anchor.y - last.anchor.y) < 1e-8
        {
          nodes[0].incoming = last.incoming
          nodes.removeLast()
        }
        closed = true
        finish()
      @unknown default: break
      }
    }
    finish()
    var result = ArtworkElement(
      kind: "path", x: bounds.minX, y: bounds.minY, width: max(0.001, bounds.width),
      height: max(0.001, bounds.height), color: color)
    result.path = .init(width: result.width, height: result.height, contours: contours)
    result.name = name
    result.parentID = parentID
    return result
  }
  public static func cap(_ value: String?) -> CGLineCap {
    value == "round" ? .round : value == "square" ? .square : .butt
  }
  public static func join(_ value: String?) -> CGLineJoin {
    value == "round" ? .round : value == "bevel" ? .bevel : .miter
  }
  @MainActor public static func expandedStroke(_ e: ArtworkElement) throws -> CGPath {
    try StrokeGeometry.path(e)
  }
  public static func convertedShape(_ source: ArtworkElement) throws -> ArtworkElement {
    guard ["rectangle", "ellipse", "line", "polygon", "star"].contains(source.kind) else {
      throw FormError.invalid("Select a geometric shape to convert to a path.")
    }
    let geometry = try element(from: path(source), color: source.color)
    var path = geometry.path!
    for c in path.contours.indices {
      path.contours[c].nodes = path.contours[c].nodes.map {
        PathCommands.transformed($0, by: .translation(geometry.x, geometry.y))
      }
    }
    path.width = source.width
    path.height = source.height
    var result = source
    result.id = UUID()
    result.kind = "path"
    result.name = "\(source.title.prefix(470)) · path"
    result.path = path
    if source.kind == "line" {
      result.fillEnabled = false
      result.stroke = source.stroke ?? .init(color: source.color)
    }
    return result
  }
}

import CoreGraphics
import CryptoKit
import FormCore
import Foundation

/// One geometric stroke for preview, bounds, outlining and portable SVG.
@MainActor public enum StrokeGeometry {
  private struct Node: Encodable {
    var anchor: Point2
    var incoming: Point2?
    var outgoing: Point2?
  }
  private struct Contour: Encodable {
    var closed: Bool
    var nodes: [Node]
  }
  private struct Key: Encodable {
    var kind: String
    var width: Double
    var height: Double
    var pathSize: Point2?
    var contours: [Contour]?
    var evenOdd: Bool?
    var corner: Double?
    var sides: Int?
    var inset: Double?
    var strokeWidth: Double
    var alignment: String
    var cap: String
    var join: String
    var miter: Double
    var dash: [Double]?
    var phase: Double
  }
  private final class Entry {
    let path: CGPath
    init(_ path: CGPath) { self.path = path }
  }
  private static let cache: NSCache<NSString, Entry> = {
    let c = NSCache<NSString, Entry>()
    c.totalCostLimit = 32_000_000
    c.countLimit = 512
    return c
  }()
  private static var builds = 0, hits = 0
  private static var lastMS = 0.0, lastError = ""
  public static var diagnostics: [String: Any] {
    [
      "builds": builds, "cache_hits": hits, "last_build_ms": lastMS, "last_error": lastError,
      "cache_limit_bytes": 32_000_000, "maximum_dash_segments": 20_000,
    ]
  }
  private static func upperLength(_ path: CGPath) -> Double {
    var current = CGPoint.zero
    var start = CGPoint.zero
    var length = 0.0
    func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    path.applyWithBlock { pointer in
      let e = pointer.pointee
      switch e.type {
      case .moveToPoint:
        current = e.points[0]
        start = current
      case .addLineToPoint:
        length += distance(current, e.points[0])
        current = e.points[0]
      case .addQuadCurveToPoint:
        length += distance(current, e.points[0]) + distance(e.points[0], e.points[1])
        current = e.points[1]
      case .addCurveToPoint:
        length +=
          distance(current, e.points[0]) + distance(e.points[0], e.points[1])
          + distance(e.points[1], e.points[2])
        current = e.points[2]
      case .closeSubpath:
        length += distance(current, start)
        current = start
      @unknown default: break
      }
    }
    return length
  }
  public static func path(_ e: ArtworkElement) throws -> CGPath {
    guard let stroke = e.visibleStroke else {
      throw FormError.invalid("Enable a nonzero stroke before outlining it.")
    }
    let key = Key(
      kind: e.kind, width: e.paintSize.x, height: e.paintSize.y,
      pathSize: e.path.map { .init($0.width, $0.height) },
      contours: e.path?.contours.map {
        Contour(
          closed: $0.closed,
          nodes: $0.nodes.map {
            Node(anchor: $0.anchor, incoming: $0.incoming, outgoing: $0.outgoing)
          })
      },
      evenOdd: e.path?.evenOdd, corner: e.cornerRadius, sides: e.sides, inset: e.starInset,
      strokeWidth: stroke.width, alignment: stroke.alignment ?? "center", cap: stroke.cap ?? "butt",
      join: stroke.join ?? "miter", miter: stroke.miter ?? 10,
      dash: stroke.dash?.isEmpty == false ? stroke.dash : nil, phase: stroke.dashOffset ?? 0)
    let encoded = try JSONEncoder.form.encode(key)
    let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined() as NSString
    if let entry = cache.object(forKey: digest) {
      hits += 1
      lastError = ""
      return entry.path
    }
    let start = CFAbsoluteTimeGetCurrent()
    let shape = VectorGeometry.path(e)
    var centerline = shape
    if let dash = stroke.dash, !dash.isEmpty {
      let period = dash.reduce(0, +)
      guard period > 0, upperLength(shape) / period * ceil(Double(dash.count) / 2) <= 20_000 else {
        lastError =
          "This dash pattern would expand beyond 20,000 segments. Increase dash/gap lengths or reduce the path size."
        throw FormError.invalid(lastError)
      }
      centerline = shape.copy(
        dashingWithPhase: stroke.dashOffset ?? 0, lengths: dash.map { CGFloat($0) })
    }
    let alignment = stroke.alignment ?? "center"
    guard alignment == "center" || e.supportsAlignedStroke else {
      throw FormError.invalid("Inside/outside strokes require closed vector geometry.")
    }
    let outline = centerline.copy(
      strokingWithWidth: stroke.width * (alignment == "center" ? 1 : 2),
      lineCap: VectorGeometry.cap(stroke.cap), lineJoin: VectorGeometry.join(stroke.join),
      miterLimit: stroke.miter ?? 10)
    let result: CGPath
    if alignment == "center" {
      result = outline
    } else {
      let area = shape.normalized(using: e.path?.evenOdd == true ? .evenOdd : .winding)
      result = alignment == "inside" ? outline.intersection(area) : outline.subtracting(area)
    }
    var elements = 0
    result.applyWithBlock { _ in elements += 1 }
    cache.setObject(Entry(result), forKey: digest, cost: max(256, elements * 96))
    builds += 1
    lastMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
    lastError = ""
    return result
  }
}

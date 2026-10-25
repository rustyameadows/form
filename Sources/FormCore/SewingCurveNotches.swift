import Foundation

public struct SewingCutNotch: Equatable, Sendable {
  public var id: UUID
  public var edgeID: UUID?
  public var sourceDistanceMM: Double
  public var openingLengthMM: Double
  public var firstMouth: Point2
  public var secondMouth: Point2
  public var tip: Point2
}

extension SewingCurves {
  /// Opening width is physical arc distance along the generated cut boundary. Source position is
  /// physical arc fraction along the original cubic edge. These are distinct measurements.
  static func notchFootprint(
    _ notch: SewingNotch, edge: SewingBoundaryEdge, normal: Point2,
    allowance: Double, cutRing: [Point2]
  ) throws -> (polygon: [Point2], record: SewingCutNotch) {
    let source = edge.sample(fraction: notch.position)
    let nominal = Point2(
      source.point.x + normal.x * allowance, source.point.y + normal.y * allowance)
    var cumulative = [0.0]
    for i in cutRing.indices {
      cumulative.append(cumulative.last! + distance(cutRing[i], cutRing[(i + 1) % cutRing.count]))
    }
    let perimeter = cumulative.last!
    var closest = Double.infinity
    var centerArc = 0.0
    var center = nominal
    for i in cutRing.indices {
      let a = cutRing[i]
      let b = cutRing[(i + 1) % cutRing.count]
      let v = sub(b, a)
      let length = cumulative[i + 1] - cumulative[i]
      let t = max(
        0, min(1, ((nominal.x - a.x) * v.x + (nominal.y - a.y) * v.y) / max(1e-20, length * length))
      )
      let p = Point2(a.x + t * v.x, a.y + t * v.y)
      let d = distance(p, nominal)
      if d < closest {
        closest = d
        center = p
        centerArc = cumulative[i] + t * length
      }
    }
    guard closest <= 0.05, perimeter > notch.width + 2 else {
      throw FormError.invalid(
        "This source arc has no unique nearby allowance boundary for a notch. Move the notch away from the offset's merged/trimmed region."
      )
    }
    func sample(_ raw: Double) -> (point: Point2, tangent: Point2) {
      let arc = (raw.truncatingRemainder(dividingBy: perimeter) + perimeter).truncatingRemainder(
        dividingBy: perimeter)
      let i = max(
        0, min(cutRing.count - 1, cumulative.dropLast().lastIndex(where: { $0 <= arc }) ?? 0))
      let a = cutRing[i]
      let b = cutRing[(i + 1) % cutRing.count]
      let length = cumulative[i + 1] - cumulative[i]
      let t = (arc - cumulative[i]) / length
      return (
        .init(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t),
        .init((b.x - a.x) / length, (b.y - a.y) / length)
      )
    }
    let first = sample(centerArc - notch.width / 2)
    let second = sample(centerArc + notch.width / 2)
    let tip = Point2(center.x - normal.x * notch.depth, center.y - normal.y * notch.depth)
    let extensionLength = notch.width + notch.depth + 2
    let an = Point2(first.tangent.y, -first.tangent.x)
    let bn = Point2(second.tangent.y, -second.tangent.x)
    var polygon = [
      first.point, tip, second.point,
      .init(second.point.x + bn.x * extensionLength, second.point.y + bn.y * extensionLength),
      .init(first.point.x + an.x * extensionLength, first.point.y + an.y * extensionLength),
    ]
    // Reject tight corners instead of silently creating a narrower or multi-opening notch.
    for i in 0...16 {
      let p = sample(centerArc - notch.width / 2 + notch.width * Double(i) / 16).point
      let nearest = polygon.indices.map {
        segmentDistance(p, polygon[$0], polygon[($0 + 1) % polygon.count])
      }.min()!
      guard contains(p, ring: polygon) || nearest < 0.003 else {
        throw FormError.invalid(
          "This notch crosses a tight offset corner. Move it along the source arc or reduce its width."
        )
      }
    }
    if signedArea(polygon) < 0 { polygon.reverse() }
    return (
      polygon,
      .init(
        id: notch.id, edgeID: edge.id, sourceDistanceMM: source.distanceMM,
        openingLengthMM: notch.width, firstMouth: first.point, secondMouth: second.point, tip: tip)
    )
  }
}

import Foundation

public enum CameraFraming {
  /// Fractions of the viewport occupied by floating controls. The orbit pivot
  /// stays at the subject's center; fitting leaves room around that pivot.
  public struct Insets {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double = 0, right: Double = 0, bottom: Double = 0, left: Double = 0) {
      self.top = top
      self.right = right
      self.bottom = bottom
      self.left = left
    }
  }

  /// SceneKit's orthographic scale is the visible half-height in scene units.
  public static let orthographicFactor = 0.36
  public static func viewportExpansion(from source: Double?, to output: Double) -> Double {
    guard let source, source.isFinite, source > 0, output.isFinite, output > 0 else { return 1 }
    return max(1, source / output)
  }

  /// Fit world-space bounds against both viewport axes and the current view
  /// direction. Perspective depth is included so near corners cannot clip.
  public static func fitted(
    _ camera: CameraState, points: [Vector3], aspect: Double,
    fieldOfView: Double = 39, margin: Double = 1.2, insets: Insets = .init()
  ) -> CameraState {
    let points = points.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
    guard let first = points.first else { return camera }
    var low = first
    var high = first
    for point in points.dropFirst() {
      low = .init(min(low.x, point.x), min(low.y, point.y), min(low.z, point.z))
      high = .init(max(high.x, point.x), max(high.y, point.y), max(high.z, point.z))
    }
    var result = camera
    result.target = .init((low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2)
    let aspect = aspect.isFinite && aspect > 0 ? aspect : 1
    result.viewportAspect = aspect
    // Near-pole SceneKit look-at rotations lose a little precision in their float matrices.
    let padding = (margin.isFinite ? max(1, margin) : 1.2) * 1.002
    func clearance(_ first: Double, _ second: Double) -> Double {
      func safe(_ value: Double) -> Double { value.isFinite ? min(0.49, max(0, value)) : 0 }
      return 1 - 2 * max(safe(first), safe(second))
    }
    let horizontal = clearance(insets.left, insets.right)
    let vertical = clearance(insets.top, insets.bottom)
    let elevation = CameraNavigation.elevation(camera.elevation)
    let a = camera.azimuth
    let n = Vector3(cos(elevation) * sin(a), sin(elevation), cos(elevation) * cos(a))
    let right = Vector3(cos(a), 0, -sin(a))
    let up = Vector3(-sin(elevation) * sin(a), cos(elevation), -sin(elevation) * cos(a))
    let angle = fieldOfView.isFinite ? min(150, max(5, fieldOfView)) : 39
    let tangent = tan(angle * .pi / 360)
    var distance = CameraNavigation.minimumDistance
    for point in points {
      let d = Vector3(
        point.x - result.target.x, point.y - result.target.y, point.z - result.target.z)
      func dot(_ v: Vector3) -> Double { d.x * v.x + d.y * v.y + d.z * v.z }
      let x = abs(dot(right))
      let y = abs(dot(up))
      let depth = dot(n)
      distance = max(distance, depth + 0.1)
      let extent = max(y / vertical, x / (aspect * horizontal))
      if camera.projection == "orthographic" {
        distance = max(distance, padding * extent / orthographicFactor)
      } else {
        distance = max(distance, depth + padding * extent / tangent)
      }
    }
    result.distance = distance
    return result
  }
}

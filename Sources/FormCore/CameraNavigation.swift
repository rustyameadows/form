import Foundation
import simd

/// Drag deltas use AppKit's view coordinates: right and up are positive.
/// Orbit is about the camera's local axes, so dragging stays direct through either pole.
public enum CameraNavigation {
  public static let minimumDistance = 0.05
  public static let maximumDistance = 300.0
  public static func elevation(_ value: Double) -> Double {
    value.isFinite ? value.remainder(dividingBy: 2 * .pi) : 0
  }

  private static func rotation(_ camera: CameraState) -> simd_quatd {
    if let rotation = camera.orientation?.quaternion { return rotation }
    let azimuth = camera.azimuth.isFinite ? camera.azimuth.remainder(dividingBy: 2 * .pi) : 0
    return simd_quatd(angle: azimuth, axis: SIMD3(0, 1, 0))
      * simd_quatd(angle: -elevation(camera.elevation), axis: SIMD3(1, 0, 0))
  }

  public static func basis(_ camera: CameraState) -> CameraBasis {
    let rotation = rotation(camera)
    func vector(_ value: SIMD3<Double>) -> Vector3 {
      let result = rotation.act(value)
      return .init(result.x, result.y, result.z)
    }
    return CameraBasis(right: vector(SIMD3(1, 0, 0)), up: vector(SIMD3(0, 1, 0)),
      outward: vector(SIMD3(0, 0, 1)))
  }

  public static func orbited(
    _ camera: CameraState, dx: Double, dy: Double, viewportHeight: Double,
    preferences: CameraPreferences = CameraPreferences()
  ) -> CameraState {
    guard dx.isFinite, dy.isFinite, viewportHeight.isFinite else { return camera }
    guard dx != 0 || dy != 0 else { return camera }
    var result = camera
    let speed = Double.pi / max(240, viewportHeight)
      * preferences.effectiveOrbitSpeed * preferences.orbitSign
    // One rotation vector makes opposite diagonal drags exact inverses too.
    // Reduce the angle before quaternion construction to retain precision on large input.
    let magnitude = hypot(dx, dy)
    guard magnitude.isFinite else { return camera }
    let delta = simd_quatd(angle: (magnitude * speed).remainder(dividingBy: 2 * .pi),
      axis: SIMD3(-dy / magnitude, dx / magnitude, 0))
    let next = (rotation(camera) * delta).normalized
    result.orientation = CameraOrientation(next)
    // Retain direction metadata for older diagnostics; the quaternion owns orientation.
    let outward = next.act(SIMD3<Double>(0, 0, 1))
    result.azimuth = atan2(outward.x, outward.z)
    result.elevation = asin(min(1, max(-1, outward.y)))
    return result
  }

  public static func panned(
    _ camera: CameraState, dx: Double, dy: Double, viewportHeight: Double,
    fieldOfView: Double = 39
  ) -> CameraState {
    guard dx.isFinite, dy.isFinite, viewportHeight.isFinite, fieldOfView.isFinite else {
      return camera
    }
    var result = camera
    let halfHeight =
      camera.distance
      * (camera.projection == "orthographic"
        ? CameraFraming.orthographicFactor : tan(min(150, max(5, fieldOfView)) * .pi / 360))
    let scale = 2 * halfHeight / max(1, viewportHeight)
    let axes = basis(camera)
    let right = axes.right
    let up = axes.up
    result.target.x -= (dx * right.x + dy * up.x) * scale
    result.target.y -= (dx * right.y + dy * up.y) * scale
    result.target.z -= (dx * right.z + dy * up.z) * scale
    return result
  }

  /// Negative deltas zoom in. Mouse-wheel direction is resolved at the event boundary.
  public static func zoomed(_ camera: CameraState, delta: Double) -> CameraState {
    guard delta.isFinite else { return camera }
    var result = camera
    result.distance = min(
      maximumDistance,
      max(
        minimumDistance,
        camera.distance * exp(min(1000, max(-1000, delta)) * 0.008)))
    return result
  }
}

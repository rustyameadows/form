import Foundation
import simd

/// Drag deltas use AppKit's view coordinates: right and up are positive.
/// Constrained turntable: world-up yaw, screen-right pitch, and no camera roll.
public enum CameraNavigation {
  public static let minimumDistance = 0.05
  public static let maximumDistance = 300.0
  public static let minimumElevation = -Double.pi / 2
  public static let maximumElevation = Double.pi / 2
  public static func elevation(_ value: Double) -> Double {
    value.isFinite ? min(maximumElevation, max(minimumElevation, value)) : 0
  }

  private static func savedRotation(_ camera: CameraState) -> simd_quatd {
    if let rotation = camera.orientation?.quaternion { return rotation }
    let azimuth = camera.azimuth.isFinite ? camera.azimuth.remainder(dividingBy: 2 * .pi) : 0
    let pitch = camera.elevation.isFinite ? camera.elevation.remainder(dividingBy: 2 * .pi) : 0
    return simd_quatd(angle: azimuth, axis: SIMD3(0, 1, 0))
      * simd_quatd(angle: -pitch, axis: SIMD3(1, 0, 0))
  }

  private static func angles(_ camera: CameraState) -> (azimuth: Double, elevation: Double) {
    let outward = savedRotation(camera).act(SIMD3<Double>(0, 0, 1))
    let horizontal = hypot(outward.x, outward.z)
    // At an exact top/bottom view the look direction cannot define yaw. Retain
    // its saved yaw so a tiny drag does not choose an arbitrary new heading.
    let fallback = camera.azimuth.isFinite ? camera.azimuth.remainder(dividingBy: 2 * .pi) : 0
    return (horizontal > 1e-10 ? atan2(outward.x, outward.z) : fallback,
      atan2(outward.y, horizontal))
  }

  private static func rotation(azimuth: Double, elevation: Double) -> simd_quatd {
    simd_quatd(angle: azimuth, axis: SIMD3(0, 1, 0))
      * simd_quatd(angle: -elevation, axis: SIMD3(1, 0, 0))
  }

  public static func basis(_ camera: CameraState) -> CameraBasis {
    let view = angles(camera)
    // Read older free-orbit quaternions by preserving their look direction and
    // removing only roll. Rendering and framing therefore agree immediately.
    let rotation = rotation(azimuth: view.azimuth, elevation: view.elevation)
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
    let current = angles(camera)
    result.azimuth = (current.azimuth + dx * speed).remainder(dividingBy: 2 * .pi)
    // Top and bottom are actual endpoints. Horizontal rotation remains unlimited
    // there; reversing a vertical drag responds immediately without a dead zone.
    result.elevation = elevation(current.elevation + dy * speed)
    result.orientation = CameraOrientation(rotation(azimuth: result.azimuth, elevation: result.elevation))
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

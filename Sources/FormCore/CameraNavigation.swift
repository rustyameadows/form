import Foundation

/// Drag deltas use AppKit's view coordinates: right and up are positive.
/// Direction is explicit; the camera always keeps a stable, upright horizon.
public enum CameraNavigation {
  public static let minimumDistance = 0.05
  public static let maximumDistance = 300.0
  public static let elevationLimit = Double.pi / 2 - 0.001

  public static func elevation(_ value: Double) -> Double {
    min(elevationLimit, max(-elevationLimit, value))
  }

  public static func orbited(
    _ camera: CameraState, dx: Double, dy: Double, viewportHeight: Double,
    preferences: CameraPreferences = CameraPreferences()
  ) -> CameraState {
    guard dx.isFinite, dy.isFinite, viewportHeight.isFinite else { return camera }
    var result = camera
    let speed = Double.pi / max(240, viewportHeight)
      * preferences.effectiveOrbitSpeed * preferences.orbitSign
    result.azimuth = (camera.azimuth + dx * speed).remainder(dividingBy: 2 * .pi)
    result.elevation = elevation(camera.elevation + dy * speed)
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
    let a = camera.azimuth
    let e = elevation(camera.elevation)
    let right = Vector3(cos(a), 0, -sin(a))
    let up = Vector3(-sin(e) * sin(a), cos(e), -sin(e) * cos(a))
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

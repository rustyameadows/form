import FormCore
import SceneKit

public enum SceneCamera {
  /// Fixed world-up prevents the shorter look-at overload from accumulating roll.
  public static func position(_ node: SCNNode, using state: CameraState) {
    let e = CameraNavigation.elevation(state.elevation)
    let a = state.azimuth
    node.position = .init(
      state.target.x + state.distance * cos(e) * sin(a),
      state.target.y + state.distance * sin(e),
      state.target.z + state.distance * cos(e) * cos(a))
    node.look(
      at: .init(state.target.x, state.target.y, state.target.z),
      up: .init(0, 1, 0), localFront: .init(0, 0, -1))
  }
}

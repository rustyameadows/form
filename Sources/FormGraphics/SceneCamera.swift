import FormCore
import FormGeometry

public enum SceneCamera {
  /// The same local basis drives orbit, pan, framing, native rendering, and snapshots.
  public static func position(_ node: MeshNode, using state: CameraState) {
    let axes = CameraNavigation.basis(state)
    // Set the orthonormal frame directly. SceneKit's look-at convenience method
    // can choose an opposite up/right basis at a pole or antiparallel direction.
    node.transform = MeshMatrix4(
      m11: axes.right.x, m12: axes.right.y, m13: axes.right.z, m14: 0,
      m21: axes.up.x, m22: axes.up.y, m23: axes.up.z, m24: 0,
      m31: axes.outward.x, m32: axes.outward.y, m33: axes.outward.z, m34: 0,
      m41: state.target.x + state.distance * axes.outward.x,
      m42: state.target.y + state.distance * axes.outward.y,
      m43: state.target.z + state.distance * axes.outward.z, m44: 1)
  }
}

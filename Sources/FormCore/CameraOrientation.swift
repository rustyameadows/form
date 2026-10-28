import Foundation
import simd

/// Persistent camera rotation. Readers retain older free-orbit values; navigation
/// resolves their look direction to a level, constrained turntable frame.
public struct CameraOrientation: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var z: Double
  public var w: Double

  public init(x: Double, y: Double, z: Double, w: Double) {
    self.x = x; self.y = y; self.z = z; self.w = w
  }

  init(_ rotation: simd_quatd) {
    let q = rotation.normalized.vector
    self.init(x: q.x, y: q.y, z: q.z, w: q.w)
  }

  /// Scale before normalization so very large/small finite saved values remain safe.
  var quaternion: simd_quatd? {
    let values = SIMD4(x, y, z, w)
    guard x.isFinite, y.isFinite, z.isFinite, w.isFinite else { return nil }
    let scale = max(abs(x), abs(y), abs(z), abs(w))
    guard scale > 0 else { return nil }
    return simd_quatd(vector: simd_normalize(values / scale))
  }
}

public struct CameraBasis: Sendable {
  public let right: Vector3
  public let up: Vector3
  public let outward: Vector3
}

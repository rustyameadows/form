import FormCore
import simd

/// One object-space frame shared by vector and rendered projections. Bounding
/// sphere size is independent of the camera angle and matches the 3D preview.
struct ObjectViewFraming {
  static let diameterPadding = 2.4
  private(set) var low = SIMD3<Double>(repeating: .infinity)
  private(set) var high = SIMD3<Double>(repeating: -.infinity)

  mutating func include(_ point: SIMD3<Double>) throws {
    guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
      throw FormError.invalid("The object contains invalid view coordinates.")
    }
    low = simd_min(low, point); high = simd_max(high, point)
  }
  func bounds() throws -> (center: SIMD3<Double>, radius: Double) {
    guard low.x.isFinite, high.x.isFinite else { throw FormError.invalid("This object has no viewable surfaces.") }
    let center = low + (high - low) / 2, radius = simd_length(high - low) / 2
    guard radius.isFinite, radius > 1e-12 else { throw FormError.invalid("This object has no viewable extent.") }
    return (center, radius)
  }
}

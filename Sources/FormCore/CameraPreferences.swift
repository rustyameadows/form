import Foundation

/// Local navigation preferences, independent of the saved project composition.
public struct CameraPreferences: Codable, Equatable, Sendable {
  public enum OrbitDirection: String, Codable, CaseIterable, Sendable {
    case moveCamera, turnObject
  }
  public var orbitDirection: OrbitDirection = .moveCamera
  public var orbitSpeed = 0.75
  public var reverseScrollZoom = false

  public init() {}
  public var effectiveOrbitSpeed: Double {
    orbitSpeed.isFinite ? min(2, max(0.25, orbitSpeed)) : 0.75
  }
  public var orbitSign: Double { orbitDirection == .moveCamera ? 1 : -1 }
  public func scrollZoomDelta(_ delta: Double, precise: Bool) -> Double {
    -delta * (precise ? 0.35 : 1) * (reverseScrollZoom ? -1 : 1)
  }
}

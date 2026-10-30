import Foundation
import CoreGraphics

/// Pointer-driven auto-scroll in visual points. The caller supplies a viewport
/// and pointer in the same coordinates, then converts the resulting offset into
/// document coordinates. This keeps the feel independent of zoom and mm scale.
enum CanvasEdgeScrolling {
  static let margin: CGFloat = 32
  static let maximumSpeed: CGFloat = 720 // 12 visual points per 60 Hz tick, per axis.

  static func offset(pointer: CGPoint, viewport: CGRect, elapsed: TimeInterval) -> CGPoint {
    guard pointer.x.isFinite, pointer.y.isFinite,
      viewport.minX.isFinite, viewport.minY.isFinite,
      viewport.width.isFinite, viewport.height.isFinite,
      viewport.width > 0, viewport.height > 0,
      elapsed.isFinite, elapsed > 0 else { return .zero }

    // A delayed run-loop callback must not fling the canvas when the app resumes.
    let duration = min(elapsed, 0.05)
    func axis(_ point: CGFloat, minimum: CGFloat, length: CGFloat) -> CGFloat {
      let edge = min(margin, length / 2)
      let leading = max(0, min(1, (minimum + edge - point) / edge))
      let trailing = max(0, min(1, (point - (minimum + length - edge)) / edge))
      func ramp(_ value: CGFloat) -> CGFloat { value * value * (3 - 2 * value) }
      return (ramp(trailing) - ramp(leading)) * maximumSpeed * duration
    }
    return CGPoint(x: axis(pointer.x, minimum: viewport.minX, length: viewport.width),
      y: axis(pointer.y, minimum: viewport.minY, length: viewport.height))
  }
}

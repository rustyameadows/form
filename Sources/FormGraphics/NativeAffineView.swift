import AppKit
import FormCore

/// Native coordinates, rather than a layer-only transform: AppKit text selection,
/// insertion points, accessibility geometry, and input methods use the same map.
@MainActor public final class NativeAffineView: NSView {
  public override var isFlipped: Bool { true }
  private var applied: (Affine2, CGRect, Double, Double, Double, Double)?

  public func configure(frame: CGRect, transform t: Affine2) {
    guard t.inverse != nil else {
      isHidden = true
      return
    }
    isHidden = false
    if let (previous, previousFrame, u, sx, sy, v) = applied {
      if previous == t && previousFrame == frame { return }
      // Setting boundsRotation to zero does not undo an earlier reflection.
      // Undo the actual concatenated operations before applying the next map.
      rotate(byDegrees: -v)
      scaleUnitSquare(to: .init(width: 1 / sx, height: 1 / sy))
      rotate(byDegrees: -u)
      translateOrigin(to: .init(x: -previous.tx, y: -previous.ty))
    }
    self.frame = frame
    bounds = CGRect(origin: .zero, size: frame.size)
    // Signed two-dimensional SVD: T R S R. The second singular value carries
    // reflection, so arbitrary invertible affine maps need no hit-test workaround.
    let p = hypot(t.a + t.d, t.b - t.c)
    let q = hypot(t.a - t.d, t.b + t.c)
    let u = atan2(t.b - t.c, t.a + t.d)
    let v = atan2(t.b + t.c, t.a - t.d)
    translateOrigin(to: .init(x: t.tx, y: t.ty))
    let left = (u + v) * 90 / .pi
    let right = (u - v) * 90 / .pi
    let sx = (p + q) / 2
    let sy = (t.a * t.d - t.b * t.c) / sx
    rotate(byDegrees: left)
    scaleUnitSquare(to: .init(width: sx, height: sy))
    rotate(byDegrees: right)
    applied = (t, frame, left, sx, sy, right)
    needsDisplay = true
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let target = super.hitTest(point)
    return target === self ? nil : target
  }
}

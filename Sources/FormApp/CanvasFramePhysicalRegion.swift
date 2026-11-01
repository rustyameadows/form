import AppKit
import FormCore

extension CanvasFrame {
  /// Shared material region for pointer picking and Find. A full-net proof's
  /// rectangular canvas also contains empty space between its physical panels.
  @MainActor var physicalMaterialClip: CGPath? {
    guard let projection else { return nil }
    if !projection.isProof { return projection.clipPath.normalized(using: .evenOdd) }
    guard let net = paperNet ?? (try? PaperConstruction.definition(for: surfaceObject).net()) else { return CGMutablePath() }
    let m = projection.sourceToLocal
    var transform = CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty)
    return PaperOutput.clipPath(net).normalized(using: .evenOdd).copy(using: &transform) ?? CGMutablePath()
  }
}

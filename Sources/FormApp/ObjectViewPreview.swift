import AppKit
import FormCore
import FormGeometry
import LabRendering
import simd
import SwiftUI

/// The preview has its own camera and never changes the table object or its camera.
struct ObjectViewPreview: NSViewRepresentable {
  let object: ProductObject
  let project: Project
  let assets: URL
  let azimuth: Double
  let elevation: Double
  let onChange: (Double, Double) -> Void

  func makeNSView(context: Context) -> ObjectViewPreviewViewport {
    ObjectViewPreviewViewport(frame: .init(x: 0, y: 0, width: 240, height: 150))
  }
  func updateNSView(_ view: ObjectViewPreviewViewport, context: Context) {
    view.onChange = onChange
    view.install(object: object, project: project, assets: assets)
    view.setAngles(azimuth: azimuth, elevation: elevation)
  }
  static func dismantleNSView(_ view: ObjectViewPreviewViewport, coordinator: ()) {
    view.task?.cancel(); view.renderer?.reset()
  }
}

@MainActor final class ObjectViewPreviewViewport: NSView {
  var renderer: RealityKitSceneRenderer?
  var task: Task<Void, Never>?
  var onChange: ((Double, Double) -> Void)?
  private var sourceState: LinkedObjectViewRenderer.SourceState?
  private var sourceAssets: URL?
  private var center = SIMD3<Double>.zero
  private var radius = 1.0
  private var azimuth = 0.0, elevation = 0.0
  private var last: CGPoint?
  private var message: NSTextField?
  override var acceptsFirstResponder: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    do {
      let renderer = try RealityKitSceneRenderer(frame: bounds)
      self.renderer = renderer
      renderer.nativeView.frame = bounds
      renderer.nativeView.autoresizingMask = [.width, .height]
      renderer.nativeView.setAccessibilityLabel("Object view preview")
      addSubview(renderer.nativeView)
    } catch { showError("3D preview unavailable") }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
  private func showError(_ text: String) {
    message?.removeFromSuperview()
    let label = NSTextField(wrappingLabelWithString: text)
    label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 10)
    label.frame = bounds.insetBy(dx: 8, dy: 8); label.autoresizingMask = [.width, .height]
    addSubview(label); message = label
  }
  func install(object: ProductObject, project: Project, assets: URL) {
    let state = LinkedObjectViewRenderer.state(object, in: project)
    guard sourceState != state || sourceAssets != assets else { return }
    sourceState = state; sourceAssets = assets
    task?.cancel(); renderer?.reset(); message?.removeFromSuperview(); message = nil
    do {
      guard let renderer else { showError("3D preview unavailable"); return }
      // Use the same isolated geometry and appearance as the rendered view.
      let values = try ObjectViewRendering.renderables(object: object, project: project, assets: assets)
      var low = SIMD3<Double>(repeating: .infinity), high = SIMD3<Double>(repeating: -.infinity)
      for value in values where value.visible {
        let matrix = value.transform.matrixMM
        for p in value.mesh.positionsMM {
          let q = matrix * SIMD4(p, 1), point = SIMD3(q.x, q.y, q.z)
          low = simd_min(low, point); high = simd_max(high, point)
        }
      }
      guard low.x.isFinite, high.x.isFinite else { throw FormError.invalid("No 3D geometry to preview.") }
      center = (low + high) / 2; radius = max(0.001, simd_length(high - low) / 2)
      updateCamera()
      task = Task { [weak self] in
        do {
          for value in values where value.visible {
            try Task.checkCancellation(); try await renderer.upsertAsync(value)
          }
        } catch {
          if !Task.isCancelled && !(error is CancellationError) { self?.showError("3D preview unavailable: " + error.localizedDescription) }
        }
      }
    } catch { showError("3D preview unavailable: " + error.localizedDescription) }
  }
  func setAngles(azimuth: Double, elevation: Double) {
    guard last == nil else { return }
    self.azimuth = azimuth; self.elevation = elevation; updateCamera()
  }
  private func updateCamera() {
    guard let renderer, azimuth.isFinite, elevation.isFinite else { return }
    let a = azimuth * .pi / 180, e = elevation * .pi / 180
    let right = SIMD3<Double>(cos(a), 0, -sin(a))
    let up = SIMD3<Double>(-sin(a)*sin(e), cos(e), -cos(a)*sin(e))
    let outward = simd_cross(right, up), eye = center + outward * (radius * 3)
    let aspect = max(0.1, Double(bounds.width / max(1, bounds.height)))
    let span = radius * 2.4 * max(1, 1 / aspect)
    let camera = SceneCameraPayload(worldFromCameraMM: .init(SIMD4(right,0), SIMD4(up,0), SIMD4(outward,0), SIMD4(eye,1)),
      projection: .orthographic(verticalSpanMM: span), nearMM: max(0.000001, radius * 0.001), farMM: radius * 8 + 1)
    do { try renderer.setCamera(camera) } catch { toolTip = error.localizedDescription }
  }
  override func layout() { super.layout(); updateCamera() }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); last = convert(event.locationInWindow, from: nil) }
  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let previous = last else { last = point; return }
    azimuth += Double(point.x - previous.x) * 0.7
    elevation = min(90, max(-90, elevation + Double(point.y - previous.y) * 0.7))
    last = point; updateCamera()
  }
  override func mouseUp(with event: NSEvent) {
    guard last != nil else { return }
    last = nil; onChange?(azimuth, elevation)
  }
}

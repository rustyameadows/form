import AppKit
import SwiftUI

struct InspectorColorPanelContent: View {
  @ObservedObject var state: InspectorColorState
  let close: () -> Void
  let applePicker: () -> Void
  let heightChanged: (CGFloat) -> Void

  var body: some View {
    let revision = state.targetRevision
    VStack(spacing: 12) {
      HStack(spacing: 8) {
        Text(state.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        Spacer()
        Button { state.isPinned.toggle() } label: {
          Image(systemName: state.isPinned ? "pin.fill" : "pin").frame(width: 24, height: 24)
        }.help(state.isPinned ? "Unpin color panel" : "Keep color panel open")
          .accessibilityLabel("Keep color panel open")
          .accessibilityValue(state.isPinned ? "On" : "Off")
        AppCloseButton("Close color panel", action: close)
          .help("Close color panel · Escape").accessibilityLabel("Close color panel")
      }.buttonStyle(.plain)
      InspectorHueSaturationWheel(state: state).frame(width: 190, height: 190).disabled(!state.canEditRGB)
      HStack(spacing: InspectorStyle.rowSpacing) {
        numeric("Hue", value: state.hue * 360, suffix: "°", range: 0...360, revision: revision, caption: true) {
          state.setHueSaturation($0 / 360, state.saturation)
        }
        numeric("Saturation", value: state.saturation * 100, suffix: "%", range: 0...100, revision: revision, caption: true) {
          state.setHueSaturation(state.hue, $0 / 100)
        }
      }
      slider("Brightness", value: Binding(get: { state.brightness }, set: state.setBrightness), revision: revision)
      if state.supportsOpacity {
        slider("Opacity", value: Binding(get: { state.components.alpha }, set: state.setAlpha), revision: revision)
      }
      HStack(spacing: InspectorStyle.rowSpacing) {
        ForEach(0..<3) { channel in
          let value = [state.components.red, state.components.green, state.components.blue][channel]
          numeric(["Red", "Green", "Blue"][channel], value: value * 255, suffix: ["R", "G", "B"][channel],
            range: 0...255, revision: revision) { state.setChannel(channel, $0) }
        }
      }
      InspectorColorHexField(state: state, targetRevision: revision)
      if let issue = state.issue {
        Text(issue).font(InspectorStyle.captionFont).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.updatesFrequently)
      }
      Button(action: applePicker) {
        Label("Apple color picker…", systemImage: "slider.horizontal.3")
          .font(InspectorStyle.labelFont).frame(maxWidth: .infinity)
      }.buttonStyle(.plain).padding(.top, 2).accessibilityLabel("Open Apple color picker")
    }.padding(InspectorStyle.panelPadding).frame(width: 280).fixedSize(horizontal: false, vertical: true)
      .id(revision)
      .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: heightChanged)
  }

  private func numeric(_ title: String, value: Double, suffix: String, range: ClosedRange<Double>,
    revision: UUID, caption: Bool = false, set: @escaping (Double) -> Void) -> some View {
    InspectorColorNumberField(title: title, value: value, suffix: suffix, range: range,
      state: state, targetRevision: revision, caption: caption, set: set)
  }

  private func slider(_ title: String, value: Binding<Double>, revision: UUID) -> some View {
    HStack(spacing: 8) {
      Text(title).font(InspectorStyle.labelFont).frame(width: 65, alignment: .leading)
      InspectorSlider(value: Binding(get: { value.wrappedValue }, set: {
        if state.targetRevision == revision { value.wrappedValue = $0 }
      }), in: 0...1, onEditingChanged: {
        if state.targetRevision == revision { state.setEditing($0) }
      })
        .accessibilityLabel(title)
      Text(String(format: "%.1f%%", value.wrappedValue * 100)).font(InspectorStyle.valueFont)
        .monospacedDigit().frame(width: 48, alignment: .trailing)
    }.frame(height: InspectorStyle.controlHeight).disabled(!state.canEditRGB)
  }
}

private struct InspectorColorNumberField: View {
  let title: String
  let value: Double
  let suffix: String
  let range: ClosedRange<Double>
  @ObservedObject var state: InspectorColorState
  let targetRevision: UUID
  let caption: Bool
  let set: (Double) -> Void
  @State private var draft = ""
  @State private var original = ""
  @State private var invalid = false
  @FocusState private var focused: Bool
  private var current: Bool { state.targetRevision == targetRevision }
  private var formatted: String {
    let text = String(format: "%.2f", value)
      .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    return text == "-0" ? "0" : text
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if caption { Text(title).font(InspectorStyle.captionFont).foregroundStyle(.secondary).accessibilityHidden(true) }
      InspectorValueBox(suffix: suffix, invalid: invalid, focused: focused) {
        TextField(title, text: $draft).textFieldStyle(.plain).font(InspectorStyle.valueFont)
          .focused($focused).accessibilityLabel(title)
          .onSubmit { guard current else { return }; commit(); state.endEditing() }
          .onExitCommand { guard current else { return }; reset(); focused = false; state.endEditing() }
      }
    }.onAppear(perform: reset)
      .onChange(of: value) { _, _ in if !focused { reset() } }
      .disabled(!state.canEditRGB).onChange(of: focused) { _, now in
        guard current else { return }
        if now { state.beginEditing() }
        else { commit(); state.endEditing(); if !invalid { reset() } }
      }
  }
  private func reset() { draft = formatted; original = draft; invalid = false }
  private func commit() {
    // An untouched rounded display is a read, including when a source value
    // changes externally while this field retains focus.
    guard current else { return }
    guard draft != original else { invalid = false; return }
    guard let number = Double(draft), number.isFinite, range.contains(number) else { invalid = true; return }
    invalid = false
    set(number); original = draft
  }
}

private struct InspectorColorHexField: View {
  @ObservedObject var state: InspectorColorState
  let targetRevision: UUID
  @State private var draft = ""
  @State private var original = ""
  @State private var invalid = false
  @FocusState private var focused: Bool
  private var current: Bool { state.targetRevision == targetRevision }

  var body: some View {
    HStack(spacing: 8) {
      Text("Hex").font(InspectorStyle.labelFont).frame(width: 65, alignment: .leading)
      InspectorValueBox(suffix: "", invalid: invalid, focused: focused) {
        TextField("#RRGGBB", text: $draft).textFieldStyle(.plain).font(InspectorStyle.valueFont)
          .focused($focused).accessibilityLabel("Hex RGB color")
          .onSubmit { guard current else { return }; commit(); state.endEditing() }
          .onExitCommand { guard current else { return }; reset(); focused = false; state.endEditing() }
      }
    }.disabled(!state.canEditRGB).onAppear(perform: reset)
      .onChange(of: state.components) { _, _ in if !focused { reset() } }
      .onChange(of: focused) { _, now in
        guard current else { return }
        if now { state.beginEditing() }
        else { commit(); state.endEditing() }
      }
  }
  private func reset() { draft = state.components.hex; original = draft; invalid = false }
  private func commit() {
    guard current, draft != original else { return }
    invalid = !state.setHex(draft)
    if !invalid { original = draft }
  }
}

private struct InspectorHueSaturationWheel: NSViewRepresentable {
  @ObservedObject var state: InspectorColorState
  func makeNSView(context: Context) -> InspectorHueSaturationWheelView {
    InspectorHueSaturationWheelView(state: state)
  }
  func updateNSView(_ view: InspectorHueSaturationWheelView, context: Context) {
    view.state = state; view.needsDisplay = true
    view.setAccessibilityValue(String(format: "Hue %.1f degrees, saturation %.1f percent", state.hue * 360, state.saturation * 100))
  }
}

/// Native focus and pointer events keep drag editing bounded by down/up while
/// arrow keys and VoiceOver actions produce discrete, undoable changes.
final class InspectorHueSaturationWheelView: NSView {
  var state: InspectorColorState
  private var tracking = false
  private var trackingRevision: UUID?
  private static let wheelImage: NSImage? = {
    let size = 256, stride = size * 4
    var data = [UInt8](repeating: 0, count: size * stride)
    for y in 0..<size { for x in 0..<size {
      let dx = (Double(x) + 0.5 - 128) / 128, dy = (128 - Double(y) - 0.5) / 128
      let radius = hypot(dx, dy)
      guard radius <= 1 else { continue }
      let hue = atan2(dy, dx) / (2 * .pi)
      let rgb = InspectorColorComponents.hsv(hue, radius, 1, alpha: 1)
      let offset = y * stride + x * 4
      data[offset] = UInt8((rgb.red * 255).rounded()); data[offset + 1] = UInt8((rgb.green * 255).rounded())
      data[offset + 2] = UInt8((rgb.blue * 255).rounded()); data[offset + 3] = 255
    } }
    guard let provider = CGDataProvider(data: Data(data) as CFData),
      let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
    return NSImage(cgImage: image, size: .init(width: size, height: size))
  }()

  init(state: InspectorColorState) {
    self.state = state; super.init(frame: .zero)
    focusRingType = .exterior
    setAccessibilityElement(true); setAccessibilityRole(.slider)
    setAccessibilityLabel("Hue and saturation")
    setAccessibilityHelp("Left and right change hue. Up and down change saturation. Numeric fields provide exact values.")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
  override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
  private var wheelRect: NSRect {
    let length = max(1, min(bounds.width, bounds.height) - 8)
    return .init(x: bounds.midX - length / 2, y: bounds.midY - length / 2, width: length, height: length)
  }
  override func draw(_ dirtyRect: NSRect) {
    let rect = wheelRect
    Self.wheelImage?.draw(in: rect)
    NSColor.separatorColor.setStroke(); NSBezierPath(ovalIn: rect).stroke()
    let angle = state.hue * 2 * .pi
    let point = CGPoint(x: rect.midX + cos(angle) * state.saturation * rect.width / 2,
      y: rect.midY + sin(angle) * state.saturation * rect.height / 2)
    let marker = NSBezierPath(ovalIn: .init(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
    NSColor.black.withAlphaComponent(0.65).setStroke(); marker.lineWidth = 3; marker.stroke()
    NSColor.white.setStroke(); marker.lineWidth = 1.5; marker.stroke()
    if window?.firstResponder === self {
      NSColor.keyboardFocusIndicatorColor.setStroke()
      let focus = NSBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3)); focus.lineWidth = 2; focus.stroke()
    }
  }
  override func mouseDown(with event: NSEvent) {
    guard state.canEditRGB else { return }
    window?.makeFirstResponder(self); tracking = true; trackingRevision = state.targetRevision
    state.beginEditing(); choose(event)
  }
  override func mouseDragged(with event: NSEvent) {
    if tracking, trackingRevision == state.targetRevision { choose(event) }
  }
  override func mouseUp(with event: NSEvent) {
    guard tracking else { return }
    tracking = false
    guard trackingRevision == state.targetRevision else { trackingRevision = nil; return }
    choose(event); trackingRevision = nil; state.endEditing()
  }
  private func choose(_ event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil), rect = wheelRect
    let dx = (point.x - rect.midX) / (rect.width / 2), dy = (point.y - rect.midY) / (rect.height / 2)
    state.setHueSaturation(atan2(dy, dx) / (2 * .pi), min(1, hypot(dx, dy)))
    needsDisplay = true
  }
  override func keyDown(with event: NSEvent) {
    let step = event.modifierFlags.contains(.shift) ? 0.05 : 0.01
    switch event.keyCode {
    case 123: state.setHueSaturation(state.hue - step, state.saturation)
    case 124: state.setHueSaturation(state.hue + step, state.saturation)
    case 125: state.setHueSaturation(state.hue, state.saturation - step)
    case 126: state.setHueSaturation(state.hue, state.saturation + step)
    default: super.keyDown(with: event); return
    }
    needsDisplay = true
  }
  override func accessibilityPerformIncrement() -> Bool {
    state.setHueSaturation(state.hue + 0.01, state.saturation); needsDisplay = true; return true
  }
  override func accessibilityPerformDecrement() -> Bool {
    state.setHueSaturation(state.hue - 0.01, state.saturation); needsDisplay = true; return true
  }
}

import AppKit
import SwiftUI

/// Shared visual vocabulary. Authoring/parsing/transaction behavior stays with
/// the existing field and model coordinators that use these controls.
enum InspectorStyle {
  static let labelFont = Font.system(size: 11)
  static let valueFont = Font.system(size: 11, design: .monospaced)
  static let captionFont = Font.system(size: 10)
  static let headingFont = Font.system(size: 10, weight: .semibold)
  static let controlHeight: CGFloat = 28
  static let controlRadius: CGFloat = 8
  static let moduleRadius: CGFloat = 10
  static let rowSpacing: CGFloat = 8
  static let sectionSpacing: CGFloat = 18
  static let panelPadding: CGFloat = 16
  static let nativeValueFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
}
enum InspectorFieldLayout { case row,stacked }

struct InspectorSectionHeader: View {
  let title: String
  var subtitle: String?
  init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(InspectorStyle.headingFont).tracking(0.8).foregroundStyle(Palette.secondary)
      if let subtitle { Text(subtitle).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
struct InspectorSection<Content: View>: View {
  let title: String
  let content: Content
  init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
  var body: some View {
    VStack(alignment: .leading, spacing: InspectorStyle.rowSpacing + 2) {
      InspectorSectionHeader(title)
      content
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
struct InspectorDivider: View {
  var body: some View { Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 3).accessibilityHidden(true).allowsHitTesting(false) }
}
struct InspectorRow<Content: View>: View {
  let title: String
  let content: Content
  init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
  var body: some View {
    HStack(spacing: 5) {
      Text(title).font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)
      Spacer(minLength: 2)
      content
    }.frame(minHeight: InspectorStyle.controlHeight)
  }
}
struct InspectorValueBox<Content: View>: View {
  var suffix: String
  var invalid: Bool
  var focused: Bool
  let content: Content
  init(suffix: String = "", invalid: Bool = false, focused: Bool = false, @ViewBuilder content: () -> Content) {
    self.suffix = suffix; self.invalid = invalid; self.focused = focused; self.content = content()
  }
  var body: some View {
    HStack(spacing: 4) {
      content.font(InspectorStyle.valueFont).textFieldStyle(.plain)
      if !suffix.isEmpty { Text(suffix).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary).fixedSize() }
    }.padding(.horizontal, 7).frame(minHeight: InspectorStyle.controlHeight)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: InspectorStyle.controlRadius))
      .overlay {
        RoundedRectangle(cornerRadius: InspectorStyle.controlRadius)
          .strokeBorder(invalid ? Color.red.opacity(0.7) : focused ? Palette.accent.opacity(0.65) : Palette.line.opacity(0.7), lineWidth: focused || invalid ? 1.25 : 0.75)
          .allowsHitTesting(false)
      }
  }
}
struct InspectorTextFieldStyle: TextFieldStyle {
  var numeric = false
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration.textFieldStyle(.plain).font(numeric ? InspectorStyle.valueFont : InspectorStyle.labelFont)
      .padding(.horizontal, 9).frame(minHeight: InspectorStyle.controlHeight)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: InspectorStyle.controlRadius))
      .overlay { RoundedRectangle(cornerRadius: InspectorStyle.controlRadius).strokeBorder(Palette.line.opacity(0.7), lineWidth: 0.75).allowsHitTesting(false) }
  }
}
struct InspectorActionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 10, weight: .medium)).padding(.horizontal, 9).frame(minHeight: InspectorStyle.controlHeight)
      .background(configuration.isPressed ? Palette.line : Palette.surface, in: RoundedRectangle(cornerRadius: InspectorStyle.controlRadius))
      .foregroundStyle(Palette.ink)
  }
}
struct InspectorModule<Content: View>: View {
  let title: String
  var symbol: String?
  @Binding var isExpanded: Bool
  let content: Content
  init(_ title: String, symbol: String? = nil, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
    self.title = title; self.symbol = symbol; _isExpanded = isExpanded; self.content = content()
  }
  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: InspectorStyle.rowSpacing) { content }.padding(.top, 10)
    } label: {
      HStack(spacing: 7) {
        if let symbol { Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Palette.secondary) }
        Text(title).font(.system(size: 11, weight: .medium)).lineLimit(2)
      }
    }.tint(Palette.secondary).font(InspectorStyle.labelFont).padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: InspectorStyle.moduleRadius))
  }
}
struct InspectorPreviewTile<Content: View>: View {
  var height: CGFloat
  let content: Content
  init(height: CGFloat = 140, @ViewBuilder content: () -> Content) { self.height = height; self.content = content() }
  var body: some View {
    content.frame(maxWidth: .infinity).frame(height: height)
      .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: InspectorStyle.moduleRadius))
      .overlay { RoundedRectangle(cornerRadius: InspectorStyle.moduleRadius).strokeBorder(Palette.line.opacity(0.7), lineWidth: 0.75).allowsHitTesting(false) }
  }
}
extension View {
  func inspectorPicker() -> some View { pickerStyle(.menu).controlSize(.small).font(InspectorStyle.labelFont).tint(Palette.accent) }
  func inspectorToggle() -> some View { toggleStyle(.switch).controlSize(.mini).font(InspectorStyle.labelFont).tint(Palette.accent) }
  func inspectorSegmented() -> some View { pickerStyle(.segmented).controlSize(.small).font(InspectorStyle.labelFont).tint(Palette.accent) }
}

/// Real NSSlider semantics with house-drawn track, knob and optional ticks.
/// The native control still owns hit testing, pointer tracking and accessibility.
@MainActor final class InspectorSliderCell: NSSliderCell {
  override func drawBar(inside rect: NSRect, flipped: Bool) {
    let track = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
    NSColor(hex: "#DADDDD").withAlphaComponent(isEnabled ? 1 : 0.55).setFill()
    NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
    let span = maxValue - minValue
    let fraction = span > 0 ? min(1, max(0, (doubleValue - minValue) / span)) : 0
    let filled = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
    Palette.accentNS.withAlphaComponent(isEnabled ? 1 : 0.35).setFill()
    NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
  }
  override func drawKnob(_ knobRect: NSRect) {
    let rect = knobRect.insetBy(dx: 1, dy: 1)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
    shadow.shadowBlurRadius = 2; shadow.shadowOffset = .init(width: 0, height: -0.5); shadow.set()
    NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.65).setFill()
    NSBezierPath(ovalIn: rect).fill()
    NSGraphicsContext.restoreGraphicsState()
    (isHighlighted ? Palette.accentNS : NSColor(hex: "#AAB0AF")).setStroke()
    let outline = NSBezierPath(ovalIn: rect); outline.lineWidth = 0.75; outline.stroke()
  }
  override func drawTickMarks() {
    NSColor(hex: "#AAB0AF").withAlphaComponent(isEnabled ? 0.7 : 0.35).setFill()
    for index in 0..<numberOfTickMarks {
      let tick = rectOfTickMark(at: index)
      NSBezierPath(roundedRect: tick, xRadius: 0.75, yRadius: 0.75).fill()
    }
  }
}
@MainActor final class InspectorNativeSlider: NSSlider {
  // NSViewRepresentable's generic accessibility adapter can otherwise assign
  // AXUnknown to a slider with a custom cell. Keep its native value contract
  // explicit, including writable AX values through the same authoring action.
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .slider }
  override func accessibilityValue() -> Any? { NSNumber(value: doubleValue) }
  override func accessibilityMinValue() -> Any? { NSNumber(value: minValue) }
  override func accessibilityMaxValue() -> Any? { NSNumber(value: maxValue) }
  override func setAccessibilityValue(_ value: Any?) {
    guard isEnabled, let number = value as? NSNumber, number.doubleValue.isFinite else { return }
    let next = min(maxValue, max(minValue, number.doubleValue))
    guard next != doubleValue else { return }
    beginEditing(); defer { endEditing() }
    doubleValue = next
    _ = sendAction(action, to: target); needsDisplay = true
  }
  var editingChanged: ((Bool) -> Void)?
  var stepSize: Double?
  private(set) var editing = false
  func beginEditing() { guard !editing else { return }; editing = true; editingChanged?(true) }
  func endEditing() { guard editing else { return }; editing = false; editingChanged?(false) }
  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    beginEditing(); defer { endEditing() }
    super.mouseDown(with: event)
  }
  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    guard isEnabled, [UInt16(123),124,125,126].contains(event.keyCode), modifiers.isSubset(of: [.shift]) else { endEditing(); super.keyDown(with: event); return }
    beginEditing()
    adjust(event.keyCode == 124 || event.keyCode == 126 ? 1 : -1, multiplier: modifiers.contains(.shift) ? 10 : 1)
  }
  override func keyUp(with event: NSEvent) {
    if [UInt16(123),124,125,126].contains(event.keyCode) { endEditing(); return }
    super.keyUp(with: event)
  }
  override func resignFirstResponder() -> Bool { endEditing(); return super.resignFirstResponder() }
  private func adjust(_ direction: Double, multiplier: Double = 1) {
    let step = stepSize.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (maxValue - minValue) / 100
    guard step.isFinite, step > 0 else { return }
    doubleValue = min(maxValue, max(minValue, doubleValue + direction * step * multiplier))
    _ = sendAction(action, to: target); needsDisplay = true
  }
  override func accessibilityPerformIncrement() -> Bool {
    guard isEnabled else { return false }; beginEditing(); defer { endEditing() }; adjust(1); return true
  }
  override func accessibilityPerformDecrement() -> Bool {
    guard isEnabled else { return false }; beginEditing(); defer { endEditing() }; adjust(-1); return true
  }
}
struct InspectorSlider: NSViewRepresentable {
  @Binding var value: Double
  var range: ClosedRange<Double>
  var step: Double?
  var label: String?
  var tickCount: Int
  var onEditingChanged: (Bool) -> Void
  @Environment(\.isEnabled) private var enabled
  init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, step: Double? = nil, label: String? = nil, tickCount: Int = 0, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
    _value = value; self.range = range; self.step = step; self.label = label; self.tickCount = tickCount; self.onEditingChanged = onEditingChanged
  }
  @MainActor final class Coordinator: NSObject {
    var parent: InspectorSlider
    private var active: InspectorSlider?
    init(_ parent: InspectorSlider) { self.parent = parent }
    func editing(_ isEditing: Bool) {
      if isEditing { guard active == nil else { return }; active = parent; active?.onEditingChanged(true) }
      else { let original = active; active = nil; original?.onEditingChanged(false) }
    }
    @objc func changed(_ sender: InspectorNativeSlider) {
      let owner = active ?? parent
      var next = min(owner.range.upperBound, max(owner.range.lowerBound, sender.doubleValue))
      if let step = owner.step, step.isFinite, step > 0 { next = min(owner.range.upperBound, max(owner.range.lowerBound, owner.range.lowerBound + ((next - owner.range.lowerBound) / step).rounded() * step)) }
      sender.doubleValue = next; owner.value = next
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> InspectorNativeSlider {
    let slider = InspectorNativeSlider(); slider.cell = InspectorSliderCell()
    slider.sliderType = .linear; slider.isVertical = false; slider.isContinuous = true; slider.controlSize = .small
    slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
    let coordinator = context.coordinator
    slider.editingChanged = { [weak coordinator] in coordinator?.editing($0) }
    slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    slider.setAccessibilityHelp("Arrow keys step this value. Shift uses ten times the step.")
    return slider
  }
  func updateNSView(_ slider: InspectorNativeSlider, context: Context) {
    context.coordinator.parent = self
    if !slider.editing {
      slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
      slider.doubleValue = min(range.upperBound, max(range.lowerBound, value)); slider.stepSize = step
    }
    slider.isEnabled = enabled && range.lowerBound < range.upperBound
    slider.numberOfTickMarks = max(0, min(100, tickCount))
    if let label { slider.setAccessibilityLabel(label) }
    slider.needsDisplay = true
  }
  static func dismantleNSView(_ slider: InspectorNativeSlider, coordinator: Coordinator) {
    slider.endEditing(); slider.editingChanged = nil; slider.target = nil
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: InspectorNativeSlider, context: Context) -> CGSize? { .init(width: proposal.width ?? 160, height: InspectorStyle.controlHeight) }
}

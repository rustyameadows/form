import AppKit
import FormGraphics
import SwiftUI

/// The specimen is drawn by SwiftUI; its entire visible area is one native
/// button. The star and project controls have separate, nonoverlapping targets.
struct FontPressable<Label: View>: View {
  let title: String
  let identifier: String
  var hover: ((Bool) -> Void)?
  let action: () -> Void
  @ViewBuilder let label: () -> Label
  var body: some View {
    label().accessibilityHidden(true)
      .overlay { FontNativeClickTarget(title: title, identifier: identifier, hover: hover, action: action) }
  }
}

private struct FontNativeClickTarget: NSViewRepresentable {
  let title: String, identifier: String
  let hover: ((Bool) -> Void)?
  let action: () -> Void
  @Environment(\.isEnabled) private var enabled
  func makeCoordinator() -> Coordinator { Coordinator(action) }
  func makeNSView(context: Context) -> FontClickButton {
    let button = FontClickButton(frame: .zero)
    button.setButtonType(.momentaryChange); button.isBordered = false
    button.target = context.coordinator; button.action = #selector(Coordinator.press)
    button.focusRingType = .exterior
    updateNSView(button, context: context)
    return button
  }
  func updateNSView(_ view: FontClickButton, context: Context) {
    context.coordinator.action = action
    view.isEnabled = enabled; view.hoverChanged = hover
    view.setAccessibilityLabel(title); view.setAccessibilityIdentifier(identifier)
    view.toolTip = title
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: FontClickButton, context: Context) -> CGSize? {
    .init(width: proposal.width ?? 28, height: proposal.height ?? 28)
  }
  static func dismantleNSView(_ view: FontClickButton, coordinator: Coordinator) {
    view.target = nil; view.action = nil; view.hoverChanged = nil; coordinator.action = {}
  }
  final class Coordinator: NSObject {
    var action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func press() { action() }
  }
}

private final class FontClickButton: NSButton {
  var hoverChanged: ((Bool) -> Void)?
  private var hoverTracking: NSTrackingArea?
  override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
  override var acceptsFirstResponder: Bool { isEnabled }
  override func draw(_ dirtyRect: NSRect) {}
  override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill() }
  override var focusRingMaskBounds: NSRect { bounds }
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityPerformPress() -> Bool {
    guard isEnabled, action != nil else { return false }; performClick(nil); return true
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHiddenOrHasHiddenAncestor, alphaValue > 0, bounds.contains(convert(point, from: superview)) else { return nil }
    return self
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTracking { removeTrackingArea(hoverTracking) }
    let area = NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(area); hoverTracking = area
  }
  override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
  override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
}

struct FontNativeStylePicker: NSViewRepresentable {
  let faces: [InstalledFontFace]
  @Binding var selected: String
  var didSelect: (String) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSPopUpButton {
    let view = NSPopUpButton(frame: .zero, pullsDown: false)
    view.controlSize = .regular; view.font = .systemFont(ofSize: 12)
    view.target = context.coordinator; view.action = #selector(Coordinator.changed(_:))
    view.setAccessibilityLabel("Font style"); view.setAccessibilityIdentifier("font-explorer-style")
    updateNSView(view, context: context); return view
  }
  func updateNSView(_ view: NSPopUpButton, context: Context) {
    context.coordinator.parent = self
    if view.itemArray.compactMap({ $0.representedObject as? String }) != faces.map(\.name) {
      view.removeAllItems()
      for face in faces {
        let item = NSMenuItem(title: face.style, action: nil, keyEquivalent: "")
        item.representedObject = face.name; view.menu?.addItem(item)
      }
    }
    if let item = view.itemArray.first(where: { $0.representedObject as? String == selected }) { view.select(item) }
  }
  static func dismantleNSView(_ view: NSPopUpButton, coordinator: Coordinator) { view.target = nil; view.action = nil }
  final class Coordinator: NSObject {
    var parent: FontNativeStylePicker
    init(_ parent: FontNativeStylePicker) { self.parent = parent }
    @objc func changed(_ sender: NSPopUpButton) {
      guard let name = sender.selectedItem?.representedObject as? String,
        parent.faces.contains(where: { $0.name == name }) else { return }
      parent.selected = name; parent.didSelect(name)
    }
  }
}

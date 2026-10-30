import AppKit
import SwiftUI

enum FloatingPanelStyle {
  static let inspectorWidth: CGFloat = 286
  static let headerHeight: CGFloat = 40
  static let outerPadding: CGFloat = 16
  static let cornerRadius: CGFloat = 13
}

/// One native close target for app panels. Closing a view is the caller's
/// responsibility; the component never changes document selection or focus.
struct AppCloseButton: NSViewRepresentable {
  let title: String
  let keyEquivalent: String
  let action: () -> Void
  @Environment(\.isEnabled) private var isEnabled

  init(_ title: String = "Close", keyEquivalent: String = "", action: @escaping () -> Void) {
    self.title = title
    self.keyEquivalent = keyEquivalent
    self.action = action
  }
  func makeCoordinator() -> Coordinator { Coordinator(action: action) }
  func makeNSView(context: Context) -> AppCloseNativeButton {
    let button = AppCloseNativeButton(frame: .zero)
    button.setButtonType(.momentaryChange)
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
    button.contentTintColor = NSColor(Palette.secondary)
    button.focusRingType = .exterior
    button.target = context.coordinator
    button.action = #selector(Coordinator.press(_:))
    updateNSView(button, context: context)
    return button
  }
  func updateNSView(_ button: AppCloseNativeButton, context: Context) {
    context.coordinator.action = action
    button.isEnabled = isEnabled
    button.keyEquivalent = keyEquivalent
    button.keyEquivalentModifierMask = []
    button.toolTip = title
    button.setAccessibilityLabel(title)
    button.needsDisplay = true
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppCloseNativeButton, context: Context) -> CGSize? {
    .init(width: AppCloseNativeButton.targetSize, height: AppCloseNativeButton.targetSize)
  }
  static func dismantleNSView(_ button: AppCloseNativeButton, coordinator: Coordinator) {
    button.target = nil
    button.action = nil
    coordinator.action = {}
  }
  final class Coordinator: NSObject {
    var action: () -> Void
    init(action: @escaping () -> Void) { self.action = action; super.init() }
    @objc func press(_ sender: NSButton) { if sender.isEnabled { action() } }
  }
}

final class AppCloseNativeButton: NSButton {
  static let targetSize: CGFloat = 28
  private var hover = false
  private var hoverTracking: NSTrackingArea?
  override var intrinsicContentSize: NSSize { .init(width: Self.targetSize, height: Self.targetSize) }
  // This image-only control draws entirely inside its target; NSButton's
  // standard bezel alignment outsets would otherwise add three vertical points.
  override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
  override var acceptsFirstResponder: Bool { isEnabled }
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityPerformPress() -> Bool {
    guard isEnabled, action != nil else { return false }
    performClick(nil)
    return true
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHiddenOrHasHiddenAncestor, alphaValue > 0,
      bounds.contains(convert(point, from: superview)) else { return nil }
    return self
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTracking { removeTrackingArea(hoverTracking) }
    let area = NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverTracking = area
  }
  override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    if isEnabled && (hover || isHighlighted) {
      NSColor(Palette.line).withAlphaComponent(isHighlighted ? 1 : 0.65).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
    super.draw(dirtyRect)
  }
}

struct FloatingPanelHeader<Accessory: View>: View {
  let title: String
  let closeLabel: String
  let onClose: (() -> Void)?
  let accessory: Accessory
  init(_ title: String, closeLabel: String = "Close panel", onClose: (() -> Void)? = nil,
    @ViewBuilder accessory: () -> Accessory) {
    self.title = title
    self.closeLabel = closeLabel
    self.onClose = onClose
    self.accessory = accessory()
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        InspectorSectionHeader(title).lineLimit(1)
        accessory
        if let onClose { AppCloseButton(closeLabel, action: onClose) }
      }.padding(.leading, InspectorStyle.panelPadding).padding(.trailing, 8)
        .frame(height: FloatingPanelStyle.headerHeight)
      InspectorDivider().padding(.horizontal, InspectorStyle.panelPadding)
    }
  }
}
extension FloatingPanelHeader where Accessory == EmptyView {
  init(_ title: String, closeLabel: String = "Close panel", onClose: (() -> Void)? = nil) {
    self.init(title, closeLabel: closeLabel, onClose: onClose) { EmptyView() }
  }
}

struct FloatingPanel<Content: View>: View {
  let title: String
  let closeLabel: String
  let onClose: () -> Void
  let content: Content
  init(_ title: String = "INSPECTOR", closeLabel: String = "Close inspector", onClose: @escaping () -> Void,
    @ViewBuilder content: () -> Content) {
    self.title = title
    self.closeLabel = closeLabel
    self.onClose = onClose
    self.content = content()
  }
  var body: some View {
    VStack(spacing: 0) {
      FloatingPanelHeader(title, closeLabel: closeLabel, onClose: onClose)
      content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }.inspectorSurface().floatingPanelSurface()
  }
}

struct FloatingPanelSurface: ViewModifier {
  var enabled = true
  func body(content: Content) -> some View {
    if enabled {
      content.background(Palette.paper)
        .clipShape(RoundedRectangle(cornerRadius: FloatingPanelStyle.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: FloatingPanelStyle.cornerRadius).strokeBorder(Palette.line).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 5)
    } else { content }
  }
}
extension View {
  func floatingPanelSurface() -> some View { modifier(FloatingPanelSurface()) }
}

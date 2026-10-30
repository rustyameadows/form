import AppKit
import SwiftUI

enum WorkspaceToolbarMetrics {
  static let symbolSize: CGFloat = 14
  static let symbolFont = Font.system(size: symbolSize, weight: .medium)
  static let valueFont = Font.system(size: 11, design: .monospaced)
  static let controlSize: CGFloat = 32
  static let spacing: CGFloat = 3
  static let padding: CGFloat = 6
  static let height: CGFloat = 44
  static let radius: CGFloat = 7
}

/// One face for Canvas tools, Table tools, viewport actions and menu labels.
private struct WorkspaceToolbarFace: ViewModifier {
  var selected = false
  var pressed = false
  @Environment(\.isEnabled) private var enabled
  @State private var hovered = false
  func body(content: Content) -> some View {
    content.font(WorkspaceToolbarMetrics.symbolFont)
      .frame(minWidth: WorkspaceToolbarMetrics.controlSize, minHeight: WorkspaceToolbarMetrics.controlSize)
      .foregroundStyle(Palette.ink.opacity(enabled ? 1 : 0.35))
      .background(pressed ? Palette.line : selected || hovered && enabled ? Palette.surface : .clear,
        in: RoundedRectangle(cornerRadius: WorkspaceToolbarMetrics.radius))
      .overlay {
        RoundedRectangle(cornerRadius: WorkspaceToolbarMetrics.radius)
          .strokeBorder(selected ? Palette.line : .clear, lineWidth: 0.75).allowsHitTesting(false)
      }
      .contentShape(RoundedRectangle(cornerRadius: WorkspaceToolbarMetrics.radius))
      .onHover { hovered = $0 }
  }
}

struct WorkspaceToolbarButton: NSViewRepresentable {
  let title: String
  let symbol: String
  let isSelected: Bool
  let help: String?
  let value: String?
  let showsTitle: Bool
  let identifier: String?
  let action: () -> Void
  @Environment(\.isEnabled) private var enabled

  init(_ title: String, symbol: String, isSelected: Bool = false, help: String? = nil,
    value: String? = nil, showsTitle: Bool = false, identifier: String? = nil, action: @escaping () -> Void) {
    self.title = title; self.symbol = symbol; self.isSelected = isSelected
    self.help = help; self.value = value; self.showsTitle = showsTitle; self.identifier = identifier; self.action = action
  }
  func makeCoordinator() -> Coordinator { Coordinator(action: action) }
  func makeNSView(context: Context) -> WorkspaceToolbarNativeButton {
    let button = WorkspaceToolbarNativeButton(frame: .zero)
    button.setButtonType(.momentaryPushIn); button.isBordered = false
    button.imagePosition = .imageOnly; button.bezelStyle = .regularSquare
    button.focusRingType = .exterior
    button.target = context.coordinator; button.action = #selector(Coordinator.press(_:))
    return button
  }
  func updateNSView(_ button: WorkspaceToolbarNativeButton, context: Context) {
    context.coordinator.action = action
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: WorkspaceToolbarMetrics.symbolSize, weight: .medium))
    button.contentTintColor = NSColor(Palette.ink).withAlphaComponent(enabled ? 1 : 0.35)
    button.isEnabled = enabled; button.selected = isSelected
    button.title = showsTitle ? title : ""
    button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    button.showsTitle = showsTitle
    button.imagePosition = showsTitle ? .imageLeading : .imageOnly
    button.invalidateIntrinsicContentSize()
    button.selectionValue = value ?? (isSelected ? "Selected" : "")
    button.toolTip = help ?? title; button.setAccessibilityLabel(title)
    button.setAccessibilityIdentifier(identifier)
    button.needsDisplay = true
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkspaceToolbarNativeButton, context: Context) -> CGSize? {
    nsView.intrinsicContentSize
  }
  static func dismantleNSView(_ button: WorkspaceToolbarNativeButton, coordinator: Coordinator) {
    button.target = nil; button.action = nil; coordinator.action = {}
  }
  final class Coordinator: NSObject {
    var action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func press(_ sender: NSButton) { if sender.isEnabled { action() } }
  }
}

/// Native keyboard/VoiceOver activation and a stable full-size hit target are
/// shared by every Canvas and Table tool; the action never owns document state.
final class WorkspaceToolbarNativeButton: NSButton {
  var selected = false
  var selectionValue = ""
  var showsTitle = false
  private var hovered = false
  private var hoverTracking: NSTrackingArea?
  override var intrinsicContentSize: NSSize {
    let labelWidth = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11)]).width
    return .init(width: showsTitle ? ceil(labelWidth) + WorkspaceToolbarMetrics.symbolSize + 26 : WorkspaceToolbarMetrics.controlSize,
      height: WorkspaceToolbarMetrics.controlSize)
  }
  override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
  override var acceptsFirstResponder: Bool { isEnabled }
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityValue() -> Any? { selectionValue }
  override func isAccessibilitySelected() -> Bool { selected }
  override func accessibilityPerformPress() -> Bool {
    guard isEnabled, action != nil else { return false }
    performClick(nil); return true
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHiddenOrHasHiddenAncestor, alphaValue > 0,
      bounds.contains(convert(point, from: superview)) else { return nil }
    return self
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTracking { removeTrackingArea(hoverTracking) }
    let area = NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect], owner: self)
    addTrackingArea(area); hoverTracking = area
  }
  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds, xRadius: WorkspaceToolbarMetrics.radius, yRadius: WorkspaceToolbarMetrics.radius)
    if isHighlighted || selected || hovered && isEnabled {
      NSColor(isHighlighted ? Palette.line : Palette.surface).setFill(); path.fill()
    }
    if selected {
      NSColor(Palette.line).setStroke(); path.lineWidth = 0.75; path.stroke()
    }
    super.draw(dirtyRect)
  }
}

/// Menus keep native menu behavior and share the exact tool-button face.
struct WorkspaceToolbarMenuLabel: View {
  let symbol: String
  var value: String?
  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: symbol)
      if let value { Text(value).font(WorkspaceToolbarMetrics.valueFont).monospacedDigit() }
    }.padding(.horizontal, value == nil ? 0 : 7)
      .modifier(WorkspaceToolbarFace()).accessibilityHidden(true)
  }
}

struct WorkspaceToolbarDivider: View {
  var body: some View {
    Rectangle().fill(Palette.line).frame(width: 1, height: 20).padding(.horizontal, 4)
      .accessibilityHidden(true)
  }
}

/// The same dock, including horizontal overflow, in full and split workspaces.
struct WorkspaceToolbarSurface<Content: View>: View {
  let maxWidth: CGFloat
  let content: Content
  @State private var contentWidth: CGFloat = 600
  init(maxWidth: CGFloat = .infinity, @ViewBuilder content: () -> Content) {
    self.maxWidth = maxWidth; self.content = content()
  }
  var body: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      HStack(spacing: WorkspaceToolbarMetrics.spacing) { content }
        .padding(WorkspaceToolbarMetrics.padding).fixedSize(horizontal: true, vertical: false)
        .background {
          GeometryReader { measured in
            Color.clear.onAppear { contentWidth = measured.size.width }
              .onChange(of: measured.size.width) { _, width in contentWidth = width }
          }
        }
    }.frame(width: min(contentWidth, max(1, maxWidth)), height: WorkspaceToolbarMetrics.height)
      .floatingPanelSurface()
  }
}

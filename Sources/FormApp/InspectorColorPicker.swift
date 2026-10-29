import AppKit
import SwiftUI

/// The default inspector color control. Opening it only reads the binding.
/// Supply targetID when a stable row can move between equal-colored targets.
struct InspectorColorPicker: View {
  let title: String
  @Binding var selection: Color
  let supportsOpacity: Bool
  let targetID: AnyHashable?
  let onEditingChanged: (Bool) -> Void

  init(_ title: String, selection: Binding<Color>, supportsOpacity: Bool = true,
    targetID: AnyHashable? = nil, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
    self.title = title; _selection = selection; self.supportsOpacity = supportsOpacity
    self.targetID = targetID; self.onEditingChanged = onEditingChanged
  }

  var body: some View {
    LabeledContent {
      InspectorColorWell(title: title, selection: $selection, supportsOpacity: supportsOpacity,
        targetID: targetID, onEditingChanged: onEditingChanged).frame(width: 34, height: 24)
    } label: { Text(title).font(InspectorStyle.labelFont) }
  }
}

@MainActor protocol InspectorColorPickerOwner: AnyObject {
  var colorOwnerID: UUID { get }
  var colorTitle: String { get }
  var colorSupportsOpacity: Bool { get }
  func readColor() -> NSColor
  func writeColor(_ color: NSColor)
  func colorEditingChanged(_ editing: Bool)
}

private struct InspectorColorWell: NSViewRepresentable {
  @Environment(\.isEnabled) private var isEnabled
  let title: String
  @Binding var selection: Color
  let supportsOpacity: Bool
  let targetID: AnyHashable?
  let onEditingChanged: (Bool) -> Void

  final class Coordinator: NSObject, InspectorColorPickerOwner {
    let colorOwnerID = UUID()
    var control: InspectorColorWell
    private var editingCallback: ((Bool) -> Void)?
    weak var button: InspectorColorWellButton?
    var colorTitle: String { control.title }
    var colorSupportsOpacity: Bool { control.supportsOpacity }
    init(_ control: InspectorColorWell) { self.control = control }
    func readColor() -> NSColor { NSColor(control.selection) }
    func writeColor(_ color: NSColor) { control.selection = Color(nsColor: color) }
    func colorEditingChanged(_ editing: Bool) {
      if editing {
        guard editingCallback == nil else { return }
        let callback = control.onEditingChanged
        editingCallback = callback
        callback(true)
      } else {
        // A live binding update can rebuild the SwiftUI row during this drag.
        // End the exact lease that began it, rather than a newly rendered closure.
        let callback = editingCallback
        editingCallback = nil
        callback?(false)
      }
    }
    @objc func open(_ sender: InspectorColorWellButton) {
      InspectorColorPanelController.shared.present(owner: self, relativeTo: sender)
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> InspectorColorWellButton {
    let button = InspectorColorWellButton(frame: .zero)
    button.target = context.coordinator; button.action = #selector(Coordinator.open(_:))
    context.coordinator.button = button
    return button
  }
  func updateNSView(_ button: InspectorColorWellButton, context: Context) {
    let owner = context.coordinator
    let changedTarget = owner.control.targetID != targetID || owner.control.title != title
      || owner.control.supportsOpacity != supportsOpacity
    // End the previous target's gesture while its old binding/callback still exists.
    if changedTarget { InspectorColorPanelController.shared.prepareRetarget(ownerID: owner.colorOwnerID) }
    owner.control = self
    button.color = NSColor(selection); button.isEnabled = isEnabled
    button.setAccessibilityLabel(title)
    button.setAccessibilityValue(InspectorColorComponents(button.color).map {
      "\($0.hex), \(String(format: "%.6g", $0.alpha * 100)) percent opacity"
    } ?? "Color")
    button.toolTip = "Choose \(title.lowercased())"
    if !isEnabled { InspectorColorPanelController.shared.detach(ownerID: owner.colorOwnerID) }
    else { InspectorColorPanelController.shared.refresh(owner: owner, newTarget: changedTarget) }
  }
  static func dismantleNSView(_ nsView: InspectorColorWellButton, coordinator: Coordinator) {
    InspectorColorPanelController.shared.detach(ownerID: coordinator.colorOwnerID)
    nsView.target = nil; nsView.action = nil
  }
}

final class InspectorColorWellButton: NSButton {
  var color: NSColor = .black { didSet { needsDisplay = true } }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    title = ""; bezelStyle = .regularSquare; isBordered = false
    setButtonType(.momentaryPushIn); focusRingType = .exterior
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var intrinsicContentSize: NSSize { .init(width: 34, height: 24) }
  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 2, dy: 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
    NSGraphicsContext.saveGraphicsState(); path.addClip()
    NSColor.white.setFill(); rect.fill()
    NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
    for row in 0..<5 { for column in 0..<7 where (row + column) % 2 == 0 {
      NSRect(x: rect.minX + CGFloat(column * 5), y: rect.minY + CGFloat(row * 5), width: 5, height: 5).fill()
    } }
    color.setFill(); rect.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
    if window?.firstResponder === self {
      NSColor.keyboardFocusIndicatorColor.setStroke(); path.lineWidth = 2; path.stroke()
    }
    if isHighlighted { NSColor.black.withAlphaComponent(0.1).setFill(); path.fill() }
    if !isEnabled { NSColor.windowBackgroundColor.withAlphaComponent(0.6).setFill(); path.fill() }
  }
}

private final class InspectorColorPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// One app-owned panel with a weak current owner. A pinned panel follows explicit
/// retargets, and is detached when its original control leaves the view tree.
@MainActor final class InspectorColorPanelController: NSObject, NSWindowDelegate {
  static let shared = InspectorColorPanelController()
  let state = InspectorColorState()
  private(set) var panel: NSPanel?
  private(set) var applePanel: NSColorPanel?
  private(set) var appleColorWell: NSColorWell?
  private weak var owner: InspectorColorPickerOwner?
  private var activeOwnerID: UUID?
  private var fallbackActive = false
  private var applyingFallbackColor = false
  private var fallbackCloseObserver: NSObjectProtocol?

  override init() {
    super.init()
    state.onChange = { [weak self] value in
      guard let self, let owner = self.owner, owner.colorOwnerID == self.activeOwnerID else { return }
      owner.writeColor(value.color)
      self.updateFallbackColor(value.color)
    }
    state.onEditingChanged = { [weak self] editing in
      guard let self, let owner = self.owner, owner.colorOwnerID == self.activeOwnerID else { return }
      owner.colorEditingChanged(editing)
    }
  }

  func present(owner: InspectorColorPickerOwner, relativeTo anchor: NSView) {
    state.endEditing()
    if activeOwnerID != owner.colorOwnerID { releaseFallback() }
    self.owner = owner; activeOwnerID = owner.colorOwnerID
    state.title = owner.colorTitle; state.supportsOpacity = owner.colorSupportsOpacity
    state.load(owner.readColor(), newTarget: true)
    if panel == nil { makePanel() }
    guard let panel else { return }
    panel.title = owner.colorTitle
    if !panel.isVisible || !state.isPinned {
      let anchorRect = anchor.convert(anchor.bounds, to: nil)
      if let window = anchor.window {
        let screenRect = window.convertToScreen(anchorRect)
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? screenRect
        let x = min(max(screenRect.maxX + 8, visible.minX), visible.maxX - panel.frame.width)
        let y = min(max(screenRect.maxY - panel.frame.height, visible.minY), visible.maxY - panel.frame.height)
        panel.setFrameOrigin(.init(x: x, y: y))
      }
    }
    panel.makeKeyAndOrderFront(nil)
    constrainToVisibleScreen()
  }

  func prepareRetarget(ownerID: UUID) {
    guard activeOwnerID == ownerID else { return }
    state.endEditing(); panel?.makeFirstResponder(nil); releaseFallback()
  }
  func refresh(owner: InspectorColorPickerOwner, newTarget: Bool) {
    guard activeOwnerID == owner.colorOwnerID else { return }
    state.title = owner.colorTitle; state.supportsOpacity = owner.colorSupportsOpacity
    state.load(owner.readColor(), newTarget: newTarget)
    panel?.title = owner.colorTitle
    if fallbackActive { updateFallbackColor(owner.readColor()) }
  }
  func detach(ownerID: UUID) {
    guard activeOwnerID == ownerID else { return }
    close()
  }
  func close() {
    state.endEditing(); releaseFallback()
    owner = nil; activeOwnerID = nil
    panel?.orderOut(nil)
  }
  func windowWillClose(_ notification: Notification) { if notification.object as? NSWindow === panel { close() } }
  func windowDidResignKey(_ notification: Notification) {
    state.endEditing()
    guard !state.isPinned, !(fallbackActive && appleColorWell?.isActive == true) else { return }
    close()
  }

  private func makePanel() {
    let panel = InspectorColorPanel(contentRect: .init(x: 0, y: 0, width: 280, height: 500),
      styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false; panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true; panel.appearance = NSAppearance(named: .aqua)
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      panel.standardWindowButton(button)?.isHidden = true
    }
    panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = true
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
    panel.level = .floating; panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    panel.delegate = self
    let effect = NSVisualEffectView()
    effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
    effect.wantsLayer = true; effect.layer?.cornerRadius = 12; effect.layer?.masksToBounds = true
    let host = NSHostingView(rootView: InspectorColorPanelContent(state: state,
      close: { [weak self] in self?.close() }, applePicker: { [weak self] in self?.showApplePicker() },
      heightChanged: { [weak self] in self?.resizeContent(height: $0) }).labInterface())
    effect.addSubview(host); host.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: effect.trailingAnchor), host.topAnchor.constraint(equalTo: effect.topAnchor),
      host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
    panel.contentView = effect
    panel.setContentSize(.init(width: 280, height: host.fittingSize.height))
    self.panel = panel
  }

  private func resizeContent(height: CGFloat) {
    guard let panel, height.isFinite, height > 0,
      abs((panel.contentView?.bounds.height ?? 0) - height) > 0.5 else { return }
    let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
    panel.setContentSize(.init(width: 280, height: height))
    panel.setFrameTopLeftPoint(topLeft)
    constrainToVisibleScreen()
  }

  private func constrainToVisibleScreen() {
    guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
    let visible = screen.visibleFrame
    let x = max(visible.minX, min(panel.frame.minX, visible.maxX - panel.frame.width))
    let y = max(visible.minY, min(panel.frame.minY, visible.maxY - panel.frame.height))
    panel.setFrameOrigin(.init(x: x, y: y))
  }

  func showApplePicker() {
    guard owner != nil, activeOwnerID != nil else { return }
    state.endEditing()
    // NSColorPanel is a singleton even when initialized directly. A dedicated
    // native well uses AppKit's exclusive activation lease instead of replacing
    // global panel targets or listening to another control's color notifications.
    if appleColorWell == nil {
      appleColorWell = NSColorWell(frame: .zero)
    }
    guard let well = appleColorWell else { return }
    let picker = NSColorPanel.shared
    applePanel = picker
    if !fallbackActive {
      fallbackActive = true
      fallbackCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
        object: picker, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.releaseFallback(orderOut: false) }
        }
    }
    applyingFallbackColor = true
    well.supportsAlpha = state.supportsOpacity
    well.color = state.components.color
    well.target = self; well.action = #selector(appleColorChanged(_:))
    well.activate(true)
    applyingFallbackColor = false
    if !picker.isVisible, let panel { picker.setFrameTopLeftPoint(.init(x: panel.frame.maxX + 8, y: panel.frame.maxY)) }
    picker.orderFront(nil)
  }
  @objc func appleColorChanged(_ sender: NSColorWell) {
    guard fallbackActive, !applyingFallbackColor, sender === appleColorWell, sender.isActive, owner != nil else { return }
    state.setNativeColor(sender.color)
  }
  private func updateFallbackColor(_ color: NSColor) {
    guard fallbackActive, let well = appleColorWell, well.isActive else { return }
    applyingFallbackColor = true; well.color = color; applyingFallbackColor = false
  }
  private func releaseFallback(orderOut: Bool = true) {
    guard fallbackActive else { return }
    fallbackActive = false
    if let observer = fallbackCloseObserver { NotificationCenter.default.removeObserver(observer) }
    fallbackCloseObserver = nil
    if let well = appleColorWell {
      let owned = well.isActive
      well.deactivate(); well.target = nil; well.action = nil
      if owned && orderOut { applePanel?.orderOut(nil) }
    }
  }
}

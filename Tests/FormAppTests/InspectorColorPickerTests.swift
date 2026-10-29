import AppKit
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class InspectorColorPickerTests: XCTestCase {
  private final class RenderedColor: ObservableObject {
    @Published var value = Color.red
    var factories = 0
    var active: UUID?
    var events = [(UUID, Bool)]()
    func callback() -> (Bool) -> Void {
      factories += 1
      let id = UUID()
      return { [weak self] editing in
        guard let self else { return }
        self.events.append((id, editing))
        if editing { self.active = id }
        else if self.active == id { self.active = nil }
      }
    }
  }
  private struct RenderedWell: View {
    @ObservedObject var color: RenderedColor
    var body: some View {
      InspectorColorPicker("Rendered color", selection: $color.value, supportsOpacity: false,
        targetID: "same-target", onEditingChanged: color.callback())
    }
  }
  private final class Owner: InspectorColorPickerOwner {
    let colorOwnerID = UUID()
    var colorTitle = "Fill color"
    var colorSupportsOpacity = true
    var value: NSColor
    var writes = [NSColor]()
    var editing = [Bool]()
    var editingHook: ((Bool) -> Void)?
    init(_ value: NSColor) { self.value = value }
    func readColor() -> NSColor { value }
    func writeColor(_ color: NSColor) { value = color; writes.append(color) }
    func colorEditingChanged(_ value: Bool) { editing.append(value); editingHook?(value) }
  }
  private func anchor() -> (NSWindow, NSView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 300, height: 180),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSView(frame: .init(x: 20, y: 20, width: 34, height: 24))
    window.contentView = view
    addTeardownBlock { @MainActor in window.close() }
    return (window, view)
  }
  private func exactColor() -> NSColor {
    InspectorColorComponents(red: 0.1234567890123, green: 0.4321987654321,
      blue: 0.6789012345678, alpha: 0.3141592653589).color
  }

  func testOpeningNativePanelReadsExactColorWithoutWritingOrBeginningAnUndoGesture() throws {
    let (_, anchor) = anchor(), owner = Owner(exactColor()), service = InspectorColorPanelController()
    defer { service.close() }
    service.present(owner: owner, relativeTo: anchor)
    let panel = try XCTUnwrap(service.panel)
    XCTAssertTrue(panel.isVisible); XCTAssertTrue(panel.isMovableByWindowBackground)
    XCTAssertGreaterThan(panel.contentView?.bounds.height ?? 0, 300)
    XCTAssertEqual(panel.level, .floating); XCTAssertFalse(panel.isOpaque)
    XCTAssertTrue(owner.writes.isEmpty); XCTAssertTrue(owner.editing.isEmpty)
    let initial = try XCTUnwrap(InspectorColorComponents(owner.value))
    XCTAssertEqual(service.state.components, initial)
    XCTAssertEqual(service.state.components.alpha, 0.3141592653589, accuracy: 1e-13)
  }

  func testRGBAndHexPreserveUneditedChannelsAndOpacityWithoutEightBitRoundTrips() throws {
    let state = InspectorColorState(), initial = try XCTUnwrap(InspectorColorComponents(exactColor()))
    var writes = [InspectorColorComponents](), edits = [Bool]()
    state.onChange = { writes.append($0) }; state.onEditingChanged = { edits.append($0) }
    state.load(initial.color); state.supportsOpacity = false
    XCTAssertTrue(writes.isEmpty)
    state.setChannel(0, 84.123456789)
    XCTAssertEqual(state.components.red, 84.123456789 / 255)
    XCTAssertEqual(state.components.green, initial.green); XCTAssertEqual(state.components.blue, initial.blue)
    XCTAssertEqual(state.components.alpha, initial.alpha)
    XCTAssertTrue(state.setHex("#ABCDEF")); XCTAssertEqual(state.components.alpha, initial.alpha)
    let count = writes.count, before = state.components
    XCTAssertFalse(state.setHex("#ABCDEF80")); XCTAssertEqual(state.components, before)
    state.setAlpha(1); XCTAssertEqual(writes.count, count)
    XCTAssertFalse(state.setHex("#GG0000")); XCTAssertEqual(writes.count, count)
    state.supportsOpacity = true
    XCTAssertTrue(state.setHex("#10203080")); XCTAssertEqual(state.components.alpha, 128.0 / 255)
    XCTAssertEqual(edits, [true, false, true, false, true, false])
  }

  func testPinnedRetargetEndsOldGestureBeforeReplacingTheBindingEvenForEqualColors() {
    let (_, anchor) = anchor(), owner = Owner(exactColor()), service = InspectorColorPanelController()
    defer { service.close() }
    service.present(owner: owner, relativeTo: anchor); service.state.isPinned = true
    var target = "old", callbacks = [String]()
    owner.editingHook = { callbacks.append("\(target):\($0)") }
    service.state.beginEditing(); service.state.setChannel(0, 90)
    service.prepareRetarget(ownerID: owner.colorOwnerID)
    XCTAssertEqual(callbacks, ["old:true", "old:false"])
    target = "new"
    service.refresh(owner: owner, newTarget: true)
    service.state.beginEditing(); service.state.setChannel(1, 160); service.state.endEditing()
    XCTAssertEqual(callbacks, ["old:true", "old:false", "new:true", "new:false"])
    XCTAssertTrue(service.panel?.isVisible == true)
    let second = Owner(owner.value)
    service.present(owner: second, relativeTo: anchor)
    let oldWrites = owner.writes.count
    service.state.setChannel(2, 70)
    XCTAssertEqual(owner.writes.count, oldWrites); XCTAssertEqual(second.writes.count, 1)
    service.detach(ownerID: owner.colorOwnerID)
    XCTAssertTrue(service.panel?.isVisible == true, "A stale control cannot close another target's panel")
    service.detach(ownerID: second.colorOwnerID)
    service.state.setChannel(2, 80)
    XCTAssertEqual(second.writes.count, 1); XCTAssertFalse(service.panel?.isVisible == true)
  }

  func testRealWheelMouseDragGroupsChangesAndNativeKeyboardAndAccessibilityActionsRemainDiscrete() throws {
    let (_, anchor) = anchor(), owner = Owner(.red), service = InspectorColorPanelController()
    defer { service.close() }
    service.present(owner: owner, relativeTo: anchor)
    let window = try XCTUnwrap(service.panel)
    let wheel = InspectorHueSaturationWheelView(state: service.state)
    wheel.frame = .init(x: 0, y: 0, width: 190, height: 190)
    window.contentView = wheel
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    wheel.mouseDown(with: try mouse(.leftMouseDown, .init(x: 95, y: 170)))
    wheel.mouseDragged(with: try mouse(.leftMouseDragged, .init(x: 35, y: 120)))
    wheel.mouseDragged(with: try mouse(.leftMouseDragged, .init(x: 40, y: 60)))
    wheel.mouseUp(with: try mouse(.leftMouseUp, .init(x: 50, y: 55)))
    XCTAssertGreaterThanOrEqual(owner.writes.count, 3); XCTAssertEqual(owner.editing, [true, false])
    XCTAssertTrue(window.firstResponder === wheel)
    let before = service.state.components
    wheel.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
      characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)))
    XCTAssertNotEqual(service.state.components, before)
    XCTAssertTrue(wheel.accessibilityPerformIncrement()); XCTAssertTrue(wheel.accessibilityPerformDecrement())
    XCTAssertEqual(wheel.accessibilityRole(), .slider)
    XCTAssertEqual(wheel.accessibilityLabel(), "Hue and saturation")
    XCTAssertEqual(owner.editing, [true, false, true, false, true, false, true, false])
  }

  func testExplicitAppleFallbackUsesExclusiveNativeWellLeaseAndDoesNotWriteAfterAnotherControlTakesOver() throws {
    let (_, anchor) = anchor(), owner = Owner(exactColor()), service = InspectorColorPanelController()
    defer { service.close() }
    service.present(owner: owner, relativeTo: anchor)
    XCTAssertTrue(owner.writes.isEmpty)
    service.showApplePicker()
    let picker = try XCTUnwrap(service.applePanel)
    let well = try XCTUnwrap(service.appleColorWell)
    XCTAssertTrue(picker === NSColorPanel.shared)
    XCTAssertTrue(well.isActive)
    XCTAssertTrue(owner.writes.isEmpty, "Opening the explicit fallback must also be read-only")
    well.color = .blue
    XCTAssertTrue(well.sendAction(well.action, to: well.target))
    XCTAssertEqual(owner.writes.count, 1)
    service.detach(ownerID: owner.colorOwnerID)
    let prior = owner.writes.count
    service.appleColorChanged(well)
    XCTAssertEqual(owner.writes.count, prior)

    service.present(owner: owner, relativeTo: anchor); service.showApplePicker()
    let oldCount = owner.writes.count
    let other = NSColorWell(frame: .zero)
    defer { other.deactivate(); picker.orderOut(nil) }
    other.color = .green; other.activate(true)
    XCTAssertTrue(other.isActive); XCTAssertFalse(well.isActive)
    picker.color = .green
    service.appleColorChanged(well)
    XCTAssertEqual(owner.writes.count, oldCount, "A deactivated fallback cannot write another well's chosen color")
    service.close()
    XCTAssertTrue(other.isActive); XCTAssertTrue(picker.isVisible, "Closing our panel must leave the new native owner's panel open")
  }

  func testOldNativeDragCannotContinueIntoANewPinnedTargetAndResigningKeyEndsTheGesture() throws {
    let (_, anchor) = anchor(), owner = Owner(.red), service = InspectorColorPanelController()
    defer { service.close() }
    service.present(owner: owner, relativeTo: anchor); service.state.isPinned = true
    let panel = try XCTUnwrap(service.panel)
    let wheel = InspectorHueSaturationWheelView(state: service.state)
    panel.contentView = wheel
    func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .init(x: 60, y: 100), modifierFlags: [],
        timestamp: 1, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    wheel.mouseDown(with: try mouse(.leftMouseDown))
    let second = Owner(.blue)
    service.present(owner: second, relativeTo: anchor)
    XCTAssertEqual(owner.editing, [true, false])
    wheel.mouseDragged(with: try mouse(.leftMouseDragged)); wheel.mouseUp(with: try mouse(.leftMouseUp))
    XCTAssertTrue(second.writes.isEmpty, "A queued drag still belongs to the original target")
    service.state.beginEditing()
    service.windowDidResignKey(.init(name: NSWindow.didResignKeyNotification, object: panel))
    XCTAssertEqual(second.editing, [true, false])
    XCTAssertTrue(panel.isVisible, "A pinned panel stays available while another editor has focus")
    service.state.isPinned = false
    service.windowDidResignKey(.init(name: NSWindow.didResignKeyNotification, object: panel))
    XCTAssertFalse(panel.isVisible)
  }

  func testActualRepresentableEndsTheOriginalCallbackAfterSameTargetBindingRerenders() async throws {
    let (window, _) = anchor(), model = RenderedColor()
    let host = NSHostingView(rootView: RenderedWell(color: model))
    window.contentView = host
    let service = InspectorColorPanelController.shared
    service.close()
    defer { service.close(); window.contentView = nil }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      if descendants(host).contains(where: { $0 is InspectorColorWellButton }) { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let button = try XCTUnwrap(descendants(host).compactMap { $0 as? InspectorColorWellButton }.first)
    button.performClick(nil)
    service.state.beginEditing()
    let original = try XCTUnwrap(model.active), rendered = model.factories
    service.state.setChannel(1, 120)
    for _ in 0..<100 where model.factories == rendered {
      host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertGreaterThan(model.factories, rendered, "The real SwiftUI row must rebuild its callback during the drag")
    service.state.setChannel(2, 80)
    service.state.endEditing()
    XCTAssertNil(model.active, "The original generation must end despite newer rendered callbacks")
    XCTAssertEqual(model.events.count, 2)
    XCTAssertEqual(model.events.first?.0, original); XCTAssertEqual(model.events.first?.1, true)
    XCTAssertEqual(model.events.last?.0, original); XCTAssertEqual(model.events.last?.1, false)
  }

  func testNativePanelUsesLightChromeAndRetargetResizeKeepsTheWholePanelOnItsVisibleScreen() async throws {
    let (window, anchor) = anchor(), owner = Owner(exactColor()), service = InspectorColorPanelController()
    window.appearance = NSAppearance(named: .darkAqua)
    owner.colorSupportsOpacity = false
    defer { service.close() }
    service.present(owner: owner, relativeTo: anchor)
    let panel = try XCTUnwrap(service.panel), screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
    XCTAssertEqual(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      XCTAssertTrue(panel.standardWindowButton(kind)?.isHidden ?? true)
    }
    let visible = screen.visibleFrame, beforeHeight = panel.frame.height
    panel.setFrameOrigin(.init(x: visible.maxX - 60, y: visible.minY - 15))
    service.prepareRetarget(ownerID: owner.colorOwnerID)
    owner.colorSupportsOpacity = true
    service.refresh(owner: owner, newTarget: true)
    for _ in 0..<200 {
      panel.contentView?.layoutSubtreeIfNeeded()
      if panel.frame.height > beforeHeight && visible.insetBy(dx: -0.5, dy: -0.5).contains(panel.frame) { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertGreaterThan(panel.frame.height, beforeHeight)
    XCTAssertTrue(visible.insetBy(dx: -0.5, dy: -0.5).contains(panel.frame), "Resized panel \(panel.frame) exceeds \(visible)")
    XCTAssertTrue(owner.writes.isEmpty)
  }

  func testNativeRoundedHueSaturationAndRGBFieldsDoNotWriteWhenFocusedAndSubmittedUntouched() async throws {
    let (_, anchor) = anchor(), owner = Owner(exactColor()), service = InspectorColorPanelController()
    owner.colorSupportsOpacity = false
    defer { service.close() }
    service.present(owner: owner, relativeTo: anchor)
    let panel = try XCTUnwrap(service.panel), initial = service.state.components
    func fields(_ view: NSView) -> [NSTextField] {
      (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    for _ in 0..<100 {
      panel.contentView?.layoutSubtreeIfNeeded()
      if panel.contentView.map(fields)?.contains(where: { $0.placeholderString == "Hue" }) == true { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    for title in ["Hue", "Saturation", "Red", "Green", "Blue"] {
      let field = try XCTUnwrap(panel.contentView.map(fields)?.first { $0.placeholderString == title })
      XCTAssertNotNil(field.stringValue.range(of: "^-?[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression))
      XCTAssertTrue(panel.makeFirstResponder(field))
      let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
      editor.insertNewline(nil)
      try await Task.sleep(nanoseconds: 5_000_000)
      panel.makeFirstResponder(nil)
      try await Task.sleep(nanoseconds: 5_000_000)
      XCTAssertEqual(service.state.components, initial)
      XCTAssertTrue(owner.writes.isEmpty, "Unchanged displayed \(title) must not round the precise source")
    }
  }
}

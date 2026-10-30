import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class CanvasBackgroundTests: XCTestCase {
  private struct ToolbarPopover: View {
    @ObservedObject var appearance: InterfaceAppearance
    @State private var showing = false
    var body: some View {
      WorkspaceToolbarButton("Canvas background", symbol: "circle.lefthalf.filled") { showing.toggle() }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
          CanvasBackgroundControls(appearance: appearance).padding(18).frame(width: 264).labInterface()
        }
    }
  }
  private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-background-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  func testOlderAccentPreferenceMigratesAndBothColorsSurviveIndependentEdits() throws {
    let file = try directory().appendingPathComponent("Appearance.json")
    try Data(##"{"accentHex":"#8822CC"}"##.utf8).write(to: file)
    let preferences = InterfaceAppearance(file: file)
    XCTAssertEqual(preferences.accentHex, "#8822CC")
    XCTAssertEqual(preferences.canvasBackgroundHex, InterfaceAppearance.defaultCanvasBackground)
    try preferences.setCanvasBackground("  223344 ")
    let saved = InterfaceAppearance(file: file)
    XCTAssertEqual(saved.canvasBackgroundHex, "#223344")
    XCTAssertEqual(saved.accentHex, "#8822CC")
    try saved.setAccent("#AA3300")
    XCTAssertEqual(InterfaceAppearance(file: file).canvasBackgroundHex, "#223344")
    let bytes = try Data(contentsOf: file)
    for invalid in ["#12", "#ABCDEF80", "#XYZXYZ", "transparent"] {
      XCTAssertThrowsError(try saved.setCanvasBackground(invalid))
      XCTAssertEqual(saved.canvasBackgroundHex, "#223344")
      XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    try saved.setCanvasBackground(NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 0.2))
    XCTAssertEqual(saved.canvasBackgroundHex, "#4080BF")
    XCTAssertEqual(saved.canvasBackgroundColor.alphaComponent, 1)
  }

  func testBackgroundDefaultsRecoverAndFailedSaveDoesNotChangePreference() throws {
    let suite = "canvas-background-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("bad", forKey: "LAB.canvasBackground")
    defaults.set("#245BFF", forKey: "LAB.interfaceAccent")
    let preferences = InterfaceAppearance(defaults: defaults)
    XCTAssertEqual(preferences.canvasBackgroundHex, InterfaceAppearance.defaultCanvasBackground)
    try preferences.setCanvasBackground("#333333")
    XCTAssertEqual(InterfaceAppearance(defaults: defaults).canvasBackgroundHex, "#333333")
    XCTAssertEqual(defaults.string(forKey: "LAB.interfaceAccent"), "#245BFF")
    let parent = try directory().appendingPathComponent("file")
    try Data([1]).write(to: parent)
    let broken = InterfaceAppearance(file: parent.appendingPathComponent("Appearance.json"))
    XCTAssertThrowsError(try broken.setCanvasBackground("#333333"))
    XCTAssertEqual(broken.canvasBackgroundHex, InterfaceAppearance.defaultCanvasBackground)
  }

  func testWorkspaceLabelsAndSelectionRemainReadableAcrossCustomColors() throws {
    let preferences = InterfaceAppearance(file: try directory().appendingPathComponent("Appearance.json"))
    func contrast(_ foreground: NSColor, _ background: NSColor) -> Double {
      let ratio = InterfaceAppearance.whiteContrast(foreground) / InterfaceAppearance.whiteContrast(background)
      return max(ratio, 1 / ratio)
    }
    for background in ["#FFFFFF", "#F2F2F2", "#B8B8B8", "#333333", "#161616", "#245BFF", "#00FF00", "#777777"] {
      try preferences.setCanvasBackground(background)
      XCTAssertGreaterThanOrEqual(contrast(preferences.canvasLabelColor, preferences.canvasBackgroundColor), 4.5, background)
      for accent in ["#245BFF", "#FFFFFF", "#000000", "#FF00FF", background] {
        try preferences.setAccent(accent)
        XCTAssertGreaterThanOrEqual(contrast(preferences.canvasControlColor, preferences.canvasBackgroundColor), 3, background + " / " + accent)
        XCTAssertEqual(preferences.canvasBackgroundHex, background)
        XCTAssertEqual(preferences.accentHex, accent)
      }
    }
  }

  func testActualPresetControlPersistsWithoutEditingArtworkOrUndoHistory() throws {
    _ = NSApplication.shared
    let root = try directory(), preferences = InterfaceAppearance(file: root.appendingPathComponent("Appearance.json"))
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Canvas appearance verification")
    _ = try project.ensureCanvasWorkspace()
    project.objects[0].artwork?.elements = [ArtworkElement(kind: "rectangle", x: 10, y: 20, width: 30, height: 40, color: "#333333")]
    store.engine.project = project
    let before = store.project, history = store.engine.undoStack.count
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 300, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: CanvasBackgroundControls(appearance: preferences).padding(18).frame(width: 264).labInterface())
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    defer { window.contentView = nil; window.close(); store.engine.project = nil }
    func settle() {
      host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15))
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    }
    func accessibility(_ item: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
      guard depth < 40, let node = item as? any NSAccessibilityProtocol else { return [] }
      return [node] + (node.accessibilityChildren() ?? []).flatMap { accessibility($0, depth: depth + 1) }
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func preset(_ label: String) -> (any NSAccessibilityProtocol)? {
      let nodes = descendants(host).flatMap { accessibility($0) }
      return nodes.first {
        $0.accessibilityRole() == .button && ($0.accessibilityLabel() == label || $0.accessibilityTitle() == label)
      }
    }
    settle()
    var charcoalRect: CGRect?
    var initialCheckmarkPixels = 0
    func checkmarkPixels(in rect: CGRect) throws -> Int {
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
      host.cacheDisplay(in: rect, to: bitmap)
      var count = 0
      // Examine only the swatch center, excluding its rounded corners and border.
      for y in bitmap.pixelsHigh/4..<bitmap.pixelsHigh*3/4 {
        for x in bitmap.pixelsWide/4..<bitmap.pixelsWide*3/4 {
          let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
          if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.8 { count += 1 }
        }
      }
      return count
    }
    func renderedCharcoalRect() throws -> CGRect {
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let sx = CGFloat(bitmap.pixelsWide) / host.bounds.width, sy = CGFloat(bitmap.pixelsHigh) / host.bounds.height
      var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
      // Locate the actual 32-point charcoal swatch. Long solid runs distinguish
      // it from antialiased text and avoid inferring SwiftUI row geometry from
      // the independently sized native color well.
      for y in 0..<bitmap.pixelsHigh {
        var start: Int?
        func finishRun(at end: Int) {
          if let start, end - start >= Int(24 * sx) {
            minX = min(minX, start); maxX = max(maxX, end - 1)
            minY = min(minY, y); maxY = max(maxY, y)
          }
          start = nil
        }
        for x in 0..<bitmap.pixelsWide {
          let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
          let charcoal = abs(color.redComponent - 0.2) < 0.015
            && abs(color.greenComponent - 0.2) < 0.015 && abs(color.blueComponent - 0.2) < 0.015
          if charcoal { if start == nil { start = x } } else { finishRun(at: x) }
        }
        finishRun(at: bitmap.pixelsWide)
      }
      guard maxX > minX, maxY > minY else {
        throw FormError.invalid("The rendered charcoal preset must be visible before sending the native pointer event.")
      }
      let rect = CGRect(x: host.bounds.minX + CGFloat(minX) / sx,
        y: host.isFlipped ? host.bounds.minY + CGFloat(minY) / sy : host.bounds.maxY - CGFloat(maxY + 1) / sy,
        width: CGFloat(maxX - minX + 1) / sx, height: CGFloat(maxY - minY + 1) / sy)
      XCTAssertGreaterThan(rect.width, 24); XCTAssertGreaterThan(rect.height, 20)
      return rect
    }
    if let charcoal = preset("Charcoal Canvas background") {
      XCTAssertTrue(charcoal.accessibilityPerformPress())
    } else {
      // SwiftUI can omit virtual AX buttons from an in-process test hierarchy.
      // Use a real window pointer event, as NativeModelControlTests does, while
      // retaining both persisted-state and rendered-selection verification.
      let rect = try renderedCharcoalRect(), center = CGPoint(x: rect.midX, y: rect.midY)
      charcoalRect = rect; initialCheckmarkPixels = try checkmarkPixels(in: rect)
      let location = host.convert(center, to: nil), stamp = ProcessInfo.processInfo.systemUptime
      let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
        timestamp: stamp, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
      let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
        timestamp: stamp + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
      NSApp.postEvent(up, atStart: false); NSApp.sendEvent(down)
      while let next = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(next) }
    }
    settle()
    XCTAssertEqual(preferences.canvasBackgroundHex, "#333333")
    XCTAssertEqual(InterfaceAppearance(file: root.appendingPathComponent("Appearance.json")).canvasBackgroundHex, "#333333")
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(store.engine.undoStack.count, history)
    if let selected = preset("Charcoal Canvas background") {
      XCTAssertEqual(selected.accessibilityValue() as? String, "Selected")
    } else if let charcoalRect {
      XCTAssertGreaterThan(try checkmarkPixels(in: charcoalRect), initialCheckmarkPixels,
        "The real preset must render its selected checkmark after the native pointer action")
    }
  }

  func testCustomPickerOpenedFromToolbarPopoverKeepsItsLivePreferenceBinding() async throws {
    _ = NSApplication.shared
    let root = try directory(), preferences = InterfaceAppearance(file: root.appendingPathComponent("Appearance.json"))
    let service = InspectorColorPanelController.shared
    service.close()
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 320, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ToolbarPopover(appearance: preferences).padding(20))
    window.contentView = host; window.orderBack(nil)
    defer { service.close(); window.contentView = nil; window.close() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      if descendants(host).contains(where: { $0 is WorkspaceToolbarNativeButton }) { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let button = try XCTUnwrap(descendants(host).compactMap { $0 as? WorkspaceToolbarNativeButton }.first)
    button.performClick(nil)
    var well: InspectorColorWellButton?
    for _ in 0..<100 {
      for visible in NSApp.windows where visible.isVisible {
        visible.contentView?.layoutSubtreeIfNeeded()
        well = visible.contentView.flatMap { descendants($0).compactMap { $0 as? InspectorColorWellButton }.first } ?? well
      }
      if well != nil { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    try XCTUnwrap(well).performClick(nil)
    for _ in 0..<20 { try await Task.sleep(nanoseconds: 5_000_000) }
    XCTAssertTrue(try XCTUnwrap(service.panel).isVisible, "Opening the custom picker must not discard its popover owner")
    XCTAssertTrue(service.state.setHex("#325678"))
    for _ in 0..<20 { try await Task.sleep(nanoseconds: 5_000_000) }
    XCTAssertEqual(preferences.canvasBackgroundHex, "#325678")
    XCTAssertEqual(InterfaceAppearance(file: root.appendingPathComponent("Appearance.json")).canvasBackgroundHex, "#325678")
    XCTAssertTrue(service.panel?.isVisible == true, "Live preference publication keeps the same color control attached")
  }
}

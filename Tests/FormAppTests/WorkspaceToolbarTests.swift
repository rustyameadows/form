import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class WorkspaceToolbarTests: XCTestCase {
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func accessibility(_ value: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
    guard depth < 40, let item = value as? any NSAccessibilityProtocol else { return [] }
    return [item] + (item.accessibilityChildren() ?? []).flatMap { accessibility($0, depth: depth + 1) }
  }
  private func button(_ root: NSView, _ label: String) throws -> any NSAccessibilityProtocol {
    try XCTUnwrap(descendants(root).flatMap { accessibility($0) }.first {
      $0.accessibilityRole() == .button && ($0.accessibilityLabel() == label || $0.accessibilityTitle() == label)
    }, "Shared toolbar button missing: \(label)")
  }
  private func assertControlTarget(_ node: any NSAccessibilityProtocol, in root: NSView,
    file: StaticString = #filePath, line: UInt = #line) throws {
    let control = try XCTUnwrap(node as? WorkspaceToolbarNativeButton, file: file, line: line)
    XCTAssertEqual(control.bounds.size, .init(width: 32, height: 32), file: file, line: line)
    XCTAssertEqual(control.frame.size, .init(width: 32, height: 32), file: file, line: line)
    let window = try XCTUnwrap(control.window, file: file, line: line)
    let screenRect = window.convertToScreen(control.convert(control.bounds, to: nil))
    // AppKit includes a one-point focus-ring outset in NSButton's AX frame.
    // The real view and every corner remain the exact shared 32-point target.
    XCTAssertTrue(node.accessibilityFrame().insetBy(dx: -0.01, dy: -0.01).contains(screenRect), file: file, line: line)
    for x in [CGFloat(1), 31] { for y in [CGFloat(1), 31] {
      let point = control.convert(.init(x: x, y: y), to: nil)
      let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
      XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true,
        "The whole shared toolbar target must accept input, including its corners", file: file, line: line)
    } }
  }
  private func settle(_ host: NSView) {
    host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)); host.layoutSubtreeIfNeeded()
  }
  private func fixture() throws -> (StudioStore, NSWindow, NSView) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-toolbar-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Shared viewport toolbars")
    let object = try project.makeObject(recipeID: "box")
    project.objects = [object]
    let workspace = try project.ensureCanvasWorkspace()
    store.engine.project = project; store.showingHome = false
    store.select(object.id); store.tableInspectorVisible = false
    store.artworkSession.activate(workspace.id)
    let host = NSHostingView(rootView: VStack(spacing: 12) {
      ArtworkStudio(session: store.artworkSession).frame(width: 800, height: 360)
      CameraControls(maxWidth: 780)
    }.environmentObject(store).frame(width: 800, height: 430))
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 800, height: 430),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    addTeardownBlock { @MainActor in
      store.artworkSession.canvas?.finishText(); window.contentView = nil; window.close()
      store.engine.project = nil; try? FileManager.default.removeItem(at: root)
    }
    settle(host)
    return (store, window, host)
  }

  func testActualCanvasAndTableDocksUseIdenticalButtonTargetsAndSelectionSemanticsWithoutChangingSource() throws {
    let (store, _, host) = try fixture()
    let before = try XCTUnwrap(store.project), history = store.engine.undoStack.count
    for tool in ArtworkTool.allCases {
      let node = try button(host, tool.rawValue.capitalized + " tool")
      try assertControlTarget(node, in: host)
    }
    for label in ["Orbit tool · O", "Move tool · V", "Perspective view · 1", "Top view · 2", "Front view · 3", "Table inspector"] {
      let node = try button(host, label)
      try assertControlTarget(node, in: host)
    }
    XCTAssertTrue(try button(host, "Text tool").accessibilityPerformPress()); settle(host)
    XCTAssertEqual(store.artworkSession.tool, .text)
    XCTAssertEqual(try button(host, "Text tool").accessibilityValue() as? String, "Selected")
    XCTAssertTrue(try button(host, "Move tool · V").accessibilityPerformPress()); settle(host)
    XCTAssertEqual(store.tableTool, .move)
    XCTAssertEqual(try button(host, "Move tool · V").accessibilityValue() as? String, "Selected")
    XCTAssertEqual(try button(host, "Orbit tool · O").accessibilityValue() as? String, "")
    XCTAssertTrue(try button(host, "Table inspector").accessibilityPerformPress()); settle(host)
    XCTAssertTrue(store.tableInspectorVisible)
    XCTAssertEqual(try button(host, "Table inspector").accessibilityValue() as? String, "Shown")
    XCTAssertTrue(try button(host, "Toggle 100 mm grid").accessibilityPerformPress()); settle(host)
    XCTAssertTrue(store.showGrid)
    XCTAssertEqual(store.project?.objects, before.objects); XCTAssertEqual(store.project?.history, before.history)
    XCTAssertEqual(store.engine.undoStack.count, history)
  }

  func testSharedOverflowKeepsEveryTableActionAndReturnsTheSameControlsAtFullWidth() throws {
    let (store, window, _) = try fixture()
    let host = NSHostingView(rootView: CameraControls(maxWidth: 210).environmentObject(store))
    window.contentView = host; host.frame = .init(x: 0, y: 0, width: 210, height: 44); settle(host)
    let labels = ["Table inspector", "Orbit tool · O", "Move tool · V", "Perspective view · 1", "Top view · 2",
      "Front view · 3", "Zoom out", "Zoom in", "Fit all · ⌘0", "Focus selection · F", "Toggle 100 mm grid"]
    let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
    XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.width, scroll.contentView.bounds.width)
    for label in labels { XCTAssertTrue(try button(host, label).isAccessibilityEnabled()) }
    let before = store.project?.objects, history = store.engine.undoStack.count
    XCTAssertTrue(try button(host, "Move tool · V").accessibilityPerformPress()); settle(host)
    host.rootView = CameraControls(maxWidth: 780).environmentObject(store)
    host.frame = .init(x: 0, y: 0, width: 780, height: 44); settle(host)
    XCTAssertEqual(store.tableTool, .move)
    for label in labels {
      try assertControlTarget(button(host, label), in: host)
    }
    XCTAssertEqual(store.project?.objects, before); XCTAssertEqual(store.engine.undoStack.count, history)
  }
}

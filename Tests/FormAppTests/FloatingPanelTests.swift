import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor private final class CloseTargetFixture: ObservableObject {
  @Published var target = 0
  @Published var enabled = true
  @Published var keyEquivalent = ""
  var actions = [Int]()
}
private struct CloseTargetFixtureView: View {
  @ObservedObject var fixture: CloseTargetFixture
  var body: some View {
    let target = fixture.target
    AppCloseButton("Close target \(target)", keyEquivalent: fixture.keyEquivalent) { fixture.actions.append(target) }
      .disabled(!fixture.enabled).padding(12)
  }
}
private struct InspectorPanelFixtureView: View {
  @ObservedObject var store: StudioStore
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      FloatingPanel(closeLabel: "Close Canvas test inspector", onClose: {}) {
        ArtworkInspector(session: store.artworkSession)
      }.frame(width: FloatingPanelStyle.inspectorWidth, height: 350)
      if store.tableInspectorVisible {
        FloatingPanel(closeLabel: "Close Table test inspector", onClose: store.closeTableInspector) {
          ObjectInspector(embedded: true)
        }.frame(width: FloatingPanelStyle.inspectorWidth, height: 350)
      }
    }.environmentObject(store).labInterface()
  }
}

@MainActor final class FloatingPanelTests: XCTestCase {
  private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
  }
  private func settle(_ root: NSView) {
    root.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
    root.layoutSubtreeIfNeeded()
  }
  private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> (NSWindow, NSHostingView<V>) {
    _ = NSApplication.shared
    let root = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: height),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    window.orderBack(nil)
    addTeardownBlock { @MainActor in window.makeFirstResponder(nil); window.contentView = nil; window.close() }
    settle(root)
    return (window, root)
  }
  private func assertNativeTarget(_ button: AppCloseNativeButton, in root: NSView, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(button.bounds.size, .init(width: 28, height: 28), file: file, line: line)
    XCTAssertTrue(button.isAccessibilityElement(), file: file, line: line)
    XCTAssertEqual(button.accessibilityRole(), .button, file: file, line: line)
    for x in [CGFloat(1), button.bounds.maxX - 1] {
      for y in [CGFloat(1), button.bounds.maxY - 1] {
        let point = button.convert(.init(x: x, y: y), to: nil)
        let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
        XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
          "The whole close target must be clickable, including its corners", file: file, line: line)
      }
    }
  }

  func testSharedInspectorHeaderCloseKeepsDocumentAndCanvasTableSelections() throws {
    let library = FileManager.default.temporaryDirectory.appendingPathComponent("shared-panel-close-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: library), seedLibrary: false)
    var project = Project(name: "Independent inspector visibility")
    var artboard = try project.makeObject(recipeID: "artboard")
    let element = ArtworkElement(kind: "rect", x: 12, y: 14, width: 30, height: 20)
    artboard.artwork = .init(elements: [element])
    let solid = try project.makeObject(recipeID: "deskClock")
    project.objects = [artboard, solid]
    store.engine.project = project
    store.select(solid.id)
    store.artworkSession.activate(artboard.id)
    store.artworkSession.choose([element.id])
    store.tableInspectorVisible = true
    let (_, root) = host(InspectorPanelFixtureView(store: store), width: 584, height: 350)
    defer { store.engine.project = nil; try? FileManager.default.removeItem(at: library) }
    let buttons = descendants(root, AppCloseNativeButton.self)
    XCTAssertEqual(buttons.count, 2, "The object content must not add another deselect/close header")
    let canvas = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Close Canvas test inspector" })
    let table = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Close Table test inspector" })
    assertNativeTarget(canvas, in: root)
    assertNativeTarget(table, in: root)
    let canvasRect = root.convert(canvas.bounds, from: canvas)
    let tableRect = root.convert(table.bounds, from: table)
    XCTAssertEqual(canvasRect.minY, tableRect.minY)
    XCTAssertEqual(tableRect.minX - canvasRect.minX, FloatingPanelStyle.inspectorWidth + 12)
    let before = store.project, selection = store.selected, artworkSelection = store.artworkSession.selection
    let canvasOwner = store.artworkSession.objectID
    XCTAssertTrue(table.accessibilityPerformPress())
    settle(root)
    XCTAssertFalse(store.tableInspectorVisible)
    XCTAssertEqual(store.selected, selection)
    XCTAssertEqual(store.artworkSession.selection, artworkSelection)
    XCTAssertEqual(store.artworkSession.objectID, canvasOwner)
    XCTAssertEqual(store.project, before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testNativeCloseUsesLatestActionAndDisabledStateWithoutReplacingItsTarget() throws {
    let fixture = CloseTargetFixture()
    let (_, root) = host(CloseTargetFixtureView(fixture: fixture), width: 60, height: 60)
    let button = try XCTUnwrap(descendants(root, AppCloseNativeButton.self).first)
    assertNativeTarget(button, in: root)
    button.performClick(nil)
    XCTAssertEqual(fixture.actions, [0])
    fixture.target = 1
    settle(root)
    XCTAssertTrue(descendants(root, AppCloseNativeButton.self).first === button)
    XCTAssertEqual(button.accessibilityLabel(), "Close target 1")
    XCTAssertTrue(button.accessibilityPerformPress())
    XCTAssertEqual(fixture.actions, [0, 1])
    fixture.enabled = false
    settle(root)
    button.performClick(nil)
    _ = button.accessibilityPerformPress()
    XCTAssertEqual(fixture.actions, [0, 1])
  }

  func testOptionalNativeCloseKeyEquivalentPreservesEscapeAndReturnActions() throws {
    let fixture = CloseTargetFixture()
    let (window, root) = host(CloseTargetFixtureView(fixture: fixture), width: 60, height: 60)
    let button = try XCTUnwrap(descendants(root, AppCloseNativeButton.self).first)
    func key(_ characters: String, code: UInt16) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    let escape = try key("\u{1b}", code: 53)
    XCTAssertFalse(button.performKeyEquivalent(with: escape), "Canvas/Table headers must not acquire a global Escape action")
    fixture.keyEquivalent = "\u{1b}"
    settle(root)
    XCTAssertTrue(button.keyEquivalentModifierMask.isEmpty)
    XCTAssertTrue(button.performKeyEquivalent(with: escape))
    XCTAssertEqual(fixture.actions, [0])
    fixture.keyEquivalent = "\r"
    fixture.target = 1
    settle(root)
    XCTAssertFalse(button.performKeyEquivalent(with: escape))
    XCTAssertTrue(button.performKeyEquivalent(with: try key("\r", code: 36)))
    XCTAssertEqual(fixture.actions, [0, 1])
    fixture.enabled = false
    settle(root)
    _ = button.performKeyEquivalent(with: try key("\r", code: 36))
    XCTAssertEqual(fixture.actions, [0, 1])
  }
}

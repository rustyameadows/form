import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class WorkspaceFindInteractionTests: XCTestCase {
  @MainActor private final class Fixture {
    let directory: URL, store: StudioStore, sourceID: UUID, physicalID: UUID
    let window: NSWindow, host: NSHostingView<AnyView>

    init(layout: DesignSurfaceLayout) throws {
      _ = NSApplication.shared
      directory = FileManager.default.temporaryDirectory.appendingPathComponent("find-field-editor-" + UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: directory), seedLibrary: false)
      var project = Project(name: "Find controls route native keyboard events")
      var source = try project.makeObject(recipeID: "artboard", name: "Navigation target", parameters: ["width": 180, "depth": 120])
      source.artwork = Artwork(elements: [
        .init(kind: "text", x: 10, y: 12, width: 35, height: 12, text: "Orbit alpha"),
        .init(kind: "text", x: 65, y: 45, width: 35, height: 12, text: "Orbit beta"),
        .init(kind: "text", x: 115, y: 80, width: 35, height: 12, text: "Orbit gamma")
      ], bleed: 0)
      let physical = try project.makeObject(recipeID: "box", name: "Retained Table target")
      sourceID = source.id; physicalID = physical.id; project.objects = [source, physical]
      project.camera.distance = 17; project.camera.azimuth = 0.83
      store.engine.project = project; store.showingHome = false; store.environment = .form; store.mode = .artwork
      store.surfaceLayout = layout; store.splitDirection = .stacked
      store.artworkSession.activate(sourceID); store.select(physicalID)
      window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1020, height: 700),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      host = NSHostingView(rootView: AnyView(ArtworkStudio(session: store.artworkSession).environmentObject(store)))
      window.contentView = host; window.orderBack(nil)
    }

    func close() {
      store.artworkSession.canvas?.finishText(); window.makeFirstResponder(nil)
      window.contentView = nil; window.close(); store.engine.project = nil
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
  }

  private func settle(_ host: NSView) async throws {
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds: 30_000_000)
    host.layoutSubtreeIfNeeded()
  }

  private func searchField(_ f: Fixture) async throws -> NSTextField {
    for _ in 0..<60 {
      f.host.layoutSubtreeIfNeeded()
      if let field = descendants(f.host, NSTextField.self).first(where: {
        $0.isEditable && ($0.accessibilityLabel() == "Find on Canvas" || $0.placeholderString == "Frames, layers, or text")
      }) { return field }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw XCTUnwrapError.missingSearchField
  }

  private enum XCTUnwrapError: Error { case missingSearchField }

  private func type(_ query: String, field: NSTextField, in f: Fixture) async throws -> NSTextView {
    f.window.makeKey()
    XCTAssertTrue(f.window.makeFirstResponder(field))
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.selectAll(nil); editor.insertText(query, replacementRange: .init(location: NSNotFound, length: 0))
    try await settle(f.host)
    XCTAssertEqual(f.store.canvasSearchQuery, query)
    return editor
  }

  private func key(_ code: UInt16, characters: String, in f: Fixture) async throws {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: f.window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
      f.window.sendEvent(event)
    }
    try await settle(f.host)
  }

  func testActualRetainedCanvasSearchFieldTypesAndNavigatesOneResultPerArrowEvent() async throws {
    let f = try Fixture(layout: .split); defer { f.close() }
    try await settle(f.host)
    let canvas = try XCTUnwrap(f.store.artworkSession.canvas)
    let before = f.store.project, selection = f.store.engine.selection, history = f.store.engine.undoStack.count
    f.store.requestWorkspaceFind(.artwork)
    let field = try await searchField(f)
    _ = try await type("orbit", field: field, in: f)
    let results = f.store.workspaceFindResults(for: .artwork, query: "orbit")
    XCTAssertEqual(results.count, 3)
    let target = try XCTUnwrap(results.dropFirst().first)
    guard case .canvasElement(_, let sourceID, let elementID) = target.target else {
      return XCTFail("The second match must be a canonical artwork element.")
    }
    let viewport = canvas.visibleCanvasRect
    try await key(125, characters: "\u{F701}", in: f)
    try await key(126, characters: "\u{F700}", in: f)
    try await key(125, characters: "\u{F701}", in: f)
    XCTAssertEqual(f.store.canvasSearchQuery, "orbit")
    XCTAssertEqual(canvas.visibleCanvasRect, viewport, "Search arrows must not nudge artwork or pan the Canvas.")
    XCTAssertEqual(f.store.project, before)
    try await key(36, characters: "\r", in: f)
    XCTAssertFalse(f.store.canvasFindVisible)
    XCTAssertEqual(f.store.artworkSession.objectID, sourceID)
    XCTAssertEqual(f.store.artworkSession.selection, [elementID], "One down arrow must advance exactly one result, including native field-editor routing.")
    XCTAssertEqual(f.store.engine.selection, selection); XCTAssertEqual(f.store.project, before)
    XCTAssertEqual(f.store.engine.undoStack.count, history)
    XCTAssertEqual(f.store.surfaceLayout, .split); XCTAssertEqual(f.store.splitDirection, .stacked)
    XCTAssertTrue(f.store.artworkSession.canvas === canvas)
  }

  func testNativeEscapeClearsQueryThenClosesWithoutCanvasOrTableSideEffects() async throws {
    for layout in [DesignSurfaceLayout.single, .detached] {
      let f = try Fixture(layout: layout); defer { f.close() }
      try await settle(f.host)
      let canvas = try XCTUnwrap(f.store.artworkSession.canvas)
      canvas.setZoom(1.4)
      let before = f.store.project, selection = f.store.engine.selection, history = f.store.engine.undoStack.count
      let frame = f.store.artworkSession.activeFrameID, viewport = canvas.visibleCanvasRect
      f.store.requestWorkspaceFind(.artwork)
      let field = try await searchField(f)
      _ = try await type("orbit", field: field, in: f)
      try await key(53, characters: "\u{1B}", in: f)
      XCTAssertTrue(f.store.canvasFindVisible); XCTAssertEqual(f.store.canvasSearchQuery, "")
      try await key(53, characters: "\u{1B}", in: f)
      XCTAssertFalse(f.store.canvasFindVisible)
      XCTAssertTrue(f.window.firstResponder === canvas)
      XCTAssertEqual(f.store.artworkSession.activeFrameID, frame)
      XCTAssertEqual(canvas.zoom, 1.4, accuracy: 1e-9); XCTAssertEqual(canvas.visibleCanvasRect, viewport)
      XCTAssertEqual(f.store.engine.selection, selection); XCTAssertEqual(f.store.project, before)
      XCTAssertEqual(f.store.engine.undoStack.count, history); XCTAssertEqual(f.store.surfaceLayout, layout)
    }
  }
}

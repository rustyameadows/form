import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

private struct ClockParameterHost: View {
  @ObservedObject var store: StudioStore
  var body: some View {
    if let object = store.primary, let parameter = store.project?.recipe(object.recipeID)?.parameters.first(where: { $0.id == "width" }) {
      ParameterControl(parameter: parameter, object: object).environmentObject(store).padding(20)
    }
  }
}
@MainActor final class ObjectParameterEditingTests: XCTestCase {
  private func fields(_ view: NSView) -> [NSTextField] {
    (view as? NSTextField).map { [$0] } ?? [] + view.subviews.flatMap { fields($0) }
  }
  private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
  private func fixture(unit: String = "mm") throws -> (StudioStore, NSWindow, NSTextView) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var p = Project(name: "Native parameter draft"); p.unit = unit
    let object = try p.makeObject(recipeID: "deskClock"); p.objects = [object]
    store.engine.project = p; store.select(object.id); store.showingHome = false; store.showEnvironment(.function)
    let host = NSHostingView(rootView: ClockParameterHost(store: store))
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 310, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    window.orderBack(nil); host.layoutSubtreeIfNeeded(); settle()
    let field = try XCTUnwrap(fields(host).first { $0.isEditable })
    XCTAssertTrue(window.makeFirstResponder(field)); settle()
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    addTeardownBlock { @MainActor in
      window.makeFirstResponder(nil); window.close(); store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    return (store, window, editor)
  }
  private func replace(_ editor: NSTextView, _ value: String) {
    editor.selectAll(nil); editor.insertText(value, replacementRange: .init(location: NSNotFound, length: 0)); settle()
  }
  func testTypingPartialNumberDoesNotPublishOrAlertAndEnvironmentHandoffCommitsOnce() throws {
    let (store, _, editor) = try fixture(), before = store.project!
    replace(editor, "1")
    XCTAssertEqual(store.project, before); XCTAssertNil(store.error); XCTAssertTrue(store.engine.undoStack.isEmpty)
    editor.insertText("81", replacementRange: .init(location: NSNotFound, length: 0)); settle()
    XCTAssertEqual(store.project, before)
    store.showEnvironment(.fabricate); settle()
    XCTAssertEqual(store.primary?["width"], 181); XCTAssertNil(store.error)
    XCTAssertEqual(store.engine.undoStack.count, 1)
    store.undo(); XCTAssertEqual(store.project, before)
    store.redo(); XCTAssertEqual(store.primary?["width"], 181)
  }
  func testInvalidCompletedDraftPreservesSourceAndDoesNotRaiseGlobalAlert() throws {
    let (store, _, editor) = try fixture(), before = store.project!
    for value in ["1", "nan", ""] {
      replace(editor, value); NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil); settle()
      XCTAssertEqual(store.project, before); XCTAssertNil(store.error); XCTAssertTrue(store.engine.undoStack.isEmpty)
    }
    replace(editor, "182"); store.showEnvironment(.fabricate); settle()
    XCTAssertEqual(store.primary?["width"], 182); XCTAssertEqual(store.engine.undoStack.count, 1)
  }
  func testInchesDraftConversionAndUntouchedPrecisionRemainPhysical() throws {
    let (store, _, editor) = try fixture(unit: "in"), before = store.project!
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
    XCTAssertEqual(store.project, before); XCTAssertTrue(store.engine.undoStack.isEmpty)
    replace(editor, "7.1"); store.showEnvironment(.fabricate); settle()
    XCTAssertEqual(try XCTUnwrap(store.primary?["width"]), 7.1 * 25.4, accuracy: 1e-10)
    XCTAssertEqual(store.engine.undoStack.count, 1); XCTAssertNil(store.error)
  }
}

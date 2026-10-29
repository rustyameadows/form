import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor private final class InspectorSliderFixture: ObservableObject {
  @Published var values = [12.25, 75.0]
  @Published var target = 0
  @Published var events = [String]()
}
private struct InspectorSliderTestView: View {
  @ObservedObject var model: InspectorSliderFixture
  var body: some View {
    let target = model.target
    InspectorSlider(value: Binding(get: { model.values[target] }, set: { model.values[target] = $0 }),
      in: 0...100, step: 0.25, label: "Declared width", tickCount: 5,
      onEditingChanged: { model.events.append("\(target):\($0 ? "begin" : "end")") })
      .padding(18).frame(width: 300, height: 72)
  }
}

private struct InspectorPhysicalParameterTestView: View {
  @ObservedObject var store: StudioStore
  var body: some View {
    if let object = store.primary, let parameter = store.project?.recipe(object.recipeID)?.parameters.first(where: { $0.id == "width" }) {
      ParameterControl(parameter: parameter, object: object).environmentObject(store).padding(18)
    }
  }
}

@MainActor final class InspectorControlsTests: XCTestCase {
  private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
  }
  private func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.035)) }
  private func fixture() throws -> (InspectorSliderFixture, NSWindow, InspectorNativeSlider) {
    _ = NSApplication.shared
    let model = InspectorSliderFixture(), root = NSHostingView(rootView: InspectorSliderTestView(model: model))
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 300, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root
    root.layoutSubtreeIfNeeded(); settle()
    let slider = try XCTUnwrap(descendants(root, InspectorNativeSlider.self).first)
    XCTAssertTrue(window.makeFirstResponder(slider))
    addTeardownBlock { @MainActor in window.makeFirstResponder(nil); window.contentView = nil; window.close() }
    return (model, window, slider)
  }
  private func arrow(_ slider: InspectorNativeSlider, _ window: NSWindow, code: UInt16, up: Bool = false, shift: Bool = false, repeated: Bool = false) throws {
    let event = try XCTUnwrap(NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero,
      modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, characters: code == 126 ? "\u{F700}" : "\u{F701}",
      charactersIgnoringModifiers: code == 126 ? "\u{F700}" : "\u{F701}", isARepeat: repeated, keyCode: code))
    if up { slider.keyUp(with: event) } else { slider.keyDown(with: event) }
    settle()
  }

  func testHouseDrawnSliderRetainsNativeKeyboardAccessibilityRangeAndEditingBoundaries() throws {
    let (model, window, slider) = try fixture()
    XCTAssertTrue(slider.cell is InspectorSliderCell)
    XCTAssertTrue(slider.isContinuous); XCTAssertEqual(slider.minValue, 0); XCTAssertEqual(slider.maxValue, 100)
    XCTAssertEqual(slider.accessibilityRole(), .slider); XCTAssertTrue(slider.isAccessibilityElement())
    XCTAssertEqual(slider.accessibilityLabel(), "Declared width")
    XCTAssertEqual((slider.accessibilityValue() as? NSNumber)?.doubleValue, 12.25)
    XCTAssertEqual((slider.accessibilityMinValue() as? NSNumber)?.doubleValue, 0)
    XCTAssertEqual((slider.accessibilityMaxValue() as? NSNumber)?.doubleValue, 100)
    try arrow(slider, window, code: 126)
    try arrow(slider, window, code: 126, repeated: true)
    try arrow(slider, window, code: 126, up: true)
    XCTAssertEqual(model.values[0], 12.75); XCTAssertEqual(model.events, ["0:begin", "0:end"])
    try arrow(slider, window, code: 125, shift: true)
    try arrow(slider, window, code: 125, up: true, shift: true)
    XCTAssertEqual(model.values[0], 10.25)
    XCTAssertTrue(slider.accessibilityPerformIncrement()); settle()
    XCTAssertEqual(model.values[0], 10.5)
    XCTAssertEqual(model.events, ["0:begin", "0:end", "0:begin", "0:end", "0:begin", "0:end"])
    slider.setAccessibilityValue(NSNumber(value: 42.5)); settle()
    XCTAssertEqual(model.values[0], 42.5)
    XCTAssertEqual((slider.accessibilityValue() as? NSNumber)?.doubleValue, 42.5)
    XCTAssertEqual(model.events.suffix(2), ["0:begin", "0:end"])
    slider.isEnabled = false
    XCTAssertFalse(slider.accessibilityPerformDecrement())
    slider.setAccessibilityValue(NSNumber(value: 12)); XCTAssertEqual(model.values[0], 42.5)
  }

  func testInProgressNativeGestureRetainsOriginalBindingAndFinishesOriginalCallback() throws {
    let (model, window, slider) = try fixture()
    try arrow(slider, window, code: 126)
    model.target = 1; settle()
    try arrow(slider, window, code: 126, repeated: true)
    try arrow(slider, window, code: 126, up: true)
    XCTAssertEqual(model.values[0], 12.75); XCTAssertEqual(model.values[1], 75)
    XCTAssertEqual(model.events, ["0:begin", "0:end"])
    try arrow(slider, window, code: 126)
    try arrow(slider, window, code: 126, up: true)
    XCTAssertEqual(model.values[0], 12.75); XCTAssertEqual(model.values[1], 75.25)
    XCTAssertEqual(model.events, ["0:begin", "0:end", "1:begin", "1:end"])
  }

  func testPhysicalParameterUsesExplicitCanvasUnitParsingAndKeepsRejectedDraftLocal() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("inspector-unit-draft-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Shared numeric fields"); project.unit = "in"
    let object = try project.makeObject(recipeID: "deskClock"); project.objects = [object]
    store.engine.project = project; store.select(object.id); store.showingHome = false
    let host = NSHostingView(rootView: InspectorPhysicalParameterTestView(store: store))
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 300, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.makeFirstResponder(nil); window.contentView = nil; window.close(); store.engine.project = nil; try? FileManager.default.removeItem(at: root) }
    host.layoutSubtreeIfNeeded(); settle()
    let field = try XCTUnwrap(descendants(host, NSTextField.self).first { $0.isEditable })
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.selectAll(nil); editor.insertText("181 mm", replacementRange: .init(location: NSNotFound, length: 0)); settle()
    XCTAssertEqual(store.project, project)
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil); settle()
    XCTAssertEqual(try XCTUnwrap(store.primary?["width"]), 181, accuracy: 1e-10)
    XCTAssertEqual(store.engine.undoStack.count, 1)
    let accepted = store.project
    editor.selectAll(nil); editor.insertText("2 in", replacementRange: .init(location: NSNotFound, length: 0)); settle()
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil); settle()
    XCTAssertEqual(store.project, accepted); XCTAssertEqual(store.engine.undoStack.count, 1)
    XCTAssertEqual(editor.string, "2 in"); XCTAssertNil(store.error)
    store.engine.undo(); XCTAssertEqual(store.project, project)
  }


  func testParameterSliderKeyboardRepeatIsOneActualDocumentUndoAndKeepsLatestValue() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("inspector-slider-undo-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Shared slider gesture")
    let object = try project.makeObject(recipeID: "deskClock"); project.objects = [object]
    store.engine.project = project; store.select(object.id); store.showingHome = false
    let host = NSHostingView(rootView: InspectorPhysicalParameterTestView(store: store))
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 300, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.makeFirstResponder(nil); window.contentView = nil; window.close(); store.engine.project = nil; try? FileManager.default.removeItem(at: root) }
    host.layoutSubtreeIfNeeded(); settle()
    let slider = try XCTUnwrap(descendants(host, InspectorNativeSlider.self).first)
    XCTAssertTrue(window.makeFirstResponder(slider))
    try arrow(slider, window, code: 126)
    try arrow(slider, window, code: 126, repeated: true)
    try arrow(slider, window, code: 126, repeated: true)
    try arrow(slider, window, code: 126, up: true)
    let latest = try XCTUnwrap(store.primary?["width"])
    XCTAssertGreaterThan(latest, object["width"])
    XCTAssertEqual(store.engine.undoStack.count, 1)
    XCTAssertFalse(store.engine.isInteracting(with: "parameter-\(object.id)-width"))
    let accepted = store.project
    store.engine.undo(); XCTAssertEqual(store.project, project)
    store.engine.redo(); XCTAssertEqual(store.project, accepted)
  }

}

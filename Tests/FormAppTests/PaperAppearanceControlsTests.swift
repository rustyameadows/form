import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class PaperAppearanceControlsTests: XCTestCase {
  private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
  }
  private func settle(_ root: NSView) {
    root.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04)); root.layoutSubtreeIfNeeded()
  }
  private func fixture(finish: Bool = false) throws -> (StudioStore, NSWindow, NSView) {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paper-native-appearance-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: folder), seedLibrary: false)
    var project = Project(name: "Native paper appearance"), paper = try project.makeObject(recipeID: "paperEnvelope")
    let text = ArtworkElement(kind: "text", x: 20, y: 80, width: 100, height: 20, text: "Live print source", color: "#123456")
    paper.artwork = .init(elements: [text]); paper.artwork!.backgroundOpacity = 0
    if finish { paper.paperConstruction!.finishes = [.init(name: "Letterpress", kind: .letterpress, elementIDs: [text.id], depthMM: 0.05)] }
    project.objects = [paper]; store.engine.project = project; store.select(paper.id); store.showingHome = false
    let root = NSHostingView(rootView: PaperAppearanceControls(object: paper).environmentObject(store).labInterface().padding(16))
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 286, height: 2200), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; window.orderBack(nil); settle(root)
    addTeardownBlock { @MainActor in window.makeFirstResponder(nil); window.contentView = nil; window.close(); store.engine.project = nil; try? FileManager.default.removeItem(at: folder) }
    return (store, window, root)
  }
  func testNativeStockSliderUsesSharedCommandGestureAndOneUndo() throws {
    let (store, window, root) = try fixture(), before = store.project!
    let slider = try XCTUnwrap(descendants(root, InspectorNativeSlider.self).first { $0.accessibilityLabel() == "Roughness" })
    XCTAssertTrue(window.makeFirstResponder(slider))
    for index in 0..<3 {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: index > 0, keyCode: 126))
      slider.keyDown(with: event); settle(root)
    }
    let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126))
    slider.keyUp(with: up); settle(root)
    XCTAssertEqual(store.project!.objects[0].paperConstruction!.stock.profile!.roughness, 0.93, accuracy: 1e-10)
    XCTAssertEqual(store.project!.objects[0].artwork, before.objects[0].artwork)
    XCTAssertEqual(store.engine.undoStack.count, 1)
    XCTAssertFalse(store.engine.isInteracting(with: "paper-stock-\(before.objects[0].id)"))
    store.engine.undo(); XCTAssertEqual(store.project, before)
  }
  func testNativeFinishDepthParsesPhysicalUnitsAndLeavesRejectedDraftLocal() throws {
    let (store, window, root) = try fixture(finish: true)
    let field = try XCTUnwrap(descendants(root, NSTextField.self).first { $0.isEditable && $0.placeholderString == "Impression depth" })
    let before = store.project!, target = before.objects[0].paperConstruction!.finishes![0]
    XCTAssertTrue(window.makeFirstResponder(field))
    var editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.selectAll(nil); editor.insertText("0.003 in", replacementRange: .init(location: NSNotFound, length: 0)); settle(root)
    editor.doCommand(by: #selector(NSResponder.insertNewline(_:))); settle(root)
    let accepted = store.project!
    XCTAssertEqual(accepted.objects[0].paperConstruction!.finishes![0].depthMM, 0.0762, accuracy: 1e-10)
    XCTAssertEqual(accepted.objects[0].paperConstruction!.finishes![0].elementIDs, target.elementIDs)
    XCTAssertEqual(accepted.objects[0].artwork, before.objects[0].artwork)
    XCTAssertEqual(store.engine.undoStack.count, 1)
    XCTAssertTrue(window.makeFirstResponder(field)); editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.selectAll(nil); editor.insertText("3 mm", replacementRange: .init(location: NSNotFound, length: 0)); settle(root)
    editor.doCommand(by: #selector(NSResponder.insertNewline(_:))); settle(root)
    XCTAssertEqual(store.project, accepted); XCTAssertEqual(store.engine.undoStack.count, 1)
    XCTAssertTrue(store.error == nil)
    store.engine.undo(); XCTAssertEqual(store.project, before)
  }
}

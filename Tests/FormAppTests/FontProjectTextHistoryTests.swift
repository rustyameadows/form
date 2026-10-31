import AppKit
import FormCore
import FormGraphics
import SwiftUI
import XCTest
@testable import FormApp

private struct ProjectFontSizeSlider: View {
  @ObservedObject var session: ArtworkSession
  var body: some View {
    InspectorSlider(value: Binding(get: { session.inspectedSize }, set: { session.typeSize($0) }),
      in: 1...144, step: 1, label: "Font size", onEditingChanged: session.inspectorEditing)
      .padding(12).frame(width: 260, height: 50)
  }
}

@MainActor final class FontProjectTextHistoryTests: XCTestCase {
  private func nativeDifference(_ actual: NSAttributedString, _ expected: NSAttributedString) -> String {
    guard actual.string == expected.string else { return "Native strings differ: actual \(actual.length) UTF-16 units, expected \(expected.length)" }
    let recoveredEqual = GlyphEngine.nativeEqual(TextCase.source(actual).text, TextCase.source(expected).text)
    func equal(_ a: Any?, _ b: Any?) -> Bool {
      if a == nil || b == nil { return a == nil && b == nil }
      return (a as? NSObject)?.isEqual(b) == true
    }
    func description(_ value: Any?) -> String {
      guard let value else { return "nil" }
      if let font = value as? NSFont {
        return "\(font.fontName) \(font.pointSize)pt, descriptor=\(font.fontDescriptor.fontAttributes)"
      }
      if let bytes = value as? Data, let json = try? JSONSerialization.jsonObject(with: bytes),
        let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
        let string = String(data: data, encoding: .utf8) { return string }
      return String(describing: value)
    }
    var edges: Set<Int> = [0, actual.length]
    for text in [actual, expected] {
      text.enumerateAttributes(in: .init(location: 0, length: text.length)) { _, range, _ in
        edges.insert(range.location); edges.insert(NSMaxRange(range))
      }
    }
    let sorted = edges.sorted(); var differences: [String] = []
    for index in 0..<max(0, sorted.count - 1) {
      let location = sorted[index], length = sorted[index + 1] - location
      guard length > 0 else { continue }
      let actualAttributes = actual.attributes(at: location, effectiveRange: nil)
      let expectedAttributes = expected.attributes(at: location, effectiveRange: nil)
      let keys = Set(actualAttributes.keys).union(expectedAttributes.keys).sorted { $0.rawValue < $1.rawValue }
      for key in keys where !equal(actualAttributes[key], expectedAttributes[key]) {
        let a = actualAttributes[key], b = expectedAttributes[key]
        var detail = "actual=\(description(a)), expected=\(description(b))"
        if let a = a as? Data, let b = b as? Data,
          let left = (try? JSONSerialization.jsonObject(with: a)) as? [String: Any],
          let right = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] {
          detail = Set(left.keys).union(right.keys).sorted().filter { !equal(left[$0], right[$0]) }
            .map { field in
              if field == "sourceArchive" {
                let actualBytes = (left[field] as? String).flatMap { Data(base64Encoded: $0) }?.count ?? 0
                let expectedBytes = (right[field] as? String).flatMap { Data(base64Encoded: $0) }?.count ?? 0
                return "sourceArchive bytes differ (actual \(actualBytes), expected \(expectedBytes))"
              }
              return "\(field): actual=\(description(left[field])), expected=\(description(right[field]))"
            }.joined(separator: "; ")
        }
        differences.append("\(location)/\(length) \(key.rawValue): \(detail.prefix(1_000))")
      }
    }
    return "Recovered source equal: \(recoveredEqual). \(differences.count) attribute differences: " + differences.prefix(4).joined(separator: " | ")
  }
  private func assertSourceEqual(_ actual: Project?, _ expected: Project,
    file: StaticString = #filePath, line: UInt = #line) {
    func runs(_ stories: [TextStory]?) -> String {
      (stories ?? []).map { story in
        "\(story.id): " + (story.textRuns ?? []).map { "\($0.location)/\($0.length)" }.joined(separator: ", ")
      }.joined(separator: "; ")
    }
    XCTAssertTrue(actual?.objects == expected.objects, "Artwork objects changed unexpectedly", file: file, line: line)
    XCTAssertTrue(actual?.textStories == expected.textStories,
      "Story source differs. Actual run ranges [\(runs(actual?.textStories))]; expected [\(runs(expected.textStories))]",
      file: file, line: line)
  }
  @MainActor private final class Fixture {
    let directory: URL, store: StudioStore, window: NSWindow, canvas: VectorCanvasView
    let textID: UUID
    var session: ArtworkSession { store.artworkSession }
    init() throws {
      _ = NSApplication.shared
      directory = FileManager.default.temporaryDirectory.appendingPathComponent("font-native-history-" + UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: directory), seedLibrary: false)
      var project = Project(name: "Native collection history")
      var object = try project.makeObject(recipeID: "artboard")
      var text = ArtworkElement(kind: "text", x: 10, y: 10, width: 100, height: 30, text: "Base", fontSize: 18)
      var type = Typography(); type.fontName = "Georgia"; type.frameMode = "area"
      text.typography = type; textID = text.id
      object.artwork = .init(elements: [text]); project.objects = [object]
      store.engine.project = project; store.showingHome = false
      window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 700, height: 500),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      canvas = VectorCanvasView(frame: .init(x: 0, y: 0, width: 700, height: 500))
      window.contentView = canvas
      canvas.session = store.artworkSession; store.artworkSession.canvas = canvas
      session.activate(object.id); session.choose([textID]); canvas.synchronize()
    }
    func source() throws -> ArtworkElement {
      try XCTUnwrap(store.project?.objects[0].artwork?.elements.first { $0.id == textID })
    }
    func begin() throws -> CanvasTextView {
      canvas.beginText(try source())
      let view = try XCTUnwrap(canvas.activeTextView)
      view.undoManager?.groupsByEvent = false
      view.setSelectedRange(.init(location: view.string.utf16.count, length: 0))
      return view
    }
    func type(_ string: String, in view: CanvasTextView) {
      view.breakUndoCoalescing(); view.undoManager?.beginUndoGrouping()
      view.insertText(string, replacementRange: view.selectedRange())
      view.undoManager?.endUndoGrouping(); view.breakUndoCoalescing()
    }
    func close() {
      canvas.finishText(); window.contentView = nil; window.close(); store.engine.project = nil
      try? FileManager.default.removeItem(at: directory)
    }
  }

  func testTypingBeforeAndAfterCollectionSaveUsesChronologicalNativeUndoAndRedo() throws {
    let f = try Fixture(); defer { f.close() }
    let original = f.store.project, view = try f.begin()
    f.type(" A", in: view)
    let captured = f.session.captureFontSelection(), range = view.selectedRange()
    XCTAssertTrue(f.session.toggleProjectFont("Missing-Saved-Face"))
    XCTAssertTrue(f.session.canApplyFont(context: captured))
    XCTAssertTrue(f.canvas.activeTextView === view); XCTAssertEqual(view.selectedRange(), range)
    f.type(" B", in: view)
    XCTAssertEqual(try f.source().text, "Base A B")
    f.store.undo(); XCTAssertEqual(try f.source().text, "Base A")
    XCTAssertEqual(f.session.projectFontNames, ["Missing-Saved-Face"])
    f.store.undo(); XCTAssertEqual(try f.source().text, "Base A"); XCTAssertTrue(f.session.projectFontNames.isEmpty)
    f.store.undo(); XCTAssertEqual(try f.source().text, "Base"); XCTAssertTrue(f.session.projectFontNames.isEmpty)
    f.store.redo(); XCTAssertEqual(try f.source().text, "Base A"); XCTAssertTrue(f.session.projectFontNames.isEmpty)
    f.store.redo(); XCTAssertEqual(f.session.projectFontNames, ["Missing-Saved-Face"])
    f.store.redo(); XCTAssertEqual(try f.source().text, "Base A B")
    XCTAssertTrue(f.canvas.activeTextView === view)
    f.canvas.finishText()
    let completed = f.store.project
    XCTAssertEqual(f.store.engine.undoStack.count, 1, "The editor retains its established grouped document-history semantics")
    f.store.undo(); XCTAssertEqual(f.store.project, original)
    f.store.redo(); XCTAssertEqual(f.store.project, completed)
  }

  func testCollectionOnlyNativeUndoRetainsPickerAndFinishedHistorySurvivesPackageRoundTrip() throws {
    let f = try Fixture(); defer { f.close() }
    let original = f.store.project, view = try f.begin(), captured = f.session.captureFontSelection()
    let range = view.selectedRange()
    XCTAssertFalse(f.canvas.canUndoText)
    XCTAssertTrue(f.session.toggleProjectFont("Missing-Portable-Face"))
    XCTAssertTrue(f.canvas.canUndoText)
    f.store.undo(); XCTAssertTrue(f.session.projectFontNames.isEmpty)
    XCTAssertTrue(f.canvas.activeTextView === view); XCTAssertEqual(view.selectedRange(), range)
    XCTAssertTrue(f.session.canApplyFont(context: captured))
    f.store.redo(); XCTAssertEqual(f.session.projectFontNames, ["Missing-Portable-Face"])
    XCTAssertTrue(f.session.canApplyFont(context: f.session.captureFontSelection()))
    f.canvas.finishText()
    let saved = try XCTUnwrap(f.store.project)
    try f.store.repository.save(saved)
    let reopened = try f.store.repository.load(saved.id)
    XCTAssertEqual(reopened.fontLibrary, saved.fontLibrary); XCTAssertEqual(reopened.objects, saved.objects)
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    f.store.undo(); XCTAssertEqual(f.store.project, original)
    f.store.redo(); XCTAssertEqual(f.store.project, saved)
    let reopenedView = try f.begin()
    XCTAssertTrue(f.session.toggleProjectFont("Missing-Portable-Face"))
    f.store.undo(); XCTAssertEqual(f.session.projectFontNames, ["Missing-Portable-Face"])
    XCTAssertTrue(f.canvas.activeTextView === reopenedView)
    f.canvas.finishText(); XCTAssertEqual(f.store.project, saved)
  }

  func testStaleNativeCollectionActionsNeverMutateReplacementProjectOrNewHistory() throws {
    let f = try Fixture(); defer { f.close() }
    let view = try f.begin()
    XCTAssertTrue(f.session.toggleProjectFont("Missing-Old-Project-Face"))
    var replacement = try XCTUnwrap(f.store.project)
    replacement.id = UUID(); replacement.name = "Other project"
    replacement.fontLibrary = .init(faceNames: ["Other-Project-Face"])
    f.store.engine.project = replacement
    view.undoManager?.undo()
    XCTAssertEqual(f.store.project, replacement)
    XCTAssertNotNil(f.store.error)
  }

  func testUnrelatedCommandFencesCollectionUndoInsteadOfOverwritingMixedChanges() throws {
    let f = try Fixture(); defer { f.close() }
    let view = try f.begin()
    XCTAssertTrue(f.session.toggleProjectFont("Missing-Saved-Face"))
    try f.store.engine.edit("Unrelated source edit") {
      $0.objects[0].artwork!.elements[0].color = "#AABBCC"
      $0.fontLibrary?.faceNames.append("Added-Elsewhere")
    }
    let changed = f.store.project
    view.undoManager?.undo()
    XCTAssertEqual(f.store.project, changed); XCTAssertNotNil(f.store.error)
  }

  func testActualInspectorSliderPreservesCollectionUndoOrderForTextAndSharedStories() throws {
    for linkedStory in [false, true] {
      let f = try Fixture(); defer { f.close() }
      let view: CanvasTextView
      if linkedStory {
        let project = try Samples.fieldGuide(), frame = try XCTUnwrap(project.textStories?.first?.frames.first)
        f.store.engine.project = project
        f.session.activate(frame.objectID); f.session.choose([frame.elementID]); f.canvas.synchronize()
        f.canvas.beginText(try XCTUnwrap(project.storyFrame(frame)?.element))
        view = try XCTUnwrap(f.canvas.activeTextView); view.undoManager?.groupsByEvent = false
      } else { view = try f.begin() }
      view.setSelectedRange(.init(location: 0, length: min(4, view.string.utf16.count)))
      let original = try XCTUnwrap(f.store.project), size = f.session.inspectedSize, range = view.selectedRange()
      let originalNative = NSAttributedString(attributedString: view.attributedString())
      let captured = f.session.captureFontSelection()
      XCTAssertTrue(f.session.toggleProjectFont("Missing-Slider-Choice"), f.store.error ?? "Collection save failed")
      XCTAssertTrue(f.session.canApplyFont(context: captured))

      let host = NSHostingView(rootView: ProjectFontSizeSlider(session: f.session))
      host.frame = .init(x: 400, y: 420, width: 260, height: 50)
      f.canvas.addSubview(host); host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.03)); host.layoutSubtreeIfNeeded()
      func sliders(_ view: NSView) -> [InspectorNativeSlider] {
        ([view as? InspectorNativeSlider].compactMap { $0 }) + view.subviews.flatMap(sliders)
      }
      let slider = try XCTUnwrap(sliders(host).first)
      XCTAssertEqual(slider.accessibilityLabel(), "Font size")
      XCTAssertTrue(f.window.makeFirstResponder(slider))
      for index in 0..<3 {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: f.window.windowNumber,
          context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
          isARepeat: index > 0, keyCode: 124))
        slider.keyDown(with: event)
      }
      let release = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: f.window.windowNumber,
        context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
      slider.keyUp(with: release)
      XCTAssertFalse(slider.editing); XCTAssertEqual(f.session.inspectedSize, size + 3)
      XCTAssertTrue(f.canvas.activeTextView === view); XCTAssertEqual(view.selectedRange(), range)
      let resized = try XCTUnwrap(f.store.project)

      f.store.undo()
      XCTAssertEqual(f.session.inspectedSize, size, "The complete slider hold is one native Undo")
      assertSourceEqual(f.store.project, original)
      XCTAssertEqual(f.session.projectFontNames, ["Missing-Slider-Choice"])
      f.store.undo(); XCTAssertTrue(f.session.projectFontNames.isEmpty, f.store.error ?? "Collection Undo was blocked")
      XCTAssertTrue(f.session.canApplyFont(context: captured), (f.session.fontSelectionUnavailableReason(context: captured) ?? "Picker target changed")
        + " · " + nativeDifference(view.attributedString(), originalNative))
      f.store.redo(); XCTAssertEqual(f.session.projectFontNames, ["Missing-Slider-Choice"])
      f.store.redo(); XCTAssertEqual(f.session.inspectedSize, size + 3)
      assertSourceEqual(f.store.project, resized)
      XCTAssertTrue(f.canvas.activeTextView === view); XCTAssertNil(f.store.error)
      f.window.makeFirstResponder(view); host.removeFromSuperview(); f.canvas.finishText()
      XCTAssertEqual(f.store.engine.undoStack.count, 1)
      f.store.undo(); XCTAssertEqual(f.store.project, original)
    }
  }

  func testSharedStoryNativeUndoRestoresSparseSourceRunsWithoutRevertingStoryMetadata() throws {
    let f = try Fixture(); defer { f.close() }
    var project = try Samples.fieldGuide()
    let frame = try XCTUnwrap(project.textStories?.first?.frames.first)
    let originalSource = try XCTUnwrap(project.textStories?.first?.sourceElement)
    f.store.engine.project = project
    f.session.activate(frame.objectID); f.session.choose([frame.elementID]); f.canvas.synchronize()
    f.canvas.beginText(try XCTUnwrap(project.storyFrame(frame)?.element))
    let view = try XCTUnwrap(f.canvas.activeTextView)
    view.undoManager?.groupsByEvent = false; view.setSelectedRange(.init(location: 0, length: 4))
    let originalNative = NSAttributedString(attributedString: view.attributedString())
    XCTAssertTrue(f.canvas.applyTextStyle { $0.tracking += 1 })
    XCTAssertNotEqual(f.store.project?.textStories?.first?.sourceElement, originalSource)
    // The restoration owns text source only, not later independent story metadata.
    project = try XCTUnwrap(f.store.project)
    project.textStories![0].name = "Renamed while editing"
    f.store.engine.project = project
    var expectedSource = originalSource; expectedSource.name = "Renamed while editing"
    f.store.undo()
    // Case provenance can rearchive equivalent derived layout attributes. The
    // recovered source must still restore every character and native attribute.
    XCTAssertTrue(GlyphEngine.nativeEqual(TextCase.source(view.attributedString()).text, TextCase.source(originalNative).text),
      nativeDifference(view.attributedString(), originalNative))
    XCTAssertTrue(f.store.project?.textStories?.first?.sourceElement == expectedSource,
      "Returning to the initial native state must restore exact sparse runs, not materialize inherited gaps")
    XCTAssertEqual(f.store.project?.textStories?.first?.name, "Renamed while editing")
    XCTAssertTrue(f.canvas.activeTextView === view)
    f.canvas.finishText()
    XCTAssertTrue(f.store.project?.textStories?.first?.sourceElement == expectedSource)
    XCTAssertEqual(f.store.project?.textStories?.first?.name, "Renamed while editing")
  }
}

import AppKit
import CryptoKit
import FormCADModel
import FormCore
import LabRendering
import MetalKit
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class NativeModelControlTests: XCTestCase {
  private final class PreviewCheckpoint {
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
  }
  private struct LiveControls: View {
    @ObservedObject var store: StudioStore
    var body: some View {
      HStack(spacing: 0) {
        TableCanvas().frame(width: 620, height: 1000)
        EnvironmentContextPanel().frame(height: 1000)
      }.environmentObject(store)
    }
  }
  private func fixture() throws -> StudioStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-model-controls-" + UUID().uuidString)
    let repository = try ProjectRepository(root: root), project = Project(name: "Native parameter controls")
    try repository.save(project)
    let store = StudioStore(repository: repository, seedLibrary: false)
    try store.engine.open(project.id); store.showingHome = false; store.environment = .function
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return store
  }
  private func host<V: View>(_ content: V) -> (NSWindow, NSView) {
    NSApp.setActivationPolicy(.accessory); NSApp.activate(ignoringOtherApps: true)
    let window = NSWindow(contentRect: .init(x: 30, y: 30, width: 980, height: 1060), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    let view = NSHostingView(rootView: content.preferredColorScheme(.light))
    window.contentView = view; window.makeKeyAndOrderFront(nil)
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15)); view.layoutSubtreeIfNeeded()
    return (window, view)
  }
  private func accessible(_ value: Any, where matches: (any NSAccessibilityProtocol) -> Bool, depth: Int = 0) -> (any NSAccessibilityProtocol)? {
    guard depth < 80, let node = value as? any NSAccessibilityProtocol else { return nil }
    if matches(node) { return node }
    for child in node.accessibilityChildren() ?? [] {
      if let result = accessible(child, where: matches, depth: depth + 1) { return result }
    }
    return nil
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func slider(_ root: NSView, label: String? = nil) throws -> any NSAccessibilityProtocol {
    let native = descendants(root).compactMap { $0 as? NSSlider }
    if let control = native.first { return control }
    for view in descendants(root) {
      if let control = accessible(view, where: { $0.accessibilityRole() == .slider && (label == nil || $0.accessibilityLabel() == label) }) { return control }
    }
    return try XCTUnwrap(nil as (any NSAccessibilityProtocol)?, "The requested native slider was not found.")
  }
  private func press(_ title: String, root: NSView, window: NSWindow) throws {
    if let node = descendants(root).compactMap({ accessible($0) { $0.accessibilityRole() == .button && ($0.accessibilityLabel() == title || $0.accessibilityTitle() == title) } }).first {
      XCTAssertTrue(node.accessibilityPerformPress()); return
    }
    let local = title == "Preview" ? CGPoint(x: root.bounds.maxX - 175, y: root.isFlipped ? root.bounds.maxY - 31 : 31)
      : CGPoint(x: root.bounds.maxX - 57, y: root.isFlipped ? 45 : root.bounds.maxY - 45)
    let point = root.convert(local, to: nil)
    let stamp = ProcessInfo.processInfo.systemUptime
    let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: stamp, windowNumber: window.windowNumber, context: nil, eventNumber: 100, clickCount: 1, pressure: 1))
    let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: stamp + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 101, clickCount: 1, pressure: 0))
    NSApp.postEvent(up, atStart: false); NSApp.sendEvent(down)
    while let next = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(next) }
  }
  /// Real native key events exercise the same sliders and bindings as pointer tracking.
  /// Yielding between events lets the actual viewport present intermediate results.
  private func controlInputs(_ control: any NSAccessibilityProtocol, fractions: [Double], window: NSWindow, sample: @escaping () -> [String: Any]) async throws -> [[String: Any]] {
    let native = try XCTUnwrap(control as? NSSlider)
    var measurements: [[String: Any]] = []
    XCTAssertTrue(window.makeFirstResponder(native))
    for fraction in fractions {
      let span = native.maxValue - native.minValue
      let target = native.minValue + fraction * span
      let tolerance = abs(span) * 0.008
      var lastCode: UInt16?
      for attempt in 0..<128 {
        let delta = target - native.doubleValue
        if abs(delta) <= tolerance { break }
        let stamp = ProcessInfo.processInfo.systemUptime, right = delta > 0
        let code: UInt16 = right ? 124 : 123
        let character = right ? "\u{F703}" : "\u{F702}"
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: stamp, windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: attempt > 0, keyCode: code))
        let old = native.doubleValue; window.sendEvent(event); lastCode = code
        try await Task.sleep(nanoseconds: 2_000_000)
        guard native.doubleValue != old else { XCTFail("The native slider did not handle its keyboard event."); throw FormError.invalid("Native slider input did not arrive.") }
        var row = sample(); row["event_to_source_ms"] = (ProcessInfo.processInfo.systemUptime - stamp) * 1000; row["native_value"] = native.doubleValue; row["event_uptime"] = stamp
        row["requested_native_value"] = target; row["native_minimum"] = native.minValue; row["native_maximum"] = native.maxValue
        measurements.append(row)
      }
      if let code = lastCode {
        let character = code == 124 ? "\u{F703}" : "\u{F702}"
        let release = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        window.sendEvent(release)
        try await Task.sleep(nanoseconds: 2_000_000)
      }
      guard abs(native.doubleValue - target) <= tolerance else { throw FormError.invalid("The bounded native keyboard sequence did not reach its requested slider value.") }
    }

    try await Task.sleep(nanoseconds: 20_000_000)
    return measurements
  }
  private func eventually(_ condition: @escaping () -> Bool) async throws {
    for _ in 0..<400 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
    XCTFail("The native control result did not become visible.")
    throw FormError.invalid("Native parameter control timed out.")
  }
  private func evidence(_ name: String, _ value: [String: Any], images: [String: CGImage] = [:]) throws {
    guard let path = ProcessInfo.processInfo.environment["FORM_NATIVE_CONTROL_PROOF_DIR"] else { return }
    let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(name + ".json"))
    for (suffix, image) in images { try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + "-" + suffix + ".png")) }
  }
  private func pixels(_ image: CGImage) -> Data { Data(SHA256.hash(data: image.dataProvider!.data! as Data)) }

  func testAuthoredNativeControlsUpdateVisibleTableAndKeepLatestPose() async throws {
    let store = try fixture(); defer { store.cad.reset(); store.cloth.clear(); store.engine.project = nil }
    _ = try store.engine.call("form_construction", arguments: ["command": "create", "definition": try jsonObject(ConstructionCommands.foldAndGlueExample())])
    let id = try XCTUnwrap(store.project?.objects.first?.id); store.select(id)
    let (window, view) = host(LiveControls(store: store)); defer { window.contentView = nil; window.close() }
    window.title = "Native authored fold controls"
    let renderer = try XCTUnwrap(store.scene?.renderer)
    try await eventually { renderer.diagnostics.componentCount > 0 }
    store.scene?.fitAll()
    let initial = try await renderer.capture(width: 620, height: 620), before = try XCTUnwrap(store.project)
    let control = try slider(view), started = ProcessInfo.processInfo.systemUptime, frames = renderer.diagnostics.frames
    let trace = try await controlInputs(control, fractions: [0.1, 0.8, 0.25, 0.9, 0.45, 0.7], window: window) {
      ["fold": store.project!.objects.first! ["fold"], "visible_frames": renderer.diagnostics.frames]
    }
    try await eventually { abs(store.project!.objects.first!["fold"] - before.objects.first!["fold"]) > 1 && renderer.diagnostics.frames > frames }
    let latest = store.project!.objects.first!["fold"], changed = try await renderer.capture(width: 620, height: 620)
    let elapsed = (ProcessInfo.processInfo.systemUptime - ((trace.last?["event_uptime"] as? Double) ?? started)) * 1000
    XCTAssertGreaterThan(latest, 60); XCTAssertLessThan(latest, 80); XCTAssertNotEqual(pixels(initial), pixels(changed))
    XCTAssertGreaterThan(Set(trace.compactMap { $0["visible_frames"] as? Int }).count, 1, "The viewport must update during native control input.")
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(store.project!.objects.first!["fold"], latest); XCTAssertEqual(store.project!.objects.first!.paperConstruction?.authored, before.objects.first!.paperConstruction?.authored)
    XCTAssertNil(store.error); XCTAssertLessThan(elapsed, 15000)
    try evidence("authored-fold", ["trace": trace, "latest_fold": latest, "last_input_to_capture_ms": elapsed, "frames_during_input": renderer.diagnostics.frames - frames], images: ["before": initial, "latest": changed])
  }

  func testFabricNativeControlsKeepSourceAndLatestRestSurface() async throws {
    let store = try fixture(); defer { store.cad.reset(); store.cloth.clear(); store.engine.project = nil }
    var project = try XCTUnwrap(store.project)
    let object = try project.makeObject(recipeID: "clothPanel", parameters: ["resolution": 8])
    project.objects = [object]; store.engine.project = project; store.select(object.id)
    let (window, view) = host(LiveControls(store: store)); defer { window.contentView = nil; window.close() }
    window.title = "Native fabric controls"
    let renderer = try XCTUnwrap(store.scene?.renderer); try await eventually { renderer.diagnostics.componentCount > 0 }
    store.scene?.fitAll()
    let initial = try await renderer.capture(width: 620, height: 620), control = try slider(view, label: "Panel width")
    let started = ProcessInfo.processInfo.systemUptime, frames = renderer.diagnostics.frames
    let trace = try await controlInputs(control, fractions: [0.2, 0.8, 0.3, 0.7, 0.4, 0.65], window: window) {
      ["width": store.project!.objects.first!["width"], "visible_frames": renderer.diagnostics.frames]
    }
    try await eventually { store.project!.objects.first!["width"] != object["width"] && renderer.diagnostics.frames > frames }
    let latest = store.project!.objects.first!["width"], changed = try await renderer.capture(width: 620, height: 620)
    let elapsed = (ProcessInfo.processInfo.systemUptime - ((trace.last?["event_uptime"] as? Double) ?? started)) * 1000
    XCTAssertGreaterThan(latest, 500); XCTAssertLessThan(latest, 600); XCTAssertNotEqual(pixels(initial), pixels(changed))
    XCTAssertGreaterThan(Set(trace.compactMap { $0["visible_frames"] as? Int }).count, 1)
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(store.project!.objects.first!["width"], latest); XCTAssertEqual(store.project!.objects.first!.id, object.id); XCTAssertEqual(store.project!.objects.first!.recipeID, object.recipeID)
    let rest = try XCTUnwrap(store.project!.objects.first!.cloth).mesh.restPositionsMm
    XCTAssertEqual(try XCTUnwrap(rest.map(\.x).max()) - XCTUnwrap(rest.map(\.x).min()), latest, accuracy: 1e-7)
    XCTAssertNil(store.error); XCTAssertLessThan(elapsed, 15000)
    try evidence("fabric-dimension", ["trace": trace, "latest_width": latest, "last_input_to_capture_ms": elapsed, "frames_during_input": renderer.diagnostics.frames - frames], images: ["before": initial, "latest": changed])
  }

  func testMechanicalNativeDraftControlsAndPreviewShowLatestValues() async throws {
    let store = try fixture(); defer { store.cad.reset(); store.engine.project = nil }
    let source = try XCTUnwrap(store.project), job = try store.cad.begin(CADModelExamples.enclosure())
    let (window, view) = host(CADModelEditor(coordinator: store.cad, review: job)); defer { window.contentView = nil; window.close() }
    window.title = "Native mechanical controls"
    let control = try slider(view), started = ProcessInfo.processInfo.systemUptime
    let trace = try await controlInputs(control, fractions: [0.2, 0.8, 0.3, 0.7, 0.4, 0.65], window: window) {
      ["width": job.definition.parameters[0].value, "state": job.state]
    }
    let draftElapsed = (ProcessInfo.processInfo.systemUptime - ((trace.last?["event_uptime"] as? Double) ?? started)) * 1000, latest = job.definition.parameters[0].value
    XCTAssertEqual(job.state, "draft"); XCTAssertNil(job.prepared); XCTAssertEqual(store.project, source)
    XCTAssertNotEqual(latest, CADModelExamples.enclosure().parameters[0].value)
    let previewStarted = ProcessInfo.processInfo.systemUptime
    try press("Preview", root: view, window: window)
    try await eventually { job.state != "preparing" }
    XCTAssertEqual(job.state, "ready", job.issue ?? "")
    XCTAssertEqual(job.prepared?.definition.parameters[0].value, latest)
    let renderer = try XCTUnwrap(descendants(view).compactMap { ($0 as? MTKView)?.delegate as? RealityKitSceneRenderer }.first)
    try await eventually { renderer.diagnostics.componentCount > 0 }
    let image = try await renderer.capture(width: 620, height: 620), previewElapsed = (ProcessInfo.processInfo.systemUptime - previewStarted) * 1000
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(job.definition.parameters[0].value, latest); XCTAssertEqual(job.prepared?.definition.parameters[0].value, latest); XCTAssertEqual(store.project, source)
    XCTAssertLessThan(previewElapsed, 4000); XCTAssertLessThan(draftElapsed, 15000)
    try evidence("mechanical-preview", ["trace": trace, "latest_width": latest, "last_input_to_draft_ms": draftElapsed, "preview_to_render_ms": previewElapsed, "timings": job.timings], images: ["latest": image])

    // Cancel an older native Preview while it is ready to publish, then show a
    // newer review. Releasing the old worker must not replace the new result.
    let checkpoint = PreviewCheckpoint()
    store.cad.preparationCheckpoint = { await checkpoint.wait() }
    defer { checkpoint.release(); store.cad.preparationCheckpoint = nil }
    try press("Preview", root: view, window: window)
    try await eventually { checkpoint.waiting }
    XCTAssertFalse(try XCTUnwrap(control as? NSSlider).isEnabled)
    try press("Cancel", root: view, window: window)
    XCTAssertEqual(job.state, "cancelled")
    window.orderOut(nil)
    store.cad.preparationCheckpoint = nil
    var definition = job.definition; try definition.setParameter("width", value: 135)
    let newest = try store.cad.begin(definition)
    let (newWindow, newView) = host(CADModelEditor(coordinator: store.cad, review: newest))
    defer { newWindow.contentView = nil; newWindow.close() }
    try press("Preview", root: newView, window: newWindow)
    try await eventually { newest.state == "ready" }
    checkpoint.release()
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(job.state, "cancelled"); XCTAssertEqual(newest.prepared?.definition.parameters.first?.value, 135)
    XCTAssertEqual(newest.state, "ready"); XCTAssertEqual(store.project, source)
    try evidence("mechanical-cancellation", ["old_state": job.state, "latest_state": newest.state, "latest_width": newest.prepared!.definition.parameters[0].value])
  }
}

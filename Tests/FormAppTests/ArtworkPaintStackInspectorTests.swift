import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class ArtworkPaintStackInspectorTests: XCTestCase {
  private struct Host: View {
    @ObservedObject var store: StudioStore
    var body: some View {
      ScrollView {
        if let element = store.artworkSession.primary {
          ArtworkPaintStackInspector(session: store.artworkSession,
            element: store.artworkSession.colored(element)).environmentObject(store).padding(16)
        }
      }.frame(width: 370, height: 900).background(Palette.paper)
    }
  }
  private func fixture(_ element: ArtworkElement) throws -> StudioStore {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("paint-inspector-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Editable layered paints")
    let object = try project.ensureCanvasWorkspace()
    project.objects[0].artwork?.elements = [element]
    project.schemaVersion = project.minimumSchemaVersion
    store.engine.project = project; store.mode = .artwork; store.showingHome = false
    store.artworkSession.activate(object.id); store.artworkSession.choose([element.id])
    addTeardownBlock { @MainActor in store.engine.project = nil; try? FileManager.default.removeItem(at: root) }
    return store
  }
  private func source(_ store: StudioStore) throws -> ArtworkElement {
    try XCTUnwrap(store.project?.objects.first?.artwork?.elements.first)
  }
  func testStackEditsReadLatestStatePreserveOtherLayersAndRejectInvalidPaintAtomically() throws {
    var shape = ArtworkElement(kind: "rectangle", x: 7, y: 9, width: 30, height: 20)
    shape.paintStack = [.init(.init(kind: "gradient", gradient: .init())),
      .init(.init(color: "#123456", opacity: 0.7), stroke: .init(width: 2))]
    shape.sourceMetadata = .init(format: "figma", nodeID: "1:2", properties: Data("{}".utf8))
    let store = try fixture(shape), session = store.artworkSession
    session.editPaintStack(elementID: shape.id) { $0[0].paint.gradient?.kind = "diamond" }
    session.editPaintStack(elementID: shape.id) { $0[0].paint.opacity = 0.4 }
    let edited = try source(store)
    XCTAssertNil(store.error); XCTAssertEqual(edited.paintStack?[0].paint.gradient?.kind, "diamond")
    XCTAssertEqual(edited.paintStack?[0].paint.opacity, 0.4)
    XCTAssertEqual(edited.paintStack?[1], shape.paintStack?[1])
    XCTAssertEqual(edited.sourceMetadata, shape.sourceMetadata)
    XCTAssertEqual(edited.x, shape.x); XCTAssertEqual(edited.width, shape.width)
    let before = store.project, history = store.engine.undoStack.count
    session.editPaintStack(elementID: shape.id) { $0[1].paint.opacity = 3 }
    XCTAssertNotNil(store.error); XCTAssertEqual(store.project, before)
    XCTAssertEqual(store.engine.undoStack.count, history)
    session.choose([])
    session.editPaintStack(elementID: shape.id) { $0.removeAll() }
    XCTAssertEqual(store.project, before, "An old inspector binding cannot edit a deselected layer")
  }
  func testBaseTextPaintEditingPreservesStyledCharactersAndLegacyBaseInk() throws {
    var text = ArtworkElement(kind: "text", x: 0, y: 0, width: 50, height: 20, text: "AB")
    text.color = "#336699"; text.fillOpacity = 0.6
    var span = TextSpan(location: 1, length: 1, typography: .init(), fontSize: 18, color: "#AA2200")
    span.paintStack = [.init(.init(color: "#AA2200", opacity: 0.8))]
    text.textRuns = [span]
    let store = try fixture(text), initial = store.project
    XCTAssertEqual(ArtworkPaintEditing.stack(for: text).first?.paint.color, text.color)
    store.artworkSession.editPaintStack(elementID: text.id, structural: true) {
      $0.append(.init(.init(color: "#000000"), stroke: .init(width: 0.3)))
    }
    let changed = try source(store)
    XCTAssertNil(store.error); XCTAssertEqual(changed.paintStack?.count, 2)
    XCTAssertEqual(changed.paintStack?[0].paint.opacity, 0.6)
    XCTAssertEqual(changed.textRuns, [span]); XCTAssertEqual(changed.text, "AB")
    XCTAssertEqual(store.engine.undoStack.count, 1)
    store.engine.undo(); XCTAssertEqual(store.project, initial)
  }
  func testImagePlacementPreservesAspectAndCentersFillAndFit() {
    let fill = ArtworkPaintPlacement.transform(filling: true, width: 100, height: 100, sourceAspect: 2)
    XCTAssertEqual(fill, .init(a: 2, d: 1, tx: -0.5, ty: 0))
    let fit = ArtworkPaintPlacement.transform(filling: false, width: 100, height: 100, sourceAspect: 2)
    XCTAssertEqual(fit, .init(a: 1, d: 0.5, tx: 0, ty: 0.25))
    XCTAssertEqual(fill.apply(.init(0.5, 0.5)), .init(0.5, 0.5))
    XCTAssertEqual(fit.apply(.init(0.5, 0.5)), .init(0.5, 0.5))
  }
  func testRotatedPaintControlsUsePhysicalScaleRotationAndPreserveSkewAndReflection() {
    let frame = Point2(100, 50)
    var transform = Affine2(a: 2, c: 0.15, d: -0.75, tx: 0.12, ty: -0.2)
    transform = ArtworkPaintPlacement.setting(transform, frame: frame, parameter: .rotation, value: 37)
    let original = ArtworkPaintPlacement.components(of: transform, frame: frame)
    XCTAssertEqual(original.rotation, 37, accuracy: 1e-10)
    XCTAssertEqual(original.scaleX, 2, accuracy: 1e-10)
    XCTAssertEqual(original.scaleY, -0.75, accuracy: 1e-10)
    let scaled = ArtworkPaintPlacement.setting(transform, frame: frame, parameter: .scaleX, value: 3)
    let changed = ArtworkPaintPlacement.components(of: scaled, frame: frame)
    XCTAssertEqual(changed.scaleX, 3, accuracy: 1e-10)
    XCTAssertEqual(changed.scaleY, original.scaleY, accuracy: 1e-10)
    XCTAssertEqual(changed.rotation, original.rotation, accuracy: 1e-10)
    XCTAssertEqual(changed.skew, original.skew, accuracy: 1e-10)
    XCTAssertEqual(scaled.tx, transform.tx); XCTAssertEqual(scaled.ty, transform.ty)
    let offset = ArtworkPaintPlacement.setting(transform, frame: frame, parameter: .offsetX, value: 0.7)
    XCTAssertEqual(offset.a, transform.a); XCTAssertEqual(offset.b, transform.b)
    XCTAssertEqual(offset.c, transform.c); XCTAssertEqual(offset.d, transform.d)
  }
  func testActualNativePaintControlsReorderDisableAndRemoveWithOneUndoEach() async throws {
    var shape = ArtworkElement(kind: "rectangle", x: 0, y: 0, width: 30, height: 20)
    shape.paintStack = [.init(.init(color: "#FF0000")), .init(.init(color: "#0000FF"))]
    let store = try fixture(shape), original = try XCTUnwrap(store.project)
    NSApp.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: .init(x: 60, y: 60, width: 370, height: 900),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: Host(store: store).labInterface()); window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.contentView = nil; window.close() }
    func nodes(_ item: Any, depth: Int = 0) -> [NSObject] {
      guard depth < 40, let node = item as? NSObject else { return [] }
      // SwiftUI's virtual accessibility objects can implement the informal
      // NSObject accessibility API without declaring NSAccessibilityProtocol.
      let formal = (node as? any NSAccessibilityProtocol)?.accessibilityChildren() ?? []
      let informal = node.accessibilityAttributeValue(.children) as? [Any] ?? []
      var seen = Set<ObjectIdentifier>()
      let children = (formal + informal).compactMap { $0 as? NSObject }.filter { seen.insert(ObjectIdentifier($0)).inserted }
      return [node] + children.flatMap { nodes($0, depth: depth + 1) }
    }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    func pointerTarget(_ identifier: String) throws -> NSView {
      let parts = identifier.split(separator: "-")
      let index = try XCTUnwrap(parts.count == 3 ? Int(parts[1]) : nil)
      let mounted = views(host).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty }
      let switches = mounted.filter { String(describing: type(of: $0)) == "PlatformSwitch" }
        .sorted {
          let a = $0.convert($0.bounds, to: host).midY, b = $1.convert($1.bounds, to: host).midY
          return host.isFlipped ? a < b : a > b
        }
      XCTAssertEqual(switches.count, 2, "Both actual paint rows must be mounted before interacting")
      let row = 1 - index
      let toggle = try XCTUnwrap(switches.indices.contains(row) ? switches[row] : nil)
      if parts[2] == "enabled" { return toggle }
      let y = toggle.convert(toggle.bounds, to: host).midY
      // The rendered dump exposes these actual NSViews even when SwiftUI does
      // not publish its virtual AX buttons in an in-process test. Match the
      // row geometrically and click the real forward/back/remove control.
      let buttons = mounted.filter {
        String(describing: type(of: $0)) == "SwiftUIAppKitButton"
          && abs($0.convert($0.bounds, to: host).midY - y) < 12
      }.sorted { $0.convert($0.bounds, to: host).midX < $1.convert($1.bounds, to: host).midX }
      XCTAssertEqual(buttons.count, 3, "Each actual paint header has forward, backward and remove buttons")
      let column = parts[2] == "forward" ? 0 : parts[2] == "backward" ? 1 : 2
      return try XCTUnwrap(buttons.indices.contains(column) ? buttons[column] : nil)
    }
    func click(_ view: NSView) throws {
      view.scrollToVisible(view.bounds); host.layoutSubtreeIfNeeded()
      let rect = view.convert(view.bounds, to: host)
      XCTAssertTrue(host.visibleRect.intersects(rect)); XCTAssertGreaterThan(rect.width, 5)
      let location = view.convert(.init(x: view.bounds.midX, y: view.bounds.midY), to: nil)
      let time = ProcessInfo.processInfo.systemUptime
      let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
        modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1))
      let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
        modifierFlags: [], timestamp: time + 0.02, windowNumber: window.windowNumber, context: nil,
        eventNumber: 2, clickCount: 1, pressure: 0))
      NSApp.postEvent(up, atStart: false); NSApp.sendEvent(down)
      while let event = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
      }
    }
    func press(_ identifier: String) async throws {
      var button: NSObject?
      for _ in 0..<15 {
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        button = views(host).flatMap { nodes($0) }.first {
          ($0 as? any NSAccessibilityProtocol)?.accessibilityIdentifier() == identifier
            || $0.accessibilityAttributeValue(.identifier) as? String == identifier
        }
        if button != nil { break }; try await Task.sleep(nanoseconds: 10_000_000)
      }
      if button == nil {
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
          host.cacheDisplay(in: host.bounds, to: bitmap)
          try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/lab-paint-inspector-controls.png"))
        }
        let tree = views(host).flatMap { nodes($0) }.map {
          "\(type(of: $0)) \($0.accessibilityAttributeValue(.role) ?? "") \($0.accessibilityAttributeValue(.identifier) ?? "") \($0.accessibilityAttributeValue(.title) ?? "")"
        }.joined(separator: "\n")
        try tree.write(to: URL(fileURLWithPath: "/tmp/lab-paint-inspector-accessibility.txt"), atomically: true, encoding: .utf8)
      }
      if let control = button as? any NSAccessibilityProtocol {
        XCTAssertTrue(control.accessibilityPerformPress())
      } else if let control = button {
        XCTAssertTrue(control.accessibilityActionNames().contains(.press))
        control.accessibilityPerformAction(.press)
      } else {
        try click(pointerTarget(identifier))
      }
      try await Task.sleep(nanoseconds: 30_000_000)
    }
    try await press("paint-0-forward")
    XCTAssertEqual(try source(store).paintStack?.map(\.paint.color), ["#0000FF", "#FF0000"])
    XCTAssertEqual(store.engine.undoStack.count, 1); store.engine.undo(); store.changed()
    XCTAssertEqual(store.project, original)
    try await press("paint-1-enabled")
    XCTAssertEqual(try source(store).paintStack?[1].enabled, false)
    XCTAssertEqual(store.engine.undoStack.count, 1); store.engine.undo(); store.changed()
    XCTAssertEqual(store.project, original)
    try await press("paint-1-remove")
    XCTAssertEqual(try source(store).paintStack?.map(\.paint.color), ["#FF0000"])
    XCTAssertEqual(store.engine.undoStack.count, 1); store.engine.undo()
    XCTAssertEqual(store.project, original); XCTAssertNil(store.error)
  }
}

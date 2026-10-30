import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasPointerRoutingTests: XCTestCase {
  @MainActor private final class Fixture {
    let root: URL, store: StudioStore, session: ArtworkSession
    let window: NSWindow, scroll: ArtworkScrollView, canvas: VectorCanvasView
    let frameID: UUID, workspaceID: UUID
    let frameOrigin = CGPoint(x: 150, y: 130)

    init(elements: [ArtworkElement] = []) throws {
      _ = NSApplication.shared
      root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-routing-" + UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
      var project = Project(name: "Canvas pointer routing")
      workspaceID = try project.ensureCanvasWorkspace().id
      var frame = try project.makeObject(recipeID: "artboard", name: "Frame", parameters: ["width": 100, "depth": 80])
      frame.artwork = Artwork(background: "#FFFFFF", elements: elements, bleed: 0)
      frame.artwork?.canvasPosition = .init(frameOrigin.x, frameOrigin.y)
      frame.artwork?.snapEnabled = false
      frameID = frame.id; project.objects.append(frame)
      project.schemaVersion = project.minimumSchemaVersion
      store.engine.project = project; store.mode = .artwork; store.showingHome = false
      session = store.artworkSession; session.activate(frameID)
      window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 650),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      scroll = ArtworkScrollView(frame: window.contentView!.bounds)
      scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
      canvas = VectorCanvasView(frame: scroll.bounds)
      canvas.session = session; session.canvas = canvas; scroll.documentView = canvas
      window.contentView = scroll; window.makeFirstResponder(canvas)
      canvas.synchronize(); canvas.fit(all: true); canvas.setZoom(1)
    }

    func close() {
      canvas.finishText(); window.contentView = nil; window.close(); store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    func location(_ local: CGPoint) -> CGPoint {
      canvas.convert(canvas.documentPoint(.init(x: frameOrigin.x + local.x, y: frameOrigin.y + local.y)), to: nil)
    }
    func mouse(_ type: NSEvent.EventType, _ local: CGPoint) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: location(local), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    func key(_ code: UInt16, characters: String = "") -> NSEvent {
      NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    func drag(_ start: CGPoint, _ end: CGPoint) {
      canvas.mouseDown(with: mouse(.leftMouseDown, start))
      canvas.mouseDragged(with: mouse(.leftMouseDragged, end))
      canvas.mouseUp(with: mouse(.leftMouseUp, end))
    }
  }

  func testFrameTitleDragTakesFocusFromInspectorSoEscapeReachesCanvas() throws {
    let f = try Fixture(); defer { f.close() }
    let field = NSTextField(frame: .init(x: 0, y: 0, width: 120, height: 24))
    f.scroll.addSubview(field); f.window.makeFirstResponder(field)
    XCTAssertFalse(f.window.firstResponder === f.canvas)
    let before = f.store.project
    let start = CGPoint(x: 40, y: -8 * 25.4 / 72), end = CGPoint(x: 55, y: 12)
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, start))
    XCTAssertTrue(f.window.firstResponder === f.canvas)
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, end))
    XCTAssertNotEqual(f.store.project, before)
    // Deliver through the actual first responder, as a keyboard event does.
    f.window.firstResponder?.keyDown(with: f.key(53))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, end))
    XCTAssertEqual(f.store.project, before)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testWindowDeactivationClearsSpaceEvenWhenCanvasRemainsFirstResponder() throws {
    let shape = ArtworkElement(kind: "rectangle", x: 20, y: 20, width: 60, height: 40)
    let f = try Fixture(elements: [shape]); defer { f.close() }
    f.session.choose([shape.id])
    f.canvas.keyDown(with: f.key(49, characters: " "))
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: f.window)
    XCTAssertTrue(f.window.firstResponder === f.canvas, "Losing key status does not resign the first responder")
    let visible = f.canvas.visibleCanvasRect
    f.drag(.init(x: 50, y: 40), .init(x: 60, y: 45))
    let moved = try XCTUnwrap(f.session.primary), bounds = f.session.art.bounds(of: moved)
    XCTAssertEqual(bounds.x, 30, accuracy: 0.000001)
    XCTAssertEqual(bounds.y, 25, accuracy: 0.000001)
    XCTAssertEqual(f.canvas.visibleCanvasRect.minX, visible.minX, accuracy: 0.000001)
    XCTAssertEqual(f.canvas.visibleCanvasRect.minY, visible.minY, accuracy: 0.000001)
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
  }

  func testWindowDeactivationCancelsAnActiveDragAndLatePointerEventsStayInert() throws {
    let shape = ArtworkElement(kind: "rectangle", x: 20, y: 20, width: 60, height: 40)
    let f = try Fixture(elements: [shape]); defer { f.close() }
    f.session.choose([shape.id])
    let before = f.store.project, start = CGPoint(x: 50, y: 40), end = CGPoint(x: 65, y: 50)
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, start))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, end))
    XCTAssertNotEqual(f.store.project, before)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: f.window)
    XCTAssertEqual(f.store.project, before)
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, .init(x: 80, y: 60)))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, end))
    XCTAssertEqual(f.store.project, before)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testSelectedResizeHandleOutsideFrameKeepsTheActiveSource() throws {
    let shape = ArtworkElement(kind: "rectangle", x: 85, y: 20, width: 40, height: 30)
    let f = try Fixture(elements: [shape]); defer { f.close() }
    f.session.choose([shape.id])
    let before = f.store.project
    f.drag(.init(x: 125, y: 50), .init(x: 135, y: 60))
    XCTAssertEqual(f.session.objectID, f.frameID)
    let resized = try XCTUnwrap(f.session.primary), bounds = f.session.art.bounds(of: resized)
    XCTAssertEqual(bounds.x, 85, accuracy: 0.000001); XCTAssertEqual(bounds.y, 20, accuracy: 0.000001)
    XCTAssertEqual(bounds.width, 50, accuracy: 0.000001); XCTAssertEqual(bounds.height, 40, accuracy: 0.000001)
    XCTAssertTrue(f.store.project!.canvasWorkspace!.artwork!.elements.isEmpty)
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    f.store.engine.undo(); XCTAssertEqual(f.store.project, before)
  }

  func testThinSelectedStrokeCanBeGrabbedWithinToleranceWithoutResizing() throws {
    var line = ArtworkElement(kind: "line", x: 20, y: 40, width: 60, height: 0.1)
    line.fillEnabled = false; line.stroke = .init(width: 0.5)
    let f = try Fixture(elements: [line]); defer { f.close() }
    f.session.choose([line.id])
    // One visual point outside the geometric bounds is still an easy stroke
    // grab, and must not become a top/bottom resize-handle hit.
    let start = CGPoint(x: 50, y: 40.05 + 25.4 / 72)
    f.drag(start, .init(x: start.x + 10, y: start.y + 5))
    let moved = try XCTUnwrap(f.session.primary), bounds = f.session.art.bounds(of: moved)
    XCTAssertEqual(bounds.x, 30, accuracy: 0.000001)
    XCTAssertEqual(bounds.y, 45, accuracy: 0.000001)
    XCTAssertEqual(bounds.width, 60, accuracy: 0.000001)
    XCTAssertEqual(bounds.height, 0.1, accuracy: 0.000001)
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
  }

  func testSelectedGradientEndpointOutsideFrameRemainsEditable() throws {
    var shape = ArtworkElement(kind: "rectangle", x: 20, y: 20, width: 50, height: 40)
    shape.gradient = .init(start: .init(-0.8, 0.5), end: .init(1, 0.5))
    let f = try Fixture(elements: [shape]); defer { f.close() }
    f.session.choose([shape.id])
    let before = f.store.project
    f.drag(.init(x: -20, y: 40), .init(x: -30, y: 50))
    XCTAssertEqual(f.session.objectID, f.frameID)
    let gradient = try XCTUnwrap(f.session.primary?.gradient)
    XCTAssertEqual(gradient.start.x, -1, accuracy: 0.000001)
    XCTAssertEqual(gradient.start.y, 0.75, accuracy: 0.000001)
    XCTAssertEqual(gradient.end, .init(1, 0.5))
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    f.store.engine.undo(); XCTAssertEqual(f.store.project, before)
  }

  func testSelectedGradientStopOutsideFrameRemainsEditable() throws {
    var shape = ArtworkElement(kind: "rectangle", x: 20, y: 20, width: 50, height: 40)
    shape.gradient = .init(start: .init(-0.8, 0.5), end: .init(1, 0.5))
    let f = try Fixture(elements: [shape]); defer { f.close() }
    f.session.choose([shape.id])
    let stopID = try XCTUnwrap(shape.gradient?.stops.first?.id)
    // Stops sit 12 visual points below the gradient axis at this zoom.
    f.drag(.init(x: -20, y: 40 + 12 * 25.4 / 72), .init(x: -10, y: 40 + 12 * 25.4 / 72))
    XCTAssertEqual(f.session.objectID, f.frameID)
    XCTAssertEqual(f.session.selectedGradientStopID, stopID)
    let stop = try XCTUnwrap(f.session.primary?.gradient?.stops.first { $0.id == stopID })
    XCTAssertEqual(stop.offset, 10.0 / 90, accuracy: 0.000001)
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
  }

  func testSelectedBezierTangentOutsideFrameRemainsEditable() throws {
    let first = BezierNode(.init(0, 0), outgoing: .init(-30, 15))
    var path = ArtworkElement(kind: "path", x: 10, y: 20, width: 60, height: 40)
    path.path = .init(width: 60, height: 40, contours: [.init([first, .init(.init(60, 40))], closed: false)])
    path.fillEnabled = false; path.stroke = .init(width: 0.5)
    let f = try Fixture(elements: [path]); defer { f.close() }
    f.session.tool = .direct; f.session.choose([path.id]); f.session.nodes = [first.id]
    let before = f.store.project
    f.drag(.init(x: -20, y: 35), .init(x: -30, y: 45))
    XCTAssertEqual(f.session.objectID, f.frameID)
    let edited = try XCTUnwrap(f.session.primary), geometry = try XCTUnwrap(edited.path)
    let node = try XCTUnwrap(geometry.contours.flatMap(\.nodes).first { $0.id == first.id })
    let transform = f.session.art.worldTransform(edited).followed(by: .scale(edited.width / geometry.width, edited.height / geometry.height))
    let tangent = transform.apply(try XCTUnwrap(node.outgoing))
    XCTAssertEqual(tangent.x, -30, accuracy: 0.000001)
    XCTAssertEqual(tangent.y, 45, accuracy: 0.000001)
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    f.store.engine.undo(); XCTAssertEqual(f.store.project, before)
  }
}

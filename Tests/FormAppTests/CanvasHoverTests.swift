import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasHoverTests: XCTestCase {
  @MainActor private final class Fixture {
    let root: URL, store: StudioStore, session: ArtworkSession, window: NSWindow
    let scroll: ArtworkScrollView, canvas: VectorCanvasView, shape: ArtworkElement
    init() throws {
      _ = NSApplication.shared
      root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-hover-" + UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
      var project = Project(name: "Canvas hover")
      _ = try project.ensureCanvasWorkspace()
      shape = ArtworkElement(kind: "rectangle", x: 20, y: 20, width: 40, height: 30)
      var frame = try project.makeObject(recipeID: "artboard", parameters: ["width": 100, "depth": 80])
      frame.artwork = Artwork(elements: [shape], bleed: 0); frame.artwork?.canvasPosition = .init()
      frame.artwork?.snapEnabled = false; project.objects.append(frame)
      project.schemaVersion = project.minimumSchemaVersion
      store.engine.project = project; store.showingHome = false; store.mode = .artwork
      session = store.artworkSession; session.activate(frame.id)
      window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 650),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      scroll = ArtworkScrollView(frame: window.contentView!.bounds)
      scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
      canvas = VectorCanvasView(frame: scroll.bounds); canvas.session = session; session.canvas = canvas
      scroll.documentView = canvas; window.contentView = scroll; window.makeFirstResponder(canvas)
      canvas.synchronize(); canvas.fit(all: true); canvas.setZoom(1)
    }
    func close() {
      window.contentView = nil; window.close(); store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    func event(_ point: CGPoint) -> NSEvent {
      NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(canvas.documentPoint(point), to: nil),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
    }
    func hover(_ point: CGPoint) { canvas.mouseMoved(with: event(point)) }
  }

  func testHoverPreviewsThePickedLayerWithoutChangingSelectionOrHistoryAndClearsOnExit() throws {
    let f = try Fixture(); defer { f.close() }
    let project = f.store.project, selection = f.session.selection
    f.hover(.init(x: 40, y: 35))
    XCTAssertEqual(f.canvas.hoveredElementID, f.shape.id)
    XCTAssertEqual(f.canvas.pointerFeedback, .arrow)
    XCTAssertEqual(f.session.selection, selection); XCTAssertEqual(f.store.project, project)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    f.canvas.mouseExited(with: f.event(.init(x: 40, y: 35)))
    XCTAssertNil(f.canvas.hoveredElementID); XCTAssertNil(f.canvas.hoveredControlPoint)
  }

  func testResizeAndRotationFeedbackUseTheExactVisibleSelectionHandles() throws {
    let f = try Fixture(); defer { f.close() }
    f.session.choose([f.shape.id])
    let baseline = f.store.project
    let points = [CGPoint(x: 20, y: 20), .init(x: 40, y: 20), .init(x: 60, y: 20), .init(x: 60, y: 35),
      .init(x: 60, y: 50), .init(x: 40, y: 50), .init(x: 20, y: 50), .init(x: 20, y: 35)]
    for (index, point) in points.enumerated() {
      f.hover(point)
      XCTAssertEqual(f.canvas.pointerFeedback, .resize(index))
      XCTAssertEqual(f.canvas.hoveredControlPoint, point)
    }
    let rotate = CGPoint(x: 40, y: 20 - 18 * 25.4 / 72)
    f.hover(rotate)
    XCTAssertEqual(f.canvas.pointerFeedback, .rotate)
    XCTAssertEqual(try XCTUnwrap(f.canvas.hoveredControlPoint).x, rotate.x, accuracy: 0.000001)
    f.hover(.init(x: 40, y: 35))
    XCTAssertEqual(f.canvas.pointerFeedback, .move); XCTAssertNil(f.canvas.hoveredControlPoint)
    XCTAssertEqual(f.store.project, baseline); XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testToolFeedbackAndWindowDeactivationDoNotLeaveHoverTargetsBehind() throws {
    let f = try Fixture(); defer { f.close() }
    f.hover(.init(x: 40, y: 35)); XCTAssertNotNil(f.canvas.hoveredElementID)
    f.session.tool = .text; f.hover(.init(x: 40, y: 35))
    XCTAssertEqual(f.canvas.pointerFeedback, .text); XCTAssertNil(f.canvas.hoveredElementID)
    f.session.tool = .hand; f.hover(.init(x: 40, y: 35))
    XCTAssertEqual(f.canvas.pointerFeedback, .hand)
    f.session.tool = .select; f.hover(.init(x: 40, y: 35))
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: f.window)
    XCTAssertNil(f.canvas.hoveredElementID); XCTAssertEqual(f.canvas.pointerFeedback, .arrow)
  }

  func testFloatingControlOcclusionSuppressesUnderlyingCanvasHover() throws {
    let f = try Fixture(); defer { f.close() }
    let location = f.event(.init(x: 40, y: 35)).locationInWindow
    f.hover(.init(x: 40, y: 35)); XCTAssertNotNil(f.canvas.hoveredElementID)
    let overlay = NSButton(frame: f.scroll.convert(.init(x: location.x - 15, y: location.y - 15, width: 30, height: 30), from: nil))
    f.scroll.addSubview(overlay)
    f.hover(.init(x: 40, y: 35))
    XCTAssertNil(f.canvas.hoveredElementID); XCTAssertNil(f.canvas.hoveredControlPoint)
    XCTAssertEqual(f.canvas.pointerFeedback, .arrow)
  }
}

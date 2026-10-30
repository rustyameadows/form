import AppKit
import FormCore
import XCTest
@testable import FormApp

/// Exercise the native event handlers in window coordinates. In particular,
/// pointer slop is a screen distance, not a physical document measurement.
@MainActor final class CanvasInteractionNavigationTests: XCTestCase {
  @MainActor private final class Fixture {
    let root: URL, store: StudioStore, session: ArtworkSession
    let window: NSWindow, scroll: ArtworkScrollView, canvas: VectorCanvasView
    let shapeID: UUID, workspaceID: UUID, frameID: UUID

    init(snapping: Bool = false) throws {
      _ = NSApplication.shared
      root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-interaction-" + UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
      var project = Project(name: "Canvas interaction regression")
      let workspace = try project.ensureCanvasWorkspace(); workspaceID = workspace.id
      let shape = ArtworkElement(kind: "rectangle", x: 20, y: 30, width: 80, height: 60)
      shapeID = shape.id
      project.objects[0].artwork?.elements = [shape]
      project.objects[0].artwork?.snapEnabled = snapping
      // A guide close to the starting top edge catches Shift locking before
      // snapping: a horizontal move must not be pulled two millimeters down.
      project.objects[0].artwork?.guides = [.init(axis: "y", position: 32)]
      var frame = try project.makeObject(recipeID: "artboard", name: "Frame", parameters: ["width": 100, "depth": 80])
      frame.artwork = Artwork(background: "#FFFFFF", bleed: 0)
      frame.artwork?.canvasPosition = .init(150, 130)
      frameID = frame.id; project.objects.append(frame)
      project.schemaVersion = project.minimumSchemaVersion
      store.engine.project = project; store.mode = .artwork; store.showingHome = false
      session = store.artworkSession; session.activate(workspaceID)
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
      canvas.finishText(); window.contentView = nil; window.close()
      store.engine.project = nil; try? FileManager.default.removeItem(at: root)
    }

    func location(_ world: CGPoint) -> CGPoint { canvas.convert(canvas.documentPoint(world), to: nil) }

    func mouse(_ type: NSEvent.EventType, at location: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    func key(_ code: UInt16, characters: String = "", type: NSEvent.EventType = .keyDown) -> NSEvent {
      NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)!
    }
  }

  private func assertPoint(_ actual: CGPoint, _ expected: CGPoint, accuracy: Double = 0.000001,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
  }

  func testClickJitterIsMeasuredInVisualPointsAndPreservesTheRedoBranch() throws {
    let f = try Fixture(); defer { f.close() }
    f.session.choose([f.shapeID]); f.session.translate(dx: 10, dy: 0); f.store.engine.undo()
    let before = try XCTUnwrap(f.store.project), redo = f.store.engine.redoStack
    for zoom in [0.25, 1.0, 4.0] {
      f.canvas.setZoom(zoom)
      let start = f.location(.init(x: 60, y: 60)), end = CGPoint(x: start.x + 2, y: start.y + 0.5)
      f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
      f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: end))
      f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: end))
      XCTAssertEqual(f.session.selection, [f.shapeID])
      XCTAssertEqual(f.store.project, before, "A click with two points of jitter must not move at zoom \(zoom)")
      XCTAssertTrue(f.store.engine.undoStack.isEmpty)
      XCTAssertEqual(f.store.engine.redoStack, redo)
    }
  }

  func testCrossingDragThresholdKeepsTheGrabPointAndMakesOneUndo() throws {
    let f = try Fixture(); defer { f.close() }
    let before = try XCTUnwrap(f.store.project)
    let start = f.location(.init(x: 60, y: 60)), jitter = CGPoint(x: start.x + 1, y: start.y)
    let end = CGPoint(x: start.x + 24, y: start.y - 12)
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: jitter))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: end))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: end))
    let element = try XCTUnwrap(f.session.primary)
    let bounds = f.session.art.bounds(of: element)
    XCTAssertEqual(bounds.x, 20 + 24 * 25.4 / 72, accuracy: 0.000001)
    XCTAssertEqual(bounds.y, 30 + 12 * 25.4 / 72, accuracy: 0.000001)
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    f.store.engine.undo(); XCTAssertEqual(f.store.project, before)
  }

  func testShiftHorizontalDragDoesNotSnapOntoNearbyVerticalOffset() throws {
    let f = try Fixture(snapping: true); defer { f.close() }
    f.canvas.setZoom(0.5) // Five visual points includes the two-millimeter guide.
    let start = f.location(.init(x: 60, y: 60)), end = f.location(.init(x: 80, y: 61))
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: end, modifiers: .shift))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: end, modifiers: .shift))
    let element = try XCTUnwrap(f.session.primary), bounds = f.session.art.bounds(of: element)
    XCTAssertEqual(bounds.x, 40, accuracy: 0.000001)
    XCTAssertEqual(bounds.y, 30, accuracy: 0.000001, "Snapping must respect the locked axis")
  }

  func testShiftDeselectingOneItemCannotDragTheRemainingSelection() throws {
    let f = try Fixture(); defer { f.close() }
    let other = ArtworkElement(kind: "ellipse", x: -80, y: 30, width: 60, height: 60)
    var project = try XCTUnwrap(f.store.project)
    project.objects[0].artwork?.elements.append(other)
    f.store.engine.project = project; f.canvas.synchronize()
    f.session.choose([f.shapeID, other.id])
    let before = try XCTUnwrap(f.store.project)
    let start = f.location(.init(x: 60, y: 60)), end = f.location(.init(x: 85, y: 60))
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start, modifiers: .shift))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: end, modifiers: .shift))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: end, modifiers: .shift))
    XCTAssertEqual(f.session.selection, [other.id])
    XCTAssertEqual(f.store.project, before)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testTinySelectedObjectCanBeGrabbedAtItsCenterWhenHandlesOverlap() throws {
    let f = try Fixture(); defer { f.close() }
    var project = try XCTUnwrap(f.store.project)
    project.objects[0].artwork?.elements[0].width = 2
    project.objects[0].artwork?.elements[0].height = 2
    f.store.engine.project = project; f.canvas.synchronize(); f.canvas.setZoom(0.25)
    f.session.choose([f.shapeID])
    let start = f.location(.init(x: 21, y: 31)), end = CGPoint(x: start.x + 12, y: start.y - 8)
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: end))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: end))
    let element = try XCTUnwrap(f.session.primary), bounds = f.session.art.bounds(of: element)
    XCTAssertEqual(bounds.width, 2, accuracy: 0.000001)
    XCTAssertEqual(bounds.height, 2, accuracy: 0.000001)
    XCTAssertEqual(bounds.x, 20 + 12 * 25.4 / (72 * 0.25), accuracy: 0.000001)
    XCTAssertEqual(bounds.y, 30 + 8 * 25.4 / (72 * 0.25), accuracy: 0.000001)
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
  }

  func testEscapeCancelsAnActiveMoveAndIgnoresTheRemainderOfThePointerGesture() throws {
    let f = try Fixture(); defer { f.close() }
    f.session.choose([f.shapeID]); f.session.translate(dx: 10, dy: 0); f.store.engine.undo()
    let before = try XCTUnwrap(f.store.project), redo = f.store.engine.redoStack
    let start = f.location(.init(x: 60, y: 60)), end = f.location(.init(x: 85, y: 75))
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: end))
    XCTAssertNotEqual(f.store.project, before)
    f.canvas.keyDown(with: f.key(53))
    XCTAssertEqual(f.store.project, before)
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: f.location(.init(x: 100, y: 85))))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: end))
    XCTAssertEqual(f.store.project, before)
    XCTAssertEqual(f.session.selection, [f.shapeID])
    XCTAssertTrue(f.store.engine.undoStack.isEmpty); XCTAssertEqual(f.store.engine.redoStack, redo)
  }

  func testEscapeCancelsShapeCreationIncludingTheInitialMouseDownMutation() throws {
    let f = try Fixture(); defer { f.close() }
    let before = try XCTUnwrap(f.store.project)
    f.session.tool = .rectangle
    let start = f.location(.init(x: -50, y: -50)), end = f.location(.init(x: -20, y: -20))
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: end))
    XCTAssertEqual(f.session.art.elements.count, 2)
    f.canvas.keyDown(with: f.key(53))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: end))
    XCTAssertEqual(f.store.project, before)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testStalePointerGestureCannotOverwriteAnUnrelatedCommand() throws {
    let f = try Fixture(); defer { f.close() }
    let start = f.location(.init(x: 60, y: 60)), end = f.location(.init(x: 85, y: 75))
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: end))
    try f.store.engine.edit("Independent layer change") { project in
      project.objects[0].artwork?.elements[0].color = "#336699"
    }
    let before = try XCTUnwrap(f.store.project), undo = f.store.engine.undoStack
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: f.location(.init(x: 95, y: 85))))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: end))
    XCTAssertEqual(f.store.project, before)
    XCTAssertEqual(f.store.engine.undoStack, undo)
  }

  func testLateEscapeCannotRestoreAnOldGestureOverAnIndependentRedoBranch() throws {
    let f = try Fixture(); defer { f.close() }
    let start = f.location(.init(x: 60, y: 60)), end = f.location(.init(x: 85, y: 75))
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: end))
    try f.store.engine.edit("Independent change") { $0.subtitle = "Redo this later" }
    f.store.engine.undo()
    let before = try XCTUnwrap(f.store.project), undo = f.store.engine.undoStack, redo = f.store.engine.redoStack
    f.canvas.keyDown(with: f.key(53))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: end))
    XCTAssertEqual(f.store.project, before)
    XCTAssertEqual(f.store.engine.undoStack, undo); XCTAssertEqual(f.store.engine.redoStack, redo)
    f.store.engine.redo(); XCTAssertEqual(f.store.project?.subtitle, "Redo this later")
  }

  func testSwitchingArtworkSourceDuringDragPreservesBothSourcesAndIgnoresLateEvents() throws {
    let f = try Fixture(); defer { f.close() }
    let destinationShape = ArtworkElement(kind: "ellipse", x: 10, y: 15, width: 25, height: 20, color: "#336699")
    var initial = try XCTUnwrap(f.store.project)
    let destinationIndex = try XCTUnwrap(initial.objects.firstIndex { $0.id == f.frameID })
    initial.objects[destinationIndex].artwork?.elements = [destinationShape]
    f.store.engine.project = initial; f.canvas.synchronize()
    let start = f.location(.init(x: 60, y: 60)), end = f.location(.init(x: 85, y: 75))
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: end))
    XCTAssertNotEqual(f.store.project, initial)
    f.session.activate(f.frameID); f.canvas.synchronize()
    let afterSwitch = try XCTUnwrap(f.store.project), undo = f.store.engine.undoStack
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: f.location(.init(x: 100, y: 90))))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: end))
    XCTAssertEqual(f.session.objectID, f.frameID)
    XCTAssertEqual(f.store.project, afterSwitch, "A stale workspace drag must not write its snapshot into the newly active frame")
    XCTAssertEqual(f.store.project?.objects[destinationIndex].artwork, initial.objects[destinationIndex].artwork)
    XCTAssertEqual(f.store.engine.undoStack, undo)
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    f.store.engine.undo(); XCTAssertEqual(f.store.project, initial)
  }

  func testEscapeCancelsAFrameTitleDrag() throws {
    let f = try Fixture(); defer { f.close() }
    let before = try XCTUnwrap(f.store.project)
    let start = f.location(.init(x: 190, y: 130 - 8 * 25.4 / 72))
    let end = CGPoint(x: start.x + 40, y: start.y - 20)
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: end))
    XCTAssertNotEqual(f.store.project, before)
    f.canvas.keyDown(with: f.key(53))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: end))
    XCTAssertEqual(f.store.project, before)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testHandPanTakesKeyboardFocusWithoutCreatingAnArtworkEdit() throws {
    let f = try Fixture(); defer { f.close() }
    let field = NSTextField(frame: .init(x: 0, y: 0, width: 100, height: 24))
    f.scroll.addSubview(field); f.window.makeFirstResponder(field)
    XCTAssertFalse(f.window.firstResponder === f.canvas)
    f.session.tool = .hand
    let visible = f.canvas.visibleCanvasRect
    let before = try XCTUnwrap(f.store.project), start = f.location(.init(x: visible.midX, y: visible.midY))
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
    XCTAssertTrue(f.window.firstResponder === f.canvas)
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: start))
    XCTAssertEqual(f.store.project, before); XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testAnchoredZoomKeepsThePointerWorldPointStationaryAcrossExtentGrowth() throws {
    let f = try Fixture(); defer { f.close() }
    let before = try XCTUnwrap(f.store.project)
    f.canvas.setFrameOrigin(.init(x: -130, y: 75))
    let visible = f.canvas.visibleCanvasRect
    let anchor = CGPoint(x: visible.minX + visible.width * 0.21, y: visible.minY + visible.height * 0.73)
    let screen = f.location(anchor)
    for zoom in [0.08, 0.25, 2.0, 24.0, 1.0] {
      f.canvas.setZoom(zoom, atCanvasPoint: anchor)
      assertPoint(f.location(anchor), screen)
      let actual = f.canvas.convert(f.scroll.contentView.bounds, from: f.scroll.contentView)
      XCTAssertTrue(f.canvas.bounds.insetBy(dx: -0.001, dy: -0.001).contains(actual))
    }
    XCTAssertEqual(f.store.project, before); XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testHeldPointerAtTheEdgeScrollsArtworkWithTheViewportAsOneUndo() async throws {
    let f = try Fixture(); defer { f.close() }
    let before = try XCTUnwrap(f.store.project)
    let start = f.location(.init(x: 60, y: 60))
    let viewport = f.scroll.convert(f.scroll.bounds, to: nil)
    let edge = CGPoint(x: viewport.maxX - 2, y: start.y)
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: edge))
    let initialViewport = f.canvas.visibleCanvasRect
    let initial = try XCTUnwrap(f.session.primary), initialBounds = f.session.art.bounds(of: initial)
    // No additional mouseDragged event arrives while the pointer is held still.
    try await Task.sleep(nanoseconds: 100_000_000)
    let scrolledViewport = f.canvas.visibleCanvasRect
    let moved = try XCTUnwrap(f.session.primary), movedBounds = f.session.art.bounds(of: moved)
    XCTAssertGreaterThan(scrolledViewport.minX, initialViewport.minX)
    XCTAssertGreaterThan(movedBounds.x, initialBounds.x)
    XCTAssertEqual(movedBounds.x - initialBounds.x, scrolledViewport.minX - initialViewport.minX, accuracy: 0.000001)
    let grabPoint = f.session.art.worldTransform(moved).apply(.init(40, 30))
    assertPoint(f.location(.init(x: grabPoint.x, y: grabPoint.y)), edge, accuracy: 0.000001)
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: edge))
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    let stopped = f.canvas.visibleCanvasRect
    try await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(f.canvas.visibleCanvasRect, stopped)
    f.store.engine.undo(); XCTAssertEqual(f.store.project, before)
  }

  func testEscapeStopsHeldEdgeScrollingAndRestoresTheOriginalArtwork() async throws {
    let f = try Fixture(); defer { f.close() }
    let before = try XCTUnwrap(f.store.project)
    let start = f.location(.init(x: 60, y: 60)), viewport = f.scroll.convert(f.scroll.bounds, to: nil)
    let edge = CGPoint(x: viewport.maxX - 2, y: start.y)
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, at: start))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: edge))
    let initialViewport = f.canvas.visibleCanvasRect
    try await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertGreaterThan(f.canvas.visibleCanvasRect.minX, initialViewport.minX)
    f.canvas.keyDown(with: f.key(53))
    XCTAssertEqual(f.store.project, before)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    let stopped = f.canvas.visibleCanvasRect
    try await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(f.canvas.visibleCanvasRect, stopped)
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, at: edge))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, at: edge))
    XCTAssertEqual(f.store.project, before)
    XCTAssertEqual(f.canvas.visibleCanvasRect, stopped)
  }
}

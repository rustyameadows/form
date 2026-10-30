import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class CanvasViewportTests: XCTestCase {
  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func fixture() async throws -> (StudioStore, NSWindow, NSScrollView, VectorCanvasView) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-viewport-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    store.engine.project = try PaperSamples.sunStudies()
    let id = try XCTUnwrap(store.project?.objects.first { PaperConstruction.isPaper($0) }?.id)
    _ = try store.engine.call("form_construction", arguments: ["command": "convert", "object_id": id.uuidString])
    let construction = try XCTUnwrap(store.project?.objects.first { $0.id == id })
    store.showingHome = false; store.mode = .artwork
    store.select(id); store.activatePaperArtwork(construction)
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 940, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: VectorCanvas(session: store.artworkSession, revision: store.revision))
    window.contentView = host
    addTeardownBlock { @MainActor in
      store.artworkSession.canvas?.finishText()
      window.contentView = nil; window.close()
      store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      if descendants(host).contains(where: { $0 is ArtworkScrollView }) { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? ArtworkScrollView }.first)
    let canvas = try XCTUnwrap(scroll.documentView as? VectorCanvasView)
    canvas.synchronize(); scroll.tile()
    return (store, window, scroll, canvas)
  }

  private func assertPoint(_ actual: CGPoint, _ expected: CGPoint,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001, file: file, line: line)
    XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001, file: file, line: line)
  }

  private func fittedViewport(_ canvas: VectorCanvasView) throws -> CGRect {
    let diagnostics = try XCTUnwrap(canvas.diagnostics["viewport"] as? [String: Any])
    let rect = try XCTUnwrap(diagnostics["unobscured_clip_points"] as? [String: Any])
    return CGRect(x: try XCTUnwrap(rect["x"] as? Double), y: try XCTUnwrap(rect["y"] as? Double),
      width: try XCTUnwrap(rect["width"] as? Double), height: try XCTUnwrap(rect["height"] as? Double))
  }

  private func assertFullClipCovered(_ canvas: VectorCanvasView, scroll: NSScrollView,
    file: StaticString = #filePath, line: UInt = #line) {
    let actual = canvas.convert(scroll.contentView.bounds, from: scroll.contentView)
    XCTAssertTrue(canvas.bounds.insetBy(dx: -0.001, dy: -0.001).contains(actual),
      "Document \(canvas.bounds) leaves native clip \(actual) outside the Canvas", file: file, line: line)
  }

  private func center(_ rect: CGRect) -> CGPoint { .init(x: rect.midX, y: rect.midY) }

  func testActualCanvasHasNoNativeRulerOrBorderGuttersAndRetainsPhysicalFit() async throws {
    let (store, _, scroll, canvas) = try await fixture()
    let before = try XCTUnwrap(store.project), undoCount = store.engine.undoStack.count
    XCTAssertFalse(scroll.rulersVisible)
    XCTAssertFalse(scroll.hasHorizontalRuler); XCTAssertFalse(scroll.hasVerticalRuler)
    XCTAssertFalse(descendants(scroll).contains { $0 is NSRulerView && !$0.isHiddenOrHasHiddenAncestor })
    XCTAssertEqual(scroll.borderType, .noBorder)
    XCTAssertEqual(scroll.scrollerStyle, .overlay)
    XCTAssertEqual(scroll.horizontalScrollElasticity, .none)
    XCTAssertEqual(scroll.verticalScrollElasticity, .none)
    XCTAssertFalse(scroll.usesPredominantAxisScrolling)
    XCTAssertFalse(scroll.automaticallyAdjustsContentInsets)
    XCTAssertEqual(scroll.contentInsets.top, 0); XCTAssertEqual(scroll.contentInsets.left, 0)
    XCTAssertEqual(scroll.contentInsets.bottom, 0); XCTAssertEqual(scroll.contentInsets.right, 0)
    let clip = scroll.convert(scroll.contentView.bounds, from: scroll.contentView)
    XCTAssertEqual(clip.minX, scroll.bounds.minX, accuracy: 0.001)
    XCTAssertEqual(clip.minY, scroll.bounds.minY, accuracy: 0.001)
    XCTAssertEqual(clip.width, scroll.bounds.width, accuracy: 0.001)
    XCTAssertEqual(clip.height, scroll.bounds.height, accuracy: 0.001)
    canvas.fit(all: true)
    let frames = store.artworkSession.frames.filter { !$0.isWorkspace }
    XCTAssertGreaterThan(frames.count, 3)
    for frame in frames {
      XCTAssertTrue(canvas.visibleCanvasRect.insetBy(dx: -0.0001, dy: -0.0001).contains(frame.rect))
    }
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(store.engine.undoStack.count, undoCount)
  }

  func testZoomAndDropCoordinateRoundTripsKeepTheVisibleAnchorAfterNativeOriginShiftAndPan() async throws {
    let (store, _, scroll, canvas) = try await fixture()
    let before = try XCTUnwrap(store.project), undoCount = store.engine.undoStack.count
    for origin in [CGPoint.zero, CGPoint(x: -150, y: 60), CGPoint(x: 130, y: -90)] {
      canvas.setFrameOrigin(origin); canvas.fit(all: true)
      scroll.contentView.scroll(to: .init(x: scroll.contentView.bounds.minX + 45,
        y: scroll.contentView.bounds.minY + 25))
      scroll.reflectScrolledClipView(scroll.contentView)
      let visible = canvas.visibleCanvasRect
      let anchor = CGPoint(x: visible.midX, y: visible.midY)
      canvas.setZoom(canvas.zoom * 1.25)
      let zoomed = canvas.visibleCanvasRect
      assertPoint(CGPoint(x: zoomed.midX, y: zoomed.midY), anchor)
      for point in [anchor, CGPoint(x: -37.25, y: 82.5)] {
        // Native mouse/drop locations arrive in window coordinates.
        let windowPoint = canvas.convert(canvas.documentPoint(point), to: nil)
        assertPoint(canvas.canvasPoint(canvas.convert(windowPoint, from: nil)), point)
      }
      let topLeft = scroll.contentView.convert(scroll.contentView.bounds.origin, to: nil)
      assertPoint(canvas.canvasPoint(canvas.convert(topLeft, from: nil)), canvas.visibleCanvasRect.origin)
      canvas.fit(all: true)
      for frame in store.artworkSession.frames where !frame.isWorkspace {
        XCTAssertTrue(canvas.visibleCanvasRect.insetBy(dx: -0.0001, dy: -0.0001).contains(frame.rect))
      }
    }
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(store.engine.undoStack.count, undoCount)
  }

  func testFitAvoidsTransientFloatingPanelsWithoutChangingDocumentOrNativeContentInsets() async throws {
    let (store, window, scroll, canvas) = try await fixture()
    let before = try XCTUnwrap(store.project), undoCount = store.engine.undoStack.count
    canvas.fittingInsets = NSEdgeInsets(top: 70, left: 160, bottom: 72, right: 210)
    for origin in [CGPoint.zero, CGPoint(x: -120, y: 75)] {
      canvas.setFrameOrigin(origin); canvas.fit(all: true)
      let viewport = try fittedViewport(canvas), clip = scroll.contentView
      let pointScale: CGFloat = 72 / 25.4
      for frame in store.artworkSession.frames where !frame.isWorkspace {
        let document = CGRect(origin: canvas.documentPoint(frame.rect.origin),
          size: .init(width: frame.rect.width * pointScale, height: frame.rect.height * pointScale))
        let actual = clip.convert(document, from: canvas)
        XCTAssertTrue(viewport.insetBy(dx: -0.001, dy: -0.001).contains(actual),
          "Floating panels obscure fitted physical frame \(actual) in \(viewport)")
      }
      XCTAssertEqual(scroll.contentInsets.top, 0); XCTAssertEqual(scroll.contentInsets.left, 0)
      XCTAssertEqual(scroll.contentInsets.bottom, 0); XCTAssertEqual(scroll.contentInsets.right, 0)
    }
    window.setContentSize(.init(width: 440, height: 500))
    window.contentView?.layoutSubtreeIfNeeded(); scroll.tile()
    canvas.fittingInsets = NSEdgeInsets(top: 900, left: 900, bottom: 900, right: 900)
    canvas.fit(all: true)
    let reduced = try fittedViewport(canvas)
    XCTAssertGreaterThan(reduced.width, 0); XCTAssertGreaterThan(reduced.height, 0)
    XCTAssertTrue(scroll.magnification.isFinite)
    XCTAssertGreaterThanOrEqual(scroll.magnification, scroll.minMagnification)
    XCTAssertLessThanOrEqual(scroll.magnification, scroll.maxMagnification)
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(store.engine.undoStack.count, undoCount)
  }

  func testPaperFloatingFitCoversWholeNativeViewportAndRoutesWhitespaceAfterZoomAndResize() async throws {
    let (store, window, scroll, canvas) = try await fixture()
    window.setContentSize(.init(width: 1020, height: 817))
    window.contentView?.layoutSubtreeIfNeeded()
    canvas.fittingInsets = NSEdgeInsets(top: 16, left: 266, bottom: 72, right: 318)
    let before = try XCTUnwrap(store.project), undoCount = store.engine.undoStack.count
    for origin in [CGPoint.zero, CGPoint(x: -130, y: 75)] {
      canvas.setFrameOrigin(origin); canvas.fit(all: true)
      assertFullClipCovered(canvas, scroll: scroll)
      let viewport = try fittedViewport(canvas)
      for frame in store.artworkSession.frames where !frame.isWorkspace {
        let document = CGRect(origin: canvas.documentPoint(frame.rect.origin),
          size: .init(width: frame.rect.width * 72 / 25.4, height: frame.rect.height * 72 / 25.4))
        XCTAssertTrue(viewport.insetBy(dx: -0.001, dy: -0.001)
          .contains(scroll.contentView.convert(document, from: canvas)))
      }
      let host = try XCTUnwrap(window.contentView)
      for fraction in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.04, y: 0.94), CGPoint(x: 0.96, y: 0.94)] {
        let p = CGPoint(x: scroll.bounds.minX + scroll.bounds.width * fraction.x,
          y: scroll.bounds.minY + scroll.bounds.height * fraction.y)
        let actual = host.hitTest(scroll.convert(p, to: host.superview))
        XCTAssertTrue(actual === canvas || actual?.isDescendant(of: canvas) == true,
          "Native whitespace hit \(String(describing: actual)) bypassed Canvas")
      }
    }
    let anchor = center(canvas.visibleCanvasRect)
    canvas.setZoom(0.08)
    assertFullClipCovered(canvas, scroll: scroll)
    assertPoint(center(canvas.visibleCanvasRect), anchor)
    let resizeAnchor = center(canvas.visibleCanvasRect)
    window.setContentSize(.init(width: 1280, height: 940))
    window.contentView?.layoutSubtreeIfNeeded(); scroll.layout()
    assertFullClipCovered(canvas, scroll: scroll)
    assertPoint(center(canvas.visibleCanvasRect), resizeAnchor)
    let stableFrame = canvas.frame
    for _ in 0..<8 { scroll.layout() }
    XCTAssertEqual(canvas.frame, stableFrame, "Repeated layout must not keep expanding the native document")
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(store.engine.undoStack.count, undoCount)
  }

  func testViewportExpansionKeepsNativeTextHostAndMarkedInputAnchoredWithoutSourceChanges() async throws {
    let (store, window, scroll, canvas) = try await fixture()
    var project = try XCTUnwrap(store.project)
    let workspace = try project.ensureCanvasWorkspace()
    let index = try XCTUnwrap(project.objects.firstIndex { $0.id == workspace.id })
    let element = ArtworkElement(kind: "text", x: -40, y: -25, width: 80, height: 24,
      text: "Viewport text", fontSize: 16)
    project.objects[index].artwork?.elements = [element]
    store.engine.project = project
    store.artworkSession.activate(workspace.id); canvas.synchronize(); canvas.fit(all: true)
    canvas.beginText(element)
    let text = try XCTUnwrap(descendants(canvas).compactMap { $0 as? CanvasTextView }.first)
    text.setMarkedText("仮", selectedRange: .init(location: 1, length: 0),
      replacementRange: .init(location: NSNotFound, length: 0))
    XCTAssertTrue(text.hasMarkedText())
    let before = try XCTUnwrap(store.project), undoCount = store.engine.undoStack.count
    let anchor = canvas.canvasPoint(text.convert(.zero, to: canvas))
    let marked = text.markedRange(), selected = text.selectedRange(), size = text.frame.size
    let responder = window.firstResponder
    let originalOrigin = canvas.canvasOrigin
    canvas.setZoom(0.08)
    assertFullClipCovered(canvas, scroll: scroll)
    XCTAssertNotEqual(canvas.canvasOrigin, originalOrigin)
    XCTAssertTrue(descendants(canvas).contains { $0 === text })
    XCTAssertTrue(window.firstResponder === responder)
    assertPoint(canvas.canvasPoint(text.convert(.zero, to: canvas)), anchor)
    XCTAssertEqual(text.markedRange(), marked)
    XCTAssertEqual(text.selectedRange(), selected)
    XCTAssertEqual(text.frame.size, size)
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(store.engine.undoStack.count, undoCount)
  }

  func testNativeHandPanKeepsExpectedWorldPositionAcrossShiftedOriginAndExtentGrowth() async throws {
    let (store, window, scroll, canvas) = try await fixture()
    canvas.fit(all: true)
    canvas.setFrameOrigin(.init(x: -130, y: 75))
    store.artworkSession.tool = .hand
    let before = try XCTUnwrap(store.project), undoCount = store.engine.undoStack.count
    let viewport = canvas.visibleCanvasRect, originalOrigin = canvas.canvasOrigin
    let clip = scroll.contentView
    let down = clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
    let scale = CGFloat(canvas.zoom) * 72 / 25.4
    let documentMinimum=canvas.canvasPoint(.init(x:canvas.bounds.minX,y:canvas.bounds.minY))
    // Both-face layouts may already allocate more view extent. Place the desired
    // viewport beyond its current physical minimum to guarantee real growth.
    let destination=CGPoint(x:documentMinimum.x-160,y:documentMinimum.y-160)
    let delta=CGPoint(x:(viewport.minX-destination.x)*scale,y:(destination.y-viewport.minY)*scale)
    let end = CGPoint(x: down.x + delta.x, y: down.y + delta.y)
    let expected = CGPoint(x: viewport.minX - delta.x / scale,
      y: viewport.minY + delta.y / scale)
    let host = try XCTUnwrap(window.contentView)
    let hit = host.hitTest(host.superview?.convert(down, from: nil) ?? down)
    XCTAssertTrue(hit === canvas)
    func event(_ kind: NSEvent.EventType, at point: CGPoint, number: Int) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: number, clickCount: 1, pressure: kind == .leftMouseUp ? 0 : 1))
    }
    // Dispatch through the actual window hit view; subsequent drag/up belong to
    // the same held Canvas gesture, including after native extent expansion.
    hit?.mouseDown(with: try event(.leftMouseDown, at: down, number: 1))
    canvas.mouseDragged(with: try event(.leftMouseDragged, at: end, number: 2))
    canvas.mouseUp(with: try event(.leftMouseUp, at: end, number: 3))
    XCTAssertNotEqual(canvas.canvasOrigin, originalOrigin)
    assertPoint(canvas.visibleCanvasRect.origin, expected)
    assertFullClipCovered(canvas, scroll: scroll)
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(store.engine.undoStack.count, undoCount)
  }
}

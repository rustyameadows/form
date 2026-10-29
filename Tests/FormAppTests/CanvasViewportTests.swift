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

  func testActualCanvasHasNoNativeRulerOrBorderGuttersAndRetainsPhysicalFit() async throws {
    let (store, _, scroll, canvas) = try await fixture()
    let before = try XCTUnwrap(store.project), undoCount = store.engine.undoStack.count
    XCTAssertFalse(scroll.rulersVisible)
    XCTAssertFalse(scroll.hasHorizontalRuler); XCTAssertFalse(scroll.hasVerticalRuler)
    XCTAssertFalse(descendants(scroll).contains { $0 is NSRulerView && !$0.isHiddenOrHasHiddenAncestor })
    XCTAssertEqual(scroll.borderType, .noBorder)
    XCTAssertEqual(scroll.scrollerStyle, .overlay)
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
}

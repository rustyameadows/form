import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasFitBoundsTests: XCTestCase {
  private func fixture() throws -> (StudioStore, NSWindow, NSScrollView, VectorCanvasView) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-fit-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    store.engine.project = try PaperSamples.sunStudies()
    let id = try XCTUnwrap(store.project?.objects.first { PaperConstruction.isPaper($0) }?.id)
    _ = try store.engine.call("form_construction", arguments: ["command": "convert", "object_id": id.uuidString])
    let construction = try XCTUnwrap(store.project?.objects.first { $0.id == id })
    store.showingHome = false; store.mode = .artwork
    store.select(id); store.activatePaperArtwork(construction)
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1200, height: 800),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = ArtworkScrollView(frame: .init(x: 210, y: 0, width: 940, height: 720))
    scroll.clipsToBounds = true; scroll.contentView.clipsToBounds = true
    scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true; scroll.allowsMagnification = true
    scroll.minMagnification = 0.08; scroll.maxMagnification = 24
    let canvas = VectorCanvasView()
    canvas.clipsToBounds = true; scroll.documentView = canvas
    canvas.session = store.artworkSession; store.artworkSession.canvas = canvas
    scroll.hasHorizontalRuler = true; scroll.hasVerticalRuler = true
    scroll.horizontalRulerView = ArtworkRuler(scrollView: scroll, orientation: .horizontalRuler)
    scroll.verticalRulerView = ArtworkRuler(scrollView: scroll, orientation: .verticalRuler)
    scroll.rulersVisible = true
    window.contentView?.addSubview(scroll); window.contentView?.layoutSubtreeIfNeeded()
    canvas.synchronize(); scroll.tile()
    addTeardownBlock { @MainActor in
      canvas.finishText(); window.contentView = nil; window.close()
      store.engine.project = nil; try? FileManager.default.removeItem(at: root)
    }
    return (store, window, scroll, canvas)
  }

  private func assertContains(_ expected: CGRect, canvas: VectorCanvasView,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(canvas.visibleCanvasRect.insetBy(dx: -0.0001, dy: -0.0001).contains(expected),
      "Visible \(canvas.visibleCanvasRect) clips expected \(expected)", file: file, line: line)
    guard let scroll = canvas.enclosingScrollView, scroll.rulersVisible else { return }
    let document = CGRect(origin: canvas.documentPoint(expected.origin),
      size: .init(width: expected.width * 72 / 25.4, height: expected.height * 72 / 25.4))
    for ruler in [scroll.horizontalRulerView, scroll.verticalRulerView].compactMap({ $0 })
    where !ruler.isHiddenOrHasHiddenAncestor {
      let covered = canvas.convert(ruler.visibleRect, from: ruler)
      XCTAssertFalse(document.intersects(covered),
        "Ruler \(covered) covers part of fitted content \(document)", file: file, line: line)
    }
  }

  func testFitContainsWholeAuthoredNetAndEveryUprightFrameAfterNativeDocumentOffsetsAndPanOnly() throws {
    let (store, _, scroll, canvas) = try fixture()
    let before = try XCTUnwrap(store.project), undoCount = store.engine.undoStack.count
    let projections = store.artworkSession.frames.filter { $0.projection != nil }
    XCTAssertTrue(projections.contains { $0.projection?.isProof == true })
    XCTAssertGreaterThan(projections.filter { $0.projection?.panelID != nil }.count, 2)
    for origin in [CGPoint.zero, CGPoint(x: -150, y: 60), CGPoint(x: 130, y: -90)] {
      canvas.setFrameOrigin(origin)
      canvas.fit(all: true)
      for frame in projections { assertContains(frame.rect, canvas: canvas) }
      let fittedZoom = scroll.magnification
      // Preserve exactly the fitted magnification; refit must restore position.
      scroll.contentView.scroll(to: .init(x: scroll.contentView.bounds.minX + 220,
        y: scroll.contentView.bounds.minY + 80))
      scroll.reflectScrolledClipView(scroll.contentView)
      XCTAssertFalse(canvas.visibleCanvasRect.contains(canvas.contentBounds(all: true)))
      store.artworkSession.fit()
      XCTAssertEqual(scroll.magnification, fittedZoom, accuracy: 0.000001)
      for frame in projections { assertContains(frame.rect, canvas: canvas) }
    }
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(store.engine.undoStack.count, undoCount)
  }

  func testPendingPaperPanelFocusFitsThePhysicalPanelInShiftedNativeDocument() async throws {
    let (store, _, _, canvas) = try fixture(), session = store.artworkSession
    let proof = try XCTUnwrap(session.frames.first { $0.projection?.isProof == true })
    session.activate(proof.id); canvas.synchronize(); canvas.fit(all: true)
    let construction = try XCTUnwrap(session.paperContext)
    let panel = try XCTUnwrap(PaperConstruction.definition(for: construction).net().panels.first { $0.id == "front" })
    let bounds = panel.bounds
    let expected = CGRect(x: proof.rect.minX + bounds.x, y: proof.rect.minY + bounds.y,
      width: bounds.width, height: bounds.height)
    let before = try XCTUnwrap(store.project), undoCount = store.engine.undoStack.count
    canvas.setFrameOrigin(.init(x: -180, y: 85))
    session.paperFocusPanelID = panel.id
    canvas.viewDidMoveToWindow()
    for _ in 0..<100 {
      if session.paperFocusPanelID == nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertNil(session.paperFocusPanelID)
    assertContains(expected, canvas: canvas)
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(store.engine.undoStack.count, undoCount)
  }

  func testNativeRulerOverlaysLeaveTheWholeTallArtboardMarginVisible() throws {
    let (store, _, scroll, canvas) = try fixture()
    var project = try XCTUnwrap(store.project)
    var artboard = try project.makeObject(recipeID: "artboard", parameters: ["width": 700, "depth": 750])
    artboard.artwork = Artwork(background: "#FFFFFF", elements: [
      .init(kind: "rectangle", x: 80, y: 80, width: 500, height: 550)
    ])
    project.objects.append(artboard); store.engine.project = project; canvas.synchronize()
    let before = try XCTUnwrap(store.project), undoCount = store.engine.undoStack.count
    let frame = try XCTUnwrap(store.artworkSession.frames.first { $0.id == artboard.id })
    XCTAssertEqual(frame.rect.minY, 40)
    let horizontal = try XCTUnwrap(scroll.horizontalRulerView), vertical = try XCTUnwrap(scroll.verticalRulerView)
    XCTAssertTrue(scroll.contentView.convert(horizontal.bounds, from: horizontal).intersects(scroll.contentView.bounds),
      "The actual AppKit ruler must overlap the clip view for this regression.")
    for rulersVisible in [true, false, true] {
      scroll.rulersVisible = rulersVisible; scroll.tile()
      canvas.fit(all: true)
      for frame in store.artworkSession.frames where !frame.isWorkspace { assertContains(frame.rect, canvas: canvas) }
    }
    // Also support custom/native layouts whose rulers occupy separate bands.
    horizontal.setFrameOrigin(.init(x: 0, y: -horizontal.frame.height - 20))
    vertical.setFrameOrigin(.init(x: -vertical.frame.width - 20, y: 0))
    canvas.fit(all: true)
    for frame in store.artworkSession.frames where !frame.isWorkspace { assertContains(frame.rect, canvas: canvas) }
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(store.engine.undoStack.count, undoCount)
  }
}

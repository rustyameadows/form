import AppKit
import FormCore
import FormGraphics
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class UnifiedDesignSurfaceHostTests: XCTestCase {
  private func fixture() throws -> (StudioStore, NSWindow, NSHostingView<AnyView>, UUID, ArtworkElement) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("unified-design-host-" + UUID().uuidString)
    let repository = try ProjectRepository(root: root)
    var project = Project(name: "One Canvas and one Table")
    let text = ArtworkElement(kind: "text", x: 15, y: 20, width: 100, height: 35, text: "A persistent editor")
    var artboard = try project.makeObject(recipeID: "artboard")
    artboard.artwork = Artwork(elements: [text])
    project.objects = [try project.makeObject(recipeID: "box"), artboard]
    _ = try project.ensureCanvasWorkspace(); project.schemaVersion = project.minimumSchemaVersion
    try repository.save(project)
    let store = StudioStore(repository: repository, seedLibrary: false)
    try store.engine.open(project.id); store.showingHome = false
    store.artworkSession.activate(artboard.id); store.showSurface(.artwork)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSHostingView(rootView: AnyView(DesignSurfaceWorkspace(store: store)))
    window.contentView = view
    addTeardownBlock { @MainActor in
      store.closeDetachedCanvas(); window.contentView = nil; window.close(); store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    settle(view)
    return (store, window, view, artboard.id, text)
  }
  private func settle(_ view: NSView) {
    for _ in 0..<8 { view.needsLayout = true; view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
  }
  private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
  }
  private func center(_ canvas: VectorCanvasView) -> CGPoint { .init(x: canvas.visibleCanvasRect.midX, y: canvas.visibleCanvasRect.midY) }
  private func assertVisualCenter(_ canvas: VectorCanvasView, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
    guard let window = canvas.window else { XCTFail("Canvas has no backing window", file: file, line: line); return }
    // Convert one physical window backing pixel through the native view map,
    // including magnification. A fixed millimeter epsilon would be zoom-dependent.
    let windowPixel = window.convertFromBacking(NSRect(x: 0, y: 0, width: 1, height: 1)).size
    let documentPixel = canvas.convert(NSRect(origin: .zero, size: windowPixel), from: nil).size
    let actual = center(canvas)
    XCTAssertEqual(actual.x, expected.x, accuracy: abs(documentPixel.width) / CGFloat(TypographyEngine.pointsPerMM), file: file, line: line)
    XCTAssertEqual(actual.y, expected.y, accuracy: abs(documentPixel.height) / CGFloat(TypographyEngine.pointsPerMM), file: file, line: line)
  }
  private func assertNoAccumulatingDrift(_ actual: CGPoint, _ firstReturn: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
    // Once an identical layout has settled on its native pixel-aligned center,
    // repeated roundtrips may differ only by coordinate-conversion roundoff.
    let xRoundoff = 64 * max(Double(actual.x).ulp, Double(firstReturn.x).ulp)
    let yRoundoff = 64 * max(Double(actual.y).ulp, Double(firstReturn.y).ulp)
    XCTAssertEqual(actual.x, firstReturn.x, accuracy: CGFloat(xRoundoff), file: file, line: line)
    XCTAssertEqual(actual.y, firstReturn.y, accuracy: CGFloat(yRoundoff), file: file, line: line)
  }

  func testSingleSplitAndBothDirectionsRetainNativeIdentitiesViewportSourceAndDividerRatios() throws {
    let (store, _, view, source, _) = try fixture()
    let canvas = try XCTUnwrap(descendants(view, VectorCanvasView.self).first)
    let scroll = try XCTUnwrap(canvas.enclosingScrollView)
    canvas.setZoom(1.7)
    scroll.contentView.scroll(to: scroll.contentView.bounds.origin.applying(.init(translationX: 80, y: 55)))
    scroll.reflectScrolledClipView(scroll.contentView)
    let anchor = center(canvas), activeFrame = store.artworkSession.activeFrameID
    store.showSplit(.sideBySide); settle(view)
    let table = try XCTUnwrap(descendants(view, TableSceneView.self).first { $0.controller?.store === store })
    let renderer = table.controller?.renderer
    let split = try XCTUnwrap(descendants(view, DesignSurfaceSplitView.self).first)
    split.setPosition(split.bounds.width * 0.57, ofDividerAt: 0)
    settle(view)
    let sideWidth = split.subviews[0].frame.width
    store.revision += 1; settle(view)
    XCTAssertEqual(split.subviews[0].frame.width, sideWidth, accuracy: 0.001)
    var camera = try XCTUnwrap(store.scene?.camera)
    camera.distance = 13; camera.azimuth = 0.74; camera.elevation = 0.44
    store.scene?.camera = camera; store.scene?.updateCamera()
    let retained = try XCTUnwrap(store.scene?.camera)
    let before = try XCTUnwrap(store.project)
    store.activateDesignSurface(.table)
    store.showSplit(.stacked); settle(view)
    XCTAssertEqual(store.mode, .table)
    XCTAssertFalse(split.isVertical)
    XCTAssertTrue(split.subviews[0] === store.designSurfaceHost?.canvasHost)
    XCTAssertLessThan(split.subviews[0].frame.minY, split.subviews[1].frame.minY)
    split.setPosition(split.bounds.height * 0.61, ofDividerAt: 0); settle(view)
    let stackedHeight = split.subviews[0].frame.height
    var firstReturnedCenter: CGPoint?
    for _ in 0..<4 {
      store.showSurface(.table); settle(view)
      XCTAssertTrue(descendants(view, VectorCanvasView.self).isEmpty)
      XCTAssertTrue(descendants(view, TableSceneView.self).first { $0.controller?.store === store } === table)
      store.showSurface(.artwork); settle(view)
      XCTAssertTrue(descendants(view, VectorCanvasView.self).first === canvas)
      store.showSplit(.sideBySide); settle(view)
      XCTAssertEqual(split.subviews[0].frame.width, sideWidth, accuracy: 0.001)
      store.showSplit(.stacked); settle(view)
      XCTAssertEqual(split.subviews[0].frame.height, stackedHeight, accuracy: 0.001)
      XCTAssertTrue(descendants(view, TableSceneView.self).first { $0.controller?.store === store } === table)
      XCTAssertTrue(table.controller?.renderer === renderer)
      XCTAssertEqual(scroll.magnification, 1.7, accuracy: 1e-9)
      assertVisualCenter(canvas, anchor)
      if let firstReturnedCenter { assertNoAccumulatingDrift(center(canvas), firstReturnedCenter) }
      else { firstReturnedCenter = center(canvas) }
      XCTAssertEqual(store.artworkSession.objectID, source)
      XCTAssertEqual(store.artworkSession.activeFrameID, activeFrame)
    }
    var expectedCamera = retained; expectedCamera.viewportAspect = store.scene!.camera.viewportAspect
    XCTAssertEqual(store.scene?.camera, expectedCamera)
    var expected = before; expected.camera = store.project!.camera
    XCTAssertEqual(store.project, expected)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testVisibleCanvasEditorAndMarkedSelectionSurviveSplitAndAxisChanges() throws {
    let (store, window, view, source, text) = try fixture()
    let canvas = try XCTUnwrap(descendants(view, VectorCanvasView.self).first)
    canvas.beginText(text)
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.setSelectedRange(.init(location: 2, length: 3))
    editor.setMarkedText("composing", selectedRange: .init(location: 3, length: 0), replacementRange: editor.selectedRange())
    let selected = editor.selectedRange(), marked = editor.markedRange(), input = NSAttributedString(attributedString: editor.attributedString())
    XCTAssertTrue(editor.hasMarkedText())
    for direction in [DesignSurfaceSplitDirection.sideBySide, .stacked, .sideBySide] {
      store.showSplit(direction); settle(view)
      XCTAssertTrue(window.firstResponder === editor)
      XCTAssertTrue(descendants(view, VectorCanvasView.self).first === canvas)
      XCTAssertTrue(editor.hasMarkedText()); XCTAssertEqual(editor.markedRange(), marked)
      XCTAssertEqual(editor.selectedRange(), selected); XCTAssertEqual(editor.attributedString(), input)
      XCTAssertEqual(store.artworkSession.objectID, source)
    }
    store.showSurface(.artwork); settle(view)
    XCTAssertTrue(window.firstResponder === editor); XCTAssertTrue(editor.hasMarkedText())
    XCTAssertEqual(editor.selectedRange(), selected)
    store.showSurface(.table); settle(view)
    XCTAssertFalse(store.artworkSession.editingText)
    XCTAssertTrue(descendants(view, VectorCanvasView.self).isEmpty)
  }

  func testParkedFormCanvasDoesNotStealVisibleEnvironmentOwnerAndReclaimsOnReturn() throws {
    let (store, window, form, source, _) = try fixture()
    let lifetime = DesignSurfaceLifecyclePresenter.Coordinator()
    lifetime.bind(store)
    let cached = try XCTUnwrap(descendants(form, VectorCanvasView.self).first)
    let host = try XCTUnwrap(store.designSurfaceHost?.canvasHost)
    cached.setZoom(1.4)
    let before = try XCTUnwrap(store.project), anchor = center(cached)
    let alternate = NSHostingView(rootView: AnyView(ArtworkStudio(session: store.artworkSession).environmentObject(store)))
    window.contentView = alternate
    settle(alternate)
    let visible = try XCTUnwrap(descendants(alternate, VectorCanvasView.self).first)
    XCTAssertFalse(visible === cached); XCTAssertNil(cached.window)
    XCTAssertTrue(store.artworkSession.canvas === visible)
    for _ in 0..<3 {
      store.revision += 1
      settle(alternate)
      // Flush the parked graph after the active environment graph, as can occur
      // with retained hosting roots receiving shared-store notifications.
      form.needsLayout = true; form.layoutSubtreeIfNeeded()
      host.needsLayout = true; host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
      XCTAssertTrue(store.artworkSession.canvas === visible)
      XCTAssertEqual(store.artworkSession.objectID, source)
    }
    window.contentView = form
    settle(form)
    XCTAssertTrue(descendants(form, VectorCanvasView.self).first === cached)
    XCTAssertTrue(store.artworkSession.canvas === cached)
    XCTAssertEqual(cached.enclosingScrollView?.magnification ?? 0, 1.4, accuracy: 1e-9)
    XCTAssertEqual(store.artworkSession.zoom, 1.4, accuracy: 1e-9)
    assertVisualCenter(cached, anchor)
    let firstReturnedCenter = center(cached)
    for _ in 0..<3 {
      window.contentView = alternate; settle(alternate)
      XCTAssertTrue(store.artworkSession.canvas === visible)
      window.contentView = form; settle(form)
      XCTAssertTrue(store.artworkSession.canvas === cached)
      XCTAssertEqual(cached.enclosingScrollView?.magnification ?? 0, 1.4, accuracy: 1e-9)
      XCTAssertEqual(store.artworkSession.zoom, 1.4, accuracy: 1e-9)
      assertVisualCenter(cached, anchor)
      assertNoAccumulatingDrift(center(cached), firstReturnedCenter)
    }
    XCTAssertEqual(store.project, before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    _ = lifetime.controller
  }

}

import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class TableViewportRetentionTests: XCTestCase {
  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func pose(_ camera: CameraState) -> CameraState {
    var value = camera
    value.viewportAspect = nil
    return value
  }

  private func fixture() async throws -> (StudioStore, NSWindow, NSView, TableSceneView) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("table-retention-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Table viewport retention")
    var object = try project.makeObject(recipeID: "box", parameters: ["width": 180, "depth": 120, "height": 100])
    object.position = .init(140, 0, -60)
    project.objects = [object]
    store.engine.project = project; store.engine.selection = [object.id]
    store.showingHome = false; store.mode = .table; store.environment = .form
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1200, height: 800),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: StudioFramedTable(controller: store.studioShots).environmentObject(store))
    window.contentView = host; window.orderBack(nil)
    addTeardownBlock { @MainActor in
      window.contentView = nil; window.close(); store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      if let view = store.scene?.view, view.bounds.width > 100 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let view = try XCTUnwrap(store.scene?.view)
    XCTAssertNotNil(store.scene?.logicalNode(for: object.id))
    return (store, window, host, view)
  }

  func testFullSplitAndOrientationResizeRetainPerspectiveAndOrthographicCameraPose() async throws {
    let (store, window, host, originalView) = try await fixture()
    let scene = try XCTUnwrap(store.scene)
    let objects = store.project?.objects, history = store.project?.history
    let undoCount = store.engine.undoStack.count
    let renderer = try XCTUnwrap(scene.renderer)
    for projection in ["perspective", "orthographic"] {
      var seed = CameraState()
      seed.target = .init(2.7, 1.1, -0.8); seed.distance = 7.25
      seed.projection = projection
      seed = CameraNavigation.orbited(seed, dx: 61, dy: -23, viewportHeight: 800)
      scene.camera = seed; scene.updateCamera()
      let expected = pose(scene.camera), matrix = scene.cameraPayload().worldFromCameraMM
      let fieldOfView = scene.cameraNode.camera?.fieldOfView
      let span = scene.cameraNode.camera?.orthographicScale
      for (layout, size, active) in [
        (DesignSurfaceLayout.single, NSSize(width: 1200, height: 800), WorkspaceMode.table),
        (.split, NSSize(width: 600, height: 800), .artwork),
        (.split, NSSize(width: 1200, height: 400), .table),
        (.single, NSSize(width: 1200, height: 800), .table)
      ] {
        store.surfaceLayout = layout; store.mode = active
        window.setContentSize(size); host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 20_000_000)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(scene.view === originalView)
        XCTAssertTrue(scene.renderer === renderer)
        XCTAssertEqual(pose(scene.camera), expected)
        XCTAssertEqual(pose(try XCTUnwrap(store.project?.camera)), expected)
        XCTAssertEqual(scene.camera.viewportAspect ?? 0,
          originalView.bounds.width / originalView.bounds.height, accuracy: 0.000001)
        XCTAssertEqual(scene.cameraNode.camera?.fieldOfView, fieldOfView)
        XCTAssertEqual(scene.cameraNode.camera?.orthographicScale, span)
        let current = scene.cameraPayload().worldFromCameraMM
        XCTAssertEqual(current.columns.0, matrix.columns.0)
        XCTAssertEqual(current.columns.1, matrix.columns.1)
        XCTAssertEqual(current.columns.2, matrix.columns.2)
        XCTAssertEqual(current.columns.3, matrix.columns.3)
      }
    }
    XCTAssertEqual(store.project?.objects, objects)
    XCTAssertEqual(store.project?.history, history)
    XCTAssertEqual(store.engine.undoStack.count, undoCount)
  }

  func testExplicitFitUsesIdenticalInspectorClearanceInFullAndSplitAtSameViewport() async throws {
    let (store, _, _, _) = try await fixture()
    let scene = try XCTUnwrap(store.scene)
    let before = try XCTUnwrap(store.project), undoCount = store.engine.undoStack.count
    var fitted: [CameraState] = []
    for layout in [DesignSurfaceLayout.single, .split] {
      store.surfaceLayout = layout; store.mode = .table
      scene.camera = CameraState(); scene.updateCamera(); scene.fitAll()
      fitted.append(scene.camera)
    }
    XCTAssertEqual(fitted[0], fitted[1])
    XCTAssertEqual(store.project?.objects, before.objects)
    XCTAssertEqual(store.project?.history, before.history)
    XCTAssertEqual(store.engine.undoStack.count, undoCount)
  }
}

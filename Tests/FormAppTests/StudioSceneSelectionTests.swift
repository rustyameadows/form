import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class StudioSceneSelectionTests: XCTestCase {
  private func fixture(twelveStudies: Bool = false) throws -> StudioStore {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-scene-selection-" + UUID().uuidString)
    let repository = try ProjectRepository(root: directory)
    let project: Project
    if twelveStudies {
      let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("examples/paper-packaging/Field — Twelve paper studies.form")
      project = try repository.load(url: package)
      try FileManager.default.copyItem(at: package, to: repository.url(for: project.id))
    } else {
      var value = Project(name: "Independent Studio scene selection")
      var first = try value.makeObject(recipeID: "box", name: "First source", parameters: ["width": 100, "height": 80, "depth": 60])
      var second = try value.makeObject(recipeID: "box", name: "Second source", parameters: ["width": 60, "height": 110, "depth": 80])
      first.color = "#E84231"; second.color = "#285ADB"; value.objects = [first, second]
      value.camera.viewportAspect = 1.5
      var a = StudioComposition(name: "First saved scene", camera: value.camera)
      a.camera.distance = 3; a.camera.target = .init(0, 0.4, 0)
      a.instances = [.init(name: "First instance", sourceObjectID: first.id)]
      var b = StudioComposition(name: "Second saved scene", camera: a.camera)
      b.camera.azimuth += 0.5; b.camera.target.x = 1.3
      b.instances = [.init(name: "Second instance", sourceObjectID: second.id, positionMM: .init(130, 0, 0))]
      value.studioPresentation = .init(); value.studioPresentation!.scenes = [a, b]
      value.schemaVersion = value.minimumSchemaVersion; project = value
    }
    let store = StudioStore(repository: repository, seedLibrary: false)
    store.engine.project = project; store.showingHome = false; store.showEnvironment(.studio)
    addTeardownBlock { @MainActor in
      store.studioComposition.reset(); store.studioComposition.stage.view = nil; store.engine.project = nil
      try? FileManager.default.removeItem(at: directory)
    }
    return store
  }
  private func host(_ controller: StudioCompositionController) -> NSWindow {
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 480, height: 320),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSHostingView(rootView: StudioCompositionViewport(controller: controller))
    window.contentView = view; view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02)); view.layoutSubtreeIfNeeded()
    return window
  }
  private func assertStage(_ controller: StudioCompositionController, scene: StudioComposition, project: Project,
    file: StaticString = #filePath, line: UInt = #line) throws {
    let resolved = try scene.resolved(in: project)
    let visible = Set(controller.stage.objectRoot.childNodes.compactMap { node -> UUID? in
      guard let name = node.name, name.hasPrefix("object:") else { return nil }
      return UUID(uuidString: String(name.dropFirst(7)))
    })
    XCTAssertEqual(visible, resolved.visible, scene.name, file: file, line: line)
    var expected = scene.camera; expected.viewportAspect = controller.stage.camera.viewportAspect
    XCTAssertEqual(controller.stage.camera, expected, scene.name, file: file, line: line)
    let renderer = try XCTUnwrap(controller.stage.renderer, file: file, line: line)
    XCTAssertTrue(renderer.camera.worldFromCameraMM == controller.stage.cameraPayload().worldFromCameraMM, file: file, line: line)
    XCTAssertEqual(renderer.camera.projection, controller.stage.cameraPayload().projection, file: file, line: line)
    XCTAssertNil(controller.error, file: file, line: line)
  }
  private func pixels(_ controller: StudioCompositionController, name: String) async throws -> Data {
    let image = try await controller.stage.snapshot(size: .init(width: 240, height: 160))
    let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let bitmap = try XCTUnwrap(CGContext(data: nil, width: 240, height: 160, bitsPerComponent: 8, bytesPerRow: 240 * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.draw(cg, in: .init(x: 0, y: 0, width: 240, height: 160))
    if let path = ProcessInfo.processInfo.environment["FORM_STUDIO_SCENE_PROOF_DIR"] {
      let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
    }
    return Data(bytes: try XCTUnwrap(bitmap.data), count: 240 * 160 * 4)
  }
  private func settleSelection() async { for _ in 0..<12 { await Task.yield() } }

  func testTwelveStudyRecallBeforeFirstAppearanceSurvivesReconcileAndChangesLiveStage() async throws {
    let store = try fixture(twelveStudies: true), controller = store.studioComposition
    let before = try XCTUnwrap(store.project), scenes = controller.scenes
    XCTAssertEqual(scenes.count, 13)
    // A real menu request can precede SwiftUI's onAppear, including the focus
    // commit turn. Initial reconciliation must not erase the requested choice.
    controller.requestScene(scenes[7].id); controller.reconcile(); await settleSelection()
    XCTAssertEqual(controller.draft?.id, scenes[7].id)
    controller.reset(); controller.load(scenes[10].id); controller.reconcile()
    XCTAssertEqual(controller.draft?.id, scenes[10].id)
    let window = host(controller); defer { window.contentView = nil; window.close() }
    controller.reconcile(); XCTAssertEqual(controller.draft?.id, scenes[10].id)
    var rendered = Set<Data>()
    for (index, scene) in scenes.enumerated() {
      controller.load(scene.id); controller.reconcile()
      XCTAssertEqual(controller.draft, scene); XCTAssertFalse(controller.dirty)
      XCTAssertEqual(controller.time, 0); XCTAssertNil(controller.selectedInstanceID)
      try assertStage(controller, scene: scene, project: before)
      if [1, 7, 12].contains(index) { rendered.insert(try await pixels(controller, name: scene.name)) }
    }
    XCTAssertEqual(rendered.count, 3, "Saved case/overview choices must change actual rendered pixels, not only the selected name.")
    XCTAssertEqual(store.project, before); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testNativeViewportRoundingDoesNotDirtyRecallAndCurrentSourcesUpdateItsPreview() async throws {
    let store = try fixture(), controller = store.studioComposition
    controller.reconcile(); let window = host(controller)
    defer { window.contentView = nil; window.close() }
    let before = try XCTUnwrap(store.project), scene = try XCTUnwrap(controller.draft)
    window.setContentSize(.init(width: 521, height: 347)); window.contentView?.layoutSubtreeIfNeeded()
    let viewport = try XCTUnwrap(controller.stage.view)
    XCTAssertNotEqual(controller.stage.camera.viewportAspect, scene.camera.viewportAspect)
    let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
    viewport.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
    XCTAssertFalse(controller.dirty); XCTAssertEqual(controller.draft, scene)
    let old = try await pixels(controller, name: "source-before")
    var changed = before; changed.objects[0].color = "#28B174"; store.engine.project = changed
    controller.reconcile()
    try assertStage(controller, scene: scene, project: changed)
    let current = try await pixels(controller, name: "source-current")
    XCTAssertNotEqual(current, old)
    XCTAssertEqual(controller.draft, scene); XCTAssertFalse(controller.dirty)
    XCTAssertEqual(store.project, changed); XCTAssertTrue(store.engine.undoStack.isEmpty)
    controller.requestScene(controller.scenes[1].id); await settleSelection()
    XCTAssertEqual(controller.draft?.id, controller.scenes[1].id)
  }

  func testSceneSwitchRequestsPreserveDraftsAndLatestRequestUntilExplicitSaveOrDiscard() async throws {
    let store = try fixture(), controller = store.studioComposition
    controller.reconcile()
    let before = try XCTUnwrap(store.project), first = controller.scenes[0], second = controller.scenes[1]
    controller.requestScene(second.id); controller.requestScene(first.id); await settleSelection()
    XCTAssertEqual(controller.draft, first)
    controller.change { $0.name = "Unsaved placement"; $0.instances[0].positionMM.x += 35 }
    controller.scrub(0.5); let draft = controller.draft, camera = controller.stage.camera
    controller.requestScene(second.id); await settleSelection()
    XCTAssertEqual(controller.pendingSceneID, second.id)
    XCTAssertEqual(controller.draft, draft); XCTAssertEqual(controller.stage.camera, camera)
    controller.cancelSceneSelection(); XCTAssertNil(controller.pendingSceneID); XCTAssertTrue(controller.dirty)
    controller.requestScene(second.id); await settleSelection()
    controller.discardAndLoadScene(try XCTUnwrap(controller.pendingSceneID))
    XCTAssertEqual(controller.draft, second); XCTAssertFalse(controller.dirty); XCTAssertEqual(controller.time, 0)
    XCTAssertEqual(store.project, before); XCTAssertTrue(store.engine.undoStack.isEmpty)
    controller.change { $0.name = "Saved placement"; $0.instances[0].positionMM.z += 50 }
    controller.requestScene(first.id); await settleSelection()
    let savedDraft = try XCTUnwrap(controller.draft)
    controller.saveAndLoadScene(try XCTUnwrap(controller.pendingSceneID))
    XCTAssertNil(controller.error); XCTAssertEqual(controller.draft, first); XCTAssertFalse(controller.dirty)
    XCTAssertEqual(store.project!.studioPresentation?.scenes?.first { $0.id == second.id }?.instances, savedDraft.instances)
    XCTAssertEqual(store.project!.studioPresentation?.scenes?.first { $0.id == second.id }?.name, savedDraft.name)
    XCTAssertEqual(store.project!.objects, before.objects); XCTAssertEqual(store.project!.camera, before.camera)
    XCTAssertEqual(store.engine.undoStack.count, 1)
    store.engine.undo(); XCTAssertEqual(store.project!.studioPresentation, before.studioPresentation)
    controller.change { $0.name = "Kept if the destination disappears" }
    controller.requestScene(second.id); await settleSelection()
    let retained = controller.draft
    store.engine.project!.studioPresentation!.scenes!.removeAll { $0.id == second.id }
    let missing = store.project
    controller.saveAndLoadScene(second.id)
    XCTAssertNotNil(controller.error); XCTAssertEqual(controller.draft, retained)
    XCTAssertEqual(store.project, missing); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
}

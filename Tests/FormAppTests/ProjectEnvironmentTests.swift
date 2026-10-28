import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class ProjectEnvironmentTests: XCTestCase {
  private func fixture() throws -> StudioStore {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ProjectRepository(root: root)
    var project = Project(name: "Shared environment source")
    let box = try project.makeObject(recipeID: "box")
    var frame = try project.makeObject(recipeID: "artboard")
    frame.artwork = Artwork(elements: [.init(kind: "text", x: 10, y: 10, width: 50, height: 12, text: "Keep this source")])
    project.objects = [box, frame]
    _ = try project.ensureCanvasWorkspace()
    try repository.save(project)
    let store = StudioStore(repository: repository, seedLibrary: false)
    try store.engine.open(project.id)
    store.showingHome = false
    addTeardownBlock { @MainActor in
      store.closeDetachedCanvas(); store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    return store
  }
  func testExactlyThreePrimaryEnvironmentsAndSeparateStudio() {
    XCTAssertEqual(ProjectEnvironment.primary, [.form, .function, .fabricate])
    XCTAssertFalse(ProjectEnvironment.primary.contains(.studio))
    XCTAssertEqual(ProjectEnvironment.studio.symbol, "camera.aperture")
  }
  func testIntentNavigationRetainsSourceSelectionCameraAndHistory() throws {
    let store = try fixture(), box = store.project!.objects[0]
    store.select(box.id)
    let originalSubtitle = store.project!.subtitle
    try store.engine.edit("An existing edit") { $0.subtitle = "Keep Undo" }
    let before = store.project!, history = store.engine.undoStack
    for next in [.function, .fabricate, .form, .studio, .function] as [ProjectEnvironment] {
      store.showEnvironment(next)
      XCTAssertEqual(store.environment, next)
      XCTAssertEqual(store.project, before)
      XCTAssertEqual(store.engine.undoStack, history)
      XCTAssertEqual(store.engine.selection, [box.id])
    }
    store.undo(); XCTAssertEqual(store.project?.subtitle, originalSubtitle)
    store.redo(); XCTAssertEqual(store.project?.subtitle, "Keep Undo")
  }
  func testStudioReturnsToFiniteSourceAndExactArtworkSelectionInSplit() throws {
    let store = try fixture(), frame = store.project!.objects[1]
    store.artworkSession.activate(frame.id)
    let element = frame.artwork!.elements[0].id
    store.artworkSession.choose([element])
    store.surfaceLayout = .split; store.mode = .artwork
    let before = store.project!
    store.showEnvironment(.studio)
    XCTAssertEqual(store.mode, .studio); XCTAssertEqual(store.surfaceLayout, .single)
    store.showEnvironment(.form)
    XCTAssertEqual(store.surfaceLayout, .split); XCTAssertEqual(store.mode, .artwork)
    XCTAssertEqual(store.artworkSession.objectID, frame.id)
    XCTAssertEqual(store.artworkSession.selection, [element])
    XCTAssertEqual(store.project, before); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testPointerFocusAndSurfaceChangesRetainTechnicalEnvironment() throws {
    let store = try fixture()
    store.showEnvironment(.function)
    store.showSplit()
    store.activateDesignSurface(.table); XCTAssertEqual(store.environment, .function)
    store.activateDesignSurface(.artwork); XCTAssertEqual(store.environment, .function)
    store.showSurface(.table); XCTAssertEqual(store.environment, .function)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testLegacyAndNewMCPNavigationUseTheSameNativeState() throws {
    let store = try fixture(), before = store.project!
    for view in ["function", "fabricate", "form", "studio", "table"] {
      _ = try store.engine.call("form_set_view", arguments: ["view": view])
    }
    XCTAssertEqual(store.environment, .form); XCTAssertEqual(store.mode, .table)
    XCTAssertEqual(store.project, before); XCTAssertTrue(store.engine.undoStack.isEmpty)
    let tool = MCP.tools.first { $0["name"] as? String == "form_set_view" }!
    let schema = tool["inputSchema"] as! [String: Any], props = schema["properties"] as! [String: Any]
    let views = (props["view"] as! [String: Any])["enum"] as! [String]
    for value in ["form", "function", "fabricate", "studio", "canvas", "split", "canvas_window", "perspective"] { XCTAssertTrue(views.contains(value)) }
  }
  func testExplicitArtworkActionLeavesStudioAndHomeClearsReturnContext() throws {
    let store = try fixture()
    store.showEnvironment(.studio)
    store.mode = .artwork
    XCTAssertEqual(store.environment, .form); XCTAssertNil(store.studioReturnSurface)
    store.showEnvironment(.studio)
    store.home()
    XCTAssertEqual(store.environment, .form); XCTAssertNil(store.studioReturnSurface)
    XCTAssertNil(store.fabricationReview)
    store.showEnvironment(.form)
    XCTAssertFalse(store.showingHome); XCTAssertEqual(store.mode, .table)
  }
  func testFabricationRoutesAreSourceSpecificAndOpenRealExistingReviews() throws {
    let store = try fixture(), project = store.project!, box = project.objects[0], frame = project.objects[1]
    XCTAssertTrue(FabricationDestination.print3D.available(in: project, object: box))
    XCTAssertFalse(FabricationDestination.page.available(in: project, object: box))
    XCTAssertTrue(FabricationDestination.page.available(in: project, object: frame))
    XCTAssertFalse(FabricationDestination.print3D.available(in: project, object: frame))
    XCTAssertFalse(FabricationDestination.embroidery.available(in: project, object: box))
    XCTAssertFalse(FabricationDestination.pattern.available(in: project, object: frame))
    XCTAssertTrue(FabricationDestination.collection.available(in: project, object: nil))
    store.select(frame.id); store.showEnvironment(.fabricate); store.presentFabrication(.page)
    XCTAssertEqual(store.fabricationReview?.destination, .page)
    XCTAssertEqual(store.fabricationReview?.objectID, frame.id)
    XCTAssertEqual(store.fabricationReview?.projectID, project.id)
    XCTAssertEqual(store.project, project); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testProjectReplacementDismissesOldProductionReviewAndStudioReturnState() throws {
    let store = try fixture(), old = store.project!
    store.select(old.objects[1].id); store.presentFabrication(.page)
    store.showEnvironment(.studio)
    let next = Project(name: "Another project"); try store.repository.save(next)
    store.openProject(next.id)
    XCTAssertEqual(store.environment, .form); XCTAssertNil(store.fabricationReview)
    XCTAssertNil(store.studioReturnSurface); XCTAssertEqual(store.project?.id, next.id)
  }
}

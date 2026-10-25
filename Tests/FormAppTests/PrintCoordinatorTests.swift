import AppKit
import XCTest

@testable import FormApp
@testable import FormCore

@MainActor final class PrintCoordinatorTests: XCTestCase {
  private func fixture() throws -> (StudioStore, ProductObject, ProductObject, UUID, URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ProjectRepository(root: root)
    var first = Project(name: "First print project")
    var a = try first.makeObject(recipeID: "box")
    a.parameters = ["width": 20, "height": 30, "depth": 40, "corner": 0]
    a.name = "First block"
    first.objects = [a]
    var second = Project(name: "Second print project")
    var b = a  // Imported packages may legitimately reuse object UUIDs.
    b.parameters["width"] = 55
    b.name = "Second block"
    second.objects = [b]
    try repository.save(first)
    try repository.save(second)
    let store = StudioStore(repository: repository, seedLibrary: false)
    try store.engine.open(first.id)
    store.printing.open(objectID: a.id)
    return (store, a, b, second.id, root)
  }
  private func preview(_ length: Double = 10) -> ToolpathPreview {
    ToolpathPreview.parse(
      "; estimated printing time (normal mode) = 1m\nM83\nG1 X0 Y0 Z0.2\nG1 X\(length) Y0 E1\nG1 X\(length) Y10 Z0.4 E1\n"
    )
  }
  private func stage(
    _ printing: PrintCoordinator, root: URL, id: String = UUID().uuidString,
    process: Process = Process()
  ) throws -> PrintCoordinator.SliceRequest {
    try printing.beginSlice(process: process, directory: root.appendingPathComponent(id), id: id)
  }
  func testSuccessfulProjectOpenDismissesSheetAndClearsAllPreviewState() throws {
    let (store, a, b, next, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let printing = store.printing
    let request = try stage(printing, root: root)
    printing.finishSlice(.success(("A log", preview())), request: request)
    XCTAssertTrue(printing.showToolpath)
    XCTAssertNotNil(printing.outputDirectory)
    printing.layer = 1
    printing.frame("object")
    store.artworkSession.showingTextStyles = true
    store.artworkSession.showingPalette = true
    let meshVersion = printing.meshVersion
    let pathVersion = printing.toolpathVersion
    try store.engine.open(next)
    XCTAssertFalse(store.showingPrint)
    XCTAssertFalse(store.artworkSession.showingTextStyles)
    XCTAssertFalse(store.artworkSession.showingPalette)
    XCTAssertNil(printing.objectID)
    XCTAssertNil(printing.preparedProjectID)
    XCTAssertNil(printing.mesh)
    XCTAssertNil(printing.toolpath)
    XCTAssertNil(printing.outputDirectory)
    XCTAssertNil(printing.jobID)
    XCTAssertNil(printing.activeRequest)
    XCTAssertFalse(printing.showToolpath)
    XCTAssertFalse(printing.busy)
    XCTAssertFalse(printing.canSlice)
    XCTAssertEqual(printing.layer, 0)
    XCTAssertEqual(printing.log, "")
    XCTAssertNil(printing.validationError)
    XCTAssertEqual(printing.status, "Ready to prepare")
    XCTAssertEqual(printing.cameraRequest, "bed")
    XCTAssertGreaterThan(printing.meshVersion, meshVersion)
    XCTAssertGreaterThan(printing.toolpathVersion, pathVersion)
    printing.open(objectID: b.id)
    XCTAssertEqual(printing.preparedProjectID, next)
    XCTAssertEqual(printing.object?.name, b.name)
    XCTAssertEqual(printing.mesh!.size.x, 55, accuracy: 0.01)
    XCTAssertEqual(
      try store.repository.load(store.projects.first { $0.id != next }!.id).objects[0].id, a.id)
  }
  func testFailedOpenAndInvalidTemplateKeepTheActiveSliceAndPreviewContext() throws {
    let (store, a, _, _, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let printing = store.printing
    let oldProject = store.project!.id
    let request = try stage(printing, root: root)
    store.artworkSession.showingTextStyles = true
    store.artworkSession.showingPalette = true
    XCTAssertThrowsError(try store.engine.open(UUID()))
    XCTAssertThrowsError(
      try store.engine.call(
        "form_create_project", arguments: ["name": "Invalid", "template": "missing"]))
    XCTAssertTrue(store.showingPrint)
    XCTAssertTrue(store.artworkSession.showingTextStyles)
    XCTAssertTrue(store.artworkSession.showingPalette)
    XCTAssertTrue(printing.busy)
    XCTAssertEqual(printing.preparedProjectID, oldProject)
    XCTAssertEqual(printing.objectID, a.id)
    XCTAssertEqual(printing.activeRequest, request)
    printing.finishSlice(.success(("Complete", preview())), request: request)
    XCTAssertTrue(printing.showToolpath)
  }
  func testNativeOpenAndNewProjectUseTheSamePrintLifecycle() throws {
    let (store, _, b, next, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    store.openProject(next)
    XCTAssertNil(store.error)
    XCTAssertFalse(store.showingPrint)
    XCTAssertNil(store.printing.mesh)
    store.printing.open(objectID: b.id)
    XCTAssertTrue(store.showingPrint)
    store.createProject()
    XCTAssertNotEqual(store.project!.id, next)
    XCTAssertTrue(store.project!.objects.isEmpty)
    XCTAssertFalse(store.showingPrint)
    XCTAssertNil(store.printing.objectID)
    XCTAssertNil(store.printing.mesh)
    XCTAssertFalse(store.printing.busy)
  }
  func testLateOldSuccessAndFailureCannotClearOrReplaceANewBusySlice() throws {
    let (store, _, b, next, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let printing = store.printing
    let old = try stage(printing, root: root, id: "same-job-id")
    try store.engine.open(next)
    printing.open(objectID: b.id)
    let current = try stage(printing, root: root, id: "same-job-id")
    XCTAssertNotEqual(old, current)
    printing.finishSlice(.success(("Old result", preview(90))), request: old)
    printing.finishSlice(.failure(FormError.invalid("Old error")), request: old)
    XCTAssertTrue(printing.busy)
    XCTAssertEqual(printing.activeRequest, current)
    XCTAssertEqual(printing.mesh!.size.x, 55, accuracy: 0.01)
    XCTAssertNil(printing.toolpath)
    XCTAssertNil(printing.validationError)
    XCTAssertEqual(printing.log, "")
    printing.finishSlice(.success(("Current result", preview(7))), request: current)
    XCTAssertFalse(printing.busy)
    XCTAssertTrue(printing.showToolpath)
    XCTAssertEqual(printing.log, "Current result")
    XCTAssertEqual(printing.toolpath!.segments[0].to.x, 7)
  }
  func testProjectSwitchStopsItsOwnedLocalProcess() async throws {
    let (store, _, _, next, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    _ = try stage(store.printing, root: root, process: process)
    try store.engine.open(next)
    for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(process.isRunning)
    XCTAssertFalse(store.printing.busy)
    XCTAssertNil(store.printing.activeRequest)
  }
  func testGeometryChangesInvalidateSlicesButPlacementAndPaintDoNot() throws {
    let (store, a, _, _, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let printing = store.printing
    let old = try stage(printing, root: root)
    try store.engine.call(
      "form_update_object",
      arguments: [
        "object_id": a.id.uuidString, "name": "Renamed", "color": "#224B9B",
        "position": [50.0, 0.0, 20.0],
      ])
    store.changed(save: false)
    XCTAssertEqual(printing.activeRequest, old)
    XCTAssertTrue(printing.busy)
    try store.engine.call(
      "form_update_object", arguments: ["object_id": a.id.uuidString, "parameters": ["width": 31]])
    store.changed(save: false)
    XCTAssertFalse(printing.busy)
    XCTAssertNil(printing.activeRequest)
    XCTAssertNil(printing.jobID)
    XCTAssertNil(printing.outputDirectory)
    XCTAssertEqual(printing.mesh!.size.x, 31, accuracy: 0.01)
    printing.finishSlice(.success(("Stale geometry", preview())), request: old)
    XCTAssertNil(printing.toolpath)
    store.engine.undo()
    store.changed(save: false)
    XCTAssertEqual(printing.mesh!.size.x, 20, accuracy: 0.01)
  }
  func testDeletedObjectClearsOutputsAndANewSelectionCanBePrepared() throws {
    let (store, a, _, _, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let printing = store.printing
    let request = try stage(printing, root: root)
    printing.finishSlice(.success(("Ready", preview())), request: request)
    try store.engine.call("form_delete_objects", arguments: ["object_ids": [a.id.uuidString]])
    store.changed(save: false)
    XCTAssertNil(printing.objectID)
    XCTAssertNil(printing.mesh)
    XCTAssertNil(printing.toolpath)
    XCTAssertNil(printing.outputDirectory)
    XCTAssertFalse(printing.canSlice)
    XCTAssertTrue(store.showingPrint)
    store.engine.undo()
    store.changed(save: false)
    printing.chooseObject(a.id)
    XCTAssertEqual(printing.mesh!.size.x, 20, accuracy: 0.01)
  }
  func testInvalidPreparationAndNewSliceNeverShowThePreviousToolpath() throws {
    let (store, _, _, _, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let printing = store.printing
    let first = try stage(printing, root: root)
    printing.finishSlice(.success(("Ready", preview())), request: first)
    let next = try stage(printing, root: root)
    XCTAssertNil(printing.toolpath)
    XCTAssertFalse(printing.showToolpath)
    printing.finishSlice(.failure(FormError.invalid("Worker failed")), request: next)
    XCTAssertEqual(printing.status, "Slicing failed")
    XCTAssertNil(printing.toolpath)
    printing.configuration.scalePercent = 0
    printing.prepare()
    XCTAssertNil(printing.mesh)
    XCTAssertNil(printing.outputDirectory)
    XCTAssertNil(printing.jobID)
    XCTAssertFalse(printing.canSlice)
    XCTAssertNotNil(printing.validationError)
    XCTAssertEqual(printing.status, "Check print setup")
  }
  func testPrintViewPreparesCurrentObjectAndStatusReportsItsOwnership() throws {
    let (store, _, b, next, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try store.engine.open(next)
    try store.applyView("print_object", ["object_id": b.id.uuidString])
    let summary = try store.printing.setupSummary()
    XCTAssertEqual(summary["project_id"] as? String, next.uuidString)
    XCTAssertEqual(summary["prepared_project_id"] as? String, next.uuidString)
    XCTAssertEqual(summary["object_id"] as? String, b.id.uuidString)
    XCTAssertEqual(summary["workspace_presented"] as? Bool, true)
    XCTAssertEqual(summary["print_commands_enabled"] as? Bool, false)
    XCTAssertFalse(store.printing.monitor.connected)
  }
  func testMalformedPrintSelectionAndDifferentBusyObjectAreRejected() throws {
    let (store, a, _, _, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try store.printing.call("form_open_print", ["object_id": "invalid"]))
    var another = a
    another.id = UUID()
    try store.engine.edit("Another object") { $0.objects.append(another) }
    let request = try stage(store.printing, root: root)
    XCTAssertThrowsError(
      try store.printing.call("form_open_print", ["object_id": another.id.uuidString]))
    XCTAssertEqual(store.printing.activeRequest, request)
    XCTAssertEqual(store.printing.objectID, a.id)
  }
  func testNativePrintSettingUndoRedoKeepsTheMeshAndSavedSetupAligned() throws {
    let (store, a, _, _, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let printing = store.printing
    printing.updateConfiguration { $0.scalePercent = 150 }
    XCTAssertEqual(printing.mesh!.size.x, 30, accuracy: 0.01)
    XCTAssertEqual(store.project?.printSetups?[a.id.uuidString]?.scalePercent, 150)
    store.engine.undo()
    store.changed(save: false)
    XCTAssertEqual(printing.configuration.scalePercent, 100)
    XCTAssertEqual(printing.mesh!.size.x, 20, accuracy: 0.01)
    XCTAssertNil(store.project?.printSetups?[a.id.uuidString])
    XCTAssertEqual(store.engine.redoStack.count, 1)
    store.engine.redo()
    store.changed(save: false)
    XCTAssertEqual(printing.configuration.scalePercent, 150)
    XCTAssertEqual(printing.mesh!.size.x, 30, accuracy: 0.01)
    XCTAssertEqual(store.project?.printSetups?[a.id.uuidString]?.scalePercent, 150)
  }
  func testSavedCompleteLampComponentSurvivesOpenChooseAndUndo() throws {
    let (store, a, _, _, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let raw =
      try store.engine.call(
        "form_add_object",
        arguments: [
          "recipe_id": "lamp",
          "parameters": [
            "height": 200, "shadeHeight": 60, "shadeDiameter": 100, "topDiameter": 40,
          ],
        ]) as! [String: Any]
    let lamp = UUID(uuidString: raw["id"] as! String)!
    store.changed(save: false)
    let printing = store.printing
    printing.open(objectID: lamp)
    XCTAssertEqual(printing.configuration.component, "Shade")
    printing.updateConfiguration { $0.component = "Complete object" }
    printing.open(objectID: lamp)
    XCTAssertEqual(printing.configuration.component, "Complete object")
    printing.chooseObject(a.id)
    printing.chooseObject(lamp)
    XCTAssertEqual(printing.configuration.component, "Complete object")
    store.engine.undo()
    store.changed(save: false)
    XCTAssertEqual(printing.configuration.component, "Shade")
    XCTAssertEqual(printing.mesh!.size.z, 60, accuracy: 0.02)
  }
  func testReadOnlyStatusAndUnchangedSettingsDoNotRebuildPreparation() throws {
    let (store, _, _, _, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let printing = store.printing
    let version = printing.meshVersion
    let history = store.project!.history
    printing.updateConfiguration { $0.scalePercent = 100 }
    _ = try printing.setupSummary()
    _ = try printing.call("form_get_slice_status", [:])
    store.changed(save: false)
    XCTAssertEqual(printing.meshVersion, version)
    XCTAssertEqual(store.project!.history, history)
  }
  func testExplicitCancellationDiscardsAQueuedSuccessAndAllowsRetry() throws {
    let (store, _, _, _, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let printing = store.printing
    let old = try stage(printing, root: root)
    printing.cancel()
    XCTAssertEqual(printing.status, "Cancelling…")
    printing.finishSlice(.success(("Arrived after cancel", preview())), request: old)
    XCTAssertFalse(printing.busy)
    XCTAssertNil(printing.toolpath)
    XCTAssertEqual(printing.status, "Slicing cancelled")
    let next = try stage(printing, root: root)
    printing.finishSlice(.success(("New slice", preview())), request: next)
    XCTAssertEqual(printing.status, "Slice ready · saved locally")
    XCTAssertTrue(printing.showToolpath)
    XCTAssertEqual(printing.log, "New slice")
  }
}

import AppKit
import XCTest
@testable import FormApp
@testable import FormCore

@MainActor final class CameraPreferenceTests: XCTestCase {
  func testPreferencesSurviveStoreRecreationWithoutChangingTheProject() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "FORM.camera-test.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let repository = try ProjectRepository(root: root)
    let project = Project(name: "Camera test")
    try repository.save(project)
    let store = StudioStore(repository: repository, seedLibrary: false, cameraDefaults: defaults)
    try store.engine.open(project.id)
    let before = store.project!
    XCTAssertEqual(store.cameraPreferences.orbitDirection, .moveCamera)
    store.cameraPreferences.orbitDirection = .turnObject
    store.cameraPreferences.orbitSpeed = 1.25
    store.cameraPreferences.reverseScrollZoom = true
    let reopened = StudioStore(repository: repository, seedLibrary: false, cameraDefaults: defaults)
    XCTAssertEqual(reopened.cameraPreferences, store.cameraPreferences)
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(try repository.load(project.id), before)
    defaults.set(Data("invalid settings".utf8), forKey: "FORM.cameraNavigation")
    let recovered = StudioStore(repository: repository, seedLibrary: false, cameraDefaults: defaults)
    XCTAssertEqual(recovered.cameraPreferences, CameraPreferences())
  }

  func testPreviewCameraUsesLiveSharedPreferencesWithoutEditingTheDocumentCamera() {
    _ = NSApplication.shared
    let controller = TableSceneController()
    var preferences = CameraPreferences()
    controller.navigationPreferences = { preferences }
    let original = controller.camera
    controller.orbit(dx: 80, dy: 40)
    XCTAssertGreaterThan(controller.camera.azimuth, original.azimuth)
    controller.camera = original
    preferences.orbitDirection = .turnObject
    controller.orbit(dx: 80, dy: 40)
    XCTAssertLessThan(controller.camera.azimuth, original.azimuth)
    XCTAssertNil(controller.store)
    XCTAssertEqual(controller.diagnostics["orbit_direction"] as? String, "turnObject")
  }
}

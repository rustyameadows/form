import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class InterfaceAppearanceTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lab-style-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  func testAccentPersistsCanonicallyAndInvalidInputIsAtomic() throws {
    let file = try directory().appendingPathComponent("Appearance.json"), prefs = InterfaceAppearance(file: file)
    XCTAssertEqual(prefs.accentHex, InterfaceAppearance.defaultAccent)
    try prefs.setAccent("  af34d2 "); XCTAssertEqual(prefs.accentHex, "#AF34D2")
    XCTAssertEqual(InterfaceAppearance(file: file).accentHex, "#AF34D2")
    let bytes = try Data(contentsOf: file)
    for value in ["#12", "#GG0022", "#11223344", "red", "#１12233"] {
      XCTAssertThrowsError(try prefs.setAccent(value)); XCTAssertEqual(prefs.accentHex, "#AF34D2")
      XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    try prefs.setAccent(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)); XCTAssertEqual(prefs.accentHex, "#FF8000")
  }
  func testDefaultsAndFilePreferencesStayIndependentAndRecoverInvalidStoredColor() throws {
    let name = "lab-style-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("invalid", forKey: "LAB.interfaceAccent")
    let prefs = InterfaceAppearance(defaults: defaults); XCTAssertEqual(prefs.accentHex, InterfaceAppearance.defaultAccent)
    try prefs.setAccent("#236644"); XCTAssertEqual(InterfaceAppearance(defaults: defaults).accentHex, "#236644")
    let filePrefs = InterfaceAppearance(file: try directory().appendingPathComponent("Appearance.json"))
    try filePrefs.setAccent("#CC2288"); XCTAssertEqual(prefs.accentHex, "#236644")
    let parent = try directory().appendingPathComponent("not-a-directory"); try Data([1]).write(to: parent)
    let broken = InterfaceAppearance(file: parent.appendingPathComponent("Appearance.json"))
    XCTAssertThrowsError(try broken.setAccent("#123456")); XCTAssertEqual(broken.accentHex, InterfaceAppearance.defaultAccent)
  }
  func testCustomPaleAndDarkColorsRetainReadableControlContrast() throws {
    let prefs = InterfaceAppearance(file: try directory().appendingPathComponent("Appearance.json"))
    for hex in ["#FFFFFF", "#FFFF00", "#000000", "#FF00FF", "#AAAAAA", "#245BFF", "#34CCAA"] {
      try prefs.setAccent(hex)
      XCTAssertEqual(prefs.accentHex, hex)
      XCTAssertGreaterThanOrEqual(InterfaceAppearance.whiteContrast(prefs.controlColor), 4.5)
      XCTAssertEqual(prefs.controlColor.alphaComponent, 1)
    }
  }
  func testLiveAccentRefreshPreservesDesignCameraDraftsAndGeometryBuilds() throws {
    _ = NSApplication.shared
    let root = try directory(), repository = try ProjectRepository(root: root), p = try PaperSamples.cosmetics()
    try repository.save(p)
    let store = StudioStore(repository: repository, seedLibrary: false); try store.engine.open(p.id)
    store.select(p.objects[0].id)
    let scene = TableSceneController(store: store); store.scene = scene; store.synchronizeScene()
    store.studioComposition.reconcile(); store.studioComposition.addShelf()
    store.fabricationGuide.reconcile(); store.fabricationGuide.caliper = "0.47"
    let before = store.project, draft = store.studioComposition.draft, camera = scene.camera
    let stageCamera = store.studioComposition.stage.camera, builds = scene.diagnostics["geometry_builds"] as? Int
    let library = try JSONEncoder.form.encode(store.library), prefs = InterfaceAppearance(file: root.appendingPathComponent("Appearance.json"))
    try prefs.setAccent("#8822CC"); store.refreshInterfaceAppearance(accent: prefs.controlColor)
    XCTAssertEqual(store.project, before); XCTAssertEqual(scene.camera, camera); XCTAssertEqual(store.studioComposition.stage.camera, stageCamera)
    XCTAssertEqual(store.studioComposition.draft, draft); XCTAssertEqual(store.fabricationGuide.caliper, "0.47")
    XCTAssertEqual(try JSONEncoder.form.encode(store.library), library); XCTAssertEqual(scene.diagnostics["geometry_builds"] as? Int, builds)
    store.studioComposition.reset()
  }
}

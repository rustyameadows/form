import AppKit
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class FontCollectionPersistenceTests: XCTestCase {
  private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-collections-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func fixture() throws -> StudioStore {
    _ = NSApplication.shared
    let root = try directory(), store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    store.fontLibraryPreferences = .init(file: root.appendingPathComponent("FontPreferences.json"))
    var project = Project(name: "Project font choices")
    _ = try project.ensureCanvasWorkspace()
    var text = ArtworkElement(kind: "text", x: 0, y: 0, width: 80, height: 20, text: "Two fonts")
    var type = Typography(); type.fontName = "FORM-Missing-Body"; text.typography = type
    type.fontName = "Georgia-Bold"
    text.textRuns = [.init(location: 0, length: 3, typography: type, fontSize: 18, color: "#123456")]
    project.objects[0].artwork?.elements = [text]
    project.schemaVersion = project.minimumSchemaVersion
    store.engine.project = project
    addTeardownBlock { @MainActor in store.engine.project = nil }
    return store
  }
  func testProjectAddRemoveUsesOneUndoAndNeverChangesArtworkOrStudioChoices() throws {
    let store = try fixture(), session = store.artworkSession, original = try XCTUnwrap(store.project)
    let preferences = store.fontLibraryPreferences
    preferences.toggle("FORM-Missing-Studio"); preferences.used("Georgia")
    XCTAssertTrue(session.toggleProjectFont("FORM-Missing-Saved"))
    XCTAssertEqual(session.projectFontNames, ["FORM-Missing-Saved"])
    XCTAssertEqual(store.engine.undoStack.count, 1); XCTAssertEqual(store.project?.objects, original.objects)
    let saved = store.project
    XCTAssertTrue(session.toggleProjectFont("FORM-Missing-Saved"))
    XCTAssertTrue(session.projectFontNames.isEmpty); XCTAssertNil(store.project?.fontLibrary)
    XCTAssertEqual(store.engine.undoStack.count, 2)
    store.engine.undo(); XCTAssertEqual(store.project, saved)
    store.engine.undo(); XCTAssertEqual(store.project, original)
    store.engine.redo(); XCTAssertEqual(store.project, saved)
    XCTAssertEqual(preferences.favorites, ["FORM-Missing-Studio"])
    XCTAssertEqual(preferences.recent, ["Georgia"])
  }
  func testUsedFontsAreDerivedAndMissingSavedChoicesRemainIndependent() throws {
    let store = try fixture(), session = store.artworkSession, original = store.project
    XCTAssertEqual(session.projectUsedFontNames, ["FORM-Missing-Body", "Georgia-Bold"])
    XCTAssertTrue(session.projectFontNames.isEmpty); XCTAssertEqual(store.project, original)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertTrue(session.toggleProjectFont("Unassigned-Missing-Choice"))
    let count = store.engine.undoStack.count
    XCTAssertEqual(session.projectUsedFontNames, ["FORM-Missing-Body", "Georgia-Bold"])
    XCTAssertEqual(session.projectFontNames, ["Unassigned-Missing-Choice"])
    XCTAssertEqual(store.engine.undoStack.count, count)
    let firstID = try XCTUnwrap(store.project?.id)
    store.engine.project = Project(name: "Different project")
    let other = store.project
    XCTAssertFalse(session.toggleProjectFont("Stale-Popover-Choice", projectID: firstID))
    XCTAssertEqual(store.project, other); XCTAssertTrue(session.projectFontNames.isEmpty)
    XCTAssertTrue(session.projectUsedFontNames.isEmpty); XCTAssertEqual(store.engine.undoStack.count, count)
  }
  func testStudioMissingFacesPartialLegacyFilesAndRecentsPersistWithoutDocumentHistory() throws {
    let store = try fixture(), before = store.project, file = try directory().appendingPathComponent("legacy.json")
    try JSONSerialization.data(withJSONObject: ["favorites": ["Missing-A", "Missing-A", ""]]).write(to: file)
    let preferences = FontLibraryPreferences(file: file)
    XCTAssertEqual(preferences.favorites, ["Missing-A"]); XCTAssertTrue(preferences.recent.isEmpty)
    XCTAssertNil(preferences.error, "Missing keys are a valid older preference format")
    preferences.toggle("Missing-B")
    for index in 0..<20 { preferences.used("Missing-Recent-\(index)") }
    preferences.used("Missing-Recent-19")
    let restored = FontLibraryPreferences(file: file)
    XCTAssertEqual(restored.favorites, ["Missing-A", "Missing-B"])
    XCTAssertTrue(restored.favorite("Missing-B")); XCTAssertEqual(restored.recent.count, 12)
    XCTAssertEqual(restored.recent.first, "Missing-Recent-19")
    XCTAssertEqual(Set(restored.recent).count, 12)
    restored.toggle("Missing-A"); XCTAssertFalse(restored.favorite("Missing-A"))
    XCTAssertEqual(store.project, before); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testInvalidNamesAndFailedStudioWritesKeepThePriorCollection() throws {
    let folder = try directory(), path = folder.appendingPathComponent("prefs.json")
    let preferences = FontLibraryPreferences(file: path)
    preferences.toggle("Missing-A"); XCTAssertEqual(preferences.favorites, ["Missing-A"])
    for name in ["", "  ", "Broken\nName", String(repeating: "x", count: 301),
      "a" + String(repeating: "\u{301}", count: 1_000)] {
      preferences.toggle(name); preferences.used(name)
      XCTAssertEqual(preferences.favorites, ["Missing-A"]); XCTAssertTrue(preferences.recent.isEmpty)
    }
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    preferences.toggle("Missing-B")
    XCTAssertNotNil(preferences.error); XCTAssertEqual(preferences.favorites, ["Missing-A"])
    let store = try fixture(), before = store.project
    XCTAssertFalse(store.artworkSession.toggleProjectFont(" "))
    XCTAssertEqual(store.project, before); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testWholeFileFailuresPreserveOriginalBytesAndDefaultsOnLaterWrites() throws {
    let suite = "font-corrupt-preferences-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["Recovered-Missing-Face"], forKey: "FORM.favoriteFontFaces")
    for bytes in [Data("{broken json".utf8), Data(repeating: 32, count: FontLibraryPreferences.maximumEncodedBytes + 1)] {
      let file = try directory().appendingPathComponent("prefs.json")
      try bytes.write(to: file)
      let preferences = FontLibraryPreferences(defaults: defaults, file: file)
      XCTAssertNotNil(preferences.error)
      XCTAssertEqual(preferences.favorites, ["Recovered-Missing-Face"])
      preferences.used("Georgia"); preferences.toggle("New-Face")
      XCTAssertEqual(try Data(contentsOf: file), bytes)
      XCTAssertEqual(preferences.favorites, ["Recovered-Missing-Face"])
      XCTAssertTrue(preferences.recent.isEmpty)
      XCTAssertEqual(defaults.stringArray(forKey: "FORM.favoriteFontFaces"), ["Recovered-Missing-Face"])
      XCTAssertNil(defaults.stringArray(forKey: "FORM.recentFontFaces")); XCTAssertNotNil(preferences.error)
    }
    let unreadable = try directory().appendingPathComponent("prefs.json")
    try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
    let preferences = FontLibraryPreferences(file: unreadable)
    preferences.used("Georgia"); preferences.toggle("New-Face")
    XCTAssertNotNil(preferences.error)
    XCTAssertTrue(preferences.favorites.isEmpty); XCTAssertTrue(preferences.recent.isEmpty)
    var directory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path, isDirectory: &directory))
    XCTAssertTrue(directory.boolValue)
  }
  func testMalformedPresentPreferenceFieldsRecoverOtherFieldsWithoutOverwritingOriginal() throws {
    for invalid in ["favorites", "recent", "legacyFamilies"] {
      var raw: [String: Any] = ["favorites": ["Missing-Saved"], "recent": ["Georgia"], "legacyFamilies": ["Missing Family"]]
      raw[invalid] = "not-an-array"
      let original = try JSONSerialization.data(withJSONObject: raw)
      let file = try directory().appendingPathComponent("prefs.json")
      try original.write(to: file)
      let preferences = FontLibraryPreferences(file: file)
      XCTAssertEqual(preferences.favorites, invalid == "favorites" ? [] : ["Missing-Saved"])
      XCTAssertEqual(preferences.recent, invalid == "recent" ? [] : ["Georgia"])
      XCTAssertEqual(preferences.legacyFamilies, invalid == "legacyFamilies" ? [] : ["Missing Family"])
      XCTAssertTrue(preferences.error?.contains(invalid) == true)
      let recovered = preferences.favorites, recent = preferences.recent, families = preferences.legacyFamilies
      preferences.used("Georgia-Bold"); preferences.toggle("Another-Missing-Face")
      XCTAssertEqual(preferences.favorites, recovered); XCTAssertEqual(preferences.recent, recent)
      XCTAssertEqual(preferences.legacyFamilies, families); XCTAssertEqual(try Data(contentsOf: file), original)
      XCTAssertNotNil(preferences.error)
    }
  }
  func testDefaultsLegacyFamiliesAndExactMissingFacesSurviveMigration() throws {
    let suite = "font-collection-tests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["Georgia", "Georgia", "Missing-Saved"], forKey: "FORM.favoriteFontFaces")
    defaults.set(["Baskerville", "Missing family"], forKey: "FORM.favoriteFontFamilies")
    defaults.set(["Georgia"], forKey: "FORM.recentFontFamilies")
    let preferences = FontLibraryPreferences(defaults: defaults)
    XCTAssertEqual(preferences.favorites, ["Georgia", "Missing-Saved"])
    XCTAssertEqual(preferences.legacyFamilies, ["Baskerville", "Missing family"])
    XCTAssertEqual(preferences.recent.count, 1)
    let face = try XCTUnwrap(FontLibraryCatalog.faces.first { $0.family == "Baskerville" })
    preferences.toggle(face)
    XCTAssertFalse(preferences.favorite(face)); XCTAssertTrue(preferences.legacyFamilies.contains("Missing family"))
    let restored = FontLibraryPreferences(defaults: defaults)
    XCTAssertEqual(restored.favorites, preferences.favorites)
    XCTAssertEqual(restored.legacyFamilies, preferences.legacyFamilies)
  }
  func testStudioAliasLookupPreservesFileUntilExplicitFavoriteOrRecentMutation() throws {
    let alias = "Skia", face = try XCTUnwrap(FontLibraryCatalog.face(named: alias)), canonical = face.name
    XCTAssertNotEqual(alias, canonical, "Fixture must use the installed Skia face alias")
    let file = try directory().appendingPathComponent("aliases.json")
    let original = try JSONSerialization.data(withJSONObject: [
      "favorites": [alias, canonical, "Missing-Saved"], "recent": [alias, "Georgia", canonical]])
    try original.write(to: file)
    let preferences = FontLibraryPreferences(file: file)
    XCTAssertEqual(preferences.favorites, [alias, canonical, "Missing-Saved"])
    XCTAssertEqual(preferences.recent, [alias, "Georgia", canonical])
    XCTAssertTrue(preferences.favorite(alias)); XCTAssertTrue(preferences.favorite(canonical)); XCTAssertTrue(preferences.favorite(face))
    XCTAssertEqual(try Data(contentsOf: file), original, "Resolving saved aliases must never rewrite preferences")
    preferences.used(alias)
    XCTAssertEqual(preferences.recent, [canonical, "Georgia"])
    XCTAssertEqual(preferences.favorites, [alias, canonical, "Missing-Saved"])
    preferences.toggle(face); XCTAssertEqual(preferences.favorites, ["Missing-Saved"])
    XCTAssertFalse(preferences.favorite(alias)); XCTAssertFalse(preferences.favorite(canonical))
    preferences.toggle(alias); XCTAssertEqual(preferences.favorites, ["Missing-Saved", canonical])
    let restored = FontLibraryPreferences(file: file)
    XCTAssertEqual(restored.favorites, preferences.favorites); XCTAssertEqual(restored.recent, preferences.recent)
  }
  func testProjectAliasToggleRemovesEquivalentSavedNamesInOneUndoWithoutReadMutation() throws {
    let store = try fixture(), session = store.artworkSession
    let alias = "Skia", canonical = try XCTUnwrap(FontLibraryCatalog.face(named: alias)).name
    XCTAssertNotEqual(alias, canonical)
    var project = try XCTUnwrap(store.project)
    project.fontLibrary = .init(faceNames: [alias, canonical, "Missing-Project-Face"])
    project.schemaVersion = project.minimumSchemaVersion; store.engine.project = project
    XCTAssertTrue(session.isProjectFont(alias)); XCTAssertTrue(session.isProjectFont(canonical))
    XCTAssertEqual(store.project, project); XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertTrue(session.toggleProjectFont(canonical))
    XCTAssertEqual(session.projectFontNames, ["Missing-Project-Face"]); XCTAssertEqual(store.engine.undoStack.count, 1)
    store.undo(); XCTAssertEqual(store.project, project)
    store.redo(); XCTAssertEqual(session.projectFontNames, ["Missing-Project-Face"])
    XCTAssertTrue(session.toggleProjectFont(alias))
    XCTAssertEqual(session.projectFontNames, ["Missing-Project-Face", alias], "Explicit project choices retain their requested exact name")
    XCTAssertTrue(session.isProjectFont(canonical))
  }
  func testCollectionUndoKeepsEvictedPhysicalPreviewWhileMixedPhysicalUndoInvalidates() throws {
    let store = try fixture(), (source, definition) = try PatternAssemblySamples.roundedPouch()
    var project = source, assembly = try project.makeObject(recipeID: "patternAssembly", name: "Active assembly")
    assembly.patternAssembly = definition; project.objects.append(assembly)
    store.engine.project = project; store.showingHome = false; store.engine.selection = [assembly.id]
    try store.cloth.activate(assembly.id); store.synchronizeScene()
    defer { store.cloth.clear() }
    let builds = AssemblyProducts.builds, geometry = try XCTUnwrap(store.scene).geometryBuilds
    let identity = store.cloth.preview.source, positions = store.cloth.preview.frame?.positionsMm
    AssemblyProducts.clear()
    XCTAssertTrue(store.artworkSession.toggleProjectFont("Missing-Collection-Choice"))
    func unchanged() {
      store.synchronizeScene()
      XCTAssertEqual(store.scene?.geometryBuilds, geometry); XCTAssertEqual(AssemblyProducts.builds, builds)
      XCTAssertEqual(store.cloth.preview.source, identity); XCTAssertEqual(store.cloth.preview.frame?.positionsMm, positions)
    }
    unchanged(); store.undo(); unchanged(); store.redo(); unchanged()
    let saved = try XCTUnwrap(store.project)
    try store.engine.edit("Font collection and actual artwork together") {
      $0.fontLibrary?.faceNames.append("Another-Missing-Choice")
      $0.objects[0].artwork!.elements[0].color = "#CC5533"
    }
    store.undo()
    XCTAssertEqual(store.project, saved)
    XCTAssertGreaterThan(AssemblyProducts.builds, builds,
      "A mixed font-collection/physical edit must retain ordinary physical-history invalidation")
  }
}

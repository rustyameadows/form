import XCTest
@testable import FormCore

final class ProjectFontLibraryTests: XCTestCase {
  private func repository() throws -> ProjectRepository {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-font-library-" + UUID().uuidString)
    let repository = try ProjectRepository(root: root)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return repository
  }
  func testSavedMissingFacesTravelInProjectPackageWithSchemaAndNoFontAssets() throws {
    let repository = try repository()
    var project = Project(name: "Portable font choices")
    project.fontLibrary = .init(faceNames: ["FORM-Missing-Display", "Georgia-Bold", "書体-Regular"])
    XCTAssertEqual(project.minimumSchemaVersion, 59)
    try repository.save(project)
    let loaded = try repository.load(project.id)
    XCTAssertEqual(loaded.fontLibrary, project.fontLibrary); XCTAssertEqual(loaded.schemaVersion, 59)
    let assetNames = try FileManager.default.contentsOfDirectory(atPath: repository.url(for: project.id).appendingPathComponent("Assets").path)
    XCTAssertTrue(assetNames.isEmpty, "Saving font choices must not copy or register font binaries")
    let manifest = try Data(contentsOf: repository.url(for: project.id).appendingPathComponent("Manifest.json"))
    XCTAssertTrue(String(decoding: manifest, as: UTF8.self).contains("FORM-Missing-Display"))
  }
  func testOlderProjectsNeedNoFontCollectionAndPreserveTheirSchema() throws {
    let project = Project(name: "Before collections")
    XCTAssertNil(project.fontLibrary); XCTAssertEqual(project.minimumSchemaVersion, 1)
    let encoded = try JSONEncoder.form.encode(project)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fontLibrary"))
    let decoded = try JSONDecoder.form.decode(Project.self, from: encoded)
    XCTAssertNil(decoded.fontLibrary); XCTAssertEqual(decoded.minimumSchemaVersion, 1)
  }
  func testInvalidCollectionCannotReplaceAnExistingProjectPackage() throws {
    let repository = try repository()
    var project = Project(name: "Bounded saved choices")
    project.fontLibrary = .init(faceNames: ["Missing-Regular"])
    try repository.save(project)
    let path = repository.url(for: project.id).appendingPathComponent("Manifest.json")
    let original = try Data(contentsOf: path)
    for names in [["A", "A"], [""], ["   "], ["A\nB"], [String(repeating: "x", count: 301)],
      ["a" + String(repeating: "\u{301}", count: 1_000)],
      (0...1024).map { "Face-\($0)" }] {
      project.fontLibrary = .init(faceNames: names)
      XCTAssertThrowsError(try project.validateArtworkLinks())
      XCTAssertThrowsError(try repository.save(project))
      XCTAssertEqual(try Data(contentsOf: path), original)
    }
  }
  func testExactNamesAndOrderAreStableAndBoundedMutationIsAtomic() throws {
    var library = ProjectFontLibrary(faceNames: ["Face", "face"])
    try library.setSaved("Face", saved: true)
    XCTAssertEqual(library.faceNames, ["Face", "face"])
    try library.setSaved("Missing-Italic", saved: true)
    try library.setSaved("Face", saved: false)
    XCTAssertEqual(library.faceNames, ["face", "Missing-Italic"])
    library.faceNames = (0..<1024).map { "Face-\($0)" }; let before = library
    XCTAssertThrowsError(try library.setSaved("Another face", saved: true))
    XCTAssertEqual(library, before)
    try library.setSaved("Face-0", saved: false)
    try library.setSaved("Another face", saved: true)
    XCTAssertEqual(library.faceNames.last, "Another face"); XCTAssertEqual(library.faceNames.count, 1024)
  }
}

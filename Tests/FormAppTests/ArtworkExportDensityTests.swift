import AppKit
import XCTest
@testable import FormCore
@testable import FormApp

@MainActor final class ArtworkExportDensityTests: XCTestCase {
  private func fixture() throws -> (StudioStore, URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root: root)
    var project = Project(name: "Requested raster density")
    var object = try project.makeObject(recipeID: "artboard", parameters: ["width": 230, "depth": 165])
    object.artwork = Artwork(background: "#F6F3EB", elements: [
      ArtworkElement(kind: "rectangle", x: 12, y: 12, width: 120, height: 90, color: "#203A4A")
    ])
    project.objects = [object]
    try repository.save(project)
    let store = StudioStore(repository: repository, seedLibrary: false)
    try store.engine.open(project.id)
    store.showingHome = false
    return (store, root)
  }

  func testNativeIntegerAndDecimalDPIHonorTheSamePhysicalPixelRequest() throws {
    let (store, root) = try fixture(), before = store.project!
    var images: [Data] = []
    for (index, dpi) in [150 as Any, 150.0 as Any].enumerated() {
      let url = root.appendingPathComponent("density-\(index).png")
      _ = try store.exportArtwork(object: before.objects[0], arguments: ["format": "png", "path": url.path, "dpi": dpi])
      let data = try Data(contentsOf: url), bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
      XCTAssertEqual(bitmap.pixelsWide, 1358)
      XCTAssertEqual(bitmap.pixelsHigh, 974)
      images.append(data)
    }
    XCTAssertEqual(images[0], images[1])
    let legacy = root.appendingPathComponent("default.png")
    _ = try store.exportArtwork(object: before.objects[0], arguments: ["format": "png", "path": legacy.path])
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: legacy)))
    XCTAssertEqual(bitmap.pixelsWide, 2717)
    XCTAssertEqual(bitmap.pixelsHigh, 1949)
    XCTAssertEqual(store.project, before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testInvalidExplicitDPINeverFallsBackOrReplacesExistingOutput() throws {
    let (store, root) = try fixture(), before = store.project!
    let url = root.appendingPathComponent("existing.png"), sentinel = Data("Keep existing output".utf8)
    try sentinel.write(to: url)
    for value in [true as Any, "150" as Any, NSNull(), Double.nan, Double.infinity, 17, 1300] {
      XCTAssertThrowsError(try store.exportArtwork(object: before.objects[0], arguments: [
        "format": "png", "path": url.path, "dpi": value,
      ]))
      XCTAssertEqual(try Data(contentsOf: url), sentinel)
      XCTAssertEqual(store.project, before)
      XCTAssertTrue(store.engine.undoStack.isEmpty)
    }
  }
}

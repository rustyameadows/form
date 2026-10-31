import Foundation
import FormCore
import XCTest
@testable import FormApp

@MainActor final class ObjectViewPageExportTests: XCTestCase {
  private func fixture() throws -> (StudioStore, URL, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ProjectRepository(root: root)
    let store = StudioStore(repository: repository, seedLibrary: false)
    let source = ProductObject(name: "Source", recipeID: "box", parameters: ["width": 20, "height": 20, "depth": 20])
    var image = ArtworkElement(kind: "image", x: 10, y: 10, width: 20, height: 20, asset: "prior.png")
    image.objectView = .init(sourceID: source.id, style: "rendered", linked: true)
    image.objectView?.renderPending = true
    let page = ProductObject(name: "Page", recipeID: "artboard", parameters: ["width": 100, "depth": 100],
      artwork: Artwork(elements: [image]))
    var project = Project(name: "Pending page"); project.objects = [source, page]
    let assets = repository.url(for: project.id).appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    // The old image is valid and can be previewed; it must not bypass the pending guard.
    let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    try png.write(to: assets.appendingPathComponent("prior.png"))
    store.engine.project = project
    return (store, root, page.id)
  }

  func testDirectPhysicalPageExportBlocksPendingLinkedRenderBeforeWritingFile() throws {
    let (store, root, pageID) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = store.project, path = root.appendingPathComponent("pending.pdf")
    XCTAssertThrowsError(try store.exportArtworkPage(objectID: pageID, arguments: [
      "format": "pdf", "page_output": ["area": "trim"], "path": path.path,
    ])) { error in
      XCTAssertTrue(error.localizedDescription.contains("still updating"), error.localizedDescription)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    XCTAssertEqual(store.project, before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testNativePageReviewExportCannotBypassPendingGuard() throws {
    let (store, root, pageID) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let review = ArtworkPageReviewModel(store: store, objectID: pageID)
    review.refresh()
    XCTAssertNotNil(review.proof, review.error)
    XCTAssertTrue(review.matchesReview, review.error)
    let path = root.appendingPathComponent("native-review.pdf")
    XCTAssertFalse(review.export(path: path))
    XCTAssertTrue(review.error.contains("still updating"), review.error)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
  }

  func testSourcePreflightAndDeliberatelyFrozenViewRemainAvailable() throws {
    let (store, root, pageID) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertNoThrow(try store.exportArtworkPage(objectID: pageID, arguments: [
      "format": "preflight", "page_output": ["area": "trim"],
    ]))
    var project = try XCTUnwrap(store.project)
    let i = try XCTUnwrap(project.objects.firstIndex { $0.id == pageID })
    project.objects[i].artwork?.elements[0].objectView?.linked = false
    store.engine.project = project
    let path = root.appendingPathComponent("frozen.pdf")
    _ = try store.exportArtworkPage(objectID: pageID, arguments: [
      "format": "pdf", "page_output": ["area": "trim"], "path": path.path,
    ])
    XCTAssertGreaterThan(try Data(contentsOf: path).count, 0)
  }
}

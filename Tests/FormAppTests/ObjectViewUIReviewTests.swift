import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class ObjectViewUIReviewTests: XCTestCase {
  func testRenderedRefreshKeepsCropAndImageAdjustments() {
    var image = ArtworkElement(kind: "image", x: 10, y: 20, width: 60, height: 30, asset: "before.png")
    image.imageCrop = ImageCrop(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
    image.imageAdjustments = ImageAdjustments(brightness: 0.2, contrast: 1.3, saturation: 0.8)
    image.rotation = 25; image.opacity = 0.7
    let crop = image.imageCrop, adjustments = image.imageAdjustments
    var settings = ObjectViewSettings(sourceID: UUID(), azimuth: 90, style: "rendered")
    settings.referenceAspect = 2
    ObjectViewRenderResult.apply(to: &image, asset: "after.png", settings: settings)
    XCTAssertEqual(image.asset, "after.png")
    XCTAssertEqual(image.imageCrop, crop)
    XCTAssertEqual(image.imageAdjustments, adjustments)
    XCTAssertEqual(image.rotation, 25)
    XCTAssertEqual(image.opacity, 0.7)
    XCTAssertEqual(image.objectView, settings)
  }

  func testProjectBoundaryCancelsPendingCapture() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    let project = Project(name: "Pending")
    try store.repository.save(project)
    store.engine.project = project
    let session = store.artworkSession, token = session.objectViewRenderToken
    let task = Task { _ = try? await Task.sleep(nanoseconds: 30_000_000_000) }
    session.objectViewRenderTask = task; session.objectViewRendering = true
    // Reopening the same document must cancel work even if its snapshot is identical.
    try store.engine.open(project.id)
    XCTAssertTrue(task.isCancelled)
    XCTAssertNotEqual(session.objectViewRenderToken, token)
    XCTAssertFalse(session.objectViewRendering)
    XCTAssertNil(session.objectViewRenderTask)
  }

  func testSourceStateIncludesLinkedArtworkButIgnoresTablePose() {
    let tile = ProductObject(name: "Artwork", recipeID: "artboard", parameters: ["width": 20, "depth": 20],
      artwork: Artwork(background: "#FFFFFF"))
    var source = ProductObject(name: "Source", recipeID: "box", parameters: ["width": 20, "depth": 20])
    source.artworkSourceID = tile.id
    var project = Project(name: "Preview"); project.objects = [tile, source]
    let original = LinkedObjectViewRenderer.state(source, in: project)
    source.position.x = 100; source.rotation = 90; project.objects[1] = source
    XCTAssertEqual(original, LinkedObjectViewRenderer.state(source, in: project))
    project.objects[0].artwork?.background = "#000000"
    XCTAssertNotEqual(original, LinkedObjectViewRenderer.state(source, in: project))
  }
}

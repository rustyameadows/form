import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasAccessibilityPerformanceTests: XCTestCase {
  private func denseArtwork() -> (Artwork, UUID, UUID) {
    var elements: [ArtworkElement] = []
    var firstGroup: UUID?, firstLeaf: UUID?
    for row in 0..<24 {
      let group = ArtworkElement(kind: "group", x: Double(row%6)*45, y: Double(row/6)*45, width: 40, height: 40)
      elements.append(group)
      if firstGroup == nil { firstGroup = group.id }
      for column in 0..<24 {
        var leaf = ArtworkElement(kind: "rectangle", x: Double(column%6)*5, y: Double(column/6)*7, width: 4, height: 5)
        leaf.parentID = group.id; elements.append(leaf)
        if firstLeaf == nil { firstLeaf = leaf.id }
      }
    }
    return (Artwork(elements: elements), firstGroup!, firstLeaf!)
  }
  func testDenseAccessibilityBoundsAreLazyAndIndependentOfCanvasPlacement() throws {
    var (art, group, leaf) = denseArtwork()
    let cache = CanvasAccessibilitySnapshot()
    XCTAssertTrue(cache.update(art))
    XCTAssertEqual(cache.boundsBuilds, 0, "Building AX labels must not resolve every nested vector bound.")
    let expected = art.bounds(of: try XCTUnwrap(art.elements.first { $0.id == group }))
    XCTAssertEqual(cache.bounds(of: group), expected)
    XCTAssertEqual(cache.boundsBuilds, 1)
    for n in 1...50 {
      art.canvasPosition = .init(Double(n)*10, -Double(n)*5)
      XCTAssertFalse(cache.update(art))
      XCTAssertEqual(cache.bounds(of: group), expected)
    }
    XCTAssertEqual(cache.builds, 1); XCTAssertEqual(cache.boundsBuilds, 1)
    let i = try XCTUnwrap(art.elements.firstIndex { $0.id == leaf })
    art.elements[i].width = 80
    XCTAssertTrue(cache.update(art))
    XCTAssertEqual(cache.bounds(of: leaf)?.width, 80,
      "Ordinary group selection bounds remain their authored frame; the edited leaf must refresh.")
    XCTAssertEqual(cache.boundsBuilds, 2)
    art.elements.removeAll { $0.id == leaf }
    XCTAssertTrue(cache.update(art)); XCTAssertNil(cache.bounds(of: leaf))
  }
  func testNativeAccessibilityFrameTracksPanZoomAndSelectionWithoutRebuildingVectorBounds() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-ax-cache-"+UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Dense accessibility surface")
    var board = try project.makeObject(recipeID: "artboard", parameters: ["width": 300, "depth": 200])
    let (art, _, leaf) = denseArtwork(); board.artwork = art; project.objects = [board]
    store.engine.project = project; store.showingHome = false
    let session = store.artworkSession; session.activate(board.id)
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = ArtworkScrollView(frame: window.contentView!.bounds)
    scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
    let canvas = VectorCanvasView(frame: scroll.bounds); canvas.session = session; session.canvas = canvas
    scroll.documentView = canvas; window.contentView = scroll
    defer { window.contentView = nil; window.close(); store.engine.project = nil; try? FileManager.default.removeItem(at: root) }
    canvas.synchronize(); canvas.fit(all: true); canvas.setZoom(1)
    let child = try XCTUnwrap((canvas.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityIdentifier() == leaf.uuidString })
    let before = child.accessibilityFrame()
    let geometryBuilds = try XCTUnwrap(canvas.diagnostics["accessibility_bounds_builds"] as? Int)
    let snapshotBuilds = try XCTUnwrap(canvas.diagnostics["accessibility_snapshot_builds"] as? Int)
    let prior = store.project, undo = store.engine.undoStack.count
    let origin = scroll.contentView.bounds.origin
    scroll.contentView.scroll(to: .init(x: origin.x+60, y: origin.y+40))
    let moved = child.accessibilityFrame()
    XCTAssertNotEqual(before.origin, moved.origin)
    XCTAssertEqual(before.size, moved.size)
    for _ in 0..<20 { canvas.synchronize(); _ = child.accessibilityFrame() }
    XCTAssertEqual(canvas.diagnostics["accessibility_bounds_builds"] as? Int, geometryBuilds)
    XCTAssertEqual(canvas.diagnostics["accessibility_snapshot_builds"] as? Int, snapshotBuilds)
    canvas.setZoom(2)
    let enlarged = child.accessibilityFrame()
    XCTAssertEqual(enlarged.width, before.width*2, accuracy: 0.00001)
    session.choose([leaf]); canvas.synchronize()
    XCTAssertEqual(child.accessibilityValue() as? String, "Selected")
    XCTAssertEqual(canvas.diagnostics["accessibility_bounds_builds"] as? Int, geometryBuilds)
    XCTAssertEqual(store.project, prior); XCTAssertEqual(store.engine.undoStack.count, undo)
  }
}

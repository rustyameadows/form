import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasInteractionCacheTests: XCTestCase {
  func testRepeatedUISynchronizationKeepsPickerAndDirectSourceAssignmentsInvalidateBeforeNextHover() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-pick-cache-"+UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Reusable native picking")
    let target = ArtworkElement(kind: "rectangle", x: 20, y: 20, width: 40, height: 30)
    var board = try project.makeObject(recipeID: "artboard", parameters: ["width": 100, "depth": 80])
    var art = Artwork(elements: [target]); art.canvasPosition = .init()
    for index in 0..<600 {
      art.elements.append(.init(kind: "ellipse", x: 140+Double(index%30)*5, y: Double(index/30)*5, width: 3, height: 3))
    }
    board.artwork = art; project.objects = [board]
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
    func hover(_ x: Double) {
      let point = canvas.convert(canvas.documentPoint(.init(x: x,y: 35)), to: nil)
      let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
      canvas.mouseMoved(with: event)
    }
    hover(40)
    XCTAssertEqual(canvas.hoveredElementID, target.id)
    let builds = try XCTUnwrap(canvas.diagnostics["hover_picker_builds"] as? Int)
    let snapshots = try XCTUnwrap(canvas.diagnostics["frame_snapshot_updates"] as? Int)
    for _ in 0..<30 { canvas.synchronize(); hover(40) }
    XCTAssertEqual(canvas.diagnostics["hover_picker_builds"] as? Int, builds)
    XCTAssertEqual(canvas.diagnostics["frame_snapshot_updates"] as? Int, snapshots)
    XCTAssertEqual(store.project, project); XCTAssertTrue(store.engine.undoStack.isEmpty)
    session.tool = .hand; canvas.synchronize()
    XCTAssertNil(canvas.hoveredElementID, "A stationary pointer must not retain an outline after a keyboard tool change.")
    XCTAssertEqual(canvas.diagnostics["hover_picker_builds"] as? Int, builds)
    session.tool = .select; canvas.synchronize(); hover(40)
    XCTAssertEqual(canvas.hoveredElementID, target.id)
    session.choose([target.id]); canvas.synchronize()
    XCTAssertNil(canvas.hoveredElementID, "Selecting the hovered layer must clear its unselected hover outline.")
    hover(40)
    XCTAssertEqual(canvas.pointerFeedback, .move)
    session.choose([]); canvas.synchronize()
    XCTAssertEqual(canvas.pointerFeedback, .arrow)
    hover(40)
    XCTAssertEqual(canvas.hoveredElementID, target.id)
    session.hiddenProductionRoles = [.print]; canvas.synchronize()
    XCTAssertNil(canvas.hoveredElementID, "Hiding a production role must clear stationary hover feedback.")
    hover(40); XCTAssertNil(canvas.hoveredElementID)
    let roleBuilds = canvas.diagnostics["hover_picker_builds"] as? Int
    session.hiddenProductionRoles = []; canvas.synchronize(); hover(40)
    XCTAssertEqual(canvas.hoveredElementID, target.id)
    XCTAssertEqual(canvas.diagnostics["hover_picker_builds"] as? Int, roleBuilds,
      "Returning to the previous interaction context should reuse its prepared picker.")
    XCTAssertEqual(canvas.diagnostics["frame_snapshot_updates"] as? Int, snapshots)
    XCTAssertEqual(store.project, project); XCTAssertTrue(store.engine.undoStack.isEmpty)
    let revision = store.revision
    var replacement = project; replacement.objects[0].artwork!.elements[0].x = 70
    store.engine.project = replacement
    XCTAssertEqual(store.revision, revision); XCTAssertEqual(replacement.updatedAt, project.updatedAt)
    hover(40)
    XCTAssertNil(canvas.hoveredElementID, "Native hover must see direct source replacement before SwiftUI synchronizes.")
    hover(90)
    XCTAssertEqual(canvas.hoveredElementID, target.id)
    XCTAssertGreaterThan(canvas.diagnostics["hover_picker_builds"] as? Int ?? 0, builds)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    let other = StudioStore(repository: try ProjectRepository(root: root.appendingPathComponent("second-engine")), seedLibrary: false)
    defer { other.engine.project = nil }
    while other.engine.projectGeneration < store.engine.projectGeneration { other.engine.project = project }
    XCTAssertEqual(other.engine.projectGeneration, store.engine.projectGeneration)
    XCTAssertEqual(other.revision, store.revision)
    other.artworkSession.activate(board.id)
    canvas.session = other.artworkSession; other.artworkSession.canvas = canvas
    hover(40)
    XCTAssertEqual(canvas.hoveredElementID, target.id,
      "Equal per-engine generation numbers must not reuse another engine's source snapshot.")
  }
}

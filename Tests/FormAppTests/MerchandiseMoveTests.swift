import AppKit
import FormGeometry
import XCTest

@testable import FormApp
@testable import FormCore

@MainActor final class MerchandiseMoveTests: XCTestCase {
  func testActualMouseMoveOfTurnedOverTeeKeepsHeightAndMovesItsSelectedPrintOnlyOnce() throws {
    _ = NSApplication.shared
    for childFirst in [false, true] {
      for combined in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = try Samples.merchandiseCollection()
        var host = original.objects.first { $0.recipeID == "crewTee" }!
        var ink = original.objects.first { $0.name == "Tee / independent back signature" }!
        host.textile!.laidFaceDown = true
        host.rotation = 19
        host.position = .init(180, 0, -240)
        ink.artwork = original.editableArtwork(ink)
        ink.artworkSourceID = nil
        var p = Project(name: "Native flipped blank move")
        p.objects = childFirst ? [ink, host] : [host, ink]
        p.schemaVersion = p.minimumSchemaVersion
        let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
        store.engine.project = p
        store.showingHome = false
        let window = NSWindow(
          contentRect: .init(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled],
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TableSceneView(frame: .init(x: 0, y: 0, width: 1200, height: 800))
        let scene = TableSceneController(store: store)
        view.controller = scene
        scene.view = view
        store.scene = scene
        window.contentView = view
        window.makeFirstResponder(view)
        defer {
          view.cancelPointerInteraction()
          window.contentView = nil
          window.close()
          store.engine.project = nil
          try? FileManager.default.removeItem(at: root)
        }
        store.engine.selection = combined ? [host.id, ink.id] : [host.id]
        store.setTableTool(.move)
        store.synchronizeScene()
        scene.preset("overhead")
        scene.focusSelection()
        let picked = combined ? ink : host
        let objectNode = scene.objectRoot.childNode(
          withName: "object:\(picked.id.uuidString)", recursively: false)!
        let local =
          combined
          ? MeshVector3(0, ink["height"] / 100, 0)
          : MeshVector3(-host["width"] * 0.3 / 100, 4 / 100, host["depth"] * 0.25 / 100)
        let projected = view.projectPoint(objectNode.convertPosition(local, to: nil))
        let start = NSPoint(x: projected.x, y: projected.y)
        let end = NSPoint(x: start.x + 48, y: start.y - 29)
        XCTAssertEqual(scene.objectID(at: start), picked.id)
        let before = store.project!
        let builds = scene.geometryBuilds
        let oldInk = before.textilePlacement(ink)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
          NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, start))
        view.mouseDragged(with: event(.leftMouseDragged, end))
        view.mouseUp(with: event(.leftMouseUp, end))
        store.synchronizeScene()
        let movedHost = store.project!.objects.first { $0.id == host.id }!
        let movedInk = store.project!.objects.first { $0.id == ink.id }!
        let newInk = store.project!.textilePlacement(movedInk)
        XCTAssertNotEqual(movedHost.position.x, host.position.x)
        XCTAssertEqual(movedHost.position.y, 0, accuracy: 1e-8)
        XCTAssertEqual(movedInk, ink)
        XCTAssertEqual(newInk.position.y, oldInk.position.y, accuracy: 1e-8)
        XCTAssertEqual(
          newInk.position.x - oldInk.position.x, movedHost.position.x - host.position.x,
          accuracy: 1e-8)
        XCTAssertEqual(
          newInk.position.z - oldInk.position.z, movedHost.position.z - host.position.z,
          accuracy: 1e-8)
        XCTAssertEqual(scene.geometryBuilds, builds)
        XCTAssertEqual(store.engine.undoStack.count, 1)
        XCTAssertFalse(window.isVisible)
        store.undo()
        XCTAssertEqual(store.project, before)
      }
    }
  }
}

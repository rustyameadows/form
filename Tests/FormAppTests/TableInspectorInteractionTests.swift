import AppKit
import FormGeometry
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore

@MainActor final class TableInspectorInteractionTests: XCTestCase {
  private func fixture() throws -> (StudioStore, UUID, UUID, URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var p = Project(name: "Independent viewports")
    var a = try p.makeObject(recipeID: "box"), b = try p.makeObject(recipeID: "box")
    a.position = .init(-180, 0, 0); b.position = .init(180, 0, 0)
    a.artwork = .init(elements: [.init(kind: "rectangle", x: 5, y: 5, width: 10, height: 10)])
    b.artwork = .init(elements: [.init(kind: "text", x: 5, y: 5, width: 40, height: 10, text: "Second")])
    p.objects = [a, b]; store.engine.project = p; store.showingHome = false
    store.surfaceLayout = .split; store.artworkSession.activate(a.id)
    addTeardownBlock { @MainActor in
      store.artworkSession.canvas?.finishText(); store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    return (store, a.id, b.id, root)
  }
  func testInspectorVisibilityIsIndependentOfSelectionAndExplicitFindDoesNotReopenIt() throws {
    let (store, a, b, _) = try fixture()
    store.selectOnTable(a); XCTAssertTrue(store.tableInspectorVisible)
    let before = store.project!, history = store.engine.undoStack.count
    store.closeTableInspector()
    XCTAssertEqual(store.engine.selection, [a]); XCTAssertFalse(store.tableInspectorVisible)
    store.artworkSession.activate(b); store.artworkSession.reconcile()
    XCTAssertEqual(store.engine.selection, [a]); XCTAssertFalse(store.tableInspectorVisible)
    XCTAssertEqual(store.artworkSession.objectID, b)
    XCTAssertTrue(store.findOnTable(b))
    XCTAssertEqual(store.engine.selection, [b]); XCTAssertFalse(store.tableInspectorVisible)
    store.toggleTableInspector(); XCTAssertTrue(store.tableInspectorVisible)
    store.closeTableInspector(); store.selectOnTable(b)
    XCTAssertTrue(store.tableInspectorVisible, "A deliberate Table pick can reopen its own inspector")
    store.selectOnTable(nil); XCTAssertFalse(store.tableInspectorVisible)
    XCTAssertEqual(store.project!.objects, before.objects)
    XCTAssertEqual(store.engine.undoStack.count, history)
  }
  func testNativeTablePickDoesNotNavigateCanvasAndCloseDoesNotDeselect() throws {
    let (store, a, b, _) = try fixture()
    let c = TableSceneController(store: store), v = TableSceneView(frame: .init(x: 0, y: 0, width: 1000, height: 700))
    let window = NSWindow(contentRect: v.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = v
    v.controller = c; c.view = v; store.scene = c; store.synchronizeScene(); c.preset("front")
    defer { window.contentView = nil; window.close() }
    let source = store.artworkSession.objectID, elements = store.artworkSession.selection
    let node = try XCTUnwrap(c.logicalNode(for: b)), bounds = node.boundingBox
    let center = node.convertPosition(.init((bounds.min.x+bounds.max.x)/2, (bounds.min.y+bounds.max.y)/2, (bounds.min.z+bounds.max.z)/2), to: nil)
    let p = c.cameraNode.convertPosition(center, from: nil), m = c.cameraNode.camera!.projectionTransform
    let w = m.m14*p.x+m.m24*p.y+m.m34*p.z+m.m44
    let x = (m.m11*p.x+m.m21*p.y+m.m31*p.z+m.m41)/w
    let y = (m.m12*p.x+m.m22*p.y+m.m32*p.z+m.m42)/w
    let local = NSPoint(x: (x/(v.bounds.width/v.bounds.height)+1)*v.bounds.width/2, y: (y+1)*v.bounds.height/2)
    XCTAssertEqual(c.objectID(at: local), b, "The native event must hit the actual intended object")
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let e = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: v.convert(local, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
      if type == .leftMouseDown { v.mouseDown(with: e) } else { v.mouseUp(with: e) }
    }
    store.artworkSession.reconcile()
    XCTAssertEqual(store.engine.selection, [b]); XCTAssertTrue(store.tableInspectorVisible)
    XCTAssertEqual(store.artworkSession.objectID, source); XCTAssertEqual(source, a)
    XCTAssertEqual(store.artworkSession.selection, elements)
    let camera = c.camera
    store.closeTableInspector()
    XCTAssertEqual(store.engine.selection, [b]); XCTAssertEqual(c.camera, camera)
    XCTAssertFalse(store.tableInspectorVisible)
  }
}

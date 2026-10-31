import Foundation
import FormCore
import XCTest
@testable import FormApp

@MainActor final class ObjectViewCompletionSafetyTests: XCTestCase {
  private final class CaptureGate {
    var continuation: CheckedContinuation<Data, Never>?
  }

  private func fixture() throws -> (StudioStore, URL, ProductObject, ArtworkElement, ArtworkElement) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    let source = ProductObject(name: "Source", recipeID: "box", parameters: ["width": 20, "height": 20, "depth": 20])
    var target = ArtworkElement(kind: "image", x: 10, y: 10, width: 30, height: 30, asset: "before.png")
    target.objectView = .init(sourceID: source.id, style: "rendered", linked: false)
    let other = ArtworkElement(kind: "rectangle", x: 55, y: 10, width: 20, height: 20, color: "#2751A0")
    let page = ProductObject(name: "Page", recipeID: "artboard", parameters: ["width": 100, "depth": 100],
      artwork: Artwork(elements: [target, other]))
    var project = Project(name: "Completion safety"); project.objects = [source, page]
    store.engine.project = project
    store.artworkSession.activate(page.id)
    store.artworkSession.selection = [target.id]
    return (store, root, source, target, other)
  }

  func testExpandedSelectionDoesNotOverwriteUnrelatedElement() async throws {
    let (store, root, source, target, other) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = store.artworkSession, gate = CaptureGate()
    let started = expectation(description: "capture is waiting")
    var settings = try XCTUnwrap(target.objectView); settings.azimuth = 35
    session.configureObjectView(settings, render: { _, _, _, _, _, _, _ in
      started.fulfill()
      return await withCheckedContinuation { gate.continuation = $0 }
    })
    let task = try XCTUnwrap(session.objectViewRenderTask)
    await fulfillment(of: [started], timeout: 5)
    session.selection.insert(other.id)
    try XCTUnwrap(gate.continuation).resume(returning: Data("completed capture".utf8))
    await task.value

    let result = try XCTUnwrap(session.art.elements.first { $0.id == target.id })
    XCTAssertNotEqual(result.asset, target.asset)
    XCTAssertEqual(result.objectView?.azimuth, 35)
    XCTAssertEqual(session.art.elements.first { $0.id == other.id }, other)
    XCTAssertEqual(session.selection, [target.id, other.id])
    XCTAssertEqual(store.project?.objects.first { $0.id == source.id }, source)
    XCTAssertEqual(store.engine.undoStack.count, 1)
    store.engine.undo()
    XCTAssertEqual(session.art.elements, [target, other])
    store.engine.redo()
    XCTAssertEqual(session.art.elements.first { $0.id == target.id }, result)
    XCTAssertEqual(session.art.elements.first { $0.id == other.id }, other)
  }

  func testDeselectedTargetCannotReceiveLateCapture() async throws {
    let (store, root, _, target, other) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = store.artworkSession, gate = CaptureGate()
    let before = try XCTUnwrap(store.project)
    let started = expectation(description: "capture is waiting")
    session.configureObjectView(try XCTUnwrap(target.objectView), render: { _, _, _, _, _, _, _ in
      started.fulfill()
      return await withCheckedContinuation { gate.continuation = $0 }
    })
    let task = try XCTUnwrap(session.objectViewRenderTask)
    await fulfillment(of: [started], timeout: 5)
    session.selection = [other.id]
    try XCTUnwrap(gate.continuation).resume(returning: Data("late capture".utf8))
    await task.value

    XCTAssertEqual(store.project, before)
    XCTAssertEqual(session.selection, [other.id])
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertFalse(session.objectViewRendering)
  }

  func testSourceEditInvalidatesPendingCapture() async throws {
    let (store, root, source, target, other) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = store.artworkSession, gate = CaptureGate()
    let started = expectation(description: "capture is waiting")
    session.configureObjectView(try XCTUnwrap(target.objectView), render: { _, _, _, _, _, _, _ in
      started.fulfill()
      return await withCheckedContinuation { gate.continuation = $0 }
    })
    let task = try XCTUnwrap(session.objectViewRenderTask)
    await fulfillment(of: [started], timeout: 5)
    try store.engine.edit("Changed source") { project in
      let i = try XCTUnwrap(project.objects.firstIndex { $0.id == source.id })
      project.objects[i].parameters["width"] = 40
    }
    let changed = store.project
    try XCTUnwrap(gate.continuation).resume(returning: Data("obsolete source capture".utf8))
    await task.value

    XCTAssertEqual(store.project, changed)
    XCTAssertEqual(session.art.elements, [target, other])
    XCTAssertEqual(store.engine.undoStack.count, 1)
    XCTAssertFalse(session.objectViewRendering)
  }
}

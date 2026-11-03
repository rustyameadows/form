import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class SelectionContextBoundsTests: XCTestCase {
  private func identity(_ value: Int) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)))
  }

  private func store() throws -> StudioStore {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-bounds-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    store.showingHome = false
    addTeardownBlock { @MainActor in
      store.bridge.stop(); store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    return store
  }

  private func dictionary(_ value: Any?) throws -> [String: Any] {
    try XCTUnwrap(value as? [String: Any])
  }

  func testLargeReferenceBoundsEachListAndPreservesFullClipboardReference() throws {
    let ids = (1...100_000).map(identity)
    var reference = LABSelectionReference(projectID: UUID(), kind: "artwork_elements", label: "Dense selection")
    reference.objectIDs = ids; reference.elementIDs = ids; reference.nodeIDs = ids
    let bounded = reference.contextJSON
    XCTAssertEqual(bounded["ids_limit"] as? Int, 4_096)
    XCTAssertEqual(bounded["ids_complete"] as? Bool, false)
    for key in ["object_ids", "element_ids", "node_ids"] {
      XCTAssertEqual((bounded[key] as? [String])?.count, 4_096)
      XCTAssertEqual((bounded[key] as? [String])?.last, ids[4_095].uuidString)
    }
    for key in ["object_count", "element_count", "node_count"] {
      XCTAssertEqual(bounded[key] as? Int, 100_000)
    }
    // The bridge serializes a context several times through reference aliases.
    // Even repeated maximal previews must fit comfortably inside its 8 MiB cap.
    let envelope: [String: Any] = ["active_target": bounded,
      "canvas": ["reference": bounded, "selected_element_ids": bounded["element_ids"]!,
        "selected_node_ids": bounded["node_ids"]!], "table": ["reference": bounded]]
    let bytes = try JSONSerialization.data(withJSONObject: envelope)
    XCTAssertLessThan(bytes.count, 2 * 1_024 * 1_024)
    let full = reference.copiedText
    XCTAssertTrue(full.hasPrefix("LAB selection reference\n"))
    let restored = try JSONDecoder().decode(LABSelectionReference.self,
      from: Data(full.dropFirst("LAB selection reference\n".count).utf8))
    XCTAssertEqual(restored, reference)
    XCTAssertEqual(reference.copiedIDs.split(separator: "\n").count, 100_000)
    XCTAssertEqual(reference.copiedIDs.split(separator: "\n").last.map(String.init), ids.last?.uuidString)
    var exactLimit = reference
    exactLimit.objectIDs = Array(ids.prefix(4_096)); exactLimit.elementIDs = []; exactLimit.nodeIDs = []
    XCTAssertEqual(exactLimit.contextJSON["ids_complete"] as? Bool, true)
  }

  func testNativeCanvasBoundsSelectedNodesAndLayersWithoutChangingSelection() throws {
    let store = try store()
    var project = Project(name: "Bounded Canvas context")
    var board = try project.makeObject(recipeID: "artboard")
    let nodes = (1...100_000).map { index -> BezierNode in
      var node = BezierNode(.init(Double(index % 100), Double(index / 100) / 10))
      node.id = identity(index); return node
    }
    var path = ArtworkElement(kind: "path", x: 0, y: 0, width: 100, height: 100)
    path.path = .init(width: 100, height: 100, contours: [.init(nodes, closed: false)])
    let shapes = (0..<4_096).map { index in
      ArtworkElement(kind: "rectangle", x: Double(index % 64), y: Double(index / 64), width: 1, height: 1)
    }
    board.artwork = .init(elements: [path] + shapes)
    project.objects = [board]; store.engine.project = project
    store.environment = .form; store.mode = .artwork
    store.artworkSession.activate(board.id)
    store.artworkSession.choose(Set(board.artwork!.elements.map(\.id)))
    store.artworkSession.nodes = Set(nodes.map(\.id))
    let before = store.project, generation = store.engine.projectGeneration
    let context = store.selectionContext()
    let canvas = try dictionary(context["canvas"]), active = try dictionary(context["active_target"])
    let reference = try dictionary(canvas["reference"])
    XCTAssertEqual((canvas["selected_node_ids"] as? [String])?.count, 4_096)
    XCTAssertEqual((canvas["selected_element_ids"] as? [String])?.count, 4_096)
    XCTAssertEqual(canvas["selected_node_count"] as? Int, 100_000)
    XCTAssertEqual(canvas["selected_element_count"] as? Int, 4_097)
    XCTAssertEqual(canvas["selection_complete"] as? Bool, false)
    for value in [active, reference] {
      XCTAssertEqual(value["ids_complete"] as? Bool, false)
      XCTAssertEqual(value["node_count"] as? Int, 100_000)
      XCTAssertEqual((value["node_ids"] as? [String])?.count, 4_096)
    }
    let status = try store.engine.call("form_status")
    XCTAssertLessThan(try JSONSerialization.data(withJSONObject: status).count, 2 * 1_024 * 1_024)
    XCTAssertEqual(store.artworkSession.nodes.count, 100_000)
    XCTAssertEqual(store.artworkSession.selection.count, 4_097)
    XCTAssertEqual(store.project, before); XCTAssertEqual(store.engine.projectGeneration, generation)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testNativeTableAndIsolationAliasesReportFullCountsWithBoundedIDs() throws {
    let store = try store()
    var project = Project(name: "Bounded Table context")
    let template = try project.makeObject(recipeID: "box")
    project.objects = (1...4_100).map { index in
      var object = template; object.id = identity(index); return object
    }
    store.engine.project = project; store.engine.selection = Set(project.objects.map(\.id))
    store.isolated = store.engine.selection
    store.environment = .form; store.mode = .table
    let context = store.selectionContext(), table = try dictionary(context["table"])
    let target = try dictionary(context["active_target"])
    XCTAssertEqual(table["selected_object_count"] as? Int, 4_100)
    XCTAssertEqual(table["isolated_object_count"] as? Int, 4_100)
    XCTAssertEqual(table["selection_complete"] as? Bool, false)
    XCTAssertEqual(table["isolation_complete"] as? Bool, false)
    XCTAssertEqual((table["selected_object_ids"] as? [String])?.count, 4_096)
    XCTAssertEqual((table["isolated_object_ids"] as? [String])?.count, 4_096)
    XCTAssertEqual(target["object_count"] as? Int, 4_100)
    XCTAssertEqual(target["ids_complete"] as? Bool, false)
    XCTAssertEqual((target["object_ids"] as? [String])?.count, 4_096)
    XCTAssertEqual(store.engine.selection.count, 4_100); XCTAssertEqual(store.isolated.count, 4_100)
    XCTAssertEqual(store.project, project)
  }

  func testFunctionAndFabricateDoNotTargetRetainedHiddenCanvasOrStudioMode() throws {
    let store = try store()
    var project = Project(name: "Physical environment context")
    let board = try project.makeObject(recipeID: "artboard")
    let physical = try project.makeObject(recipeID: "box")
    project.objects = [board, physical]; store.engine.project = project
    store.artworkSession.activate(board.id); store.engine.selection = [physical.id]
    for environment in [ProjectEnvironment.function, .fabricate] {
      store.environment = environment
      for mode in [WorkspaceMode.artwork, .studio] {
        store.mode = mode
        let context = store.selectionContext()
        XCTAssertEqual(try dictionary(context["active_target"])["object_id"] as? String, physical.id.uuidString)
        XCTAssertEqual(context["focused_surface"] as? String, "table")
        XCTAssertEqual(try dictionary(context["table"])["active"] as? Bool, true)
        XCTAssertEqual(try dictionary(context["canvas"])["active"] as? Bool, false)
        XCTAssertTrue(context["studio_subview"] is NSNull)
      }
    }
    XCTAssertEqual(store.project, project); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
}

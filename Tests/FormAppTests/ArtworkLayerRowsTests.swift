import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class ArtworkLayerRowsTests: XCTestCase {
  private func element(_ name: String, kind: String = "rectangle", parent: UUID? = nil,
    x: Double = 0, y: Double = 0, width: Double = 10, height: Double = 10) -> ArtworkElement {
    var value = ArtworkElement(kind: kind, x: x, y: y, width: width, height: height)
    value.name = name; value.parentID = parent
    return value
  }
  private func projection(_ boundary: [Point2], cutouts: [[Point2]]? = nil) -> CanvasSourceProjection {
    .init(constructionID: UUID(), sourceID: UUID(), panelID: "face", inside: false,
      title: "Physical face", size: .init(100, 100), sourceToLocal: .init(),
      boundary: boundary, cutouts: cutouts)
  }

  func testDenseExpandedGroupsVisitEachElementOnceAndPreserveFrontToBackOrder() {
    var elements: [ArtworkElement] = []
    for row in 0..<300 {
      let group = element("Group \(row)", kind: "group", x: Double(row) * 12)
      elements.append(group)
      for column in 0..<10 {
        elements.append(element("Cell \(row)/\(column)", parent: group.id))
      }
    }
    let result = ArtworkLayerRows(artwork: .init(elements: elements), projection: nil)
    XCTAssertEqual(result.rows.count, 3300)
    XCTAssertEqual(result.candidatesVisited, 3300, "Expanded groups must not rescan unrelated siblings.")
    XCTAssertEqual(result.rows.prefix(3).map(\.element.name), ["Group 299", "Cell 299/9", "Cell 299/8"])
    XCTAssertEqual(result.rows.suffix(2).map(\.element.name), ["Cell 0/1", "Cell 0/0"])
    XCTAssertEqual(result.rows.filter { $0.depth == 0 }.count, 300)
    XCTAssertTrue(result.rows.filter { $0.element.parentID != nil }.allSatisfy { $0.depth == 1 })
  }

  func testCollapseKeepsAuthoredHiddenLockedAndComponentRowsWithoutExpandingDefinitions() {
    let back = element("Back")
    let group = element("Outer", kind: "group")
    let nested = element("Nested", kind: "group", parent: group.id)
    let child = element("Nested child", parent: nested.id)
    var hidden = element("Hidden", parent: group.id); hidden.hidden = true
    var locked = element("Locked", parent: group.id); locked.locked = true
    var instance = element("Instance", kind: "group")
    instance.component = .init(sourceObjectID: UUID())
    let artwork = Artwork(elements: [back, group, nested, child, hidden, locked, instance])
    let expanded = ArtworkLayerRows(artwork: artwork, projection: nil)
    XCTAssertEqual(expanded.rows.map(\.element.id), [instance.id, group.id, locked.id, hidden.id, nested.id, child.id, back.id])
    XCTAssertEqual(expanded.rows.map(\.depth), [0, 0, 1, 1, 1, 2, 0])
    let collapsed = ArtworkLayerRows(artwork: artwork, projection: nil, collapsed: [nested.id])
    XCTAssertEqual(collapsed.rows.map(\.element.id), [instance.id, group.id, locked.id, hidden.id, nested.id, back.id])
    XCTAssertEqual(collapsed.rows.first?.element.component, instance.component)
    XCTAssertEqual(collapsed.rows.first { $0.element.id == hidden.id }?.element.hidden, true)
    XCTAssertEqual(collapsed.rows.first { $0.element.id == locked.id }?.element.locked, true)
  }

  func testProjectedRowsAccumulateNestedRotationAndScaleAndExcludePhysicalCutout() {
    var root = element("Rotated parent", kind: "group", width: 60, height: 60)
    root.affine = Affine2.translation(40, 40).followed(by: .rotation(90))
    var nested = element("Scaled child group", kind: "group", parent: root.id, width: 20, height: 20)
    nested.contentSize = .init(10, 10)
    let visible = element("Visible", parent: nested.id, x: 2, y: 2, width: 2, height: 2)
    let outside = element("Other face", parent: root.id, x: 40, y: 0, width: 2, height: 2)
    let hole = element("In cutout", x: 35.2, y: 45.2, width: 0.4, height: 0.4)
    let artwork = Artwork(elements: [root, nested, visible, outside, hole])
    let face = projection([.init(30, 40), .init(40, 40), .init(40, 50), .init(30, 50)],
      cutouts: [[.init(35, 45), .init(36, 45), .init(36, 46), .init(35, 46)]])
    let result = ArtworkLayerRows(artwork: artwork, projection: face)
    XCTAssertEqual(result.rows.map(\.element.id), [root.id, nested.id, visible.id])
    XCTAssertEqual(result.rows.map(\.depth), [0, 1, 2])
    XCTAssertEqual(artwork.bounds(of: visible).x, 32, accuracy: 1e-9)
    XCTAssertEqual(artwork.bounds(of: visible).y, 44, accuracy: 1e-9)
  }

  func testBooleanProjectionUsesOperandBoundsInsteadOfItsStaleGroupBox() {
    var boolean = element("Boolean", kind: "group", x: 100, width: 1, height: 1)
    boolean.booleanOperation = "union"
    let operand = element("Operand", parent: boolean.id, x: -98, y: 2, width: 4, height: 4)
    var hidden = element("Hidden operand", parent: boolean.id, x: 20, y: 20)
    hidden.hidden = true
    let artwork = Artwork(elements: [boolean, operand, hidden])
    let face = projection([.init(0, 0), .init(20, 0), .init(20, 20), .init(0, 20)])
    XCTAssertEqual(ArtworkLayerRows(artwork: artwork, projection: face).rows.map(\.element.id),
      [boolean.id, operand.id])
  }

  func testSessionLayersShowAuthoredInstanceIDsAndSwitchToEditableComponentSource() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("layer-source-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: directory), seedLibrary: false)
    defer { store.engine.project = nil; try? FileManager.default.removeItem(at: directory) }
    var project = Project(name: "Authored layer identity")
    var definition = try project.makeObject(recipeID: "artboard", parameters: ["width": 30, "depth": 20])
    definition.componentDefinition = true; definition.canvasSourceOnly = true
    let ink = element("Definition ink")
    definition.artwork = .init(elements: [ink])
    var instance = element("Instance", kind: "group", width: 30, height: 20)
    instance.component = .init(sourceObjectID: definition.id); instance.contentSize = .init(30, 20)
    var sheet = try project.makeObject(recipeID: "artboard")
    sheet.artwork = .init(elements: [instance]); project.objects = [definition, sheet]
    store.engine.project = project
    let session = store.artworkSession; session.activate(sheet.id)
    let before = store.project
    XCTAssertEqual(ArtworkLayers(session: session).rows.map(\.element.id), [instance.id])
    XCTAssertFalse(ArtworkLayers(session: session).rows.contains { $0.element.id == ComponentCommands.derivedID(instance.id, ink.id) })
    session.editComponentSource(instance)
    XCTAssertEqual(ArtworkLayers(session: session).rows.map(\.element.id), [ink.id])
    session.returnToComponent()
    XCTAssertEqual(ArtworkLayers(session: session).rows.map(\.element.id), [instance.id])
    XCTAssertEqual(store.project, before); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
}

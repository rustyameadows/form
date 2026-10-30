import AppKit
import FormCore
import FormCADModel
import XCTest
@testable import FormApp

@MainActor final class CanvasPaperPickingIntegrationTests: XCTestCase {
  @MainActor private final class Fixture {
    let directory: URL, store: StudioStore, session: ArtworkSession
    let window: NSWindow, scroll: ArtworkScrollView, canvas: VectorCanvasView
    let sourceID: UUID, frameID: UUID

    init(elements: [ArtworkElement], inside: Bool, proof: Bool = false) throws {
      _ = NSApplication.shared
      directory = FileManager.default.temporaryDirectory.appendingPathComponent("paper-picking-" + UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: directory), seedLibrary: false)
      store.engine.project = Project(name: "Shared clipped paper source")
      let definition = PlanarConstructionDefinition(name: "Window and diagonal boundary", size: .init(60, 30), stockThickness: 1,
        panels: [
          .init(id: "square", name: "Square", polygon: [.init(0, 0), .init(30, 0), .init(30, 30), .init(0, 30)],
            artworkRotationDegrees: 90,
            cutouts: [.init(id: "window", polygon: [.init(10, 10), .init(20, 10), .init(20, 20), .init(10, 20)], kind: .window)]),
          .init(id: "triangle", name: "Triangle", polygon: [.init(30, 0), .init(60, 0), .init(30, 30)])],
        hinges: [.init(id: "crease", parentPanelID: "square", childPanelID: "triangle", start: .init(30, 0), end: .init(30, 30), angleDegrees: 90)],
        rootPanelID: "square")
      let created = try store.engine.call("form_construction", arguments: ["command": "create", "definition": try jsonObject(definition)])
      let result = try XCTUnwrap(created as? [String: Any])
      let paperID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(result["object_id"] as? String)))
      if inside { _ = try store.engine.call("form_paper", arguments: ["command": "ensure_inside", "object_id": paperID.uuidString]) }
      let paper = try XCTUnwrap(store.project!.objects.first { $0.id == paperID })
      sourceID = inside ? try XCTUnwrap(paper.paperConstruction?.insideArtworkSourceID) : paperID
      var artwork = Artwork(background: "#FFFFFF", elements: elements, bleed: 0)
      artwork.backgroundOpacity = 0; artwork.snapEnabled = false
      let source = sourceID
      try store.engine.edit("Prepared canonical source") { project in
        let index = try XCTUnwrap(project.objects.firstIndex { $0.id == source })
        project.objects[index].artwork = artwork
      }
      store.showingHome = false; store.mode = .artwork
      session = store.artworkSession; session.activate(sourceID); session.linkedTargetID = paperID
      store.paperInside = inside
      let target = try XCTUnwrap(session.frames.first {
        $0.projection?.constructionID == paperID && $0.projection?.inside == inside
          && $0.projection?.panelID == (proof ? nil : "square")
      })
      frameID = target.id; session.activate(frameID)
      window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 650),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      scroll = ArtworkScrollView(frame: window.contentView!.bounds)
      scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
      canvas = VectorCanvasView(frame: scroll.bounds)
      canvas.session = session; session.canvas = canvas; scroll.documentView = canvas
      window.contentView = scroll; window.makeFirstResponder(canvas)
      canvas.synchronize(); canvas.fit(all: true); canvas.setZoom(1)
    }
    func close() {
      canvas.finishText(); window.contentView = nil; window.close(); store.engine.project = nil
      try? FileManager.default.removeItem(at: directory)
    }
    func frame() throws -> CanvasFrame { try XCTUnwrap(session.frames.first { $0.id == frameID }) }
    func local(_ canonical: Point2) throws -> CGPoint {
      let projection = try XCTUnwrap(frame().projection)
      let point=projection.sourceToLocal.apply(canonical)
      return CGPoint(x:point.x,y:point.y)
    }
    func mouse(_ type: NSEvent.EventType, at canonical: Point2) throws -> NSEvent {
      let frame = try frame(), point = try local(canonical)
      let location = canvas.convert(canvas.documentPoint(.init(x: frame.rect.minX + point.x, y: frame.rect.minY + point.y)), to: nil)
      return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }
    func click(_ point: Point2) throws {
      canvas.mouseDown(with: try mouse(.leftMouseDown, at: point))
      canvas.mouseUp(with: try mouse(.leftMouseUp, at: point))
    }
    func probe(_ point: Point2) throws -> [NSMenuItem] {
      let menu = canvas.makeCanvasContextMenu(for: try mouse(.rightMouseDown, at: point))
      return try XCTUnwrap(menu.items.first { $0.title == "Select Layer" }?.submenu).items
    }
  }

  private func rectangle(_ name: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double,
    parent: UUID? = nil) -> ArtworkElement {
    var element = ArtworkElement(kind: "rectangle", x: x, y: y, width: width, height: height)
    element.name = name; element.parentID = parent
    return element
  }

  func testHiddenHoleAndOffPanelArtworkCannotBePickedByClickHoverOrContextProbe() throws {
    let hidden = rectangle("Hidden inside window", 10.2, 14, 0.4, 2)
    let neighbor = rectangle("Printed only on neighbor", 30.2, 4, 0.4, 2)
    let absent = rectangle("Outside the complete net", 50, 24, 2, 2)
    for inside in [false, true] {
      for proof in [false, true] {
        let fixture = try Fixture(elements: [hidden, neighbor, absent], inside: inside, proof: proof)
        defer { fixture.close() }
        let before = fixture.store.project, history = fixture.store.engine.undoStack.count
        var points = [Point2(9.8, 15), Point2(10.3, 15)]
        if proof { points.append(.init(51, 25)) } else { points.append(.init(29.8, 5)) }
        for point in points {
          fixture.session.choose([])
          fixture.canvas.mouseMoved(with: try fixture.mouse(.mouseMoved, at: point))
          XCTAssertNil(fixture.canvas.hoveredElementID)
          try fixture.click(point); XCTAssertTrue(fixture.session.selection.isEmpty)
          XCTAssertTrue(try fixture.probe(point).isEmpty)
        }
        XCTAssertEqual(fixture.session.objectID, fixture.sourceID)
        XCTAssertEqual(fixture.store.project, before); XCTAssertEqual(fixture.store.engine.undoStack.count, history)
      }
    }
  }

  func testCrossingArtworkRemainsEditableFromInsideAndOutsideMaterialWithOneCanonicalUndo() throws {
    let crossing = rectangle("Crossing the removed window", 9.2, 13, 2, 2)
    for inside in [false, true] {
      for proof in [false, true] {
        let fixture = try Fixture(elements: [crossing], inside: inside, proof: proof)
        defer { fixture.close() }
        let before = fixture.store.project!, history = fixture.store.engine.undoStack.count
        fixture.canvas.mouseMoved(with: try fixture.mouse(.mouseMoved, at: .init(9.5, 14)))
        XCTAssertEqual(fixture.canvas.hoveredElementID, crossing.id)
        try fixture.click(.init(9.5, 14)); XCTAssertEqual(fixture.session.selection, [crossing.id])
        XCTAssertEqual(try fixture.probe(.init(9.5, 14)).map { $0.identifier?.rawValue }, [crossing.id.uuidString])
        fixture.session.translate(dx: 1, dy: 2)
        XCTAssertEqual(fixture.store.engine.undoStack.count, history + 1)
        let source = try XCTUnwrap(fixture.store.project!.objects.first { $0.id == fixture.sourceID }?.artwork)
        XCTAssertEqual(source.elements.map(\.id), [crossing.id]); XCTAssertNotEqual(source, before.objects.first { $0.id == fixture.sourceID }?.artwork)
        fixture.store.engine.undo()
        XCTAssertEqual(fixture.store.project!.objects, before.objects)
      }
    }
  }

  func testOutsideGroupRecoveryUsesOnlyVisibleMaterialIncludingReflectedRotatedFrames() throws {
    var editing = ArtworkElement(kind: "group", x: 0, y: 0, width: 60, height: 30)
    editing.name = "Current group"
    let current = rectangle("Current child", 2, 2, 2, 2, parent: editing.id)
    let hiddenGroup = ArtworkElement(kind: "group", x: 0, y: 0, width: 60, height: 30)
    let hidden = rectangle("Hidden sibling child", 10.2, 14, 0.4, 2, parent: hiddenGroup.id)
    let visibleGroup = ArtworkElement(kind: "group", x: 0, y: 0, width: 60, height: 30)
    let crossing = rectangle("Visible crossing sibling", 29.2, 22, 2, 2, parent: visibleGroup.id)
    for inside in [false, true] {
      let fixture = try Fixture(elements: [editing, current, hiddenGroup, hidden, visibleGroup, crossing], inside: inside)
      defer { fixture.close() }
      let before = fixture.store.project, history = fixture.store.engine.undoStack.count
      fixture.session.navigateGroup(to: editing.id)
      let frame = try fixture.frame()
      for cached in [false, true] {
        XCTAssertNil(fixture.canvas.externalGroupTarget(at: try fixture.local(.init(9.8, 15)), in: fixture.session.art, frame: frame, cached: cached))
        XCTAssertEqual(fixture.canvas.externalGroupTarget(at: try fixture.local(.init(29.5, 23)), in: fixture.session.art, frame: frame, cached: cached)?.id, visibleGroup.id)
      }
      fixture.canvas.mouseMoved(with: try fixture.mouse(.mouseMoved, at: .init(9.8, 15)))
      XCTAssertNil(fixture.canvas.hoveredElementID)
      fixture.canvas.mouseMoved(with: try fixture.mouse(.mouseMoved, at: .init(29.5, 23)))
      XCTAssertEqual(fixture.canvas.hoveredElementID, visibleGroup.id)
      try fixture.click(.init(29.5, 23)); XCTAssertEqual(fixture.session.selection, [visibleGroup.id])
      XCTAssertNil(fixture.session.scopeID)
      XCTAssertEqual(fixture.store.project, before); XCTAssertEqual(fixture.store.engine.undoStack.count, history)
    }
  }
}

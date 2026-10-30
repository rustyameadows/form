import AppKit
import FormCore
import XCTest
@testable import FormApp

/// A densely layered source, exercised through the same window-coordinate
/// pointer handlers and context-menu actions as the native editor.
@MainActor final class CanvasDenseInteractionTests: XCTestCase {
  private struct Cell {
    let group: UUID, inner: UUID, ellipse: UUID
    let center: CGPoint
  }

  @MainActor private final class Fixture {
    let root: URL, store: StudioStore, session: ArtworkSession
    let window: NSWindow, scroll: ArtworkScrollView, canvas: VectorCanvasView
    let cells: [Cell], topOverlay: UUID

    init() throws {
      _ = NSApplication.shared
      root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-dense-" + UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
      var project = Project(name: "Dense layered interaction")
      let workspace = try project.ensureCanvasWorkspace()
      var elements: [ArtworkElement] = [], cells: [Cell] = []
      for row in 0..<8 { for column in 0..<12 {
        let x = Double(column) * 22, y = Double(row) * 22
        var outer = ArtworkElement(kind: "group", x: x, y: y, width: 18, height: 18)
        outer.contentSize = .init(18, 18)
        var mask = ArtworkElement(kind: "ellipse", x: 0, y: 0, width: 18, height: 18)
        mask.parentID = outer.id
        var inner = ArtworkElement(kind: "group", x: 0, y: 0, width: 18, height: 18)
        inner.parentID = outer.id; inner.contentSize = .init(18, 18); inner.clipID = mask.id
        var base = ArtworkElement(kind: "rectangle", x: -2, y: -2, width: 22, height: 22, color: "#DDE5ED")
        base.parentID = inner.id
        var ellipse = ArtworkElement(kind: "ellipse", x: 4, y: 4, width: 10, height: 10, color: "#4060A0")
        ellipse.parentID = inner.id; ellipse.opacity = 0.75
        var line = ArtworkElement(kind: "line", x: 2, y: 14, width: 14, height: 1, color: "#E05A35")
        line.parentID = inner.id; line.fillEnabled = false; line.stroke = .init(color: "#E05A35", width: 0.35)
        var text = ArtworkElement(kind: "text", x: 3, y: 1.5, width: 12, height: 3,
          text: "\(row + 1).\(column + 1)", color: "#14253A", fontSize: 6)
        text.parentID = inner.id
        elements += [outer, mask, inner, base, ellipse, line, text]
        cells.append(.init(group: outer.id, inner: inner.id, ellipse: ellipse.id,
          center: .init(x: x + 9, y: y + 9)))
      } }
      let overlay = ArtworkElement(kind: "rectangle", x: 240, y: 154, width: 26, height: 18, color: "#EE8050")
      var locked = ArtworkElement(kind: "ellipse", x: 240, y: 154, width: 26, height: 18)
      locked.locked = true
      var hidden = ArtworkElement(kind: "rectangle", x: 240, y: 154, width: 26, height: 18)
      hidden.hidden = true
      elements += [overlay, locked, hidden]
      self.cells = cells; topOverlay = overlay.id
      project.objects[0].artwork?.elements = elements
      project.objects[0].artwork?.snapEnabled = false
      project.schemaVersion = project.minimumSchemaVersion
      store.engine.project = project; store.mode = .artwork; store.showingHome = false
      session = store.artworkSession; session.activate(workspace.id)
      window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1000, height: 760),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      scroll = ArtworkScrollView(frame: window.contentView!.bounds)
      scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
      canvas = VectorCanvasView(frame: scroll.bounds)
      canvas.session = session; session.canvas = canvas; scroll.documentView = canvas
      window.contentView = scroll; window.makeFirstResponder(canvas)
      canvas.synchronize(); canvas.fit(all: true)
    }

    func close() {
      canvas.finishText(); window.contentView = nil; window.close()
      store.engine.project = nil; try? FileManager.default.removeItem(at: root)
    }

    func event(_ type: NSEvent.EventType, _ world: CGPoint, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: canvas.convert(canvas.documentPoint(world), to: nil),
        modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count,
        pressure: type == .leftMouseUp ? 0 : 1)!
    }

    func click(_ point: CGPoint, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) {
      canvas.mouseDown(with: event(.leftMouseDown, point, modifiers: modifiers, count: count))
      canvas.mouseUp(with: event(.leftMouseUp, point, modifiers: modifiers, count: count))
    }

    func drag(_ start: CGPoint, _ end: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
      canvas.mouseDown(with: event(.leftMouseDown, start, modifiers: modifiers))
      // More than one drag event verifies the transform is based on the grab
      // snapshot, rather than repeatedly accumulating the same translation.
      canvas.mouseDragged(with: event(.leftMouseDragged, .init(x: (start.x + end.x)/2, y: (start.y + end.y)/2), modifiers: modifiers))
      canvas.mouseDragged(with: event(.leftMouseDragged, end, modifiers: modifiers))
      canvas.mouseUp(with: event(.leftMouseUp, end, modifiers: modifiers))
    }

    func menuAction(_ title: String, at point: CGPoint) throws {
      let menu = try XCTUnwrap(canvas.menu(for: event(.rightMouseDown, point)))
      let index = try XCTUnwrap(menu.items.firstIndex { $0.title == title })
      menu.performActionForItem(at: index)
      XCTAssertNil(store.error)
    }
  }

  private func point(_ id: UUID, in art: Artwork) throws -> Point2 {
    let element = try XCTUnwrap(art.elements.first { $0.id == id })
    return art.worldTransform(element).apply(.init(element.width/2, element.height/2))
  }

  func testDensePaintOrderClippingAndNestedSelectionAtThreeZoomLevels() throws {
    let f = try Fixture(); defer { f.close() }
    XCTAssertEqual(f.session.art.elements.count, 675)
    let before = try XCTUnwrap(f.store.project)
    for zoom in [0.2, 0.8, 3.0] {
      f.canvas.setZoom(zoom); f.session.scopeID = nil; f.session.choose([])
      f.canvas.ensureViewportCoverage(preserving: .init(x: 251, y: 163))
      f.click(.init(x: 251, y: 163))
      XCTAssertEqual(f.session.selection, [f.topOverlay], "Hidden and locked overlays must not steal the top painted target")
      f.session.choose([])
      f.canvas.ensureViewportCoverage(preserving: .init(x: 0.5, y: 0.5))
      f.click(.init(x: 0.5, y: 0.5))
      XCTAssertTrue(f.session.selection.isEmpty, "The clipped-off corners must not capture a click")
      let cell = f.cells[40]
      f.canvas.ensureViewportCoverage(preserving: cell.center)
      f.click(cell.center)
      XCTAssertEqual(f.session.selection, [cell.group])
      f.click(cell.center, count: 2)
      XCTAssertEqual(f.session.scopeID, cell.group)
      f.click(cell.center)
      XCTAssertEqual(f.session.selection, [cell.inner], "Masks are geometry, not selectable painted siblings")
      f.click(cell.center, count: 2)
      XCTAssertEqual(f.session.scopeID, cell.inner)
      f.click(cell.center)
      XCTAssertEqual(f.session.selection, [cell.ellipse])
    }
    XCTAssertEqual(f.store.project, before); XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testImmediateGroupUndoRedoRefreshPickingAndHoverWithoutAViewUpdate() throws {
    let f = try Fixture(); defer { f.close() }
    f.canvas.setZoom(0.8); f.canvas.ensureViewportCoverage(preserving: .init(x: 86, y: 64))
    let first = f.cells[27], second = f.cells[28], before = try XCTUnwrap(f.store.project)
    f.click(first.center); f.click(second.center, modifiers: .shift)
    try f.menuAction("Group", at: first.center)
    let group = try XCTUnwrap(f.session.primary), grouped = try XCTUnwrap(f.store.project)
    let viewport = f.canvas.visibleCanvasRect, zoom = f.canvas.zoom
    f.session.choose([])
    // Deliberately do not call synchronize: the user can move the pointer or
    // click before SwiftUI has delivered its next representable update.
    f.canvas.mouseMoved(with: f.event(.mouseMoved, first.center))
    XCTAssertEqual(f.canvas.hoveredElementID, group.id)
    f.store.undo()
    f.canvas.mouseMoved(with: f.event(.mouseMoved, first.center))
    XCTAssertEqual(f.canvas.hoveredElementID, first.group)
    XCTAssertTrue(f.store.project == before, "Undo must restore the entire dense source")
    f.store.redo()
    f.canvas.mouseMoved(with: f.event(.mouseMoved, first.center))
    XCTAssertEqual(f.canvas.hoveredElementID, group.id)
    XCTAssertTrue(f.store.project == grouped, "Redo must restore the entire grouped source")
    f.click(first.center)
    XCTAssertEqual(f.session.selection, [group.id])
    XCTAssertEqual(f.canvas.visibleCanvasRect, viewport)
    XCTAssertEqual(f.canvas.zoom, zoom)
  }

  func testDenseMarqueeAndShiftSelectionMoveOnlyChosenRootsWithExactUndoRedo() throws {
    for zoom in [0.2, 1.8] {
      let f = try Fixture(); defer { f.close() }
      f.canvas.setZoom(zoom)
      f.canvas.ensureViewportCoverage(preserving: .init(x: 86, y: 75))
      let chosen = [f.cells[27], f.cells[28], f.cells[39], f.cells[40]]
      f.drag(.init(x: 64, y: 42), .init(x: 108, y: 86))
      XCTAssertEqual(f.session.selection, Set(chosen.map(\.group)))
      let extra = f.cells[52]
      f.click(extra.center, modifiers: .shift)
      XCTAssertEqual(f.session.selection, Set(chosen.map(\.group) + [extra.group]))
      f.click(extra.center, modifiers: .shift)
      XCTAssertEqual(f.session.selection, Set(chosen.map(\.group)))
      let before = try XCTUnwrap(f.store.project), art = f.session.art
      let roots = Set(chosen.map(\.group)), descendants = art.descendants(of: roots)
      let originalPoints = try Dictionary(uniqueKeysWithValues: descendants.map { ($0, try point($0, in: art)) })
      f.drag(chosen[0].center, .init(x: chosen[0].center.x + 13, y: chosen[0].center.y + 8))
      for (id, old) in originalPoints {
        let moved = try point(id, in: f.session.art)
        XCTAssertEqual(moved.x, old.x + 13, accuracy: 0.000001)
        XCTAssertEqual(moved.y, old.y + 8, accuracy: 0.000001)
      }
      XCTAssertEqual(f.session.art.elements.filter { !roots.contains($0.id) }, art.elements.filter { !roots.contains($0.id) },
        "A multi-selection move must not rewrite children or any unselected layer")
      XCTAssertEqual(f.store.engine.undoStack.count, 1)
      let moved = f.store.project
      f.store.engine.undo(); XCTAssertEqual(f.store.project, before)
      f.store.engine.redo(); XCTAssertEqual(f.store.project, moved)
    }
  }

  func testDenseNativeGroupingMovingAndProportionalScalingPreserveDescendantsAndUndoEachStep() throws {
    let cases: [(zoom: Double, columns: Range<Int>, rows: Range<Int>)] = [
      (0.2, 2..<10, 1..<7), // 48 roots / 336 nested elements in one compound edit.
      (1.8, 3..<5, 2..<4),
    ]
    for configuration in cases {
      let f = try Fixture(); defer { f.close() }
      f.canvas.setZoom(configuration.zoom)
      f.canvas.ensureViewportCoverage(preserving: .init(x: 86, y: 75))
      let chosen = configuration.rows.flatMap { row in configuration.columns.map { f.cells[row * 12 + $0] } }
      f.drag(.init(x: Double(configuration.columns.lowerBound) * 22 - 2, y: Double(configuration.rows.lowerBound) * 22 - 2),
        .init(x: Double(configuration.columns.upperBound - 1) * 22 + 20, y: Double(configuration.rows.upperBound - 1) * 22 + 20))
      XCTAssertEqual(f.session.selection, Set(chosen.map(\.group)))
      let baseline = try XCTUnwrap(f.store.project), source = f.session.art
      let affected = source.descendants(of: Set(chosen.map(\.group)))
      let originalPoints = try Dictionary(uniqueKeysWithValues: affected.map { ($0, try point($0, in: source)) })
      try f.menuAction("Group", at: chosen[0].center)
      let group = try XCTUnwrap(f.session.primary)
      XCTAssertEqual(group.kind, "group"); XCTAssertEqual(f.session.selection, [group.id])
      XCTAssertEqual(Set(f.session.art.elements.filter { $0.parentID == group.id }.map(\.id)), Set(chosen.map(\.group)))
      for (id, expected) in originalPoints {
        let actual = try point(id, in: f.session.art)
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001)
      }
      let grouped = try XCTUnwrap(f.store.project)
      f.drag(chosen[0].center, .init(x: chosen[0].center.x + 31, y: chosen[0].center.y + 18))
      for (id, old) in originalPoints {
        let moved = try point(id, in: f.session.art)
        XCTAssertEqual(moved.x, old.x + 31, accuracy: 0.000001)
        XCTAssertEqual(moved.y, old.y + 18, accuracy: 0.000001)
      }
      let moved = try XCTUnwrap(f.store.project), movedArt = f.session.art
      let bounds = try XCTUnwrap(f.session.selectionBounds), scale = 1.35
      f.drag(.init(x: bounds.maxX, y: bounds.maxY),
        .init(x: bounds.x + bounds.width * scale, y: bounds.y + bounds.height * scale), modifiers: .shift)
      XCTAssertEqual(f.session.selectionBounds?.width ?? 0, bounds.width * scale, accuracy: 0.000001)
      XCTAssertEqual(f.session.selectionBounds?.height ?? 0, bounds.height * scale, accuracy: 0.000001)
      for id in affected {
        let old = try point(id, in: movedArt), resized = try point(id, in: f.session.art)
        XCTAssertEqual(resized.x, bounds.x + (old.x - bounds.x) * scale, accuracy: 0.000001)
        XCTAssertEqual(resized.y, bounds.y + (old.y - bounds.y) * scale, accuracy: 0.000001)
      }
      XCTAssertEqual(f.session.art.elements.filter { !affected.contains($0.id) && $0.id != group.id },
        source.elements.filter { !affected.contains($0.id) }, "Unrelated dense layers must remain byte-for-byte unchanged")
      XCTAssertNil(f.store.error); XCTAssertEqual(f.store.engine.undoStack.count, 3)
      let scaled = try XCTUnwrap(f.store.project)
      f.store.engine.undo(); XCTAssertEqual(f.store.project, moved)
      f.store.engine.undo(); XCTAssertEqual(f.store.project, grouped)
      f.store.engine.undo(); XCTAssertEqual(f.store.project, baseline)
      f.store.engine.redo(); XCTAssertEqual(f.store.project, grouped)
      f.store.engine.redo(); XCTAssertEqual(f.store.project, moved)
      f.store.engine.redo(); XCTAssertEqual(f.store.project, scaled)
    }
  }
}

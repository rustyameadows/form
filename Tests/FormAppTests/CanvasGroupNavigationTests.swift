import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class CanvasGroupNavigationTests: XCTestCase {
  @MainActor private final class Fixture {
    let root: URL, store: StudioStore, session: ArtworkSession, window: NSWindow
    let levels: [UUID], leafID: UUID, innerSiblingID: UUID, middleSiblingID: UUID, outerSiblingID: UUID, rootSiblingID: UUID
    let leafPoint = CGPoint(x: 108, y: 106)
    var canvas: VectorCanvasView { session.canvas! }

    init() throws {
      _ = NSApplication.shared
      root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-group-navigation-" + UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
      var project = Project(name: "Dense nested group navigation")
      let workspace = try project.ensureCanvasWorkspace()
      var elements: [ArtworkElement] = []
      // 111 layered neighbors keep 675 source elements present throughout every
      // navigation sequence, including glyphs, strokes and nested transforms.
      for index in 0..<111 {
        var outer = ArtworkElement(kind: "group", x: 350 + Double(index % 15) * 24,
          y: Double(index / 15) * 24, width: 18, height: 18)
        outer.contentSize = .init(18, 18)
        var inner = ArtworkElement(kind: "group", x: 0, y: 0, width: 18, height: 18)
        inner.contentSize = .init(18, 18); inner.parentID = outer.id
        var base = ArtworkElement(kind: "rectangle", x: 0, y: 0, width: 18, height: 18, color: "#CCDDEA")
        base.parentID = inner.id
        var ellipse = ArtworkElement(kind: "ellipse", x: 4, y: 4, width: 10, height: 10, color: "#5675B1")
        ellipse.parentID = inner.id
        var line = ArtworkElement(kind: "line", x: 2, y: 14, width: 14, height: 1)
        line.parentID = inner.id; line.fillEnabled = false; line.stroke = .init(color: "#AA5522", width: 0.3)
        var text = ArtworkElement(kind: "text", x: 2, y: 1, width: 14, height: 3, text: "\(index)", fontSize: 6)
        text.parentID = inner.id
        elements += [outer, inner, base, ellipse, line, text]
      }
      var outer = ArtworkElement(kind: "group", x: 40, y: 40, width: 180, height: 150)
      outer.contentSize = .init(180, 150)
      var middle = ArtworkElement(kind: "group", x: 20, y: 20, width: 120, height: 100)
      middle.contentSize = .init(120, 100); middle.parentID = outer.id
      var inner = ArtworkElement(kind: "group", x: 20, y: 20, width: 70, height: 60)
      inner.contentSize = .init(70, 60); inner.parentID = middle.id
      var deep = ArtworkElement(kind: "group", x: 10, y: 10, width: 40, height: 35)
      deep.contentSize = .init(40, 35); deep.parentID = inner.id
      var leaf = ArtworkElement(kind: "rectangle", x: 8, y: 8, width: 20, height: 16, color: "#E2633D")
      leaf.parentID = deep.id
      var innerSibling = ArtworkElement(kind: "ellipse", x: 48, y: 8, width: 16, height: 14, color: "#446DA0")
      innerSibling.parentID = inner.id
      var middleSibling = ArtworkElement(kind: "rectangle", x: 85, y: 15, width: 20, height: 20, color: "#46785B")
      middleSibling.parentID = middle.id
      var outerSibling = ArtworkElement(kind: "rectangle", x: 130, y: 20, width: 25, height: 20, color: "#996744")
      outerSibling.parentID = outer.id
      let rootSibling = ArtworkElement(kind: "rectangle", x: 250, y: 75, width: 38, height: 30, color: "#776099")
      elements += [outer, middle, inner, deep, leaf, innerSibling, middleSibling, outerSibling, rootSibling]
      levels = [outer.id, middle.id, inner.id, deep.id]
      leafID = leaf.id; innerSiblingID = innerSibling.id; middleSiblingID = middleSibling.id
      outerSiblingID = outerSibling.id; rootSiblingID = rootSibling.id
      project.objects[0].artwork?.elements = elements; project.objects[0].artwork?.snapEnabled = false
      project.schemaVersion = project.minimumSchemaVersion
      store.engine.project = project; store.showingHome = false; store.mode = .artwork
      session = store.artworkSession; session.activate(workspace.id)
      window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1200, height: 800),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let scroll = ArtworkScrollView(frame: window.contentView!.bounds)
      scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
      let view = VectorCanvasView(frame: scroll.bounds)
      view.session = session; session.canvas = view; scroll.documentView = view
      window.contentView = scroll; window.makeFirstResponder(view)
      view.synchronize(); view.fit(all: true); view.setZoom(0.8)
      view.ensureViewportCoverage(preserving: .init(x: 155, y: 105))
    }

    func close() {
      canvas.finishText(); window.contentView = nil; window.close(); store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    func event(_ type: NSEvent.EventType, _ point: CGPoint, count: Int = 1,
      modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: canvas.convert(canvas.documentPoint(point), to: nil),
        modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count,
        pressure: type == .leftMouseUp ? 0 : 1)!
    }
    func click(_ point: CGPoint, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
      canvas.mouseDown(with: event(.leftMouseDown, point, count: count, modifiers: modifiers))
      canvas.mouseUp(with: event(.leftMouseUp, point, count: count, modifiers: modifiers))
    }
    func doubleClick(_ point: CGPoint) { click(point); click(point, count: 2) }
    func enterAll() {
      for id in levels { doubleClick(leafPoint); XCTAssertEqual(session.scopeID, id) }
    }
    func escape() {
      canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!)
    }
  }

  private func assertUnchanged(_ f: Fixture, _ project: Project, _ viewport: CGRect, _ zoom: Double,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(f.store.project == project, "Group navigation must not alter any dense source/history", file: file, line: line)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty, file: file, line: line)
    XCTAssertEqual(f.canvas.visibleCanvasRect, viewport, file: file, line: line)
    XCTAssertEqual(f.canvas.zoom, zoom, file: file, line: line)
  }

  func testFreshAndCumulativeDoubleClicksEnterExactlyOneLevelPerPairWithoutRefitting() throws {
    for zoom in [0.25, 1.5] {
      let f = try Fixture(); defer { f.close() }
      f.canvas.setZoom(zoom); f.canvas.ensureViewportCoverage(preserving: f.leafPoint)
      XCTAssertEqual(f.session.art.elements.count, 675)
      let project = try XCTUnwrap(f.store.project), viewport = f.canvas.visibleCanvasRect
      for cumulative in [false, true] {
        for (index, id) in f.levels.enumerated() {
          let previous = index == 0 ? nil : f.levels[index - 1]
          f.click(f.leafPoint, count: cumulative ? index * 2 + 1 : 1)
          XCTAssertEqual(f.session.scopeID, previous, "The first click in a pair selects; it must not skip a level")
          f.click(f.leafPoint, count: cumulative ? index * 2 + 2 : 2)
          XCTAssertEqual(f.session.scopeID, id)
        }
        f.click(f.leafPoint, count: cumulative ? 9 : 1)
        XCTAssertEqual(f.session.selection, [f.leafID])
        for (index, expected) in ([f.levels[2], f.levels[1], f.levels[0], nil] as [UUID?]).enumerated() {
          f.escape(); XCTAssertEqual(f.session.scopeID, expected)
          XCTAssertEqual(f.session.selection, [f.levels[3 - index]], "Escape selects the group that was just exited")
        }
      }
      assertUnchanged(f, project, viewport, zoom)
    }
  }

  func testExternalSiblingClickWalksToTheNearestReachableScopeAndSelectsItImmediately() throws {
    let f = try Fixture(); defer { f.close() }
    let project = try XCTUnwrap(f.store.project), viewport = f.canvas.visibleCanvasRect, zoom = f.canvas.zoom
    f.enterAll()
    f.click(.init(x: 136, y: 95))
    XCTAssertEqual(f.session.scopeID, f.levels[2]); XCTAssertEqual(f.session.selection, [f.innerSiblingID])
    f.doubleClick(f.leafPoint); XCTAssertEqual(f.session.scopeID, f.levels[3])
    f.click(.init(x: 155, y: 85))
    XCTAssertEqual(f.session.scopeID, f.levels[1]); XCTAssertEqual(f.session.selection, [f.middleSiblingID])
    f.click(.init(x: 182.5, y: 70))
    XCTAssertEqual(f.session.scopeID, f.levels[0]); XCTAssertEqual(f.session.selection, [f.outerSiblingID])
    f.click(.init(x: 269, y: 90))
    XCTAssertNil(f.session.scopeID); XCTAssertEqual(f.session.selection, [f.rootSiblingID])
    assertUnchanged(f, project, viewport, zoom)
  }

  func testExternalSiblingHoverPreviewsTheSameNearestTargetAsClickWithoutNavigating() throws {
    let f = try Fixture(); defer { f.close() }
    let project = try XCTUnwrap(f.store.project), viewport = f.canvas.visibleCanvasRect, zoom = f.canvas.zoom
    let targets: [(CGPoint, UUID, UUID?)] = [
      (.init(x: 136, y: 95), f.innerSiblingID, f.levels[2]),
      (.init(x: 155, y: 85), f.middleSiblingID, f.levels[1]),
      (.init(x: 182.5, y: 70), f.outerSiblingID, f.levels[0]),
      (.init(x: 269, y: 90), f.rootSiblingID, nil),
    ]
    for (point, target, scope) in targets {
      f.session.navigateGroup(to: f.levels[3])
      for _ in 0..<3 {
        f.canvas.mouseMoved(with: f.event(.mouseMoved, point, count: 0))
        XCTAssertEqual(f.canvas.hoveredElementID, target)
        XCTAssertEqual(f.session.scopeID, f.levels[3], "Hover previews an escape target without leaving isolation")
        XCTAssertTrue(f.session.selection.isEmpty)
      }
      f.canvas.mouseMoved(with: f.event(.mouseMoved, point, count: 0, modifiers: .shift))
      XCTAssertNil(f.canvas.hoveredElementID, "Shift cannot preview a target that clicking would leave unreachable")
      f.click(point)
      XCTAssertEqual(f.session.scopeID, scope); XCTAssertEqual(f.session.selection, [target])
    }
    assertUnchanged(f, project, viewport, zoom)
  }

  func testBlankDoubleClickLeavesTheCurrentGroupEvenInsideItsEmptyBounds() throws {
    let f = try Fixture(); defer { f.close() }
    let project = try XCTUnwrap(f.store.project), viewport = f.canvas.visibleCanvasRect, zoom = f.canvas.zoom
    f.enterAll()
    f.click(.init(x: 92, y: 92))
    XCTAssertEqual(f.session.scopeID, f.levels[3], "An ordinary internal whitespace click should remain available for a marquee")
    f.click(.init(x: 92, y: 92), count: 2)
    XCTAssertEqual(f.session.scopeID, f.levels[2])
    XCTAssertEqual(f.session.selection, [f.levels[3]])
    assertUnchanged(f, project, viewport, zoom)
  }

  func testOutsideBlankAscendsOneLevelWithoutStartingAMarqueeUntilTheNextGesture() throws {
    let f = try Fixture(); defer { f.close() }
    f.enterAll(); f.click(f.leafPoint)
    let project = try XCTUnwrap(f.store.project), viewport = f.canvas.visibleCanvasRect, zoom = f.canvas.zoom
    let outside = CGPoint(x: -40, y: -40), end = CGPoint(x: 147, y: 138)
    f.canvas.mouseDown(with: f.event(.leftMouseDown, outside))
    XCTAssertEqual(f.session.scopeID, f.levels[2]); XCTAssertEqual(f.session.selection, [f.levels[3]])
    f.canvas.mouseDragged(with: f.event(.leftMouseDragged, end))
    f.canvas.mouseUp(with: f.event(.leftMouseUp, end))
    XCTAssertEqual(f.session.scopeID, f.levels[2]); XCTAssertEqual(f.session.selection, [f.levels[3]])

    // A later gesture starting in the enclosing group's empty interior still
    // supports a marquee spanning both the nested group and its sibling.
    let interior = CGPoint(x: 82, y: 82)
    f.canvas.mouseDown(with: f.event(.leftMouseDown, interior))
    f.canvas.mouseDragged(with: f.event(.leftMouseDragged, end))
    f.canvas.mouseUp(with: f.event(.leftMouseUp, end))
    XCTAssertEqual(f.session.scopeID, f.levels[2])
    XCTAssertEqual(f.session.selection, [f.levels[3], f.innerSiblingID])
    assertUnchanged(f, project, viewport, zoom)
  }

  func testShiftClickOutsideTheIsolatedGroupPreservesScopeAndExistingSelection() throws {
    let f = try Fixture(); defer { f.close() }
    f.enterAll(); f.click(f.leafPoint)
    let project = try XCTUnwrap(f.store.project), viewport = f.canvas.visibleCanvasRect, zoom = f.canvas.zoom
    for point in [CGPoint(x: 269, y: 90), CGPoint(x: -40, y: -40)] {
      f.click(point, modifiers: .shift)
      XCTAssertEqual(f.session.scopeID, f.levels[3])
      XCTAssertEqual(f.session.selection, [f.leafID])
    }
    assertUnchanged(f, project, viewport, zoom)
  }

  func testEscapeCancelsTheHeldNestedDragBeforeAscendingOnTheNextPress() throws {
    let f = try Fixture(); defer { f.close() }
    f.enterAll(); f.click(f.leafPoint)
    let project = try XCTUnwrap(f.store.project), viewport = f.canvas.visibleCanvasRect, zoom = f.canvas.zoom
    let destination = CGPoint(x: f.leafPoint.x + 12, y: f.leafPoint.y + 6)
    f.canvas.mouseDown(with: f.event(.leftMouseDown, f.leafPoint))
    f.canvas.mouseDragged(with: f.event(.leftMouseDragged, destination))
    XCTAssertFalse(f.store.project == project)
    f.escape()
    XCTAssertEqual(f.session.scopeID, f.levels[3]); XCTAssertTrue(f.store.project == project)
    f.escape(); XCTAssertEqual(f.session.scopeID, f.levels[2])
    f.canvas.mouseUp(with: f.event(.leftMouseUp, destination))
    XCTAssertEqual(f.session.scopeID, f.levels[2])
    assertUnchanged(f, project, viewport, zoom)
  }

  func testNestedDragLeaveUndoRedoAndRapidReentryKeepNavigationIndependentOfHistory() throws {
    let f = try Fixture(); defer { f.close() }
    let original = try XCTUnwrap(f.store.project), viewport = f.canvas.visibleCanvasRect, zoom = f.canvas.zoom
    f.enterAll(); f.click(f.leafPoint)
    let destination = CGPoint(x: f.leafPoint.x + 9, y: f.leafPoint.y + 5)
    f.canvas.mouseDown(with: f.event(.leftMouseDown, f.leafPoint))
    f.canvas.mouseDragged(with: f.event(.leftMouseDragged, destination))
    f.canvas.mouseUp(with: f.event(.leftMouseUp, destination))
    let moved = try XCTUnwrap(f.store.project)
    XCTAssertFalse(moved == original); XCTAssertEqual(f.store.engine.undoStack.count, 1)
    f.click(.init(x: 269, y: 90)); XCTAssertNil(f.session.scopeID)
    f.store.undo(); XCTAssertTrue(f.store.project == original)
    f.enterAll(); f.escape(); XCTAssertEqual(f.session.scopeID, f.levels[2])
    f.store.redo(); XCTAssertTrue(f.store.project == moved)
    f.click(.init(x: 269, y: 90)); XCTAssertNil(f.session.scopeID)
    for _ in 0..<3 {
      for (index, id) in f.levels.enumerated() {
        f.click(destination, count: index * 2 + 1); f.click(destination, count: index * 2 + 2)
        XCTAssertEqual(f.session.scopeID, id)
      }
      f.click(.init(x: 269, y: 90)); XCTAssertNil(f.session.scopeID)
    }
    XCTAssertTrue(f.store.project == moved); XCTAssertEqual(f.store.engine.undoStack.count, 1)
    XCTAssertEqual(f.canvas.visibleCanvasRect, viewport); XCTAssertEqual(f.canvas.zoom, zoom)
  }

  func testSharedNavigationCancelsHeldDragAndIgnoresLateDragAndMouseUp() throws {
    let f = try Fixture(); defer { f.close() }
    f.enterAll(); f.click(f.leafPoint)
    let project = try XCTUnwrap(f.store.project), viewport = f.canvas.visibleCanvasRect, zoom = f.canvas.zoom
    let destination = CGPoint(x: 120, y: 112)
    f.canvas.mouseDown(with: f.event(.leftMouseDown, f.leafPoint))
    f.canvas.mouseDragged(with: f.event(.leftMouseDragged, destination))
    XCTAssertFalse(f.store.project == project)
    f.session.navigateGroup(to: f.levels[2], selection: [f.levels[3]])
    XCTAssertTrue(f.store.project == project)
    XCTAssertEqual(f.session.scopeID, f.levels[2]); XCTAssertEqual(f.session.selection, [f.levels[3]])
    f.canvas.mouseDragged(with: f.event(.leftMouseDragged, .init(x: 136, y: 122)))
    f.canvas.mouseUp(with: f.event(.leftMouseUp, .init(x: 136, y: 122)))
    XCTAssertEqual(f.session.scopeID, f.levels[2]); XCTAssertEqual(f.session.selection, [f.levels[3]])
    assertUnchanged(f, project, viewport, zoom)
    XCTAssertTrue(f.store.engine.redoStack.isEmpty, "Cancelled movement must not leave a stale redo branch")
  }

  func testActualLeaveGroupButtonActsImmediatelyAndReturnsKeyboardFocusToCanvas() throws {
    let f = try Fixture(); defer { f.close() }
    let host = NSHostingView(rootView: ArtworkStudio(session: f.session).environmentObject(f.store).labInterface())
    f.window.contentView = host; f.window.orderBack(nil)
    func settle() {
      host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.06)); host.layoutSubtreeIfNeeded()
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func findButton(identifier: String) -> WorkspaceToolbarNativeButton? {
      let views: [NSView] = descendants(host)
      for view in views {
        guard let button = view as? WorkspaceToolbarNativeButton else { continue }
        if button.accessibilityIdentifier() == identifier { return button }
      }
      return nil
    }
    settle()
    let canvas = try XCTUnwrap(f.session.canvas)
    XCTAssertTrue(canvas.window === f.window)
    canvas.setZoom(0.8); canvas.ensureViewportCoverage(preserving: f.leafPoint)
    let project = try XCTUnwrap(f.store.project), viewport = canvas.visibleCanvasRect, zoom = canvas.zoom
    for _ in 0..<3 {
      f.session.navigateGroup(to: f.levels[3], selection: [f.leafID]); settle()
      let button = try XCTUnwrap(findButton(identifier: "canvas-group-leave"))
      let field = NSTextField(frame: .init(x: 320, y: 300, width: 100, height: 24))
      host.addSubview(field); f.window.makeFirstResponder(field)
      XCTAssertFalse(f.window.firstResponder === canvas)
      XCTAssertTrue(button.accessibilityPerformPress())
      XCTAssertEqual(f.session.scopeID, f.levels[2], "The button must ascend one level before another layout pass")
      XCTAssertEqual(f.session.selection, [f.levels[3]])
      XCTAssertTrue(f.window.firstResponder === canvas)
      field.removeFromSuperview(); settle()
      XCTAssertTrue(f.session.canvas === canvas)
      let rootButton = try XCTUnwrap(findButton(identifier: "canvas-group-root"))
      XCTAssertTrue(rootButton.accessibilityPerformPress())
      XCTAssertNil(f.session.scopeID, "The Canvas breadcrumb leaves every isolation level immediately")
      XCTAssertTrue(f.window.firstResponder === canvas)
      settle()
    }
    assertUnchanged(f, project, viewport, zoom)
  }
}

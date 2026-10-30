import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class CanvasContextMenuTests: XCTestCase {
  @MainActor private final class Fixture {
    let root: URL, store: StudioStore, session: ArtworkSession
    let window: NSWindow, scroll: ArtworkScrollView, canvas: VectorCanvasView
    let workspaceID: UUID, frameID: UUID
    init(_ elements: [ArtworkElement]) throws {
      _ = NSApplication.shared
      root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-menu-" + UUID().uuidString)
      store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
      var project = Project(name: "Canvas context controls")
      workspaceID = try project.ensureCanvasWorkspace().id
      project.objects[0].artwork?.elements = elements
      project.objects[0].artwork?.snapEnabled = false
      var frame = try project.makeObject(recipeID: "artboard", name: "Other source", parameters: ["width": 80, "depth": 60])
      frame.artwork = Artwork(background: "#FFFFFF", bleed: 0)
      frame.artwork?.canvasPosition = .init(300, 200)
      frameID = frame.id; project.objects.append(frame)
      project.schemaVersion = project.minimumSchemaVersion
      store.engine.project = project; store.mode = .artwork; store.showingHome = false
      session = store.artworkSession; session.activate(workspaceID)
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
      try? FileManager.default.removeItem(at: root)
    }
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
      let location = canvas.convert(canvas.documentPoint(point), to: nil)
      return NSEvent.mouseEvent(with: type, location: location,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    func menu(_ point: CGPoint) throws -> NSMenu {
      try XCTUnwrap(canvas.menu(for: mouse(.rightMouseDown, point)))
    }
    func invoke(_ item: NSMenuItem) throws {
      let action = try XCTUnwrap(item.action)
      XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
    }
  }
  private func shape(_ name: String, _ x: Double = 0, _ y: Double = 0, width: Double = 30, height: Double = 25) -> ArtworkElement {
    var result = ArtworkElement(kind: "rectangle", x: x, y: y, width: width, height: height)
    result.name = name; return result
  }
  private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
    try XCTUnwrap(menu.items.first { $0.title == title })
  }

  func testRightClickTargetsTheObjectAndInspectorActionIsScopedWithoutDocumentMutation() throws {
    let a = shape("First"), b = shape("Second", 60)
    let f = try Fixture([a, b]); defer { f.close() }
    f.session.choose([a.id])
    let before = f.store.project
    let menu = try f.menu(.init(x: 70, y: 10))
    XCTAssertEqual(f.session.selection, [b.id])
    var received: ArtworkSession?
    let observer = NotificationCenter.default.addObserver(forName: .formShowCanvasInspector,
      object: nil, queue: .main) { notification in received = notification.object as? ArtworkSession }
    defer { NotificationCenter.default.removeObserver(observer) }
    try f.invoke(item("Show Inspector", in: menu))
    XCTAssertTrue(received === f.session)
    XCTAssertEqual(f.store.project, before)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testRightClickPreservesMultiselectionAndGroupUngroupAreSeparateUndoSteps() throws {
    let a = shape("First"), b = shape("Second", 60)
    let f = try Fixture([a, b]); defer { f.close() }
    f.session.choose([a.id, b.id]); let before = f.store.project
    var menu = try f.menu(.init(x: 10, y: 10))
    XCTAssertEqual(f.session.selection, [a.id, b.id])
    XCTAssertTrue(try item("Group", in: menu).isEnabled)
    try f.invoke(item("Group", in: menu))
    let group = try XCTUnwrap(f.session.primary)
    XCTAssertEqual(group.kind, "group"); XCTAssertEqual(f.store.engine.undoStack.count, 1)
    // The next menu must use the newly authored hierarchy immediately.
    menu = try f.menu(.init(x: 10, y: 10))
    XCTAssertEqual(f.session.selection, [group.id])
    XCTAssertTrue(try item("Ungroup", in: menu).isEnabled)
    try f.invoke(item("Ungroup", in: menu))
    XCTAssertEqual(f.session.selection, [a.id, b.id]); XCTAssertEqual(f.store.engine.undoStack.count, 2)
    XCTAssertNil(f.store.error)
    f.store.engine.undo(); f.store.engine.undo(); XCTAssertEqual(f.store.project, before)
  }

  func testRightClickCancelsHeldDragBeforeSelectingAnotherLayerAndLateEventsStayInert() throws {
    let a = shape("First"), b = shape("Second", 60)
    let f = try Fixture([a, b]); defer { f.close() }
    f.session.choose([a.id]); let before = f.store.project
    f.canvas.mouseDown(with: f.mouse(.leftMouseDown, .init(x: 10, y: 10)))
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, .init(x: 20, y: 20)))
    XCTAssertNotEqual(f.store.project, before)
    _ = try f.menu(.init(x: 70, y: 10))
    XCTAssertEqual(f.store.project, before, "Opening a context menu cancels the held drag before changing selection")
    XCTAssertEqual(f.session.selection, [b.id])
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, .init(x: 100, y: 40)))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, .init(x: 100, y: 40)))
    XCTAssertEqual(f.store.project, before)
    XCTAssertEqual(f.session.selection, [b.id])
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testDeepProbeSelectsTransformedDescendantAndOffersImmediateScopeExit() throws {
    var outer = ArtworkElement(kind: "group", x: 20, y: 30, width: 120, height: 90)
    outer.name = "Outer"; outer.contentSize = .init(120, 90); outer.rotation = 15
    var inner = ArtworkElement(kind: "group", x: 10, y: 10, width: 60, height: 45)
    inner.name = "Inner"; inner.contentSize = .init(60, 45); inner.parentID = outer.id
    var leaf = shape("Leaf", 5, 5); leaf.parentID = inner.id
    let f = try Fixture([outer, inner, leaf]); defer { f.close() }
    let point = f.session.art.worldTransform(leaf).apply(.init(15, 12))
    var menu = try f.menu(.init(x: point.x, y: point.y))
    let probe = try XCTUnwrap(item("Select Layer", in: menu).submenu)
    XCTAssertEqual(probe.items.map(\.title), ["Outer › Inner › Leaf", "Outer › Inner", "Outer"])
    try f.invoke(try XCTUnwrap(probe.items.first { $0.identifier?.rawValue == leaf.id.uuidString }))
    XCTAssertEqual(f.session.selection, [leaf.id]); XCTAssertEqual(f.session.scopeID, inner.id)
    menu = try f.menu(.init(x: point.x, y: point.y))
    try f.invoke(item("Leave Group", in: menu))
    XCTAssertEqual(f.session.scopeID, outer.id); XCTAssertEqual(f.session.selection, [inner.id])
    menu = try f.menu(.init(x: point.x, y: point.y))
    try f.invoke(item("Return to Canvas", in: menu))
    XCTAssertNil(f.session.scopeID); XCTAssertTrue(f.session.selection.isEmpty)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testArrangeForwardSkipsInterleavedChildrenAndHasOneUndo() throws {
    let a = shape("First"), b = shape("Second", 60)
    var group = ArtworkElement(kind: "group", x: 140, y: 0, width: 40, height: 40)
    group.contentSize = .init(40, 40)
    var child = shape("Child"); child.parentID = group.id
    let f = try Fixture([a, child, b, group]); defer { f.close() }
    let before = f.store.project
    let menu = try f.menu(.init(x: 10, y: 10))
    let arrange = try XCTUnwrap(item("Arrange", in: menu).submenu)
    try f.invoke(item("Bring Forward", in: arrange))
    XCTAssertEqual(f.session.art.elements.filter { $0.parentID == nil }.map(\.id), [b.id, a.id, group.id])
    XCTAssertEqual(f.session.art.elements.first { $0.id == child.id }, child)
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    f.store.engine.undo(); XCTAssertEqual(f.store.project, before)
  }

  func testAlignAndDistributeMenusUseTheirActualCommandsWithIndependentUndo() throws {
    let a = shape("First", 0, 0, width: 10, height: 10)
    let b = shape("Second", 40, 20, width: 10, height: 10)
    let c = shape("Third", 100, 40, width: 10, height: 10)
    let f = try Fixture([a, b, c]); defer { f.close() }
    let before = f.store.project
    f.session.choose([a.id, b.id])
    var menu = try f.menu(.init(x: 5, y: 5))
    XCTAssertTrue(try item("Align", in: menu).isEnabled)
    XCTAssertFalse(try item("Distribute", in: menu).isEnabled)
    f.session.choose([a.id, b.id, c.id])
    menu = try f.menu(.init(x: 5, y: 5))
    let align = try XCTUnwrap(item("Align", in: menu).submenu)
    try f.invoke(item("Align Top", in: align))
    XCTAssertEqual(f.session.elements.map { f.session.art.bounds(of: $0).y }, [0, 0, 0])
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    menu = try f.menu(.init(x: 5, y: 5))
    let distribute = try XCTUnwrap(item("Distribute", in: menu).submenu)
    try f.invoke(item("Horizontal Spacing", in: distribute))
    let middle = try XCTUnwrap(f.session.art.elements.first { $0.id == b.id })
    XCTAssertEqual(f.session.art.bounds(of: middle).x, 50, accuracy: 0.000001)
    XCTAssertEqual(f.store.engine.undoStack.count, 2)
    XCTAssertNil(f.store.error)
    f.store.engine.undo(); f.store.engine.undo(); XCTAssertEqual(f.store.project, before)
  }

  func testLockedAndClippedLayersAreProbedSafelyAndStaleMenusCannotEditAnotherSource() throws {
    var locked = shape("Locked"); locked.locked = true
    var mask = shape("Mask", 60, 0, width: 10, height: 10); mask.hidden = true
    var hidden = shape("Clipped away", 71, 0, width: 10, height: 10); hidden.clipID = mask.id
    let f = try Fixture([locked, hidden, mask]); defer { f.close() }
    let before = f.store.project
    let lockedMenu = try f.menu(.init(x: 10, y: 10))
    XCTAssertEqual(f.session.selection, [locked.id])
    XCTAssertFalse(try item("Delete", in: lockedMenu).isEnabled)
    XCTAssertFalse(try item("Arrange", in: lockedMenu).isEnabled)
    let probe = try XCTUnwrap(item("Select Layer", in: lockedMenu).submenu)
    XCTAssertEqual(probe.items.map(\.title), ["Locked (Locked)"])
    let empty = try f.menu(.init(x: 69.8, y: 5))
    XCTAssertFalse(try item("Select Layer", in: empty).isEnabled)
    XCTAssertTrue(f.session.selection.isEmpty)
    XCTAssertEqual(f.store.project, before)

    var project = try XCTUnwrap(f.store.project)
    project.objects[0].artwork?.elements[0].locked = false
    f.store.engine.project = project; f.canvas.synchronize()
    let stale = try f.menu(.init(x: 10, y: 10))
    f.session.activate(f.frameID); f.canvas.synchronize()
    try f.invoke(item("Delete", in: stale))
    XCTAssertEqual(f.store.project, project)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testOpeningContextMenuPreservesActiveMaskEditingUntilExplicitCanvasExit() throws {
    var mask = shape("Mask"); mask.hidden = true
    var content = shape("Clipped content", 0, 0, width: 60, height: 40)
    content.clipID = mask.id
    let f = try Fixture([content, mask]); defer { f.close() }
    f.session.editMask(mask.id); f.canvas.synchronize()
    let before = f.store.project, scope = f.session.scopeID
    let menu = try f.menu(.init(x: 10, y: 10))
    XCTAssertEqual(f.session.maskEditing?.maskID, mask.id)
    XCTAssertEqual(f.session.maskEditing?.targets, [content.id])
    XCTAssertEqual(f.session.selection, [mask.id])
    XCTAssertEqual(f.session.scopeID, scope)
    XCTAssertFalse(try item("Delete", in: menu).isEnabled)
    XCTAssertFalse(try item("Arrange", in: menu).isEnabled)
    XCTAssertEqual(f.store.project, before)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    try f.invoke(item("Return to Canvas", in: menu))
    XCTAssertNil(f.session.maskEditing)
    XCTAssertNil(f.session.scopeID)
    XCTAssertTrue(f.session.selection.isEmpty)
    XCTAssertEqual(f.store.project, before)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testRightClickFromDeepIsolationSelectsNearestParentSiblingBeforeDestructiveAction() throws {
    var outer = ArtworkElement(kind: "group", x: 0, y: 0, width: 200, height: 100)
    outer.name = "Outer"; outer.contentSize = .init(200, 100)
    var inner = ArtworkElement(kind: "group", x: 10, y: 10, width: 80, height: 60)
    inner.name = "Inner"; inner.contentSize = .init(80, 60); inner.parentID = outer.id
    var deep = ArtworkElement(kind: "group", x: 10, y: 10, width: 30, height: 30)
    deep.name = "Deep"; deep.contentSize = .init(30, 30); deep.parentID = inner.id
    var leaf = shape("Leaf", 5, 5, width: 10, height: 10); leaf.parentID = deep.id
    var sibling = shape("Nearby sibling", 50, 10, width: 20, height: 20); sibling.parentID = inner.id
    let f = try Fixture([outer, inner, deep, leaf, sibling]); defer { f.close() }
    f.session.navigateGroup(to: deep.id, selection: [leaf.id])
    let before = f.store.project
    let point = f.session.art.worldTransform(sibling).apply(.init(10, 10))
    let menu = try f.menu(.init(x: point.x, y: point.y))
    XCTAssertEqual(f.session.scopeID, inner.id)
    XCTAssertEqual(f.session.selection, [sibling.id], "Right click uses the same nearest-scope target as hover and left click")
    try f.invoke(item("Delete", in: menu))
    XCTAssertEqual(Set(f.session.art.elements.map(\.id)), [outer.id, inner.id, deep.id, leaf.id])
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    f.store.engine.undo(); XCTAssertEqual(f.store.project, before)
  }

  func testMountedAlignmentButtonsHaveFullTargetsTrackSelectionAndProduceOneUndo() throws {
    let a = shape("First", 0, 0, width: 10, height: 10)
    let b = shape("Second", 40, 20, width: 20, height: 15)
    let c = shape("Third", 100, 40, width: 30, height: 20)
    let f = try Fixture([a, b, c]); defer { f.close() }
    let host = NSHostingView(rootView: CanvasArrangementControls(session: f.session).padding(12).labInterface())
    host.frame = .init(x: 600, y: 450, width: 280, height: 140)
    f.scroll.addSubview(host); f.window.orderBack(nil)
    defer { host.removeFromSuperview() }
    func settle() {
      host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)); host.layoutSubtreeIfNeeded()
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func controls() -> [WorkspaceToolbarNativeButton] {
      descendants(host).compactMap { $0 as? WorkspaceToolbarNativeButton }
    }
    f.session.choose([a.id]); settle()
    XCTAssertEqual(controls().count, 6)
    for button in controls() {
      XCTAssertFalse(button.isEnabled)
      XCTAssertEqual(button.bounds.size, .init(width: 32, height: 32))
      XCTAssertEqual(button.frame.size, .init(width: 32, height: 32))
    }
    f.session.choose([a.id, b.id, c.id]); settle()
    XCTAssertTrue(controls().allSatisfy(\.isEnabled))
    for button in controls() {
      for x in [CGFloat(1), 31] { for y in [CGFloat(1), 31] {
        // NSView.hitTest expects coordinates in the receiver's superview.
        let point = button.convert(.init(x: x, y: y), to: host.superview)
        let hit = host.hitTest(point)
        XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true)
      } }
    }
    let before = f.store.project
    let alignLeft = try XCTUnwrap(controls().first { $0.accessibilityIdentifier() == "canvas-align.left" })
    let field = NSTextField(frame: .init(x: 610, y: 400, width: 90, height: 24))
    f.scroll.addSubview(field); defer { field.removeFromSuperview() }
    f.window.makeFirstResponder(field)
    XCTAssertTrue(alignLeft.accessibilityPerformPress())
    XCTAssertEqual(f.session.elements.map { f.session.art.bounds(of: $0).x }, [0, 0, 0])
    XCTAssertEqual(f.session.elements.map { f.session.art.bounds(of: $0).y }, [0, 20, 40])
    XCTAssertEqual(f.store.engine.undoStack.count, 1)
    XCTAssertTrue(f.window.firstResponder === f.canvas)
    f.store.engine.undo(); f.canvas.synchronize()
    XCTAssertEqual(f.store.project, before)
    f.session.choose([a.id]); settle()
    XCTAssertTrue(controls().allSatisfy { !$0.isEnabled })
  }
}

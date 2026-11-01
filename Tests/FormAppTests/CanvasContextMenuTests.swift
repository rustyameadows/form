import AppKit
import FormCore
import FormGraphics
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

  func testGenerateHereCreatesOneBlankArtboardAtTheContextPointAndUndoRemovesIt() throws {
    let f=try Fixture([]);defer{f.canvas.closeCanvasImagePrompt();f.close()}
    let original=f.store.project
    let menu=try f.menu(.init(x:130,y:90))
    try f.invoke(item("Generate Image Here…",in:menu))
    let draft=try XCTUnwrap(f.store.canvasImages.draft)
    let board=try XCTUnwrap(f.store.project?.objects.first{$0.id==draft.destinationID})
    XCTAssertEqual(board.artwork?.canvasPosition,Point2(130,90))
    XCTAssertTrue(board.artwork?.elements.isEmpty == true)
    XCTAssertEqual(f.store.engine.undoStack.count,1)
    f.canvas.closeCanvasImagePrompt();f.store.engine.undo()
    XCTAssertEqual(f.store.project,original)
    XCTAssertFalse(f.store.canvasImages.canGenerate)
  }

  func testGenerateFromNestedArtworkKeepsReferenceAndPlacesNewFrameNearby() throws {
    var group=shape("Dense group",20,40,width:80,height:70);group.kind="group"
    var a=shape("Nested artwork",3,4);a.parentID=group.id
    let f=try Fixture([group,a]);defer{f.canvas.closeCanvasImagePrompt();f.close()}
    let original=f.session.art
    let menu=try f.menu(.init(x:25,y:48))
    try f.invoke(item("Generate Image Using This as Reference…",in:menu))
    let draft=try XCTUnwrap(f.store.canvasImages.draft)
    XCTAssertEqual(draft.references.count,1)
    XCTAssertEqual(draft.references.first?.objectID,f.workspaceID)
    XCTAssertEqual(draft.references.first?.elementIDs,[group.id])
    XCTAssertEqual(f.store.project?.objects.first{$0.id==f.workspaceID}?.artwork,original)
    let board=try XCTUnwrap(f.store.project?.objects.first{$0.id==draft.destinationID})
    XCTAssertLessThan(try XCTUnwrap(board.artwork?.canvasPosition?.x),200,"Workspace references must be placed beside artwork, not at the 2,000 mm workspace edge")
  }

  func testReferenceInsideFiniteArtboardPlacesResultOutsideItsSourceBoard() throws {
    let f=try Fixture([]);defer{f.canvas.closeCanvasImagePrompt();f.close()}
    let layer=shape("Source detail",5,5,width:10,height:10)
    let index=try XCTUnwrap(f.store.engine.project?.objects.firstIndex{$0.id==f.frameID})
    f.store.engine.project?.objects[index].artwork?.elements=[layer]
    f.session.activate(f.frameID);f.canvas.synchronize()
    let menu=try f.menu(.init(x:310,y:210))
    try f.invoke(item("Generate Image Using This as Reference…",in:menu))
    let draft=try XCTUnwrap(f.store.canvasImages.draft)
    XCTAssertEqual(draft.references.first?.elementIDs,[layer.id])
    let board=try XCTUnwrap(f.store.project?.objects.first{$0.id==draft.destinationID})
    XCTAssertEqual(board.artwork?.canvasPosition,Point2(396,200))
    XCTAssertEqual(f.store.project?.objects[index].artwork?.elements,[layer])
  }

  func testNativeImagePromptOpensFirstTimeReopensAndRoutesTextUndoWithoutRemovingArtboard()async throws {
    let f=try Fixture([]);defer{f.canvas.closeCanvasImagePrompt();f.close()}
    f.window.makeKeyAndOrderFront(nil)
    try f.invoke(item("Generate Image Here…",in:try f.menu(.init(x:130,y:90))))
    try await Task.sleep(nanoseconds:80_000_000)
    let popover=try XCTUnwrap(f.canvas.imagePromptPopover)
    XCTAssertTrue(popover.isShown)
    XCTAssertEqual(popover.behavior,.transient)
    let host=try XCTUnwrap(popover.contentViewController?.view)
    func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    let editor=try XCTUnwrap(descendants(host).compactMap{$0 as? CanvasGenerationTextView}.first)
    XCTAssertGreaterThan(editor.bounds.width,100)
    let panelWindow=try XCTUnwrap(editor.window)
    panelWindow.makeKey()
    XCTAssertTrue(panelWindow.makeFirstResponder(editor))
    XCTAssertTrue(panelWindow.firstResponder === editor)
    let before=f.store.project
    let destinationID=try XCTUnwrap(f.store.canvasImages.draft?.destinationID)
    editor.insertText("A blue horizon",replacementRange:NSRange(location:0,length:0))
    editor.breakUndoCoalescing()
    try await Task.sleep(nanoseconds:80_000_000)
    XCTAssertEqual(f.store.canvasImages.draft?.prompt,"A blue horizon")
    XCTAssertTrue(panelWindow.firstResponder === editor)
    XCTAssertTrue(editor.undoManager?.canUndo == true,"The real prompt editor must own a native text Undo before routing through StudioStore")
    f.store.undo()
    XCTAssertEqual(editor.string,"")
    XCTAssertEqual(f.store.canvasImages.draft?.prompt,"")
    XCTAssertEqual(f.store.project,before)
    f.store.undo()
    XCTAssertEqual(f.store.project,before,"Exhausting prompt Undo must not remove the artboard while text retains focus")
    f.store.redo()
    XCTAssertEqual(editor.string,"A blue horizon")
    XCTAssertEqual(f.store.canvasImages.draft?.prompt,"A blue horizon")
    f.canvas.closeCanvasImagePrompt();f.canvas.showCanvasImagePrompt()
    try await Task.sleep(nanoseconds:80_000_000)
    XCTAssertTrue(f.canvas.imagePromptPopover?.isShown == true)
    XCTAssertEqual(f.store.canvasImages.draft?.prompt,"A blue horizon")
    XCTAssertEqual(f.store.project,before)
    f.canvas.closeCanvasImagePrompt()
    f.window.makeKey()
    XCTAssertTrue(f.window.makeFirstResponder(f.canvas))
    XCTAssertFalse(f.canvas.applyCanvasImageTextHistory(redo:false))
    f.store.undo()
    XCTAssertFalse(f.store.project?.objects.contains{$0.id==destinationID} == true)
    XCTAssertEqual(f.store.project?.objects.count,(before?.objects.count ?? 0)-1)
    XCTAssertEqual(f.store.engine.redoStack.count,1,"Canvas focus restores ordinary document Undo")
  }

  func testContinuePromptReopensTheCapturedDraftAfterSelectionChangesWithoutRefittingOrHistory() async throws {
    let f = try Fixture([]); defer { f.canvas.closeCanvasImagePrompt(); f.close() }
    f.window.makeKeyAndOrderFront(nil)
    let destination = try f.store.canvasImages.begin(at: .init(130, 90),
      reference: .init(objectID: f.frameID, title: "Other source"))
    f.store.canvasImages.updatePrompt("Keep this quiet coral landscape")
    var options = try XCTUnwrap(f.store.canvasImages.draft?.options)
    options.model = .flare
    f.store.canvasImages.updateOptions(options)
    f.canvas.synchronize(); XCTAssertTrue(f.canvas.fit(frameIDs: [destination]))
    let menu = try f.menu(.init(x: 140, y: 100))
    let resume = try item("Continue Image Prompt…", in: menu)
    // An inspector selection or a delayed menu action must not make reopening
    // depend on the old layer selection, or create a second image artboard.
    f.session.activate(f.workspaceID); f.canvas.synchronize()
    let before = f.store.project, history = f.store.engine.undoStack
    let draft = f.store.canvasImages.draft, viewport = f.canvas.visibleCanvasRect
    let zoom = f.canvas.zoom
    let fitRequest = try XCTUnwrap((f.canvas.diagnostics["last_fit"] as? [String: Any])?["request"] as? Int)
    // AppKit aligns the clip origin when the native popover gains focus. Allow
    // at most half a backing pixel of translation, while requiring unchanged
    // zoom and the exact fit invocation count.
    let roundingMM = 0.5 / (TypographyEngine.pointsPerMM * zoom * f.window.backingScaleFactor)
    try f.invoke(resume)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertTrue(f.canvas.imagePromptPopover?.isShown == true)
    XCTAssertEqual(f.store.canvasImages.draft, draft)
    XCTAssertEqual(f.session.activeFrameID, destination)
    XCTAssertEqual(f.store.project, before); XCTAssertEqual(f.store.engine.undoStack, history)
    XCTAssertEqual(f.canvas.zoom, zoom)
    XCTAssertEqual((f.canvas.diagnostics["last_fit"] as? [String: Any])?["request"] as? Int, fitRequest)
    let delta = hypot(f.canvas.visibleCanvasRect.minX - viewport.minX, f.canvas.visibleCanvasRect.minY - viewport.minY)
    XCTAssertLessThanOrEqual(delta, roundingMM)
    XCTAssertEqual(f.canvas.visibleCanvasRect.width, viewport.width, accuracy: 0.00001)
    XCTAssertEqual(f.canvas.visibleCanvasRect.height, viewport.height, accuracy: 0.00001)
    f.canvas.closeCanvasImagePrompt()
    let fresh = try item("Continue Image Prompt…", in: f.menu(.init(x: 140, y: 100)))
    try f.invoke(fresh)
    try await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertTrue(f.canvas.imagePromptPopover?.isShown == true)
    XCTAssertEqual(f.store.canvasImages.draft, draft)
    XCTAssertEqual(f.canvas.zoom, zoom)
    XCTAssertEqual((f.canvas.diagnostics["last_fit"] as? [String: Any])?["request"] as? Int, fitRequest)
  }

  func testDeferredContinueCannotOpenAReplacementDraftOrAnotherProjectEpoch() async throws {
    let f = try Fixture([]); defer { f.canvas.closeCanvasImagePrompt(); f.close() }
    f.window.makeKeyAndOrderFront(nil)
    _ = try f.store.canvasImages.begin(at: .init(130, 90))
    f.canvas.synchronize()
    let oldAction = try item("Continue Image Prompt…", in: f.menu(.init(x: 140, y: 100)))
    try f.invoke(oldAction)
    let replacement = try f.store.canvasImages.begin(at: .init(410, 90))
    f.store.canvasImages.updatePrompt("A different draft")
    let expected = f.store.canvasImages.draft
    try await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertNil(f.canvas.imagePromptPopover)
    XCTAssertEqual(f.store.canvasImages.draft, expected)
    try f.invoke(oldAction)
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertNil(f.canvas.imagePromptPopover)
    XCTAssertEqual(f.store.canvasImages.draft?.destinationID, replacement)
    let current = try XCTUnwrap(f.canvas.canvasImagePromptIdentity)
    XCTAssertTrue(f.canvas.requestCanvasImagePrompt(current))
    f.store.artworkTransferProjectEpoch = UUID()
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertNil(f.canvas.imagePromptPopover)
    XCTAssertFalse(f.canvas.requestCanvasImagePrompt(current))
  }

  func testNativeArtboardPromptButtonKeepsItsScreenTargetThroughZoomAndScrollAndReopens() async throws {
    let f = try Fixture([]); defer { f.canvas.closeCanvasImagePrompt(); f.close() }
    f.window.makeKeyAndOrderFront(nil)
    let destination = try f.store.canvasImages.begin(at: .init(130, 90))
    f.store.canvasImages.updatePrompt("A folded paper landscape")
    f.canvas.synchronize(); XCTAssertTrue(f.canvas.fit(frameIDs: [destination]))
    let button = try XCTUnwrap(f.scroll.subviews.compactMap { $0 as? CanvasImagePromptButton }.first)
    let board = try XCTUnwrap(f.session.frames.first { $0.id == destination })
    let corner = CGPoint(x: board.rect.maxX, y: board.rect.minY)
    for zoom in [0.25, 1.0, 4.0] {
      f.canvas.setZoom(zoom, atCanvasPoint: corner)
      XCTAssertFalse(button.isHidden, "Prompt action should remain reachable at \(zoom)×")
      XCTAssertEqual(button.frame.size, CanvasImagePromptButton.buttonSize)
      let anchor = f.canvas.convert(f.canvas.documentPoint(corner), to: f.scroll)
      XCTAssertEqual(button.frame.maxX, anchor.x, accuracy: 0.00001)
      let gap = f.scroll.isFlipped ? anchor.y - button.frame.maxY : button.frame.minY - anchor.y
      XCTAssertGreaterThanOrEqual(gap, 18, "The action must not steal the artboard title or resize-corner hit target")
    }
    let clip = f.scroll.contentView
    clip.scroll(to: .init(x: clip.bounds.minX + 3, y: clip.bounds.minY + 2))
    f.scroll.reflectScrolledClipView(clip)
    try await Task.sleep(nanoseconds: 30_000_000)
    let afterScroll = f.canvas.convert(f.canvas.documentPoint(corner), to: f.scroll)
    XCTAssertEqual(button.frame.maxX, afterScroll.x, accuracy: 0.00001)
    XCTAssertFalse(button.isHidden)
    let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
    let hit = f.scroll.hitTest(button.convert(center, to: f.scroll.superview))
    XCTAssertTrue(hit === button, "The visible control must own its actual pointer target")
    let location = button.convert(center, to: nil), time = ProcessInfo.processInfo.systemUptime
    let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
      modifierFlags: [], timestamp: time, windowNumber: f.window.windowNumber, context: nil,
      eventNumber: 1, clickCount: 1, pressure: 1))
    let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
      modifierFlags: [], timestamp: time + 0.01, windowNumber: f.window.windowNumber, context: nil,
      eventNumber: 2, clickCount: 1, pressure: 0))
    let before = f.store.project, history = f.store.engine.undoStack
    NSApp.postEvent(up, atStart: true); f.window.sendEvent(down)
    if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
      f.window.sendEvent(pending)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertTrue(f.canvas.imagePromptPopover?.isShown == true)
    XCTAssertEqual(f.store.canvasImages.draft?.prompt, "A folded paper landscape")
    XCTAssertEqual(f.store.project, before); XCTAssertEqual(f.store.engine.undoStack, history)
  }

  func testPromptButtonDisappearsOnArtboardUndoAndCannotOpenFromAStaleControl() async throws {
    let f = try Fixture([]); defer { f.canvas.closeCanvasImagePrompt(); f.close() }
    f.window.makeKeyAndOrderFront(nil)
    let destination = try f.store.canvasImages.begin(at: .init(130, 90))
    f.canvas.synchronize(); XCTAssertTrue(f.canvas.fit(frameIDs: [destination]))
    let button = try XCTUnwrap(f.scroll.subviews.compactMap { $0 as? CanvasImagePromptButton }.first)
    let identity = try XCTUnwrap(f.canvas.canvasImagePromptIdentity)
    f.store.engine.undo(); f.canvas.synchronize()
    XCTAssertNil(button.superview)
    XCTAssertFalse(f.canvas.requestCanvasImagePrompt(identity))
    button.performClick(nil)
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertNil(f.canvas.imagePromptPopover)
    f.store.engine.redo(); f.canvas.synchronize()
    XCTAssertNotNil(f.canvas.canvasImagePromptIdentity)
    XCTAssertNotNil(f.scroll.subviews.compactMap { $0 as? CanvasImagePromptButton }.first)
    f.store.canvasImages.dismiss(); f.canvas.synchronize()
    XCTAssertTrue(f.scroll.subviews.compactMap { $0 as? CanvasImagePromptButton }.isEmpty)
  }

  func testActualCanvasPopoverMouseClickTransfersTypingFromPromptToSavedName()async throws {
    let f=try Fixture([]);defer{f.canvas.closeCanvasImagePrompt();f.close()}
    f.window.makeKeyAndOrderFront(nil)
    try f.invoke(item("Generate Image Here…",in:try f.menu(.init(x:130,y:90))))
    try await Task.sleep(nanoseconds:100_000_000)
    let popover=try XCTUnwrap(f.canvas.imagePromptPopover),host=try XCTUnwrap(popover.contentViewController?.view)
    let panel=try XCTUnwrap(host.window)
    func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    func focusDescription()->String {
      "active=\(NSApp.isActive), key=\(String(describing:NSApp.keyWindow)), panelKey=\(panel.isKeyWindow), responder=\(String(describing:panel.firstResponder))"
    }
    func click(_ target:NSView)throws {
      let center=CGPoint(x:target.bounds.midX,y:target.bounds.midY)
      let hit=host.hitTest(target.convert(center,to:host.superview))
      XCTAssertTrue(hit === target || hit?.isDescendant(of:target)==true,
        "Actual popover target intercepted by \(String(describing:hit)); \(focusDescription())")
      let location=target.convert(center,to:nil),time=ProcessInfo.processInfo.systemUptime
      let down=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:time,
        windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
      let up=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:time+0.01,
        windowNumber:panel.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0))
      NSApp.postEvent(up,atStart:true);panel.sendEvent(down)
      if let pending=NSApp.nextEvent(matching:.leftMouseUp,until:.distantPast,inMode:.default,dequeue:true) {panel.sendEvent(pending)}
    }
    let prompt=try XCTUnwrap(descendants(host).compactMap{$0 as? CanvasGenerationTextView}.first)
    XCTAssertTrue(panel.firstResponder === prompt,focusDescription())
    let initial=try XCTUnwrap(panel.firstResponder as? NSTextView)
    initial.insertText("A blue horizon",replacementRange:.init(location:NSNotFound,length:0))
    try await Task.sleep(nanoseconds:80_000_000)
    let before=f.store.project,undo=f.store.engine.undoStack
    let save=try XCTUnwrap(descendants(host).compactMap{$0 as? NSButton}.first{$0.accessibilityIdentifier()=="canvas-generation-save-prompt"})
    try click(save);try await Task.sleep(nanoseconds:80_000_000)
    host.layoutSubtreeIfNeeded()
    let name=try XCTUnwrap(descendants(host).compactMap{$0 as? NSTextField}.first{$0.accessibilityIdentifier()=="canvas-generation-prompt-name"})
    XCTAssertTrue(name.isEditable);XCTAssertTrue(name.isEnabled)
    try click(name);try await Task.sleep(nanoseconds:80_000_000)
    XCTAssertFalse(panel.firstResponder === prompt,"Saved-name click retained prompt focus; "+focusDescription())
    let active=try XCTUnwrap(panel.firstResponder as? NSTextView,focusDescription())
    XCTAssertTrue(name.currentEditor() === active,"The real clicked name field must own typing; "+focusDescription())
    active.insertText("Chromatic landscape",replacementRange:.init(location:NSNotFound,length:0))
    try await Task.sleep(nanoseconds:80_000_000)
    XCTAssertEqual(f.store.canvasImages.draft?.prompt,"A blue horizon")
    XCTAssertEqual(name.stringValue,"Chromatic landscape")
    let enter=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
      windowNumber:panel.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
    panel.sendEvent(enter);try await Task.sleep(nanoseconds:80_000_000)
    let saved=try XCTUnwrap(f.store.canvasImages.promptLibrary?.savedPresets.first{$0.name=="Chromatic landscape"})
    XCTAssertEqual(saved.prompt,"A blue horizon");XCTAssertFalse(f.store.canvasImages.busy)
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.undoStack,undo)
    XCTAssertTrue(popover.isShown)
  }

  func testActualCanvasPopoverAccessibilityPressFocusesSavedNameWithoutSubmitting()async throws {
    let f=try Fixture([]);defer{f.canvas.closeCanvasImagePrompt();f.close()}
    f.window.makeKeyAndOrderFront(nil)
    try f.invoke(item("Generate Image Here…",in:try f.menu(.init(x:130,y:90))))
    try await Task.sleep(nanoseconds:100_000_000)
    let popover=try XCTUnwrap(f.canvas.imagePromptPopover),host=try XCTUnwrap(popover.contentViewController?.view)
    let panel=try XCTUnwrap(host.window)
    func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    let prompt=try XCTUnwrap(descendants(host).compactMap{$0 as? CanvasGenerationTextView}.first)
    XCTAssertTrue(panel.firstResponder === prompt)
    prompt.insertText("An accessible color study",replacementRange:.init(location:NSNotFound,length:0))
    try await Task.sleep(nanoseconds:80_000_000)
    let before=f.store.project,history=f.store.engine.undoStack
    let save=try XCTUnwrap(descendants(host).compactMap{$0 as? NSButton}.first{$0.accessibilityIdentifier()=="canvas-generation-save-prompt"})
    // AppKit's built-in button can perform the action while returning false
    // from this direct call; the revealed native field proves the outcome.
    _ = save.accessibilityPerformPress();try await Task.sleep(nanoseconds:80_000_000)
    let name=try XCTUnwrap(descendants(host).compactMap{$0 as? CanvasGenerationNativeTextField}.first{$0.accessibilityIdentifier()=="canvas-generation-prompt-name"})
    let priorResponder=panel.firstResponder
    name.isEnabled=false
    XCTAssertFalse(name.accessibilityPerformPress());XCTAssertTrue(panel.firstResponder === priorResponder)
    name.isEnabled=true;name.isEditable=false
    XCTAssertFalse(name.accessibilityPerformPress());XCTAssertTrue(panel.firstResponder === priorResponder)
    name.isEditable=true
    XCTAssertTrue(name.accessibilityPerformPress())
    let active=try XCTUnwrap(panel.firstResponder as? NSTextView)
    XCTAssertTrue(name.currentEditor() === active);XCTAssertFalse(active === prompt)
    XCTAssertTrue(f.store.canvasImages.promptLibrary?.savedPresets.isEmpty == true)
    XCTAssertEqual(f.store.canvasImages.draft?.status,.draft);XCTAssertFalse(f.store.canvasImages.busy)
    active.insertText("Coral forms",replacementRange:.init(location:NSNotFound,length:0))
    let enter=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
      windowNumber:panel.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
    panel.sendEvent(enter);try await Task.sleep(nanoseconds:80_000_000)
    let saved=try XCTUnwrap(f.store.canvasImages.promptLibrary?.savedPresets.first{$0.name=="Coral forms"})
    XCTAssertEqual(saved.prompt,"An accessible color study")
    XCTAssertEqual(f.store.canvasImages.draft?.prompt,"An accessible color study")
    XCTAssertEqual(f.store.canvasImages.draft?.status,.draft);XCTAssertFalse(f.store.canvasImages.busy)
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.undoStack,history)
    XCTAssertTrue(popover.isShown)
  }

  func testRightClickTargetsTheObjectAndInspectorActionIsScopedWithoutDocumentMutation() throws {
    let a = shape("First"), b = shape("Second", 60)
    let f = try Fixture([a, b]); defer { f.close() }
    f.session.choose([a.id])
    let before = f.store.project
    let menu = try f.menu(.init(x: 70, y: 10))
    XCTAssertEqual(f.session.selection, [a.id], "Opening a menu captures its target without changing the current selection.")
    var received: ArtworkSession?
    let observer = NotificationCenter.default.addObserver(forName: .formShowCanvasInspector,
      object: nil, queue: .main) { notification in received = notification.object as? ArtworkSession }
    defer { NotificationCenter.default.removeObserver(observer) }
    try f.invoke(item("Show Inspector", in: menu))
    XCTAssertTrue(received === f.session)
    XCTAssertEqual(f.session.selection, [b.id])
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
    XCTAssertEqual(f.session.selection, [a.id])
    f.canvas.mouseDragged(with: f.mouse(.leftMouseDragged, .init(x: 100, y: 40)))
    f.canvas.mouseUp(with: f.mouse(.leftMouseUp, .init(x: 100, y: 40)))
    XCTAssertEqual(f.store.project, before)
    XCTAssertEqual(f.session.selection, [a.id])
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
    XCTAssertTrue(f.session.selection.isEmpty)
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
    XCTAssertEqual(f.session.scopeID, deep.id)
    XCTAssertEqual(f.session.selection, [leaf.id], "Opening a context menu must preserve the current editing scope.")
    try f.invoke(item("Delete", in: menu))
    XCTAssertEqual(f.session.scopeID, inner.id, "The chosen action adopts its captured nearest-scope target.")
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

  func testNativeCopyReferenceTargetsHoveredLayerWithoutCommittingTextOrChangingSelection() throws {
    let text = ArtworkElement(kind: "text",x: 0,y: 0,width: 45,height: 24,text: "Editing this label",fontSize: 10)
    let other = shape("Reference this shape",70)
    let f = try Fixture([text,other]); defer { f.close() }
    let pasteboard = NSPasteboard.withUniqueName(); f.store.selectionReferencePasteboard = pasteboard
    f.session.choose([text.id]); f.canvas.beginText(text)
    let editor = try XCTUnwrap(f.canvas.activeTextView)
    editor.setSelectedRange(.init(location: 2,length: 4))
    let project = f.store.project, history = f.store.engine.undoStack, selection = f.session.selection
    let range = editor.selectedRange(), interaction = f.store.engine.hasActiveInteraction
    var commits = 0
    let observer = NotificationCenter.default.addObserver(forName: .formCommitArtworkFields,object: nil,queue: .main) { _ in commits += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }
    let menu = try f.menu(.init(x: 80,y: 10))
    let reference = try item("Copy reference",in: menu)
    XCTAssertEqual(reference.identifier?.rawValue,"canvas-copy-reference")
    try f.invoke(reference)
    let copied = try XCTUnwrap(pasteboard.string(forType: .string))
    XCTAssertTrue(copied.contains(other.id.uuidString)); XCTAssertTrue(copied.contains(f.workspaceID.uuidString))
    XCTAssertTrue(copied.contains("Reference this shape")); XCTAssertFalse(copied.contains(text.id.uuidString))
    try f.invoke(item("Copy ID",in: menu))
    XCTAssertEqual(pasteboard.string(forType: .string),other.id.uuidString)
    XCTAssertEqual(commits,0); XCTAssertEqual(f.session.selection,selection)
    XCTAssertTrue(f.canvas.activeTextView === editor); XCTAssertTrue(f.session.editingText)
    XCTAssertEqual(editor.selectedRange(),range)
    XCTAssertEqual(f.store.engine.hasActiveInteraction,interaction)
    XCTAssertEqual(f.store.project,project); XCTAssertEqual(f.store.engine.undoStack,history)
  }

  func testNativeCopyFrameHeaderAndMultipleLayerIDsKeepExistingSourceAndRejectAnotherProject() throws {
    let a = shape("First"), b = shape("Second",60)
    let f = try Fixture([a,b]); defer { f.close() }
    let pasteboard = NSPasteboard.withUniqueName(); f.store.selectionReferencePasteboard = pasteboard
    f.session.choose([a.id,b.id]); let before = f.store.project
    let menu = try f.menu(.init(x: 70,y: 10))
    try f.invoke(item("Copy IDs",in: menu))
    XCTAssertEqual(Set(try XCTUnwrap(pasteboard.string(forType: .string)).split(separator: "\n").map(String.init)),
      Set([a.id.uuidString,b.id.uuidString]))
    let frame = try XCTUnwrap(f.session.frames.first { $0.id == f.frameID })
    let header = CanvasFrameChrome.headerRect(for: frame,scale: TypographyEngine.pointsPerMM*f.canvas.zoom)
    let frameMenu = try f.menu(.init(x: header.midX,y: header.midY))
    try f.invoke(item("Copy reference",in: frameMenu))
    let copied = try XCTUnwrap(pasteboard.string(forType: .string))
    XCTAssertTrue(copied.contains(f.frameID.uuidString)); XCTAssertTrue(copied.contains("Other source"))
    try f.invoke(item("Copy ID",in: frameMenu))
    XCTAssertEqual(pasteboard.string(forType: .string),f.frameID.uuidString)
    XCTAssertEqual(f.session.activeFrameID,f.workspaceID); XCTAssertEqual(f.session.selection,[a.id,b.id])
    XCTAssertEqual(f.store.project,before); XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    pasteboard.clearContents(); pasteboard.setString("Keep current clipboard",forType: .string)
    f.store.engine.project = Project(name: "Different project")
    try f.invoke(item("Copy reference",in: frameMenu))
    XCTAssertEqual(pasteboard.string(forType: .string),"Keep current clipboard")
  }
}

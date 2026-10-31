import AppKit
import SwiftUI
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasImageGenerationPresentationTests:XCTestCase {
  private func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
  private func fixture()throws->StudioStore {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("canvas-generation-ui-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    var project=Project(name:"Canvas image study");_ = try project.ensureCanvasWorkspace()
    store.engine.project=project;store.showingHome=false;store.mode = .artwork
    _ = try store.canvasImages.begin(at:.init(30,40))
    addTeardownBlock{@MainActor in
      store.canvasImages.resetForProjectChange();store.engine.project=nil
      try? FileManager.default.removeItem(at:root)
    }
    return store
  }
  private func mount<V:View>(_ root:V)->NSHostingView<V> {
    let host=NSHostingView(rootView:root)
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:392,height:530),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil)
    addTeardownBlock{@MainActor in window.makeFirstResponder(nil);window.contentView=nil;window.close()}
    return host
  }
  private func settle(_ view:NSView)async throws {
    view.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:60_000_000);view.layoutSubtreeIfNeeded()
  }
  private func key(_ code:UInt16,flags:NSEvent.ModifierFlags=[])->NSEvent {
    NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,
      characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:code)!
  }
  func testPromptReturnSubmitsAndShiftReturnPreservesMultilineEditing() {
    let editor=CanvasGenerationTextView(frame:.init(x:0,y:0,width:300,height:120));editor.isRichText=false
    var submits=0;editor.submit={submits+=1}
    editor.string="First line";editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0))
    editor.keyDown(with:key(36,flags:.shift))
    XCTAssertTrue(editor.string.contains("\n"));XCTAssertEqual(submits,0)
    editor.keyDown(with:key(36));XCTAssertEqual(submits,1)
    editor.keyDown(with:key(36,flags:.command));XCTAssertEqual(submits,2)
  }
  func testRealPanelNativeGenerateButtonTracksPromptAndWritesNormalCanvasImage()async throws {
    let store=try fixture(),controller=store.canvasImages
    let host=mount(CanvasImageGenerationPanel(controller:controller,store:store,close:{}))
    try await settle(host)
    let button=try XCTUnwrap(descendants(host).compactMap{$0 as? NSButton}.first{$0.accessibilityIdentifier()=="canvas-generation-submit"})
    let editor=try XCTUnwrap(descendants(host).compactMap{$0 as? CanvasGenerationTextView}.first)
    XCTAssertFalse(button.isEnabled)
    editor.insertText("A quiet geometric landscape",replacementRange:NSRange(location:0,length:0))
    try await settle(host)
    XCTAssertEqual(controller.draft?.prompt,"A quiet geometric landscape")
    XCTAssertTrue(button.isEnabled)
    let hit=host.hitTest(button.convert(CGPoint(x:button.bounds.midX,y:button.bounds.midY),to:host.superview))
    XCTAssertTrue(hit === button || hit?.isDescendant(of:button)==true)
    button.performClick(nil)
    for _ in 0..<60 {
      try await Task.sleep(nanoseconds:30_000_000)
      if controller.draft?.status == .succeeded {break}
    }
    XCTAssertEqual(controller.draft?.status,.succeeded,controller.error ?? "")
    let destination=try XCTUnwrap(store.project?.objects.first{$0.id==controller.draft?.destinationID})
    XCTAssertEqual(destination.artwork?.elements.map(\.kind),["image"])
    XCTAssertEqual(store.studioImageConnection.state,.demoReady)
    try await settle(host)
    let done=try XCTUnwrap(descendants(host).compactMap{$0 as? NSButton}.first{$0.accessibilityIdentifier()=="canvas-generation-submit"})
    XCTAssertEqual(done.title,"Done")
    if let path=ProcessInfo.processInfo.environment["FORM_CANVAS_GENERATION_PROOF_DIR"],
      let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
      host.cacheDisplay(in:host.bounds,to:bitmap)
      try FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true)
      try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path).appendingPathComponent("canvas-generation-result.png"))
    }
  }
  func testControllerAndPromptLibraryAreRecreatedForAnotherProject()throws {
    let store=try fixture(),first=store.canvasImages
    _ = try XCTUnwrap(first.promptLibrary).save(name:"Original only",prompt:"First project's prompt")
    var next=Project(name:"Next project");_ = try next.ensureCanvasWorkspace()
    store.engine.project=next
    let second=store.canvasImages
    XCTAssertFalse(first === second)
    XCTAssertTrue(second.draft == nil)
    XCTAssertTrue(try XCTUnwrap(second.promptLibrary).savedPresets.isEmpty)
    XCTAssertFalse(first.busy)
  }
  func testInitialPromptFocusAndSavedPromptNameKeepTypingInTheFocusedNativeField()async throws {
    let store=try fixture(),controller=store.canvasImages,before=store.project,history=store.engine.undoStack
    let host=mount(CanvasImageGenerationPanel(controller:controller,store:store,close:{}))
    try await settle(host)
    let window=try XCTUnwrap(host.window)
    let promptEditor=try XCTUnwrap(descendants(host).compactMap{$0 as? CanvasGenerationTextView}.first)
    XCTAssertTrue(window.firstResponder === promptEditor,"First opening must focus the prompt without a click")
    XCTAssertGreaterThan(promptEditor.visibleRect.height,90,"Initial focus must leave the prompt viewport visible")
    let activePrompt=try XCTUnwrap(window.firstResponder as? NSTextView)
    activePrompt.insertText("A blue horizon",replacementRange:.init(location:NSNotFound,length:0))
    try await settle(host)
    XCTAssertEqual(controller.draft?.prompt,"A blue horizon")
    let save=try XCTUnwrap(descendants(host).compactMap{$0 as? NSButton}.first{
      $0.title=="Save prompt…" || $0.accessibilityLabel()=="Save prompt…"
    },"The actual mounted Save prompt control must be reachable")
    XCTAssertTrue(save.isEnabled);save.performClick(nil);try await settle(host)
    let name=try XCTUnwrap(descendants(host).compactMap{$0 as? NSTextField}.first{
      $0.accessibilityIdentifier()=="canvas-generation-prompt-name" || $0.placeholderString=="Prompt name"
    })
    let center=CGPoint(x:name.bounds.midX,y:name.bounds.midY)
    let hit=host.hitTest(name.convert(center,to:host.superview))
    XCTAssertTrue(hit === name || hit?.isDescendant(of:name)==true,
      "The saved-name field's visible center is intercepted by \(String(describing:hit))")
    let location=name.convert(center,to:nil),timestamp=ProcessInfo.processInfo.systemUptime
    let down=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:timestamp,
      windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
    let up=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:timestamp+0.01,
      windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0))
    // Queue only this window's synthetic release for AppKit's mouse-tracking
    // loop, then dispatch its press locally. Nothing reaches the global event tap.
    NSApp.postEvent(up,atStart:true);window.sendEvent(down)
    if let pending=NSApp.nextEvent(matching:.leftMouseUp,until:.distantPast,inMode:.default,dequeue:true) {window.sendEvent(pending)}
    try await settle(host)
    let nameEditor=try XCTUnwrap(name.currentEditor() as? NSTextView)
    XCTAssertFalse(nameEditor === promptEditor);XCTAssertTrue(window.firstResponder === nameEditor)
    let focusedEditor=try XCTUnwrap(window.firstResponder as? NSTextView)
    focusedEditor.insertText("Chromatic landscape",replacementRange:.init(location:NSNotFound,length:0))
    var options=try XCTUnwrap(controller.draft?.options);options.quality = .draft
    controller.updateOptions(options);try await settle(host)
    // Reparent the existing native scroll view, as a SwiftUI layout rebuild can
    // do. A fresh viewDidMoveToWindow callback must not claim the name field.
    let promptScroll=try XCTUnwrap(promptEditor.enclosingScrollView)
    promptScroll.documentView=nil;promptScroll.documentView=promptEditor
    try await settle(host)
    XCTAssertTrue(window.firstResponder === nameEditor)
    XCTAssertEqual(nameEditor.string,"Chromatic landscape")
    XCTAssertEqual(controller.draft?.prompt,"A blue horizon")
    let submit=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],
      timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,
      characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
    window.sendEvent(submit);try await settle(host)
    let saved=try XCTUnwrap(controller.promptLibrary?.savedPresets.first{$0.name=="Chromatic landscape"})
    XCTAssertEqual(saved.prompt,"A blue horizon")
    XCTAssertEqual(controller.draft?.status,.draft);XCTAssertFalse(controller.busy)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack,history)
    XCTAssertEqual(controller.promptLibrary?.savedPresets.count,1)
  }
}

import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class ArtworkTransferLifecycleTests:XCTestCase {
  private final class Gate {
    var entered=false
    private var continuation:CheckedContinuation<Void,Never>?
    func hold()async {await withCheckedContinuation{continuation=$0;entered=true}}
    func release(){let pending=continuation;continuation=nil;pending?.resume()}
  }
  private struct Fixture {
    let store:StudioStore,window:NSWindow,canvas:VectorCanvasView,board:NSPasteboard
    let first:UUID,second:UUID,firstText:ArtworkElement,secondText:ArtworkElement
    let portableName:String,bytes:Data
  }
  private func fixture()throws->Fixture {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("transfer-lifecycle-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    func text(_ words:String)->ArtworkElement {
      var element=ArtworkElement(kind:"text",x:12,y:12,width:140,height:60,text:words,fontSize:24)
      var type=Typography();type.fontName=".AppleSystemUIFont";type.frameMode="area";element.typography=type;return element
    }
    var project=Project(name:"Transfer lifetime")
    var first=try project.makeObject(recipeID:"artboard",parameters:["width":200,"depth":140])
    var second=try project.makeObject(recipeID:"artboard",parameters:["width":200,"depth":140])
    let firstText=text("First committed words"),secondText=text("Second committed words")
    first.artwork=Artwork(elements:[firstText]);first.artwork!.safeInset=5
    second.artwork=Artwork(elements:[secondText]);second.artwork!.safeInset=6
    project.objects=[first,second];project.schemaVersion=project.minimumSchemaVersion
    store.engine.project=project;try store.engine.flush();store.mode = .artwork;store.showingHome=false
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:900,height:700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:.init(x:0,y:0,width:900,height:700));canvas.session=store.artworkSession;store.artworkSession.canvas=canvas;store.artworkSession.objectID=first.id;store.artworkSession.choose([firstText.id]);window.contentView=canvas;window.orderBack(nil);canvas.synchronize();window.makeFirstResponder(canvas)
    let board=NSPasteboard.withUniqueName();store.artworkSession.transferPasteboard=board
    let context=CGContext(data:nil,width:4,height:3,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.orange.cgColor);context.fill(.init(x:0,y:0,width:4,height:3))
    let bytes=try XCTUnwrap(NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:]))
    var source=Project(name:"Image source");let owner=try source.ensureCanvasWorkspace()
    let image=ArtworkElement(kind:"image",x:5,y:8,width:30,height:20,asset:"source.png");source.objects[0].artwork!.elements=[image]
    let bundle=try ArtworkTransferGraph.capture(project:source,objectID:owner.id,ids:[image.id],readAsset:{_,_ in bytes})
    board.clearContents();XCTAssertTrue(board.setData(try bundle.encoded(),forType:ArtworkTransferPasteboard.type))
    try Data("Keep foreign asset".utf8).write(to:store.repository.url(for:project.id).appendingPathComponent("Assets/prior.png"))
    addTeardownBlock {MainActor.assumeIsolated {
      store.artworkTransferStageCheckpoint=nil;store.artworkSession.cancelArtworkTransfer();canvas.finishText();store.engine.project=nil;window.close();board.releaseGlobally();try? FileManager.default.removeItem(at:root)
    }}
    return .init(store:store,window:window,canvas:canvas,board:board,first:first.id,second:second.id,firstText:firstText,secondText:secondText,portableName:bundle.metadata.assets[0].portableName,bytes:bytes)
  }
  private func paste(_ fixture:Fixture)throws {
    let menu=NSMenu(),item=NSMenuItem(title:"Paste",action:#selector(VectorCanvasView.paste(_:)),keyEquivalent:"v");item.keyEquivalentModifierMask = .command;item.target=fixture.canvas;menu.addItem(item)
    let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:fixture.window.windowNumber,context:nil,characters:"v",charactersIgnoringModifiers:"v",isARepeat:false,keyCode:9))
    XCTAssertTrue(menu.performKeyEquivalent(with:event))
  }
  private func waitForGate(_ gate:Gate)async throws {
    for _ in 0..<200 {if gate.entered{return};try await Task.sleep(nanoseconds:5_000_000)}
    throw FormError.invalid("Transfer did not reach its held staging checkpoint.")
  }
  private func heldPaste(_ fixture:Fixture,_ gate:Gate)async throws->Task<Void,Never> {
    fixture.store.artworkTransferStageCheckpoint={await gate.hold()}
    try paste(fixture)
    let task=try XCTUnwrap(fixture.store.artworkSession.transferTask)
    try await waitForGate(gate)
    return task
  }
  private func draft(_ fixture:Fixture,_ element:ArtworkElement,_ words:String)throws->CanvasTextView {
    fixture.canvas.synchronize();fixture.canvas.beginText(element)
    let editor=try XCTUnwrap(fixture.window.firstResponder as? CanvasTextView)
    editor.textStorage!.replaceCharacters(in:.init(location:0,length:editor.string.utf16.count),with:words);editor.setSelectedRange(.init(location:3,length:4));return editor
  }
  private func assertNoPublishedAsset(_ fixture:Fixture,projectID:UUID,file:StaticString=#filePath,line:UInt=#line)throws {
    let assets=fixture.store.repository.url(for:projectID).appendingPathComponent("Assets")
    XCTAssertFalse(FileManager.default.fileExists(atPath:assets.appendingPathComponent(fixture.portableName).path),file:file,line:line)
    XCTAssertEqual(try Data(contentsOf:assets.appendingPathComponent("prior.png")),Data("Keep foreign asset".utf8),file:file,line:line)
    let stages=try FileManager.default.contentsOfDirectory(at:assets,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix(".form-transfer-")}
    XCTAssertEqual(stages.count,1,file:file,line:line)
    for stage in stages {
      XCTAssertFalse(FileManager.default.fileExists(atPath:stage.appendingPathComponent(fixture.portableName).path),file:file,line:line)
      XCTAssertTrue(FileManager.default.fileExists(atPath:stage.appendingPathComponent("intent.json").path),file:file,line:line)
    }
  }
  func testFrameSwitchWhileStagingPreservesNewerEditorCaretAndHistory()async throws {
    let f=try fixture(),gate=Gate();defer{gate.release()}
    let task=try await heldPaste(f,gate),projectID=f.store.project!.id
    f.store.artworkSession.activate(f.second)
    let editor=try draft(f,f.secondText,"Newer second-frame draft"),caret=editor.selectedRange(),before=f.store.project!,undo=f.store.engine.undoStack,selection=f.store.artworkSession.selection
    gate.release();await task.value
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.undoStack,undo);XCTAssertTrue(f.window.firstResponder === editor);XCTAssertEqual(editor.string,"Newer second-frame draft");XCTAssertEqual(editor.selectedRange(),caret);XCTAssertEqual(f.store.artworkSession.selection,selection)
    try assertNoPublishedAsset(f,projectID:projectID)
  }
  func testFrameRoundTripCannotReviveCancelledPaste()async throws {
    let f=try fixture(),gate=Gate();defer{gate.release()}
    let task=try await heldPaste(f,gate),projectID=f.store.project!.id
    f.store.artworkSession.activate(f.second);f.store.artworkSession.activate(f.first)
    let editor=try draft(f,f.firstText,"Draft after frame round trip"),caret=editor.selectedRange(),before=f.store.project!,undo=f.store.engine.undoStack
    gate.release();await task.value
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.undoStack,undo);XCTAssertTrue(f.window.firstResponder === editor);XCTAssertEqual(editor.string,"Draft after frame round trip");XCTAssertEqual(editor.selectedRange(),caret)
    try assertNoPublishedAsset(f,projectID:projectID)
  }
  func testScopeRoundTripCannotReviveCancelledPaste()async throws {
    let f=try fixture(),gate=Gate();defer{gate.release()}
    var group=ArtworkElement(kind:"group",x:0,y:0,width:180,height:110);group.contentSize = .init(180,110)
    var other=group;other.id=UUID();other.x=10
    var text=f.firstText;text.parentID=group.id
    f.store.engine.project!.objects[0].artwork!.elements=[group,other,text];try f.store.engine.flush();f.store.artworkSession.scopeID=group.id;f.canvas.synchronize()
    let task=try await heldPaste(f,gate),projectID=f.store.project!.id
    f.store.artworkSession.scopeID=other.id;f.store.artworkSession.scopeID=group.id
    let editor=try draft(f,text,"Draft after group round trip"),caret=editor.selectedRange(),before=f.store.project!,undo=f.store.engine.undoStack
    gate.release();await task.value
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.undoStack,undo);XCTAssertEqual(f.store.artworkSession.scopeID,group.id);XCTAssertTrue(f.window.firstResponder === editor);XCTAssertEqual(editor.string,"Draft after group round trip");XCTAssertEqual(editor.selectedRange(),caret)
    try assertNoPublishedAsset(f,projectID:projectID)
  }
  func testProjectAtoBtoARejectsOldLifetimeBeforeNewDraftHandoff()async throws {
    let f=try fixture(),gate=Gate();defer{gate.release()}
    let original=f.store.project!,epoch=f.store.artworkTransferProjectEpoch,other=Project(name:"Other lifetime");try f.store.repository.save(other)
    let task=try await heldPaste(f,gate)
    try f.store.engine.open(other.id);try f.store.engine.open(original.id)
    XCTAssertNotEqual(f.store.artworkTransferProjectEpoch,epoch)
    let editor=try draft(f,f.firstText,"Draft after reopening original"),caret=editor.selectedRange(),before=f.store.project!,undo=f.store.engine.undoStack
    gate.release();await task.value
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.undoStack,undo);XCTAssertTrue(f.window.firstResponder === editor);XCTAssertEqual(editor.string,"Draft after reopening original");XCTAssertEqual(editor.selectedRange(),caret)
    try assertNoPublishedAsset(f,projectID:original.id)
  }
  func testHomeCancelsPreparedPasteWithoutLateHistoryOrSelectionChanges()async throws {
    let f=try fixture(),gate=Gate();defer{gate.release()}
    let task=try await heldPaste(f,gate),projectID=f.store.project!.id
    f.store.home();let before=f.store.project!,undo=f.store.engine.undoStack,selection=f.store.artworkSession.selection
    gate.release();await task.value
    XCTAssertTrue(f.store.showingHome);XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.undoStack,undo);XCTAssertEqual(f.store.artworkSession.selection,selection)
    try assertNoPublishedAsset(f,projectID:projectID)
  }
  func testMCPDestinationLockedDuringStagingRejectsBeforeUnrelatedDraftHandoff()async throws {
    let f=try fixture(),gate=Gate();defer{gate.release()}
    let file=f.store.repository.root.appendingPathComponent("held.formart")
    try ArtworkTransferFile.writeNew(try XCTUnwrap(f.board.data(forType:ArtworkTransferPasteboard.type)),to:file)
    f.store.artworkTransferStageCheckpoint={await gate.hold()}
    let task=Task{_ = try await f.store.artworkTransferCallAsync(["command":"transfer_import","object_id":f.first.uuidString,"transfer_path":file.path])}
    try await waitForGate(gate)
    try f.store.engine.edit("Lock former destination"){$0.objects[0].locked=true}
    f.store.artworkSession.activate(f.second)
    let editor=try draft(f,f.secondText,"Keep unrelated MCP draft"),caret=editor.selectedRange(),before=f.store.project!,undo=f.store.engine.undoStack
    gate.release()
    do {try await task.value;XCTFail("A locked destination must reject")}catch{}
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.undoStack,undo);XCTAssertTrue(f.window.firstResponder === editor);XCTAssertEqual(editor.string,"Keep unrelated MCP draft");XCTAssertEqual(editor.selectedRange(),caret)
    try assertNoPublishedAsset(f,projectID:before.id)
  }
  func testUnchangedContextStillCommitsLaggingWordsReplansAndUsesOnePasteUndo()async throws {
    let f=try fixture(),gate=Gate();defer{gate.release()}
    let task=try await heldPaste(f,gate)
    _=try draft(f,f.firstText,"Committed only at valid handoff")
    gate.release();await task.value
    XCTAssertNil(f.store.artworkSession.lastTransferError)
    let art=try XCTUnwrap(f.store.project!.objects[0].artwork),image=try XCTUnwrap(art.elements.first{$0.kind=="image"})
    XCTAssertEqual(art.elements.first{$0.id==f.firstText.id}?.text,"Committed only at valid handoff");XCTAssertEqual(art.safeInset,5);XCTAssertEqual(f.store.engine.undoStack.count,2)
    let path=f.store.repository.url(for:f.store.project!.id).appendingPathComponent("Assets/"+image.asset!)
    XCTAssertEqual(try Data(contentsOf:path),f.bytes)
    f.store.engine.undo();XCTAssertFalse(f.store.project!.objects[0].artwork!.elements.contains{$0.kind=="image"});XCTAssertEqual(f.store.project!.objects[0].artwork!.elements.first{$0.id==f.firstText.id}?.text,"Committed only at valid handoff");XCTAssertEqual(try Data(contentsOf:path),f.bytes)
  }
}

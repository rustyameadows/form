import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class ArtworkTransferEditingTests:XCTestCase {
  private func project(_ name:String,text:Bool=false)throws->(Project,ProductObject) {
    var p=Project(name:name),o=try p.makeObject(recipeID:"artboard",parameters:["width":200,"depth":140])
    if text {var e=ArtworkElement(kind:"text",x:10,y:10,width:150,height:60,text:"Original words",color:"#203A4A",fontSize:24);var type=Typography();type.fontName=".AppleSystemUIFont";e.typography=type;o.artwork=Artwork(background:"#FFFFFF",elements:[e])}
    else {var group=ArtworkElement(kind:"group",x:15,y:20,width:90,height:60);group.contentSize = .init(90,60);group.rotation=17;var mask=ArtworkElement(kind:"ellipse",x:0,y:0,width:85,height:55);mask.parentID=group.id;var leaf=ArtworkElement(kind:"rectangle",x:5,y:5,width:75,height:45,color:"#D47745");leaf.parentID=group.id;leaf.clipID=mask.id;o.artwork=Artwork(background:"#FFFFFF",elements:[group,mask,leaf])}
    o.artwork!.backgroundOpacity=0;p.objects=[o];p.schemaVersion=p.minimumSchemaVersion;return(p,o)
  }
  private func fixture(text:Bool=false)throws->(StudioStore,NSWindow,VectorCanvasView,NSPasteboard) {
    _=NSApplication.shared;let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false);store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    let(p,o)=try project("Native transfer",text:text);store.engine.project=p;try store.engine.flush();store.mode = .artwork
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:900,height:700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:.init(x:0,y:0,width:900,height:700));canvas.session=store.artworkSession;store.artworkSession.canvas=canvas;store.artworkSession.objectID=o.id;store.artworkSession.choose([o.artwork!.elements[0].id]);window.contentView=canvas;window.orderBack(nil);canvas.synchronize();window.makeFirstResponder(canvas)
    let board=NSPasteboard.withUniqueName();store.artworkSession.transferPasteboard=board
    addTeardownBlock{MainActor.assumeIsolated{store.artworkSession.transferTask?.cancel();canvas.finishText();store.engine.project=nil;window.close();board.releaseGlobally()}}
    return(store,window,canvas,board)
  }
  private func key(_ character:String,_ code:UInt16,action:Selector,window:NSWindow,canvas:VectorCanvasView)throws {
    let menu=NSMenu(),item=NSMenuItem(title:character,action:action,keyEquivalent:character);item.keyEquivalentModifierMask = .command;item.target=canvas;menu.addItem(item)
    let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:code))
    XCTAssertTrue(menu.performKeyEquivalent(with:event))
  }
  private func wait(_ session:ArtworkSession)async throws {for _ in 0..<250 {if !session.transferInFlight{return};try await Task.sleep(nanoseconds:10_000_000)};XCTFail("Portable paste did not settle")}
  func testActualCopySwitchProjectPasteUsesPrivateBoardAndOneUndo()async throws {
    let(store,window,canvas,board)=try fixture(),source=store.project!,session=store.artworkSession
    try key("c",8,action:#selector(VectorCanvasView.copy(_:)),window:window,canvas:canvas)
    let payload=try XCTUnwrap(board.data(forType:ArtworkTransferPasteboard.type));XCTAssertEqual(try ArtworkTransferBundle.decode(payload).metadata.projectID,source.id);XCTAssertEqual(store.project,source);XCTAssertTrue(store.engine.undoStack.isEmpty)
    var(destination,o)=try project("New target");o.artwork!.elements=[];destination.objects=[o];try store.repository.save(destination);store.engine.project=destination;session.objectID=o.id;session.choose([]);canvas.synchronize()
    try key("v",9,action:#selector(VectorCanvasView.paste(_:)),window:window,canvas:canvas);try await wait(session)
    XCTAssertNil(session.lastTransferError);XCTAssertEqual(store.engine.undoStack.count,1);XCTAssertEqual(store.project!.objects[0].artwork!.elements.count,3);XCTAssertEqual(store.project!.camera,destination.camera)
    let result=store.project!;store.engine.undo();XCTAssertEqual(store.project,destination);store.engine.redo();XCTAssertEqual(store.project,result);try store.engine.flush();XCTAssertEqual(try store.repository.load(destination.id).objects[0].artwork,result.objects[0].artwork)
  }
  func testCopyPublicationFailureCannotCutAndSuccessfulCutHasOneRecoverableUndo()throws {
    let(store,window,canvas,board)=try fixture(),session=store.artworkSession,before=store.project!
    board.clearContents();board.setString("Keep private board",forType:.string)
    session.transferPasteboardPublisher={_,_,_ in false}
    try key("x",7,action:#selector(VectorCanvasView.cut(_:)),window:window,canvas:canvas)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty);XCTAssertEqual(board.string(forType:.string),"Keep private board");XCTAssertNotNil(session.lastTransferError)
    session.transferPasteboardPublisher=nil
    try key("x",7,action:#selector(VectorCanvasView.cut(_:)),window:window,canvas:canvas)
    XCTAssertTrue(store.project!.objects[0].artwork!.elements.isEmpty);XCTAssertEqual(store.engine.undoStack.count,1);XCTAssertNotNil(board.data(forType:ArtworkTransferPasteboard.type));store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testInvalidPastePreservesActiveUnpublishedTextCaretAndDocument()throws {
    let(store,window,canvas,board)=try fixture(text:true),session=store.artworkSession,before=store.project!,element=before.objects[0].artwork!.elements[0]
    canvas.beginText(element);let editor=try XCTUnwrap(window.firstResponder as? CanvasTextView);editor.textStorage!.replaceCharacters(in:.init(location:0,length:editor.string.utf16.count),with:"Unpublished words");editor.setSelectedRange(.init(location:3,length:4));let caret=editor.selectedRange()
    board.clearContents();board.setData(Data("invalid transfer".utf8),forType:ArtworkTransferPasteboard.type)
    try key("v",9,action:#selector(VectorCanvasView.paste(_:)),window:window,canvas:canvas)
    XCTAssertEqual(store.project,before);XCTAssertTrue(window.firstResponder === editor);XCTAssertEqual(editor.string,"Unpublished words");XCTAssertEqual(editor.selectedRange(),caret);XCTAssertTrue(store.engine.undoStack.isEmpty);XCTAssertNotNil(session.lastTransferError)
  }
  func testValidPasteCommitsThenReplansLaggingTextAndUndoKeepsThoseWords()async throws {
    let(store,window,canvas,board)=try fixture(text:true),session=store.artworkSession,source=store.project!,element=source.objects[0].artwork!.elements[0]
    var incoming=Project(name:"Incoming");let owner=try incoming.ensureCanvasWorkspace(),shape=ArtworkElement(kind:"ellipse",x:5,y:8);incoming.objects[0].artwork!.elements=[shape]
    let payload=try ArtworkTransferGraph.capture(project:incoming,objectID:owner.id,ids:[shape.id],readAsset:{_,_ in Data()}).encoded()
    canvas.beginText(element);let editor=try XCTUnwrap(window.firstResponder as? CanvasTextView);editor.textStorage!.replaceCharacters(in:.init(location:0,length:editor.string.utf16.count),with:"Committed during handoff");XCTAssertEqual(store.project!.objects[0].artwork!.elements[0].text,"Original words")
    board.clearContents();board.setData(payload,forType:ArtworkTransferPasteboard.type)
    try key("v",9,action:#selector(VectorCanvasView.paste(_:)),window:window,canvas:canvas);try await wait(session)
    XCTAssertNil(session.lastTransferError);XCTAssertEqual(store.project!.objects[0].artwork!.elements.count,2);XCTAssertEqual(store.project!.objects[0].artwork!.elements[0].text,"Committed during handoff");XCTAssertEqual(store.engine.undoStack.count,2)
    store.engine.undo();XCTAssertEqual(store.project!.objects[0].artwork!.elements.count,1);XCTAssertEqual(store.project!.objects[0].artwork!.elements[0].text,"Committed during handoff");store.engine.undo();XCTAssertEqual(store.project,source)
  }
  func testReadOnlyFileExportAndInvalidImportLeaveEditorActiveAndUnknownArgsReject()throws {
    let(store,window,canvas,_)=try fixture(text:true),before=store.project!,element=before.objects[0].artwork!.elements[0],path=store.repository.root.appendingPathComponent("copy.formart")
    canvas.beginText(element);let editor=try XCTUnwrap(window.firstResponder as? CanvasTextView);editor.textStorage!.replaceCharacters(in:.init(location:0,length:editor.string.utf16.count),with:"Still a draft");editor.setSelectedRange(.init(location:4,length:2))
    let args:[String:Any]=["command":"transfer_export","object_id":before.objects[0].id.uuidString,"transfer_path":path.path]
    _ = try store.engine.call("form_edit_artwork",arguments:args);XCTAssertEqual(store.project,before);XCTAssertTrue(window.firstResponder === editor);XCTAssertEqual(editor.string,"Still a draft");XCTAssertTrue(store.engine.undoStack.isEmpty)
    let bundle=try ArtworkTransferBundle.decode(ArtworkTransferFile.read(path));XCTAssertEqual(bundle.metadata.artwork.elements[0].text,"Original words")
    XCTAssertThrowsError(try store.engine.call("form_edit_artwork",arguments:args));var invalid=args;invalid["unexpected"]=true;XCTAssertThrowsError(try store.engine.call("form_edit_artwork",arguments:invalid));var reserved=args;reserved["transfer_path"]=store.repository.root.appendingPathComponent("intent.json").path;XCTAssertThrowsError(try store.engine.call("form_edit_artwork",arguments:reserved));XCTAssertFalse(FileManager.default.fileExists(atPath:reserved["transfer_path"] as! String));XCTAssertEqual(store.project,before);XCTAssertTrue(window.firstResponder === editor)
    let batch:[String:Any]=["operations":[["name":"form_edit_artwork","arguments":args]]];XCTAssertTrue(ArtworkTransferCommands.rejectsBatch("form_batch",batch));XCTAssertThrowsError(try store.engine.call("form_batch",arguments:batch));XCTAssertTrue(window.firstResponder === editor)
  }
  func testNativePrivateImagePasteSurvivesSourceAssetDeletionAndRetainsUndoResources()async throws {
    let(store,window,canvas,board)=try fixture(),session=store.artworkSession
    var source=store.project!;let sourceOwner=source.objects[0].id,folder=store.repository.url(for:source.id).appendingPathComponent("Assets")
    let context=CGContext(data:nil,width:12,height:8,bitsPerComponent:8,bytesPerRow:48,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;context.setFillColor(NSColor.orange.cgColor);context.fill(.init(x:0,y:0,width:12,height:8))
    let bytes=try XCTUnwrap(NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:])),originalName="native-original.png"
    try bytes.write(to:folder.appendingPathComponent(originalName))
    var image=ArtworkElement(kind:"image",x:10,y:12,width:60,height:40,asset:originalName);image.name=originalName;source.objects[0].artwork!.elements=[image];store.engine.project=source;session.choose([image.id]);canvas.synchronize()
    let started=Date();try key("c",8,action:#selector(VectorCanvasView.copy(_:)),window:window,canvas:canvas);let copyMs=Date().timeIntervalSince(started)*1000
    let wire=try XCTUnwrap(board.data(forType:ArtworkTransferPasteboard.type));XCTAssertNil(session.lastTransferError);XCTAssertEqual(try ArtworkTransferBundle.decode(wire).blobs[originalName],bytes)
    try FileManager.default.removeItem(at:folder)
    var(destination,o)=try project("Image destination");o.artwork!.elements=[];destination.objects=[o];try store.repository.save(destination);store.engine.project=destination;session.objectID=o.id;session.choose([]);canvas.synchronize()
    let pasteStart=Date();try key("v",9,action:#selector(VectorCanvasView.paste(_:)),window:window,canvas:canvas);try await wait(session);let pasteMs=Date().timeIntervalSince(pasteStart)*1000
    XCTAssertNil(session.lastTransferError);let copied=try XCTUnwrap(store.project!.objects[0].artwork!.elements.first),assets=store.repository.url(for:destination.id).appendingPathComponent("Assets"),name=try XCTUnwrap(copied.asset)
    XCTAssertEqual(try Data(contentsOf:assets.appendingPathComponent(name)),bytes);XCTAssertEqual(copied.name,originalName);XCTAssertNotEqual(name,originalName);XCTAssertEqual(store.engine.undoStack.count,1)
    store.engine.undo();XCTAssertEqual(store.project,destination);XCTAssertEqual(try Data(contentsOf:assets.appendingPathComponent(name)),bytes);store.engine.redo();try store.engine.flush();let reopened=try store.repository.load(destination.id);XCTAssertEqual(reopened.objects[0].artwork!.elements[0].asset,name)
    _=sourceOwner;print("TRANSFER48_NATIVE_IMAGE",["copy_ms":copyMs,"paste_ms":pasteMs,"wire_bytes":Double(wire.count),"original_bytes":Double(bytes.count)])
  }
  func testMalformedDecodedAssetInMCPFilePreservesPendingEditorAndAllPriorAssets()throws {
    let(store,window,canvas,_)=try fixture(text:true),before=store.project!,element=before.objects[0].artwork!.elements[0],assets=store.repository.url(for:before.id).appendingPathComponent("Assets")
    var incoming=Project(name:"Malformed image source");let owner=try incoming.ensureCanvasWorkspace(),image=ArtworkElement(kind:"image",x:0,y:0,asset:"broken.png");incoming.objects[0].artwork!.elements=[image]
    let bundle=try ArtworkTransferGraph.capture(project:incoming,objectID:owner.id,ids:[image.id],readAsset:{_,_ in Data("not an image".utf8)}),file=store.repository.root.appendingPathComponent("malformed.formart");try ArtworkTransferFile.writeNew(bundle.encoded(),to:file)
    let original=Data("Unchanged foreign file".utf8);try original.write(to:assets.appendingPathComponent("prior.png"));let names=try FileManager.default.contentsOfDirectory(atPath:assets.path)
    canvas.beginText(element);let editor=try XCTUnwrap(window.firstResponder as? CanvasTextView);editor.textStorage!.replaceCharacters(in:.init(location:0,length:editor.string.utf16.count),with:"Keep this raw draft");editor.setSelectedRange(.init(location:2,length:3));let caret=editor.selectedRange()
    XCTAssertThrowsError(try store.engine.call("form_edit_artwork",arguments:["command":"transfer_import","object_id":before.objects[0].id.uuidString,"transfer_path":file.path]))
    XCTAssertEqual(store.project,before);XCTAssertTrue(window.firstResponder === editor);XCTAssertEqual(editor.string,"Keep this raw draft");XCTAssertEqual(editor.selectedRange(),caret);XCTAssertTrue(store.engine.undoStack.isEmpty);XCTAssertEqual(try Data(contentsOf:assets.appendingPathComponent("prior.png")),original);XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:assets.path),names)
  }

  func testCutCannotPublishOrDeleteALockedArtworkOwner()throws {
    let(store,window,canvas,board)=try fixture(),session=store.artworkSession
    var project=store.project!;project.objects[0].locked=true;store.engine.project=project
    board.clearContents();board.setString("Previous private clipboard",forType:.string)
    var publications=0;session.transferPasteboardPublisher={_,_,_ in publications+=1;return true}
    try key("x",7,action:#selector(VectorCanvasView.cut(_:)),window:window,canvas:canvas)
    XCTAssertEqual(store.project,project);XCTAssertTrue(store.engine.undoStack.isEmpty);XCTAssertEqual(publications,0)
    XCTAssertEqual(board.string(forType:.string),"Previous private clipboard");XCTAssertNotNil(session.lastTransferError)
  }

}

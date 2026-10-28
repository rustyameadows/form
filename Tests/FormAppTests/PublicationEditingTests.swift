import AppKit
import CoreText
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class PublicationEditingTests:XCTestCase {
  private func fixture(grid:Bool=false,caseLists:Bool=false) throws -> (NSWindow,StudioStore,VectorCanvasView,UUID,[StoryFrameID]) {
    _=NSApplication.shared
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:800),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),repo=try ProjectRepository(root:root)
    var p=Project(name:"Shared native story"),frames:[StoryFrameID]=[]
    for page in 0..<2 {
      var object=try p.makeObject(recipeID:"artboard",name:"Page \(page+1)",parameters:["width":160,"depth":210]),elements:[ArtworkElement]=[]
      for column in 0..<2 {
        let words=page==0 && column==0 ? (caseLists ? "istanbul\n":"")+(1...25).map{"Step \($0): Inspect the materials and record careful observations before assembly."}.joined(separator:"\n"):""
        var e=ArtworkElement(kind:"text",x:14+Double(column)*70,y:28,width:62,height:65,text:words,color:"#24353D",fontSize:13)
        e.typography=Typography();e.typography!.fontName="Georgia";e.typography!.kerningMode="metrics";e.typography!.alignToBaselineGrid=grid
        e.typography!.caseTreatment=caseLists ? "uppercase":"original"
        if caseLists,!words.isEmpty {try ParagraphLists.edit(&e.listItems,text:words,marker:.decimal)}
        frames.append(.init(objectID:object.id,elementID:e.id));elements.append(e)
      }
      object.artwork=Artwork(background:"#F5F1E6",elements:elements,bleed:0);p.objects.append(object)
    }
    let document=try PublicationCommands.createPublication(in:&p,name:"Native booklet",pages:p.objects.map(\.id),language:caseLists ? "tr":"en")
    let story=try PublicationCommands.createStory(in:&p,frames:frames,publicationID:document)
    if grid {var doc=p.publications![0];doc.baselineGrid = .init(spacing:18,origin:6);try PublicationCommands.setPublication(in:&p,document:doc)}
    try repo.save(p)
    let store=StudioStore(repository:repo,seedLibrary:false);try store.engine.open(p.id)
    let canvas=VectorCanvasView(frame:window.contentView!.bounds),session=store.artworkSession
    canvas.session=session;session.canvas=canvas;session.objectID=frames[0].objectID;session.choose([frames[0].elementID]);window.contentView=canvas;canvas.synchronize()
    return(window,store,canvas,story,frames)
  }
  private func close(_ window:NSWindow,_ store:StudioStore,_ canvas:VectorCanvasView) {
    canvas.finishText();window.close();try? FileManager.default.removeItem(at:store.repository.root)
  }
  func testFourNativeViewsShareOneStoryAndEnterFinishAddsNoHistory() throws {
    let(window,store,canvas,id,frames)=try fixture(grid:true);defer{close(window,store,canvas)}
    let baseline=store.project
    canvas.beginText(store.project!.objects[0].artwork!.elements[0])
    let editor=try XCTUnwrap(canvas.storyEditor)
    XCTAssertEqual(editor.views.count,4);XCTAssertEqual(editor.storyID,id)
    XCTAssertTrue(editor.views.allSatisfy{$0.textStorage === editor.composition.storage})
    XCTAssertTrue(editor.views.allSatisfy{$0.undoManager === editor.nativeUndo})
    XCTAssertTrue(store.artworkSession.editingText)
    let native=try XCTUnwrap(window.firstResponder as? CanvasTextView);native.didChangeText()
    editor.focus(frames[2]);(window.firstResponder as? CanvasTextView)?.didChangeText()
    canvas.finishText();XCTAssertEqual(store.project,baseline);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testEscapeFinishesLinkedTextAndReturnsDocumentUndoToCanvas() throws {
    let(window,store,canvas,_,frames)=try fixture();defer{close(window,store,canvas)}
    let baseline=store.project
    canvas.beginText(store.project!.objects[0].artwork!.elements[0])
    let editor=try XCTUnwrap(canvas.storyEditor)
    editor.focus(frames[1],range:NSRange(location:editor.composition.sourceRange(1).location,length:0))
    let text=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    text.insertText("ESCAPE / ",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertNotEqual(store.project,baseline)
    text.doCommand(by:#selector(NSResponder.cancelOperation(_:)))
    XCTAssertNil(canvas.storyEditor)
    XCTAssertFalse(store.artworkSession.editingText)
    XCTAssertTrue(window.firstResponder === canvas)
    XCTAssertTrue(editor.views.allSatisfy{$0.window == nil})
    store.engine.undo()
    XCTAssertEqual(store.project,baseline)
  }
  func testEditingSecondFrameReflowsSingleSourceWithNativeAndDocumentUndo() throws {
    let(window,store,canvas,id,frames)=try fixture();defer{close(window,store,canvas)}
    let baseline=store.project!,original=baseline.textStories![0].text
    canvas.beginText(store.project!.objects[0].artwork!.elements[0]);let editor=try XCTUnwrap(canvas.storyEditor)
    editor.nativeUndo.groupsByEvent=false
    let insertion=editor.composition.sourceRange(1).location
    editor.focus(frames[1],range:NSRange(location:insertion,length:0))
    let text=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    text.insertText("NATIVE EDIT / ",replacementRange:NSRange(location:NSNotFound,length:0))
    let edited=store.project!.textStories!.first{$0.id==id}!.text
    XCTAssertEqual(edited.components(separatedBy:"NATIVE EDIT / ").count-1,1)
    XCTAssertEqual(store.project!.objects,baseline.objects)
    editor.focus(frames[2]);editor.nativeUndo.undo()
    XCTAssertEqual(store.project!.textStories![0].text,original)
    editor.nativeUndo.redo();XCTAssertEqual(store.project!.textStories![0].text,edited)
    canvas.finishText();store.engine.undo();XCTAssertEqual(store.project,baseline)
  }
  func testSharedLocaleCaseListFormattingAndTypingKeepGlobalSourceAndItemIDs() throws {
    let(window,store,canvas,_,frames)=try fixture(grid:true,caseLists:true);defer{close(window,store,canvas)}
    let before=store.project!.textStories![0],identities=before.listItems!.map(\.id)
    canvas.beginText(store.project!.objects[0].artwork!.elements[0]);let editor=try XCTUnwrap(canvas.storyEditor)
    editor.nativeUndo.groupsByEvent=false
    XCTAssertTrue(editor.composition.storage.string.hasPrefix("İSTANBUL"))
    editor.focus(frames[2],range:NSRange(location:editor.composition.sourceRange(2).location,length:0))
    let text=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    text.insertText("i",replacementRange:NSRange(location:NSNotFound,length:0))
    let source=store.project!.textStories![0]
    XCTAssertEqual(source.text.utf16.count,before.text.utf16.count+1);XCTAssertTrue(source.text.hasPrefix("istanbul"))
    XCTAssertEqual(source.listItems!.map(\.id),identities)
    text.setSelectedRange(NSRange(location:0,length:8));_ = canvas.applyTextStyle{$0.tracking=0.5}
    XCTAssertEqual(store.project!.textStories![0].listItems!.map(\.id),identities)
    XCTAssertEqual(store.project!.textStories![0].text,source.text)
    XCTAssertEqual(store.project!.objects.flatMap{$0.artwork!.elements}.filter{$0.storyFrame != nil}.map(\.text),["","","",""])
  }
  func testEmptyStoryUsesItsOwnTypingLanguageFontAndSafeEmptyContainers() throws {
    let(window,store,canvas,id,_)=try fixture(grid:true);defer{close(window,store,canvas)}
    var p=store.project!,source=p.textStories![0].sourceElement
    source.text="";source.textRuns=nil;source.listItems=nil;source.typography!.caseTreatment="uppercase"
    try PublicationCommands.setSource(in:&p,storyID:id,source:source,language:"tr",replaceLanguage:true);store.engine.project=p
    canvas.synchronize();canvas.beginText(p.objects[0].artwork!.elements[0])
    let text=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    XCTAssertEqual(text.string,"");text.insertText("istanbul",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(text.string,"İSTANBUL");XCTAssertEqual(store.project!.textStories![0].text,"istanbul")
    XCTAssertEqual((text.attributedString().attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.fontName,"Georgia")
  }
  func testGridCanBeActivatedDuringNativeEditingWithoutMovingSourceOrLeavingStalePadding() throws {
    let(window,store,canvas,_,_)=try fixture();defer{close(window,store,canvas)}
    var document=store.project!.publications![0];document.baselineGrid = .init(spacing:18,origin:6)
    try store.engine.edit("Grid") {try PublicationCommands.setPublication(in:&$0,document:document)}
    canvas.synchronize();canvas.beginText(store.project!.objects[0].artwork!.elements[0])
    let editor=try XCTUnwrap(canvas.storyEditor),before=store.project!.textStories![0].text
    let text=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    text.setSelectedRange(NSRange(location:0,length:text.string.utf16.count))
    XCTAssertTrue(canvas.applyTextStyle{$0.alignToBaselineGrid=true})
    XCTAssertTrue(editor.composition.topOffsets.contains{$0>0.01})
    editor.composition.layout.ensureLayout(for:editor.composition.overflow)
    for index in editor.composition.containers.indices {
      let range=editor.composition.glyphRange(index)
      guard range.length>0 else{continue}
      let glyph=range.location,y=editor.composition.context.frames[index].pageY+editor.composition.topOffsets[index]+editor.composition.layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil).minY+editor.composition.layout.location(forGlyphAt:glyph).y
      XCTAssertEqual((y-6)/18,((y-6)/18).rounded(),accuracy:0.001)
    }
    XCTAssertEqual(store.project!.textStories![0].text,before)
    XCTAssertTrue(canvas.applyTextStyle{$0.alignToBaselineGrid=false})
    XCTAssertTrue(editor.composition.topOffsets.allSatisfy{$0==0})
  }
  func testRejectedAgentStoryEditAndAtomicBatchKeepNativeDraftResponderSelectionAndUndo() throws {
    let(window,store,canvas,id,_)=try fixture();defer{close(window,store,canvas)}
    canvas.beginText(store.project!.objects[0].artwork!.elements[0]);let editor=try XCTUnwrap(canvas.storyEditor)
    editor.nativeUndo.groupsByEvent=false
    let text=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    text.insertText("Native draft / ",replacementRange:NSRange(location:NSNotFound,length:0))
    let baseline=store.project,range=text.selectedRange(),undo=store.engine.undoStack
    XCTAssertThrowsError(try store.preflightPublicationHandoff("form_story",["command":"append","story_id":id.uuidString,"frames":[["object_id":UUID().uuidString,"element_id":UUID().uuidString]]]))
    XCTAssertThrowsError(try store.preflightPublicationHandoff("form_batch",["operations":[
      ["name":"form_story","arguments":["command":"edit","story_id":id.uuidString,"name":"Must roll back"]],
      ["name":"form_publication","arguments":["command":"settings","publication_id":UUID().uuidString,"name":"Missing"]]]]))
    XCTAssertTrue(window.firstResponder === text);XCTAssertTrue(canvas.storyEditor === editor)
    XCTAssertEqual(text.selectedRange(),range);XCTAssertEqual(store.project,baseline);XCTAssertEqual(store.engine.undoStack,undo)
    editor.nativeUndo.undo();XCTAssertFalse(store.project!.textStories![0].text.contains("Native draft / "))
  }
  func testClosedEditorInspectorEditsGlobalStoryAndFrameGeometryStaysBounded() throws {
    let(window,store,canvas,_,_)=try fixture();defer{close(window,store,canvas)}
    let geometry=store.project!.objects
    store.artworkSession.typeSize(17);store.artworkSession.typography{$0.tracking=0.7};store.artworkSession.textColor("#A55135")
    let source=store.project!.textStories![0].sourceElement
    XCTAssertEqual(source.fontSize,17);XCTAssertEqual(source.typography?.tracking,0.7);XCTAssertEqual(source.color,"#A55135")
    XCTAssertEqual(store.project!.objects,geometry);XCTAssertEqual(store.artworkSession.inspectedSize,17)
    XCTAssertEqual(store.artworkSession.inspectedTypography.tracking,0.7)
    let swatch=ArtworkSwatch(name:"Story ink",color:"#314D59")
    try store.engine.edit("Story palette") {p in
      p.swatches=[swatch]
      try SwatchCommands.assign(in:&p,objectID:store.artworkSession.objectID!,ids:store.artworkSession.selection,swatchID:swatch.id)
    }
    XCTAssertEqual(store.artworkSession.inspectedFillSwatchID,swatch.id)
  }

  func testArrowNavigationCrossesThePhysicalFrameBoundaryAndKeepsGlobalInsertion() throws {
    let(window,store,canvas,_,frames)=try fixture();defer{close(window,store,canvas)}
    canvas.beginText(store.project!.objects[0].artwork!.elements[0]);let editor=try XCTUnwrap(canvas.storyEditor)
    let boundary=NSMaxRange(editor.composition.displayRange(0))
    editor.focus(frames[0],range:NSRange(location:boundary-1,length:0))
    let first=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    first.moveRight(nil);(window.firstResponder as? CanvasTextView)?.moveRight(nil)
    let active=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    XCTAssertEqual(active.selectedRange().location,boundary+1)
    XCTAssertTrue(active.textContainer === editor.composition.containers[1])
    active.insertText("CROSS FRAME ",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual((store.project!.textStories![0].text as NSString).substring(with:NSRange(location:boundary+1,length:12)),"CROSS FRAME ")
  }
  func testMarkedInputIsNotPublishedOrInterruptedByAgentHandoffAndCommitsOnce() throws {
    let(window,store,canvas,id,frames)=try fixture();defer{close(window,store,canvas)}
    canvas.beginText(store.project!.objects[0].artwork!.elements[0]);let editor=try XCTUnwrap(canvas.storyEditor)
    let point=editor.composition.sourceRange(1).location
    editor.focus(frames[1],range:NSRange(location:point,length:0))
    let text=try XCTUnwrap(window.firstResponder as? CanvasTextView),before=store.project
    text.setMarkedText("に",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertTrue(text.hasMarkedText());XCTAssertEqual(store.project,before)
    XCTAssertThrowsError(try store.preflightPublicationHandoff("form_story",["command":"edit","story_id":id.uuidString,"name":"Do not interrupt composition"]))
    XCTAssertTrue(text.hasMarkedText());XCTAssertTrue(window.firstResponder === text)
    XCTAssertThrowsError(try store.publicationGraphicsCall("form_export_publication",["publication_id":store.project!.publications![0].id.uuidString]))
    XCTAssertTrue(text.hasMarkedText());XCTAssertTrue(window.firstResponder === text)
    text.insertText("日本語",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertFalse(text.hasMarkedText());XCTAssertEqual(store.project!.textStories![0].text.components(separatedBy:"日本語").count-1,1)
    XCTAssertEqual(store.project!.objects,before!.objects)
  }
  func testExactFontGlyphChoiceRoutesToTheSharedSourceAndSurvivesFrameEditingUndo() throws {
    let(window,store,canvas,id,frames)=try fixture();defer{close(window,store,canvas)}
    var source=store.project!.textStories![0].sourceElement
    source.text="Q "+source.text;source.typography!.fontName="HoeflerText-Regular"
    try store.engine.edit("Source font") {try PublicationCommands.setSource(in:&$0,storyID:id,source:source)}
    let font=TypographyEngine.font(source.typography!,size:source.fontSize)
    let glyph=try GlyphCatalog.glyph(fontName:font.fontName,id:Int(CTFontGetGlyphWithName(font as CTFont,"Q.alt" as CFString)))
    _ = try store.engine.call("form_edit_artwork",arguments:["object_id":frames[1].objectID.uuidString,"element_ids":[frames[1].elementID.uuidString],"command":"glyph","location":0,"length":1,"glyph":try jsonObject(glyph)])
    let choice=try XCTUnwrap(store.project!.textStories![0].glyphOverrides?.first)
    canvas.synchronize();canvas.beginText(store.project!.objects[0].artwork!.elements[0]);let editor=try XCTUnwrap(canvas.storyEditor)
    editor.nativeUndo.groupsByEvent=false;editor.focus(frames[1],range:NSRange(location:editor.composition.sourceRange(1).location,length:0))
    let text=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    text.insertText("A ",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(store.project!.textStories![0].glyphOverrides?.first,choice)
    editor.nativeUndo.undo();XCTAssertEqual(store.project!.textStories![0].glyphOverrides?.first,choice)
    XCTAssertEqual(TextCase.source(text.attributedString()).text.string,source.text)
  }

}

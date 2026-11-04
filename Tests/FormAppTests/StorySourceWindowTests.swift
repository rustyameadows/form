import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class StorySourceWindowTests:XCTestCase {
  @MainActor private final class Fixture {
    let root:URL,store:StudioStore,window:NSWindow,canvas:VectorCanvasView
    let storyID:UUID,frames:[StoryFrameID]
    var editor:PublicationEditingController {canvas.storyEditor!}
    var text:CanvasTextView {editor.sourceTextView!}
    init(ink:String="#000000",paper:String="#FFFFFF",wordCount:Int=180)throws {
      _=NSApplication.shared
      root=FileManager.default.temporaryDirectory.appendingPathComponent("story-source-window-"+UUID().uuidString)
      let repository=try ProjectRepository(root:root)
      var project=Project(name:"Mounted linked source"),references:[StoryFrameID]=[]
      for index in 0..<3 {
        var page=try project.makeObject(recipeID:"artboard",name:"Reader page \(index+1)",parameters:["width":100,"depth":140])
        var element=ArtworkElement(kind:"text",x:10,y:15,width:80,height:30,
          text:index==0 ? (0..<wordCount).map{"word\($0)"}.joined(separator:" "):"",color:ink,fontSize:14)
        var type=Typography();type.fontName="Georgia";type.leading=17;element.typography=type
        page.artwork = .init(background:paper,elements:[element],bleed:0)
        references.append(.init(objectID:page.id,elementID:element.id));project.objects.append(page)
      }
      frames=references
      let publication=try PublicationCommands.createPublication(in:&project,name:"Reader source",pages:project.objects.map(\.id))
      storyID=try PublicationCommands.createStory(in:&project,frames:references,publicationID:publication)
      try repository.save(project)
      store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(project.id)
      store.showingHome=false;store.mode = .artwork
      window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1000,height:760),styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false
      canvas=VectorCanvasView(frame:window.contentView!.bounds);canvas.session=store.artworkSession
      store.artworkSession.canvas=canvas;window.contentView=canvas
      store.artworkSession.activate(frames[0].objectID);store.artworkSession.choose([frames[0].elementID]);canvas.synchronize()
    }
    func open(frame index:Int=0,range:NSRange?=nil)throws {
      let frame=frames[index]
      store.artworkSession.activate(frame.objectID);store.artworkSession.choose([frame.elementID]);canvas.synchronize()
      canvas.beginText(try XCTUnwrap(store.project?.storyFrame(frame)?.element))
      editor.nativeUndo.groupsByEvent=false
      let selected=range ?? .init(location:editor.composition.sourceRange(index).location,length:0)
      editor.focus(frame,range:selected)
      editor.showSource()
      text.window?.setFrameOrigin(.init(x:-10000,y:-10000));layout()
    }
    func layout(){text.window?.contentView?.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.025))}
    func source()throws->TextStory {try XCTUnwrap(store.project?.textStories?.first{$0.id==storyID})}
    func pagePNG(_ index:Int)throws->Data {
      let project=try XCTUnwrap(store.project),page=try XCTUnwrap(project.objects.first{$0.id==frames[index].objectID})
      let art=try XCTUnwrap(project.surfaceArtwork(page))
      let image=ArtworkRenderer.image(art,width:100,height:140,assets:store.artworkSession.assets,pixelsPerMM:2)
      return try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))).representation(using:.png,properties:[:]))
    }
    func close(){canvas.finishText();window.contentView=nil;window.close();try? FileManager.default.removeItem(at:root)}
  }
  private func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
  private func button(_ identifier:String,in window:NSWindow)throws->NSButton {
    try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap{$0 as? NSButton}.first{$0.accessibilityIdentifier()==identifier})
  }
  private func press(_ button:NSButton)throws {
    XCTAssertTrue(button.isEnabled)
    let point=try XCTUnwrap(button.superview).convert(.init(x:button.bounds.midX,y:button.bounds.midY),from:button)
    XCTAssertTrue(button.hitTest(point) === button)
    XCTAssertTrue(button.accessibilityPerformPress())
  }
  private func assertNativeSource(_ actual:Project?,equals expected:Project,file:StaticString=#filePath,line:UInt=#line) {
    var value=actual;value?.history=expected.history;value?.updatedAt=expected.updatedAt
    value?.schemaVersion=expected.schemaVersion // Like endInteraction, remove only the transient schema stamp.
    XCTAssertEqual(value,expected,file:file,line:line)
  }
  func testMountedAquaWindowUsesTemporaryReadableInkAndRetainsBothPrintedInkColors()throws {
    for (ink,paper) in [("#FFFFFF","#000000"),("#000000","#FFFFFF")] {
      let f=try Fixture(ink:ink,paper:paper,wordCount:30);defer{f.close()}
      let baseline=try XCTUnwrap(f.store.project),before=try f.pagePNG(0)
      try f.open()
      let source=f.text,window=try XCTUnwrap(source.window),layout=try XCTUnwrap(source.layoutManager as? PublicationLayoutManager)
      XCTAssertEqual(window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]),.aqua)
      XCTAssertNotNil(layout.displayInkColor)
      XCTAssertNotNil(layout.temporaryAttribute(.foregroundColor,atCharacterIndex:0,effectiveRange:nil))
      XCTAssertNil(f.editor.composition.layout.displayInkColor,"The page compositor must keep authored printing ink.")
      let native=try XCTUnwrap(source.textStorage?.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor)
      XCTAssertEqual(FormColor.hex(native),ink)
      source.setSelectedRange(.init(location:0,length:0));source.scrollRangeToVisible(source.selectedRange());f.layout()
      let rect=NSRect(x:0,y:0,width:min(600,source.bounds.width),height:100)
      let bitmap=try XCTUnwrap(source.bitmapImageRepForCachingDisplay(in:rect));source.cacheDisplay(in:rect,to:bitmap)
      var dark=0,light=0
      for y in stride(from:0,to:bitmap.pixelsHigh,by:2){for x in stride(from:0,to:bitmap.pixelsWide,by:2){
        guard let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB) else{continue}
        if c.redComponent<0.35,c.greenComponent<0.35,c.blueComponent<0.35 {dark+=1}
        if c.redComponent>0.9,c.greenComponent>0.9,c.blueComponent>0.9 {light+=1}
      }}
      XCTAssertGreaterThan(dark,20,"Actual source-window text must be readable for \(ink) print ink.")
      XCTAssertGreaterThan(light,1000)
      XCTAssertEqual(try f.pagePNG(0),before);XCTAssertEqual(f.store.project,baseline);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    }
  }
  func testOpeningFromMiddleFrameRetainsGlobalSelectionAndLogicalPageWithoutHistory()throws {
    let f=try Fixture();defer{f.close()}
    let baseline=try XCTUnwrap(f.store.project)
    f.store.artworkSession.activate(f.frames[1].objectID);f.store.artworkSession.choose([f.frames[1].elementID]);f.canvas.synchronize()
    f.canvas.beginText(try XCTUnwrap(f.store.project?.storyFrame(f.frames[1])?.element))
    let range=f.editor.composition.sourceRange(1)
    XCTAssertGreaterThan(range.location,0);XCTAssertGreaterThan(range.length,3)
    let selected=NSRange(location:range.location+1,length:3)
    f.editor.focus(f.frames[1],range:selected);f.editor.showSource();f.layout()
    XCTAssertEqual(TextCase.source(f.text.attributedString()).sourceRange(f.text.selectedRange()),selected)
    XCTAssertEqual(f.store.artworkSession.objectID,f.frames[1].objectID)
    XCTAssertEqual(f.editor.sourceSelectedFrame,f.frames[1])
    XCTAssertEqual(f.editor.sourceFrameOptions.count,3);XCTAssertEqual(f.editor.sourceWordCount,180)
    XCTAssertGreaterThan(f.editor.sourceOverflowCount,0)
    XCTAssertEqual(f.store.project,baseline);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }
  func testNativeWindowResizeAndZoomReuseOneScrollViewWithoutChangingPhysicalLayout()throws {
    let f=try Fixture();defer{f.close()};try f.open()
    let baseline=try XCTUnwrap(f.store.project),storage=f.editor.composition.storage
    let scroll=try XCTUnwrap(f.editor.sourceScrollView),window=try XCTUnwrap(f.text.window)
    let container=try XCTUnwrap(f.text.textContainer),oldWidth=container.size.width,physical=f.editor.composition.context.frames
    window.setContentSize(.init(width:1050,height:720));f.layout()
    XCTAssertGreaterThan(container.size.width,oldWidth)
    XCTAssertTrue(f.editor.sourceScrollView === scroll);XCTAssertTrue(scroll.documentView === f.text)
    f.editor.setSourceZoom(1.5);f.layout()
    XCTAssertEqual(scroll.magnification,1.5,accuracy:0.001);XCTAssertEqual(f.editor.sourceZoom,1.5)
    XCTAssertTrue(f.text.textStorage === storage);XCTAssertEqual(f.editor.composition.context.frames,physical)
    XCTAssertEqual(f.store.project,baseline);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }
  func testMountedShowOnCanvasFitsChosenMiddlePageBetweenRealViewportOcclusionsWithoutChangingSource()throws {
    let f=try Fixture();defer{f.close()}
    let scroll=ArtworkScrollView(frame:f.window.contentView!.bounds)
    scroll.allowsMagnification=true;scroll.minMagnification=0.08;scroll.maxMagnification=24
    f.window.contentView=nil;scroll.documentView=f.canvas;f.window.contentView=scroll
    // These are the same real left/right card and bottom toolbar reservations
    // consumed by the ordinary floating Canvas workspace.
    f.canvas.fittingInsets = .init(top:16,left:266,bottom:72,right:318)
    f.window.contentView?.layoutSubtreeIfNeeded();scroll.tile();f.canvas.synchronize()
    try f.open()
    let editor=f.editor,text=f.text,storage=editor.composition.storage
    editor.navigateSourceFrame(f.frames[1])
    f.canvas.setZoom(4)
    let target=try XCTUnwrap(f.store.artworkSession.frames.first{$0.id==f.frames[1].objectID})
    XCTAssertFalse(f.canvas.unobscuredVisibleCanvasRect.contains(target.rect),"At the retained close-up zoom, scrolling alone cannot fit this physical page between the panels.")
    let baseline=try XCTUnwrap(f.store.project),undo=f.store.engine.undoStack.count
    let caret=TextCase.source(text.attributedString()).sourceRange(text.selectedRange()),sourceZoom=editor.sourceZoom
    let sourceWindow=try XCTUnwrap(text.window)
    try press(button("story-source-show-canvas",in:sourceWindow))
    f.window.contentView?.layoutSubtreeIfNeeded();scroll.tile()
    let available=f.canvas.unobscuredVisibleCanvasRect.insetBy(dx:-0.001,dy:-0.001)
    XCTAssertTrue(available.contains(target.rect),"Chosen page \(target.rect) must fit within unobscured Canvas bounds \(available), not behind the floating inspector.")
    XCTAssertLessThan(f.canvas.zoom,4)
    XCTAssertEqual(f.store.artworkSession.objectID,f.frames[1].objectID)
    XCTAssertEqual(f.store.artworkSession.selection,[f.frames[1].elementID])
    XCTAssertTrue(f.canvas.storyEditor === editor);XCTAssertTrue(text.textStorage === storage)
    XCTAssertEqual(TextCase.source(text.attributedString()).sourceRange(text.selectedRange()),caret)
    XCTAssertEqual(editor.sourceZoom,sourceZoom)
    XCTAssertEqual(f.store.project,baseline);XCTAssertEqual(f.store.engine.undoStack.count,undo)
  }
  func testMountedFormattingButtonAndNativeKeyboardUseOneSharedSourceUndo()throws {
    let f=try Fixture();defer{f.close()};try f.open()
    let baseline=try XCTUnwrap(f.store.project),window=try XCTUnwrap(f.text.window)
    let selection=NSRange(location:0,length:5);f.text.setSelectedRange(selection);f.layout()
    try press(button("story-source-format-bold",in:window))
    XCTAssertTrue(f.editor.formatState(.bold).isOn)
    for (key,keyCode) in [("i",UInt16(34)),("u",UInt16(32))] {
      let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,
        windowNumber:window.windowNumber,context:nil,characters:key,charactersIgnoringModifiers:key,isARepeat:false,keyCode:keyCode))
      XCTAssertTrue(f.text.performKeyEquivalent(with:event))
    }
    XCTAssertTrue(f.editor.formatState(.italic).isOn);XCTAssertTrue(f.editor.formatState(.underline).isOn)
    XCTAssertEqual(f.text.selectedRange(),selection)
    XCTAssertTrue(f.editor.views.allSatisfy{$0.textStorage === f.editor.composition.storage})
    XCTAssertEqual(try f.source().text,baseline.textStories![0].text);XCTAssertEqual(f.store.project?.objects,baseline.objects)
    for _ in 0..<3 {f.editor.nativeUndo.undo()}
    assertNativeSource(f.store.project,equals:baseline)
    for _ in 0..<3 {f.editor.nativeUndo.redo()}
    f.canvas.finishText();f.store.engine.undo();XCTAssertEqual(f.store.project,baseline)
  }
  func testActualSourceEditReflowsLinkedPagePixelsAndHasNativeAndDocumentUndo()throws {
    let f=try Fixture();defer{f.close()};try f.open()
    let baseline=try XCTUnwrap(f.store.project),before=try f.pagePNG(1),editor=f.editor
    f.text.setSelectedRange(.init(location:0,length:0))
    f.text.insertText("EXPLICIT NATIVE SOURCE CHANGE ",replacementRange:.init(location:NSNotFound,length:0))
    XCTAssertTrue(try f.source().text.hasPrefix("EXPLICIT NATIVE SOURCE CHANGE "))
    XCTAssertTrue(editor.views.allSatisfy{$0.textStorage === editor.composition.storage})
    XCTAssertNotEqual(try f.pagePNG(1),before,"The untouched later page must render its newly flowed portion of the same source.")
    XCTAssertEqual(f.store.project?.objects,baseline.objects,"Bound frames remain source references, never copied words.")
    editor.nativeUndo.undo();assertNativeSource(f.store.project,equals:baseline);XCTAssertEqual(try f.pagePNG(1),before)
    editor.nativeUndo.redo();let edited=try XCTUnwrap(f.store.project)
    f.canvas.finishText();try f.store.engine.flush()
    XCTAssertEqual(try f.store.repository.load(edited.id).textStories,edited.textStories)
    f.store.engine.undo();XCTAssertEqual(f.store.project,baseline)
  }
  func testAnnotationsAreNonprintingMetadataWithNativeUndoAndGlobalPublicContext()throws {
    let f=try Fixture();defer{f.close()};try f.open()
    let baseline=try XCTUnwrap(f.store.project),before=try f.pagePNG(0)
    let range=(try f.source().text as NSString).range(of:"word10")
    f.text.setSelectedRange(range)
    XCTAssertTrue(f.editor.saveSourceAnnotation(id:nil,kind:.note,body:"Check this source wording."))
    let note=try XCTUnwrap(f.editor.sourceNotes.first)
    XCTAssertEqual(note.location,range.location);XCTAssertEqual(note.length,range.length)
    XCTAssertTrue(f.editor.saveSourceAnnotation(id:note.id,kind:.reference,body:"Literal reference text; no URL request."))
    f.editor.selectSourceAnnotation(note.id)
    XCTAssertEqual(f.text.selectedRange(),range)
    let context=try XCTUnwrap(f.store.engine.call("form_get_context") as? [String:Any])
    let canvas=try XCTUnwrap(context["canvas"] as? [String:Any]),selection=try XCTUnwrap(canvas["text_selection_utf16"] as? [String:Int])
    XCTAssertEqual(selection["location"],range.location);XCTAssertEqual(selection["length"],range.length)
    XCTAssertEqual(canvas["text_editing"] as? Bool,true)
    XCTAssertEqual(try f.pagePNG(0),before,"Editorial metadata and temporary highlights must never enter printed art.")
    f.editor.removeSourceAnnotation(note.id);XCTAssertTrue(f.editor.sourceNotes.isEmpty)
    for _ in 0..<3 {f.editor.nativeUndo.undo()}
    assertNativeSource(f.store.project,equals:baseline)
    for _ in 0..<3 {f.editor.nativeUndo.redo()}
    XCTAssertTrue(f.editor.sourceNotes.isEmpty);XCTAssertEqual(try f.source().text,baseline.textStories![0].text)
    f.canvas.finishText();XCTAssertEqual(f.store.project,baseline)
  }
  func testPerformCloseCommitsMarkedInputEndsInteractionAndReopensWithoutExtraGalley()throws {
    let f=try Fixture();defer{f.close()};try f.open()
    let baseline=try XCTUnwrap(f.store.project),editor=f.editor,text=f.text,storage=editor.composition.storage
    let sourceWindow=try XCTUnwrap(text.window)
    XCTAssertEqual(storage.layoutManagers.count,2)
    text.setSelectedRange(.init(location:0,length:0))
    editor.nativeUndo.beginUndoGrouping()
    text.setMarkedText("日本語",selectedRange:.init(location:3,length:0),replacementRange:.init(location:0,length:0))
    XCTAssertTrue(text.hasMarkedText());XCTAssertEqual(f.store.project,baseline)
    sourceWindow.performClose(nil)
    if editor.nativeUndo.groupingLevel>0 {editor.nativeUndo.endUndoGrouping()}
    XCTAssertFalse(sourceWindow.isVisible);XCTAssertNil(f.canvas.storyEditor);XCTAssertFalse(f.store.artworkSession.editingText)
    XCTAssertNil(editor.sourceTextView);XCTAssertNil(editor.sourceScrollView);XCTAssertNil(text.sourceFormattingAction)
    XCTAssertEqual(storage.layoutManagers.count,1);XCTAssertFalse(editor.nativeUndo.canUndo)
    XCTAssertTrue(try f.source().text.hasPrefix("日本語"))
    let committed=try XCTUnwrap(f.store.project)
    try f.open()
    XCTAssertFalse(f.editor === editor);XCTAssertEqual(f.editor.composition.storage.layoutManagers.count,2)
    XCTAssertTrue(f.editor.views.allSatisfy{$0.textStorage === f.editor.composition.storage})
    f.text.window?.performClose(nil)
    XCTAssertEqual(f.store.project,committed)
    f.store.engine.undo();XCTAssertEqual(f.store.project,baseline)
  }
  func testMarkedSourceUpdatesKeepGlobalUTF16ContextCurrentWithoutPublishingUntilCommitAndUndoExactly()throws {
    let f=try Fixture();defer{f.close()};try f.open(frame:1)
    let editor=f.editor,text=f.text,baseline=try XCTUnwrap(f.store.project),undo=f.store.engine.undoStack
    let frameRange=editor.composition.sourceRange(1),point=frameRange.location+1
    XCTAssertGreaterThan(frameRange.location,0);XCTAssertGreaterThan(frameRange.length,1)
    text.setSelectedRange(.init(location:point,length:0))
    func assertContext(_ offset:Int)throws {
      let context=try XCTUnwrap(f.store.engine.call("form_get_context") as? [String:Any])
      let canvas=try XCTUnwrap(context["canvas"] as? [String:Any])
      let reported=try XCTUnwrap(canvas["text_selection_utf16"] as? [String:Int])
      let actual=TextCase.source(text.attributedString()).sourceRange(text.selectedRange())
      XCTAssertEqual(actual,NSRange(location:point+offset,length:0))
      XCTAssertEqual(reported,["location":actual.location,"length":actual.length])
      XCTAssertEqual(f.store.artworkSession.characterRange,actual)
      XCTAssertEqual(canvas["text_editing"] as? Bool,true)
      XCTAssertTrue(text.hasMarkedText());XCTAssertTrue(text.window?.firstResponder === text)
      XCTAssertEqual(f.store.project,baseline);XCTAssertEqual(f.store.engine.undoStack,undo)
    }
    // Represent one native input event explicitly because this fixture disables
    // automatic event Undo grouping to make the final composition one action.
    editor.nativeUndo.beginUndoGrouping()
    defer{if editor.nativeUndo.groupingLevel>0 {editor.nativeUndo.endUndoGrouping()}}
    text.setMarkedText("に",selectedRange:.init(location:1,length:0),replacementRange:.init(location:point,length:0))
    text.didChangeText()
    try assertContext(1)
    let committed="日本語🧵"
    text.setMarkedText(committed,selectedRange:.init(location:committed.utf16.count,length:0),replacementRange:.init(location:NSNotFound,length:0))
    text.didChangeText()
    try assertContext(committed.utf16.count)
    XCTAssertEqual(text.markedRange(),NSRange(location:point,length:committed.utf16.count))
    text.insertText(committed,replacementRange:.init(location:NSNotFound,length:0))
    editor.nativeUndo.endUndoGrouping()
    XCTAssertFalse(text.hasMarkedText())
    let expected=(baseline.textStories![0].text as NSString).replacingCharacters(in:.init(location:point,length:0),with:committed)
    XCTAssertEqual(Array(try f.source().text.utf16),Array(expected.utf16))
    XCTAssertEqual(f.store.project?.objects,baseline.objects)
    let edited=try XCTUnwrap(f.store.project)
    editor.nativeUndo.undo();assertNativeSource(f.store.project,equals:baseline)
    editor.nativeUndo.redo();assertNativeSource(f.store.project,equals:edited)
    f.canvas.finishText();f.store.engine.undo();XCTAssertEqual(f.store.project,baseline)
  }
}

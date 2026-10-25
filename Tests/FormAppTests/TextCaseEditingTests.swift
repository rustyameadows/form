import AppKit
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class TextCaseEditingTests:XCTestCase {
  private func editor()->(NSWindow,CanvasTextView) {
    _=NSApplication.shared
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:300),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let view=CanvasTextView(frame:window.contentView!.bounds)
    view.isRichText=true;view.allowsUndo=true;window.contentView=view
    window.makeFirstResponder(view)
    return(window,view)
  }
  func testTypedLowercaseRendersUppercaseWithOriginalSourceAndNativeUndoRedo() {
    let (window,view)=editor();defer{window.close()}
    var type=Typography();type.caseTreatment="uppercase"
    view.typingAttributes=TypographyEngine.attributes(type,size:24,color:"#222222",millimeters:false)
    view.insertText("Straße",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(view.string,"STRASSE");XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"Straße")
    view.undoManager?.undo();XCTAssertEqual(view.string,"")
    view.undoManager?.redo();XCTAssertEqual(view.string,"STRASSE")
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"Straße")
  }
  func testInsertNextToExpandedCharacterDoesNotInheritItsSourceMarker() {
    let (window,view)=editor();defer{window.close()}
    var e=ArtworkElement(kind:"text",x:0,y:0,width:100,height:50,text:"ß",color:"#222222",fontSize:24)
    var type=Typography();type.caseTreatment="uppercase";e.typography=type
    view.textStorage?.setAttributedString(TypographyEngine.attributed(e,preservingSource:true));view.setSelectedRange(NSRange(location:2,length:0))
    view.insertText("s",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(view.string,"SSS");XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"ßs")
    view.undoManager?.undo();XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"ß")
  }
  func testFormattingCaseHasOneNativeUndoAndRestoresTheOriginalLetters() {
    let (window,view)=editor();defer{window.close()}
    var type=Typography()
    view.textStorage?.setAttributedString(NSAttributedString(string:"Straße",attributes:TypographyEngine.attributes(type,size:24,color:"#222222",millimeters:false)))
    view.undoManager?.beginUndoGrouping()
    type.caseTreatment="uppercase"
    let range=NSRange(location:0,length:6)
    XCTAssertTrue(view.shouldChangeText(in:range,replacementString:nil))
    view.textStorage?.setAttributes(TypographyEngine.attributes(type,size:24,color:"#222222",millimeters:false),range:range)
    view.didChangeText();view.undoManager?.endUndoGrouping()
    XCTAssertEqual(view.string,"STRASSE");XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"Straße")
    view.undoManager?.undo();XCTAssertEqual(view.string,"Straße")
    view.undoManager?.redo();XCTAssertEqual(view.string,"STRASSE")
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"Straße")
  }
  func testInsertAtBeginningAndReplaceWholeCaseTextRetainsEachNewSource() {
    let (window,view)=editor();defer{window.close()}
    var e=ArtworkElement(kind:"text",x:0,y:0,width:100,height:50,text:"Straße",color:"#222222",fontSize:24)
    var type=Typography();type.caseTreatment="uppercase";e.typography=type
    view.textStorage?.setAttributedString(TypographyEngine.attributed(e,preservingSource:true));view.setSelectedRange(NSRange(location:0,length:0))
    view.setSelectedRange(NSRange(location:view.string.utf16.count,length:0))
    view.insertText("strasse",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"Straßestrasse")
    view.undoManager?.undo()
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"Straße")
    view.setSelectedRange(NSRange(location:0,length:0))
    view.insertText("a long introduction ",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"a long introduction Straße")
    view.setSelectedRange(NSRange(location:0,length:view.string.utf16.count))
    view.insertText("İstanbul",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"İstanbul")
  }
  func testMarkedCompositionRemainsUntouchedUntilNativeCommit() {
    let (window,view)=editor();defer{window.close()}
    var type=Typography();type.caseTreatment="uppercase"
    view.typingAttributes=TypographyEngine.attributes(type,size:24,color:"#222222",millimeters:false)
    view.setMarkedText("straße",selectedRange:NSRange(location:6,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertTrue(view.hasMarkedText());XCTAssertEqual(view.string,"straße")
    view.insertText("Straße",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertFalse(view.hasMarkedText());XCTAssertEqual(view.string,"STRASSE")
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"Straße")
  }
  func testCaretArrowReleaseKeepsDocumentInteractionAndCancelledHistory() throws {
    let (window,_)=editor();defer{window.close()}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let repo=try ProjectRepository(root:root)
    var project=Project(name:"Case interaction"),object=try Project(name:"Object").makeObject(recipeID:"artboard")
    var e=ArtworkElement(kind:"text",x:10,y:10,width:100,height:30,text:"Straße",color:"#222222",fontSize:24)
    var type=Typography();type.caseTreatment="uppercase";e.typography=type
    object.artwork=Artwork(elements:[e]);project.objects=[object];try repo.save(project)
    let store=StudioStore(repository:repo,seedLibrary:false);try store.engine.open(project.id)
    let baseline=store.project
    let canvas=VectorCanvasView(frame:window.contentView!.bounds),session=store.artworkSession
    canvas.session=session;session.canvas=canvas;session.objectID=object.id;session.choose([e.id]);window.contentView=canvas
    canvas.synchronize();canvas.beginText(e)
    let text=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyUp,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:124))
    canvas.keyUp(with:event)
    text.setSelectedRange(NSRange(location:text.string.utf16.count,length:0))
    text.insertText("x",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(store.project?.objects[0].artwork?.elements[0].text,"Straßex")
    text.undoManager?.undo();canvas.finishText()
    XCTAssertEqual(store.project,baseline);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testGrowingTextKeepsNativeLayoutPastItsStartingFrame() {
    let (window,view)=editor();defer{window.close()}
    let startingHeight=view.frame.height
    view.isVerticallyResizable=true
    var type=Typography();type.caseTreatment="uppercase"
    view.typingAttributes=TypographyEngine.attributes(type,size:24,color:"#222222",millimeters:false)
    let content=Array(repeating:"line",count:30).joined(separator:"\n")
    view.insertText(content,replacementRange:NSRange(location:NSNotFound,length:0))
    view.layoutManager!.ensureLayout(for:view.textContainer!)
    XCTAssertGreaterThan(view.layoutManager!.usedRect(for:view.textContainer!).height,startingHeight)
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,content)
  }
  func testMarkedReplacementAfterAnExpansionKeepsUntouchedSourceAndCommittedCase() {
    let (window,view)=editor();defer{window.close()}
    var e=ArtworkElement(kind:"text",x:0,y:0,width:100,height:50,text:"Straße ORIGINAL",color:"#222222",fontSize:24)
    var type=Typography();type.caseTreatment="uppercase";e.typography=type
    view.textStorage?.setAttributedString(TypographyEngine.attributed(e,preservingSource:true))
    view.setSelectedRange(NSRange(location:8,length:8))
    view.setMarkedText("straße",selectedRange:NSRange(location:6,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
    view.setMarkedText("strasse",selectedRange:NSRange(location:7,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
    view.insertText("straße",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(view.string,"STRASSE STRASSE")
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"Straße straße")
  }
}

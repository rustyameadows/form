import AppKit
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class ParagraphListEditingTests:XCTestCase {
  private func fixture(_ value:String="First")->(NSWindow,CanvasTextView,ArtworkElement) {
    _=NSApplication.shared
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:350),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let view=CanvasTextView(frame:window.contentView!.bounds);window.contentView=view;window.makeFirstResponder(view)
    view.isRichText=true;view.allowsUndo=true
    view.undoManager?.groupsByEvent=false
    var e=ArtworkElement(kind:"text",x:0,y:0,width:100,height:70,text:value,color:"#24353D",fontSize:20)
    e.typography=Typography();e.typography!.fontName="Georgia"
    view.textStorage?.setAttributedString(TypographyEngine.attributed(e,preservingSource:true))
    view.setSelectedRange(NSRange(location:0,length:view.string.utf16.count))
    return(window,view,e)
  }
  private func items(_ view:CanvasTextView)->[ParagraphListItem] {
    PublicationLists.items(from:TextCase.source(view.attributedString()).text,trailingAttributes:view.typingAttributes) ?? []
  }
  func testNativeReturnCreatesStableItemsAndEmptyReturnExitsWithUndoRedo() throws {
    let (window,view,_)=fixture();defer{window.close()}
    try view.applyParagraphList(["marker":"decimal"])
    let first=try XCTUnwrap(items(view).first)
    view.setSelectedRange(NSRange(location:view.string.utf16.count,length:0))
    view.insertNewline(nil)
    XCTAssertEqual(view.string,"First\n");XCTAssertEqual(items(view).count,2)
    let next=try XCTUnwrap(items(view).last);XCTAssertEqual(items(view).last?.id,next.id);XCTAssertNotEqual(first.id,next.id)
    view.insertText("Second",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(items(view).count,2);XCTAssertEqual(items(view).last?.id,next.id)
    view.insertNewline(nil);XCTAssertEqual(items(view).count,3)
    let before=view.string
    view.insertNewline(nil)
    XCTAssertEqual(view.string,before);XCTAssertEqual(items(view).count,2)
    view.undoManager?.undo();XCTAssertEqual(items(view).count,3)
    view.undoManager?.redo();XCTAssertEqual(items(view).count,2)
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"First\nSecond\n")
  }
  func testTabAndShiftTabChangeListNestingWithoutSourceCharactersAndShareNativeUndo() throws {
    let (window,view,_)=fixture("First\nSecond");defer{window.close()}
    try view.applyParagraphList(["marker":"bullet"])
    view.setSelectedRange(NSRange(location:6,length:3))
    let identity=items(view)[1].id
    view.insertTab(nil);XCTAssertEqual(items(view)[1].level,1);XCTAssertEqual(items(view)[1].id,identity)
    XCTAssertEqual(view.string,"First\nSecond")
    view.insertBacktab(nil);XCTAssertEqual(items(view)[1].level,0)
    view.undoManager?.undo();XCTAssertEqual(items(view)[1].level,1)
  }
  func testCaseExpandedParagraphSelectionKeepsSourceWordsAndNativeListUndo() throws {
    let (window,view,original)=fixture("straße\nNext");defer{window.close()}
    var e=original;e.typography!.caseTreatment="uppercase"
    view.textStorage?.setAttributedString(TypographyEngine.attributed(e,preservingSource:true))
    view.setSelectedRange(NSRange(location:0,length:7))
    try view.applyParagraphList(["marker":"decimal"])
    XCTAssertEqual(view.string,"STRASSE\nNEXT");XCTAssertEqual(TextCase.source(view.attributedString()).text.string,e.text)
    XCTAssertEqual(items(view).count,1);XCTAssertEqual(items(view)[0].location,0)
    view.undoManager?.undo();XCTAssertTrue(items(view).isEmpty)
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,e.text)
    view.undoManager?.redo();XCTAssertEqual(items(view).count,1)
  }
  func testAttributedListPasteMintsDistinctParagraphIdentitiesAndRetainsWords() throws {
    let (window,view,_)=fixture("First\nSecond");defer{window.close()}
    try view.applyParagraphList(["marker":"decimal"])
    let original=items(view),fragment=view.attributedString().attributedSubstring(from:NSRange(location:0,length:6))
    view.setSelectedRange(NSRange(location:view.string.utf16.count,length:0));view.insertNewline(nil)
    view.insertText(fragment,replacementRange:NSRange(location:NSNotFound,length:0))
    let pasted=items(view)
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"First\nSecond\nFirst\n")
    XCTAssertEqual(pasted.first?.id,original.first?.id)
    XCTAssertEqual(Set(pasted.map(\.id)).count,pasted.count)
    XCTAssertGreaterThanOrEqual(pasted.count,3);XCTAssertNotEqual(pasted[2].id,original[0].id)
  }
  func testNativeCanvasEnterFinishFormattingAndReturnPreserveDocumentListIdentity() throws {
    let (window,_,source)=fixture("First\nSecond");defer{window.close()}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let repo=try ProjectRepository(root:root);var p=Project(name:"Native lists"),object=try p.makeObject(recipeID:"artboard"),e=source
    try ParagraphLists.edit(&e.listItems,text:e.text,marker:.decimal)
    object.artwork=Artwork(elements:[e]);p.objects=[object];try repo.save(p)
    let store=StudioStore(repository:repo,seedLibrary:false);try store.engine.open(p.id)
    let canvas=VectorCanvasView(frame:window.contentView!.bounds),session=store.artworkSession
    canvas.session=session;session.canvas=canvas;session.objectID=object.id;session.choose([e.id]);window.contentView=canvas
    let before=store.project;canvas.synchronize();canvas.beginText(e)
    let editor=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    editor.didChangeText();canvas.finishText();XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    canvas.beginText(e)
    let live=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    live.setSelectedRange(NSRange(location:0,length:5));_ = canvas.applyTextStyle{$0.tracking=1.2}
    XCTAssertEqual(store.project!.objects[0].artwork!.elements[0].listItems,e.listItems)
    live.setSelectedRange(NSRange(location:live.string.utf16.count,length:0));live.insertNewline(nil)
    let saved=store.project!.objects[0].artwork!.elements[0]
    XCTAssertEqual(saved.text,"First\nSecond\n");XCTAssertEqual(saved.listItems?.count,3)
    XCTAssertEqual(saved.listItems?.first?.id,e.listItems?.first?.id)
    canvas.finishText()
    store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testInstructionListPhysicalPDFAndRasterAgreeWithGeneratedOutlines() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    var p=Project(name:"Orbital assembly"),sheet=try p.makeObject(recipeID:"artboard",parameters:["width":180,"depth":230])
    func text(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ value:String,_ size:Double=14,_ color:String="#24353D")->ArtworkElement {
      var e=ArtworkElement(kind:"text",x:x,y:y,width:w,height:h,text:value,color:color,fontSize:size)
      e.typography=Typography();e.typography!.fontName="Georgia";e.typography!.leading=size*1.45;return e
    }
    let identity=UUID()
    var checklist=text(14,44,152,46,"Inspect the fabric and lining\nConfirm the decoration placement\nCheck thread colors and backing\nKeep the original artwork editable")
    try ParagraphLists.edit(&checklist.listItems,text:checklist.text,marker:.bullet)
    checklist.listItems![2].level=1
    var first=text(14,106,70,47,"Prepare the panels and marks\nPlace each patch against its registration guides")
    try ParagraphLists.edit(&first.listItems,text:first.text,marker:.decimal,listID:identity)
    var second=text(96,106,70,47,"Check dimensions at physical size\nSave the approved arrangement")
    try ParagraphLists.edit(&second.listItems,text:second.text,marker:.decimal,listID:identity)
    var restart=text(14,169,70,30,"Inspect the first sample\nRecord the final settings")
    try ParagraphLists.edit(&restart.listItems,text:restart.text,marker:.decimal,listID:identity,restart:1)
    var rtl=text(96,169,70,30,"افحص المواد\nابدأ التجميع")
    rtl.typography!.direction="rtl";try ParagraphLists.edit(&rtl.listItems,text:rtl.text,marker:.decimal)
    let elements=[text(14,12,152,15,"ORBITAL / ASSEMBLY NOTES",23),text(14,34,152,8,"01 / PREPARATION",9,"#A55135"),checklist,
      text(14,96,152,8,"02 / ASSEMBLY — CONTINUED ACROSS COLUMNS",9,"#A55135"),first,second,
      text(14,159,152,8,"03 / FINAL CHECK — RESTART + RTL",9,"#A55135"),restart,rtl,
      text(14,216,152,8,"FORM / INSTRUCTION STUDIES · 180 × 230 MM",8,"#A55135")]
    let art=Artwork(background:"#F5F1E6",elements:elements,bleed:0);sheet.artwork=art;p.objects=[sheet];store.engine.project=p
    let before=store.project
    let directory=root.appendingPathComponent("Exports");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    for format in ["pdf","svg","png"] {
      let path=directory.appendingPathComponent("publication-lists."+format)
      _=try store.graphicsCall("form_export_artwork",["object_id":sheet.id.uuidString,"format":format,"path":path.path,"dpi":144,"outline_text":false])
      let data=try Data(contentsOf:path);XCTAssertGreaterThan(data.count,1000)
      if format=="pdf" {
        let doc=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:data as CFData)!)),page=try XCTUnwrap(doc.page(at:1))
        XCTAssertEqual(page.getBoxRect(.mediaBox).width/TypographyEngine.pointsPerMM,180,accuracy:0.001)
        XCTAssertEqual(page.getBoxRect(.mediaBox).height/TypographyEngine.pointsPerMM,230,accuracy:0.001)
      }
      if let destination=ProcessInfo.processInfo.environment["FORM_PUBLICATION_PROOF_DIR"] {
        let folder=URL(fileURLWithPath:destination);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try data.write(to:folder.appendingPathComponent(path.lastPathComponent),options:.atomic)
      }
    }
    let converted=try ArtworkOutlines.convert(art,ids:Set(elements.filter{$0.kind=="text"}.map(\.id)),mode:"text").artwork
    let native=ArtworkRenderer.image(art,width:180,height:230,assets:root,pixelsPerMM:3).representations[0] as! NSBitmapImageRep
    let outlined=ArtworkRenderer.image(converted,width:180,height:230,assets:root,pixelsPerMM:3).representations[0] as! NSBitmapImageRep
    var sum=0.0,count=0
    for y in 0..<native.pixelsHigh {for x in 0..<native.pixelsWide {
      let a=native.colorAt(x:x,y:y)!,b=outlined.colorAt(x:x,y:y)!
      if min(a.redComponent,b.redComponent)<0.6 {sum+=abs(a.redComponent-b.redComponent);count+=1}
    }}
    print("Structured-list native/outline foreground error: \(sum/Double(max(1,count)))")
    XCTAssertGreaterThan(count,1000);XCTAssertLessThan(sum/Double(count),0.15);XCTAssertEqual(store.project,before)
  }
}

import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class FontSelectionContextTests:XCTestCase {
  @MainActor private final class Fixture {
    let root:URL,store:StudioStore,window:NSWindow,canvas:VectorCanvasView,search:NSTextField
    let textID:UUID,otherID:UUID
    var session:ArtworkSession {store.artworkSession}
    init(text:String="First 👩🏽‍💻\n שלום tail")throws {
      _ = NSApplication.shared
      root=FileManager.default.temporaryDirectory.appendingPathComponent("font-handoff-"+UUID().uuidString)
      store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
      store.fontLibraryPreferences = .init(file:root.appendingPathComponent("fonts.json"))
      var project=Project(name:"Font picker target")
      var object=try project.makeObject(recipeID:"artboard")
      var element=ArtworkElement(kind:"text",x:10,y:20,width:160,height:60,text:text,fontSize:18)
      var typography=Typography();typography.fontName="Skia";typography.frameMode="area"
      typography.features=[21:0];typography.variations=[2_003_268_040:1.3]
      element.typography=typography;textID=element.id
      let other=ArtworkElement(kind:"text",x:10,y:100,width:100,height:30,text:"Other target")
      otherID=other.id;object.artwork = .init(elements:[element,other]);project.objects=[object]
      store.engine.project=project;store.showingHome=false
      window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:900,height:700),
        styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false
      canvas=VectorCanvasView(frame:.init(x:0,y:0,width:900,height:650))
      search=NSTextField(frame:.init(x:15,y:660,width:300,height:25))
      let host=try XCTUnwrap(window.contentView);host.addSubview(canvas);host.addSubview(search)
      canvas.session=store.artworkSession;store.artworkSession.canvas=canvas
      store.artworkSession.activate(object.id);store.artworkSession.choose([element.id]);canvas.synchronize()
    }
    func close() {
      canvas.finishText();window.contentView=nil;window.close();store.engine.project=nil
      try? FileManager.default.removeItem(at:root)
    }
    func source()throws->ArtworkElement {
      try XCTUnwrap(store.project?.objects.first?.artwork?.elements.first{$0.id==textID})
    }
    func edit()throws->CanvasTextView {
      canvas.beginText(try source())
      let view=try XCTUnwrap(canvas.activeTextView);view.undoManager?.groupsByEvent=false
      return view
    }
    func searchFocus()throws {
      XCTAssertTrue(window.makeFirstResponder(search))
      let editor=try XCTUnwrap(search.currentEditor() as? NSTextView)
      editor.insertText("Georgia",replacementRange:editor.selectedRange())
      XCTAssertFalse(window.firstResponder === canvas.activeTextView)
    }
  }

  func testNativeUTF16RangeSurvivesSearchFocusAndUsesItsOwnUndo()throws {
    let f=try Fixture();defer{f.close()}
    let baseline=try XCTUnwrap(f.store.project),view=try f.edit()
    let range=(view.string as NSString).range(of:"👩🏽‍💻\n שלום")
    view.setSelectedRange(range)
    let context=f.session.captureFontSelection()
    XCTAssertEqual(context.sourceRange,range);XCTAssertEqual(context.previewText,"👩🏽‍💻 שלום")
    try f.searchFocus()
    _ = FontLibraryCatalog.search("Georgia")
    let preview=try XCTUnwrap(FontLibraryCatalog.preview("Georgia-Bold"))
    _ = FontLibraryCatalog.previewText(context.previewText,font:preview)
    XCTAssertTrue(f.session.canApplyFont(context:context))
    XCTAssertEqual(f.store.project,baseline);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertTrue(f.store.fontLibraryPreferences.recent.isEmpty)

    XCTAssertTrue(f.session.chooseFont("Georgia-Bold",context:context),f.store.error ?? "Font assignment failed")
    XCTAssertTrue(f.window.firstResponder === view)
    XCTAssertEqual(TextCase.source(view.attributedString()).sourceRange(view.selectedRange()),range)
    let assigned=try f.source(),runs=try XCTUnwrap(assigned.textRuns)
    XCTAssertEqual(assigned.text,try XCTUnwrap(baseline.objects.first?.artwork?.elements.first?.text))
    for run in runs {
      XCTAssertEqual(run.typography.fontName,
        NSIntersectionRange(NSRange(location:run.location,length:run.length),range).length>0 ? "Georgia-Bold":"Skia")
      XCTAssertEqual(run.typography.features,[21:0]);XCTAssertEqual(run.typography.variations,[2_003_268_040:1.3])
    }
    XCTAssertEqual(f.store.fontLibraryPreferences.recent,["Georgia-Bold"])
    XCTAssertFalse(f.session.canApplyFont(context:context),"An applied picker token cannot be reused.")
    view.undoManager?.undo();f.canvas.finishText()
    XCTAssertEqual(f.store.project,baseline)
  }

  func testPreviewUsesSourceCharactersAndCapsWholeGraphemesWithoutMutatingHistory()throws {
    let text="  \n"+String(repeating:"👨‍👩‍👧‍👦",count:140)+"\tend"
    let f=try Fixture(text:text);defer{f.close()}
    let before=f.store.project,context=f.session.captureFontSelection()
    XCTAssertEqual(context.previewText.count,128)
    XCTAssertEqual(context.previewText,String(repeating:"👨‍👩‍👧‍👦",count:128))
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertTrue(f.store.fontLibraryPreferences.recent.isEmpty)
    XCTAssertEqual(FontSelectionContext.normalizedPreview(" \tOne\n\nשלום  two\r\n"),"One שלום two")
    XCTAssertNil(FontSelectionContext.normalizedPreview("\n \t"))
    f.session.choose([])
    XCTAssertEqual(f.session.captureFontSelection().previewText,FontLibraryCatalog.defaultPreview)
  }

  func testChangedSelectionProjectLifetimeAndSourceRejectOldPickerWithoutRecents()throws {
    let f=try Fixture();defer{f.close()}
    let before=f.store.project,first=f.session.captureFontSelection()
    f.session.choose([f.otherID]);f.session.choose([f.textID])
    XCTAssertFalse(f.session.canApplyFont(context:first),"Changing away and back does not revive a stale picker.")
    XCTAssertFalse(f.session.chooseFont("Georgia",context:first))
    let lifetime=f.session.captureFontSelection();f.store.invalidateArtworkTransferProject()
    XCTAssertFalse(f.session.chooseFont("Georgia",context:lifetime))
    let source=f.session.captureFontSelection()
    var changed=try XCTUnwrap(f.store.project);changed.objects[0].artwork!.elements[0].text="Changed elsewhere"
    f.store.engine.project=changed
    XCTAssertFalse(f.session.chooseFont("Georgia",context:source))
    XCTAssertEqual(f.store.project,changed);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertTrue(f.store.fontLibraryPreferences.recent.isEmpty)
    f.store.engine.project=before
    let project=f.session.captureFontSelection();var other=try XCTUnwrap(before);other.id=UUID()
    f.store.engine.project=other
    XCTAssertFalse(f.session.chooseFont("Georgia",context:project));XCTAssertEqual(f.store.project,other)
  }

  func testMarkedTextAndClosedEditorCannotApplyCapturedFont()throws {
    let f=try Fixture();defer{f.close()}
    let view=try f.edit(),context=f.session.captureFontSelection(),before=f.store.project
    view.undoManager?.beginUndoGrouping()
    view.setMarkedText("に",selectedRange:.init(location:1,length:0),replacementRange:.init(location:NSNotFound,length:0))
    XCTAssertTrue(view.hasMarkedText())
    XCTAssertFalse(f.session.chooseFont("Georgia",context:context))
    XCTAssertTrue(view.hasMarkedText());XCTAssertEqual(f.store.project,before)
    XCTAssertTrue(f.store.fontLibraryPreferences.recent.isEmpty)
    view.unmarkText();view.didChangeText()
    view.undoManager?.endUndoGrouping()
    let closed=f.session.captureFontSelection();f.canvas.finishText()
    let committed=f.store.project
    XCTAssertFalse(f.session.chooseFont("Georgia",context:closed));XCTAssertEqual(f.store.project,committed)
    XCTAssertTrue(f.store.fontLibraryPreferences.recent.isEmpty)
  }

  func testMissingFaceLockedTextAndNonTextSelectionDoNotEnterRecents()throws {
    let f=try Fixture();defer{f.close()}
    let before=f.store.project
    XCTAssertFalse(f.session.chooseFont("FORM Definitely Missing Face",context:f.session.captureFontSelection()))
    XCTAssertEqual(f.store.project,before)
    var project=try XCTUnwrap(before);project.objects[0].artwork!.elements[0].locked=true
    f.store.engine.project=project
    XCTAssertFalse(f.session.chooseFont("Georgia",context:f.session.captureFontSelection()))
    XCTAssertEqual(f.store.project,project)
    project.objects[0].artwork!.elements[0].locked=nil;project.objects[0].artwork!.elements[0].kind="rectangle"
    f.store.engine.project=project
    XCTAssertFalse(f.session.chooseFont("Georgia",context:f.session.captureFontSelection()))
    XCTAssertEqual(f.store.project,project);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertTrue(f.store.fontLibraryPreferences.recent.isEmpty)
  }

  func testWholeSelectedTextAssignmentUsesOneHistoryStepAndRetainsRichSettings()throws {
    let f=try Fixture();defer{f.close()}
    let before=f.store.project,context=f.session.captureFontSelection()
    try f.searchFocus()
    XCTAssertTrue(f.session.chooseFont("Georgia-Bold",context:context))
    let result=try f.source()
    XCTAssertEqual(result.typography?.fontName,"Georgia-Bold")
    XCTAssertEqual(result.typography?.features,[21:0]);XCTAssertEqual(result.typography?.variations,[2_003_268_040:1.3])
    XCTAssertEqual(f.store.engine.undoStack.count,1);XCTAssertEqual(f.store.fontLibraryPreferences.recent,["Georgia-Bold"])
    f.store.engine.undo();XCTAssertEqual(f.store.project,before)
  }

  func testStoryPreviewAndApplyUseGlobalSourceRangeAfterSearchTakesFocus()throws {
    let f=try Fixture();defer{f.close()}
    var project=try Samples.fieldGuide(),source=project.textStories![0].sourceElement
    source.textRuns=nil;source.typography!.fontName="Skia"
    try PublicationCommands.setSource(in:&project,storyID:project.textStories![0].id,source:source)
    let frame=project.textStories![0].frames[1],baseline=project
    f.store.engine.project=project;f.session.activate(frame.objectID);f.session.choose([frame.elementID]);f.canvas.synchronize()
    f.canvas.beginText(try XCTUnwrap(project.storyFrame(frame)?.element))
    let editor=try XCTUnwrap(f.canvas.storyEditor),view=try XCTUnwrap(f.canvas.activeTextView)
    editor.nativeUndo.groupsByEvent=false
    let position=editor.composition.sourceRange(1).location,range=NSRange(location:position,length:8)
    editor.focus(frame,range:range)
    let context=f.session.captureFontSelection()
    XCTAssertEqual(context.sourceRange,range)
    XCTAssertEqual(context.previewText,FontSelectionContext.normalizedPreview((source.text as NSString).substring(with:range)))
    try f.searchFocus();XCTAssertTrue(f.session.canApplyFont(context:context))
    XCTAssertEqual(f.store.project,baseline,"Opening and searching must not normalize or commit story source.")
    XCTAssertTrue(f.session.chooseFont("Georgia-Bold",context:context),f.store.error ?? "Font assignment failed")
    XCTAssertTrue(f.window.firstResponder === view)
    XCTAssertEqual(f.store.project?.objects,baseline.objects,"A shared-story font edit must not write frame placeholders.")
    let changed=try XCTUnwrap(f.store.project?.textStories?.first)
    XCTAssertEqual(changed.text,source.text)
    XCTAssertEqual(changed.textRuns?.first{$0.location==position}?.typography.fontName,"Georgia-Bold")
    editor.nativeUndo.undo();f.canvas.finishText();XCTAssertEqual(f.store.project,baseline)
  }

  func testMixedDirectTextAndGroupSelectionChangesOnlyCapturedDirectText()throws {
    let f=try Fixture();defer{f.close()}
    var project=try XCTUnwrap(f.store.project)
    let group=ArtworkElement(kind:"group",x:20,y:30,width:120,height:50)
    project.objects[0].artwork!.elements.append(group)
    project.objects[0].artwork!.elements[1].parentID=group.id
    f.store.engine.project=project;f.session.choose([f.textID,group.id]);f.canvas.synchronize()
    let context=f.session.captureFontSelection()
    XCTAssertEqual(context.textElementIDs,[f.textID])
    try f.searchFocus()
    XCTAssertTrue(f.session.chooseFont("Georgia-Bold",context:context),f.store.error ?? "Font assignment failed")
    XCTAssertEqual(try f.source().typography?.fontName,"Georgia-Bold")
    XCTAssertEqual(f.store.project?.objects[0].artwork?.elements[1],project.objects[0].artwork?.elements[1],
      "Selecting a group beside a text layer must not assign its unselected descendants.")
    XCTAssertEqual(f.store.engine.undoStack.count,1)
    f.store.engine.undo();XCTAssertEqual(f.store.project,project)
  }

  func testDocumentReplacementContextRejectsDifferentProjectAndSameIDReopeningBeforeClosingEditor()throws {
    let f=try Fixture();defer{f.close()}
    let view=try f.edit(),context=FontDocumentContext(store:f.store),baseline=f.store.project
    let review=try f.store.replaceDocumentFont(from:"Skia",to:"Georgia-Bold",context:context,dryRun:true) as? [String:Any]
    XCTAssertGreaterThan(review?["replaced_assignments"] as? Int ?? 0,0)
    XCTAssertEqual(f.store.project,baseline);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertTrue(f.canvas.activeTextView === view);XCTAssertTrue(f.store.fontLibraryPreferences.recent.isEmpty)
    f.store.invalidateArtworkTransferProject()
    for dry in [true,false] {
      XCTAssertThrowsError(try f.store.replaceDocumentFont(from:"Skia",to:"Georgia-Bold",context:context,dryRun:dry))
      XCTAssertTrue(f.canvas.activeTextView === view,"A stale operation must be rejected before ending a native editor.")
    }
    let next=FontDocumentContext(store:f.store)
    var other=try XCTUnwrap(baseline);other.id=UUID();f.store.engine.project=other
    XCTAssertThrowsError(try f.store.replaceDocumentFont(from:"Skia",to:"Georgia-Bold",context:next,dryRun:false))
    XCTAssertEqual(f.store.project,other);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertTrue(f.store.fontLibraryPreferences.recent.isEmpty)
  }

  func testCurrentDocumentReplacementUsesOneUndoAndRecordsOnlyActualReplacement()throws {
    let f=try Fixture();defer{f.close()}
    let before=f.store.project,context=FontDocumentContext(store:f.store)
    _ = try f.store.replaceDocumentFont(from:"Skia",to:"Georgia-Bold",context:context,dryRun:false)
    XCTAssertEqual(try f.source().typography?.fontName,"Georgia-Bold")
    XCTAssertEqual(f.store.engine.undoStack.count,1)
    XCTAssertEqual(f.store.fontLibraryPreferences.recent,["Georgia-Bold"])
    f.store.engine.undo();XCTAssertEqual(f.store.project,before)
  }

  func testRecolorResizeOpticalResetAndCaretKeepAuthoredFacesAcrossNativeFallbacks()throws {
    let f=try Fixture(text:"👩🏽‍💻 שלום Latin");defer{f.close()}
    var project=try XCTUnwrap(f.store.project),element=try f.source()
    var first=try XCTUnwrap(element.typography);first.fontName="Georgia-Bold";first.opticalSizing = .init(.automatic)
    var second=first;second.fontName="Baskerville"
    let latin=(element.text as NSString).range(of:"Latin")
    element.typography=first;element.textRuns=[.init(location:latin.location,length:latin.length,
      typography:second,fontSize:18,color:element.color)]
    project.objects[0].artwork!.elements[0]=element;f.store.engine.project=project
    let view=try f.edit(),all=NSRange(location:0,length:view.string.utf16.count)
    func assertFaces(_ runs:[TextSpan],file:StaticString=#filePath,line:UInt=#line) {
      XCTAssertFalse(runs.isEmpty,file:file,line:line)
      for run in runs {
        XCTAssertEqual(run.typography.fontName,run.location>=latin.location ? "Baskerville":"Georgia-Bold",file:file,line:line)
        XCTAssertEqual(run.typography.features,first.features,file:file,line:line)
        XCTAssertEqual(run.typography.variations,first.variations,file:file,line:line)
      }
    }
    view.setSelectedRange(all)
    XCTAssertEqual(Set(try XCTUnwrap(f.canvas.opticalSizingInspection()).map(\.fontName)),["Georgia-Bold","Baskerville"])
    XCTAssertTrue(f.canvas.applyTextColor("#CC3300"))
    assertFaces(try XCTUnwrap(f.source().textRuns))
    view.undoManager?.undo()
    view.setSelectedRange(all)
    XCTAssertTrue(f.canvas.applyTextSize(32))
    let resized=try XCTUnwrap(f.source().textRuns);assertFaces(resized)
    XCTAssertTrue(resized.allSatisfy{$0.fontSize==32 && $0.typography.opticalSizing == .init(.automatic)})
    view.undoManager?.undo()
    view.setSelectedRange(all)
    XCTAssertTrue(try f.canvas.applyOpticalSizing(nil))
    let reset=try XCTUnwrap(f.source().textRuns);assertFaces(reset)
    XCTAssertTrue(reset.allSatisfy{$0.typography.opticalSizing==nil})
    view.undoManager?.undo()
    let emoji=(view.string as NSString).range(of:"👩🏽‍💻")
    view.setSelectedRange(.init(location:NSMaxRange(emoji),length:0))
    XCTAssertEqual(f.canvas.textInspection()?.typography.fontName,"Georgia-Bold")
    XCTAssertEqual(f.canvas.opticalSizingInspection()?.first?.fontName,"Georgia-Bold")
    f.canvas.finishText();XCTAssertEqual(f.store.project,project)
  }
}

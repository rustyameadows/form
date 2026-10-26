import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

private struct NativePositionSizeField:View {
  @ObservedObject var session:ArtworkSession
  var body:some View {
    ScalarArtworkField("Size",value:session.inspectedSize,unit:"pt",increment:session.numericIncrement(step:1)) {session.typeSize($0)}.padding(15).frame(width:230,height:90)
  }
}
@MainActor final class CharacterPositionEditingTests:XCTestCase {
  private func fixture(words:String="H12abQO",story:Bool=false)throws->(StudioStore,URL,NSWindow,VectorCanvasView,CanvasTextView,ArtworkElement) {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);let repository=try ProjectRepository(root:root),store=StudioStore(repository:repository,seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    var p=Project(name:"Character position native"),o=try p.makeObject(recipeID:"artboard",parameters:["width":180,"depth":110]),e=ArtworkElement(kind:"text",x:10,y:10,width:150,height:70,text:words,fontSize:36)
    var type=Typography();type.fontName=".AppleSystemUIFont";type.baseline=3;type.kerningMode="metrics";e.typography=type;o.artwork = .init(elements:[e]);p.objects=[o]
    if story {var next=try p.makeObject(recipeID:"artboard",parameters:["width":180,"depth":110]);var capacity=e;capacity.id=UUID();capacity.text="";next.artwork = .init(elements:[capacity]);p.objects.append(next);_ = try PublicationCommands.createStory(in:&p,frames:[.init(objectID:o.id,elementID:e.id),.init(objectID:next.id,elementID:capacity.id)])}
    store.engine.project=p;try store.engine.flush();store.mode = .artwork
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:980,height:700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:window.contentView!.bounds),session=store.artworkSession;canvas.session=session;session.canvas=canvas;session.objectID=o.id;session.choose([e.id]);window.contentView=canvas;canvas.synchronize()
    canvas.beginText(try XCTUnwrap(store.project!.objects[0].artwork!.elements.first));let view=try XCTUnwrap(window.firstResponder as? CanvasTextView);view.undoManager?.groupsByEvent=false
    addTeardownBlock {MainActor.assumeIsolated {window.makeFirstResponder(nil);canvas.finishText();window.close();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}}
    return(store,root,window,canvas,view,e)
  }
  private func spans(_ view:CanvasTextView,fallback:Typography)->[TextSpan] {TypographyEngine.spans(from:TextCase.source(view.attributedString()).text,fallback:fallback)}
  func testSelectedCharacterPositionHasOneNativeUndoAndOneExactDomainUndoAfterFinish()throws {
    let(store,_,_,canvas,view,e)=try fixture(),before=store.project!,native=NSAttributedString(attributedString:view.attributedString())
    view.setSelectedRange(.init(location:1,length:5));XCTAssertTrue(try canvas.applyCharacterPosition(.superscript));let changed=NSAttributedString(attributedString:view.attributedString())
    XCTAssertEqual(view.selectedRange(),NSRange(location:1,length:5),"A character-position edit must retain the real native selection and inspector context.")
    XCTAssertEqual(view.string,e.text);XCTAssertEqual(canvas.textInspection()?.fontSize,36);XCTAssertEqual(canvas.textInspection()?.typography.baseline,3)
    XCTAssertEqual(spans(view,fallback:e.typography!).first{$0.location==1}?.typography.characterPosition,.superscript)
    view.undoManager?.undo();XCTAssertTrue(GlyphEngine.nativeEqual(view.attributedString(),native));view.undoManager?.redo();XCTAssertTrue(GlyphEngine.nativeEqual(view.attributedString(),changed))
    canvas.finishText();XCTAssertEqual(store.engine.undoStack.count,1);XCTAssertEqual(store.project!.camera,before.camera);XCTAssertEqual(store.project!.objects[0].artwork!.elements[0].width,e.width);XCTAssertEqual(store.project!.objects[0].artwork!.elements[0].height,e.height)
    store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testNativeSuperscriptSubscriptAndUnscriptActionsUseSemanticSourceWithoutAppKitAlias()throws {
    let(_,_,_,canvas,view,e)=try fixture();view.setSelectedRange(.init(location:1,length:4))
    view.superscript(nil);XCTAssertEqual(spans(view,fallback:e.typography!).first{$0.location==1}?.typography.characterPosition,.superscript)
    XCTAssertEqual(CharacterTypography.records(in:view.attributedString()).first?.1.method,"font-authored")
    XCTAssertNil(view.attributedString().attribute(.superscript,at:1,effectiveRange:nil));XCTAssertEqual(canvas.textInspection()?.fontSize,36)
    view.subscript(nil);XCTAssertEqual(spans(view,fallback:e.typography!).first{$0.location==1}?.typography.characterPosition,.subscript)
    view.unscript(nil);XCTAssertEqual(spans(view,fallback:e.typography!).first{$0.location==1}?.typography.characterPosition,.normal);XCTAssertEqual(view.string,e.text)
  }
  func testTypingWithPositionPreservesSourceAndNativeUndoWithoutDoubleScaling()throws {
    let(_,_,_,canvas,view,e)=try fixture();view.setSelectedRange(.init(location:1,length:0));XCTAssertTrue(try canvas.applyCharacterPosition(.superscript))
    view.insertText("9",replacementRange:view.selectedRange());XCTAssertEqual(TextCase.source(view.attributedString()).text.string,"H912abQO")
    let selected=try XCTUnwrap(spans(view,fallback:e.typography!).first{$0.location==1});XCTAssertEqual(selected.fontSize,36);XCTAssertEqual(selected.typography.baseline,3);XCTAssertEqual(selected.typography.characterPosition,.superscript)
    view.undoManager?.undo();XCTAssertEqual(TextCase.source(view.attributedString()).text.string,e.text);XCTAssertTrue(spans(view,fallback:e.typography!).allSatisfy{$0.fontSize==36 && $0.typography.characterPosition==nil})
  }
  func testSizeBaselineAndFontEditsUseAuthoredValuesAndSurviveDiskReopen()throws {
    let(store,root,_,canvas,view,e)=try fixture();view.setSelectedRange(.init(location:1,length:5));XCTAssertTrue(try canvas.applyCharacterPosition(.superscript))
    XCTAssertTrue(canvas.applyTextSize(42));XCTAssertTrue(canvas.applyTextStyle{$0.baseline=4.25;$0.opticalSizing = .init(.automatic);$0.variations[OpticalSizing.axisID]=72})
    var run=try XCTUnwrap(spans(view,fallback:e.typography!).first{$0.location==1});XCTAssertEqual(run.fontSize,42);XCTAssertEqual(run.typography.baseline,4.25);XCTAssertEqual(run.typography.variations[OpticalSizing.axisID],72)
    XCTAssertTrue(canvas.applyTextStyle{$0.fontName="Georgia"});run=try XCTUnwrap(spans(view,fallback:e.typography!).first{$0.location==1});XCTAssertEqual(run.fontSize,42);XCTAssertEqual(run.typography.baseline,4.25);XCTAssertEqual(run.typography.fontName,"Georgia");XCTAssertEqual(run.typography.characterPosition,.superscript);XCTAssertEqual(run.typography.opticalSizing,.init(.automatic));XCTAssertEqual(run.typography.variations[OpticalSizing.axisID],72)
    canvas.finishText();try store.engine.flush();let before=store.project!,restored=try ProjectRepository(root:root).load(before.id)
    XCTAssertEqual(restored.objects,before.objects);XCTAssertEqual(restored.schemaVersion,47);XCTAssertEqual(restored.objects[0].artwork!.elements[0].text,e.text)
  }
  func testIncompleteGraphemeAndMarkedInputPreserveNativeSelectionAndDocument()throws {
    let(store,_,window,canvas,view,e)=try fixture(words:"e\u{301}Q");view.setSelectedRange(.init(location:0,length:1));let before=NSAttributedString(attributedString:view.attributedString()),project=store.project!
    XCTAssertThrowsError(try canvas.applyCharacterPosition(.superscript));XCTAssertTrue(GlyphEngine.nativeEqual(view.attributedString(),before));XCTAssertEqual(view.selectedRange(),NSRange(location:0,length:1));XCTAssertTrue(window.firstResponder === view);XCTAssertEqual(store.project,project)
    view.undoManager?.beginUndoGrouping();defer{view.undoManager?.endUndoGrouping()}
    view.setSelectedRange(.init(location:2,length:0));view.setMarkedText("に",selectedRange:.init(location:1,length:0),replacementRange:view.selectedRange());XCTAssertTrue(view.hasMarkedText())
    let marked=NSAttributedString(attributedString:view.attributedString()),range=view.selectedRange(),current=store.project!
    XCTAssertThrowsError(try canvas.applyCharacterPosition(.subscript));XCTAssertThrowsError(try store.preflightCharacterPositionHandoff("form_edit_artwork",["object_id":store.project!.objects[0].id.uuidString,"element_ids":[e.id.uuidString],"command":"character_position","position":"superscript"]))
    XCTAssertTrue(GlyphEngine.nativeEqual(view.attributedString(),marked));XCTAssertEqual(view.selectedRange(),range);XCTAssertEqual(store.project,current)
    view.unmarkText()
  }
  func testRejectedMCPPreflightKeepsPendingNativeDraftFocusAndUndoStack()throws {
    let(store,_,window,_,view,e)=try fixture();view.setSelectedRange(.init(location:1,length:0));view.insertText("Draft",replacementRange:view.selectedRange())
    let native=NSAttributedString(attributedString:view.attributedString()),range=view.selectedRange(),project=store.project!,undo=store.engine.undoStack.count
    let args:[String:Any]=["object_id":project.objects[0].id.uuidString,"element_ids":[e.id.uuidString],"command":"character_position","position":"raised"]
    XCTAssertThrowsError(try store.preflightCharacterPositionHandoff("form_edit_artwork",args));XCTAssertEqual(store.project,project);XCTAssertEqual(store.engine.undoStack.count,undo);XCTAssertTrue(window.firstResponder === view);XCTAssertEqual(view.selectedRange(),range);XCTAssertTrue(GlyphEngine.nativeEqual(view.attributedString(),native))
  }
  func testLinkedNativeStoryPositionEditsOneSourceAndRetainsAllFrameDefinitions()throws {
    let(store,_,_,canvas,view,e)=try fixture(story:true),frames=store.project!.objects,original=store.project!.textStories![0]
    view.setSelectedRange(.init(location:1,length:4));view.superscript(nil)
    XCTAssertEqual(TextCase.source(view.attributedString()).text.string,original.text);XCTAssertEqual(canvas.textInspection()?.fontSize,36)
    canvas.finishText();XCTAssertEqual(store.project!.objects,frames);XCTAssertEqual(store.project!.textStories![0].id,original.id);XCTAssertEqual(store.project!.textStories![0].text,original.text)
    let run=try XCTUnwrap(store.project!.textStories![0].textRuns?.first{$0.location==1});XCTAssertEqual(run.fontSize,36);XCTAssertEqual(run.typography.baseline,e.typography!.baseline);XCTAssertEqual(run.typography.characterPosition,.superscript)
    store.engine.undo();XCTAssertEqual(store.project!.textStories![0],original)
  }
  func testDetachedTextViewActionsCannotChangeTheReplacementEditorOrProject()throws {
    let(store,_,window,canvas,old,e)=try fixture();canvas.finishText()
    canvas.beginText(e);let current=try XCTUnwrap(window.firstResponder as? CanvasTextView);XCTAssertFalse(old===current)
    current.setSelectedRange(.init(location:1,length:4));let native=NSAttributedString(attributedString:current.attributedString()),before=store.project!,undo=store.engine.undoStack.count
    old.superscript(nil);old.subscript(nil);old.unscript(nil)
    XCTAssertTrue(GlyphEngine.nativeEqual(current.attributedString(),native));XCTAssertEqual(current.selectedRange(),NSRange(location:1,length:4));XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
  }

  private func fields(_ view:NSView)->[NSTextField] {([view as? NSTextField].compactMap{$0})+view.subviews.flatMap{fields($0)}}
  func testPositionActionCommitsAnActiveNativeSizeFieldWithoutTabAndPreservesOtherCharacters()throws {
    let(store,_,window,canvas,view,e)=try fixture();view.setSelectedRange(.init(location:1,length:5));let before=store.project!
    let host=NSHostingView(rootView:NativePositionSizeField(session:store.artworkSession));host.frame = .init(x:690,y:400,width:230,height:90);canvas.addSubview(host);host.layoutSubtreeIfNeeded();window.orderBack(nil);RunLoop.main.run(until:Date().addingTimeInterval(0.07));host.layoutSubtreeIfNeeded()
    let field=try XCTUnwrap(fields(host).first{$0.isEditable});window.makeFirstResponder(field);let editor=try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.selectAll(nil);editor.insertText("44",replacementRange:.init(location:NSNotFound,length:0))
    try store.artworkSession.characterPosition(.superscript)
    let runs=spans(view,fallback:e.typography!),selected=try XCTUnwrap(runs.first{$0.location==1})
    XCTAssertEqual(selected.fontSize,44);XCTAssertEqual(selected.typography.characterPosition,.superscript);XCTAssertEqual(selected.typography.baseline,3);XCTAssertEqual(runs.first{$0.location==0}?.fontSize,36);XCTAssertEqual(view.string,e.text)
    window.makeFirstResponder(nil);canvas.finishText();XCTAssertEqual(store.project!.camera,before.camera);store.undo();XCTAssertEqual(store.project,before)
  }
  func testNativePositionSelectionAndInspectionSurviveHostedPickerRefresh()throws {
    let(store,_,window,canvas,view,e)=try fixture(words:"12abQ")
    view.setSelectedRange(.init(location:0,length:5));XCTAssertTrue(try canvas.applyCharacterPosition(.superscript))
    view.setSelectedRange(.init(location:2,length:2))
    let host=NSHostingView(rootView:FontFeaturesInspector(session:store.artworkSession).padding(20).frame(width:350,height:680))
    host.frame = .init(x:610,y:0,width:350,height:680);canvas.addSubview(host);window.orderBack(nil);host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.07));host.layoutSubtreeIfNeeded()
    func pickers(_ root:NSView)->[NSPopUpButton] {([root as? NSPopUpButton].compactMap{$0})+root.subviews.flatMap{pickers($0)}}
    let picker=try XCTUnwrap(pickers(host).first{$0.itemTitles.contains("Superscript") && $0.itemTitles.contains("Subscript")})
    view.setSelectedRange(.init(location:2,length:2))
    try store.artworkSession.characterPosition(.subscript)
    // Force the same native source refresh used by an inspector/project update.
    // Only non-text metadata differs; the selection must remain over the words.
    var refreshed=store.project!;refreshed.objects[0].artwork!.elements[0].name="Refreshed source metadata";store.engine.project=refreshed
    canvas.synchronize();host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.07));canvas.synchronize();host.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.selectedRange(),NSRange(location:2,length:2))
    XCTAssertEqual(store.artworkSession.opticalInspectionTypes.map(\.characterPosition),[.subscript])
    XCTAssertEqual(picker.titleOfSelectedItem,"Subscript")
    XCTAssertEqual(spans(view,fallback:e.typography!).first{$0.location==2}?.typography.characterPosition,.subscript)
  }

  func testNativePositionControlsHaveOnePositionPickerAndExplicitSmallCapStatusProof()throws {
    let(store,_,_,canvas,_,_)=try fixture();canvas.finishText();try store.artworkSession.characterPosition(.superscript)
    var p=store.project!;p.objects[0].artwork!.elements[0].typography!.features=[37:1];p.objects[0].artwork!.elements[0].typography!.fontName="Georgia";store.engine.project=p;let before=store.project!
    let panel=NSWindow(contentRect:.init(x:-10000,y:-10000,width:350,height:680),styleMask:[.titled],backing:.buffered,defer:false);panel.isReleasedWhenClosed=false
    defer{panel.close()}
    let host=NSHostingView(rootView:FontFeaturesInspector(session:store.artworkSession).padding(20).frame(width:350,height:680,alignment:.topLeading).background(Palette.paper));panel.contentView=host;panel.orderBack(nil);host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.06));host.layoutSubtreeIfNeeded()
    XCTAssertFalse(store.artworkSession.characterPositionInspection.isEmpty);XCTAssertTrue(store.artworkSession.smallCapWarnings.contains{$0.contains("does not offer")})
    if let path=ProcessInfo.processInfo.environment["FORM_CHARACTER_POSITION_PROOF_DIR"] {
      let target=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
      let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap);try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:target.appendingPathComponent("native-position-controls.png"))
    }
    XCTAssertEqual(store.project,before)
  }

}

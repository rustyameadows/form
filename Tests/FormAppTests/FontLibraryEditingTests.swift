import AppKit
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class FontLibraryEditingTests:XCTestCase {
  private func directory() throws -> URL {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root
  }
  private func fixture() throws -> (NSWindow,StudioStore,VectorCanvasView,ArtworkElement) {
    _=NSApplication.shared;let root=try directory(),store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("FontPreferences.json"))
    var p=Project(name:"Font replacement"),o=try p.makeObject(recipeID:"artboard")
    var e=ArtworkElement(kind:"text",x:10,y:20,width:160,height:60,text:"Original words remain editable",fontSize:18)
    var t=Typography();t.fontName="Skia";t.variations=[2_003_268_040:1.3];t.features=[1:3];e.typography=t
    o.artwork=Artwork(elements:[e]);p.objects=[o];store.engine.project=p
    let window=NSWindow(contentRect:.init(x:0,y:0,width:900,height:700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:window.contentView!.bounds),session=store.artworkSession
    canvas.session=session;session.canvas=canvas;session.objectID=o.id;session.choose([e.id]);window.contentView=canvas;canvas.synchronize()
    return(window,store,canvas,e)
  }
  func testFavoritesAndTwelveFaceRecentsPersistOutsideDocumentHistory() throws {
    let root=try directory(),file=root.appendingPathComponent("prefs.json"),p=FontLibraryPreferences(file:file)
    let first=try XCTUnwrap(FontLibraryCatalog.faces.first)
    p.toggle(first);XCTAssertTrue(p.favorite(first));p.used(first.name)
    for face in FontLibraryCatalog.faces.prefix(20) {p.used(face.name)}
    XCTAssertEqual(p.recent.count,12);XCTAssertEqual(Set(p.recent).count,12)
    let loaded=FontLibraryPreferences(file:file);XCTAssertEqual(loaded.favorites,p.favorites);XCTAssertEqual(loaded.recent,p.recent)
    loaded.toggle(first);XCTAssertFalse(loaded.favorite(first))
  }
  func testInstalledFaceSelectionKeepsCharacterFeaturesAxesAndNativeUndo() throws {
    let(window,store,canvas,e)=try fixture();defer{canvas.finishText();window.close()}
    let baseline=store.project!
    canvas.beginText(e);let text=try XCTUnwrap(window.firstResponder as? CanvasTextView);text.undoManager?.groupsByEvent=false
    text.setSelectedRange(NSRange(location:0,length:8));store.artworkSession.chooseFont("Georgia")
    let saved=try XCTUnwrap(store.project!.objects[0].artwork?.elements[0]),run=try XCTUnwrap(saved.textRuns?.first)
    XCTAssertEqual(saved.text,e.text);XCTAssertEqual(run.typography.fontName,"Georgia")
    XCTAssertEqual(run.typography.features,e.typography!.features);XCTAssertEqual(run.typography.variations,e.typography!.variations)
    XCTAssertEqual(saved.textRuns?.last?.typography.fontName,"Skia")
    XCTAssertEqual(store.fontLibraryPreferences.recent.first,"Georgia")
    text.undoManager?.undo();XCTAssertEqual(TextCase.source(text.attributedString()).text.string,e.text)
    canvas.finishText();XCTAssertEqual(store.project,baseline)
  }
  func testReplacementDryRunAtomicUndoAndMissingTargetLeaveAssignmentsAlone() throws {
    let(window,store,canvas,e)=try fixture();defer{canvas.finishText();window.close()}
    let baseline=store.project!
    let report=try store.replaceFontCall(["from_font":"Skia","to_font":"Georgia","dry_run":true]) as! [String:Any]
    XCTAssertEqual(report["replaced_assignments"] as? Int,1);XCTAssertEqual(store.project,baseline);XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertTrue(store.fontLibraryPreferences.recent.isEmpty)
    XCTAssertThrowsError(try store.replaceFontCall(["from_font":"Skia","to_font":"Georgia","dry_run":1]))
    _ = try store.replaceFontCall(["from_font":"Skia","to_font":"Georgia"])
    XCTAssertEqual(store.engine.undoStack.count,1);XCTAssertEqual(store.project!.objects[0].artwork!.elements[0].text,e.text)
    XCTAssertEqual(store.project!.objects[0].artwork!.elements[0].typography?.features,e.typography?.features)
    XCTAssertEqual(store.project!.objects[0].artwork!.elements[0].typography?.variations,e.typography?.variations)
    store.engine.undo();XCTAssertEqual(store.project,baseline)
    XCTAssertThrowsError(try store.replaceFontCall(["from_font":"Skia","to_font":"FORM Missing Face"]));XCTAssertEqual(store.project,baseline)
  }
  func testFontOnlyMCPSourceRangeAndInvalidHandoffKeepNativeEditingSafe() throws {
    let(window,store,canvas,e)=try fixture();defer{canvas.finishText();window.close()}
    canvas.beginText(e);let text=try XCTUnwrap(window.firstResponder as? CanvasTextView),before=store.project
    let bad:[String:Any]=["object_id":store.project!.objects[0].id.uuidString,"element_ids":[e.id.uuidString],"command":"font","font_name":"Georgia","location":9999,"length":3]
    XCTAssertThrowsError(try store.preflightFontHandoff("form_edit_artwork",bad))
    XCTAssertTrue(window.firstResponder === text);XCTAssertTrue(store.artworkSession.editingText);XCTAssertEqual(store.project,before)
    var valid=bad;valid["location"]=0;valid["length"]=8
    try store.preflightFontHandoff("form_edit_artwork",valid);canvas.finishText()
    _ = try store.engine.call("form_edit_artwork",arguments:valid)
    XCTAssertEqual(store.project!.objects[0].artwork!.elements[0].textRuns?.first?.typography.fontName,"Georgia")
    store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testReadOnlyCatalogPagingUsageAndInvalidBoundsDoNotMakeHistory() throws {
    let(window,store,canvas,_)=try fixture();defer{canvas.finishText();window.close()};let before=store.project
    let page=try store.fontLibraryCall(["command":"faces","query":"Georgia Bold","limit":1]) as! [String:Any]
    XCTAssertEqual((page["faces"] as? [[String:String]])?.count,1)
    let usage=try store.fontLibraryCall(["command":"usage"]) as! [String:Any]
    XCTAssertEqual((usage["fonts"] as? [[String:Any]])?.count,1)
    XCTAssertThrowsError(try store.fontLibraryCall(["limit":true]));XCTAssertThrowsError(try store.fontLibraryCall(["limit":0]))
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testLegacyFamilyPreferencesRemainFavoritesAndRecentFaceIdsAreBoundedAndUnique() throws {
    let root=try directory(),file=root.appendingPathComponent("legacy.json")
    let raw:[String:Any]=["favorites":["Georgia","Georgia"],"recent":["Georgia","Georgia",""],"legacyFamilies":["Baskerville"]]
    try JSONSerialization.data(withJSONObject:raw).write(to:file)
    let p=FontLibraryPreferences(file:file)
    XCTAssertEqual(p.favorites,["Georgia"]);XCTAssertEqual(p.recent,["Georgia"])
    let face=try XCTUnwrap(FontLibraryCatalog.faces.first{$0.family=="Baskerville"})
    XCTAssertTrue(p.favorite(face));p.toggle(face);XCTAssertFalse(p.favorite(face))
    let sibling=try XCTUnwrap(FontLibraryCatalog.faces.first{$0.family==face.family && $0.name != face.name})
    XCTAssertTrue(p.favorite(sibling));XCTAssertTrue(p.legacyFamilies.isEmpty)
  }

  func testActualBrowserHostingBuildsOnlyVisiblePreviewsAndKeepsPreferencesOutOfHistory() throws {
    let(window,store,canvas,_)=try fixture();defer{canvas.finishText();window.close()}
    FontLibraryCatalog.invalidate();let before=store.project,builds=FontLibraryCatalog.diagnostics["preview_builds"] as! Int
    let hosting=NSHostingView(rootView:FontBrowser(session:store.artworkSession))
    window.setContentSize(.init(width:460,height:590))
    hosting.frame=NSRect(x:0,y:0,width:460,height:590);window.contentView=hosting;hosting.layoutSubtreeIfNeeded()
    let bitmap=try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds))
    hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
    let created=(FontLibraryCatalog.diagnostics["preview_builds"] as! Int)-builds
    XCTAssertGreaterThan(created,0);XCTAssertLessThan(created,80,"Offscreen font rows must remain lazy.")
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    print("FONT33_ACTUAL_BROWSER_PREVIEWS",created)
    if let directory=ProcessInfo.processInfo.environment["FORM_FONT_PROOF_DIR"] {
      let folder=URL(fileURLWithPath:directory);try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("font-browser-native.png"))
    }
  }

  func testSharedStoryCharacterFontSelectionAndAgentRangeKeepOneSourceAndUndo() throws {
    let(window,store,canvas,_)=try fixture();defer{canvas.finishText();window.close()}
    var p=try Samples.fieldGuide(),source=p.textStories![0].sourceElement
    source.textRuns=nil;source.typography!.features=[21:0];source.typography!.variations=[123:2]
    try PublicationCommands.setSource(in:&p,storyID:p.textStories![0].id,source:source)
    let baseline=p,frame=p.textStories![0].frames[1]
    store.engine.project=p;store.artworkSession.activate(frame.objectID);store.artworkSession.choose([frame.elementID]);canvas.synchronize()
    let raw=try XCTUnwrap(p.storyFrame(frame)?.element);canvas.beginText(raw)
    let editor=try XCTUnwrap(canvas.storyEditor),position=editor.composition.sourceRange(1).location
    editor.nativeUndo.groupsByEvent=false;editor.focus(frame,range:NSRange(location:position,length:8))
    XCTAssertTrue(store.artworkSession.chooseFont("Skia"),store.error ?? "Font assignment failed")
    let changed=store.project!.textStories![0]
    XCTAssertEqual(changed.text,source.text);XCTAssertEqual(store.project!.objects,p.objects)
    let run=try XCTUnwrap(changed.textRuns?.first{$0.location==position})
    XCTAssertEqual(run.typography.fontName,try XCTUnwrap(NSFont(name:"Skia",size:14)).fontName);XCTAssertEqual(run.typography.features,source.typography!.features);XCTAssertEqual(run.typography.variations,[123:2])
    editor.nativeUndo.undo();canvas.finishText();XCTAssertEqual(store.project,baseline)
    let args:[String:Any]=["object_id":frame.objectID.uuidString,"element_ids":[frame.elementID.uuidString],"command":"font","font_name":"Georgia-Bold","location":position,"length":8]
    _ = try store.engine.call("form_edit_artwork",arguments:args)
    XCTAssertEqual(store.project!.textStories![0].text,source.text);XCTAssertEqual(store.project!.objects,p.objects)
    store.engine.undo();XCTAssertEqual(store.project,baseline)
  }
  func testOpeningMissingStoryFaceNeverSilentlyReassignsItsWordsFeaturesOrAxes() throws {
    let(window,store,canvas,_)=try fixture();defer{canvas.finishText();window.close()}
    var p=try Samples.fieldGuide(),source=p.textStories![0].sourceElement
    source.typography!.fontName="FORM Missing Story Face";source.typography!.features=[21:0];source.typography!.variations=[123:2]
    for r in source.textRuns?.indices ?? 0..<0 {source.textRuns![r].typography.fontName="FORM Missing Story Face"}
    try PublicationCommands.setSource(in:&p,storyID:p.textStories![0].id,source:source)
    let frame=p.textStories![0].frames[0];store.engine.project=p
    store.artworkSession.activate(frame.objectID);store.artworkSession.choose([frame.elementID]);canvas.synchronize()
    canvas.beginText(p.storyFrame(frame)!.element)
    let native=try XCTUnwrap(window.firstResponder as? CanvasTextView);native.didChangeText();canvas.finishText()
    XCTAssertEqual(store.project,p);XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertTrue(FontLibraryCatalog.usage(p).contains{$0["font_name"] as? String=="FORM Missing Story Face" && $0["available"] as? Bool==false})
  }

}

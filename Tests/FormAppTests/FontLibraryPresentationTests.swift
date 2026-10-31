import AppKit
import SwiftUI
import XCTest
import FormCore
import FormGraphics
@testable import FormApp

@MainActor final class FontLibraryPresentationTests:XCTestCase {
  private struct Fixture {
    let store:StudioStore,canvas:VectorCanvasView,state:FontBrowsingState,preferences:URL
  }
  private func fixture(fontName:String="Georgia",savedNames:[String]=[])throws->Fixture {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("font-presentation-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    let preferences=root.appendingPathComponent("FontPreferences.json")
    store.fontLibraryPreferences = .init(file:preferences)
    var project=Project(name:"A collection of type"),object=try project.makeObject(recipeID:"artboard")
    var text=ArtworkElement(kind:"text",x:12,y:12,width:120,height:60,text:"Words worth keeping.\nA second line.",fontSize:18)
    text.typography = .init();text.typography!.fontName=fontName
    if !savedNames.isEmpty {project.fontLibrary = .init(faceNames:savedNames)}
    object.artwork = .init(elements:[text]);project.objects=[object];store.engine.project=project;store.showingHome=false
    let canvas=VectorCanvasView(frame:.init(x:0,y:0,width:800,height:600)),session=store.artworkSession
    let window=NSWindow(contentRect:canvas.bounds,styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=canvas
    canvas.session=session;session.canvas=canvas;session.activate(object.id);session.choose([text.id]);canvas.synchronize()
    addTeardownBlock{@MainActor in
      canvas.finishText();window.contentView=nil;window.close();store.engine.project=nil
      try? FileManager.default.removeItem(at:root)
    }
    return .init(store:store,canvas:canvas,state:.init(session:session),preferences:preferences)
  }
  private func mount<V:View>(_ root:V,size:NSSize)throws->NSHostingView<V> {
    let host=NSHostingView(rootView:root),window=NSWindow(contentRect:.init(origin:.init(x:-10000,y:-10000),size:size),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;host.frame = .init(origin:.zero,size:size)
    window.makeKeyAndOrderFront(nil)
    addTeardownBlock{@MainActor in window.makeFirstResponder(nil);window.contentView=nil;window.close()}
    return host
  }
  private func content(_ f:Fixture,expanded:Bool,onChoose:((String)->Void)?=nil,onClose:@escaping()->Void={}) -> some View {
    FontLibraryContent(session:f.store.artworkSession,store:f.store,preferences:f.store.fontLibraryPreferences,
      state:f.state,expanded:expanded,onChoose:onChoose,onClose:onClose).labInterface()
  }
  private func settle(_ host:NSView)async throws {
    host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:50_000_000);host.layoutSubtreeIfNeeded()
  }
  @discardableResult private func capture(_ host:NSView,name:String)throws->NSBitmapImageRep {
    let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
    host.cacheDisplay(in:host.bounds,to:bitmap)
    if let path=ProcessInfo.processInfo.environment["FORM_FONT_PROOF_DIR"] {
      let folder=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent(name+".png"))
    }
    return bitmap
  }
  private func descendants(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(descendants)}
  private func stylePicker(in host:NSView)throws->NSPopUpButton {
    let controls=descendants(host).compactMap{$0 as? NSPopUpButton}.filter {
      !$0.isHiddenOrHasHiddenAncestor && $0.accessibilityIdentifier()=="font-explorer-style"
    }
    XCTAssertEqual(controls.count,1,"The mounted explorer exposes exactly one native style picker")
    return try XCTUnwrap(controls.first)
  }
  private func press(_ id:String,in host:NSView)async throws {
    let controls=descendants(host).compactMap{$0 as? NSButton}.filter {
      !$0.isHiddenOrHasHiddenAncestor && $0.accessibilityIdentifier()==id
    }
    XCTAssertEqual(controls.count,1,"The mounted view exposes exactly one native control: "+id)
    let control=try XCTUnwrap(controls.first)
    XCTAssertTrue(control.isEnabled);XCTAssertFalse(control.bounds.isEmpty)
    let center=CGPoint(x:control.bounds.midX,y:control.bounds.midY)
    let hit=host.hitTest(control.convert(center,to:host.superview))
    XCTAssertTrue(hit === control || hit?.isDescendant(of:control)==true,"The actual native control owns its visible center: "+id)
    control.performClick(nil)
  }
  private func assertUnchanged(_ f:Fixture,_ project:Project?,file:StaticString=#filePath,line:UInt=#line) {
    XCTAssertEqual(f.store.project,project,file:file,line:line)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty,file:file,line:line);XCTAssertTrue(f.store.engine.redoStack.isEmpty,file:file,line:line)
    XCTAssertTrue(f.store.fontLibraryPreferences.recent.isEmpty,file:file,line:line)
  }

  func testCompactPickerBuildsOnlyVisibleFamilySpecimensAndKeepsDocumentExact()async throws {
    let f=try fixture(),before=f.store.project
    FontLibraryCatalog.invalidate();let count=FontLibraryCatalog.diagnostics["preview_builds"] as! Int
    let host=try mount(FontBrowser(session:f.store.artworkSession,state:f.state),size:.init(width:460,height:590))
    try await settle(host);try capture(host,name:"font-picker-families")
    let built=(FontLibraryCatalog.diagnostics["preview_builds"] as! Int)-count
    XCTAssertGreaterThan(built,0);XCTAssertLessThan(built,80,"The compact picker must not build every installed face specimen")
    XCTAssertEqual(f.state.sample,"Words worth keeping. A second line.")
    assertUnchanged(f,before);XCTAssertFalse(FileManager.default.fileExists(atPath:f.preferences.path))
  }
  func testExplorerIsLazyAndSpecimenSearchColorsAndStylePreviewNeverApply()async throws {
    let f=try fixture(),before=f.store.project
    FontLibraryCatalog.invalidate();let count=FontLibraryCatalog.diagnostics["preview_builds"] as! Int
    let host=try mount(content(f,expanded:true),size:.init(width:980,height:680))
    try await settle(host);try capture(host,name:"font-explorer-initial")
    let built=(FontLibraryCatalog.diagnostics["preview_builds"] as! Int)-count
    XCTAssertGreaterThan(built,0);XCTAssertLessThan(built,80,"Offscreen explorer cards must remain lazy")
    f.state.sample="The quiet character of a sentence. 0123456789"
    f.state.query="Georgia";f.state.category = .serif;f.state.previewSize=64
    f.state.previewInk = .white;f.state.previewPaper = Color(red:0,green:0.48,blue:0.26)
    f.state.selectedFace="Georgia-BoldItalic"
    try await settle(host);try capture(host,name:"font-explorer-custom-specimen")
    f.state.scope = .project;try await settle(host)
    f.state.scope = .studio;try await settle(host)
    f.state.scope = .recent;try await settle(host)
    assertUnchanged(f,before);XCTAssertFalse(f.state.didApply)
    XCTAssertFalse(FileManager.default.fileExists(atPath:f.preferences.path))
  }
  func testExplorerStyleQueryPreviewsMatchingFaceInsteadOfPreviouslySelectedRegular()async throws {
    let f=try fixture(),before=f.store.project
    f.state.query="Georgia Bold"
    let host=try mount(content(f,expanded:true),size:.init(width:980,height:680))
    try await settle(host)
    try await press("font-family-Georgia",in:host);try await settle(host)
    XCTAssertTrue(f.state.selectedFace.contains("Bold"))
    assertUnchanged(f,before);XCTAssertFalse(f.state.didApply)
  }
  func testActualFavoriteAndProjectButtonsHaveSeparatePersistenceAndUndo()async throws {
    let f=try fixture(),before=try XCTUnwrap(f.store.project)
    f.state.query="Georgia"
    let host=try mount(content(f,expanded:true),size:.init(width:980,height:680));try await settle(host)
    try await press("font-favorite-Georgia",in:host);try await settle(host)
    XCTAssertTrue(f.store.fontLibraryPreferences.favorite("Georgia"));assertUnchanged(f,before)
    XCTAssertTrue(FontLibraryPreferences(file:f.preferences).favorite("Georgia"))
    try await press("font-project-Georgia",in:host);try await settle(host)
    XCTAssertEqual(f.store.artworkSession.projectFontNames,["Georgia"])
    XCTAssertEqual(f.store.project?.objects,before.objects);XCTAssertEqual(f.store.engine.undoStack.count,1)
    XCTAssertTrue(f.store.fontLibraryPreferences.recent.isEmpty)
    f.store.engine.undo();f.store.changed();try await settle(host)
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.fontLibraryPreferences.favorite("Georgia"))
    let redo=f.store.engine.redoStack
    try await press("font-favorite-Georgia",in:host);try await settle(host)
    XCTAssertFalse(f.store.fontLibraryPreferences.favorite("Georgia"))
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.redoStack,redo)
    try await press("font-favorite-Georgia",in:host);try await settle(host)
    XCTAssertTrue(f.store.fontLibraryPreferences.favorite("Georgia"))
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.redoStack,redo)
  }
  func testCompactActualSelectionCallsProvidedCallbackWithoutChangingAssignments()async throws {
    let f=try fixture(),before=f.store.project
    f.state.query="Baskerville"
    var chosen:[String]=[],closes=0
    let host=try mount(content(f,expanded:false,onChoose:{chosen.append($0)},onClose:{closes+=1}),size:.init(width:460,height:590))
    try await settle(host);try await press("font-family-Baskerville",in:host);try await settle(host)
    XCTAssertEqual(chosen.count,1);XCTAssertEqual(FontLibraryCatalog.face(named:try XCTUnwrap(chosen.first))?.family,"Baskerville")
    XCTAssertEqual(closes,1);XCTAssertTrue(f.state.didApply);assertUnchanged(f,before)
  }
  func testActualFooterStyleChoicePreviewsUnsavedStyleAndAppliesThatExactFace()async throws {
    let f=try fixture(),before=f.store.project
    f.state.scope = .project;f.state.query="Georgia"
    var chosen:[String]=[]
    let host=try mount(content(f,expanded:true,onChoose:{chosen.append($0)}),size:.init(width:980,height:680))
    try await settle(host)
    let picker=try stylePicker(in:host)
    picker.selectItem(withTitle:"Bold Italic")
    let action=try XCTUnwrap(picker.action)
    XCTAssertTrue(NSApp.sendAction(action,to:picker.target,from:picker));try await settle(host)
    XCTAssertEqual(f.state.selectedFace,"Georgia-BoldItalic")
    assertUnchanged(f,before);XCTAssertFalse(f.state.didApply)
    try capture(host,name:"font-explorer-explicit-style")
    try await press("font-explorer-apply",in:host);try await settle(host)
    XCTAssertEqual(chosen,["Georgia-BoldItalic"]);XCTAssertTrue(f.state.didApply);assertUnchanged(f,before)
  }
  func testInstalledAliasShowsNativeStyleAndSavedStateWithoutRewritingAuthoredNames()async throws {
    let resolved=try XCTUnwrap(NSFont(name:"Skia",size:12)).fontName
    let f=try fixture(fontName:"Skia",savedNames:["Skia","FORM Missing Face"]),before=try XCTUnwrap(f.store.project)
    XCTAssertEqual(f.state.currentFace,resolved);XCTAssertEqual(f.state.selectedFace,resolved)
    XCTAssertEqual(f.state.projectSaved,["Skia","FORM Missing Face"]);XCTAssertEqual(f.state.projectUsed,["Skia"])
    f.state.scope = .project;f.state.query="Skia"
    let host=try mount(content(f,expanded:true),size:.init(width:980,height:680));try await settle(host)
    let picker=try stylePicker(in:host)
    XCTAssertEqual(picker.selectedItem?.title,try XCTUnwrap(FontLibraryCatalog.face(named:resolved)).style)
    let button=try XCTUnwrap(descendants(host).compactMap{$0 as? NSButton}.first{$0.accessibilityIdentifier()=="font-project-"+resolved})
    XCTAssertEqual(button.accessibilityLabel(),"Remove project font "+resolved)
    assertUnchanged(f,before)
    try await press("font-project-"+resolved,in:host);try await settle(host)
    XCTAssertEqual(f.store.artworkSession.projectFontNames,["FORM Missing Face"])
    XCTAssertEqual(f.store.project?.objects,before.objects);XCTAssertEqual(f.store.engine.undoStack.count,1)
    f.store.engine.undo();f.store.changed();try await settle(host)
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.state.projectSaved,["Skia","FORM Missing Face"])
  }
  func testEmptyExplorerResultsClearStaleChoiceAndRestoreAValidApplyControl()async throws {
    let f=try fixture(),before=f.store.project
    f.state.query="Georgia"
    var choices:[String]=[]
    let host=try mount(content(f,expanded:true,onChoose:{choices.append($0)}),size:.init(width:980,height:680))
    try await settle(host)
    func applyControls()->[NSButton] {
      descendants(host).compactMap{$0 as? NSButton}.filter{
        !$0.isHiddenOrHasHiddenAncestor && $0.accessibilityIdentifier()=="font-explorer-apply"
      }
    }
    XCTAssertEqual(applyControls().count,1);XCTAssertEqual(f.state.selectedFace,"Georgia")
    f.state.query="FORM No Matching Font 938475";try await settle(host)
    XCTAssertEqual(f.state.selectedFace,"");XCTAssertNil(f.state.highlighted)
    XCTAssertTrue(applyControls().isEmpty,"An empty search must not offer the previous face for Apply")
    f.state.query="";try await settle(host)
    XCTAssertNotNil(FontLibraryCatalog.face(named:f.state.selectedFace));XCTAssertEqual(applyControls().count,1)
    f.state.scope = .studio;try await settle(host)
    XCTAssertEqual(f.state.selectedFace,"");XCTAssertNil(f.state.highlighted)
    XCTAssertTrue(applyControls().isEmpty,"An empty collection must not retain an invisible chosen face")
    assertUnchanged(f,before);XCTAssertTrue(choices.isEmpty)
    f.state.scope = .all;try await settle(host)
    let restored=f.state.selectedFace
    XCTAssertNotNil(FontLibraryCatalog.face(named:restored));XCTAssertEqual(applyControls().count,1)
    try await press("font-explorer-apply",in:host);try await settle(host)
    XCTAssertEqual(choices,[restored]);assertUnchanged(f,before)
  }
  func testFirstDirectExplorerOpenPresentsCapturedContentAndAppliesToThatProject()async throws {
    let f=try fixture(),before=try XCTUnwrap(f.store.project)
    let host=try mount(FontBrowserButton(session:f.store.artworkSession).labInterface(),size:.init(width:360,height:90))
    try await settle(host)
    let window=try XCTUnwrap(host.window)
    XCTAssertNil(window.attachedSheet)
    try await press("font-explorer-open",in:host)
    for _ in 0..<20 {
      if let content=window.attachedSheet?.contentView,
        descendants(content).contains(where:{$0.accessibilityIdentifier()=="font-explorer-style"}) {break}
      try await Task.sleep(nanoseconds:50_000_000)
    }
    let sheet=try XCTUnwrap(window.attachedSheet),content=try XCTUnwrap(sheet.contentView)
    try await settle(content)
    let picker=try stylePicker(in:content)
    XCTAssertEqual(picker.selectedItem?.representedObject as? String,"Georgia",
      "The very first direct opening must contain the current project's captured face")
    assertUnchanged(f,before)
    try capture(content,name:"font-explorer-first-direct-open")
    picker.selectItem(withTitle:"Bold Italic")
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action),to:picker.target,from:picker))
    try await settle(content);try await press("font-explorer-apply",in:content)
    for _ in 0..<20 where window.attachedSheet != nil {try await Task.sleep(nanoseconds:50_000_000)}
    XCTAssertNil(window.attachedSheet)
    XCTAssertEqual(f.store.project?.id,before.id)
    XCTAssertEqual(f.store.project?.objects.first?.artwork?.elements.first?.typography?.fontName,"Georgia-BoldItalic")
    XCTAssertEqual(f.store.engine.undoStack.count,1)
    XCTAssertEqual(f.store.fontLibraryPreferences.recent.first,"Georgia-BoldItalic")
    f.store.engine.undo();f.store.changed();XCTAssertEqual(f.store.project,before)
  }
}

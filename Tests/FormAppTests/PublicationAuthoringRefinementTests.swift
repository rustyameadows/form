import AppKit
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore
import FormGraphics

@MainActor final class PublicationAuthoringRefinementTests:XCTestCase {
  private struct Fixture {
    var store:StudioStore
    var controller:PublicationWorkspaceController
    var documentID:UUID
    var pages:[UUID]
    var firstStory:UUID
    var laterStory:UUID
  }
  private func fixture()throws->Fixture {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("publication-authoring-refinement-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    var project=Project(name:"Independent chapter sources");project.camera.azimuth=0.67;project.camera.distance=19
    try store.repository.save(project);try store.engine.open(project.id);store.showingHome=false
    let controller=store.artworkSession.publicationWorkspace
    let documentID=try XCTUnwrap(controller.create(name:"Editable chapters",width:148,height:210,pageCount:4,columns:2,gutter:7,
      margins:.init(top:12,right:12,bottom:12,left:12),facingPages:true,linkedBody:false))
    let pages=try XCTUnwrap(store.project?.publications?.first{$0.id==documentID}).pages.map(\.objectID)
    var storyIDs:[UUID]=[]
    try store.engine.edit("Prepared separate chapter sources") {value in
      for (index,text) in ["Opening chapter words stay in their sole source.","Later chapter words retain their independent source."].enumerated() {
        let page=try XCTUnwrap(value.objects.first{$0.id==pages[index]})
        let frames=try XCTUnwrap(page.artwork).elements.filter{$0.kind=="text"}.map{StoryFrameID(objectID:page.id,elementID:$0.id)}
        let id=try PublicationCommands.createStory(in:&value,frames:frames,name:index==0 ? "Opening":"Later chapter",publicationID:documentID)
        var source=try XCTUnwrap(value.textStories?.first{$0.id==id}).sourceElement;source.text=text
        try PublicationCommands.setSource(in:&value,storyID:id,source:source);storyIDs.append(id)
      }
      let cover=try XCTUnwrap(value.objects.firstIndex{$0.id==pages[2]})
      value.objects[cover].artwork?.elements=[.init(kind:"text",x:12,y:20,width:124,height:30,text:"An independent cover",fontSize:18)]
    }
    store.changed()
    addTeardownBlock{@MainActor in store.artworkSession.canvas?.finishText();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return .init(store:store,controller:controller,documentID:documentID,pages:pages,firstStory:storyIDs[0],laterStory:storyIDs[1])
  }
  private func story(_ id:UUID,in project:Project)throws->TextStory {try XCTUnwrap(project.textStories?.first{$0.id==id})}
  private func pressThumbnail(_ pageID:UUID,in fixture:Fixture)throws {
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:260,height:700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:PublicationNavigator(session:fixture.store.artworkSession,controller:fixture.controller,maxHeight:680).environmentObject(fixture.store))
    host.sizingOptions=[];window.contentView=host;host.frame=window.contentView!.bounds
    defer{window.contentView=nil;window.close()}
    host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.05))
    func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    let button=try XCTUnwrap(descendants(host).compactMap{$0 as? PublicationPageNativeButton}.first{$0.accessibilityIdentifier()=="publication-page-"+pageID.uuidString})
    let point=try XCTUnwrap(button.superview).convert(CGPoint(x:button.bounds.midX,y:button.bounds.midY),from:button)
    XCTAssertTrue(button.hitTest(point) === button);XCTAssertTrue(button.accessibilityPerformPress())
    XCTAssertEqual(fixture.controller.currentPageID,pageID)
  }
  func testNativeThumbnailThenAddPageExtendsOnlyThatChapterKeepsRegularColumnsAndOneUndo()throws {
    let f=try fixture(),store=f.store,session=store.artworkSession
    try pressThumbnail(f.pages[1],in:f)
    XCTAssertTrue(session.selection.isEmpty,"A real page tile selects its page, without requiring a text-layer click")
    XCTAssertEqual(f.controller.activeStory?.id,f.laterStory)
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    let opening=try story(f.firstStory,in:before),chapter=try story(f.laterStory,in:before)
    let added=try XCTUnwrap(f.controller.addPage()),after=try XCTUnwrap(store.project)
    XCTAssertEqual(store.engine.undoStack.count,undo+1);XCTAssertEqual(after.camera,before.camera)
    XCTAssertEqual(try story(f.firstStory,in:after),opening)
    let updated=try story(f.laterStory,in:after)
    XCTAssertEqual(updated.sourceElement,chapter.sourceElement);XCTAssertEqual(updated.frames.count,chapter.frames.count+2)
    let page=try XCTUnwrap(after.objects.first{$0.id==added}),frames=try XCTUnwrap(page.artwork).elements
    XCTAssertEqual(frames.count,2);XCTAssertTrue(frames.allSatisfy{$0.storyFrame?.storyID==f.laterStory && $0.text.isEmpty && $0.textRuns==nil})
    XCTAssertEqual(frames[0].x,12,accuracy:0.0001);XCTAssertEqual(frames[1].x-frames[0].x-frames[0].width,7,accuracy:0.0001)
    XCTAssertEqual(after.publications?.first{$0.id==f.documentID}?.pages[2].objectID,added)
    XCTAssertEqual(after.objects.filter{$0.id != added},before.objects,"Adding capacity must not copy text into, or rewrite, existing pages")
    try store.engine.flush();let reopened=try store.repository.load(after.id)
    XCTAssertEqual(reopened.objects,after.objects);XCTAssertEqual(reopened.publications,after.publications);XCTAssertEqual(reopened.textStories,after.textStories)
    store.engine.undo();f.controller.reconcile();XCTAssertEqual(store.project,before)
    store.engine.redo();f.controller.reconcile();XCTAssertEqual(store.project?.objects,after.objects);XCTAssertEqual(store.project?.textStories,after.textStories)
  }
  func testExplicitSelectedStoryWinsOnAMultiStoryPageAndUnselectedPageDoesNotGuess()throws {
    let f=try fixture(),store=f.store;var captionID:UUID?,frameID:UUID?
    try store.engine.edit("Prepared a separate caption on the chapter page") {project in
      let index=try XCTUnwrap(project.objects.firstIndex{$0.id==f.pages[1]})
      let caption=ArtworkElement(kind:"text",x:12,y:5,width:80,height:5,text:"A separately authored caption.",fontSize:8)
      frameID=caption.id;project.objects[index].artwork!.elements.append(caption)
      captionID=try PublicationCommands.createStory(in:&project,frames:[.init(objectID:f.pages[1],elementID:caption.id)],name:"Caption",publicationID:f.documentID)
    }
    store.changed();f.controller.focusPage(f.pages[1])
    XCTAssertNil(f.controller.activeStory,"Two chapter sources on the same page need an explicit text choice")
    store.artworkSession.choose([try XCTUnwrap(frameID)])
    XCTAssertEqual(f.controller.activeStory?.id,captionID)
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count,caption=try story(XCTUnwrap(captionID),in:before)
    let added=try XCTUnwrap(f.controller.addPage()),after=try XCTUnwrap(store.project)
    XCTAssertEqual(try story(f.firstStory,in:after),try story(f.firstStory,in:before))
    XCTAssertEqual(try story(f.laterStory,in:after),try story(f.laterStory,in:before))
    let updated=try story(caption.id,in:after);XCTAssertEqual(updated.sourceElement,caption.sourceElement)
    XCTAssertEqual(updated.frames.filter{$0.objectID==added}.count,1)
    XCTAssertEqual(store.engine.undoStack.count,undo+1);store.engine.undo();f.controller.reconcile();XCTAssertEqual(store.project,before)
  }
  func testCoverAndExplicitUnlinkedPageNeverAcquireAnotherChaptersWordsOrCapacity()throws {
    let f=try fixture(),store=f.store
    f.controller.focusPage(f.pages[2]);XCTAssertNil(f.controller.activeStory)
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    let added=try XCTUnwrap(f.controller.addPage()),after=try XCTUnwrap(store.project)
    XCTAssertEqual(after.textStories,before.textStories)
    XCTAssertTrue(try XCTUnwrap(after.objects.first{$0.id==added}?.artwork).elements.allSatisfy{$0.storyFrame==nil && $0.text.isEmpty})
    XCTAssertEqual(store.engine.undoStack.count,undo+1);store.engine.undo();f.controller.reconcile();XCTAssertEqual(store.project,before)
    f.controller.focusPage(f.pages[1]);let unlinked=try XCTUnwrap(f.controller.addPage(linkStory:false)),current=try XCTUnwrap(store.project)
    XCTAssertEqual(current.textStories,before.textStories)
    let frames=try XCTUnwrap(current.objects.first{$0.id==unlinked}?.artwork).elements
    XCTAssertEqual(frames.count,2);XCTAssertTrue(frames.allSatisfy{$0.storyFrame==nil && $0.text.isEmpty})
  }
  func testNativeAddCapacityKeepsTransparentProfiledKOnlyStockIntentWithoutCopyingPageMetadata()throws {
    let f=try fixture(),store=f.store
    let assets=store.repository.url(for:try XCTUnwrap(store.project).id).appendingPathComponent("Assets")
    let profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"));try profile.store(in:assets)
    try store.engine.edit("Prepared transparent source pages on colored K-only stock") {project in
      let ink=try SwatchCommands.save(in:&project,name:"True process K",color:"#1A1919",printInk:.init(kind:.processCMYK,components:.init(0,0,0,1),profile:profile.reference))
      for index in project.objects.indices where f.pages.contains(project.objects[index].id) {
        var artwork=try XCTUnwrap(project.objects[index].artwork)
        artwork.background="#1A1919";artwork.backgroundOpacity=0;artwork.backgroundSwatchID=ink;artwork.outputColorProfile=profile.reference
        artwork.bleed=0;artwork.safeInset=9;artwork.unit = .mm;artwork.language="en"
        artwork.gridSpacing=2.5;artwork.showGrid=false;artwork.showGuides=true;artwork.snapEnabled=true;artwork.nudge=0.2
        for element in artwork.elements.indices {artwork.elements[element].color="#1A1919";artwork.elements[element].fillSwatchID=ink}
        project.objects[index].artwork=artwork
      }
      for id in [f.firstStory,f.laterStory] {
        var source=try story(id,in:project).sourceElement;source.color="#1A1919";source.fillSwatchID=ink
        try PublicationCommands.setSource(in:&project,storyID:id,source:source)
      }
      var document=try XCTUnwrap(project.publications?.first{$0.id==f.documentID})
      document.pages[0].label="A chosen opening";document.pages[0].numberOverride=7;document.pages[0].chapterTitle="Opening chapter";document.pages[0].masterIDs=[]
      try PublicationCommands.setPublication(in:&project,document:document)
      let stock=PaperStock(thicknessMM:0.2,profile:.init(color:"#D3BA76")),entries=document.pages
      var definition=SheetAssemblyDefinition(publicationID:f.documentID,stock:stock)
      definition.parentSheets=[.init(frontPageIDs:[entries[3].id,entries[0].id],backPageIDs:[entries[1].id,entries[2].id],stock:stock,sizeMM:.init(296,210),printIntent:.blackOnly)]
      _=try SheetAssemblyCommands.create(in:&project,definition:definition)
    }
    store.changed();f.controller.focusPage(f.pages[0])
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count,source=try XCTUnwrap(before.objects.first{$0.id==f.pages[0]})
    XCTAssertEqual(try store.publicationPreflightReport(f.documentID,layout:.booklet)["can_export"] as? Bool,true)
    let added=try XCTUnwrap(f.controller.addPage()),after=try XCTUnwrap(store.project)
    let page=try XCTUnwrap(after.objects.first{$0.id==added}),artwork=try XCTUnwrap(page.artwork),inherited=try XCTUnwrap(source.artwork)
    XCTAssertEqual(artwork.backgroundOpacity,0);XCTAssertEqual(artwork.background,inherited.background);XCTAssertEqual(artwork.backgroundSwatchID,inherited.backgroundSwatchID)
    XCTAssertEqual(artwork.outputColorProfile,profile.reference);XCTAssertEqual(artwork.bleed,0);XCTAssertEqual(artwork.safeInset,9)
    XCTAssertEqual(artwork.unit,inherited.unit);XCTAssertEqual(artwork.language,inherited.language);XCTAssertEqual(artwork.gridSpacing,2.5)
    XCTAssertEqual(artwork.showGrid,false);XCTAssertEqual(artwork.showGuides,true);XCTAssertEqual(artwork.snapEnabled,true);XCTAssertEqual(artwork.nudge,0.2)
    XCTAssertNotEqual(artwork.canvasPosition,inherited.canvasPosition);XCTAssertNotEqual(page.id,source.id);XCTAssertNotEqual(page.designID,source.designID)
    XCTAssertTrue(Set(artwork.elements.map(\.id)).isDisjoint(with:Set(inherited.elements.map(\.id))))
    XCTAssertTrue(artwork.elements.allSatisfy{$0.text.isEmpty && $0.textRuns==nil && $0.storyFrame?.storyID==f.firstStory})
    let document=try XCTUnwrap(after.publications?.first{$0.id==f.documentID}),entry=try XCTUnwrap(document.pages.first{$0.objectID==added})
    XCTAssertNil(entry.label);XCTAssertNil(entry.numberOverride);XCTAssertNil(entry.chapterTitle);XCTAssertNil(entry.masterIDs)
    let assembly=try XCTUnwrap(after.objects.first{$0.sheetAssembly?.publicationID==f.documentID})
    XCTAssertEqual(try after.parentSheet(forPageObjectID:added,in:assembly)?.printIntent,.blackOnly)
    let report=try store.publicationPreflightReport(f.documentID,layout:.booklet)
    XCTAssertEqual(report["can_export"] as? Bool,true,"Adding empty linked capacity must not paint the colored substrate or lose its K-only output intent: \(report)")
    XCTAssertEqual(store.engine.undoStack.count,undo+1)
    XCTAssertEqual(try story(f.firstStory,in:after).sourceElement,try story(f.firstStory,in:before).sourceElement)
    XCTAssertEqual(try story(f.laterStory,in:after),try story(f.laterStory,in:before))
    try store.engine.flush();let reopened=try store.repository.load(after.id)
    XCTAssertEqual(reopened.objects,after.objects);XCTAssertEqual(reopened.publications,after.publications);XCTAssertEqual(reopened.textStories,after.textStories)
    store.engine.undo();f.controller.reconcile();XCTAssertEqual(store.project,before)
  }
  func testIrregularSourceFramesFallBackWithoutRewritingTheAuthoredLayout()throws {
    let f=try fixture(),store=f.store
    try store.engine.edit("Prepared intentionally irregular chapter frames") {project in
      let index=try XCTUnwrap(project.objects.firstIndex{$0.id==f.pages[1]})
      project.objects[index].artwork!.elements[1].y+=20
    }
    store.changed();f.controller.focusPage(f.pages[1]);let before=try XCTUnwrap(store.project)
    let added=try XCTUnwrap(f.controller.addPage()),after=try XCTUnwrap(store.project)
    XCTAssertEqual(after.objects.filter{$0.id != added},before.objects)
    let frames=try XCTUnwrap(after.objects.first{$0.id==added}?.artwork).elements
    XCTAssertEqual(frames.count,1);XCTAssertEqual(frames[0].storyFrame?.storyID,f.laterStory)
    XCTAssertEqual(try story(f.laterStory,in:after).sourceElement,try story(f.laterStory,in:before).sourceElement)
  }
}

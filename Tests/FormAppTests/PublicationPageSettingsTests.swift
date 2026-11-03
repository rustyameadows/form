import AppKit
import XCTest
@testable import FormApp
@testable import FormCore

@MainActor final class PublicationPageSettingsTests:XCTestCase {
  private func fixture()throws->(StudioStore,PublicationWorkspaceController,PublicationPageSettingsTarget) {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("publication-page-settings-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    var project=Project(name:"Native page metadata")
    let id=try PublicationCommands.createPublication(in:&project,name:"Shared source document",pages:[])
    var frames:[StoryFrameID]=[]
    for _ in 0..<4 {frames += try PublicationCommands.addPage(in:&project,publicationID:id,width:148,height:210,columns:2,gutter:8).1}
    let storyID=try PublicationCommands.createStory(in:&project,frames:frames,name:"Original chapter",publicationID:id)
    var source=project.textStories!.first{$0.id==storyID}!.sourceElement
    source.text="One rich source, café and an emoji 🌿, stays in its original frames."
    var typography=Typography();typography.fontName="HelveticaNeue-Bold"
    source.textRuns=[.init(location:0,length:3,typography:typography,fontSize:12,color:"#203040")]
    try PublicationCommands.setSource(in:&project,storyID:storyID,source:source)
    var masters:[PublicationMaster]=[]
    for side in [PublicationMasterSide.all,.recto] {
      var object=try project.makeObject(recipeID:"artboard",name:"Canonical running source",parameters:["width":148,"depth":210])
      object.artwork = .init(elements:[.init(kind:"text",x:12,y:12,width:100,height:15,text:"{{page.number}}",fontSize:10)])
      project.objects.append(object);masters.append(.init(name:side.rawValue+" master",sourceObjectID:object.id,side:side))
    }
    var document=project.publications!.first{$0.id==id}!;document.layout = .init();document.masters=masters
    try PublicationCommands.setPublication(in:&project,document:document)
    project.camera.azimuth=0.87;project.camera.distance=19
    store.engine.project=project;store.showingHome=false
    let controller=store.artworkSession.publicationWorkspace;controller.open(id)
    let target=PublicationPageSettingsTarget(projectID:project.id,documentID:id,page:document.pages[0])
    addTeardownBlock{@MainActor in store.artworkSession.canvas?.finishText();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return(store,controller,target)
  }
  func testSelectedPageMetadataUsesSharedSourceAndOneUndoWithoutChangingArtworkOrCamera()throws {
    let(store,controller,target)=try fixture(),before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    let document=try XCTUnwrap(before.publications?.first),master=try XCTUnwrap(document.masters?.last)
    let tableSelection:Set<UUID>=[before.objects.last!.id];store.engine.selection=tableSelection
    XCTAssertTrue(target.update(using:controller){page in page.label="Title page";page.chapterTitle="A new running chapter";page.numberOverride=7;page.masterIDs=[master.id]})
    let after=try XCTUnwrap(store.project),changed=try XCTUnwrap(after.publications?.first?.pages.first)
    XCTAssertEqual(changed.label,"Title page");XCTAssertEqual(changed.chapterTitle,"A new running chapter");XCTAssertEqual(changed.numberOverride,7);XCTAssertEqual(changed.masterIDs,[master.id])
    XCTAssertEqual(after.objects,before.objects);XCTAssertEqual(after.textStories,before.textStories);XCTAssertEqual(after.camera,before.camera)
    XCTAssertEqual(after.publications?.first?.pages.dropFirst(),before.publications?.first?.pages.dropFirst())
    XCTAssertEqual(after.publications?.first?.masters,document.masters);XCTAssertEqual(after.publications?.first?.layout,document.layout)
    XCTAssertEqual(store.engine.selection,tableSelection)
    XCTAssertEqual(store.engine.undoStack.count,undo+1)
    store.engine.undo();XCTAssertEqual(store.project,before)
    store.engine.redo();XCTAssertEqual(store.project,after)
  }
  func testAutomaticEmptyAndExplicitMastersAndChapterInheritanceRemainDistinct()throws {
    let(store,controller,target)=try fixture(),before=try XCTUnwrap(store.project),master=try XCTUnwrap(before.publications?.first?.masters?.last)
    XCTAssertEqual(before.publications?.first?.appliedMasters(for:target.objectID).count,2)
    XCTAssertTrue(target.update(using:controller){$0.masterIDs=[];$0.chapterTitle=""})
    XCTAssertEqual(store.project?.publications?.first?.pages[0].masterIDs,[])
    XCTAssertEqual(store.project?.publications?.first?.appliedMasters(for:target.objectID).count,0)
    XCTAssertEqual(store.project?.publications?.first?.pages[0].chapterTitle,"")
    XCTAssertTrue(target.update(using:controller){$0.masterIDs=[master.id];$0.chapterTitle="Own chapter"})
    XCTAssertEqual(store.project?.publications?.first?.appliedMasters(for:target.objectID).map(\.id),[master.id])
    XCTAssertTrue(target.update(using:controller){$0.masterIDs=nil;$0.chapterTitle=nil;$0.numberOverride=nil;$0.label=nil})
    XCTAssertNil(store.project?.publications?.first?.pages[0].masterIDs);XCTAssertNil(store.project?.publications?.first?.pages[0].chapterTitle)
    XCTAssertEqual(store.project?.publications?.first?.appliedMasters(for:target.objectID).count,2)
    XCTAssertEqual(store.project?.objects,before.objects);XCTAssertEqual(store.project?.textStories,before.textStories)
  }
  func testDocumentFieldsKeepTheirRenderedProjectWhenImportedCopySharesDocumentIDs()throws {
    let(store,controller,pageTarget)=try fixture(),original=try XCTUnwrap(store.project)
    let target=PublicationDocumentSettingsTarget(projectID:original.id,documentID:pageTarget.documentID)
    var imported=original;imported.id=UUID();store.engine.project=imported
    let undo=store.engine.undoStack.count;var called=false
    XCTAssertFalse(target.update(using:controller){called=true;$0.name="Stale name";$0.margins.top=49})
    XCTAssertFalse(called);XCTAssertEqual(store.project,imported);XCTAssertEqual(store.engine.undoStack.count,undo)
    store.engine.project=original
    XCTAssertTrue(target.update(using:controller){$0.name="Current document"})
    XCTAssertEqual(store.project?.publications?.first?.name,"Current document")
    XCTAssertEqual(store.project?.objects,original.objects);XCTAssertEqual(store.project?.textStories,original.textStories);XCTAssertEqual(store.project?.camera,original.camera)
    XCTAssertEqual(store.engine.undoStack.count,undo+1)
    store.engine.undo();XCTAssertEqual(store.project,original)
  }
  func testCapturedTargetRejectsImportedProjectAndReplacedLogicalPageWithoutWrites()throws {
    let(store,controller,target)=try fixture(),original=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    var imported=original;imported.id=UUID();store.engine.project=imported
    var called=false
    XCTAssertFalse(target.update(using:controller){called=true;$0.label="Wrong imported copy"})
    XCTAssertFalse(called);XCTAssertEqual(store.project,imported);XCTAssertEqual(store.engine.undoStack.count,undo)
    var replaced=original;replaced.publications![0].pages[0].id=UUID();store.engine.project=replaced
    XCTAssertFalse(target.update(using:controller){called=true;$0.label="Reused object, new page"})
    XCTAssertFalse(called);XCTAssertEqual(store.project,replaced);XCTAssertEqual(store.engine.undoStack.count,undo)
    store.engine.project=original
    XCTAssertFalse(target.update(using:controller){$0.numberOverride=0})
    XCTAssertEqual(store.project,original);XCTAssertEqual(store.engine.undoStack.count,undo)
  }
}

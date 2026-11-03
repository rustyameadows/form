import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class PublicationReliabilityTests:XCTestCase {
  private func fixture()throws->(StudioStore,UUID,UUID,UUID,UUID) {
    _=NSApplication.shared
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("publication-reliability-"+UUID().uuidString)
    let store=StudioStore(repository:try .init(root:folder),seedLibrary:false)
    var project=Project(name:"Publication source navigation")
    var page=try project.makeObject(recipeID:"artboard",name:"Cover",parameters:["width":148,"depth":210])
    let group=ArtworkElement(kind:"group",x:0,y:0,width:148,height:50)
    var title=ArtworkElement(kind:"text",x:12,y:12,width:120,height:1,text:"A masthead that needs space",fontSize:36)
    title.parentID=group.id
    page.artwork = .init(elements:[group,title],bleed:0)
    var master=try project.makeObject(recipeID:"artboard",name:"Running furniture",parameters:["width":148,"depth":210])
    let masterTitle=ArtworkElement(kind:"text",x:12,y:20,width:120,height:1,text:"Master title",fontSize:30)
    master.artwork = .init(elements:[masterTitle],bleed:0)
    project.objects=[page,master]
    let publication=try PublicationCommands.createPublication(in:&project,name:"Source identities",pages:[page.id])
    var document=project.publications![0]
    document.masters=[.init(name:"Header",sourceObjectID:master.id)]
    try PublicationCommands.setPublication(in:&project,document:document)
    store.engine.project=project;store.showingHome=false;store.mode = .artwork
    store.artworkSession.activate(page.id)
    addTeardownBlock{@MainActor in
      store.artworkSession.canvas?.finishText();store.bridge.stop();store.engine.project=nil
      try? FileManager.default.removeItem(at:folder)
    }
    return(store,publication,page.id,title.id,masterTitle.id)
  }

  func testPreflightLocatesCanonicalNestedAndMasterTextWithoutEditingSource()throws {
    let(store,publication,pageID,titleID,masterTitleID)=try fixture(),before=try XCTUnwrap(store.project)
    let report=try store.publicationPreflightReport(publication,layout:.pages)
    XCTAssertEqual(report["can_export"] as? Bool,false)
    let issues=try XCTUnwrap(report["issues"] as? [[String:Any]])
    let controller=store.artworkSession.publicationWorkspace
    for id in [titleID,masterTitleID] {
      let issue=try XCTUnwrap(issues.first{$0["element_id"] as? String==id.uuidString && $0["code"] as? String=="overset"})
      let target=try XCTUnwrap(PublicationPreflightTarget(issue:issue,projectID:before.id,publicationID:publication))
      XCTAssertTrue(controller.focusPreflightIssue(target))
      XCTAssertEqual(store.artworkSession.objectID,target.objectID)
      XCTAssertEqual(store.artworkSession.selection,[id])
      XCTAssertEqual(store.artworkSession.scopeID,before.objects.first{$0.id==target.objectID}?.artwork?.elements.first{$0.id==id}?.parentID)
      XCTAssertEqual(target.affectedPageObjectID,pageID)
      XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    }
    let source=try XCTUnwrap(before.objects.first{$0.artwork?.elements.contains{$0.id==masterTitleID}==true})
    XCTAssertEqual(store.artworkSession.objectID,source.id,"Master errors must open editable furniture, never a derived page clone")
  }

  func testStaleIssueDoesNotChangeProjectOrSelection()throws {
    let(store,publication,pageID,titleID,_)=try fixture(),before=try XCTUnwrap(store.project)
    let issue:[String:Any]=["object_id":pageID.uuidString,"element_id":titleID.uuidString,"page_object_id":pageID.uuidString]
    let target=try XCTUnwrap(PublicationPreflightTarget(issue:issue,projectID:before.id,publicationID:publication))
    let controller=store.artworkSession.publicationWorkspace
    store.engine.project?.objects[0].artwork?.elements.removeAll{$0.id==titleID}
    let changed=store.project,active=store.artworkSession.objectID,selection=store.artworkSession.selection
    XCTAssertFalse(controller.focusPreflightIssue(target))
    XCTAssertEqual(store.project,changed);XCTAssertEqual(store.artworkSession.objectID,active);XCTAssertEqual(store.artworkSession.selection,selection)
    var imported=before;imported.id=UUID();store.engine.project=imported
    XCTAssertFalse(controller.focusPreflightIssue(target),"An imported source with equal page IDs belongs to a different project")
    XCTAssertEqual(store.project,imported);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testComponentIssueOpensEditableSourceAndRetainsReturnOccurrence()throws {
    let(store,publication,_,_,masterTitleID)=try fixture()
    var project=try XCTUnwrap(store.project),master=project.objects[1]
    let title=try XCTUnwrap(master.artwork?.elements.first{$0.id==masterTitleID})
    var source=try project.makeObject(recipeID:"artboard",name:"Shared header")
    source.componentDefinition=true;source.artwork = .init(elements:[title])
    var instance=ArtworkElement(kind:"group",x:0,y:0,width:source.artworkSize.x,height:source.artworkSize.y)
    instance.component = .init(sourceObjectID:source.id)
    master.artwork?.elements=[instance];project.objects[1]=master;project.objects.append(source)
    store.engine.project=project
    let report=try store.publicationPreflightReport(publication,layout:.pages)
    let issue=try XCTUnwrap((report["issues"] as? [[String:Any]])?.first{$0["element_id"] as? String==masterTitleID.uuidString})
    let target=try XCTUnwrap(PublicationPreflightTarget(issue:issue,projectID:project.id,publicationID:publication))
    XCTAssertTrue(store.artworkSession.publicationWorkspace.focusPreflightIssue(target))
    XCTAssertEqual(store.artworkSession.objectID,source.id)
    XCTAssertEqual(store.artworkSession.selection,[title.id])
    XCTAssertEqual(store.artworkSession.componentReturn?.objectID,master.id)
    XCTAssertEqual(store.artworkSession.componentReturn?.instanceID,instance.id)
    XCTAssertTrue(store.artworkSession.frames.contains{$0.object.id==source.id})
    store.artworkSession.returnToComponent()
    XCTAssertEqual(store.artworkSession.objectID,master.id);XCTAssertEqual(store.artworkSession.selection,[instance.id])
    XCTAssertEqual(store.project,project);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testContextSeparatesLogicalPageArtboardAndMasterWithoutOpeningNavigator()throws {
    let(store,publication,pageID,titleID,masterTitleID)=try fixture(),before=try XCTUnwrap(store.project)
    store.artworkSession.choose([titleID])
    func publicationContext()throws->[String:Any] {
      let context=try XCTUnwrap(try store.engine.call("form_get_context") as? [String:Any])
      return try XCTUnwrap((context["canvas"] as? [String:Any])?["publication"] as? [String:Any])
    }
    var value=try publicationContext()
    XCTAssertEqual(value["publication_id"] as? String,publication.uuidString)
    XCTAssertEqual(value["page_object_id"] as? String,pageID.uuidString)
    XCTAssertEqual(value["publication_page_id"] as? String,before.publications![0].pages[0].id.uuidString)
    XCTAssertNotEqual(value["publication_page_id"] as? String,value["page_object_id"] as? String)
    let master=try XCTUnwrap(before.objects.first{$0.artwork?.elements.contains{$0.id==masterTitleID}==true})
    store.artworkSession.activate(master.id);store.artworkSession.choose([masterTitleID]);value=try publicationContext()
    XCTAssertEqual(value["master_source_object_id"] as? String,master.id.uuidString)
    XCTAssertTrue(value["publication_page_id"] is NSNull)
    XCTAssertFalse(store.artworkSession.publicationWorkspace.isVisible)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    store.engine.project?.publications?[0].masters?.append(.init(name:"Second occurrence",sourceObjectID:master.id))
    value=try publicationContext()
    XCTAssertTrue(value["master_id"] is NSNull,"Selecting shared master artwork cannot identify an arbitrary application")
    XCTAssertEqual(value["master_count"] as? Int,2)
    XCTAssertEqual((value["master_ids"] as? [String])?.count,2)
  }

  func testNativeOutputSettingsKeepPreflightAndExportIntentEquivalent()throws {
    let id=UUID(),physical=UUID()
    var settings=PublicationOutputSettings();settings.layout = .booklet;settings.physicalObjectID=physical
    settings.inkOutput="preview";settings.padBooklet=true;settings.dpi=600;settings.outlineText=true;settings.allowOverset=true
    let preflight=settings.arguments(publicationID:id,preflight:true),export=settings.arguments(publicationID:id,preflight:false)
    for key in ["publication_id","physical_object_id","ink_output"] {XCTAssertEqual(preflight[key] as? String,export[key] as? String)}
    XCTAssertEqual(preflight["output_layout"] as? String,export["layout"] as? String)
    XCTAssertEqual(preflight["pad_to_multiple_of_four"] as? Bool,true)
    XCTAssertNil(preflight["allow_overset"],"Preflight always exposes text loss, even when export is explicitly allowed")
    XCTAssertEqual(export["allow_overset"] as? Bool,true);XCTAssertEqual(export["outline_text"] as? Bool,true);XCTAssertEqual(export["dpi"] as? Double,600)
  }
}

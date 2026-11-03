import AppKit
import Foundation
import FormCore
import XCTest
@testable import FormApp

@MainActor final class PublicationLinkedViewTests:XCTestCase {
  func testCanonicalPageStoryAndMasterChangesInvalidateAndRefreshLinkedAssemblyWithoutExtraUndo()async throws {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("publication-linked-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:folder)}
    let repository=try ProjectRepository(root:folder)
    var project=Project(name:"Canonical linked assembly"),frames:[StoryFrameID]=[]
    for index in 0..<2 {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index+1)",parameters:["width":100,"depth":140])
      let text=ArtworkElement(kind:"text",x:10,y:10,width:80,height:110,text:index==0 ? "Original body":"",fontSize:12)
      page.artwork = .init(elements:[text]);project.objects.append(page);frames.append(.init(objectID:page.id,elementID:text.id))
    }
    let story=try PublicationCommands.createStory(in:&project,frames:frames)
    let publication=try PublicationCommands.createPublication(in:&project,name:"Publication",pages:project.objects.map(\.id))
    var master=try project.makeObject(recipeID:"artboard",name:"Running source",parameters:["width":100,"depth":140])
    master.artwork = .init(elements:[.init(kind:"text",x:10,y:125,text:"Footer {{page.number}}",fontSize:9)]);project.objects.append(master)
    var document=project.publications![0];document.masters=[.init(sourceObjectID:master.id)]
    try PublicationCommands.setPublication(in:&project,document:document)
    let assemblyID=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,openingDegrees:180,activeSpread:1))
    let assembly=project.objects.first{$0.id==assemblyID}!
    var live=ArtworkElement(kind:"image",x:0,y:0,width:50,height:50,asset:"old.png")
    live.objectView = .init(sourceID:assemblyID,style:"rendered",linked:true)
    var frozen=live;frozen.id=UUID();frozen.asset="frozen.png";frozen.objectView?.linked=false
    var review=try project.makeObject(recipeID:"artboard",name:"Linked review",parameters:["width":100,"depth":140])
    review.artwork = .init(elements:[live,frozen]);project.objects.append(review)
    let state=LinkedObjectViewRenderer.state(assembly,in:project)
    var pageEdit=project;pageEdit.objects[0].artwork?.background="#A0B0C0"
    XCTAssertNotEqual(LinkedObjectViewRenderer.state(assembly,in:pageEdit),state)
    var storyEdit=project;storyEdit.textStories![0].text+=" Changed"
    XCTAssertNotEqual(LinkedObjectViewRenderer.state(assembly,in:storyEdit),state)
    var masterEdit=project;masterEdit.objects[masterEdit.objects.firstIndex{$0.id==master.id}!].artwork!.elements[0].text="New footer {{page.number}}"
    XCTAssertNotEqual(LinkedObjectViewRenderer.state(assembly,in:masterEdit),state)
    XCTAssertFalse(LinkedObjectViewRenderer.hasCycle(from:assemblyID,project:project))
    let store=StudioStore(repository:repository,seedLibrary:false);store.engine.project=project
    let rendered=expectation(description:"changed canonical source rendered")
    var calls=0
    let coordinator=LinkedObjectViewRenderer(store:store){source,snapshot,_,_,_,_,_ in
      calls+=1;XCTAssertEqual(source.id,assemblyID);XCTAssertEqual(snapshot.textStories?.first{$0.id==story}?.text,"Original body Changed")
      rendered.fulfill();return Data("current-full-source".utf8)
    }
    defer{coordinator.reset();store.linkedObjectViews.reset();store.solids.reset()}
    coordinator.synchronize(project)
    try store.engine.edit("Edit original story"){candidate in candidate.textStories![0].text+=" Changed"}
    let undo=store.engine.undoStack.count
    XCTAssertEqual(store.project?.objects.first{$0.id==review.id}?.artwork?.elements[0].objectView?.renderPending,true)
    XCTAssertNil(store.project?.objects.first{$0.id==review.id}?.artwork?.elements[1].objectView?.renderPending)
    coordinator.synchronize(store.project)
    await fulfillment(of:[rendered],timeout:5)
    for _ in 0..<500 {
      if store.project?.objects.first(where:{$0.id==review.id})?.artwork?.elements[0].objectView?.renderPending==false {break}
      try await Task.sleep(nanoseconds:2_000_000)
    }
    let refreshed=try XCTUnwrap(store.project?.objects.first{$0.id==review.id}?.artwork)
    XCTAssertEqual(refreshed.elements[0].objectView?.renderPending,false);XCTAssertNotEqual(refreshed.elements[0].asset,"old.png")
    XCTAssertEqual(refreshed.elements[1].asset,"frozen.png");XCTAssertEqual(calls,1);XCTAssertEqual(store.engine.undoStack.count,undo)
    store.engine.undo();XCTAssertEqual(store.project,project)
  }
}

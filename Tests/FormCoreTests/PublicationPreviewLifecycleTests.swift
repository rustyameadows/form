import Foundation
import XCTest
@testable import FormCore

final class PublicationPreviewLifecycleTests:XCTestCase {
  private func fixture(first:PublicationPageSide = .recto,explicit:Bool=false)throws->(OperationEngine,UUID,UUID,UUID) {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("publication-preview-"+UUID().uuidString)
    let engine=OperationEngine(repository:try .init(root:folder));var project=Project(name:"Source and preview lifecycle"),frames:[StoryFrameID]=[]
    for index in 0..<4 {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index+1)",parameters:["width":100,"depth":140])
      let text=ArtworkElement(kind:"text",x:10,y:10,width:80,height:120,text:index==0 ? "All original source words":"",fontSize:12)
      page.artwork = .init(elements:[text]);frames.append(.init(objectID:page.id,elementID:text.id));project.objects.append(page)
    }
    let story=try PublicationCommands.createStory(in:&project,frames:frames)
    let publication=try PublicationCommands.createPublication(in:&project,name:"Publication",pages:project.objects.map(\.id))
    var document=project.publications![0];document.layout = .init(firstPageSide:first);try PublicationCommands.setPublication(in:&project,document:document)
    let leaves=explicit ? document.leafPairs().map{SheetAssemblyLeaf(id:$0.id,frontPageID:$0.front?.id,backPageID:$0.back?.id)}:nil
    let assembly=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,openingDegrees:180,activeSpread:document.leafPairs().count,leaves:leaves))
    engine.project=project;addTeardownBlock{try? FileManager.default.removeItem(at:folder)}
    return(engine,publication,assembly,story)
  }
  func testRemovingImplicitPagesClampsPreviewInSameUndoAndPreservesAllWords()throws {
    let (engine,publication,assembly,story)=try fixture(),before=try XCTUnwrap(engine.project)
    let pages=Array(before.publications![0].pages.suffix(2)).map{ $0.objectID.uuidString }
    _ = try engine.call("form_publication",arguments:["command":"remove","publication_id":publication.uuidString,"page_ids":pages,"delete_objects":true])
    let after=try XCTUnwrap(engine.project)
    XCTAssertEqual(after.publications![0].pages.count,2);XCTAssertEqual(after.objects.first{$0.id==assembly}?.sheetAssembly?.activeSpread,1)
    XCTAssertEqual(after.textStories?.first{$0.id==story}?.sourceElement,before.textStories?.first{$0.id==story}?.sourceElement)
    XCTAssertEqual(engine.undoStack.count,1);engine.undo();XCTAssertEqual(engine.project,before)
    engine.redo();XCTAssertEqual(engine.project,after)
  }
  func testGenericPageDeletionReconcilesImplicitPreviewAndUndo()throws {
    let (engine,_,assembly,story)=try fixture(),before=try XCTUnwrap(engine.project)
    let pages=Array(before.publications![0].pages.suffix(2)).map{$0.objectID.uuidString}
    _ = try engine.call("form_delete_objects",arguments:["object_ids":pages])
    XCTAssertEqual(engine.project?.objects.first{$0.id==assembly}?.sheetAssembly?.activeSpread,1)
    XCTAssertEqual(engine.project?.textStories?.first{$0.id==story}?.text,before.textStories?.first{$0.id==story}?.text)
    XCTAssertEqual(engine.undoStack.count,1);engine.undo();XCTAssertEqual(engine.project,before)
  }
  func testFirstVersoToRectoRetargetsOnlyImplicitPreviewWithOneUndo()throws {
    let (engine,publication,assembly,_)=try fixture(first:.verso),before=try XCTUnwrap(engine.project)
    XCTAssertEqual(before.objects.first{$0.id==assembly}?.sheetAssembly?.activeSpread,3)
    _ = try engine.call("form_publication",arguments:["command":"settings","publication_id":publication.uuidString,"layout":["facingPages":true,"firstPageSide":"recto"]])
    XCTAssertEqual(engine.project?.objects.first{$0.id==assembly}?.sheetAssembly?.activeSpread,2)
    XCTAssertEqual(engine.project?.objects.filter{$0.id != assembly},before.objects.filter{$0.id != assembly})
    XCTAssertEqual(engine.undoStack.count,1);engine.undo();XCTAssertEqual(engine.project,before)
  }
  func testExplicitDanglingFacesAndEmptyLivePublicationRejectAtomically()throws {
    let (mapped,publication,_,_)=try fixture(explicit:true),before=try XCTUnwrap(mapped.project)
    let pages=Array(before.publications![0].pages.suffix(2)).map{$0.objectID.uuidString}
    XCTAssertThrowsError(try mapped.call("form_publication",arguments:["command":"remove","publication_id":publication.uuidString,"page_ids":pages]))
    XCTAssertEqual(mapped.project,before);XCTAssertTrue(mapped.undoStack.isEmpty)
    let (implicit,document,assembly,_)=try fixture(),original=try XCTUnwrap(implicit.project)
    let all=original.publications![0].pages.map{$0.objectID.uuidString}
    XCTAssertThrowsError(try implicit.call("form_publication",arguments:["command":"remove","publication_id":document.uuidString,"page_ids":all,"delete_objects":true])){error in
      XCTAssertTrue(error.localizedDescription.contains("Remove the linked physical sheet assembly"))
    }
    XCTAssertEqual(implicit.project,original);XCTAssertTrue(implicit.undoStack.isEmpty)
    _ = try implicit.call("form_delete_objects",arguments:["object_ids":[assembly.uuidString]])
    _ = try implicit.call("form_publication",arguments:["command":"remove","publication_id":document.uuidString,"page_ids":all,"delete_objects":true])
    XCTAssertTrue(implicit.project!.publications![0].pages.isEmpty)
    XCTAssertEqual(implicit.project?.textStories,original.textStories?.map{story in var value=story;value.frames=[];return value})
  }
}

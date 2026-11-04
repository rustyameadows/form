import Foundation
import XCTest
@testable import FormCore

@MainActor final class PublicationBulkPageTests:XCTestCase {
  private func engine(_ project:Project)throws->OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("publication-bulk-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=project;return engine
  }
  private func page(in project:inout Project,name:String="Original",text:String="Original source words")throws->(UUID,StoryFrameID) {
    var object=try project.makeObject(recipeID:"artboard",name:name,parameters:["width":148,"depth":210])
    let element=ArtworkElement(kind:"text",x:15,y:20,width:118,height:170,text:text,fontSize:13)
    object.artwork = .init(elements:[element],bleed:0)
    project.objects.append(object);return(object.id,.init(objectID:object.id,elementID:element.id))
  }
  func testBulkInsertionLinksBlankFramesOnceKeepsOriginalWordsAndStableOwnersAndHasOneUndo()throws {
    var project=Project(name:"Bulk source identity")
    let first=try page(in:&project)
    let publication=try PublicationCommands.createPublication(in:&project,name:"Reading order",pages:[first.0])
    let story=try PublicationCommands.createStory(in:&project,frames:[first.1],name:"Canonical chapter",publicationID:publication)
    let baselineStory=try XCTUnwrap(project.textStories?.first)
    let original=project.objects
    let e=try engine(project),undo=e.undoStack.count
    let response=try XCTUnwrap(e.call("form_publication",arguments:["command":"create_pages","publication_id":publication.uuidString,"count":3,"width":148,"height":210,"columns":2,"gutter":8,"index":0,"story_id":story.uuidString]) as? [String:Any])
    let rawIDs=try XCTUnwrap(response["page_ids"] as? [String]),ids=rawIDs.compactMap(UUID.init(uuidString:))
    XCTAssertEqual(ids.count,3);XCTAssertEqual(Set(ids).count,3)
    let after=try XCTUnwrap(e.project),document=try XCTUnwrap(after.publications?.first)
    XCTAssertEqual(document.pages.map(\.objectID),ids+[first.0])
    XCTAssertEqual(after.objects.filter{original.map(\.id).contains($0.id)},original)
    let actualStory=try XCTUnwrap(after.textStories?.first)
    var expectedStory=baselineStory;expectedStory.frames=actualStory.frames
    XCTAssertEqual(actualStory,expectedStory,"Adding physical capacity must not alter words, rich spans, annotations or story identity.")
    XCTAssertEqual(actualStory.frames.count,7)
    XCTAssertEqual(actualStory.frames.map(\.objectID),ids.flatMap{[$0,$0]}+[first.0])
    for id in ids {
      let object=try XCTUnwrap(after.objects.first{$0.id==id}),elements=try XCTUnwrap(object.artwork?.elements)
      XCTAssertEqual(elements.count,2)
      XCTAssertTrue(elements.allSatisfy{$0.text.isEmpty && $0.storyFrame?.storyID==story})
      XCTAssertEqual(elements[0].width,56);XCTAssertEqual(elements[1].width,56)
    }
    XCTAssertEqual(e.undoStack.count,undo+1)
    e.undo();XCTAssertEqual(e.project?.objects,project.objects);XCTAssertEqual(e.project?.textStories,project.textStories)
    e.redo();XCTAssertEqual(e.project?.objects,after.objects)
  }
  func testLateForeignStoryFailureAndBoundsRejectWholeCandidateWithoutPartialPagesOrUndo()throws {
    var project=Project(name:"Bulk rollback")
    let first=try page(in:&project),other=try page(in:&project,name:"Other owner")
    let destination=try PublicationCommands.createPublication(in:&project,name:"Destination",pages:[first.0])
    let foreign=try PublicationCommands.createPublication(in:&project,name:"Other document",pages:[other.0])
    let story=try PublicationCommands.createStory(in:&project,frames:[other.1],publicationID:foreign)
    let e=try engine(project),before=e.project,undo=e.undoStack.count
    XCTAssertThrowsError(try e.call("form_publication",arguments:["command":"create_pages","publication_id":destination.uuidString,"count":5,"story_id":story.uuidString]))
    XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,undo)
    let invalidArguments:[[String:Any]]=[["count":0],["count":200],["count":2,"width":20,"height":20],["count":2,"index":-1]]
    for arguments in invalidArguments {
      var request=arguments;request["command"]="create_pages";request["publication_id"]=destination.uuidString
      XCTAssertThrowsError(try e.call("form_publication",arguments:request))
      XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,undo)
    }
  }
  func testLargeNativeRelationshipShapeAddsNinetySixPagesAndRefreshesEverySharedMeasurementAfterUpstreamEdits()throws {
    var project=Project(name:"Large real relationship run"),pageIDs=[UUID]()
    for index in 0..<128 {pageIDs.append(try page(in:&project,name:"Physical page \(index)",text:"Page \(index)").0)}
    let publication=try PublicationCommands.createPublication(in:&project,name:"Existing 128-page run",pages:pageIDs)
    let controls=try page(in:&project,name:"Independent trim allowance control",text:"").0
    project.objects[project.objects.firstIndex{$0.id==controls}!].parameters["width"]=100
    project.recipes.append(Recipe("bulkAssemblyControls","Measured run","square.stack","Project-owned physical controls",[.init("overhang","Overhang",1,0...10)]))
    let plane=SheetAssemblyPlane(id:"cover",name:"Measured cover",size:.init("width+2*overhang","height+2*overhang"),positionMM:.init("-overhang","stackThickness+0.75","-height/2-overhang"),rotationDegrees:.init(-90,0,0),stock:.init(thicknessMM:1.5))
    let book=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,stock:.init(thicknessMM:0.1),enclosure:[plane],binding:.init(style:.adhesive,adhesiveMM:0.3)),recipeID:"bulkAssemblyControls")
    project.objects[project.objects.firstIndex{$0.id==book}!].dimensionBindings=[.init(parameter:"overhang",expression:"v/100",inputs:["v":.init(sourceObjectID:controls,measurement:.parameter,parameter:"width")])]
    let measures:[PhysicalDimensionMeasurement]=[.trimWidth,.trimHeight,.textBlockThickness,.bindingAllowance,.spineThickness,.closedWidth,.closedHeight,.closedThickness]
    var recipeParameters=[Parameter]()
    for index in measures.indices {recipeParameters.append(.init("d\(index)","Measured dimension \(index)",1,0...10000))}
    let recipe=Recipe("bulkMeasuredSource","Dependent source","square.and.pencil","Independent project-owned dimensions",recipeParameters)
    project.recipes.append(recipe)
    var dependent=try project.makeObject(recipeID:recipe.id);dependent.artwork = .init(elements:[])
    let inputs=Dictionary(uniqueKeysWithValues:measures.enumerated().map{("m\($0.offset)",PhysicalDimensionReference(sourceObjectID:book,measurement:$0.element))})
    dependent.dimensionBindings=measures.indices.map{.init(parameter:"d\($0)",expression:"m\($0)",inputs:inputs)}
    project.objects.append(dependent)
    try project.reconcilePhysicalDimensions(previous:project)
    let second=try PublicationCommands.createPublication(in:&project,name:"Second publication",pages:[])
    let originals=project.objects,bookDefinition=try XCTUnwrap(project.objects.first{$0.id==book}?.sheetAssembly)
    let e=try engine(project),started=Date()
    let response=try XCTUnwrap(e.call("form_publication",arguments:["command":"create_pages","publication_id":second.uuidString,"count":96,"width":148,"height":210,"columns":2,"gutter":8]) as? [String:Any])
    let creationSeconds=Date().timeIntervalSince(started)
    XCTAssertEqual((response["page_ids"] as? [String])?.count,96)
    XCTAssertEqual(e.project?.objects.filter{originals.map(\.id).contains($0.id)},originals)
    XCTAssertEqual(e.project?.objects.first{$0.id==book}?.sheetAssembly,bookDefinition)
    XCTAssertLessThan(creationSeconds,180,"The whole actual relationship operation must fit its bounded bridge response window.")
    let updateStarted=Date()
    for width in [200.0,300.0] {
      _ = try e.call("form_update_object",arguments:["object_id":controls.uuidString,"parameters":["width":width]])
      let current=try XCTUnwrap(e.project),actualBook=try XCTUnwrap(current.objects.first{$0.id==book})
      XCTAssertEqual(actualBook.parameters["overhang"],width/100)
      let source=try XCTUnwrap(current.objects.first{$0.id==dependent.id})
      XCTAssertEqual(source.parameters["d0"],148);XCTAssertEqual(source.parameters["d1"],210)
      XCTAssertEqual(try XCTUnwrap(source.parameters["d2"]),6.4,accuracy:1e-10)
      XCTAssertEqual(try XCTUnwrap(source.parameters["d5"]),148+2*width/100,accuracy:1e-10)
      XCTAssertEqual(try XCTUnwrap(source.parameters["d6"]),210+2*width/100,accuracy:1e-10)
      XCTAssertEqual(current.objects.filter{pageIDs.contains($0.id)},originals.filter{pageIDs.contains($0.id)})
    }
    print("PublicationBulkPageTests actual 128-page+8x8 measured dependency fixture: create96=\(creationSeconds)s, two live parameter edits=\(Date().timeIntervalSince(updateStarted))s")
  }
  func testPageCountGrowAndShrinkResizeBoundSpineAndJacketBeforeCropValidationAndUndoReopenExactly()throws {
    var project=Project(name:"Bound cover growth"),ids=[UUID]()
    for index in 0..<96 {ids.append(try page(in:&project,name:"Original \(index)",text:"Page \(index)").0)}
    let publication=try PublicationCommands.createPublication(in:&project,name:"Caliper-driven edition",pages:ids)
    let spine=try SheetAssemblyCommands.createArtworkSource(in:&project,name:"Canonical spine",size:.init(4.8,210))
    let jacket=try SheetAssemblyCommands.createArtworkSource(in:&project,name:"Canonical jacket",size:.init(300.8,210))
    let pages=project.publications![0].pages
    var parents=[SheetAssemblyParentSheet]()
    for index in 0..<24 {
      let front:[UUID?]=[pages[95-index*2].id,pages[index*2].id]
      let back:[UUID?]=[pages[index*2+1].id,pages[94-index*2].id]
      parents.append(.init(frontPageIDs:front,backPageIDs:back,stock:.init(thicknessMM:0.1),sizeMM:.init(296,210)))
    }
    let panel=SheetAssemblyPlane(id:"spine",name:"Actual-size linked spine",size:.init("stackThickness","height"),stock:.init(thicknessMM:0.2),front:.init(sourceObjectID:spine))
    let book=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,stock:.init(thicknessMM:0.1),enclosure:[panel],parentSheets:parents))
    let grouping=try SheetAssemblyCommands.reimposingSignatures(in:project,objectID:book,parentSheetsPerSignature:4)
    try SheetAssemblyCommands.configure(in:&project,objectID:book,definition:grouping)
    project.objects[project.objects.firstIndex{$0.id==spine}!].dimensionBindings=[.init(parameter:"width",expression:"v",inputs:["v":.init(sourceObjectID:book,measurement:.textBlockThickness)])]
    project.objects[project.objects.firstIndex{$0.id==jacket}!].dimensionBindings=[.init(parameter:"width",expression:"2*w+s",inputs:["w":.init(sourceObjectID:book,measurement:.trimWidth),"s":.init(sourceObjectID:book,measurement:.spineThickness)])]
    try project.reconcilePhysicalDimensions(previous:project)
    let e=try engine(project),before=try XCTUnwrap(e.project),undo=e.undoStack.count
    let added=try XCTUnwrap(e.call("form_publication",arguments:["command":"create_pages","publication_id":publication.uuidString,"count":32,"width":148,"height":210]) as? [String:Any])
    let addedIDs=try XCTUnwrap(added["page_ids"] as? [String])
    let grown=try XCTUnwrap(e.project)
    XCTAssertEqual(grown.publications?.first?.pages.count,128)
    XCTAssertEqual(try XCTUnwrap(grown.objects.first{$0.id==spine}?.parameters["width"]),6.4,accuracy:1e-10)
    XCTAssertEqual(try XCTUnwrap(grown.objects.first{$0.id==jacket}?.parameters["width"]),302.4,accuracy:1e-10)
    XCTAssertEqual(grown.objects.first{$0.id==book}?.sheetAssembly?.signatures?.map(\.id),grouping.signatures?.map(\.id))
    try grown.validateSheetAssemblies()
    _ = try e.call("form_publication",arguments:["command":"remove","publication_id":publication.uuidString,"page_ids":addedIDs,"delete_objects":true])
    XCTAssertEqual(e.project?.publications?.first?.pages.count,96)
    XCTAssertEqual(e.project?.objects,before.objects,"The same source pages, parent stocks, art and geometry return after physical shrink.")
    XCTAssertEqual(e.undoStack.count,undo+2)
    e.undo();XCTAssertEqual(e.project?.objects,grown.objects)
    e.redo();XCTAssertEqual(e.project?.objects,before.objects)
    try e.flush()
    let reopened=try e.repository.load(before.id)
    XCTAssertEqual(reopened.objects,before.objects);try reopened.validateArtworkLinks()
  }
  func testOnlyBulkPageCreationReceivesTheExtendedEditingResponseWindow() {
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_publication",arguments:["command":"create_pages","count":96]),180)
    for command in ["add_page","settings","reorder","insert","sheet_assembly_configure","Create_pages"] {
      XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_publication",arguments:["command":command]),30)
    }
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_story",arguments:["command":"create_pages"]),30)
  }
  func testBulkCanvasSourceRoleIsAtomicDefaultsStayAbsentAndTheSamePagesFeedAnAssembly()throws {
    var project=Project(name:"Bulk canonical source role")
    let publication=try PublicationCommands.createPublication(in:&project,name:"Editable physical pages",pages:[])
    let e=try engine(project)
    let defaultOptions:[[String:Any]]=[[:],["canvas_source_only":false]]
    for fields in defaultOptions {
      var request=fields;request["command"]="create_pages";request["publication_id"]=publication.uuidString
      request["count"]=1;request["width"]=148;request["height"]=210
      _=try e.call("form_publication",arguments:request)
    }
    let defaults=try XCTUnwrap(e.project)
    XCTAssertEqual(defaults.objects.count,2)
    for page in defaults.objects {
      XCTAssertNil(page.canvasSourceOnly)
      XCTAssertNil((try jsonObject(page) as? [String:Any])?["canvasSourceOnly"],"The existing default JSON must remain unchanged.")
    }
    XCTAssertEqual(defaults.tablePresentationObjects.count,2)
    let result=try XCTUnwrap(e.call("form_publication",arguments:["command":"create_pages","publication_id":publication.uuidString,"count":4,"width":148,"height":210,"canvas_source_only":true]) as? [String:Any])
    let ids=Set(try XCTUnwrap(result["page_ids"] as? [String]).compactMap(UUID.init(uuidString:)))
    let beforeAssembly=try XCTUnwrap(e.project),created=beforeAssembly.objects.filter{ids.contains($0.id)}
    XCTAssertEqual(created.count,4)
    XCTAssertTrue(created.allSatisfy{$0.canvasSourceOnly==true && $0.recipeID=="artboard" && $0.artwork != nil && beforeAssembly.isIndependentFlatArtworkSource($0)})
    XCTAssertTrue(Set(beforeAssembly.tablePresentationObjects.map(\.id)).isDisjoint(with:ids))
    XCTAssertEqual(beforeAssembly.objects.filter{!ids.contains($0.id)},defaults.objects)
    let definition=SheetAssemblyDefinition(publicationID:publication)
    _=try e.call("form_publication",arguments:["command":"sheet_assembly_create","definition":try jsonObject(definition)])
    let assembled=try XCTUnwrap(e.project),assembly=try XCTUnwrap(assembled.objects.first{$0.sheetAssembly != nil})
    let resolved=try assembled.resolvedSheetAssembly(assembly)
    XCTAssertTrue(ids.isSubset(of:resolved.sourceObjectIDs));XCTAssertEqual(resolved.leaves.count,3)
    XCTAssertEqual(assembled.tablePresentationObjects.map(\.id),[assembly.id])
    XCTAssertEqual(assembled.objects.filter{ids.contains($0.id)},created)
    e.undo();XCTAssertEqual(e.project,beforeAssembly)
    e.undo();XCTAssertEqual(e.project,defaults)
  }
  func testBulkSourceRoleAcceptsOnlyAnExplicitBooleanOnCreatePages()throws {
    var project=Project(name:"Bulk role rollback")
    let publication=try PublicationCommands.createPublication(in:&project,name:"Destination",pages:[])
    let e=try engine(project),before=e.project
    let badValues:[Any]=[1,"true",NSNull()]
    for raw in badValues {
      XCTAssertThrowsError(try e.call("form_publication",arguments:["command":"create_pages","publication_id":publication.uuidString,"count":4,"canvas_source_only":raw]))
      XCTAssertEqual(e.project,before);XCTAssertTrue(e.undoStack.isEmpty)
    }
    for command in ["add_page","settings","get"] {
      XCTAssertThrowsError(try e.call("form_publication",arguments:["command":command,"publication_id":publication.uuidString,"canvas_source_only":true]))
      XCTAssertEqual(e.project,before);XCTAssertTrue(e.undoStack.isEmpty)
    }
    XCTAssertThrowsError(try e.call("form_publication",arguments:["command":"create_pages","publication_id":publication.uuidString,"count":4,"canvas_source_only":true,"story_id":UUID().uuidString]))
    XCTAssertEqual(e.project,before);XCTAssertTrue(e.undoStack.isEmpty,"Late story validation must discard all new source roles and pages together.")
  }
}

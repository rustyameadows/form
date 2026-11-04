import Foundation
import XCTest
@testable import FormCore

@MainActor final class BulkArtworkReplacementTests:XCTestCase {
  private struct Fixture {
    var project:Project
    var publicationID:UUID
    var pageIDs:[UUID]
    var captionIDs:[UUID:UUID]
    var assemblyID:UUID
  }
  private func fixture(count:Int=100)throws->Fixture {
    var project=Project(name:"Bulk native publication source")
    let publication=try PublicationCommands.createPublication(in:&project,name:"Original canonical source",pages:[])
    let ids=try PublicationCommands.addPages(in:&project,publicationID:publication,count:count,width:148,height:210,canvasSourceOnly:true)
    let frames=ids.flatMap{id in
      project.objects.first{$0.id==id}!.artwork!.elements.filter{$0.kind=="text"}.map{StoryFrameID(objectID:id,elementID:$0.id)}
    }
    let story=try PublicationCommands.createStory(in:&project,frames:frames,name:"Shared rich words",publicationID:publication)
    var source=project.textStories![0].sourceElement
    source.text="Original story: café, a reference 🌿, and every source word stay intact across all physical frames."
    var bold=Typography();bold.fontName="HelveticaNeue-Bold"
    source.textRuns=[.init(location:0,length:8,typography:bold,fontSize:15,color:"#204030")]
    try PublicationCommands.setSource(in:&project,storyID:story,source:source)
    try PublicationCommands.upsertAnnotation(in:&project,storyID:story,annotation:.init(location:0,length:8,kind:.reference,body:"Original editorial reference"))
    var type=Typography();type.fontName="HelveticaNeue";type.leading=18
    let style=ArtworkTextStyle(name:"Shared caption style",typography:type,fontSize:12)
    project.textStyles=[style]
    var captions=[UUID:UUID]()
    for (ordinal,id) in ids.enumerated() {
      let index=project.objects.firstIndex{$0.id==id}!
      var caption=ArtworkElement(kind:"text",x:15,y:190,width:110,height:12,text:"Caption \(ordinal+1)",color:"#253C32",fontSize:12)
      caption.name="Standalone styled caption";caption.typography=type
      caption.textStyle = .init(styleID:style.id);caption.paragraphStyle = .init(styleID:style.id)
      captions[id]=caption.id
      project.objects[index].artwork!.elements.append(caption)
      project.objects[index].artwork!.elements.append(.init(kind:"rectangle",x:15,y:183,width:110,height:0.3,color:"#253C32"))
    }
    let assembly=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,stock:.init(thicknessMM:0.12)))
    project.camera.azimuth=0.87;project.camera.distance=17.5
    project.schemaVersion=project.minimumSchemaVersion
    try project.validateArtworkLinks()
    return .init(project:project,publicationID:publication,pageIDs:ids,captionIDs:captions,assemblyID:assembly)
  }
  private func engine(_ project:Project)throws->OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("bulk-artwork-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let value=OperationEngine(repository:try ProjectRepository(root:root));value.project=project;return value
  }
  private func replacements(_ fixture:Fixture)throws->[(UUID,Artwork)] {
    try fixture.pageIDs.enumerated().map{ordinal,id in
      var art=try XCTUnwrap(fixture.project.objects.first{$0.id==id}?.artwork)
      let caption=try XCTUnwrap(art.elements.firstIndex{$0.id==fixture.captionIDs[id]})
      art.elements[caption].text="Revised caption \(ordinal+1)"
      art.elements[caption].fontSize=14
      art.elements[caption].typography!.tracking=0.4
      art.elements[caption].typography!.paragraphBefore=2
      return(id,art)
    }
  }
  private func operations(_ values:[(UUID,Artwork)])throws->[[String:Any]] {
    try values.map{id,art in ["name":"form_set_artwork","arguments":["object_id":id.uuidString,"artwork":try jsonObject(art)]]}
  }
  private func assertRollback(_ engine:OperationEngine,operations:[[String:Any]],contains:String?=nil,file:StaticString=#filePath,line:UInt=#line)throws {
    let original=engine.project,undo=engine.undoStack.count,redo=engine.redoStack.count,selection=engine.selection
    XCTAssertThrowsError(try engine.call("form_batch",arguments:["operations":operations]),file:file,line:line){error in
      if let contains {XCTAssertTrue(error.localizedDescription.lowercased().contains(contains.lowercased()),"Expected \(contains), got \(error)",file:file,line:line)}
    }
    XCTAssertEqual(engine.project,original,file:file,line:line)
    XCTAssertEqual(engine.undoStack.count,undo,file:file,line:line);XCTAssertEqual(engine.redoStack.count,redo,file:file,line:line)
    XCTAssertEqual(engine.selection,selection,file:file,line:line)
  }
  func testOneHundredCanonicalPageReplacementsPrepareTheCompleteCandidateOnceAndUndoReopenExactly()throws {
    let f=try fixture(),e=try engine(f.project),values=try replacements(f),requests=try operations(values)
    let before=try XCTUnwrap(e.project),selection:Set<UUID>=[f.assemblyID];e.selection=selection
    var expected=before
    for (id,art) in values {try expected.setArtwork(art,for:id)}
    var preparations=0
    e.onPrepareProjectEdit={old,candidate in
      preparations+=1
      XCTAssertEqual(old,before)
      XCTAssertEqual(candidate.objects,expected.objects,"Native preparation must see the complete final100-page source, never a partially updated edition.")
      XCTAssertEqual(candidate.textStories,before.textStories)
      candidate.notes.append(.init("Prepared the complete canonical artwork replacement once"))
    }
    let started=Date()
    let result=try XCTUnwrap(e.call("form_batch",arguments:["operations":requests]) as? [String:Any])
    let elapsed=Date().timeIntervalSince(started),after=try XCTUnwrap(e.project)
    XCTAssertEqual((result["results"] as? [[String:Any]])?.count,100)
    XCTAssertEqual(preparations,1);XCTAssertEqual(e.undoStack.count,1)
    XCTAssertEqual(after.objects,expected.objects);XCTAssertEqual(after.textStories,before.textStories)
    XCTAssertEqual(after.publications,before.publications);XCTAssertEqual(after.textStyles,before.textStyles)
    XCTAssertEqual(after.camera,before.camera);XCTAssertEqual(e.selection,selection)
    XCTAssertEqual(after.objects.first{$0.id==f.assemblyID},before.objects.first{$0.id==f.assemblyID})
    XCTAssertEqual(after.notes.count,before.notes.count+1)
    let first=try XCTUnwrap(after.objects.first{$0.id==f.pageIDs[0]}?.artwork?.elements.first{$0.id==f.captionIDs[f.pageIDs[0]]})
    XCTAssertTrue(first.textStyle?.overrides.contains("fontSize")==true)
    XCTAssertTrue(first.textStyle?.overrides.contains("tracking")==true)
    XCTAssertTrue(first.paragraphStyle?.overrides.contains("paragraphBefore")==true)
    try e.flush();let loaded=try e.repository.load(before.id)
    XCTAssertEqual(loaded.objects,after.objects);XCTAssertEqual(loaded.textStories,after.textStories)
    XCTAssertEqual(loaded.publications,after.publications);try loaded.validateArtworkLinks()
    e.undo();XCTAssertEqual(e.project,before)
    e.redo();XCTAssertEqual(e.project,after);XCTAssertEqual(preparations,1)
    XCTAssertLessThan(elapsed,30,"Actual100-page source replacement must fit the unchanged editing response deadline.")
    print("BulkArtworkReplacementTests actual100-page publication+rich story+physical assembly: \(elapsed)s for100 artwork replacements; native preparation callbacks=\(preparations)")
  }
  func testLateInvalidArtworkAndMissingProjectImageAssetRollBackAllEarlierPages()throws {
    let f=try fixture(),e=try engine(f.project)
    e.selection=[f.assemblyID]
    var invalid=try replacements(f)
    invalid[invalid.count-1].1.elements.append(.init(kind:"rectangle",x:10,y:10,width:-1,height:10))
    try assertRollback(e,operations:operations(invalid))
    var missing=try replacements(f)
    var image=ArtworkElement(kind:"image",x:10,y:10,width:20,height:20)
    image.asset="missing-bulk-"+UUID().uuidString+".png"
    missing[missing.count-1].1.elements.append(image)
    try assertRollback(e,operations:operations(missing),contains:"image asset not found")
  }
  func testLateCanonicalBindingConflictDiscardsEveryPreviousReplacement()throws {
    var f=try fixture()
    let id=try XCTUnwrap(f.pageIDs.last),objectIndex=try XCTUnwrap(f.project.objects.firstIndex{$0.id==id}),captionID=try XCTUnwrap(f.captionIDs[id])
    let elementIndex=try XCTUnwrap(f.project.objects[objectIndex].artwork!.elements.firstIndex{$0.id==captionID})
    f.project.objects[objectIndex].artwork!.elements[elementIndex].width=37
    f.project.objects[objectIndex].artworkParameterBindings=[.init(id:"actual-quarter-trim",elementID:captionID,property:.width,value:"width/4")]
    try f.project.validateArtworkLinks()
    let e=try engine(f.project);var values=try replacements(f)
    let last=values.count-1,caption=try XCTUnwrap(values[last].1.elements.firstIndex{$0.id==captionID})
    values[last].1.elements[caption].width=38
    let before=e.project
    XCTAssertThrowsError(try e.call("form_batch",arguments:["operations":try operations(values)])){error in
      XCTAssertEqual((error as? ArtworkParameterBindingFailure)?.bindingID,"actual-quarter-trim")
    }
    XCTAssertEqual(e.project,before);XCTAssertTrue(e.undoStack.isEmpty)
  }
  func testLateAggregateLiveViewFeedbackCycleIsRejectedByFinalProjectValidation()throws {
    let f=try fixture(),e=try engine(f.project);var values=try replacements(f)
    var view=ArtworkElement(kind:"path",x:15,y:155,width:20,height:20,color:"#253C32")
    view.path = .init(width:20,height:20,contours:[.init([.init(.init(0,0)),.init(.init(20,0)),.init(.init(20,20)),.init(.init(0,20))])])
    view.objectView = .init(sourceID:f.assemblyID,linked:true)
    values[values.count-1].1.elements.append(view)
    var preparations=0
    e.onPrepareProjectEdit={_,candidate in
      preparations+=1
      XCTAssertTrue(candidate.objects.first{$0.id==f.pageIDs[0]}?.artwork?.elements.contains{$0.text=="Revised caption 1"}==true)
    }
    try assertRollback(e,operations:operations(values),contains:"live view")
    XCTAssertEqual(preparations,1,"Aggregate validation follows one native preparation of the complete candidate.")
  }
  func testHomogeneousBulkMatchesPublicSingleSheetStyleAndStorySemanticsIncludingRepeatedOwners()throws {
    let f=try fixture(count:4),bulk=try engine(f.project),single=try engine(f.project)
    var values=try replacements(f)
    for (id,art) in values {_=try single.call("form_set_artwork",arguments:["object_id":id.uuidString,"artwork":try jsonObject(art)])}
    // A subsequent public edit starts with the returned canonical document,
    // including the overrides recorded by the earlier edit to this owner.
    // Reusing the pre-edit reference explicitly removes those overrides and is
    // invalid for both single-sheet and batch commands.
    var repeated=try XCTUnwrap(single.project?.objects.first{$0.id==values[0].0}?.artwork)
    let caption=try XCTUnwrap(repeated.elements.firstIndex{$0.id==f.captionIDs[values[0].0]})
    XCTAssertTrue(repeated.elements[caption].textStyle?.overrides.contains("tracking")==true)
    XCTAssertTrue(repeated.elements[caption].paragraphStyle?.overrides.contains("paragraphBefore")==true)
    repeated.elements[caption].fontSize=16
    _=try single.call("form_set_artwork",arguments:["object_id":values[0].0.uuidString,"artwork":try jsonObject(repeated)])
    values.append((values[0].0,repeated))
    _=try bulk.call("form_batch",arguments:["operations":try operations(values)])
    let actual=try XCTUnwrap(bulk.project),reference=try XCTUnwrap(single.project)
    XCTAssertEqual(actual.objects,reference.objects);XCTAssertEqual(actual.textStories,reference.textStories)
    XCTAssertEqual(actual.textStyles,reference.textStyles);XCTAssertEqual(actual.publications,reference.publications)
    XCTAssertThrowsError(try single.call("form_set_artwork",arguments:["object_id":values[0].0.uuidString,"artwork":try jsonObject(values[0].1)]))
    try assertRollback(bulk,operations:operations([values[0]]),contains:"Shared caption style")
    XCTAssertEqual(single.project,reference)
    XCTAssertEqual(bulk.undoStack.count,1);bulk.undo();XCTAssertEqual(bulk.project,f.project)
  }
  func testNativePreparationFailureCannotPublishOrDiscardExistingRedo()throws {
    let f=try fixture(count:4),e=try engine(f.project)
    _=try e.call("form_add_note",arguments:["text":"Existing redo entry"]);e.undo()
    let before=e.project,oldRedo=e.redoStack
    var preparations=0
    e.onPrepareProjectEdit={_,candidate in
      preparations+=1
      XCTAssertTrue(candidate.objects.first{$0.id==f.pageIDs[3]}?.artwork?.elements.contains{$0.text=="Revised caption 4"}==true)
      throw FormError.invalid("Rejected complete prepared artwork candidate")
    }
    try assertRollback(e,operations:operations(replacements(f)),contains:"complete prepared")
    XCTAssertEqual(preparations,1);XCTAssertEqual(e.project,before);XCTAssertEqual(e.redoStack,oldRedo)
  }
}

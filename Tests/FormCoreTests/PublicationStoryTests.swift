import XCTest
@testable import FormCore

final class PublicationStoryTests:XCTestCase {
  private func fixture(_ values:[String]=["Istanbul\nPrepare materials","Check dimensions\nAssemble carefully"]) throws -> (Project,[StoryFrameID]) {
    var p=Project(name:"Instruction booklet"),frames:[StoryFrameID]=[]
    for (i,value) in values.enumerated() {
      var page=try p.makeObject(recipeID:"artboard",name:"Page \(i+1)",parameters:["width":160,"depth":210])
      var e=ArtworkElement(kind:"text",x:14,y:28,width:132,height:150,text:value,color:"#24353D",fontSize:14)
      e.typography=Typography();e.typography!.fontName="Georgia";e.typography!.kerningMode="metrics"
      var art=Artwork(elements:[e]);art.language=i==0 ? "tr":"en";page.artwork=art
      frames.append(.init(objectID:page.id,elementID:e.id));p.objects.append(page)
    }
    return(p,frames)
  }
  func testOneStoryOwnsRichSourceAndFramesStoreOnlyReferences() throws {
    var (p,frames)=try fixture()
    let original=p.objects.compactMap{ $0.artwork?.elements.first }
    var rich=original[0].typography!;rich.tracking=0.4
    p.objects[0].artwork!.elements[0].textRuns=[.init(location:0,length:1,typography:rich,fontSize:20,color:"#A55135")]
    let id=try PublicationCommands.createStory(in:&p,frames:frames,name:"Assembly")
    let story=try XCTUnwrap(p.textStories?.first)
    XCTAssertEqual(story.id,id);XCTAssertEqual(story.text,original.map(\.text).joined(separator:"\n"))
    XCTAssertEqual(story.frames,frames);XCTAssertEqual(story.textRuns?.first?.fontSize,20);XCTAssertEqual(story.textRuns?.first?.color,"#A55135")
    let offset=original[0].text.utf16.count+1
    XCTAssertTrue(story.textRuns!.filter{$0.location>=offset}.allSatisfy{$0.typography.language=="en"})
    for object in p.objects {
      let e=object.artwork!.elements[0];XCTAssertEqual(e.text,"");XCTAssertNil(e.textRuns);XCTAssertNil(e.listItems)
      XCTAssertEqual(e.storyFrame?.storyID,id)
    }
    XCTAssertEqual(p.minimumSchemaVersion,26);try p.validatePublications()
  }
  func testStoryEditChangesRenderKeysWithoutRewritingFrameSourceObjects() throws {
    var (p,frames)=try fixture();let id=try PublicationCommands.createStory(in:&p,frames:frames)
    let objects=p.objects,first=p.objects[0],resolved=p.resolvingTextStories(in:first.artwork!,objectID:first.id)
    let before=try resolved.renderCacheData()
    let saved=String(decoding:try JSONEncoder.form.encode(resolved),as:UTF8.self)
    XCTAssertFalse(saved.contains("resolved"));XCTAssertFalse(saved.contains("Prepare materials"))
    var source=p.textStories![0].sourceElement;source.text += "\nA new final observation."
    try PublicationCommands.setSource(in:&p,storyID:id,source:source)
    XCTAssertEqual(p.objects,objects)
    let after=p.resolvingTextStories(in:p.objects[0].artwork!,objectID:first.id)
    XCTAssertNotEqual(try after.renderCacheData(),before)
  }
  func testPageOrderGridValidationAndSchemaReopenKeepSingleSource() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let repo=try ProjectRepository(root:root)
    var (p,frames)=try fixture();let story=try PublicationCommands.createStory(in:&p,frames:frames)
    let document=try PublicationCommands.createPublication(in:&p,name:"ORBITAL",pages:p.objects.map(\.id))
    try PublicationCommands.assignStory(in:&p,storyID:story,publicationID:document)
    var settings=p.publications![0];settings.baselineGrid = .init(spacing:18,origin:6)
    try PublicationCommands.setPublication(in:&p,document:settings)
    var source=p.textStories![0].sourceElement;source.typography!.alignToBaselineGrid=true
    try PublicationCommands.setSource(in:&p,storyID:story,source:source)
    try repo.save(p);let loaded=try repo.load(p.id)
    XCTAssertEqual(loaded.schemaVersion,26);XCTAssertEqual(loaded.textStories,p.textStories);XCTAssertEqual(loaded.publications,p.publications)
    XCTAssertEqual(loaded.objects,p.objects)
    var invalid=p;invalid.objects[0].artwork!.elements[0].rotation=15
    XCTAssertThrowsError(try invalid.validatePublications())
  }
  func testUnlinkAndReorderPreserveGlobalWordsAndOrphanRecovery() throws {
    var (p,frames)=try fixture();let id=try PublicationCommands.createStory(in:&p,frames:frames)
    let words=p.textStories![0].text
    try PublicationCommands.reorderFrames(in:&p,storyID:id,frames:Array(frames.reversed()))
    XCTAssertEqual(p.textStories![0].text,words)
    try PublicationCommands.unlinkFrames(in:&p,frames:[frames[0]])
    XCTAssertEqual(p.textStories![0].frames,[frames[1]]);XCTAssertNil(p.objects[0].artwork!.elements[0].storyFrame)
    try PublicationCommands.unlinkFrames(in:&p,frames:[frames[1]])
    XCTAssertTrue(p.textStories![0].frames.isEmpty);XCTAssertEqual(p.textStories![0].text,words);try p.validatePublications()
  }
  func testInvalidLinksAndLockedSourceFailAtomicallyAndLongStoryIsGlobalOnly() throws {
    var (p,frames)=try fixture([String(repeating:"A",count:10000),String(repeating:"B",count:9000)])
    let before=p;p.objects[0].locked=true
    XCTAssertThrowsError(try PublicationCommands.createStory(in:&p,frames:frames));XCTAssertNil(p.textStories)
    p=before;_ = try PublicationCommands.createStory(in:&p,frames:frames)
    XCTAssertEqual(p.textStories![0].text.utf16.count,19001)
    XCTAssertEqual(p.objects.map{$0.artwork!.elements[0].text},["",""])
    var duplicate=p;duplicate.textStories![0].frames.append(frames[0]);XCTAssertThrowsError(try duplicate.validatePublications())
  }
  func testDuplicateDeleteAndTransferKeepGlobalWordsAndExplicitPageCapacity() throws {
    var (p,frames)=try fixture();let storyID=try PublicationCommands.createStory(in:&p,frames:frames)
    let documentID=try PublicationCommands.createPublication(in:&p,name:"Pages",pages:p.objects.map(\.id)),words=p.textStories![0].text
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=p
    XCTAssertThrowsError(try engine.call("form_duplicate_object",arguments:["object_id":frames[0].objectID.uuidString,"mode":"variant"]))
    let copy=try engine.call("form_duplicate_object",arguments:["object_id":frames[0].objectID.uuidString,"mode":"iteration"]) as! [String:Any]
    let copyID=UUID(uuidString:copy["id"] as! String)!
    XCTAssertEqual(engine.project!.publications![0].pages.map(\.objectID),[frames[0].objectID,copyID,frames[1].objectID])
    XCTAssertEqual(engine.project!.textStories![0].frames.count,3);XCTAssertEqual(engine.project!.textStories![0].text,words)
    _ = try engine.call("form_delete_objects",arguments:["object_ids":[copyID.uuidString]])
    XCTAssertEqual(engine.project!.textStories![0].frames,frames);XCTAssertEqual(engine.project!.textStories![0].text,words)
    p=engine.project!;var target=try p.makeObject(recipeID:"artboard",name:"New page",parameters:["width":160,"depth":210]);target.artwork=Artwork();p.objects.append(target)
    let moved=try p.transferArtwork(from:frames[0].objectID,to:target.id,ids:[frames[0].elementID],offset:.init())
    XCTAssertEqual(moved,[frames[0].elementID]);XCTAssertEqual(p.textStories![0].id,storyID);XCTAssertEqual(p.textStories![0].text,words)
    XCTAssertTrue(p.publications!.first{$0.id==documentID}!.pages.contains{$0.objectID==target.id})
    XCTAssertEqual(p.textStories![0].frames.last?.objectID,target.id);try p.validateArtworkLinks()
    let workspace=try p.ensureCanvasWorkspace(),before=p
    XCTAssertThrowsError(try p.transferArtwork(from:target.id,to:workspace.id,ids:moved));XCTAssertEqual(p,before)
  }
  func testParagraphListAndPaletteCommandsTargetOneGlobalStoryThroughAnyFrame() throws {
    var (p,frames)=try fixture();let story=try PublicationCommands.createStory(in:&p,frames:frames),sourceText=p.textStories![0].text
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=p
    _ = try engine.call("form_edit_artwork",arguments:["object_id":frames[1].objectID.uuidString,"element_ids":[frames[1].elementID.uuidString],"command":"paragraph","typography":["direction":"rtl","language":"tr"]])
    _ = try engine.call("form_edit_artwork",arguments:["object_id":frames[0].objectID.uuidString,"element_ids":[frames[0].elementID.uuidString],"command":"list","marker":"decimal"])
    let color=ArtworkSwatch(name:"Accent",color:"#A55135");engine.project!.swatches=[color]
    var candidate=engine.project!
    try SwatchCommands.assign(in:&candidate,objectID:frames[1].objectID,ids:[frames[1].elementID],target:"fill",swatchID:color.id)
    XCTAssertEqual(candidate.textStories![0].id,story);XCTAssertEqual(candidate.textStories![0].text,sourceText)
    XCTAssertEqual(candidate.textStories![0].typography?.direction,"rtl");XCTAssertFalse(candidate.textStories![0].listItems!.isEmpty)
    XCTAssertEqual(candidate.textStories![0].fillSwatchID,color.id)
    XCTAssertEqual(candidate.resolvedTextStory(story)?.story.color,color.color)
    XCTAssertTrue(candidate.objects.flatMap{$0.artwork!.elements}.allSatisfy{$0.text.isEmpty && $0.listItems==nil})
    try candidate.validateArtworkLinks()
  }

}

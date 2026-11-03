import Foundation
import XCTest
@testable import FormCore

final class PublicationStructureTests:XCTestCase {
  private func fixture(count:Int=4)throws->(Project,UUID,UUID) {
    var project=Project(name:"Source-owned publication"),frames:[StoryFrameID]=[]
    for index in 0..<count {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index+1)",parameters:["width":120,"depth":180])
      let element=ArtworkElement(kind:"text",x:14,y:14,width:92,height:152,text:index==0 ? "Original words 🙂\nSecond paragraph.":"",fontSize:12)
      page.artwork = .init(elements:[element]);project.objects.append(page);frames.append(.init(objectID:page.id,elementID:element.id))
    }
    let story=try PublicationCommands.createStory(in:&project,frames:frames,name:"Body")
    let publication=try PublicationCommands.createPublication(in:&project,name:"Publication",pages:project.objects.map(\.id))
    return(project,publication,story)
  }
  func testFacingSpreadsPhysicalLeafSidesAndMirroredMarginsRemainSeparate()throws {
    var (project,id,_)=try fixture()
    var document=try XCTUnwrap(project.publications?.first);document.layout = .init(innerMargin:22,outerMargin:9)
    try PublicationCommands.setPublication(in:&project,document:document)
    let pages=document.pages
    XCTAssertEqual(document.spreads().map{$0.pages.count},[1,2,1])
    XCTAssertEqual(document.spreads()[0].right?.id,pages[0].id);XCTAssertNil(document.spreads()[0].left)
    XCTAssertEqual(document.spreads()[1].left?.id,pages[1].id);XCTAssertEqual(document.spreads()[1].right?.id,pages[2].id)
    XCTAssertEqual(document.leafPairs().map{$0.front?.id},[pages[0].id,pages[2].id])
    XCTAssertEqual(document.leafPairs().map{$0.back?.id},[pages[1].id,pages[3].id])
    XCTAssertEqual(document.resolvedMargins(for:pages[0].objectID).left,22);XCTAssertEqual(document.resolvedMargins(for:pages[1].objectID).left,9)
    document.layout?.firstPageSide = .verso
    try PublicationCommands.setPublication(in:&project,document:document)
    XCTAssertEqual(document.spreads().map{$0.pages.count},[2,2]);XCTAssertEqual(document.leafPairs().count,3)
    XCTAssertNil(document.leafPairs()[0].front);XCTAssertEqual(document.leafPairs()[0].back?.id,pages[0].id)
    XCTAssertEqual(document.leafPairs().map(\.id),document.leafPairs().map(\.id));XCTAssertEqual(project.publications?.first?.id,id)
    XCTAssertEqual(project.minimumSchemaVersion,63)
  }
  func testNumberingChapterInheritanceExplicitGroupsAndLegacyDecode()throws {
    var (project,_,_)=try fixture()
    var document=project.publications![0]
    document.layout = .init();document.numbering = .init(start:3,style:.lowerRoman,prefix:"[",suffix:"]")
    document.pages[0].chapterTitle="Opening";document.pages[2].chapterTitle="Next"
    document.pages[2].numberOverride=10;document.pages[1].label="Plate A"
    let group=UUID();document.pages[1].spreadID=group;document.pages[2].spreadID=group
    try PublicationCommands.setPublication(in:&project,document:document)
    XCTAssertEqual(document.pageNumber(for:document.pages[0].objectID),"[iii]");XCTAssertEqual(document.pageNumber(for:document.pages[3].objectID),"[xi]")
    XCTAssertEqual(document.pageLabel(for:document.pages[1].objectID),"Plate A")
    XCTAssertEqual(document.chapterTitle(for:document.pages[1].objectID),"Opening");XCTAssertEqual(document.chapterTitle(for:document.pages[3].objectID),"Next")
    let before=project;var invalid=document;invalid.pages[0].spreadID=group
    XCTAssertThrowsError(try PublicationCommands.setPublication(in:&project,document:invalid));XCTAssertEqual(project,before)
    var old=document;old.layout=nil;old.numbering=nil;old.pages=old.pages.map{.init(objectID:$0.objectID)}
    let decoded=try JSONDecoder.form.decode(PublicationDocument.self,from:JSONEncoder.form.encode(old))
    XCTAssertNil(decoded.layout);XCTAssertNil(decoded.numbering);XCTAssertNil(decoded.masters);XCTAssertFalse(decoded.requiresExtendedPublicationSchema)
  }
  func testInsertionDuplicationRemovalPreserveRichStorySourceAndReadingOrder()throws {
    var (project,id,storyID)=try fixture()
    let source=project.textStories![0].sourceElement,first=project.publications![0].pages[0].objectID
    var document=project.publications![0];document.layout = .init(innerMargin:20,outerMargin:8)
    try PublicationCommands.setPublication(in:&project,document:document)
    let inserted=try PublicationCommands.addPages(in:&project,publicationID:id,count:2,width:120,height:180,storyID:storyID,columns:2,gutter:6,at:1)
    XCTAssertEqual(Array(project.publications![0].pages[1...2]).map(\.objectID),inserted)
    XCTAssertEqual(project.objects.first{$0.id==inserted[0]}?.artwork?.elements.first?.x,8,"The inserted verso uses its outer left margin")
    XCTAssertEqual(project.objects.first{$0.id==inserted[1]}?.artwork?.elements.first?.x,20)
    XCTAssertEqual(project.textStories![0].sourceElement,source)
    let duplicate=try PublicationCommands.duplicatePublicationPage(in:&project,publicationID:id,objectID:first,at:3)
    XCTAssertEqual(project.textStories![0].sourceElement,source)
    XCTAssertTrue(project.textStories![0].frames.contains{$0.objectID==duplicate})
    XCTAssertTrue(project.objects.first{$0.id==duplicate}!.artwork!.elements.filter{$0.storyFrame != nil}.allSatisfy{$0.text.isEmpty})
    try PublicationCommands.removePages(in:&project,publicationID:id,pageIDs:[duplicate],deleteObjects:false)
    XCTAssertEqual(project.textStories![0].sourceElement,source);XCTAssertNotNil(project.objects.first{$0.id==duplicate})
    XCTAssertTrue(project.objects.first{$0.id==duplicate}!.artwork!.elements.allSatisfy{$0.storyFrame==nil})
    let all=Set(project.publications![0].pages.map(\.objectID))
    try PublicationCommands.removePages(in:&project,publicationID:id,pageIDs:all,deleteObjects:true)
    XCTAssertTrue(project.publications![0].pages.isEmpty);XCTAssertTrue(project.textStories![0].frames.isEmpty);XCTAssertEqual(project.textStories![0].sourceElement,source)
  }
  func testPageBatchCreationAndRejectedMembershipAreAtomic()throws {
    var (project,id,_)=try fixture(count:1),before=project
    XCTAssertThrowsError(try PublicationCommands.addPages(in:&project,publicationID:id,count:3,width:25,height:30,columns:4,gutter:20))
    XCTAssertEqual(project,before)
    let pages=try PublicationCommands.addPages(in:&project,publicationID:id,count:2,width:80,height:100,at:0)
    XCTAssertEqual(Array(project.publications![0].pages.prefix(2)).map(\.objectID),pages)
    before=project
    XCTAssertThrowsError(try PublicationCommands.insertPages(in:&project,publicationID:id,pageIDs:[pages[0]],at:0));XCTAssertEqual(project,before)
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try .init(root:root));engine.project=project
    _ = try engine.call("form_publication",arguments:["command":"duplicate","publication_id":id.uuidString,"page_id":pages[0].uuidString,"index":1])
    XCTAssertEqual(engine.undoStack.count,1);engine.undo();XCTAssertEqual(engine.project,before)
    let count=engine.undoStack.count
    XCTAssertThrowsError(try engine.call("form_publication",arguments:["command":"create_pages","publication_id":id.uuidString,"count":true]))
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,count)
  }
  func testPreexistingLinkedVariantsCannotBecomePublicationPageOwners()throws {
    var project=Project(name:"Independent page membership")
    var source=try project.makeObject(recipeID:"artboard",name:"Original shared design",parameters:["width":100,"depth":140])
    source.artwork = .init(elements:[.init(kind:"text",x:10,y:10,text:"Shared before publication")])
    var variant=source;variant.id=UUID();variant.relationship="variant";variant.name="Existing linked variant"
    var independent=source;independent.id=UUID();independent.designID=UUID();independent.name="Independent page"
    project.objects=[source,variant,independent]
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("publication-owner-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:folder)}
    let engine=OperationEngine(repository:try .init(root:folder));engine.project=project
    for ids in [[source.id],[variant.id],[source.id,variant.id]] {
      XCTAssertThrowsError(try engine.call("form_publication",arguments:["command":"create","name":"Reject shared owners","page_ids":ids.map(\.uuidString)]))
      XCTAssertEqual(engine.project,project);XCTAssertTrue(engine.undoStack.isEmpty)
    }
    let result=try XCTUnwrap(try engine.call("form_publication",arguments:["command":"create","name":"Independent owner","page_ids":[independent.id.uuidString]]) as? [String:Any])
    let document=try XCTUnwrap(result["publication_id"] as? String),before=try XCTUnwrap(engine.project),undo=engine.undoStack.count
    for owner in [source.id,variant.id] {
      XCTAssertThrowsError(try engine.call("form_publication",arguments:["command":"insert","publication_id":document,"page_ids":[owner.uuidString],"index":0]))
      XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,undo)
    }
    let iteration=try XCTUnwrap(try engine.call("form_duplicate_object",arguments:["object_id":source.id.uuidString,"mode":"iteration"]) as? [String:Any])
    let iterationID=try XCTUnwrap(iteration["id"] as? String)
    XCTAssertNoThrow(try engine.call("form_publication",arguments:["command":"insert","publication_id":document,"page_ids":[iterationID],"index":1]))
    XCTAssertEqual(engine.project?.objects.first{$0.id==source.id},source);XCTAssertEqual(engine.project?.objects.first{$0.id==variant.id},variant)
  }
  func testRichUTF16SplicePreservesUnaffectedSpansGlyphsAndParagraphIdentities()throws {
    var source=ArtworkElement(kind:"text",x:0,y:0,text:"Alpha 🙂 beta\nTail words",fontSize:12)
    var rich=Typography();rich.fontName="Georgia";rich.caseTreatment="uppercase";rich.pairKerning=[17:0.5]
    let tail=(source.text as NSString).range(of:"Tail")
    source.textRuns=[.init(location:tail.location,length:10,typography:rich,fontSize:18,color:"#A00000")]
    let listA=ParagraphListItem(location:0,listID:UUID(),marker:.decimal),listB=ParagraphListItem(location:tail.location,listID:UUID(),marker:.decimal)
    source.listItems=[listA,listB]
    source.glyphOverrides=[.init(location:tail.location,sourceText:"T",glyph:.init(fontName:"Georgia",glyphID:5,glyphName:nil,fontSignature:String(repeating:"a",count:64)))]
    let range=(source.text as NSString).range(of:"🙂"),replacement="a longer phrase"
    let edited=try PublicationTextEdits.replacing(source,range:range,with:replacement),delta=replacement.utf16.count-range.length
    XCTAssertEqual(edited.text,"Alpha a longer phrase beta\nTail words")
    XCTAssertEqual(edited.textRuns?.last?.fontSize,18);XCTAssertEqual(edited.textRuns?.last?.typography.caseTreatment,"uppercase")
    XCTAssertEqual(edited.glyphOverrides?.first?.id,source.glyphOverrides?.first?.id);XCTAssertEqual(edited.glyphOverrides?.first?.location,tail.location+delta)
    XCTAssertEqual(edited.listItems?.map(\.id),[listA.id,listB.id]);XCTAssertEqual(edited.listItems?.last?.location,tail.location+delta)
    XCTAssertEqual(edited.textRuns?.last?.typography.pairKerning[17+delta],0.5)
    XCTAssertThrowsError(try PublicationTextEdits.replacing(source,range:NSRange(location:range.location+1,length:1),with:"x"))
    XCTAssertThrowsError(try PublicationTextEdits.replacing(source,range:NSRange(location:Int.max,length:1),with:"x"))
  }
  func testMalformedExtendedSettingsRejectWithoutSourceOrUndoChanges()throws {
    let (project,id,_)=try fixture(count:2)
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try .init(root:root));engine.project=project
    let malformed:[[String:Any]]=[["layout":"invalid"],["layout":true],["numbering":12],["numbering":[]],["masters":"invalid"],["masters":["wrong":true]]]
    for patch in malformed {
      var arguments=patch;arguments["command"]="settings";arguments["publication_id"]=id.uuidString
      XCTAssertThrowsError(try engine.call("form_publication",arguments:arguments))
      XCTAssertEqual(engine.project,project);XCTAssertTrue(engine.undoStack.isEmpty);XCTAssertTrue(engine.redoStack.isEmpty)
    }
  }
  func testMasterCannotImportStoryCapacityThroughNestedComponentSource()throws {
    var (project,_,_)=try fixture(count:2)
    project.objects[0].componentDefinition=true
    var master=try project.makeObject(recipeID:"artboard",name:"Nested master",parameters:["width":120,"depth":180])
    var component=ArtworkElement(kind:"group",x:0,y:0,width:120,height:180)
    component.contentSize = .init(120,180);component.component = .init(sourceObjectID:project.objects[0].id);master.artwork = .init(elements:[component]);project.objects.append(master)
    try project.validateArtworkLinks()
    let expanded=try project.resolvingComponents(in:master.artwork!)
    XCTAssertTrue(expanded.elements.contains{$0.storyFrame != nil},"The fixture must exercise the nested resolved source, not a direct story frame")
    let before=project;var document=project.publications![0]
    document.masters=[.init(sourceObjectID:master.id)]
    XCTAssertThrowsError(try PublicationCommands.setPublication(in:&project,document:document))
    XCTAssertEqual(project,before);XCTAssertEqual(project.textStories,before.textStories)
  }
  func testInsertedParagraphBreakContinuesListAtEndOfInsertedRange()throws {
    var source=ArtworkElement(kind:"text",x:0,y:0,text:"AB",fontSize:12)
    let item=ParagraphListItem(location:0,marker:.decimal);source.listItems=[item]
    let edited=try PublicationTextEdits.replacing(source,range:NSRange(location:1,length:0),with:"\n")
    XCTAssertEqual(edited.text,"A\nB");XCTAssertEqual(edited.listItems?.map(\.location),[0,2])
    XCTAssertEqual(edited.listItems?.first?.id,item.id);XCTAssertNotEqual(edited.listItems?.last?.id,item.id)
    XCTAssertEqual(Set(edited.listItems!.map(\.listID)),[item.listID])
    XCTAssertEqual(Artwork(elements:[edited]).resolvingLists.elements[0].listItems?.map(\.resolvedNumber),[1,2])
    let namespace=UUID()
    let a=try PublicationTextEdits.replacing(source,range:NSRange(location:1,length:0),with:"\n",derivedParagraphNamespace:namespace)
    let b=try PublicationTextEdits.replacing(source,range:NSRange(location:1,length:0),with:"\n",derivedParagraphNamespace:namespace)
    XCTAssertEqual(a.listItems?.map(\.id),b.listItems?.map(\.id))
  }
  func testRepeatedMasterSourcesKeepIndependentListIdentitiesAndCounters()throws {
    var (project,_,_)=try fixture(count:1)
    var source=try project.makeObject(recipeID:"artboard",name:"Listed master",parameters:["width":120,"depth":180])
    var text=ArtworkElement(kind:"text",x:10,y:10,width:80,height:30,text:"One\nTwo",fontSize:10)
    let listID=UUID();text.listItems=[.init(location:0,listID:listID,marker:.decimal),.init(location:4,listID:listID,marker:.decimal)]
    source.artwork = .init(elements:[text]);project.objects.append(source)
    var document=project.publications![0]
    document.masters=[.init(name:"First",sourceObjectID:source.id),.init(name:"Second",sourceObjectID:source.id,y:60)]
    try PublicationCommands.setPublication(in:&project,document:document)
    let original=project.objects,page=project.objects.first{$0.id==document.pages[0].objectID}!
    let art=try XCTUnwrap(project.surfaceArtwork(page)).resolvingLists
    let lists=art.elements.filter{$0.kind=="text" && $0.storyFrame==nil}.flatMap{$0.listItems ?? []}
    XCTAssertEqual(lists.map(\.resolvedNumber),[1,2,1,2]);XCTAssertEqual(Set(lists.map(\.id)).count,4);XCTAssertEqual(Set(lists.map(\.listID)).count,2)
    XCTAssertEqual(project.objects,original)
  }
  func testMultilineRunningTokenHasDeterministicParagraphIDsAndRenderSignature()throws {
    var (project,_,_)=try fixture(count:1)
    var source=try project.makeObject(recipeID:"artboard",name:"Multiline master",parameters:["width":120,"depth":180])
    var text=ArtworkElement(kind:"text",x:10,y:10,width:100,height:50,text:"{{chapter.title}}",fontSize:10)
    text.listItems=[.init(location:0,marker:.decimal)];source.artwork = .init(elements:[text]);project.objects.append(source)
    var document=project.publications![0];document.pages[0].chapterTitle="First heading\nSecond heading"
    document.masters=[.init(sourceObjectID:source.id)];try PublicationCommands.setPublication(in:&project,document:document)
    let page=project.objects.first{$0.id==document.pages[0].objectID}!,original=project.objects
    let a=try XCTUnwrap(project.surfaceArtwork(page)),b=try XCTUnwrap(project.surfaceArtwork(page))
    let first=try XCTUnwrap(a.elements.first{$0.kind=="text" && $0.storyFrame==nil}),second=try XCTUnwrap(b.elements.first{$0.id==first.id})
    XCTAssertEqual(first.text,"First heading\nSecond heading");XCTAssertEqual(first.listItems?.count,2)
    XCTAssertEqual(first.listItems?.map(\.id),second.listItems?.map(\.id));XCTAssertEqual(try a.renderCacheData(),try b.renderCacheData())
    XCTAssertEqual(project.objects,original)
  }
  func testNestedMasterTokenReplacementRetainsItsReadOnlyHierarchyAndRichSource()throws {
    var (project,_,_)=try fixture(count:1)
    var master=try project.makeObject(recipeID:"artboard",name:"Nested furniture",parameters:["width":120,"depth":180])
    let group=ArtworkElement(kind:"group",x:4,y:6,width:100,height:30)
    var child=ArtworkElement(kind:"text",x:2,y:3,width:90,height:20,text:"Page {{page.number}}",fontSize:10)
    child.parentID=group.id;child.textRuns=[.init(location:0,length:4,typography:.init(),fontSize:14,color:"#A00000")]
    master.artwork = .init(elements:[group,child]);project.objects.append(master)
    var document=project.publications![0];document.numbering = .init(start:9);document.masters=[.init(sourceObjectID:master.id)]
    try PublicationCommands.setPublication(in:&project,document:document)
    let original=project.objects,page=project.objects.first{$0.id==document.pages[0].objectID}!
    let art=try XCTUnwrap(project.surfaceArtwork(page)),text=try XCTUnwrap(art.elements.first{$0.kind=="text" && $0.storyFrame==nil})
    XCTAssertEqual(text.text,"Page 9");XCTAssertEqual(text.textRuns?.first?.fontSize,14);XCTAssertEqual(text.locked,true)
    let parent=try XCTUnwrap(art.elements.first{$0.id==text.parentID})
    XCTAssertEqual(parent.kind,"group");XCTAssertNotNil(parent.parentID);XCTAssertNotEqual(text.parentID,group.id)
    XCTAssertNoThrow(try validateArtwork(art));XCTAssertEqual(project.objects,original)
  }
  func testMasterFurnitureHasOneEditableSourceStableIDsAndDynamicLabels()throws {
    var (project,id,_)=try fixture(count:3)
    var source=try project.makeObject(recipeID:"artboard",name:"Running master",parameters:["width":120,"depth":180])
    var text=ArtworkElement(kind:"text",x:10,y:164,width:100,height:8,text:"Keep {{chapter.title}} / {{page.number}}",fontSize:9)
    text.textRuns=[.init(location:0,length:4,typography:.init(),fontSize:13,color:"#AA0000")]
    source.artwork = .init(elements:[text]);project.objects.append(source)
    var document=project.publications![0];document.layout = .init();document.pages[0].chapterTitle="Opening";document.numbering = .init(start:7)
    let master=PublicationMaster(name:"Running furniture",sourceObjectID:source.id)
    document.masters=[master];try PublicationCommands.setPublication(in:&project,document:document)
    let originalObjects=project.objects,page=document.pages[1]
    let resolved=try XCTUnwrap(project.surfaceArtwork(project.objects.first{$0.id==page.objectID}!))
    let generated=try XCTUnwrap(resolved.elements.first{$0.kind=="text" && $0.storyFrame==nil})
    XCTAssertEqual(generated.text,"Keep Opening / 8");XCTAssertEqual(generated.textRuns?.first?.fontSize,13);XCTAssertEqual(generated.locked,true)
    XCTAssertEqual(project.objects,originalObjects)
    let own=project.removingPublicationSpreadArtwork(from:resolved,objectID:page.objectID)
    XCTAssertEqual(project.removingPublicationFurniture(from:own,objectID:page.objectID).elements.map(\.id),project.objects.first{$0.id==page.objectID}!.artwork!.elements.map(\.id))
    var saved=project;try saved.setArtwork(resolved,for:page.objectID);try saved.validateArtworkLinks()
    XCTAssertEqual(saved.objects.first{$0.id==page.objectID}?.artwork?.elements,project.objects.first{$0.id==page.objectID}?.artwork?.elements,"Saving a resolved page must strip both derived neighbors and master furniture")
    XCTAssertEqual(saved.objects.filter{$0.id != page.objectID},project.objects.filter{$0.id != page.objectID})
    document.pages.reverse();try PublicationCommands.setPublication(in:&project,document:document)
    let second=try XCTUnwrap(project.surfaceArtwork(project.objects.first{$0.id==page.objectID}!))
    XCTAssertEqual(second.elements.first{$0.id==generated.id}?.id,generated.id)
    XCTAssertEqual(project.objects.first{$0.id==source.id}?.artwork,source.artwork);XCTAssertEqual(project.publications?.first?.id,id)
    document.pages[1].masterIDs=[];try PublicationCommands.setPublication(in:&project,document:document)
    XCTAssertFalse(project.surfaceArtwork(project.objects.first{$0.id==page.objectID}!)!.elements.contains{$0.id==generated.id})
  }
}

import Foundation
import XCTest
@testable import FormCore

@MainActor final class PublicationTrimTests:XCTestCase {
  private func engine(_ project:Project)throws->OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("publication-trim-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let value=OperationEngine(repository:try ProjectRepository(root:root));value.project=project;return value
  }
  private func fixture()throws->(Project,UUID,UUID,UUID,UUID) {
    var project=Project(name:"Physical trim relationships")
    let publication=try PublicationCommands.createPublication(in:&project,name:"Unscaled source edition",pages:[],margins:.init(top:12,right:13,bottom:14,left:15))
    var frames=[StoryFrameID]()
    for _ in 0..<8 {frames += try PublicationCommands.addPage(in:&project,publicationID:publication,width:148,height:210,columns:2,gutter:8).1}
    let story=try PublicationCommands.createStory(in:&project,frames:frames,name:"Original linked chapter",publicationID:publication)
    var source=project.textStories![0].sourceElement
    source.text="Exact rich source, café 🌿, survives a new physical trim."
    source.fontSize=13
    var typography=Typography();typography.fontName="HelveticaNeue-Bold"
    source.textRuns=[.init(location:0,length:5,typography:typography,fontSize:15,color:"#203040")]
    try PublicationCommands.setSource(in:&project,storyID:story,source:source)
    try PublicationCommands.upsertAnnotation(in:&project,storyID:story,annotation:.init(location:6,length:4,kind:.note,body:"Editorial metadata also stays exact."))
    let cover=try SheetAssemblyCommands.createArtworkSource(in:&project,name:"Canonical cover",size:.init(1000,1000))
    let jacket=try SheetAssemblyCommands.createArtworkSource(in:&project,name:"Canonical jacket",size:.init(1000,1000))
    let pageEntries=project.publications![0].pages
    let parent0=SheetAssemblyParentSheet(frontPageIDs:[pageEntries[7].id,pageEntries[0].id],backPageIDs:[pageEntries[1].id,pageEntries[6].id],stock:.init(thicknessMM:0.24,profile:.init(color:"#E3D8A8")),sizeMM:.init(296,210),printIntent:.blackOnly)
    let parent1=SheetAssemblyParentSheet(frontPageIDs:[pageEntries[5].id,pageEntries[2].id],backPageIDs:[pageEntries[3].id,pageEntries[4].id],stock:.init(thicknessMM:0.1),sizeMM:.init(296,210),printIntent:.color)
    let planes:[SheetAssemblyPlane]=[
      .init(id:"cover",name:"Bound cover face",size:.init("width+4","height+4"),stock:.init(thicknessMM:1.5),front:.init(sourceObjectID:cover)),
      .init(id:"jacket",name:"Bound jacket source",size:.init("2*width+spineThickness+40","height+6"),stock:.init(thicknessMM:0.15),front:.init(sourceObjectID:jacket))]
    let book=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,enclosure:planes,
      binding:.init(style:.sewn,sewingSwellMM:0.2),parentSheets:[parent0,parent1],signatures:[.init(parentSheetIDs:[parent0.id,parent1.id])]))
    let widthInput=["trim":PhysicalDimensionReference(sourceObjectID:book,measurement:.trimWidth)]
    let heightInput=["trim":PhysicalDimensionReference(sourceObjectID:book,measurement:.trimHeight)]
    let coverIndex=project.objects.firstIndex{$0.id==cover}!
    project.objects[coverIndex].dimensionBindings=[.init(parameter:"width",expression:"trim+4",inputs:widthInput),.init(parameter:"depth",expression:"trim+4",inputs:heightInput)]
    let jacketIndex=project.objects.firstIndex{$0.id==jacket}!
    project.objects[jacketIndex].dimensionBindings=[.init(parameter:"width",expression:"2*trim+spine+40",inputs:["trim":.init(sourceObjectID:book,measurement:.trimWidth),"spine":.init(sourceObjectID:book,measurement:.spineThickness)]),.init(parameter:"depth",expression:"trim+6",inputs:heightInput)]
    try project.reconcilePhysicalDimensions(previous:project)
    project.camera.azimuth=0.87;project.camera.distance=18
    try project.validateArtworkLinks()
    return(project,publication,book,cover,jacket)
  }
  func testWholeDocumentTrimUpdatesParentAndBoundCoverJacketTogetherWithoutScalingSourceAndUndoReopensExactly()throws {
    let(project,publication,book,cover,jacket)=try fixture(),e=try engine(project)
    let before=try XCTUnwrap(e.project),document=try XCTUnwrap(before.publications?.first)
    let oldDefinition=try XCTUnwrap(before.objects.first{$0.id==book}?.sheetAssembly),undo=e.undoStack.count
    let selection:Set<UUID>=[book];e.selection=selection
    let response=try XCTUnwrap(e.call("form_publication",arguments:["command":"resize_pages","publication_id":publication.uuidString,"width":150,"height":215]) as? [String:Any])
    let after=try XCTUnwrap(e.project),definition=try XCTUnwrap(after.objects.first{$0.id==book}?.sheetAssembly)
    XCTAssertEqual((response["page_ids"] as? [String])?.count,8)
    XCTAssertEqual(after.publications,before.publications);XCTAssertEqual(after.textStories,before.textStories)
    XCTAssertEqual(after.camera,before.camera);XCTAssertEqual(e.selection,selection)
    for entry in document.pages {
      var old=try XCTUnwrap(before.objects.first{$0.id==entry.objectID})
      let changed=try XCTUnwrap(after.objects.first{$0.id==entry.objectID})
      old.parameters["width"]=150;old.parameters["depth"]=215
      XCTAssertEqual(changed,old,"Only physical trim parameters change; source element/frame IDs, positions, fonts and rich source stay exact.")
    }
    var expected=oldDefinition
    for index in expected.parentSheets!.indices {expected.parentSheets![index].sizeMM = .init(300,215)}
    XCTAssertEqual(definition,expected,"Parent IDs, gathered IDs, stock, ink intent and logical slots stay authoritative.")
    XCTAssertEqual(after.objects.first{$0.id==cover}?.artworkSize,.init(154,219))
    let body=try after.sheetAssemblyMeasurements(XCTUnwrap(after.objects.first{$0.id==book}))
    let actualJacket=try XCTUnwrap(after.objects.first{$0.id==jacket})
    XCTAssertEqual(actualJacket.artworkSize.x,340+body.spineThickness,accuracy:1e-10);XCTAssertEqual(actualJacket.artworkSize.y,221)
    XCTAssertEqual(actualJacket.artwork,before.objects.first{$0.id==jacket}?.artwork)
    try after.validateArtworkLinks();XCTAssertEqual(e.undoStack.count,undo+1)
    e.undo();XCTAssertEqual(e.project,before)
    e.redo();XCTAssertEqual(e.project,after)
    try e.flush();let reopened=try e.repository.load(before.id)
    XCTAssertEqual(reopened.objects,after.objects);XCTAssertEqual(reopened.publications,after.publications);XCTAssertEqual(reopened.textStories,after.textStories)
    try reopened.validateArtworkLinks()
  }
  func testInvalidBoundsMissingAxesSubsetSelectorsAndMalformedParentsRejectAtomically()throws {
    let(project,publication,book,_,_)=try fixture(),e=try engine(project)
    let before=e.project,undo=e.undoStack.count
    let bad:[[String:Any]]=[
      ["width":19,"height":215],["width":150,"height":2001],["width":true,"height":215],
      ["width":Double.infinity,"height":215],["width":150],
      ["width":150,"height":215,"page_id":project.publications![0].pages[0].objectID.uuidString]]
    for fields in bad {
      var request=fields;request["command"]="resize_pages";request["publication_id"]=publication.uuidString
      XCTAssertThrowsError(try e.call("form_publication",arguments:request))
      XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,undo)
    }
    var malformed=project;let index=malformed.objects.firstIndex{$0.id==book}!
    malformed.objects[index].sheetAssembly!.parentSheets![0].sizeMM.x=299
    e.project=malformed
    XCTAssertThrowsError(try e.call("form_publication",arguments:["command":"resize_pages","publication_id":publication.uuidString,"width":150,"height":215]))
    XCTAssertEqual(e.project,malformed);XCTAssertEqual(e.undoStack.count,undo)
  }
  func testLockedPagesParentsAndDependentArtworkSourcesRejectWithoutPartialTrim()throws {
    let(project,publication,book,cover,_)=try fixture()
    let page=project.publications![0].pages[0].objectID
    for id in [page,book,cover] {
      var locked=project;locked.objects[locked.objects.firstIndex{$0.id==id}!].locked=true
      let e=try engine(locked),before=e.project
      XCTAssertThrowsError(try e.call("form_publication",arguments:["command":"resize_pages","publication_id":publication.uuidString,"width":150,"height":215]))
      XCTAssertEqual(e.project,before);XCTAssertTrue(e.undoStack.isEmpty)
    }
  }
  func testExistingPageArtworkParameterAuthorityCannotSilentlyMoveInkDuringTrimResize()throws {
    var(project,publication,_,_,_)=try fixture()
    let index=project.objects.firstIndex{$0.id==project.publications![0].pages[0].objectID}!
    let layer=ArtworkElement(kind:"rectangle",x:74,y:5,width:4,height:4,color:"#202020")
    project.objects[index].artwork!.elements.append(layer)
    project.objects[index].artworkParameterBindings=[.init(id:"position-authority",elementID:layer.id,property:.x,value:"width/2")]
    let before=project
    XCTAssertThrowsError(try PublicationCommands.resizePages(in:&project,publicationID:publication,width:150,height:215))
    XCTAssertEqual(project,before)
  }
  func testResizeCommandAndPhysicalAxisSemanticsAreDiscoverable()throws {
    let tool=try XCTUnwrap(MCP.tools.first{$0["name"] as? String=="form_publication"})
    let schema=try XCTUnwrap(tool["inputSchema"] as? [String:Any]),properties=try XCTUnwrap(schema["properties"] as? [String:Any])
    let command=try XCTUnwrap(properties["command"] as? [String:Any])
    XCTAssertTrue((command["enum"] as? [String] ?? []).contains("resize_pages"))
    XCTAssertTrue((tool["description"] as? String ?? "").contains("resize_pages"))
  }
}

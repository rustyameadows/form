import AppKit
import XCTest
import FormCore
import FormGeometry
import FormGraphics
@testable import FormApp

@MainActor final class SheetAssemblyRenderFailureTests:XCTestCase {
  private func fixture()throws->(StudioStore,UUID,UUID,URL) {
    _=NSApplication.shared
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("sheet-render-failure-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:folder),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:folder.appendingPathComponent("Fonts.json"))
    var project=Project(name:"Strict linked sheet capture")
    var page=try project.makeObject(recipeID:"artboard",name:"Canonical page",parameters:["width":100,"depth":140])
    page.artwork = .init(elements:[]);project.objects=[page]
    let publication=try PublicationCommands.createPublication(in:&project,name:"Canonical source",pages:[page.id])
    let book=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication),name:"Linked physical book")
    try store.repository.save(project);store.engine.project=project;store.showingHome=false
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    addTeardownBlock{@MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:folder)}
    return(store,page.id,book,assets)
  }
  private func failedExport(_ store:StudioStore,book:UUID,containing text:String)async throws {
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count,selection=store.engine.selection
    var shot=StudioShot(name:"Strict source evidence",camera:before.camera,referenceAspect:1.5)
    shot.pixels = .init(width:320,height:240);shot.visibility = .init(mode:.objects,objectIDs:[book])
    let destination=store.repository.root.appendingPathComponent("Rejected-"+UUID().uuidString+".render")
    do{_=try await store.studioShots.export(shot,to:destination);XCTFail("An invalid linked source must not produce a successful empty capture")}
    catch{XCTAssertTrue(error.localizedDescription.contains(text),error.localizedDescription);XCTAssertTrue(error.localizedDescription.contains("Linked physical book"),error.localizedDescription)}
    XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
    XCTAssertEqual(store.studioShots.renderer.renders,0)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo);XCTAssertEqual(store.engine.selection,selection)
  }
  func testFactoryConstructionFailureSurvivesViewportRenameAndClone()throws {
    let(store,_,id,assets)=try fixture();var project=try XCTUnwrap(store.project)
    let index=project.objects.firstIndex{$0.id==id}!
    project.objects[index].sheetAssembly!.bendMM=51 // Damaged/legacy input cannot silently disappear.
    let before=project,node=GeometryFactory.object(project.objects[index],project:project,assets:assets,textureLimit:128)
    let issue=try XCTUnwrap(node.constructionFailure)
    XCTAssertEqual(issue.objectID,id);XCTAssertTrue(issue.message.contains("Linked physical book"))
    node.name="object:"+id.uuidString
    let scene=MeshNode(),clone=node.clone();scene.addChildNode(clone)
    XCTAssertEqual(clone.constructionFailure,issue)
    XCTAssertThrowsError(try SheetAssemblyRenderValidation.scene(scene,project:project,objectIDs:[id])){error in XCTAssertEqual(error as? MeshConstructionFailure,issue)}
    XCTAssertEqual(project,before)
  }
  func testActualStudioExportRejectsInvalidSheetGeometryWithoutRepairingSource()async throws {
    let(store,_,id,_)=try fixture()
    store.engine.project!.objects[store.project!.objects.firstIndex{$0.id==id}!].sheetAssembly!.bendMM=51
    try await failedExport(store,book:id,containing:"bending")
  }
  func testActualStudioExportRejectsMissingCanonicalRasterAndValidatorAcceptsRepairAtSamePath()async throws {
    let(store,page,id,assets)=try fixture(),filename="Missing-page-image.png"
    let image=ArtworkElement(kind:"image",x:5,y:5,width:60,height:80,asset:filename)
    try store.engine.edit("Authored portable raster reference"){project in try project.setArtwork(.init(elements:[image]),for:page)}
    try await failedExport(store,book:id,containing:filename)
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    bitmap.setColor(.systemGreen,atX:0,y:0);bitmap.setColor(.systemGreen,atX:1,y:0);bitmap.setColor(.systemGreen,atX:0,y:1);bitmap.setColor(.systemGreen,atX:1,y:1)
    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:assets.appendingPathComponent(filename))
    let before=try XCTUnwrap(store.project),object=try XCTUnwrap(before.objects.first{$0.id==id})
    XCTAssertNoThrow(try SheetAssemblyRenderValidation.sources(object,project:before,assets:assets))
    XCTAssertEqual(store.project,before)
  }
  func testActualStudioExportRejectsMissingImagePaintInGlobalRichStorySource()async throws {
    let(store,page,id,_)=try fixture(),filename="Missing-rich-story-paint.png"
    var paint=ArtworkPaint(kind:"image");paint.asset=filename
    var frame=ArtworkElement(kind:"text",x:8,y:8,width:84,height:100,text:"A painted word.",fontSize:12)
    var span=TextSpan(location:0,length:1,typography:.init(),fontSize:12,color:"#193F3C");span.paintStack=[.init(paint)];frame.textRuns=[span]
    try store.engine.edit("One global rich source"){project in
      try project.setArtwork(.init(elements:[frame]),for:page)
      let publicationID=project.publications![0].id
      _=try PublicationCommands.createStory(in:&project,frames:[.init(objectID:page,elementID:frame.id)],publicationID:publicationID)
    }
    let owner=try XCTUnwrap(store.project?.objects.first{$0.id==page})
    XCTAssertEqual(owner.artwork?.elements.first?.text,"");XCTAssertNil(owner.artwork?.elements.first?.textRuns)
    try await failedExport(store,book:id,containing:filename)
  }
  func testActualStudioExportRejectsCorruptMasterImagePaintAndIgnoresHiddenPaint()async throws {
    let(store,_,id,assets)=try fixture(),filename="Corrupt-running-master.png"
    try Data("not a readable raster".utf8).write(to:assets.appendingPathComponent(filename))
    var paint=ArtworkPaint(kind:"image");paint.asset=filename
    var element=ArtworkElement(kind:"rectangle",x:8,y:8,width:50,height:20);element.paintStack=[.init(paint)]
    var masterID:UUID?
    try store.engine.edit("Authored shared master image paint"){project in
      var source=try project.makeObject(recipeID:"artboard",name:"Running master",parameters:["width":100,"depth":140]);source.artwork = .init(elements:[element]);masterID=source.id;project.objects.append(source)
      var document=project.publications![0];document.masters=[.init(name:"Live image header",sourceObjectID:source.id)]
      try PublicationCommands.setPublication(in:&project,document:document)
    }
    try await failedExport(store,book:id,containing:filename)
    try store.engine.edit("Hidden unused image paint"){project in let index=project.objects.firstIndex{$0.id==masterID}!;project.objects[index].artwork!.elements[0].hidden=true}
    let before=try XCTUnwrap(store.project),object=try XCTUnwrap(before.objects.first{$0.id==id})
    XCTAssertNoThrow(try SheetAssemblyRenderValidation.sources(object,project:before,assets:assets))
    XCTAssertEqual(store.project,before)
  }
}

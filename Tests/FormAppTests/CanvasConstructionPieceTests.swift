import AppKit
import FormCADModel
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class CanvasConstructionPieceTests:XCTestCase {
  private func fixture()throws->(StudioStore,UUID,UUID,UUID,URL) {
    _=NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("piece-canvas-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    var project=Project(name:"Physical pattern and readable faces")
    var front=try project.makeObject(recipeID:"artboard",name:"Canonical front",parameters:["width":100,"depth":80])
    front.artwork = .init(elements:[.init(kind:"rectangle",x:8,y:13,width:4,height:5,color:"#124567")]);front.artwork?.backgroundOpacity=0
    var reverse=try project.makeObject(recipeID:"artboard",name:"Readable reverse",parameters:["width":100,"depth":80])
    reverse.artwork = .init(elements:[.init(kind:"rectangle",x:12,y:10,width:4,height:5,color:"#A34B26")]);reverse.artwork?.backgroundOpacity=0
    let shape=PlanarConstructionDefinition(name:"Independent physical pieces",size:.init(150,80),stockThickness:2,panels:[
      .init(id:"board",name:"Support",polygon:[.init(0,0),.init(40,0),.init(40,30),.init(0,30)]),
      .init(id:"face",name:"Main face",polygon:[.init(70,0),.init(100,0),.init(100,30),.init(70,30)],cutouts:[.init(id:"window",polygon:[.init(75,5),.init(79,5),.init(79,9),.init(75,9)],kind:.window)]),
      .init(id:"edge",name:"Angled edge",polygon:[.init(100,0),.init(110,0),.init(110,20),.init(100,30)])],hinges:[.init(id:"bend",parentPanelID:"face",childPanelID:"edge",start:.init(100,0),end:.init(100,30),angleDegrees:90)],rootPanelID:"board",components:[
        .init(id:"board-piece",name:"Support board",rootPanelID:"board",anchor:.init(0,0),position:.init(0,1,0),rotationDegrees:.init(-90,0,0),stock:.init(name:"Board",thicknessMM:2,profile:.init(color:"#B8AA8D")),front:.init(sourceObjectID:front.id,sourceOriginMM:.init(5,7))),
        .init(id:"facing-piece",name:"Cut facing",rootPanelID:"face",anchor:.init(70,0),position:.init(0,2.2,0),rotationDegrees:.init(-90,0,0),stock:.init(name:"Facing",thicknessMM:0.2,profile:.init(color:"#DFE4B0")),front:.init(sourceObjectID:front.id,sourceOriginMM:.init(5,7)),back:.init(sourceObjectID:reverse.id,sourceOriginMM:.init(5,7)))])
    project.recipes.append(.init("piece-canvas-source","Physical pieces","square","Generic planar source",[.init("fold","Fold",100,0...100),.init("opening","Opening",0,0...100),.init("explosion","Explosion",0,0...100)]))
    var owner=try project.makeObject(recipeID:"piece-canvas-source",name:"Physical assembly")
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:150,height:80,depth:2),stock:.init(thicknessMM:2),explosionPercent:0);paper.authored=shape;owner.paperConstruction=paper
    let unrelated=try project.makeObject(recipeID:"box",name:"Unchanged Table selection")
    project.objects=[owner,front,reverse,unrelated];project.schemaVersion=project.minimumSchemaVersion
    store.engine.project=project;store.environment = .form;store.mode = .artwork;store.showingHome=false
    store.engine.selection=[unrelated.id];store.tableInspectorVisible=false
    let scene=TableSceneController(store:store);var camera=project.camera;camera.distance=17;camera.azimuth=0.7;scene.camera=camera;store.scene=scene
    addTeardownBlock { @MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:directory) }
    return(store,owner.id,front.id,reverse.id,directory)
  }
  private func frame(_ store:StudioStore,_ owner:UUID,_ component:String,_ inside:Bool,_ panel:String?=nil)throws->CanvasFrame {
    try XCTUnwrap(store.artworkSession.frames.first{$0.projection?.constructionID==owner && $0.projection?.componentID==component && $0.projection?.inside==inside && $0.projection?.panelID==panel})
  }
  func testIndependentPatternsAndUprightFacesUseActualStockStableKeysAndWholePieceReverseContour()throws {
    let(store,id,frontID,backID,_)=try fixture(),project=try XCTUnwrap(store.project),owner=project.objects[0]
    let session=store.artworkSession;session.activate(id)
    XCTAssertEqual(session.paperContext?.id,id);XCTAssertEqual(session.activeProjection?.componentID,"board-piece")
    let frames=session.frames.filter{$0.projection?.constructionID==id}
    XCTAssertEqual(frames.count,10);XCTAssertEqual(Set(frames.map(\.id)).count,frames.count)
    let proof=try frame(store,id,"facing-piece",false),panel=try frame(store,id,"facing-piece",false,"face"),back=try frame(store,id,"facing-piece",true)
    XCTAssertEqual(proof.rect.size,.init(width:40,height:30));XCTAssertEqual(proof.physicalStock?.resolvedThicknessMM,0.2)
    XCTAssertEqual(try frame(store,id,"board-piece",false).physicalStock?.resolvedThicknessMM,2)
    XCTAssertEqual(proof.projection?.sourceID,frontID);XCTAssertEqual(panel.projection?.sourceID,frontID);XCTAssertEqual(back.projection?.sourceID,backID)
    XCTAssertEqual(proof.artwork.elements[0].affine?.tx,-5);XCTAssertEqual(panel.artwork.elements[0].affine?.tx,-5)
    XCTAssertEqual(back.artwork.elements[0].affine?.a,1,"An independent readable reverse source must remain upright.")
    let net=try XCTUnwrap(back.paperNet),edge=try XCTUnwrap(net.panels.first{$0.id=="edge"}),local=edge.polygon.map(back.projection!.sourceToLocal.apply)
    XCTAssertTrue(local.contains(.init(0,20)));XCTAssertTrue(local.contains(.init(10,30)),"Reverse contour must reflect the actual asymmetric cut piece.")
    let holes=try XCTUnwrap(net.panels.first{$0.id=="face"}?.cutouts?.first).polygon.map(back.projection!.sourceToLocal.apply)
    XCTAssertTrue(holes.contains(.init(35,5)));XCTAssertTrue(holes.contains(.init(31,9)))
    let links=LinkedInspectorRelationships.table(owner,in:project)
    XCTAssertEqual(links.count,4);XCTAssertEqual(Set(links.map(\.id)).count,4)
    for link in links {
      guard case .constructionPiece(let componentID,let inside)=link.kind else{continue}
      let proof=try frame(store,id,componentID,inside)
      XCTAssertEqual(link.sourceID,proof.projection?.sourceID,"Lightweight inspector navigation must share the exact canonical source used by Canvas.")
      XCTAssertEqual(link.title,proof.title.replacingOccurrences(of:owner.name+" · ",with:""))
    }
    let link=try XCTUnwrap(links.first{$0.kind == .constructionPiece("facing-piece",inside:true)})
    let content=try XCTUnwrap(LinkedInspectorArtwork.content(link,in:project,guides:false))
    XCTAssertEqual(content.size,.init(40,30));XCTAssertEqual(content.stockColor,"#DFE4B0");XCTAssertNotNil(content.net)
    let thumbnail=LinkedInspectorArtworkView();thumbnail.update(content,assets:FileManager.default.temporaryDirectory)
    XCTAssertNotNil(thumbnail.renderedImage())
    let before=try XCTUnwrap(store.project),selection=store.engine.selection,camera=store.scene?.camera
    for value in frames {session.activate(value.id);XCTAssertEqual(session.paperContext?.id,id)}
    XCTAssertTrue(LinkedInspectorRelationships.openCanvas(link,store:store));XCTAssertEqual(session.activeFrameID,back.id)
    XCTAssertEqual(store.engine.selection,selection);XCTAssertEqual(store.scene?.camera,camera);XCTAssertFalse(store.tableInspectorVisible)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testFaceEditChangesOneCanonicalSourceAndAllLinkedViewsUndoAndReopenExactly()throws {
    let(store,id,frontID,_,_)=try fixture(),session=store.artworkSession
    let surface=try frame(store,id,"facing-piece",false,"face");session.activate(surface.id)
    let before=try XCTUnwrap(store.project),selection=store.engine.selection,camera=store.scene?.camera
    var edited=session.art;edited.elements[0].color="#AA2266";session.save(edited);session.endGesture()
    XCTAssertNil(store.error)
    let after=try XCTUnwrap(store.project),source=try XCTUnwrap(after.objects.first{$0.id==frontID})
    XCTAssertEqual(source.artwork?.elements[0].color,"#AA2266");XCTAssertEqual(source.artwork?.elements[0].x,8);XCTAssertEqual(source.artwork?.elements[0].width,4)
    for object in after.objects where object.id != frontID {XCTAssertEqual(object,before.objects.first{$0.id==object.id})}
    XCTAssertEqual(try frame(store,id,"board-piece",false).artwork.elements[0].color,"#AA2266")
    XCTAssertEqual(try frame(store,id,"facing-piece",false).artwork.elements[0].color,"#AA2266")
    XCTAssertEqual(store.engine.undoStack.count,1);XCTAssertEqual(store.engine.selection,selection);XCTAssertEqual(store.scene?.camera,camera)
    store.engine.undo();session.reconcile();XCTAssertEqual(store.project,before)
    store.engine.redo();session.reconcile();XCTAssertEqual(store.project,after)
    try store.engine.flush();let reopened=try store.repository.load(after.id)
    XCTAssertEqual(reopened.objects,after.objects)
    let savedIDs=session.frames.filter{$0.projection?.constructionID==id}.map(\.id)
    store.engine.project=reopened;session.reconcile();XCTAssertEqual(session.frames.filter{$0.projection?.constructionID==id}.map(\.id),savedIDs)
    XCTAssertEqual(try frame(store,id,"facing-piece",false,"face").artwork.elements[0].color,"#AA2266")
  }
  func testLinkedPieceNavigationBeforeFirstCanvasMountFitsOnlyThatPhysicalPatternOnce()throws {
    let(store,id,_,_,_)=try fixture(),session=store.artworkSession,project=try XCTUnwrap(store.project)
    let owner=try XCTUnwrap(project.objects.first{$0.id==id})
    let link=try XCTUnwrap(LinkedInspectorRelationships.table(owner,in:project).first{$0.kind == .constructionPiece("facing-piece",inside:false)})
    let proof=try frame(store,id,"facing-piece",false),selection=store.engine.selection,camera=store.scene?.camera
    XCTAssertNil(session.canvas)
    XCTAssertTrue(LinkedInspectorRelationships.openCanvas(link,store:store))
    XCTAssertEqual(session.pendingCanvasFrameFocus?.frameIDs,[proof.id],"Navigation must survive the absence of a native Canvas.")
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:700,height:560),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let scroll=ArtworkScrollView(frame:.init(x:0,y:0,width:700,height:560));scroll.allowsMagnification=true
    scroll.minMagnification=0.08;scroll.maxMagnification=24
    let canvas=VectorCanvasView();scroll.documentView=canvas;canvas.session=session;session.canvas=canvas
    window.contentView=scroll;window.contentView?.layoutSubtreeIfNeeded();canvas.synchronize();scroll.tile();canvas.fitWhenReady()
    addTeardownBlock { @MainActor in window.contentView=nil;window.close() }
    XCTAssertNil(session.pendingCanvasFrameFocus)
    XCTAssertTrue(canvas.unobscuredVisibleCanvasRect.contains(proof.rect))
    XCTAssertLessThan(canvas.unobscuredVisibleCanvasRect.width,proof.rect.width*3,"Fit must use the cut-piece crop, not the entire construction frame column.")
    XCTAssertGreaterThan(scroll.magnification,1)
    canvas.setZoom(0.7);let chosenZoom=scroll.magnification
    canvas.fitWhenReady();canvas.synchronize();canvas.fitWhenReady()
    XCTAssertEqual(scroll.magnification,chosenZoom,accuracy:1e-9,"Consumed navigation must not refit during later layouts or source updates.")
    XCTAssertEqual(store.project,project);XCTAssertEqual(store.engine.selection,selection);XCTAssertEqual(store.scene?.camera,camera)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testComponentLinkedToEmbeddedPaperInsideMigratesTheActualSourceOwnerInOneUndo()throws {
    let(store,id,_,_,_)=try fixture();var project=try XCTUnwrap(store.project)
    let definition=PlanarConstructionDefinition(name:"Canonical two-sided sheet",size:.init(100,80),stockThickness:0.4,panels:[
      .init(id:"sheet",name:"Sheet",polygon:[.init(0,0),.init(100,0),.init(100,80),.init(0,80)])],rootPanelID:"sheet")
    project.recipes.append(.init("embedded-source-sheet","Canonical sheet","square","Generic source",[.init("fold","Fold",100,0...100),.init("opening","Opening",0,0...100)]))
    var source=try project.makeObject(recipeID:"embedded-source-sheet",name:"Actual embedded reverse owner")
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:100,height:80,depth:0.4),stock:.init(thicknessMM:0.4),insideArtwork:.init(elements:[.init(kind:"rectangle",x:8,y:13,width:4,height:5,color:"#123456")]))
    paper.authored=definition;source.paperConstruction=paper;source.canvasSourceOnly=true
    project.objects.append(source);project.objects[0].paperConstruction!.authored!.components![1].back = .init(sourceObjectID:source.id,sourceSide:.inside,sourceOriginMM:.init(5,7))
    project.schemaVersion=project.minimumSchemaVersion;store.engine.project=project
    let reverse=try frame(store,id,"facing-piece",true,"face"),session=store.artworkSession
    session.activate(reverse.id);XCTAssertEqual(session.paperContext?.id,id)
    XCTAssertEqual(session.sourceArtwork.elements.first?.color,"#123456")
    XCTAssertTrue(session.activeProjection?.requiresInsideSource==true)
    var edited=session.art;edited.elements[0].color="#BB6699";session.save(edited);session.endGesture()
    XCTAssertNil(store.error)
    let after=try XCTUnwrap(store.project),changedSource=try XCTUnwrap(after.objects.first{$0.id==source.id})
    let insideID=try XCTUnwrap(changedSource.paperConstruction?.insideArtworkSourceID)
    XCTAssertEqual(after.objects.first{$0.id==insideID}?.artwork?.elements.first?.color,"#BB6699")
    XCTAssertNil(after.objects[0].paperConstruction?.insideArtworkSourceID,"The physical consumer must never acquire the source owner's reverse sheet.")
    XCTAssertEqual(after.objects[0],project.objects[0]);XCTAssertEqual(session.objectID,insideID)
    XCTAssertEqual(session.activeFrameID,reverse.id);XCTAssertEqual(store.engine.undoStack.count,1)
    store.engine.undo();session.reconcile();XCTAssertEqual(store.project,project)
    XCTAssertEqual(session.activeFrameID,reverse.id);XCTAssertEqual(session.sourceArtwork.elements.first?.color,"#123456")
    store.engine.redo();session.reconcile();XCTAssertEqual(store.project,after);XCTAssertEqual(session.objectID,insideID)
  }
}

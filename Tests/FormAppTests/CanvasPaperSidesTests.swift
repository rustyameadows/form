import AppKit
import FormCADModel
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasPaperSidesTests:XCTestCase {
  @MainActor private final class Fixture {
    let directory:URL,store:StudioStore,paperID:UUID,tableID:UUID
    var session:ArtworkSession {store.artworkSession}
    var window:NSWindow?,canvas:VectorCanvasView?
    init(inside:Artwork?=nil,independent:Bool=false)throws {
      _ = NSApplication.shared
      directory=FileManager.default.temporaryDirectory.appendingPathComponent("paper-sides-"+UUID().uuidString)
      store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
      var project=Project(name:"Two editable physical faces")
      let definition=PlanarConstructionDefinition(name:"Unregistered window card",size:.init(30,20),stockThickness:1,panels:[
        .init(id:"sheet",name:"Sheet",polygon:[.init(0,0),.init(30,0),.init(30,20),.init(0,20)],artworkRotationDegrees:90,
          cutouts:[.init(id:"window",polygon:[.init(20,4),.init(24,4),.init(24,8),.init(20,8)],kind:.window)])],rootPanelID:"sheet")
      project.recipes.append(.init("duplex-canvas-fixture","Unregistered window card","square","Generic authored paper",[
        .init("fold","Fold",100,0...100),.init("opening","Opening",0,0...100)]))
      var paper=try project.makeObject(recipeID:"duplex-canvas-fixture")
      var settings=PaperConstruction(kind:.authored,dimensions:.init(width:30,height:20,depth:1),stock:.init(thicknessMM:1));settings.authored=definition
      settings.insideArtwork=inside
      paper.artwork = .init(elements:[.init(kind:"rectangle",x:2,y:3,width:4,height:3,color:"#225588")])
      if independent {
        var source=try project.makeObject(recipeID:"artboard",name:"Existing bottom",parameters:["width":30,"depth":20])
        source.artwork=inside ?? .init(elements:[.init(kind:"text",x:3,y:9,text:"Bottom",fontSize:8)])
        source.canvasSourceOnly=true;project.objects.append(source);settings.insideArtworkSourceID=source.id;settings.insideArtwork=nil
      }
      if let target=inside?.elements.first {settings.finishes=[.init(name:"Retained bottom target",kind:.emboss,side:.inside,elementIDs:[target.id],heightMM:0.05)]}
      paper.paperConstruction=settings
      let table=try project.makeObject(recipeID:"box",position:.init(500,0,400))
      paperID=paper.id;tableID=table.id;project.objects.insert(paper,at:0);project.objects.append(table);project.schemaVersion=project.minimumSchemaVersion
      store.engine.project=project;store.showingHome=false;store.environment = .form;store.mode = .artwork
      store.select(table.id);store.tableInspectorVisible=false;session.activate(paperID)
      let scene=TableSceneController(store:store);var camera=project.camera;camera.azimuth=1.1;camera.distance=16;camera.target = .init(4,2,8);scene.camera=camera;store.scene=scene
    }
    func frame(inside:Bool,proof:Bool=false)throws->CanvasFrame {
      try XCTUnwrap(session.frames.first{$0.projection?.constructionID==paperID && $0.projection?.inside==inside && $0.projection?.isProof==proof})
    }
    func mount() {
      let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false
      let scroll=ArtworkScrollView(frame:window.contentView!.bounds),canvas=VectorCanvasView(frame:scroll.bounds)
      scroll.allowsMagnification=true;scroll.minMagnification=0.08;scroll.maxMagnification=24
      canvas.session=session;session.canvas=canvas;scroll.documentView=canvas;window.contentView=scroll
      self.window=window;self.canvas=canvas;window.makeFirstResponder(canvas);canvas.synchronize();canvas.fit(all:false)
    }
    func mouse(_ type:NSEvent.EventType,_ local:Point2)throws->NSEvent {
      let canvas=try XCTUnwrap(canvas),frame=try XCTUnwrap(session.activeCanvasFrame)
      let point=canvas.documentPoint(.init(x:frame.rect.minX+local.x,y:frame.rect.minY+local.y))
      return try XCTUnwrap(NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:canvas.window?.windowNumber ?? 0,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1))
    }
    func close() {canvas?.finishText();window?.contentView=nil;window?.close();store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
  }

  func testBlankTopAndBottomAndBothDielinesAreStableReadOnlyFramesWithIndependentNavigation()throws {
    let f=try Fixture();defer{f.close()}
    let before=try XCTUnwrap(f.store.project),frames=f.session.frames,camera=f.store.scene?.camera
    XCTAssertEqual(frames.count,4);XCTAssertEqual(Set(frames.map(\.id)).count,4)
    let top=try f.frame(inside:false),bottom=try f.frame(inside:true),topProof=try f.frame(inside:false,proof:true),bottomProof=try f.frame(inside:true,proof:true)
    XCTAssertTrue(top.title.hasSuffix(" · Top"));XCTAssertTrue(bottom.title.hasSuffix(" · Bottom"))
    XCTAssertTrue(topProof.title.hasSuffix("Top dieline"));XCTAssertTrue(bottomProof.title.hasSuffix("Bottom dieline"))
    XCTAssertTrue(bottom.projection?.requiresInsideSource==true);XCTAssertTrue(bottom.artwork.elements.isEmpty);XCTAssertEqual(bottom.artwork.backgroundOpacity,0)
    for first in frames.indices {for second in frames.indices where first<second {XCTAssertFalse(frames[first].rect.intersects(frames[second].rect))}}
    let builds=f.session.frameBuildCount
    for _ in 0..<20 {
      f.session.activate(bottom.id);f.store.setPaperInside(false,object:before.objects[0]);f.store.setPaperInside(true,object:before.objects[0])
      XCTAssertTrue(f.session.activeProjection?.inside==true);XCTAssertEqual(f.session.activeProjection?.panelID,"sheet")
      XCTAssertEqual(f.session.frames.map(\.id),frames.map(\.id));XCTAssertEqual(f.session.frames.map(\.rect),frames.map(\.rect))
    }
    XCTAssertEqual(f.session.frameBuildCount,builds);XCTAssertEqual(f.store.project,before)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty);XCTAssertEqual(f.store.engine.selection,[f.tableID]);XCTAssertEqual(f.store.scene?.camera,camera);XCTAssertFalse(f.store.tableInspectorVisible)
    let links=LinkedInspectorRelationships.table(before.objects[0],in:before)
    XCTAssertEqual(links.map(\.title),["Top dieline","Bottom dieline"])
  }

  func testNativeFirstBottomDrawContinuesItsHeldGestureAndUndoesSourceCreationExactlyOnce()throws {
    let f=try Fixture();defer{f.close()}
    let bottom=try f.frame(inside:true),before=try XCTUnwrap(f.store.project),camera=f.store.scene?.camera
    f.session.activate(bottom.id);f.mount();f.session.tool = .rectangle
    let canvas=try XCTUnwrap(f.canvas)
    canvas.mouseDown(with:try f.mouse(.leftMouseDown,.init(2,3)))
    canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,.init(9,12)))
    canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,.init(13,17)))
    canvas.mouseUp(with:try f.mouse(.leftMouseUp,.init(13,17)))
    XCTAssertNil(f.store.error)
    let after=try XCTUnwrap(f.store.project),paper=after.objects[0],sourceID=try XCTUnwrap(paper.paperConstruction?.insideArtworkSourceID)
    let source=try XCTUnwrap(after.objects.first{$0.id==sourceID}),element=try XCTUnwrap(f.session.art.elements.first)
    XCTAssertTrue(source.canvasSourceOnly==true);XCTAssertFalse(source.hasTablePresentation);XCTAssertEqual(source.artwork?.backgroundOpacity,0)
    XCTAssertEqual(after.objects.count,before.objects.count+1);XCTAssertEqual(paper.artwork,before.objects[0].artwork)
    XCTAssertEqual(f.session.objectID,sourceID);XCTAssertEqual(f.session.activeFrameID,bottom.id)
    let bounds=f.session.art.bounds(of:element)
    XCTAssertEqual(bounds.x,2,accuracy:1e-8);XCTAssertEqual(bounds.y,3,accuracy:1e-8)
    XCTAssertEqual(bounds.width,11,accuracy:1e-8);XCTAssertEqual(bounds.height,14,accuracy:1e-8)
    XCTAssertEqual(f.store.engine.undoStack.count,1);XCTAssertEqual(f.store.engine.selection,[f.tableID]);XCTAssertEqual(f.store.scene?.camera,camera)
    f.store.engine.undo();f.session.reconcile();XCTAssertEqual(f.store.project,before)
    XCTAssertEqual(f.session.activeFrameID,bottom.id);XCTAssertTrue(f.session.activeProjection?.requiresInsideSource==true)
    f.store.engine.redo();f.session.reconcile();XCTAssertEqual(f.store.project,after)
    XCTAssertEqual(f.session.activeFrameID,bottom.id);XCTAssertEqual(f.session.objectID,sourceID)
    try f.store.engine.flush()
    let reopened=try f.store.repository.load(after.id)
    // The package's established ISO-8601 codec stores dates at whole seconds.
    // Compare every saved field through that codec, and geometry/source data exactly.
    let persisted=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(after))
    XCTAssertEqual(reopened,persisted);XCTAssertEqual(reopened.objects,after.objects)
  }

  func testEscapeDuringFirstBottomDrawRemovesTheProvisionalSourceAndLateEventsCannotRecreateIt()throws {
    let f=try Fixture();defer{f.close()}
    let bottom=try f.frame(inside:true),before=try XCTUnwrap(f.store.project)
    f.session.activate(bottom.id);f.mount();f.session.tool = .rectangle
    let canvas=try XCTUnwrap(f.canvas)
    canvas.mouseDown(with:try f.mouse(.leftMouseDown,.init(2,3)))
    canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,.init(12,16)))
    XCTAssertNotNil(f.store.project?.objects[0].paperConstruction?.insideArtworkSourceID)
    canvas.keyDown(with:try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:f.window?.windowNumber ?? 0,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)))
    canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,.init(14,18)));canvas.mouseUp(with:try f.mouse(.leftMouseUp,.init(14,18)))
    f.session.reconcile()
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertEqual(f.session.activeFrameID,bottom.id);XCTAssertTrue(f.session.activeProjection?.requiresInsideSource==true)
  }

  func testExistingInspectorInteractionSurvivesFirstBottomSaveAndNonlocalCommandCannotWriteOutside()throws {
    let f=try Fixture();defer{f.close()}
    let before=try XCTUnwrap(f.store.project),bottom=try f.frame(inside:true)
    f.session.activate(bottom.id)
    let colorTarget=f.session.inspectorColorTarget("background")
    let token=f.store.engine.beginInteraction("artwork-\(f.paperID)")
    f.session.mutate{$0.background="#334455";$0.backgroundOpacity=1}
    let sourceID=try XCTUnwrap(f.store.project?.objects[0].paperConstruction?.insideArtworkSourceID)
    XCTAssertEqual(f.session.inspectorColorTarget("background"),colorTarget)
    f.session.mutate{$0.background="#667788"}
    XCTAssertTrue(f.store.engine.isInteracting(withGeneration:token));XCTAssertEqual(f.store.engine.undoStack.count,1)
    XCTAssertEqual(f.session.objectID,sourceID);XCTAssertEqual(f.session.sourceArtwork.background,"#667788")
    XCTAssertEqual(f.store.project?.objects[0].artwork,before.objects[0].artwork)
    f.store.engine.endInteraction(ifGeneration:token)
    f.store.engine.undo();f.session.reconcile();XCTAssertEqual(f.store.project,before)
    f.session.execute("language",["language":"fr"])
    XCTAssertNil(f.store.error);XCTAssertEqual(f.session.sourceArtwork.language,"fr")
    XCTAssertEqual(f.store.project?.objects[0].artwork,before.objects[0].artwork);XCTAssertEqual(f.store.engine.undoStack.count,1)
    f.store.engine.undo();f.session.reconcile();XCTAssertEqual(f.store.project,before)
  }

  func testLegacyInlineBottomMigratesOnFirstEditKeepingMasksAndMetadataInOneUndo()throws {
    var legacy=Artwork(elements:[.init(kind:"text",x:4,y:9,width:15,height:4,text:"Legacy bottom",fontSize:8)])
    legacy.backgroundOpacity=0;legacy.guides=[.init(axis:"x",position:7)];legacy.language="fr"
    let f=try Fixture(inside:legacy);defer{f.close()}
    let before=try XCTUnwrap(f.store.project),bottom=try f.frame(inside:true)
    f.session.activate(bottom.id);XCTAssertEqual(f.session.sourceArtwork,legacy)
    let new=ArtworkElement(kind:"rectangle",x:2,y:3,width:4,height:5,color:"#773355")
    f.session.add([new]);XCTAssertNil(f.store.error)
    let after=try XCTUnwrap(f.store.project),sourceID=try XCTUnwrap(after.objects[0].paperConstruction?.insideArtworkSourceID),source=try XCTUnwrap(after.objects.first{$0.id==sourceID}?.artwork)
    XCTAssertNil(after.objects[0].paperConstruction?.insideArtwork)
    XCTAssertEqual(source.elements.filter{$0.id != new.id},legacy.elements);XCTAssertEqual(source.guides,legacy.guides);XCTAssertEqual(source.language,legacy.language)
    XCTAssertEqual(after.objects[0].artwork,before.objects[0].artwork)
    XCTAssertEqual(after.objects[0].paperConstruction?.finishes,before.objects[0].paperConstruction?.finishes)
    XCTAssertTrue(try PaperAppearance.inspect(project:after,object:after.objects[0]).finishes.allSatisfy{$0.missingElementIDs.isEmpty})
    XCTAssertEqual(f.store.engine.undoStack.count,1)
    f.store.engine.undo();f.session.reconcile();XCTAssertEqual(f.store.project,before)
    f.store.engine.redo();f.session.reconcile();XCTAssertEqual(f.store.project,after)
  }

  func testEachFacePositionPersistsIndependentlyAndFoldedGoodsKeepOutsideInsideLabels()throws {
    let f=try Fixture(independent:true);defer{f.close()}
    let top=try f.frame(inside:false),bottom=try f.frame(inside:true),before=try XCTUnwrap(f.store.project)
    f.session.activate(bottom.id);f.session.moveCanvasFrame(to:.init(-500,400));f.session.endGesture()
    XCTAssertEqual(try f.frame(inside:false).rect,top.rect);XCTAssertEqual(try f.frame(inside:true).rect.origin,.init(x:-500,y:400))
    f.store.engine.undo();XCTAssertEqual(f.store.project,before);f.store.engine.redo();try f.store.engine.flush()
    let reopened=try f.store.repository.load(before.id),newKey=try XCTUnwrap(bottom.projection?.key)
    XCTAssertEqual(reopened.objects[0].canvasProjectionPositions?[newKey],.init(-500,400))
    let folded=try PaperSamples.cosmetics(),object=try XCTUnwrap(folded.objects.first{PaperConstruction.isPaper($0)})
    XCTAssertEqual(PaperSideLabels.title(inside:false,object:object),"Outside");XCTAssertEqual(PaperSideLabels.title(inside:true,object:object),"Inside")
  }

  func testLockedPhysicalOwnerRejectsBlankAndExistingBottomWritesWithoutPartialSourceOrHistory()throws {
    for existing in [false,true] {
      let f=try Fixture(independent:existing);defer{f.close()}
      var locked=try XCTUnwrap(f.store.project);locked.objects[0].locked=true;f.store.engine.project=locked
      f.session.activate(try f.frame(inside:true).id)
      XCTAssertFalse(try XCTUnwrap(f.session.activeCanvasFrame).editable)
      f.session.add([.init(kind:"text",x:1,y:1,text:"Forbidden")])
      XCTAssertNotNil(f.store.error);XCTAssertEqual(f.store.project,locked);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
      f.store.error=nil;f.session.execute("language",["language":"fr"])
      XCTAssertNotNil(f.store.error);XCTAssertEqual(f.store.project,locked);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    }
  }
}

import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasOnlySourcePresentationTests:XCTestCase {
  func testSupportComponentDefinitionsStayOutOfFramesAndFitUntilExplicitlyOpened()throws {
    _ = NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("component-source-presentation-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:900,height:650),
      styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    defer {
      store.artworkSession.canvas?.finishText();window.contentView=nil;window.close()
      store.engine.project=nil;try? FileManager.default.removeItem(at:directory)
    }
    var project=Project(name:"Component resources are not Canvas frames")
    let workspace=try project.ensureCanvasWorkspace()
    project.objects[0].artwork?.elements=[.init(kind:"rectangle",x:10,y:10,width:300,height:200)]
    var sheet=try project.makeObject(recipeID:"artboard",name:"Visible artboard",
      parameters:["width":100,"depth":80])
    sheet.artwork = .init();sheet.artwork?.canvasPosition = .init(500,300)
    var legacy=try project.makeObject(recipeID:"artboard",name:"Authored component frame",
      parameters:["width":40,"depth":30])
    legacy.componentDefinition=true;legacy.artwork = .init()
    legacy.artwork?.canvasPosition = .init(20,400)
    project.objects += [sheet,legacy]
    store.engine.project=project;store.showingHome=false;store.mode = .artwork
    let session=store.artworkSession;session.activate(workspace.id)
    let scroll=ArtworkScrollView(frame:window.contentView!.bounds)
    scroll.allowsMagnification=true;scroll.minMagnification=0.08;scroll.maxMagnification=24
    let canvas=VectorCanvasView(frame:scroll.bounds)
    canvas.session=session;session.canvas=canvas;scroll.documentView=canvas;window.contentView=scroll
    canvas.synchronize();canvas.fit(all:true)
    let originalFrames=session.frames.map(\.id),originalRects=session.frames.map(\.rect)
    let originalBounds=canvas.contentBounds(all:true),originalZoom=scroll.magnification
    XCTAssertEqual(originalFrames,[workspace.id,sheet.id,legacy.id])

    var source=try project.makeObject(recipeID:"artboard",name:"Study badge/component",
      parameters:["width":30,"depth":20])
    let ink=ArtworkElement(kind:"rectangle",x:0,y:0,width:30,height:20,color:"#15A060")
    source.componentDefinition=true;source.canvasSourceOnly=true
    source.artwork = .init(elements:[ink]);source.artwork?.canvasPosition = .init(-900,-800)
    var instance=ArtworkElement(kind:"group",x:180,y:140,width:30,height:20)
    instance.component = .init(sourceObjectID:source.id);instance.contentSize = .init(30,20)
    project.objects[0].artwork?.elements.append(instance)
    project.objects.insert(source,at:0)
    store.engine.project=project;session.reconcile();canvas.synchronize();canvas.fit(all:true)
    let before=try XCTUnwrap(store.project),history=store.engine.undoStack.count
    XCTAssertEqual(session.frames.map(\.id),originalFrames,"The Canvas & Surfaces list must omit support definitions.")
    XCTAssertEqual(session.frames.map(\.rect),originalRects,"Resources must not displace real frame layouts.")
    XCTAssertEqual(canvas.contentBounds(all:true),originalBounds)
    XCTAssertEqual(scroll.magnification,originalZoom,accuracy:1e-9)
    let displayed=try XCTUnwrap(session.frames.first{$0.id==workspace.id})
    let resolvedID=ComponentCommands.derivedID(instance.id,ink.id)
    XCTAssertEqual(displayed.artwork.elements.first{$0.id==resolvedID}?.color,ink.color,
      "The instance must still resolve its hidden support definition into visible native ink.")
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,history)

    session.choose([instance.id]);session.editComponentSource(instance);session.reconcile();canvas.synchronize()
    XCTAssertEqual(session.activeCanvasFrame?.id,source.id)
    XCTAssertEqual(session.componentReturn?.objectID,workspace.id)
    XCTAssertEqual(session.sourceArtwork.elements.first?.id,ink.id)
    session.mutate { artwork in artwork.elements[0].color="#2244DD" }
    session.returnToComponent();session.reconcile();canvas.synchronize();canvas.fit(all:true)
    XCTAssertEqual(session.objectID,workspace.id);XCTAssertEqual(session.selection,[instance.id])
    XCTAssertEqual(session.frames.map(\.id),originalFrames)
    XCTAssertEqual(canvas.contentBounds(all:true),originalBounds)
    XCTAssertEqual(scroll.magnification,originalZoom,accuracy:1e-9)
    XCTAssertEqual(session.frames.first{$0.id==workspace.id}?.artwork.elements.first{$0.id==resolvedID}?.color,"#2244DD")
    XCTAssertEqual(store.engine.undoStack.count,history+1)
    store.engine.undo();session.reconcile();canvas.synchronize()
    XCTAssertEqual(store.project?.objects,before.objects)
    XCTAssertEqual(session.frames.map(\.id),originalFrames)
  }

  func testInsideSourceStaysEditableOnCanvasWithoutTableNodeOrFindTarget()throws {
    _ = NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("inside-source-native-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    defer{store.artworkSession.canvas?.finishText();store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    var p=Project(name:"Inside source presentation")
    let paper=try p.makeObject(recipeID:"paperEnvelope"),legacy=try p.makeObject(recipeID:"artboard",position:.init(-500,0,0))
    p.objects=[paper,legacy];store.engine.project=p;store.showingHome=false
    let response=try XCTUnwrap(store.engine.call("form_paper",arguments:["command":"ensure_inside","object_id":paper.id.uuidString]) as? [String:Any])
    let sourceID=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(response["inside_source_id"] as? String)))
    store.select(paper.id)
    let scene=TableSceneController(store:store),view=TableSceneView(frame:.init(x:0,y:0,width:800,height:600))
    view.controller=scene;scene.view=view;store.scene=scene;store.synchronizeScene()
    XCTAssertNotNil(scene.logicalNode(for:paper.id));XCTAssertNotNil(scene.logicalNode(for:legacy.id))
    XCTAssertNil(scene.logicalNode(for:sourceID))
    let before=store.project!,history=store.engine.undoStack.count,camera=scene.camera,selection=store.engine.selection
    store.artworkSession.activate(sourceID);store.artworkSession.reconcile()
    XCTAssertEqual(store.artworkSession.objectID,sourceID)
    XCTAssertTrue(store.artworkSession.activeProjection?.inside == true)
    XCTAssertTrue(store.artworkSession.frames.contains{$0.projection?.sourceID==sourceID})
    XCTAssertFalse(store.findOnTable(sourceID))
    XCTAssertEqual(store.engine.selection,selection);XCTAssertEqual(scene.camera,camera)
    XCTAssertEqual(store.project!.objects,before.objects);XCTAssertEqual(store.engine.undoStack.count,history)
    let text=ArtworkElement(kind:"text",x:20,y:30,width:60,height:12,text:"Canonical inside text",fontSize:10)
    store.artworkSession.add([text])
    let edited=try XCTUnwrap(store.project!.objects.first{$0.id==sourceID})
    XCTAssertTrue(edited.artwork?.elements.contains{$0.id==text.id && $0.text==text.text} == true)
    XCTAssertEqual(edited.canvasSourceOnly,true);XCTAssertFalse(edited.hasTablePresentation)
    XCTAssertEqual(store.engine.undoStack.count,history+1)
    store.synchronizeScene();XCTAssertNil(scene.logicalNode(for:sourceID))
    XCTAssertEqual(try StudioVisibility().resolved(in:store.project!),[paper.id,legacy.id])
    try store.engine.flush();let reopened=try store.repository.load(p.id)
    XCTAssertEqual(reopened.objects,store.project!.objects);XCTAssertEqual(reopened.physicalObjectCount,2)
  }
}

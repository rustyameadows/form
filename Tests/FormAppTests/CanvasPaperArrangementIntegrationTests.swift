import AppKit
import FormCADModel
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasPaperArrangementIntegrationTests:XCTestCase {
  @MainActor private final class Fixture {
    let directory:URL,store:StudioStore,session:ArtworkSession,window:NSWindow,canvas:VectorCanvasView
    let paperID:UUID,outsideID:UUID,insideID:UUID,tableID:UUID,elementIDs:[UUID]
    let activeSourceID:UUID,otherSourceID:UUID,frameID:UUID
    let camera:CameraState

    init(inside:Bool)throws {
      _ = NSApplication.shared
      directory=FileManager.default.temporaryDirectory.appendingPathComponent("paper-arrangement-"+UUID().uuidString)
      store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
      var project=Project(name:"Shared paper arrangement commands")
      let definition=PlanarConstructionDefinition(name:"Quarter-turn paper sheet",size:.init(80,140),panels:[
        .init(id:"sheet",name:"Rotated sheet",polygon:[.init(0,0),.init(80,0),.init(80,140),.init(0,140)],artworkRotationDegrees:90)],rootPanelID:"sheet")
      var paper=PaperConstruction(kind:.authored,dimensions:.init(width:80,height:140,depth:1));paper.authored=definition
      let recipe=Recipe("paper-arrangement-fixture","Paper arrangement","square","Authored regression data",[
        .init("fold","Fold",100,0...100),.init("opening","Opening",0,0...100)])
      project.recipes.append(recipe)
      var physical=try project.makeObject(recipeID:recipe.id)
      var outside=try project.makeObject(recipeID:"artboard",name:"Outside canonical",parameters:["width":80,"depth":140])
      var reverse=try project.makeObject(recipeID:"artboard",name:"Inside canonical",parameters:["width":80,"depth":140])
      outside.canvasSourceOnly=true;reverse.canvasSourceOnly=true
      func artwork(_ isInside:Bool)throws->Artwork {
        var local=Artwork(elements:[
          .init(kind:"rectangle",x:10,y:10,width:14,height:10,color:"#225588"),
          .init(kind:"rectangle",x:45,y:28,width:18,height:12,color:"#A85B32"),
          .init(kind:"rectangle",x:100,y:42,width:12,height:14,color:"#447755")])
        local.backgroundOpacity=0;local.snapEnabled=false
        let frame=try PhysicalArtworkFrame.paper(net:definition.net(),panelID:"sheet",inside:isInside)
        return try frame.source(from:local,original:Artwork())
      }
      outside.artwork=try artwork(false);reverse.artwork=try artwork(true)
      physical.artwork=nil;physical.artworkSourceID=outside.id;physical.artworkFit="actual"
      paper.insideArtworkSourceID=reverse.id
      paper.finishes=[
        .init(name:"Outside foil target",kind:.foil,elementIDs:[outside.artwork!.elements[0].id],color:"#B88C45"),
        .init(name:"Inside press target",kind:.letterpress,side:.inside,elementIDs:[reverse.artwork!.elements[0].id],depthMM:0.04)]
      physical.paperConstruction=paper
      let table=try project.makeObject(recipeID:"box",name:"Independent Table selection",position:.init(500,0,300))
      project.objects=[physical,outside,reverse,table];project.schemaVersion=project.minimumSchemaVersion
      paperID=physical.id;outsideID=outside.id;insideID=reverse.id;tableID=table.id
      activeSourceID=inside ? reverse.id:outside.id;otherSourceID=inside ? outside.id:reverse.id
      elementIDs=(inside ? reverse:outside).artwork!.elements.map(\.id)
      store.engine.project=project;store.showingHome=false;store.environment = .form;store.mode = .artwork
      store.select(table.id);store.activatePaperArtwork(physical)
      session=store.artworkSession
      if inside {session.activate(reverse.id)}
      let frame=try XCTUnwrap(session.frames.first{$0.projection?.constructionID==physical.id && $0.projection?.panelID=="sheet" && $0.projection?.inside==inside})
      frameID=frame.id;session.activate(frame.id)
      store.tableInspectorVisible=inside
      let scene=TableSceneController(store:store)
      var retained=project.camera;retained.target = .init(7,3,5);retained.distance=17;retained.azimuth=1.1
      scene.camera=retained;store.scene=scene;camera=retained
      window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false
      let scroll=ArtworkScrollView(frame:window.contentView!.bounds)
      scroll.allowsMagnification=true;scroll.minMagnification=0.08;scroll.maxMagnification=24
      canvas=VectorCanvasView(frame:scroll.bounds);canvas.session=session;session.canvas=canvas;scroll.documentView=canvas
      window.contentView=scroll;window.makeFirstResponder(canvas);canvas.synchronize();canvas.fit(all:false)
    }
    func close() {
      canvas.finishText();window.contentView=nil;window.close();store.engine.project=nil
      try? FileManager.default.removeItem(at:directory)
    }
    func bounds()->[Rect2] {
      let artwork=session.art
      return elementIDs.compactMap{id in artwork.elements.first{$0.id==id}.map{artwork.bounds(of:$0)}}
    }
    func menu()throws->NSMenu {
      let local=try XCTUnwrap(bounds().first),frame=try XCTUnwrap(session.activeCanvasFrame)
      let point=CGPoint(x:frame.rect.minX+local.x+local.width/2,y:frame.rect.minY+local.y+local.height/2)
      let event=try XCTUnwrap(NSEvent.mouseEvent(with:.rightMouseDown,location:canvas.convert(canvas.documentPoint(point),to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
      return try XCTUnwrap(canvas.menu(for:event))
    }
    func invoke(_ title:String,in menu:NSMenu)throws {
      let item=try XCTUnwrap(menu.items.first{$0.title==title})
      XCTAssertTrue(item.isEnabled,title)
      XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action),to:item.target,from:item))
      XCTAssertNil(store.error)
    }
    func submenu(_ title:String,in menu:NSMenu)throws->NSMenu {try XCTUnwrap(menu.items.first{$0.title==title}?.submenu)}
  }

  private func assertContext(_ f:Fixture,baseline:Project,inspector:Bool,file:StaticString=#filePath,line:UInt=#line)throws {
    let project=try XCTUnwrap(f.store.project,file:file,line:line)
    XCTAssertEqual(f.session.objectID,f.activeSourceID,file:file,line:line)
    XCTAssertEqual(f.session.activeFrameID,f.frameID,file:file,line:line)
    XCTAssertEqual(f.store.engine.selection,[f.tableID],file:file,line:line)
    XCTAssertEqual(f.store.scene?.camera,f.camera,file:file,line:line)
    XCTAssertEqual(f.store.tableInspectorVisible,inspector,file:file,line:line)
    XCTAssertEqual(project.objects.first{$0.id==f.otherSourceID},baseline.objects.first{$0.id==f.otherSourceID},file:file,line:line)
    XCTAssertEqual(project.objects.first{$0.id==f.paperID},baseline.objects.first{$0.id==f.paperID},file:file,line:line)
    let reverse=try XCTUnwrap(project.objects.first{$0.id==f.insideID},file:file,line:line)
    XCTAssertTrue(reverse.canvasSourceOnly==true,file:file,line:line);XCTAssertFalse(reverse.hasTablePresentation,file:file,line:line)
    let paper=try XCTUnwrap(project.objects.first{$0.id==f.paperID},file:file,line:line)
    let report=try PaperAppearance.inspect(project:project,object:paper)
    XCTAssertTrue(report.finishes.allSatisfy{$0.missingElementIDs.isEmpty},file:file,line:line)
    XCTAssertEqual(report.finishes.map(\.assignment),baseline.objects.first{$0.id==f.paperID}?.paperConstruction?.finishes ?? [],file:file,line:line)
    let source=try XCTUnwrap(project.objects.first{$0.id==f.activeSourceID}?.artwork,file:file,line:line)
    XCTAssertTrue(Set(f.elementIDs).isSubset(of:Set(source.elements.map(\.id))),file:file,line:line)
    XCTAssertEqual(project.objects.count,baseline.objects.count,file:file,line:line)
  }
  private func assertExactHistory(_ f:Fixture,snapshots:[Project],inspector:Bool)throws {
    for expected in snapshots.dropLast().reversed() {
      f.store.engine.undo();f.session.reconcile();f.canvas.synchronize()
      XCTAssertEqual(f.store.project,expected);try assertContext(f,baseline:snapshots[0],inspector:inspector)
    }
    for expected in snapshots.dropFirst() {
      f.store.engine.redo();f.session.reconcile();f.canvas.synchronize()
      XCTAssertEqual(f.store.project,expected);try assertContext(f,baseline:snapshots[0],inspector:inspector)
    }
  }

  func testOutsideQuarterTurnSharedArrangementAndGroupCommandsPreserveCanonicalTargetsAndExactHistory()throws {
    let f=try Fixture(inside:false);defer{f.close()}
    let baseline=try XCTUnwrap(f.store.project),initialBounds=f.bounds(),builds=f.session.frameBuildCount
    XCTAssertEqual(try XCTUnwrap(f.session.activeProjection).sourceToLocal.a,0,accuracy:1e-9)
    f.session.choose(Set(f.elementIDs))
    let top=try XCTUnwrap(CanvasArrangementAction.alignment.first{$0.mode=="top"})
    XCTAssertTrue(top.isEnabled(in:f.session));top.perform(in:f.session)
    let aligned=f.bounds();XCTAssertEqual(aligned.count,3)
    for bounds in aligned {XCTAssertEqual(bounds.y,initialBounds[0].y,accuracy:1e-8)}
    var snapshots=[baseline,try XCTUnwrap(f.store.project)]
    let spacing=try XCTUnwrap(CanvasArrangementAction.distribution.first{$0.mode=="horizontal"})
    XCTAssertTrue(spacing.isEnabled(in:f.session));spacing.perform(in:f.session)
    let distributed=f.bounds().sorted{$0.x<$1.x}
    XCTAssertEqual(distributed[1].x-distributed[0].maxX,distributed[2].x-distributed[1].maxX,accuracy:1e-8)
    snapshots.append(try XCTUnwrap(f.store.project));try assertContext(f,baseline:baseline,inspector:false)
    try f.invoke("Group",in:f.menu())
    let group=try XCTUnwrap(f.session.primary);XCTAssertEqual(group.kind,"group")
    XCTAssertEqual(Set(f.session.sourceArtwork.elements.filter{$0.parentID==group.id}.map(\.id)),Set(f.elementIDs))
    snapshots.append(try XCTUnwrap(f.store.project))
    try f.invoke("Ungroup",in:f.menu());snapshots.append(try XCTUnwrap(f.store.project))
    XCTAssertEqual(Set(f.session.sourceArtwork.elements.map(\.id)),Set(f.elementIDs))
    XCTAssertEqual(f.store.engine.undoStack.count,4)
    XCTAssertGreaterThan(f.session.frameBuildCount,builds,"Command edits must invalidate the exact-source frame memo.")
    try assertContext(f,baseline:baseline,inspector:false);try assertExactHistory(f,snapshots:snapshots,inspector:false)
  }

  func testInsideReflectedQuarterTurnNativeMenuArrangementPreservesIndependentSourceAndTableState()throws {
    let f=try Fixture(inside:true);defer{f.close()}
    let baseline=try XCTUnwrap(f.store.project),initial=f.bounds(),projection=try XCTUnwrap(f.session.activeProjection)
    XCTAssertTrue(projection.inside);XCTAssertLessThan(projection.sourceToLocal.a*projection.sourceToLocal.d-projection.sourceToLocal.b*projection.sourceToLocal.c,0)
    f.session.choose(Set(f.elementIDs))
    let align=try f.submenu("Align",in:f.menu());try f.invoke("Align Left",in:align)
    for bounds in f.bounds(){XCTAssertEqual(bounds.x,initial[0].x,accuracy:1e-8)}
    var snapshots=[baseline,try XCTUnwrap(f.store.project)]
    let distribute=try f.submenu("Distribute",in:f.menu());try f.invoke("Vertical Spacing",in:distribute)
    let arranged=f.bounds().sorted{$0.y<$1.y}
    XCTAssertEqual(arranged[1].y-arranged[0].maxY,arranged[2].y-arranged[1].maxY,accuracy:1e-8)
    snapshots.append(try XCTUnwrap(f.store.project));try assertContext(f,baseline:baseline,inspector:true)
    try f.invoke("Group",in:f.menu());snapshots.append(try XCTUnwrap(f.store.project))
    try f.invoke("Ungroup",in:f.menu());snapshots.append(try XCTUnwrap(f.store.project))
    XCTAssertEqual(f.store.engine.undoStack.count,4)
    XCTAssertEqual(Set(f.session.sourceArtwork.elements.map(\.id)),Set(f.elementIDs))
    try assertContext(f,baseline:baseline,inspector:true);try assertExactHistory(f,snapshots:snapshots,inspector:true)
  }
}

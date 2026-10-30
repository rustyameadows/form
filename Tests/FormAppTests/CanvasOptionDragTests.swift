import AppKit
import FormCADModel
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasOptionDragTests:XCTestCase {
  private enum ModifierSequence {case beforeDown,afterDown}
  @MainActor private final class Fixture {
    let directory:URL,store:StudioStore,session:ArtworkSession,window:NSWindow,canvas:VectorCanvasView
    let sourceID:UUID,rootIDs:Set<UUID>,paintID:UUID,paperID:UUID?,tableID:UUID?,destinationID:UUID?
    init(insidePaper:Bool=false,destination:Bool=false,destinationLocked:Bool=false)throws {
      _ = NSApplication.shared
      directory=FileManager.default.temporaryDirectory.appendingPathComponent("canvas-option-drag-"+UUID().uuidString)
      store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
      var project=Project(name:"Native copy-and-move")
      var group=ArtworkElement(kind:"group",x:20,y:20,width:36,height:30)
      group.name="Assembly";group.contentSize = .init(36,30);group.rotation=12
      var inner=ArtworkElement(kind:"group",x:4,y:5,width:22,height:18)
      inner.name="Nested";inner.parentID=group.id;inner.contentSize = .init(22,18)
      var mask=ArtworkElement(kind:"rectangle",x:0,y:0,width:22,height:18)
      mask.name="Clip mask";mask.parentID=inner.id
      var ink=ArtworkElement(kind:"path",x:4,y:3,width:12,height:10,color:"#246599")
      ink.name="Grouped ink";ink.parentID=inner.id;ink.clipID=mask.id
      ink.path = .init(width:12,height:10,contours:[.init([.init(.init(0,0)),.init(.init(12,0)),.init(.init(12,10)),.init(.init(0,10))])])
      var second=ArtworkElement(kind:"rectangle",x:65,y:100,width:22,height:20,color:"#A85D39");second.name="Second root"
      var artwork=Artwork(elements:[group,inner,mask,ink,second]);artwork.backgroundOpacity=0;artwork.snapEnabled=false
      rootIDs=[group.id,second.id];paintID=ink.id
      if insidePaper {
        let definition=PlanarConstructionDefinition(name:"Unregistered duplex sheet",size:.init(160,110),panels:[
          .init(id:"sheet",name:"Sheet",polygon:[.init(0,0),.init(160,0),.init(160,110),.init(0,110)],artworkRotationDegrees:90)],rootPanelID:"sheet")
        project.recipes.append(.init("option-drag-sheet","Duplex sheet","square","Generic authored fixture",[
          .init("fold","Fold",100,0...100),.init("opening","Opening",0,0...100)]))
        var physical=try project.makeObject(recipeID:"option-drag-sheet")
        var settings=PaperConstruction(kind:.authored,dimensions:.init(width:160,height:110,depth:1));settings.authored=definition
        var source=try project.makeObject(recipeID:"artboard",name:"Canonical bottom",parameters:["width":160,"depth":110])
        let frame=try PhysicalArtworkFrame.paper(net:definition.net(),panelID:"sheet",inside:true)
        source.artwork=try frame.source(from:artwork,original:Artwork());source.canvasSourceOnly=true
        settings.insideArtworkSourceID=source.id
        settings.finishes=[.init(name:"Original leaf remains the mask",kind:.foil,side:.inside,elementIDs:[ink.id],color:"#B08B43")]
        physical.paperConstruction=settings;physical.artwork = .init(elements:[.init(kind:"text",x:10,y:12,text:"Untouched top")])
        let table=try project.makeObject(recipeID:"box",name:"Independent selection",position:.init(500,0,400))
        project.objects=[physical,source,table];sourceID=source.id;paperID=physical.id;tableID=table.id;destinationID=nil
      } else {
        let workspace=try project.ensureCanvasWorkspace();sourceID=workspace.id;paperID=nil;tableID=nil
        project.objects[0].artwork=artwork
        if destination {
          var target=try project.makeObject(recipeID:"artboard",name:"Independent destination",parameters:["width":140,"depth":150])
          target.artwork=Artwork();target.artwork?.canvasPosition = .init(230,20);target.locked=destinationLocked
          destinationID=target.id;project.objects.append(target)
        } else {destinationID=nil}
      }
      project.schemaVersion=project.minimumSchemaVersion
      store.engine.project=project;store.showingHome=false;store.mode = .artwork
      session=store.artworkSession
      if let paperID,let tableID {
        store.select(tableID);session.activate(sourceID)
        let frame=try XCTUnwrap(session.frames.first{$0.projection?.constructionID==paperID && $0.projection?.inside==true && $0.projection?.panelID=="sheet"})
        session.activate(frame.id);store.tableInspectorVisible=false
        let scene=TableSceneController(store:store);var camera=project.camera;camera.target = .init(5,3,8);camera.azimuth=1.1;scene.camera=camera;store.scene=scene
      } else {session.activate(sourceID)}
      session.choose(rootIDs)
      window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false
      let scroll=ArtworkScrollView(frame:window.contentView!.bounds)
      scroll.allowsMagnification=true;scroll.minMagnification=0.08;scroll.maxMagnification=24
      canvas=VectorCanvasView(frame:scroll.bounds);canvas.session=session;session.canvas=canvas;scroll.documentView=canvas;window.contentView=scroll
      window.makeFirstResponder(canvas);canvas.synchronize();canvas.fit(all:false);canvas.setZoom(1)
    }
    func close() {canvas.finishText();window.contentView=nil;window.close();store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    func center(_ element:ArtworkElement,in artwork:Artwork)->Point2 {artwork.worldTransform(element).apply(.init(element.width/2,element.height/2))}
    func start()throws->CGPoint {
      let artwork=session.art,ink=try XCTUnwrap(artwork.elements.first{$0.id==paintID}),frame=try XCTUnwrap(session.activeCanvasFrame)
      let local=center(ink,in:artwork)
      let world=CGPoint(x:frame.rect.minX+local.x,y:frame.rect.minY+local.y)
      canvas.ensureViewportCoverage(preserving:world)
      return canvas.convert(canvas.documentPoint(world),to:nil)
    }
    func mouse(_ type:NSEvent.EventType,_ point:CGPoint,option:Bool)throws->NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:option ? .option:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1))
    }
    func optionChanged(_ active:Bool)throws {
      canvas.flagsChanged(with:try XCTUnwrap(NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:active ? .option:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:58)))
    }
    func begin(_ sequence:ModifierSequence)throws->CGPoint {
      let point=try start(),host=try XCTUnwrap(window.contentView)
      let hit=host.hitTest(host.superview?.convert(point,from:nil) ?? point)
      XCTAssertTrue(hit === canvas,"The real window must route the held gesture to the Canvas.")
      if sequence == .beforeDown {try optionChanged(true)}
      hit?.mouseDown(with:try mouse(.leftMouseDown,point,option:sequence == .beforeDown))
      if sequence == .afterDown {
        canvas.mouseDragged(with:try mouse(.leftMouseDragged,.init(x:point.x+1,y:point.y),option:false))
        try optionChanged(true)
      }
      return point
    }
    func endPoint(_ start:CGPoint,dx:Double,dy:Double)->CGPoint {
      let scale=canvas.zoom*72/25.4
      return .init(x:start.x+dx*scale,y:start.y-dy*scale)
    }
    func destinationPoint()throws->CGPoint {
      let id=try XCTUnwrap(destinationID),frame=try XCTUnwrap(session.frames.first{$0.id==id})
      return canvas.convert(canvas.documentPoint(.init(x:frame.rect.minX+20,y:frame.rect.minY+30)),to:nil)
    }
  }

  private func assertCopies(_ f:Fixture,original:Artwork,dx:Double,dy:Double,roots:Set<UUID>?=nil,file:StaticString=#filePath,line:UInt=#line)throws {
    let after=f.session.art,originalIDs=Set(original.elements.map(\.id)),copies=after.elements.filter{!originalIDs.contains($0.id)}
    let selectedRoots=roots ?? f.rootIDs,affected=original.descendants(of:selectedRoots)
    XCTAssertEqual(copies.count,affected.count,file:file,line:line)
    XCTAssertEqual(Set(copies.map(\.id)).count,copies.count,file:file,line:line)
    let mapping=try Dictionary(uniqueKeysWithValues:original.elements.filter{affected.contains($0.id)}.map{old -> (UUID,UUID) in
      let copy=try XCTUnwrap(copies.first{$0.name==old.name},file:file,line:line)
      return(old.id,copy.id)
    })
    XCTAssertEqual(f.session.selection,Set(selectedRoots.compactMap{mapping[$0]}),file:file,line:line)
    for old in original.elements {
      XCTAssertEqual(after.elements.first{$0.id==old.id},old,"Original layers must remain byte-for-byte unchanged.",file:file,line:line)
      guard affected.contains(old.id) else{continue}
      let copy=try XCTUnwrap(copies.first{$0.id==mapping[old.id]},file:file,line:line)
      XCTAssertEqual(copy.parentID,old.parentID.flatMap{mapping[$0] ?? $0},file:file,line:line)
      XCTAssertEqual(copy.clipID,old.clipID.flatMap{mapping[$0] ?? $0},file:file,line:line)
      let a=f.center(old,in:original),b=f.center(copy,in:after)
      XCTAssertEqual(b.x,a.x+dx,accuracy:1e-7,file:file,line:line);XCTAssertEqual(b.y,a.y+dy,accuracy:1e-7,file:file,line:line)
      let oldNodes=Set(old.path?.contours.flatMap{$0.nodes.map(\.id)} ?? [])
      let newNodes=Set(copy.path?.contours.flatMap{$0.nodes.map(\.id)} ?? [])
      XCTAssertEqual(newNodes.count,oldNodes.count,file:file,line:line);XCTAssertTrue(oldNodes.isDisjoint(with:newNodes),file:file,line:line)
    }
  }
  private func exercise(_ sequence:ModifierSequence,insidePaper:Bool=false)throws {
    let f=try Fixture(insidePaper:insidePaper);defer{f.close()}
    let before=try XCTUnwrap(f.store.project),original=f.session.art,canonical=f.session.sourceArtwork,frameID=f.session.activeFrameID,camera=f.store.scene?.camera
    let start=try f.begin(sequence)
    XCTAssertEqual(f.store.project,before,"Option and sub-threshold motion cannot create a copy.")
    let intermediate=f.endPoint(start,dx:5,dy:4),end=f.endPoint(start,dx:12,dy:9)
    f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,intermediate,option:true))
    let firstCopyIDs=Set(f.session.art.elements.map(\.id)).subtracting(original.elements.map(\.id))
    XCTAssertEqual(firstCopyIDs.count,original.elements.count)
    f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,end,option:true));f.canvas.mouseUp(with:try f.mouse(.leftMouseUp,end,option:true))
    XCTAssertEqual(Set(f.session.art.elements.map(\.id)).subtracting(original.elements.map(\.id)),firstCopyIDs,"A second drag event must move the same copy.")
    try assertCopies(f,original:original,dx:12,dy:9)
    for old in canonical.elements {XCTAssertEqual(f.session.sourceArtwork.elements.first{$0.id==old.id},old)}
    XCTAssertEqual(f.session.activeFrameID,frameID);XCTAssertNil(f.store.error);XCTAssertEqual(f.store.engine.undoStack.count,1)
    let after=try XCTUnwrap(f.store.project)
    if let paperID=f.paperID,let tableID=f.tableID {
      XCTAssertEqual(after.objects.first{$0.id==paperID},before.objects.first{$0.id==paperID})
      XCTAssertEqual(f.store.engine.selection,[tableID]);XCTAssertEqual(f.store.scene?.camera,camera);XCTAssertFalse(f.store.tableInspectorVisible)
      XCTAssertTrue(f.session.activeProjection?.inside==true)
    }
    f.store.engine.undo();f.session.reconcile();XCTAssertEqual(f.store.project,before)
    f.store.engine.redo();f.session.reconcile();XCTAssertEqual(f.store.project,after)
  }

  func testOptionHeldBeforeMouseDownCopiesSelectedRootsAndDeepGroupExactlyOnce()throws {try exercise(.beforeDown)}
  func testOptionPressedAfterMouseDownBeforeDragCopiesWithoutMovingOriginals()throws {try exercise(.afterDown)}
  func testOptionPressedAfterMouseDownUsesReflectedQuarterTurnInsideCoordinates()throws {try exercise(.afterDown,insidePaper:true)}

  func testOptionBeforeDownOnUnselectedArtworkPicksAndCopiesOnlyItsPaintedRoot()throws {
    let f=try Fixture();defer{f.close()}
    f.session.choose([])
    let before=try XCTUnwrap(f.store.project),original=f.session.art,group=try XCTUnwrap(original.elements.first{$0.kind=="group" && $0.parentID==nil})
    let start=try f.begin(.beforeDown)
    XCTAssertEqual(f.session.selection,[group.id]);XCTAssertEqual(f.store.project,before)
    let end=f.endPoint(start,dx:12,dy:9)
    f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,end,option:true));f.canvas.mouseUp(with:try f.mouse(.leftMouseUp,end,option:true))
    try assertCopies(f,original:original,dx:12,dy:9,roots:[group.id])
    XCTAssertEqual(f.session.art.elements.filter{$0.name=="Second root"}.count,1)
    XCTAssertEqual(f.store.engine.undoStack.count,1);let after=try XCTUnwrap(f.store.project)
    f.store.engine.undo();XCTAssertEqual(f.store.project,before);f.store.engine.redo();XCTAssertEqual(f.store.project,after)
  }

  func testOptionDuplicateDropIntoAnotherFrameLeavesOriginalsAndTransfersOnlyCopiesInOneUndo()throws {
    let f=try Fixture(destination:true);defer{f.close()}
    f.canvas.setZoom(0.5)
    let before=try XCTUnwrap(f.store.project),original=f.session.art,destination=try XCTUnwrap(f.destinationID)
    _ = try f.begin(.beforeDown)
    let end=try f.destinationPoint()
    f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,end,option:true))
    let copies=Set(f.session.art.elements.map(\.id)).subtracting(original.elements.map(\.id))
    XCTAssertEqual(copies.count,original.elements.count)
    f.canvas.mouseUp(with:try f.mouse(.leftMouseUp,end,option:true))
    XCTAssertNil(f.store.error)
    let after=try XCTUnwrap(f.store.project),source=try XCTUnwrap(after.objects.first{$0.id==f.sourceID}),target=try XCTUnwrap(after.objects.first{$0.id==destination}?.artwork)
    XCTAssertEqual(source,before.objects.first{$0.id==f.sourceID});XCTAssertEqual(Set(target.elements.map(\.id)),copies)
    XCTAssertEqual(f.session.objectID,destination);XCTAssertEqual(f.session.selection.count,2);XCTAssertTrue(f.session.selection.isSubset(of:copies))
    let leaf=try XCTUnwrap(target.elements.first{$0.name=="Grouped ink"}),center=f.center(leaf,in:target)
    XCTAssertEqual(center.x,20,accuracy:1e-7);XCTAssertEqual(center.y,30,accuracy:1e-7)
    XCTAssertEqual(f.store.engine.undoStack.count,1)
    f.store.engine.undo();f.session.reconcile();XCTAssertEqual(f.store.project,before)
    f.store.engine.redo();f.session.reconcile();XCTAssertEqual(f.store.project,after)
  }

  func testRejectedDuplicateDropIntoLockedFrameRollsBackCopiesMovementSelectionAndRedoExactly()throws {
    let f=try Fixture(destination:true,destinationLocked:true);defer{f.close()}
    f.session.translate(dx:5,dy:0);f.store.engine.undo();f.canvas.synchronize();f.canvas.setZoom(0.5)
    let before=try XCTUnwrap(f.store.project),redo=f.store.engine.redoStack
    _ = try f.begin(.beforeDown)
    let end=try f.destinationPoint()
    f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,end,option:true))
    XCTAssertGreaterThan(f.session.art.elements.count,before.objects[0].artwork?.elements.count ?? 0)
    f.canvas.mouseUp(with:try f.mouse(.leftMouseUp,end,option:true))
    XCTAssertNotNil(f.store.error);XCTAssertEqual(f.store.project,before)
    XCTAssertEqual(f.session.objectID,f.sourceID);XCTAssertEqual(f.session.selection,f.rootIDs)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty);XCTAssertEqual(f.store.engine.redoStack,redo)
    f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,end,option:true));f.canvas.mouseUp(with:try f.mouse(.leftMouseUp,end,option:true))
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.redoStack,redo)
  }

  func testIndependentOwnerLockInvalidatesHeldCopyGestureWithoutOverwritingTheNewLockOrHistory()throws {
    let f=try Fixture();defer{f.close()}
    let start=try f.begin(.beforeDown)
    try f.store.engine.edit("Locked owner while pointer held") {project in
      let index=try XCTUnwrap(project.objects.firstIndex{$0.id==f.sourceID});project.objects[index].locked=true
    }
    let locked=try XCTUnwrap(f.store.project),undo=f.store.engine.undoStack,redo=f.store.engine.redoStack
    let end=f.endPoint(start,dx:12,dy:9)
    f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,end,option:true));f.canvas.mouseUp(with:try f.mouse(.leftMouseUp,end,option:true))
    XCTAssertEqual(f.store.project,locked);XCTAssertEqual(f.store.engine.undoStack,undo);XCTAssertEqual(f.store.engine.redoStack,redo)
    XCTAssertEqual(f.session.selection,f.rootIDs);XCTAssertTrue(f.session.selection.isSubset(of:Set(f.session.art.elements.map(\.id))))
  }

  func testOptionDuringMaskEditingMovesTheExistingMaskWithoutCreatingOrdinaryInk()throws {
    let f=try Fixture();defer{f.close()}
    let original=f.session.art,mask=try XCTUnwrap(original.elements.first{$0.name=="Clip mask"})
    f.session.editMask(mask.id);f.canvas.synchronize()
    let before=try XCTUnwrap(f.store.project),start=try f.begin(.beforeDown),end=f.endPoint(start,dx:12,dy:9)
    f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,end,option:true));f.canvas.mouseUp(with:try f.mouse(.leftMouseUp,end,option:true))
    let artwork=f.session.art,moved=try XCTUnwrap(artwork.elements.first{$0.id==mask.id})
    XCTAssertEqual(Set(artwork.elements.map(\.id)),Set(original.elements.map(\.id)))
    for element in original.elements where element.id != mask.id {XCTAssertEqual(artwork.elements.first{$0.id==element.id},element)}
    let oldCenter=f.center(mask,in:original),newCenter=f.center(moved,in:artwork)
    XCTAssertEqual(newCenter.x,oldCenter.x+12,accuracy:1e-7);XCTAssertEqual(newCenter.y,oldCenter.y+9,accuracy:1e-7)
    XCTAssertEqual(f.session.maskEditing?.maskID,mask.id);XCTAssertEqual(f.session.maskEditing?.targets,[f.paintID]);XCTAssertEqual(f.session.selection,[mask.id])
    XCTAssertEqual(artwork.elements.first{$0.id==f.paintID}?.clipID,mask.id)
    XCTAssertEqual(f.store.engine.undoStack.count,1);let after=try XCTUnwrap(f.store.project)
    f.store.engine.undo();XCTAssertEqual(f.store.project,before);f.store.engine.redo();XCTAssertEqual(f.store.project,after)
  }

  func testLateOptionRestoresMovedOriginalsAndReleaseRepressKeepsTheSameCopy()throws {
    let f=try Fixture();defer{f.close()}
    let before=try XCTUnwrap(f.store.project),original=f.session.art,start=try f.start()
    f.canvas.mouseDown(with:try f.mouse(.leftMouseDown,start,option:false))
    f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,f.endPoint(start,dx:5,dy:4),option:false))
    XCTAssertEqual(f.session.art.elements.count,original.elements.count)
    let moved=try XCTUnwrap(f.session.art.elements.first{$0.id==f.paintID}),old=try XCTUnwrap(original.elements.first{$0.id==f.paintID})
    XCTAssertEqual(f.center(moved,in:f.session.art).x,f.center(old,in:original).x+5,accuracy:1e-7)
    try f.optionChanged(true)
    f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,f.endPoint(start,dx:12,dy:9),option:true))
    let copyIDs=Set(f.session.art.elements.map(\.id)).subtracting(original.elements.map(\.id))
    try f.optionChanged(false)
    f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,f.endPoint(start,dx:15,dy:11),option:false))
    try f.optionChanged(true)
    let end=f.endPoint(start,dx:18,dy:13)
    f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,end,option:true));f.canvas.mouseUp(with:try f.mouse(.leftMouseUp,end,option:true))
    XCTAssertEqual(Set(f.session.art.elements.map(\.id)).subtracting(original.elements.map(\.id)),copyIDs)
    try assertCopies(f,original:original,dx:18,dy:13)
    XCTAssertEqual(f.store.engine.undoStack.count,1);let after=try XCTUnwrap(f.store.project)
    f.store.engine.undo();XCTAssertEqual(f.store.project,before)
    f.store.engine.redo();XCTAssertEqual(f.store.project,after)
  }

  func testOptionClickAndSubthresholdJitterNeverDuplicateOrConsumeRedo()throws {
    let f=try Fixture();defer{f.close()}
    f.session.translate(dx:5,dy:0);f.store.engine.undo();f.canvas.synchronize()
    let before=try XCTUnwrap(f.store.project),redo=f.store.engine.redoStack
    for zoom in [0.25,1.0,4.0] {
      f.canvas.setZoom(zoom)
      for sequence in [ModifierSequence.beforeDown,.afterDown] {
        f.session.choose(f.rootIDs)
        let start=try f.begin(sequence),end=CGPoint(x:start.x+2,y:start.y+0.5)
        f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,end,option:true));f.canvas.mouseUp(with:try f.mouse(.leftMouseUp,end,option:true))
        XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty);XCTAssertEqual(f.store.engine.redoStack,redo)
        try f.optionChanged(false)
      }
    }
  }

  func testEscapeCancelsCopiesAndMovementExactlyAndLateEventsCannotRecreateThem()throws {
    let f=try Fixture();defer{f.close()}
    f.session.translate(dx:5,dy:0);f.store.engine.undo();f.canvas.synchronize()
    let before=try XCTUnwrap(f.store.project),redo=f.store.engine.redoStack
    for sequence in [ModifierSequence.beforeDown,.afterDown] {
      f.session.choose(f.rootIDs)
      let start=try f.begin(sequence),end=f.endPoint(start,dx:12,dy:9)
      f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,end,option:true))
      XCTAssertEqual(f.session.art.elements.count,2*(before.objects.first{$0.id==f.sourceID}?.artwork?.elements.count ?? 0))
      f.canvas.keyDown(with:try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:f.window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)))
      f.canvas.mouseDragged(with:try f.mouse(.leftMouseDragged,f.endPoint(start,dx:20,dy:15),option:true));f.canvas.mouseUp(with:try f.mouse(.leftMouseUp,end,option:true))
      XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.session.selection,f.rootIDs)
      XCTAssertTrue(f.store.engine.undoStack.isEmpty);XCTAssertEqual(f.store.engine.redoStack,redo)
      try f.optionChanged(false)
    }
  }
}

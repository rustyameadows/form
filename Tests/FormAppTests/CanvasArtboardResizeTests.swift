import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasArtboardResizeTests:XCTestCase {
  @MainActor private final class Fixture {
    let root:URL,store:StudioStore,session:ArtworkSession,window:NSWindow,scroll:ArtworkScrollView,canvas:VectorCanvasView
    let boardID:UUID,imageID:UUID,workspaceID:UUID
    init()throws {
      _ = NSApplication.shared
      root=FileManager.default.temporaryDirectory.appendingPathComponent("canvas-frame-resize-"+UUID().uuidString)
      store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
      var project=Project(name:"Native artboard resize")
      workspaceID=try project.ensureCanvasWorkspace().id
      var board=try project.makeObject(recipeID:"artboard",parameters:["width":120,"depth":80])
      boardID=board.id
      var image=ArtworkElement(kind:"image",x:0,y:0,width:120,height:80,asset:"placed.png")
      image.imageCrop = .init(x:0.1,y:0.15,width:0.7,height:0.6);imageID=image.id
      board.artwork = .init(background:"#FFFFFF",elements:[image],bleed:0)
      board.artwork?.canvasPosition = .init(100,90);board.artwork?.snapEnabled=false
      project.objects.append(board);project.schemaVersion=project.minimumSchemaVersion
      store.engine.project=project;store.mode = .artwork;store.showingHome=false
      session=store.artworkSession;session.activate(boardID)
      window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false
      scroll=ArtworkScrollView(frame:window.contentView!.bounds)
      scroll.allowsMagnification=true;scroll.minMagnification=0.08;scroll.maxMagnification=24
      canvas=VectorCanvasView(frame:scroll.bounds);canvas.session=session;session.canvas=canvas
      scroll.documentView=canvas;window.contentView=scroll;window.orderBack(nil);window.makeKey();window.makeFirstResponder(canvas)
      canvas.synchronize();canvas.fit(all:false);canvas.setZoom(1)
    }
    func close() {canvas.prepareForGroupNavigation();window.contentView=nil;window.close();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    var board:ProductObject {store.project!.objects.first{$0.id==boardID}!}
    func location(_ point:CGPoint)->CGPoint {canvas.convert(canvas.documentPoint(point),to:nil)}
    func event(_ type:NSEvent.EventType,_ world:CGPoint,flags:NSEvent.ModifierFlags=[])->NSEvent {
      NSEvent.mouseEvent(with:type,location:location(world),modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,
        windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1)!
    }
    func drag(_ start:CGPoint,_ end:CGPoint,flags:NSEvent.ModifierFlags=[]) {
      canvas.mouseDown(with:event(.leftMouseDown,start,flags:flags))
      canvas.mouseDragged(with:event(.leftMouseDragged,end,flags:flags))
      canvas.mouseUp(with:event(.leftMouseUp,end,flags:flags))
    }
    func escape() {
      canvas.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,
        windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:53)!)
    }
  }

  func testHeaderSelectsFrameBeforeFullBleedCornerResizeAtDifferentZoomsWithOneUndo()throws {
    let f=try Fixture();defer{f.close()}
    let original=try XCTUnwrap(f.store.project),source=f.board.artwork!.elements
    for zoom in [0.25,1.0,2.0] {
      f.canvas.setZoom(zoom);f.session.choose([f.imageID])
      let header=CGPoint(x:145,y:90-8*25.4/(72*zoom))
      f.drag(header,header)
      XCTAssertTrue(f.session.selection.isEmpty,"A header click selects the artboard rather than its image.")
      XCTAssertTrue(f.store.engine.undoStack.isEmpty)
      let start=CGPoint(x:220,y:170),end=CGPoint(x:240,y:180)
      f.canvas.mouseDown(with:f.event(.leftMouseDown,start))
      XCTAssertEqual(f.canvas.diagnostics["pointer_gesture"] as? String,"frame_resize")
      XCTAssertTrue(f.session.selection.isEmpty)
      f.canvas.mouseDragged(with:f.event(.leftMouseDragged,.init(x:230,y:175)))
      f.canvas.mouseDragged(with:f.event(.leftMouseDragged,end))
      f.canvas.mouseUp(with:f.event(.leftMouseUp,end))
      XCTAssertEqual(f.board["width"],140,accuracy:1e-8);XCTAssertEqual(f.board["depth"],90,accuracy:1e-8)
      XCTAssertEqual(f.board.artwork?.elements,source,"Frame resize must never scale or recrop the full-bleed image.")
      XCTAssertEqual(f.store.engine.undoStack.count,1)
      f.store.engine.undo();f.canvas.synchronize();XCTAssertEqual(f.store.project,original)
    }
  }

  func testSelectedFullBleedImageKeepsItsCornerResizeControl()throws {
    let f=try Fixture();defer{f.close()}
    f.session.choose([f.imageID])
    let original=f.store.project,crop=f.session.primary?.imageCrop
    let start=CGPoint(x:220,y:170),end=CGPoint(x:240,y:180)
    f.canvas.mouseDown(with:f.event(.leftMouseDown,start))
    XCTAssertEqual(f.canvas.diagnostics["pointer_gesture"] as? String,"resize")
    f.canvas.mouseDragged(with:f.event(.leftMouseDragged,end));f.canvas.mouseUp(with:f.event(.leftMouseUp,end))
    XCTAssertEqual(f.board["width"],120);XCTAssertEqual(f.board["depth"],80)
    let image=try XCTUnwrap(f.session.primary),bounds=f.session.art.bounds(of:image)
    XCTAssertEqual(bounds.width,140,accuracy:1e-8);XCTAssertEqual(bounds.height,90,accuracy:1e-8)
    XCTAssertEqual(image.imageCrop,crop);XCTAssertEqual(f.session.selection,[f.imageID])
    f.store.engine.undo();XCTAssertEqual(f.store.project,original)
  }

  func testActiveCropOwnsFullBleedBorderAndChangesOnlyCrop()throws {
    let f=try Fixture();defer{f.close()}
    f.session.choose([f.imageID]);f.session.croppingImageID=f.imageID
    let original=f.store.project,source=try XCTUnwrap(f.session.primary)
    let start=CGPoint(x:219,y:130),end=CGPoint(x:209,y:130)
    f.canvas.mouseDown(with:f.event(.leftMouseDown,start))
    XCTAssertEqual(f.canvas.diagnostics["pointer_gesture"] as? String,"image_crop")
    f.canvas.mouseDragged(with:f.event(.leftMouseDragged,end));f.canvas.mouseUp(with:f.event(.leftMouseUp,end))
    XCTAssertEqual(f.board["width"],120);XCTAssertEqual(f.board["depth"],80)
    XCTAssertEqual(f.session.croppingImageID,f.imageID)
    var image=try XCTUnwrap(f.session.primary)
    XCTAssertNotEqual(image.imageCrop,source.imageCrop);image.imageCrop=source.imageCrop
    XCTAssertEqual(image,source)
    f.store.engine.undo();XCTAssertEqual(f.store.project,original)
  }

  func testDirectNodeAtFrameCornerKeepsItsEditingControl()throws {
    let f=try Fixture();defer{f.close()}
    let first=BezierNode(.init(0,0))
    var path=ArtworkElement(kind:"path",x:0,y:0,width:120,height:80)
    path.path = .init(width:120,height:80,contours:[.init([first,.init(.init(120,80))],closed:false)])
    path.fillEnabled=false;path.stroke = .init(width:0.5)
    var project=try XCTUnwrap(f.store.project)
    let index=try XCTUnwrap(project.objects.firstIndex{$0.id==f.boardID})
    project.objects[index].artwork?.elements=[path];f.store.engine.project=project;f.canvas.synchronize()
    f.session.tool = .direct;f.session.choose([path.id]);f.session.nodes=[first.id]
    let start=CGPoint(x:100,y:90),end=CGPoint(x:110,y:100)
    f.canvas.mouseDown(with:f.event(.leftMouseDown,start))
    XCTAssertEqual(f.canvas.diagnostics["pointer_gesture"] as? String,"node")
    f.canvas.mouseDragged(with:f.event(.leftMouseDragged,end));f.canvas.mouseUp(with:f.event(.leftMouseUp,end))
    XCTAssertEqual(f.board["width"],120);XCTAssertEqual(f.board["depth"],80)
    let edited=try XCTUnwrap(f.session.primary),geometry=try XCTUnwrap(edited.path)
    let node=try XCTUnwrap(geometry.contours.flatMap(\.nodes).first{$0.id==first.id})
    let map=f.session.art.worldTransform(edited).followed(by:.scale(edited.width/geometry.width,edited.height/geometry.height))
    XCTAssertEqual(map.apply(node.anchor).x,10,accuracy:1e-8)
    XCTAssertEqual(map.apply(node.anchor).y,10,accuracy:1e-8)
    f.store.engine.undo();XCTAssertEqual(f.store.project,project)
  }

  func testActiveMaskOwnsFrameCornerAndAnotherFrameRemainsReachable()throws {
    let f=try Fixture();defer{f.close()}
    var project=try XCTUnwrap(f.store.project)
    let boardIndex=try XCTUnwrap(project.objects.firstIndex{$0.id==f.boardID})
    var mask=ArtworkElement(kind:"rectangle",x:0,y:0,width:120,height:80,color:"#FFFFFF");mask.hidden=true
    project.objects[boardIndex].artwork?.elements[0].clipID=mask.id
    project.objects[boardIndex].artwork?.elements[0].clipMode="alpha"
    project.objects[boardIndex].artwork?.elements.append(mask)
    var other=try project.makeObject(recipeID:"artboard",parameters:["width":80,"depth":60])
    other.artwork = .init(bleed:0);other.artwork?.canvasPosition = .init(320,90)
    let otherID=other.id;project.objects.append(other);project.schemaVersion=project.minimumSchemaVersion
    f.store.engine.project=project;f.canvas.synchronize();f.session.editMask(mask.id)
    let original=f.store.project,start=CGPoint(x:220,y:170),end=CGPoint(x:235,y:180)
    f.canvas.mouseDown(with:f.event(.leftMouseDown,start))
    XCTAssertEqual(f.canvas.diagnostics["pointer_gesture"] as? String,"resize")
    f.canvas.mouseDragged(with:f.event(.leftMouseDragged,end));f.canvas.mouseUp(with:f.event(.leftMouseUp,end))
    XCTAssertEqual(f.board["width"],120);XCTAssertEqual(f.board["depth"],80)
    XCTAssertEqual(f.session.maskEditing?.maskID,mask.id)
    let changed=try XCTUnwrap(f.session.art.elements.first{$0.id==mask.id})
    XCTAssertEqual(f.session.art.bounds(of:changed).width,135,accuracy:1e-8)
    f.store.engine.undo();f.canvas.synchronize();XCTAssertEqual(f.store.project,original)
    f.session.editMask(mask.id)
    f.drag(.init(x:400,y:150),.init(x:420,y:160))
    XCTAssertEqual(f.session.activeFrameID,otherID);XCTAssertNil(f.session.maskEditing)
    XCTAssertEqual(f.board.artwork,project.objects[boardIndex].artwork)
    let resized=try XCTUnwrap(f.store.project?.objects.first{$0.id==otherID})
    XCTAssertEqual(resized["width"],100,accuracy:1e-8);XCTAssertEqual(resized["depth"],70,accuracy:1e-8)
  }

  func testTopLeftResizeKeepsArtworkWorldPositionAndPreservesLayerAppearance()throws {
    let f=try Fixture();defer{f.close()}
    let original=try XCTUnwrap(f.store.project),source=f.board.artwork!.elements[0]
    f.drag(.init(x:100,y:90),.init(x:80,y:75))
    XCTAssertEqual(f.board["width"],140,accuracy:1e-8);XCTAssertEqual(f.board["depth"],95,accuracy:1e-8)
    XCTAssertEqual(f.board.artwork!.canvasPosition!.x,80,accuracy:1e-8)
    XCTAssertEqual(f.board.artwork!.canvasPosition!.y,75,accuracy:1e-8)
    let image=try XCTUnwrap(f.board.artwork?.elements.first)
    XCTAssertEqual(image.x,20,accuracy:1e-8);XCTAssertEqual(image.y,15,accuracy:1e-8)
    var appearance=image;appearance.x=source.x;appearance.y=source.y
    XCTAssertEqual(appearance,source)
    XCTAssertEqual(image.x+f.board.artwork!.canvasPosition!.x,100,accuracy:1e-8)
    XCTAssertEqual(image.y+f.board.artwork!.canvasPosition!.y,90,accuracy:1e-8)
    f.store.engine.undo();XCTAssertEqual(f.store.project,original)
  }

  func testWholeEdgeHasHoverCursorAndResizesOnlyItsAxis()throws {
    let f=try Fixture();defer{f.close()}
    let point=CGPoint(x:220,y:111),source=f.board.artwork!.elements
    f.canvas.mouseMoved(with:f.event(.mouseMoved,point))
    XCTAssertEqual(f.canvas.pointerFeedback,.resize(3))
    f.drag(point,.init(x:245,y:128))
    XCTAssertEqual(f.board["width"],145,accuracy:1e-8);XCTAssertEqual(f.board["depth"],80,accuracy:1e-8)
    XCTAssertEqual(f.board.artwork?.elements,source)
  }

  func testResizeClickJitterPreservesRedoAndEscapeRollsBackThenIgnoresLateEvents()throws {
    let f=try Fixture();defer{f.close()}
    try f.store.engine.edit("Prior edit"){$0.subtitle="Redo branch"};f.store.engine.undo()
    let original=try XCTUnwrap(f.store.project),redo=f.store.engine.redoStack
    let start=CGPoint(x:220,y:170),jitter=CGPoint(x:220.3,y:170.3),end=CGPoint(x:250,y:190)
    f.drag(start,jitter)
    XCTAssertEqual(f.store.project,original);XCTAssertEqual(f.store.engine.redoStack,redo)
    f.canvas.mouseDown(with:f.event(.leftMouseDown,start));f.canvas.mouseDragged(with:f.event(.leftMouseDragged,end))
    XCTAssertNotEqual(f.store.project,original);f.escape()
    f.canvas.mouseDragged(with:f.event(.leftMouseDragged,.init(x:280,y:200)))
    f.canvas.mouseUp(with:f.event(.leftMouseUp,end))
    XCTAssertEqual(f.store.project,original);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertEqual(f.store.engine.redoStack,redo)
  }

  func testSourceSwitchAndIndependentCommandsInvalidateHeldResize()throws {
    let f=try Fixture();defer{f.close()}
    let start=CGPoint(x:220,y:170),end=CGPoint(x:250,y:190)
    f.canvas.mouseDown(with:f.event(.leftMouseDown,start));f.canvas.mouseDragged(with:f.event(.leftMouseDragged,end))
    try f.store.engine.edit("Independent change"){$0.subtitle="Keep this change"}
    let current=try XCTUnwrap(f.store.project),undo=f.store.engine.undoStack
    f.canvas.mouseDragged(with:f.event(.leftMouseDragged,.init(x:280,y:210)));f.canvas.mouseUp(with:f.event(.leftMouseUp,end))
    XCTAssertEqual(f.store.project,current);XCTAssertEqual(f.store.engine.undoStack,undo)
    f.canvas.mouseDown(with:f.event(.leftMouseDown,end));f.session.activate(f.workspaceID)
    f.canvas.mouseDragged(with:f.event(.leftMouseDragged,.init(x:290,y:220)));f.canvas.mouseUp(with:f.event(.leftMouseUp,end))
    XCTAssertEqual(f.store.project,current);XCTAssertEqual(f.session.activeFrameID,f.workspaceID)
  }

  func testHeaderMovesWholeBoardAndLockedFrameCannotResize()throws {
    let f=try Fixture();defer{f.close()}
    let original=try XCTUnwrap(f.store.project),source=f.board.artwork!.elements
    f.drag(.init(x:160,y:90-8*25.4/72),.init(x:185,y:110-8*25.4/72))
    XCTAssertEqual(f.board.artwork!.canvasPosition!.x,125,accuracy:1e-8)
    XCTAssertEqual(f.board.artwork!.canvasPosition!.y,110,accuracy:1e-8)
    XCTAssertEqual(f.board.artwork?.elements,source)
    f.store.engine.undo();XCTAssertEqual(f.store.project,original)
    var locked=original;let index=try XCTUnwrap(locked.objects.firstIndex{$0.id==f.boardID});locked.objects[index].locked=true
    f.store.engine.project=locked;f.canvas.synchronize()
    f.drag(.init(x:220,y:170),.init(x:260,y:200))
    XCTAssertEqual(f.store.project,locked);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testFrontFrameHeaderOccludesTheResizeEdgeBehindIt()throws {
    let f=try Fixture();defer{f.close()}
    var project=try XCTUnwrap(f.store.project)
    var front=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":60])
    front.artwork = .init(bleed:0);front.artwork?.canvasPosition = .init(180,120)
    let frontID=front.id;project.objects.append(front);f.store.engine.project=project;f.canvas.synchronize()
    let titleY=120-8*25.4/72
    f.drag(.init(x:220,y:titleY),.init(x:240,y:titleY+10))
    XCTAssertEqual(f.board["width"],120);XCTAssertEqual(f.board["depth"],80)
    let moved=try XCTUnwrap(f.store.project?.objects.first{$0.id==frontID})
    XCTAssertEqual(moved.artwork!.canvasPosition!.x,200,accuracy:1e-8)
    XCTAssertEqual(moved.artwork!.canvasPosition!.y,130,accuracy:1e-8)
    XCTAssertEqual(f.session.activeFrameID,frontID)
    XCTAssertEqual(f.store.engine.undoStack.count,1)
  }

  func testAllEightResizeDirectionsKeepOppositeAnchorAndModifiersAreBounded() {
    let rect=CGRect(x:100,y:90,width:120,height:80),points=CanvasArtboardResizing.points(rect)
    for handle in 0..<8 {
      XCTAssertEqual(CanvasArtboardResizing.handle(at:points[handle],rect:rect,scale:0.5),handle)
      let resized=CanvasArtboardResizing.resized(rect,handle:handle,delta:.init(x:20,y:10),aspectLocked:false,fromCenter:false)
      let opposite=(handle+4)%8
      XCTAssertEqual(CanvasArtboardResizing.points(resized)[opposite],points[opposite])
    }
    let locked=CanvasArtboardResizing.resized(rect,handle:4,delta:.init(x:20,y:35),aspectLocked:true,fromCenter:false)
    XCTAssertEqual(locked.width/locked.height,1.5,accuracy:1e-10)
    let centered=CanvasArtboardResizing.resized(rect,handle:4,delta:.init(x:20,y:10),aspectLocked:false,fromCenter:true)
    XCTAssertEqual(centered.midX,rect.midX);XCTAssertEqual(centered.midY,rect.midY)
    XCTAssertEqual(centered.width,160);XCTAssertEqual(centered.height,100)
    let minimum=CanvasArtboardResizing.resized(rect,handle:4,delta:.init(x:-1000,y:-1000),aspectLocked:false,fromCenter:false)
    XCTAssertEqual(minimum.width,0.01,accuracy:1e-10);XCTAssertEqual(minimum.height,0.01,accuracy:1e-10)
    let maximum=CanvasArtboardResizing.resized(rect,handle:4,delta:.init(x:1e9,y:1e9),aspectLocked:false,fromCenter:false)
    XCTAssertEqual(maximum.width,10_000);XCTAssertEqual(maximum.height,10_000)
  }
}

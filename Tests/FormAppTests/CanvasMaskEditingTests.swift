import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class CanvasMaskEditingTests:XCTestCase {
  @MainActor private final class Fixture {
    let directory:URL,store:StudioStore,window:NSWindow,canvas:VectorCanvasView,ownerID:UUID
    let maskID:UUID,groups:[UUID],leafID:UUID,contentID:UUID
    let board=NSPasteboard.withUniqueName()
    let point=CGPoint(x:62,y:62)
    var session:ArtworkSession{store.artworkSession}
    init()throws {
      _=NSApplication.shared
      directory=FileManager.default.temporaryDirectory.appendingPathComponent("mask-edit-"+UUID().uuidString)
      store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
      var project=Project(name:"Deep editable mask"),elements:[ArtworkElement]=[]
      let owner=try project.ensureCanvasWorkspace();ownerID=owner.id
      var mask=ArtworkElement(kind:"group",x:20,y:20,width:180,height:130);mask.hidden=true;mask.contentSize = .init(180,130)
      maskID=mask.id;elements.append(mask)
      var ids:[UUID]=[],parent=mask.id
      for _ in 0..<3 {
        var group=ArtworkElement(kind:"group",x:10,y:10,width:120,height:90)
        group.contentSize = .init(120,90);group.parentID=parent;elements.append(group);ids.append(group.id);parent=group.id
      }
      groups=ids
      var leaf=ArtworkElement(kind:"rectangle",x:5,y:5,width:24,height:24,color:"#FFFFFF");leaf.parentID=parent;leafID=leaf.id;elements.append(leaf)
      // Dense mask geometry exercises the same picker and ancestry paths as a
      // real layered mask, with no project-specific app or fixture branches.
      for index in 0..<180 {
        var cell=ArtworkElement(kind:"ellipse",x:80+Double(index%18)*4,y:Double(index/18)*4,width:2,height:2,color:"#FFFFFF")
        cell.parentID=parent;elements.append(cell)
      }
      var content=ArtworkElement(kind:"rectangle",x:0,y:0,width:240,height:180,color:"#E04020")
      content.clipID=mask.id;content.clipMode="alpha";contentID=content.id;elements.append(content)
      var artwork=Artwork(elements:elements,bleed:0);artwork.backgroundOpacity=0;artwork.snapEnabled=false
      try project.setArtwork(artwork,for:owner.id);project.schemaVersion=project.minimumSchemaVersion
      store.engine.project=project;store.mode = .artwork;store.showingHome=false
      window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1000,height:750),styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false
      let scroll=ArtworkScrollView(frame:window.contentView!.bounds)
      canvas=VectorCanvasView(frame:scroll.bounds);canvas.session=store.artworkSession
      scroll.documentView=canvas;window.contentView=scroll;window.orderBack(nil)
      store.artworkSession.canvas=canvas;store.artworkSession.objectID=owner.id
      store.artworkSession.transferPasteboard=board
      canvas.synchronize();canvas.fit(all:true);canvas.setZoom(0.8);window.makeFirstResponder(canvas)
    }
    func close(){canvas.finishText();store.engine.project=nil;window.close();board.releaseGlobally();try? FileManager.default.removeItem(at:directory)}
    func event(_ type:NSEvent.EventType,_ p:CGPoint,count:Int=1)->NSEvent {
      NSEvent.mouseEvent(with:type,location:canvas.convert(canvas.documentPoint(p),to:nil),modifierFlags:[],
        timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,
        clickCount:count,pressure:type == .leftMouseUp ? 0:1)!
    }
    func click(_ p:CGPoint?=nil,count:Int=1){let p=p ?? point;canvas.mouseDown(with:event(.leftMouseDown,p,count:count));canvas.mouseUp(with:event(.leftMouseUp,p,count:count))}
    func escape(){canvas.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,
      windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:53)!)}
    func enter(){session.editMask(maskID);click(count:2);for _ in groups{click(count:2)}}
    func alpha()->Double {
      let image=ArtworkRenderer.image(session.art,width:240,height:180,assets:directory,pixelsPerMM:2)
      return (image.representations[0] as! NSBitmapImageRep).colorAt(x:124,y:124)!.alphaComponent
    }
  }
  func testNativeDoubleClicksDescendHiddenMaskAndEscapeLeavesOneLevelThenReturnsToContents()throws {
    let f=try Fixture();defer{f.close()}
    let before=f.store.project,viewport=f.canvas.visibleCanvasRect,zoom=f.canvas.zoom
    f.session.editMask(f.maskID)
    let menu=try XCTUnwrap(f.canvas.menu(for:f.event(.rightMouseDown,f.point)))
    let enter=try XCTUnwrap(menu.items.first{$0.title=="Enter Group"})
    XCTAssertTrue(enter.isEnabled);f.canvas.performCanvasMenuAction(enter)
    XCTAssertEqual(f.session.scopeID,f.maskID)
    for id in f.groups {f.click(count:2);XCTAssertEqual(f.session.scopeID,id);XCTAssertEqual(f.session.maskEditing?.maskID,f.maskID)}
    f.click();XCTAssertEqual(f.session.selection,[f.leafID]);XCTAssertEqual(f.session.maskEditing?.maskID,f.maskID)
    XCTAssertEqual(Set(f.session.selectionCandidates(in:f.session.art).map(\.id)).count,181)
    for id in Array(f.groups.dropLast().reversed())+[f.maskID] {f.escape();XCTAssertEqual(f.session.scopeID,id);XCTAssertNotNil(f.session.maskEditing)}
    f.escape();XCTAssertNil(f.session.maskEditing);XCTAssertNil(f.session.scopeID);XCTAssertEqual(f.session.selection,[f.contentID])
    XCTAssertEqual(f.session.tool,.select);XCTAssertTrue(f.store.project==before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertEqual(f.canvas.visibleCanvasRect,viewport);XCTAssertEqual(f.canvas.zoom,zoom)
  }
  func testMaskOpacityAndBlurAreEditableAffectRenderedCoverageAndUndoExactly()throws {
    let f=try Fixture();defer{f.close()};f.session.editMask(f.maskID)
    let before=f.store.project;XCTAssertGreaterThan(f.alpha(),0.95)
    f.session.appearance(["opacity":0.4,"effect_stack":["effects":[["kind":"blur","blur":0.3]]]])
    XCTAssertNil(f.store.error);XCTAssertEqual(f.alpha(),0.4,accuracy:0.03)
    let after=try XCTUnwrap(f.store.project)
    XCTAssertEqual(f.store.engine.undoStack.count,1)
    XCTAssertEqual(f.session.art.elements.first{$0.id==f.maskID}?.hidden,true)
    XCTAssertEqual(f.session.art.elements.first{$0.id==f.maskID}?.effectStack?.effects.first?.blur,0.3)
    f.store.engine.undo();XCTAssertTrue(f.store.project==before);XCTAssertGreaterThan(f.alpha(),0.95)
    f.store.engine.redo();XCTAssertEqual(f.store.project,after);XCTAssertEqual(f.alpha(),0.4,accuracy:0.03)
    try f.store.engine.flush();XCTAssertEqual(try f.store.repository.load(after.id).objects,after.objects)
  }
  func testZeroOpacityMaskChildRemainsSelectableAndCanBeRestored()throws {
    let f=try Fixture();defer{f.close()}
    let index=try XCTUnwrap(f.store.engine.project?.objects[0].artwork?.elements.firstIndex(where:{$0.id==f.leafID}))
    f.store.engine.project!.objects[0].artwork!.elements[index].opacity=0
    f.canvas.synchronize();f.enter();f.click()
    XCTAssertEqual(f.session.selection,[f.leafID]);XCTAssertEqual(f.session.maskEditing?.maskID,f.maskID)
    XCTAssertEqual(f.alpha(),0,accuracy:0.01)
    f.session.appearance(["opacity":0.6]);XCTAssertNil(f.store.error);XCTAssertEqual(f.alpha(),0.6,accuracy:0.03)
    f.canvas.mouseMoved(with:f.event(.mouseMoved,f.point))
    XCTAssertEqual(f.canvas.pointerFeedback,.move)
  }
  func testLeavingDuringMaskChildDragCancelsItAndIgnoresLateEvents()throws {
    let f=try Fixture();defer{f.close()};f.enter();f.click()
    let before=f.store.project,p=CGPoint(x:f.point.x+18,y:f.point.y+12)
    f.canvas.mouseDown(with:f.event(.leftMouseDown,f.point));f.canvas.mouseDragged(with:f.event(.leftMouseDragged,p))
    XCTAssertFalse(f.store.project==before)
    f.session.leaveGroup();XCTAssertTrue(f.store.project==before);XCTAssertEqual(f.session.scopeID,f.groups[1])
    f.canvas.mouseDragged(with:f.event(.leftMouseDragged,.init(x:p.x+20,y:p.y+10)))
    f.canvas.mouseUp(with:f.event(.leftMouseUp,p))
    XCTAssertTrue(f.store.project==before);XCTAssertTrue(f.store.engine.undoStack.isEmpty);XCTAssertEqual(f.session.maskEditing?.maskID,f.maskID)
  }
}

import AppKit
import FormGeometry
import XCTest
@testable import FormCore
@testable import FormApp

@MainActor final class ClothMoveTests:XCTestCase {
  @MainActor private final class Fixture {
    let root:URL,store:StudioStore,window:NSWindow,view:TableSceneView,scene:TableSceneController,surfaceID:UUID,labelID:UUID
    init(childFirst:Bool = false)throws {
      _ = NSApplication.shared;root=FileManager.default.temporaryDirectory.appendingPathComponent("cloth-move-\(UUID().uuidString)")
      let repository=try ProjectRepository(root:root);var p=Project(name:"Native cloth movement")
      var surface=try p.makeObject(recipeID:"clothPanel",parameters:["resolution":8],position:.init(170,0,-130));surface.rotation=23
      var label=try p.makeObject(recipeID:"textileLabel",parameters:["width":54,"depth":30,"height":2])
      label.clothAttachment = .init(surfaceObjectID:surface.id,anchor:try surface.cloth!.mesh.anchor(at:.init(0.72,0.65),normalOffsetMm:2),rotationDegrees:12)
      surfaceID=surface.id;labelID=label.id;p.objects=childFirst ? [label,surface]:[surface,label];try repository.save(p)
      store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(p.id);store.showingHome=false
      window=NSWindow(contentRect:.init(x:0,y:0,width:1200,height:800),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
      view=TableSceneView(frame:.init(x:0,y:0,width:1200,height:800));scene=TableSceneController(store:store);view.controller=scene;scene.view=view;store.scene=scene
      window.contentView=view;window.makeFirstResponder(view)
      store.synchronizeScene();scene.preset("overhead");store.setTableTool(.move)
    }
    func object(_ id:UUID)->ProductObject {store.project!.objects.first {$0.id==id}!}
    func select(_ ids:Set<UUID>) {store.engine.selection=ids;store.synchronizeScene();scene.focusSelection()}
    func drag()throws -> Vector3 {
      let node=try XCTUnwrap(scene.objectRoot.childNode(withName:"object:\(labelID.uuidString)",recursively:false)),world=node.convertPosition(.init(0,object(labelID)["height"]/100,0),to:nil),projected=view.projectPoint(world)
      let start=NSPoint(x:projected.x,y:projected.y),end=NSPoint(x:start.x+44,y:start.y-27)
      XCTAssertEqual(scene.objectID(at:start),labelID)
      let height=scene.worldPosition(store.primary!).y,from=try XCTUnwrap(scene.pointOnTable(start,height:height)),to=try XCTUnwrap(scene.pointOnTable(end,height:height))
      func event(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent {NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1)!}
      view.mouseDown(with:event(.leftMouseDown,start));view.mouseDragged(with:event(.leftMouseDragged,end));view.mouseUp(with:event(.leftMouseUp,end));store.synchronizeScene()
      XCTAssertFalse(window.isVisible);return .init(to.x-from.x,0,to.z-from.z)
    }
    func close() {view.cancelPointerInteraction();store.cloth.clear();window.contentView=nil;window.close();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
  }
  func testAttachedLabelDragProjectsOntoItsMaterialPanelAndUndoRestoresExactly()throws {
    let f=try Fixture();defer {f.close()};f.select([f.labelID])
    let before=f.store.project!,label=f.object(f.labelID),oldUV=try f.object(f.surfaceID).cloth!.mesh.materialPoint(label.clothAttachment!.anchor),builds=f.scene.geometryBuilds
    _ = try f.drag()
    let after=f.store.project!,moved=f.object(f.labelID),uv=try f.object(f.surfaceID).cloth!.mesh.materialPoint(moved.clothAttachment!.anchor)
    XCTAssertGreaterThan(abs(uv.x-oldUV.x)+abs(uv.y-oldUV.y),0.01);XCTAssertEqual(moved.position,label.position)
    XCTAssertEqual(moved.clothAttachment?.rotationDegrees,label.clothAttachment?.rotationDegrees);XCTAssertEqual(moved.clothAttachment?.anchor.normalOffsetMm,2)
    XCTAssertEqual(f.object(f.surfaceID),before.objects.first {$0.id==f.surfaceID});XCTAssertEqual(f.scene.geometryBuilds,builds)
    XCTAssertEqual(f.store.engine.undoStack.count,1);f.store.undo();f.store.synchronizeScene();XCTAssertEqual(f.store.project,before)
    f.store.redo();f.store.synchronizeScene();XCTAssertEqual(f.store.project,after)
  }
  func testParentAndLabelSelectionMovesOnceInBothSavedObjectOrders()throws {
    for childFirst in [false,true] {
      let f=try Fixture(childFirst:childFirst);defer {f.close()};f.select([f.surfaceID,f.labelID])
      let before=f.store.project!,surface=f.object(f.surfaceID),label=f.object(f.labelID),old=try XCTUnwrap(before.clothPlacement(label)),builds=f.scene.geometryBuilds
      let delta=try f.drag(),after=f.store.project!,next=try XCTUnwrap(after.clothPlacement(f.object(f.labelID)))
      let dx=(surface.position.x+delta.x).rounded()-surface.position.x,dz=(surface.position.z+delta.z).rounded()-surface.position.z
      XCTAssertEqual(next.positionMm.x-old.positionMm.x,dx,accuracy:1e-8);XCTAssertEqual(next.positionMm.z-old.positionMm.z,dz,accuracy:1e-8)
      XCTAssertEqual(f.object(f.labelID),label);XCTAssertEqual(f.scene.geometryBuilds,builds);XCTAssertEqual(f.store.engine.undoStack.count,1)
      f.store.undo();f.store.synchronizeScene();XCTAssertEqual(f.store.project,before)
    }
  }
}

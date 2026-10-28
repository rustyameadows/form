import AppKit
import FormGeometry
import XCTest
@testable import FormCore
@testable import FormGraphics
@testable import FormApp

@MainActor final class PatternAssemblyMoveTests:XCTestCase {
  @MainActor private final class Fixture {
    let root:URL,store:StudioStore,window:NSWindow,view:TableSceneView,scene:TableSceneController,surfaceID:UUID,labelID:UUID
    init(childFirst:Bool = false)throws {
      _ = NSApplication.shared;root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      var (p,d)=try PatternAssemblySamples.roundedPouch();d.maximumEdgeMm=42
      surfaceID=try p.addPatternAssembly(d)
      let main=d.panels.first{$0.panel.copy==1 && $0.pose.vAxis.y == -1}!.panel
      var label=try p.makeObject(recipeID:"textileLabel",parameters:["width":45,"depth":24,"height":2])
      label.patternAssemblyAttachment = .init(surfaceObjectID:surfaceID,anchor:.init(panel:main,materialPointMm:.init(130,80),normalOffsetMm:2))
      labelID=label.id
      p.objects[0].position.x=700
      if childFirst {p.objects.insert(label,at:0)}else {p.objects.append(label)}
      let repository=try ProjectRepository(root:root);try repository.save(p)
      store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(p.id);store.showingHome=false
      window=NSWindow(contentRect:.init(x:0,y:0,width:1200,height:800),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
      view=TableSceneView(frame:.init(x:0,y:0,width:1200,height:800));scene=TableSceneController(store:store);view.controller=scene;scene.view=view;store.scene=scene
      window.contentView=view;window.makeFirstResponder(view)
      store.synchronizeScene();scene.preset("front");store.setTableTool(.move)
      select([labelID])
    }
    func object(_ id:UUID)->ProductObject {store.project!.objects.first{$0.id==id}!}
    func select(_ ids:Set<UUID>) {store.engine.selection=ids;store.synchronizeScene();scene.focusSelection()}
    func placement()throws -> ClothSurfacePlacement {try XCTUnwrap(store.cloth.placement(of:object(labelID),in:store.project!))}
    func screen(_ p:Vector3)->NSPoint {let q=view.projectPoint(MeshVector3(p.x/100,p.y/100,p.z/100));return .init(x:q.x,y:q.y)}
    func event(_ type:NSEvent.EventType,_ p:NSPoint)->NSEvent {NSEvent.mouseEvent(with:type,location:view.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1)!}
    func drag(_ delta:NSPoint)throws {
      let start=screen(try placement().positionMm),end=NSPoint(x:start.x+delta.x,y:start.y+delta.y),before=store.project!
      XCTAssertEqual(scene.objectID(at:start),labelID)
      view.mouseDown(with:event(.leftMouseDown,start));XCTAssertEqual(store.project,before)
      view.mouseDragged(with:event(.leftMouseDragged,end));view.mouseUp(with:event(.leftMouseUp,end));store.synchronizeScene();XCTAssertFalse(window.isVisible)
    }
    func close() {view.cancelPointerInteraction();store.cloth.clear();window.contentView=nil;window.close();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
  }
  func testFrontViewHorizontalAndVerticalDragsPersistActualMaterialPointWithOneUndo()throws {
    for delta in [NSPoint(x:48,y:0),NSPoint(x:0,y:48)] {
      let f=try Fixture();defer {f.close()}
      let before=f.store.project!,label=f.object(f.labelID),old=label.patternAssemblyAttachment!.anchor.materialPointMm,camera=f.scene.camera,builds=f.scene.geometryBuilds
      try f.drag(delta)
      let after=f.store.project!,moved=f.object(f.labelID),point=moved.patternAssemblyAttachment!.anchor.materialPointMm
      if delta.x>0 {XCTAssertGreaterThan(point.x,old.x+1);XCTAssertEqual(point.y,old.y,accuracy:0.1)}
      else {XCTAssertLessThan(point.y,old.y-1);XCTAssertEqual(point.x,old.x,accuracy:0.1)}
      XCTAssertEqual(moved.position,label.position);XCTAssertEqual(moved.patternAssemblyAttachment?.anchor.panel,label.patternAssemblyAttachment?.anchor.panel)
      XCTAssertEqual(moved.patternAssemblyAttachment?.anchor.normalOffsetMm,2);XCTAssertEqual(f.scene.camera,camera);XCTAssertEqual(f.scene.geometryBuilds,builds)
      XCTAssertEqual(f.store.engine.undoStack.count,1);f.store.undo();f.store.synchronizeScene();XCTAssertEqual(f.store.project,before)
      f.store.redo();f.store.synchronizeScene();XCTAssertEqual(f.store.project,after)
    }
  }
  func testMissedPanelAndOccludingObjectCannotJumpAnAttachedLabelOrChangeCamera()throws {
    let f=try Fixture();defer {f.close()}
    let center=try f.placement().positionMm
    // Other geometry covers a valid destination, while the grab remains visible.
    let blocker=try f.store.project!.makeObject(recipeID:"box",parameters:["width":16,"depth":25,"height":50],position:.init(center.x+35,center.y-25,center.z+35))
    try f.store.engine.edit("Occluder") {$0.objects.append(blocker)};f.store.changed(save:false);f.store.synchronizeScene()
    let target=Vector3(center.x+35,center.y,center.z),start=f.screen(center),end=f.screen(target),before=f.store.project!,camera=f.scene.camera,undos=f.store.engine.undoStack.count
    XCTAssertTrue(f.view.bounds.contains(end));XCTAssertEqual(f.scene.objectID(at:end),blocker.id)
    XCTAssertNil(f.scene.attachmentTarget(target,for:f.object(f.labelID)))
    f.view.mouseDown(with:f.event(.leftMouseDown,start));f.view.mouseDragged(with:f.event(.leftMouseDragged,end));f.view.mouseUp(with:f.event(.leftMouseUp,end))
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.undoStack.count,undos);XCTAssertEqual(f.scene.camera,camera)
    try f.drag(.init(x:5000,y:5000));XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.scene.camera,camera)
    // The actual opaque analytic support is category4, like non-pickable scene
    // helpers. It must occlude material picking even though it is not an object.
    try f.store.engine.edit("Static opaque support") {p in
      p.objects.removeAll{$0.id==blocker.id}
      let index=p.objects.firstIndex{$0.id==f.surfaceID}!
      p.objects[index].patternAssembly!.colliders.append(.sphere(centerMm:.init(center.x+35,center.y,center.z+35),radiusMm:10))
    }
    f.store.changed(save:false);f.store.synchronizeScene()
    let supportBefore=f.store.project!,supportUndos=f.store.engine.undoStack.count
    let supports=f.scene.objectRoot.childNodes.flatMap(\.childNodes).filter{$0.name=="cloth.static-support"}
    XCTAssertEqual(supports.count,1)
    XCTAssertNil(f.scene.attachmentTarget(target,for:f.object(f.labelID)))
    f.view.mouseDown(with:f.event(.leftMouseDown,start));f.view.mouseDragged(with:f.event(.leftMouseDragged,end));f.view.mouseUp(with:f.event(.leftMouseUp,end))
    XCTAssertEqual(f.store.project,supportBefore);XCTAssertEqual(f.store.engine.undoStack.count,supportUndos);XCTAssertEqual(f.scene.camera,camera)
  }
  func testParentAndAttachedLabelMoveOnceInEitherSavedObjectOrder()throws {
    for childFirst in [false,true] {
      let f=try Fixture(childFirst:childFirst);defer {f.close()}
      f.scene.preset("perspective");f.select([f.surfaceID,f.labelID])
      let before=f.store.project!,oldParent=f.object(f.surfaceID),oldLabel=f.object(f.labelID),old=try f.placement(),camera=f.scene.camera
      try f.drag(.init(x:44,y:-27))
      let parent=f.object(f.surfaceID),next=try f.placement()
      XCTAssertEqual(f.object(f.labelID),oldLabel)
      XCTAssertEqual(next.positionMm.x-old.positionMm.x,parent.position.x-oldParent.position.x,accuracy:1e-7)
      XCTAssertEqual(next.positionMm.z-old.positionMm.z,parent.position.z-oldParent.position.z,accuracy:1e-7)
      XCTAssertEqual(next.positionMm.y,old.positionMm.y,accuracy:1e-7);XCTAssertEqual(f.scene.camera,camera)
      XCTAssertEqual(f.store.engine.undoStack.count,1);f.store.undo();f.store.synchronizeScene();XCTAssertEqual(f.store.project,before)
    }
  }
}

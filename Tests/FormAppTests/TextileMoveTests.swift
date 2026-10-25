import AppKit
import SceneKit
import XCTest
@testable import FormApp
@testable import FormCore

/// Exercises Move through AppKit handlers and actual SceneKit picking. Windows
/// stay hidden; no operating-system input or printer connection is involved.
@MainActor final class TextileMoveTests:XCTestCase {
  @MainActor private final class Fixture {
    let root:URL
    let store:StudioStore
    let window:NSWindow
    let view:TableSCNView
    let scene:TableSceneController
    let jacketID:UUID
    let patchID:UUID
    init(childFirst:Bool = false) throws {
      _ = NSApplication.shared
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let repository = try ProjectRepository(root:root)
      var project = Project(name:"Native textile move")
      var jacket = try project.makeObject(recipeID:"bomberJacket",materialID:"flight-nylon",position:.init(180,0,-240))
      jacket.rotation = 31
      var patch = try project.makeObject(recipeID:"textilePatch",materialID:"patch-twill")
      patch.parameters["width"] = 100; patch.parameters["depth"] = 80; patch.parameters["corner"] = 12
      patch.artwork = Artwork(background:"#20374F",elements:[])
      patch.textile?.attachment = .init(garmentID:jacket.id,zone:.leftChest,offset:.init(7,-11),rotation:14,clearance:2)
      jacketID = jacket.id; patchID = patch.id
      project.objects = childFirst ? [patch,jacket]:[jacket,patch]
      project.schemaVersion = project.minimumSchemaVersion
      try repository.save(project)
      store = StudioStore(repository:repository,seedLibrary:false)
      try store.engine.open(project.id)
      store.showingHome = false
      window = NSWindow(contentRect:.init(x:0,y:0,width:1200,height:800),styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed = false
      view = TableSCNView(frame:.init(x:0,y:0,width:1200,height:800))
      scene = TableSceneController(store:store)
      view.controller = scene; scene.view = view; store.scene = scene
      view.scene = scene.scene; view.pointOfView = scene.cameraNode
      view.allowsCameraControl = false; view.rendersContinuously = false
      window.contentView = view
      window.makeFirstResponder(view)
      store.synchronizeScene()
      scene.preset("overhead")
      store.setTableTool(.move)
    }
    func object(_ id:UUID) -> ProductObject {store.project!.objects.first {$0.id == id}!}
    func node(_ id:UUID) -> SCNNode {scene.objectRoot.childNode(withName:"object:\(id.uuidString)",recursively:false)!}
    func select(_ ids:Set<UUID>) {
      store.engine.selection = ids
      store.synchronizeScene()
      scene.focusSelection()
    }
    func pointOnPatch() -> NSPoint {
      let patch = object(patchID)
      let world = node(patchID).convertPosition(.init(0,patch["height"]/100,0),to:nil)
      let point = view.projectPoint(world)
      return .init(x:point.x,y:point.y)
    }
    func event(_ type:NSEvent.EventType,_ point:NSPoint,flags:NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:flags,timestamp:0,
        windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,
        pressure:type == .leftMouseUp ? 0:1)!
    }
    func dragPatch(dx:Double = 54,dy:Double = -33,flags:NSEvent.ModifierFlags = []) throws -> Vector3 {
      let start = pointOnPatch(),end = NSPoint(x:start.x+dx,y:start.y+dy)
      XCTAssertEqual(scene.objectID(at:start),patchID,"Fixture must exercise the attached patch's real pick hit")
      let height = store.project!.textilePlacement(store.primary!).position.y
      let origin = try XCTUnwrap(scene.pointOnTable(start,height:height))
      let destination = try XCTUnwrap(scene.pointOnTable(end,height:height))
      view.mouseDown(with:event(.leftMouseDown,start,flags:flags))
      view.mouseDragged(with:event(.leftMouseDragged,end,flags:flags))
      view.mouseUp(with:event(.leftMouseUp,end,flags:flags))
      store.synchronizeScene()
      XCTAssertFalse(window.isVisible)
      return .init(destination.x-origin.x,0,destination.z-origin.z)
    }
    func close() {
      view.cancelPointerInteraction()
      window.contentView = nil; window.close()
      store.engine.project = nil
      try? FileManager.default.removeItem(at:root)
    }
  }

  func testDraggingAnAttachedPatchChangesItsGarmentOffsetAndNativeUndoRestoresExactly() throws {
    let f = try Fixture(); defer {f.close()}
    f.select([f.patchID])
    let before = f.store.project!,patch = f.object(f.patchID),placement = before.textilePlacement(patch)
    let builds = f.scene.geometryBuilds
    let delta = try f.dragPatch()
    let applied = f.store.project!,moved = f.object(f.patchID),after = applied.textilePlacement(moved)
    XCTAssertEqual(after.position.x,(placement.position.x+delta.x).rounded(),accuracy:0.00001)
    XCTAssertEqual(after.position.z,(placement.position.z+delta.z).rounded(),accuracy:0.00001)
    XCTAssertNotEqual(moved.textile?.attachment?.offset,patch.textile?.attachment?.offset)
    XCTAssertEqual(moved.textile?.attachment?.garmentID,f.jacketID)
    XCTAssertEqual(moved.textile?.attachment?.rotation,patch.textile?.attachment?.rotation)
    XCTAssertEqual(moved.textile?.attachment?.clearance,patch.textile?.attachment?.clearance)
    XCTAssertEqual(moved.position,patch.position)
    XCTAssertEqual(moved.artwork,patch.artwork)
    XCTAssertEqual(f.object(f.jacketID),before.objects.first {$0.id == f.jacketID})
    XCTAssertEqual(f.scene.geometryBuilds,builds)
    XCTAssertEqual(f.store.engine.undoStack.count,1)
    f.store.undo(); f.store.synchronizeScene()
    XCTAssertEqual(f.store.project,before)
    f.store.redo(); f.store.synchronizeScene()
    XCTAssertEqual(f.store.project,applied)
    XCTAssertEqual(f.scene.geometryBuilds,builds)
  }

  func testSelectingTheJacketAndItsPatchMovesTheAttachmentOnceInEitherObjectOrder() throws {
    for childFirst in [false,true] {
      let f = try Fixture(childFirst:childFirst); defer {f.close()}
      f.select([f.jacketID,f.patchID])
      let before = f.store.project!,jacket = f.object(f.jacketID),patch = f.object(f.patchID)
      let oldPlacement = before.textilePlacement(patch)
      let builds = f.scene.geometryBuilds
      let delta = try f.dragPatch()
      let movedJacket = f.object(f.jacketID),movedPatch = f.object(f.patchID)
      let placement = f.store.project!.textilePlacement(movedPatch)
      let expectedX = (jacket.position.x+delta.x).rounded()-jacket.position.x
      let expectedZ = (jacket.position.z+delta.z).rounded()-jacket.position.z
      XCTAssertEqual(movedJacket.position.x-jacket.position.x,expectedX,accuracy:0.00001)
      XCTAssertEqual(movedJacket.position.z-jacket.position.z,expectedZ,accuracy:0.00001)
      XCTAssertEqual(placement.position.x-oldPlacement.position.x,expectedX,accuracy:0.00001)
      XCTAssertEqual(placement.position.z-oldPlacement.position.z,expectedZ,accuracy:0.00001)
      XCTAssertEqual(movedPatch,patch,"Moving its selected parent must retain the exact relative attachment")
      XCTAssertEqual(f.scene.geometryBuilds,builds)
      XCTAssertEqual(f.store.engine.undoStack.count,1)
      f.store.undo(); f.store.synchronizeScene()
      XCTAssertEqual(f.store.project,before)
    }
  }

  func testDetachingATiltedPatchClearsThePreviousSurfaceNormalWithoutGeometryRebuilds() throws {
    let f = try Fixture(); defer {f.close()}
    let before = f.store.project!,patch = f.object(f.patchID),placement = before.textilePlacement(patch)
    let attached = f.node(f.patchID)
    XCTAssertGreaterThan(abs(Double(attached.simdWorldUp.x))+abs(Double(attached.simdWorldUp.z)),0.01)
    let builds = f.scene.geometryBuilds
    try f.store.engine.edit("Detached patch for independent placement") { project in
      project.detachTextileConsumers(of:[f.jacketID])
    }
    f.store.synchronizeScene()
    let detached = f.object(f.patchID),node = f.node(f.patchID)
    XCTAssertNil(detached.textile?.attachment)
    XCTAssertEqual(detached.position,placement.position)
    XCTAssertEqual(Double(node.simdWorldUp.x),0,accuracy:0.00001)
    XCTAssertEqual(Double(node.simdWorldUp.y),1,accuracy:0.00001)
    XCTAssertEqual(Double(node.simdWorldUp.z),0,accuracy:0.00001)
    XCTAssertEqual(f.scene.geometryBuilds,builds)
    f.store.undo(); f.store.synchronizeScene()
    XCTAssertEqual(f.store.project,before)
    XCTAssertEqual(Double(f.node(f.patchID).simdWorldUp.x),placement.normal.x,accuracy:0.00001)
    XCTAssertEqual(Double(f.node(f.patchID).simdWorldUp.y),placement.normal.y,accuracy:0.00001)
    XCTAssertEqual(Double(f.node(f.patchID).simdWorldUp.z),placement.normal.z,accuracy:0.00001)
  }

  func testEveryTextileZoneNormalAndFocusedBoundsMatchTheActualSceneTransform() throws {
    let f = try Fixture(); defer {f.close()}
    f.select([f.patchID])
    let builds = f.scene.geometryBuilds
    for zone in [TextileAttachment.Zone.leftChest,.rightChest,.leftSleeve,.rightSleeve,.collar,.back] {
      let index = f.store.project!.objects.firstIndex {$0.id == f.patchID}!
      f.store.engine.project!.objects[index].textile?.attachment?.zone = zone
      f.store.synchronizeScene()
      let placement = f.store.project!.textilePlacement(f.object(f.patchID)),node = f.node(f.patchID)
      XCTAssertEqual(Double(node.simdWorldUp.x),placement.normal.x,accuracy:0.00001)
      XCTAssertEqual(Double(node.simdWorldUp.y),placement.normal.y,accuracy:0.00001)
      XCTAssertEqual(Double(node.simdWorldUp.z),placement.normal.z,accuracy:0.00001)
      XCTAssertEqual(Double(node.position.x)*100,placement.position.x,accuracy:0.0001)
      XCTAssertEqual(Double(node.position.y)*100,placement.position.y,accuracy:0.0001)
      XCTAssertEqual(Double(node.position.z)*100,placement.position.z,accuracy:0.0001)
      for projection in ["perspective","orthographic"] {
        f.scene.camera.orientation = nil
        f.scene.camera.azimuth = 0.43
        f.scene.camera.elevation = zone == .back ? -0.8:0.8
        f.scene.camera.projection = projection
        f.scene.focusSelection()
        let bounds = node.boundingBox
        for x in [bounds.min.x,bounds.max.x] {for y in [bounds.min.y,bounds.max.y] {for z in [bounds.min.z,bounds.max.z] {
          let point = f.view.projectPoint(node.convertPosition(.init(x,y,z),to:nil))
          XCTAssertGreaterThanOrEqual(point.x,0)
          XCTAssertLessThanOrEqual(point.x,1200-ObjectInspector.width-48)
          XCTAssertGreaterThanOrEqual(point.y,80)
          XCTAssertLessThanOrEqual(point.y,720)
          XCTAssertGreaterThan(point.z,0); XCTAssertLessThan(point.z,1)
        }}}
      }
    }
    XCTAssertEqual(f.scene.geometryBuilds,builds)
    XCTAssertFalse(f.view.rendersContinuously)
  }
}

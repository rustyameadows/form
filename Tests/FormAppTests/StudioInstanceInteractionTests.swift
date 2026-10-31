import AppKit
import FormCore
import FormGeometry
import LabRendering
import SwiftUI
import XCTest
@testable import FormApp

/// Real stage picking and AppKit input. No OS input or design-store borrowing.
@MainActor final class StudioInstanceInteractionTests:XCTestCase {
  @MainActor private final class Fixture {
    let root:URL,store:StudioStore,window:NSWindow
    let controller:StudioCompositionController
    var view:TableSceneView {controller.stage.view!}
    init(attached:Bool=false)throws {
      _ = NSApplication.shared
      root=FileManager.default.temporaryDirectory.appendingPathComponent("studio-instance-input-"+UUID().uuidString)
      store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
      var project=Project(name:"Independent presentation placement")
      if attached {
        let garment=try project.makeObject(recipeID:"bomberJacket",materialID:"flight-nylon")
        var patch=try project.makeObject(recipeID:"textilePatch",materialID:"patch-twill")
        patch.parameters["width"]=100;patch.parameters["depth"]=80
        patch.artwork=Artwork(background:"#B85139")
        patch.textile?.attachment = .init(garmentID:garment.id,zone:.leftChest,offset:.init(),rotation:0,clearance:2)
        project.objects=[garment,patch]
      }else {
        var source=try project.makeObject(recipeID:"box",parameters:["width":100,"height":90,"depth":70,"corner":2],position:.init(350,25,-140))
        source.color="#C08061";source.rotation=33
        var variant=source;variant.id=UUID();variant.name="Artwork alternative";variant.color="#284C54"
        variant.artwork=Artwork(background:"#F3E9D6",elements:[.init(kind:"text",x:5,y:5,width:50,height:15,text:"FIELD",fontSize:18)])
        project.objects=[source,variant]
      }
      var scene=StudioComposition(name:"Placement scene",camera:project.camera)
      scene.instances=[.init(name:"Independent first copy",sourceObjectID:project.objects[0].id)]
      var second=scene;second.id=UUID();second.name="Other saved scene";second.instances[0].id=UUID();second.instances[0].positionMM.x=240
      project.studioPresentation = .init();project.studioPresentation!.scenes=[scene,second]
      store.engine.project=project;store.showingHome=false
      controller=store.studioComposition;controller.reconcile();controller.gizmoVisible=false
      window=NSWindow(contentRect:.init(x:0,y:0,width:960,height:640),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false;window.setFrameOrigin(.init(x:-10000,y:-10000))
      window.contentView=NSHostingView(rootView:StudioCompositionViewport(controller:controller))
      window.contentView?.layoutSubtreeIfNeeded()
      controller.stage.fitAll();controller.cameraEdited();controller.save()
      window.makeFirstResponder(view)
    }
    func close(){window.contentView=nil;window.close();controller.reset();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    func event(_ type:NSEvent.EventType,_ point:NSPoint,flags:NSEvent.ModifierFlags=[])->NSEvent {
      NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1)!
    }
    func pickPoint(_ id:UUID)throws->NSPoint {
      let node=try XCTUnwrap(controller.stage.logicalNode(for:id)),b=try XCTUnwrap(controller.stage.localBounds(for:id))
      let q=view.projectPoint(node.convertPosition(.init((b.min.x+b.max.x)/2,(b.min.y+b.max.y)/2,(b.min.z+b.max.z)/2),to:nil))
      for y in stride(from:-20.0,through:20,by:4) {for x in stride(from:-20.0,through:20,by:4) {
        let point=NSPoint(x:q.x+x,y:q.y+y)
        if controller.stage.objectID(at:point)==id {return point}
      }}
      throw FormError.invalid("Actual stage mesh could not be picked at its projected bounds")
    }
    func drag(from start:NSPoint,dx:Double,dy:Double,flags:NSEvent.ModifierFlags=[]) {
      view.mouseDown(with:event(.leftMouseDown,start,flags:flags))
      for fraction in [0.3,0.65,1.0] {view.mouseDragged(with:event(.leftMouseDragged,.init(x:start.x+dx*fraction,y:start.y+dy*fraction),flags:flags))}
      view.mouseUp(with:event(.leftMouseUp,.init(x:start.x+dx,y:start.y+dy),flags:flags))
    }
  }
  func testNativeMoveLiftRotateAreIndependentAndExactlyOneDraftUndoWithoutGeometryRebuild()throws {
    let f=try Fixture();defer{f.close()}
    let c=f.controller,source=f.store.project!,before=try XCTUnwrap(c.draft),id=before.instances[0].id
    XCTAssertNil(c.stage.store);XCTAssertEqual(c.tool,.move);XCTAssertFalse(c.canUndoDraft)
    let builds=c.stage.geometryBuilds,documentUndo=f.store.engine.undoStack.count
    for tool in [StudioCompositionTool.move,.lift,.rotate] {
      c.tool=tool;let camera=c.stage.camera,start=try f.pickPoint(id)
      f.drag(from:start,dx:70,dy:45)
      let changed=try XCTUnwrap(c.draft),value=changed.instances[0],original=before.instances[0]
      XCTAssertEqual(c.selectedInstanceID,id);XCTAssertNotEqual(value,original)
      switch tool {
      case .move:XCTAssertEqual(value.positionMM.y,original.positionMM.y);XCTAssertEqual(value.rotationDegrees,original.rotationDegrees)
      case .lift:XCTAssertEqual(value.positionMM.x,original.positionMM.x);XCTAssertEqual(value.positionMM.z,original.positionMM.z);XCTAssertNotEqual(value.positionMM.y,original.positionMM.y)
      case .rotate:XCTAssertEqual(value.positionMM,original.positionMM);XCTAssertEqual(value.rotationDegrees,original.rotationDegrees+35,accuracy:1e-9)
      case .orbit:break
      }
      XCTAssertEqual(changed.camera,before.camera);XCTAssertEqual(c.stage.camera,camera)
      XCTAssertTrue(c.undoDraft());XCTAssertEqual(c.draft,before);XCTAssertFalse(c.canUndoDraft)
      XCTAssertTrue(c.redoDraft());XCTAssertEqual(c.draft,changed)
      XCTAssertTrue(c.undoDraft());XCTAssertEqual(c.draft,before)
      XCTAssertEqual(f.store.project,source);XCTAssertEqual(f.store.engine.undoStack.count,documentUndo)
    }
    XCTAssertEqual(c.stage.geometryBuilds,builds)
  }
  func testExactFrontAndTopMoveLiftUseConstrainedFallbackWithoutOrbiting()throws {
    let f=try Fixture();defer{f.close()};let c=f.controller,id=c.draft!.instances[0].id
    for name in ["front","overhead"] {for tool in [StudioCompositionTool.move,.lift] {
      // Native view shortcuts must also persist the effective draft camera.
      let key=name=="front" ? "3":"2"
      f.view.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:f.window.windowNumber,context:nil,characters:key,charactersIgnoringModifiers:key,isARepeat:false,keyCode:name=="front" ? 20:19)!)
      XCTAssertEqual(c.draft?.camera.projection,"orthographic")
      XCTAssertEqual(c.draft?.camera.elevation,name=="front" ? 0:Double.pi/2)
      c.save();c.tool=tool
      let before=try XCTUnwrap(c.draft),camera=c.stage.camera,point=try f.pickPoint(id)
      f.drag(from:point,dx:55,dy:35)
      let value=try XCTUnwrap(c.selected)
      XCTAssertNotEqual(value.positionMM,before.instances[0].positionMM)
      XCTAssertEqual(c.stage.camera,camera);XCTAssertEqual(c.draft?.camera,before.camera)
      if tool == .move {XCTAssertEqual(value.positionMM.y,before.instances[0].positionMM.y)}
      else {XCTAssertEqual(value.positionMM.x,before.instances[0].positionMM.x);XCTAssertEqual(value.positionMM.z,before.instances[0].positionMM.z)}
      XCTAssertTrue(c.undoDraft());XCTAssertEqual(c.draft,before);XCTAssertFalse(c.canUndoDraft)
    }}
  }
  func testNoOpEscapeResizeAndSceneProjectChangesRollbackAndIgnoreLateEvents()throws {
    let f=try Fixture();defer{f.close()};let c=f.controller,before=try XCTUnwrap(c.draft),id=before.instances[0].id
    let start=try f.pickPoint(id)
    f.view.mouseDown(with:f.event(.leftMouseDown,start));f.view.mouseUp(with:f.event(.leftMouseUp,start))
    f.drag(from:start,dx:2,dy:0);f.drag(from:start,dx:0,dy:0)
    XCTAssertEqual(c.draft,before);XCTAssertFalse(c.canUndoDraft)
    // A real displaced gesture that returns to its anchor is also a no-op.
    f.view.mouseDown(with:f.event(.leftMouseDown,start));f.view.mouseDragged(with:f.event(.leftMouseDragged,.init(x:start.x+70,y:start.y)))
    f.view.mouseDragged(with:f.event(.leftMouseDragged,start));f.view.mouseUp(with:f.event(.leftMouseUp,start))
    XCTAssertEqual(c.draft,before);XCTAssertFalse(c.canUndoDraft)
    for resize in [false,true] {
      let point=try f.pickPoint(id)
      f.view.mouseDown(with:f.event(.leftMouseDown,point));f.view.mouseDragged(with:f.event(.leftMouseDragged,.init(x:point.x+70,y:point.y)))
      XCTAssertNotEqual(c.draft,before)
      if resize {f.view.setFrameSize(.init(width:920,height:620))}
      else {f.view.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:f.window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!)}
      f.view.mouseDragged(with:f.event(.leftMouseDragged,.init(x:point.x+130,y:point.y)));f.view.mouseUp(with:f.event(.leftMouseUp,.init(x:point.x+130,y:point.y)))
      XCTAssertEqual(c.draft,before);XCTAssertFalse(c.canUndoDraft)
    }
    let point=try f.pickPoint(id)
    f.view.mouseDown(with:f.event(.leftMouseDown,point));f.view.mouseDragged(with:f.event(.leftMouseDragged,.init(x:point.x+70,y:point.y)))
    let next=c.scenes[1];c.load(next.id,discard:true)
    f.view.mouseDragged(with:f.event(.leftMouseDragged,.init(x:point.x+140,y:point.y)));f.view.mouseUp(with:f.event(.leftMouseUp,point))
    XCTAssertEqual(c.draft,next)
    let nextPoint=try f.pickPoint(next.instances[0].id)
    f.view.mouseDown(with:f.event(.leftMouseDown,nextPoint));f.view.mouseDragged(with:f.event(.leftMouseDragged,.init(x:nextPoint.x+50,y:nextPoint.y)))
    var other=Project(name:"Next document");other.objects=[try other.makeObject(recipeID:"box")]
    f.store.engine.project=other;c.reconcile();let adopted=c.draft
    f.view.mouseDragged(with:f.event(.leftMouseDragged,.init(x:nextPoint.x+130,y:nextPoint.y)));f.view.mouseUp(with:f.event(.leftMouseUp,nextPoint))
    XCTAssertEqual(f.store.project,other);XCTAssertEqual(c.draft,adopted);XCTAssertFalse(c.canUndoDraft)
  }
  func testDuplicateHighlightVariantsAndEmptySceneKeepCanonicalDesignObjectsUntouched()throws {
    let f=try Fixture();defer{f.close()};let c=f.controller,source=f.store.project!,original=try XCTUnwrap(c.draft)
    c.selectInstance(original.instances[0].id);let request=c.selectionRequest;c.selectInstance(original.instances[0].id)
    XCTAssertGreaterThan(c.selectionRequest,request)
    c.duplicateInstance();let duplicate=try XCTUnwrap(c.selected)
    XCTAssertNotEqual(duplicate.id,original.instances[0].id);XCTAssertEqual(duplicate.sourceObjectID,original.instances[0].sourceObjectID)
    XCTAssertTrue(try XCTUnwrap(c.stage.logicalNode(for:duplicate.id)).childNodes.contains{$0.name=="selection"})
    XCTAssertTrue(c.undoDraft());XCTAssertEqual(c.draft,original);XCTAssertFalse(c.canUndoDraft)
    let unchangedCamera=c.stage.camera
    c.focusSelected();XCTAssertEqual(c.stage.camera,unchangedCamera);XCTAssertFalse(c.canUndoDraft)
    c.selectInstance(original.instances[0].id);let alternate=source.objects[1]
    c.changeInstance{$0.sourceObjectID=alternate.id}
    let resolved=try XCTUnwrap(c.draft).resolved(in:source),shown=try XCTUnwrap(resolved.project.objects.first{$0.id==original.instances[0].id})
    XCTAssertEqual(shown.artwork,alternate.artwork);XCTAssertEqual(shown.color,alternate.color)
    XCTAssertEqual(f.store.project,source)
    c.changeInstance{$0.visible=false};let hiddenCamera=c.stage.camera,hiddenDraft=c.draft
    c.focusSelected();XCTAssertEqual(c.stage.camera,hiddenCamera);XCTAssertEqual(c.draft,hiddenDraft)
    c.newEmptyScene(discard:true);XCTAssertTrue(c.draft?.instances.isEmpty==true);XCTAssertNil(c.error);XCTAssertFalse(c.dirty)
    c.add(source.objects[0]);XCTAssertEqual(c.draft?.instances.count,1);XCTAssertNil(c.error)
    XCTAssertTrue(c.undoDraft());XCTAssertTrue(c.draft?.instances.isEmpty==true);XCTAssertNil(c.error)
  }
  func testAttachmentRenderPickSelectsOwningInstanceAndFocusIncludesItsPhysicalGeometry()throws {
    let f=try Fixture(attached:true);defer{f.close()};let c=f.controller,source=f.store.project!,scene=try XCTUnwrap(c.draft),root=scene.instances[0].id
    let resolved=try scene.resolved(in:source),child=try XCTUnwrap(resolved.visible.first{$0 != root})
    let point=try f.pickPoint(child)
    f.view.mouseDown(with:f.event(.leftMouseDown,point));f.view.mouseUp(with:f.event(.leftMouseUp,point))
    XCTAssertEqual(c.selectedInstanceID,root)
    c.focusSelected();let rectangle=try XCTUnwrap(c.stage.navigationFramingRect)
    for id in resolved.visible {
      let node=try XCTUnwrap(c.stage.logicalNode(for:id)),b=try XCTUnwrap(c.stage.localBounds(for:id))
      for x in [b.min.x,b.max.x] {for y in [b.min.y,b.max.y] {for z in [b.min.z,b.max.z] {
        let p=f.view.projectPoint(node.convertPosition(.init(x,y,z),to:nil))
        XCTAssertTrue(rectangle.insetBy(dx:-0.5,dy:-0.5).contains(.init(x:p.x,y:f.view.bounds.height-p.y)))
      }}}
    }
    XCTAssertEqual(f.store.project,source)
  }
  func testExportInterruptionRollsBackPendingMovementBeforeRejectingDestination()async throws {
    let f=try Fixture();defer{f.close()};let c=f.controller,before=try XCTUnwrap(c.draft),source=f.store.project!,point=try f.pickPoint(before.instances[0].id)
    f.view.mouseDown(with:f.event(.leftMouseDown,point));f.view.mouseDragged(with:f.event(.leftMouseDragged,.init(x:point.x+60,y:point.y)))
    XCTAssertNotEqual(c.draft,before)
    do {_ = try await c.export(before,to:f.root.appendingPathComponent("blocked.render"),video:false);XCTFail("Repository-internal destination must reject")}
    catch {XCTAssertTrue(error.localizedDescription.contains("Exports folder"))}
    f.view.mouseDragged(with:f.event(.leftMouseDragged,.init(x:point.x+110,y:point.y)));f.view.mouseUp(with:f.event(.leftMouseUp,point))
    XCTAssertEqual(c.draft,before);XCTAssertFalse(c.canUndoDraft);XCTAssertEqual(f.store.project,source)
  }
  func testStudioEditingOutlinesAreVisibleButSnapshotsAndDefaultShotStagesExcludeThem()async throws {
    let f=try Fixture();defer{f.close()};let c=f.controller,scene=try XCTUnwrap(c.draft),id=scene.instances[0].id
    c.selectInstance(id);c.gizmoVisible=true
    let node=try XCTUnwrap(c.stage.logicalNode(for:id))
    XCTAssertTrue(node.childNodes.contains{$0.name=="selection" && !$0.isHidden})
    let selected=try await c.stage.snapshot(size:.init(width:180,height:120))
    XCTAssertTrue(node.childNodes.contains{$0.name=="selection" && !$0.isHidden},"Capture must restore the editing outline")
    c.selectInstance(nil)
    let unselected=try await c.stage.snapshot(size:.init(width:180,height:120))
    XCTAssertEqual(selected.tiffRepresentation,unselected.tiffRepresentation,"Editing selection must never enter captured pixels")
    let resolved=try scene.resolved(in:f.store.project!),shot=TableSceneController()
    XCTAssertFalse(shot.showsStudioSelection)
    shot.sync(resolved.project,selection:[id],isolated:resolved.visible,showGrid:false,studio:true,preset:scene.surface,assets:f.root.appendingPathComponent("Assets"),renderObjectIDs:resolved.visible)
    XCTAssertFalse(try XCTUnwrap(shot.logicalNode(for:id)).childNodes.contains{$0.name=="selection"})
  }
  func testNativeXYZGizmoArrowsConstrainWorldAxesInPerspectiveFrontAndTopRegardlessOfTool()throws {
    let f=try Fixture();defer{f.close()};let c=f.controller,id=c.draft!.instances[0].id
    c.gizmoVisible=true;c.tool = .orbit;c.selectInstance(id)
    for camera in ["perspective","front","overhead"] {
      c.stage.preset(camera);c.cameraEdited();c.save()
      for handle in [StudioTransformGizmo.Handle.x,.y,.z] {
        let source=f.store.project!,before=try XCTUnwrap(c.draft),gizmo=try XCTUnwrap(c.presentationGizmo)
        let start=try XCTUnwrap(gizmo.handlePoint(handle)),axis=try XCTUnwrap(gizmo.axis(handle))
        XCTAssertEqual(gizmo.hitTest(start),handle)
        let dx:Double,dy:Double,expected:Double
        if axis.endOn {dx=handle == .x ? 36:0;dy=handle == .x ? 0:handle == .y ? 36:-36;expected=36*gizmo.millimetersPerPoint}
        else {
          // Independent renderer projection of a known +15mm world-axis move.
          let world=gizmo.centerMM+axis.world*(gizmo.lengthMM+15)
          let q=try XCTUnwrap(SceneProjection.project(world,camera:gizmo.camera,viewport:gizmo.viewport))
          dx=q.x-start.x;dy=gizmo.viewport.height-q.y-start.y;expected=15
        }
        let cameraBefore=c.stage.camera,builds=c.stage.geometryBuilds
        f.drag(from:start,dx:dx,dy:dy)
        let value=try XCTUnwrap(c.selected),original=before.instances[0]
        XCTAssertNotEqual(value.positionMM,original.positionMM);XCTAssertEqual(value.rotationDegrees,original.rotationDegrees)
        XCTAssertEqual(value.positionMM.x,original.positionMM.x+axis.world.x*expected,accuracy:1e-8)
        XCTAssertEqual(value.positionMM.y,original.positionMM.y+axis.world.y*expected,accuracy:1e-8)
        XCTAssertEqual(value.positionMM.z,original.positionMM.z+axis.world.z*expected,accuracy:1e-8)
        XCTAssertEqual(c.stage.camera,cameraBefore);XCTAssertEqual(c.draft?.camera,before.camera)
        XCTAssertEqual(c.stage.geometryBuilds,builds);XCTAssertEqual(f.store.project,source)
        XCTAssertTrue(c.undoDraft());XCTAssertEqual(c.draft,before);XCTAssertFalse(c.canUndoDraft)
        XCTAssertTrue(c.redoDraft());XCTAssertEqual(c.selected?.positionMM,value.positionMM)
        XCTAssertTrue(c.undoDraft());XCTAssertEqual(c.draft,before)
      }
    }
  }
  func testNativeYawRingUsesProjectedQuarterTurnAndUnwrapsAcrossPiWithoutDrift()throws {
    let f=try Fixture();defer{f.close()};let c=f.controller,id=c.draft!.instances[0].id
    c.gizmoVisible=true;c.tool = .move;c.selectInstance(id)
    for camera in ["perspective","front","overhead"] {
      c.stage.preset(camera);c.cameraEdited();c.save()
      let before=try XCTUnwrap(c.draft),gizmo=try XCTUnwrap(c.presentationGizmo)
      XCTAssertEqual(gizmo.ringFallback,camera=="front")
      let index=try XCTUnwrap((25...30).first{gizmo.hitTest(gizmo.ring[$0]) == .yaw})
      let start=gizmo.ring[index],end=gizmo.ring[index+18]
      f.view.mouseDown(with:f.event(.leftMouseDown,start))
      for offset in [6,12,18,18] {f.view.mouseDragged(with:f.event(.leftMouseDragged,gizmo.ring[index+offset]))}
      f.view.mouseUp(with:f.event(.leftMouseUp,end))
      XCTAssertEqual(c.selected?.rotationDegrees ?? .nan,before.instances[0].rotationDegrees+90,accuracy:1e-8)
      XCTAssertEqual(c.selected?.positionMM,before.instances[0].positionMM)
      XCTAssertTrue(c.undoDraft());XCTAssertEqual(c.draft,before);XCTAssertFalse(c.canUndoDraft)
      // Returning through the same physical ring points must not leave tiny
      // accumulated angular noise or manufacture an Undo entry.
      f.view.mouseDown(with:f.event(.leftMouseDown,start))
      for offset in [6,12,18,12,6,0] {f.view.mouseDragged(with:f.event(.leftMouseDragged,gizmo.ring[index+offset]))}
      f.view.mouseUp(with:f.event(.leftMouseUp,start))
      XCTAssertEqual(c.draft,before);XCTAssertFalse(c.canUndoDraft)
    }
  }
  func testGizmoNoOpClicksEscapeAndVisibilityCancellationKeepSelectionAndSource()throws {
    let f=try Fixture();defer{f.close()};let c=f.controller,id=c.draft!.instances[0].id,source=f.store.project!
    c.gizmoVisible=true;c.selectInstance(id)
    let before=try XCTUnwrap(c.draft),gizmo=try XCTUnwrap(c.presentationGizmo)
    XCTAssertTrue(f.view.subviews.contains{$0 is StudioTransformGizmoOverlay})
    let points=gizmo.axes.map(\.tip)+[gizmo.ring[27]]
    for point in points {
      f.view.mouseDown(with:f.event(.leftMouseDown,point));f.view.mouseUp(with:f.event(.leftMouseUp,point))
      XCTAssertEqual(c.selectedInstanceID,id);XCTAssertEqual(c.draft,before);XCTAssertFalse(c.canUndoDraft)
    }
    let start=try XCTUnwrap(gizmo.handlePoint(.x)),axis=try XCTUnwrap(gizmo.axis(.x))
    let dx=(axis.tip.x-gizmo.center.x)*0.4,dy=(axis.tip.y-gizmo.center.y)*0.4
    for hide in [false,true] {
      f.view.mouseDown(with:f.event(.leftMouseDown,start));f.view.mouseDragged(with:f.event(.leftMouseDragged,.init(x:start.x+dx,y:start.y+dy)))
      XCTAssertNotEqual(c.draft,before)
      if hide {c.gizmoVisible=false;XCTAssertNil(c.presentationGizmo)}
      else {f.view.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:f.window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!)}
      f.view.mouseDragged(with:f.event(.leftMouseDragged,.init(x:start.x+2*dx,y:start.y+2*dy)));f.view.mouseUp(with:f.event(.leftMouseUp,start))
      XCTAssertEqual(c.draft,before);XCTAssertFalse(c.canUndoDraft);XCTAssertEqual(c.selectedInstanceID,id)
      c.gizmoVisible=true
    }
    XCTAssertEqual(f.store.project,source)
  }
  func testAsymmetricSourceYawGizmoUsesTheActualInstanceOriginRatherThanBoundsCenter()throws {
    let f=try Fixture();defer{f.close()};let c=f.controller,id=c.draft!.instances[0].id
    var project=f.store.project!
    project.recipes.append(.init("offset-gizmo-source","Offset solid","cube","Independent local geometry",[],parts:[
      .init("box",["width":"100","height":"60","depth":"70","x":"130","y":"30","z":"40","corner":"0"])]))
    project.objects[0].recipeID="offset-gizmo-source";project.objects[0].parameters=[:]
    f.store.engine.project=project;c.reconcile();c.selectInstance(id);c.gizmoVisible=true
    c.stage.fitAll();c.stage.camera.distance*=2;c.stage.updateCamera();c.cameraEdited();c.save()
    let before=try XCTUnwrap(c.draft),gizmo=try XCTUnwrap(c.presentationGizmo),node=try XCTUnwrap(c.stage.logicalNode(for:id)),bounds=try XCTUnwrap(c.stage.localBounds(for:id))
    let localCenter=MeshVector3((bounds.min.x+bounds.max.x)/2,(bounds.min.y+bounds.max.y)/2,(bounds.min.z+bounds.max.z)/2)
    let worldBefore=node.convertPosition(localCenter,to:nil).simd*100
    XCTAssertEqual(gizmo.centerMM.x,before.instances[0].positionMM.x,accuracy:1e-9)
    XCTAssertEqual(gizmo.centerMM.z,before.instances[0].positionMM.z,accuracy:1e-9)
    XCTAssertGreaterThan(abs(worldBefore.x-gizmo.centerMM.x),100)
    let index=try XCTUnwrap((25...30).first{gizmo.hitTest(gizmo.ring[$0]) == .yaw})
    XCTAssertTrue(f.view.bounds.contains(gizmo.ring[index]))
    f.view.mouseDown(with:f.event(.leftMouseDown,gizmo.ring[index]))
    for offset in [6,12,18] {f.view.mouseDragged(with:f.event(.leftMouseDragged,gizmo.ring[index+offset]))}
    f.view.mouseUp(with:f.event(.leftMouseUp,gizmo.ring[index+18]))
    XCTAssertEqual(c.selected?.positionMM,before.instances[0].positionMM)
    XCTAssertEqual(c.selected?.rotationDegrees ?? .nan,90,accuracy:1e-8)
    let after=try XCTUnwrap(c.stage.logicalNode(for:id)).convertPosition(localCenter,to:nil).simd*100
    XCTAssertEqual(after.x,worldBefore.z,accuracy:1e-4);XCTAssertEqual(after.z,-worldBefore.x,accuracy:1e-4)
    XCTAssertTrue(c.undoDraft());XCTAssertEqual(c.draft,before)
  }
}

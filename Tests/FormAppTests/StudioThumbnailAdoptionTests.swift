import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor final class StudioThumbnailAdoptionTests:XCTestCase {
  private func fixture()throws->(StudioStore,Project,StudioComposition,StudioComposition) {
    _=NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("studio-thumbnail-adoption-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    var project=Project(name:"Native Studio adoption")
    var object=try project.makeObject(recipeID:"box",parameters:["width":400,"height":220,"depth":280])
    object.color="#426DB2";project.objects=[object]
    var camera=CameraState()
    camera.distance=17.237546451697753;camera.azimuth=0.40489178628508343
    camera.elevation=1.1421808210221485;camera.target = .init(0,1.2,0);camera.viewportAspect=1.5
    var first=StudioComposition(name:"Fractional saved camera",camera:camera)
    first.instances=[.init(name:"Left source copy",sourceObjectID:object.id,positionMM:.init(-250,0,0)),
      .init(name:"Right source copy",sourceObjectID:object.id,positionMM:.init(250,0,0))]
    var second=StudioComposition(name:"Another saved still",camera:camera)
    second.camera.azimuth+=0.5;second.instances=[.init(name:"Turned source copy",sourceObjectID:object.id,rotationDegrees:35)]
    project.studioPresentation = .init();project.studioPresentation!.scenes=[first,second]
    project.schemaVersion=project.minimumSchemaVersion
    store.engine.project=project;store.showingHome=false;store.environment = .studio;store.mode = .studio
    addTeardownBlock { @MainActor in
      store.studioComposition.reset();store.studioComposition.stage.view=nil;store.engine.project=nil
      try? FileManager.default.removeItem(at:directory)
    }
    return(store,project,first,second)
  }
  private func assets(_ store:StudioStore,_ project:Project)->URL {
    store.repository.url(for:project.id).appendingPathComponent("Assets")
  }
  private func descendants(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(descendants)}
  private func settle(_ host:NSView) {
    host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.04));host.layoutSubtreeIfNeeded()
  }

  func testPreSynchronizedCacheSurvivesFirstReconcileAndSameProjectReentry()async throws {
    let (store,project,scene,_)=try fixture(),controller=store.studioComposition,cache=controller.thumbnails
    XCTAssertNil(controller.draft)
    // Force the ordering that the workspace's task and onAppear may take.
    cache.synchronize(project:project,assets:assets(store,project))
    controller.reconcile()
    let image=try await cache.image(for:scene,preflight:{_,_ in})
    XCTAssertEqual(cache.renderCount,1)
    let key=cache.key(for:scene)
    controller.selectInstance(scene.instances[0].id);controller.reconcile()
    let selectedImage=try await cache.image(for:scene,preflight:{_,_ in})
    XCTAssertTrue(selectedImage === image)
    cache.suspend();controller.reconcile()
    let returnedImage=try await cache.image(for:scene,preflight:{_,_ in})
    XCTAssertTrue(returnedImage === image)
    XCTAssertEqual(cache.renderCount,1,"Same-project selection and reentry retain completed pixels")
    XCTAssertEqual(cache.key(for:scene),key)
    XCTAssertEqual(controller.draft,scene);XCTAssertFalse(controller.dirty);XCTAssertFalse(controller.canUndoDraft)
    XCTAssertEqual(store.project,project);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testSceneRequestBeforeAppearanceRestoresItsThumbnailSourceAfterAdoption()async throws {
    let (store,project,_,scene)=try fixture(),controller=store.studioComposition,cache=controller.thumbnails
    cache.synchronize(project:project,assets:assets(store,project))
    controller.requestScene(scene.id)
    XCTAssertEqual(controller.draft,scene)
    let image=try await cache.image(for:scene,preflight:{_,_ in})
    XCTAssertGreaterThan(image.size.width,0);XCTAssertEqual(cache.renderCount,1)
    XCTAssertEqual(controller.draft,scene);XCTAssertFalse(controller.dirty)
    XCTAssertEqual(store.project,project);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testFirstNativeWorkspaceMountAndRealInstancePickPreserveCompleteFractionalScene()async throws {
    let (store,project,scene,_)=try fixture(),controller=store.studioComposition
    XCTAssertNil(controller.draft,"Do not preload the controller before native appearance")
    let host=NSHostingView(rootView:StudioCompositionWorkspace(controller:controller).environmentObject(store).labInterface())
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1180,height:900),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil)
    defer{window.makeFirstResponder(nil);window.contentView=nil;window.close()}
    settle(host)
    for _ in 0..<200 where controller.draft==nil {try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertEqual(controller.draft,scene);XCTAssertFalse(controller.dirty)
    let view=try XCTUnwrap(controller.stage.view),id=scene.instances[0].id
    let node=try XCTUnwrap(controller.stage.logicalNode(for:id)),bounds=try XCTUnwrap(controller.stage.localBounds(for:id))
    let center=node.convertPosition(.init((bounds.min.x+bounds.max.x)/2,(bounds.min.y+bounds.max.y)/2,(bounds.min.z+bounds.max.z)/2),to:nil)
    let projected=view.projectPoint(center)
    var hit:NSPoint?
    for y in stride(from:-20.0,through:20,by:4) {
      for x in stride(from:-20.0,through:20,by:4) {
        let point=NSPoint(x:projected.x+x,y:projected.y+y)
        if controller.stage.objectID(at:point)==id {hit=point;break}
      }
      if hit != nil {break}
    }
    let location=view.convert(try XCTUnwrap(hit,"Find the actual rendered instance"),to:nil)
    for kind in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
      let event=try XCTUnwrap(NSEvent.mouseEvent(with:kind,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:kind == .leftMouseDown ? 1:0))
      if kind == .leftMouseDown {view.mouseDown(with:event)}else{view.mouseUp(with:event)}
    }
    settle(host)
    XCTAssertEqual(controller.selectedInstanceID,id)
    XCTAssertEqual(controller.draft,scene,"Compare every saved field, including camera precision and optional orientation")
    XCTAssertFalse(controller.dirty);XCTAssertFalse(controller.canUndoDraft)
    let context=store.selectionContext(),studio=try XCTUnwrap(context["studio"] as? [String:Any])
    XCTAssertEqual(studio["has_unsaved_changes"] as? Bool,false)
    XCTAssertEqual(studio["native_draft_changed"] as? Bool,false)
    // Exercise the actual row task, not only the standalone cache API.
    var rows:[StudioSceneThumbnailNativeButton]=[]
    for _ in 0..<1000 {
      rows=descendants(host).compactMap{$0 as? StudioSceneThumbnailNativeButton}
      if rows.count==2,rows.allSatisfy({$0.thumbnail != nil}) {break}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    XCTAssertEqual(rows.count,2)
    XCTAssertTrue(rows.allSatisfy{$0.thumbnail != nil},"Visible saved scenes must finish their native thumbnails")
    XCTAssertTrue(rows.allSatisfy{$0.subtitle==nil})
    XCTAssertEqual(controller.draft,scene);XCTAssertEqual(store.project,project)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
}

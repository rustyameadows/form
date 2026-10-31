import AppKit
import FormCore
import FormGeometry
import XCTest
@testable import FormApp

@MainActor final class TableViewportFocusTests:XCTestCase {
  private struct Fixture {
    let store:StudioStore,scene:TableSceneController,view:TableSceneView,window:NSWindow
    let ids:[UUID]
  }
  private func fixture()throws->Fixture {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("table-free-viewport-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    var p=Project(name:"Visible Table focus")
    var large=try p.makeObject(recipeID:"box",parameters:["width":950,"height":360,"depth":700],position:.init(-440,0,-200));large.rotation=37
    var small=try p.makeObject(recipeID:"box",parameters:["width":12,"height":8,"depth":7,"corner":0],position:.init(360,80,240));small.rotation = -19
    p.recipes.append(.init("focus-thin","Thin physical sheet","rectangle","Generic flat slab",[],parts:[
      .init("box",["width":"280","depth":"180","height":"0.1","y":"0.05","corner":"0"])]))
    var thin=try p.makeObject(recipeID:"focus-thin",position:.init(150,220,-310));thin.rotation = -11
    p.objects=[large,small,thin]
    store.engine.project=p;store.showingHome=false;store.mode = .table;store.environment = .form
    let scene=TableSceneController(store:store),view=TableSceneView(frame:.init(x:0,y:0,width:1280,height:820))
    store.scene=scene;scene.view=view;view.controller=scene;view.autoresizingMask=[.width,.height]
    let window=NSWindow(contentRect:view.bounds,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.setFrameOrigin(.init(x:-10000,y:-10000));window.contentView=view
    scene.sync(p,selection:[],isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:root.appendingPathComponent("Assets"))
    addTeardownBlock { @MainActor in window.contentView=nil;window.close();store.engine.project=nil;try? FileManager.default.removeItem(at:root) }
    return .init(store:store,scene:scene,view:view,window:window,ids:p.objects.map(\.id))
  }
  private func occlusions(_ size:CGSize,navigator:Bool,inspector:Bool)->[CGRect] {
    var result=[CGRect(x:16,y:size.height-60,width:max(1,size.width-32),height:44)]
    if navigator {result.append(.init(x:16,y:16,width:220,height:min(360,max(180,size.height-116))))}
    if inspector {result.append(.init(x:size.width-302,y:16,width:286,height:max(180,size.height-116)))}
    return result
  }
  private func points(_ f:Fixture,_ ids:[UUID])throws->[MeshVector3] {
    var points=[MeshVector3]()
    for id in ids {
      let node=try XCTUnwrap(f.scene.logicalNode(for:id)),b=try XCTUnwrap(f.scene.localBounds(for:id))
      for x in [b.min.x,b.max.x] {for y in [b.min.y,b.max.y] {for z in [b.min.z,b.max.z] {
        points.append(node.convertPosition(.init(x,y,z),to:nil))
      }}}
    }
    return points
  }
  @discardableResult private func assertVisible(_ f:Fixture,_ points:[MeshVector3],file:StaticString=#filePath,line:UInt=#line)throws->CGRect {
    let free=try XCTUnwrap(f.scene.navigationFramingRect,file:file,line:line)
    var bounds=CGRect.null
    for point in points {
      let q=f.view.projectPoint(point)
      XCTAssertTrue(q.x.isFinite && q.y.isFinite && (0...1).contains(q.z),"Real renderer camera must project every physical corner",file:file,line:line)
      bounds=bounds.union(.init(x:q.x,y:f.view.bounds.height-q.y,width:0,height:0))
    }
    XCTAssertTrue(free.insetBy(dx:-0.5,dy:-0.5).contains(bounds),"Projected bounds \(bounds) escape useful region \(free)",file:file,line:line)
    XCTAssertEqual(bounds.midX,free.midX,accuracy:0.5,file:file,line:line)
    XCTAssertEqual(bounds.midY,free.midY,accuracy:0.5,file:file,line:line)
    for blocked in f.scene.navigationOcclusions ?? [] {
      XCTAssertFalse(bounds.intersection(blocked).width>0 && bounds.intersection(blocked).height>0,"Focused subject sits under a floating control",file:file,line:line)
    }
    return bounds
  }
  func testFocusProjectsLargeSmallRotatedAndThinObjectsIntoFreeRectAcrossLayouts()throws {
    let f=try fixture(),source=try XCTUnwrap(f.store.project),builds=f.scene.geometryBuilds,undo=f.store.engine.undoStack.count
    for size in [CGSize(width:1280,height:820),CGSize(width:620,height:820),CGSize(width:1280,height:410)] {
      f.window.setContentSize(size);f.view.layoutSubtreeIfNeeded()
      for (nav,inspector) in [(false,false),(true,false),(false,true),(true,true)] {
        f.scene.navigationOcclusions=occlusions(f.view.bounds.size,navigator:nav,inspector:inspector)
        for projection in ["perspective","orthographic"] {for id in f.ids {
          var camera=CameraState();camera.projection=projection;f.scene.camera=camera;f.scene.updateCamera()
          f.store.engine.selection=[id];f.scene.focusSelection()
          try assertVisible(f,points(f,[id]))
          let fitted=f.scene.camera
          f.scene.focusSelection();XCTAssertEqual(f.scene.camera,fitted,"Repeat Focus must not accumulate target drift")
        }}
      }
    }
    XCTAssertEqual(f.scene.geometryBuilds,builds)
    XCTAssertEqual(f.store.project?.objects,source.objects);XCTAssertEqual(f.store.project?.history,source.history)
    XCTAssertEqual(f.store.engine.undoStack.count,undo)
  }
  func testShortNavigatorLeavesUsefulSpaceBelowInsteadOfShrinkingToMiddleStrip()throws {
    let f=try fixture();f.window.setContentSize(.init(width:620,height:820))
    f.scene.navigationOcclusions=occlusions(f.view.bounds.size,navigator:true,inspector:true)
    f.store.engine.selection=[f.ids[0]];f.scene.focusSelection()
    let rect=try XCTUnwrap(f.scene.navigationFramingRect),bounds=try assertVisible(f,points(f,[f.ids[0]]))
    XCTAssertGreaterThan(rect.width,220)
    XCTAssertGreaterThanOrEqual(rect.minY,384)
    XCTAssertGreaterThan(max(bounds.width/rect.width,bounds.height/rect.height),0.75,"Focus must fill the useful area")
  }
  func testFitAndNamedViewsFrameWholeProjectWhileResizeAndOverlayChangesKeepSavedPose()throws {
    let f=try fixture(),before=try XCTUnwrap(f.store.project),builds=f.scene.geometryBuilds
    f.scene.navigationOcclusions=[];f.scene.fitAll()
    let original=f.scene.camera
    f.scene.navigationOcclusions=occlusions(f.view.bounds.size,navigator:true,inspector:true)
    XCTAssertEqual(f.scene.camera,original,"Showing controls must not refit the saved view")
    f.window.setContentSize(.init(width:620,height:820));f.scene.viewportResized(f.view)
    var resized=f.scene.camera,expected=original;resized.viewportAspect=nil;expected.viewportAspect=nil
    XCTAssertEqual(resized,expected)
    f.scene.navigationOcclusions=occlusions(f.view.bounds.size,navigator:true,inspector:true)
    f.scene.fitAll();try assertVisible(f,points(f,f.ids))
    for name in ["front","overhead","perspective"] {
      f.store.isolated=[f.ids[0]]
      f.scene.preset(name);XCTAssertTrue(f.store.isolated.isEmpty)
      try assertVisible(f,points(f,f.ids))
    }
    XCTAssertEqual(f.scene.geometryBuilds,builds)
    XCTAssertEqual(f.store.project?.objects,before.objects);XCTAssertEqual(f.store.project?.history,before.history)
  }
  func testFlatBoundsAndDepthHeavyPerspectiveUseActualProjectionWithoutChangingCoreContract()throws {
    let f=try fixture();f.scene.navigationOcclusions=occlusions(f.view.bounds.size,navigator:true,inspector:true)
    for projection in ["perspective","orthographic"] {
      var camera=CameraState();camera.projection=projection
      for world in [[Vector3(-3,0,-1),.init(3,0,-1),.init(3,0,1),.init(-3,0,1)],
        [.init(-2,-1,-8),.init(2,1,8),.init(-2,1,8),.init(2,-1,-8)]] {
        let result=try XCTUnwrap(TableViewportFraming.fitted(camera,points:world,viewport:f.view.bounds.size,occlusions:f.scene.navigationOcclusions!))
        f.scene.camera=result.camera;f.scene.updateCamera()
        var bounds=CGRect.null
        for p in world {let q=f.view.projectPoint(.init(p.x,p.y,p.z));XCTAssertTrue(q.x.isFinite && q.y.isFinite);bounds=bounds.union(.init(x:q.x,y:f.view.bounds.height-q.y,width:0,height:0))}
        XCTAssertTrue(result.visibleRect.insetBy(dx:-0.5,dy:-0.5).contains(bounds))
        XCTAssertEqual(bounds.midX,result.visibleRect.midX,accuracy:0.5)
        XCTAssertEqual(bounds.midY,result.visibleRect.midY,accuracy:0.5)
      }
    }
    let core=CameraFraming.fitted(CameraState(),points:[.init(-1,-1,-1),.init(1,1,1)],aspect:1)
    XCTAssertEqual(core.target,.init(0,0,0),"The shared Core framing contract still centers its orbit pivot")
  }
}

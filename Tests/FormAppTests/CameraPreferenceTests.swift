import AppKit
import FormGeometry
import simd
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

/// Real AppKit event handlers and the actual renderer camera, without sending
/// operating-system input or touching the user's library.
@MainActor final class CameraPreferenceTests: XCTestCase {
  @MainActor private final class ViewFixture {
    let window: NSWindow
    let view: TableSceneView
    let controller: TableSceneController
    init(store: StudioStore? = nil) {
      _ = NSApplication.shared
      window = NSWindow(contentRect: NSRect(x:0,y:0,width:1200,height:800),
        styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed = false
      controller = TableSceneController(store:store)
      view = TableSceneView(frame:NSRect(x:0,y:0,width:1200,height:800))
      view.controller = controller; controller.view = view
        window.contentView = view
      window.makeFirstResponder(view)
      if let store { store.scene = controller; store.synchronizeScene() }
      controller.updateCamera()
    }
    func close() { window.close() }
    func mouse(_ type:NSEvent.EventType,_ point:NSPoint,
      flags:NSEvent.ModifierFlags = [],count:Int = 1) -> NSEvent {
      NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:flags,
        timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,
        context:nil,eventNumber:1,clickCount:count,pressure:type == .leftMouseUp ? 0 : 1)!
    }
    func drag(_ dx:CGFloat,_ dy:CGFloat,from:NSPoint = NSPoint(x:200,y:400),
      flags:NSEvent.ModifierFlags = []) {
      let end = NSPoint(x:from.x+dx,y:from.y+dy)
      view.mouseDown(with:mouse(.leftMouseDown,from,flags:flags))
      view.mouseDragged(with:mouse(.leftMouseDragged,end,flags:flags))
      view.mouseUp(with:mouse(.leftMouseUp,end,flags:flags))
    }
    func screen(_ point:Vector3) -> NSPoint {
      let p = controller.cameraNode.convertPosition(.init(point.x,point.y,point.z),from:nil)
      let m = controller.cameraNode.camera!.projectionTransform
      let w = m.m14*p.x+m.m24*p.y+m.m34*p.z+m.m44
      let x = (m.m11*p.x+m.m21*p.y+m.m31*p.z+m.m41)/w
      let y = (m.m12*p.x+m.m22*p.y+m.m32*p.z+m.m42)/w
      let aspect = view.bounds.width/view.bounds.height
      return NSPoint(x:(x/aspect+1)*view.bounds.width/2,y:(y+1)*view.bounds.height/2)
    }
  }
  private func assertAxesEqual(_ a:CameraState,_ b:CameraState,
    accuracy:Double = 1e-9,file:StaticString = #filePath,line:UInt = #line) {
    let x = CameraNavigation.basis(a),y = CameraNavigation.basis(b)
    for (p,q) in [(x.right,y.right),(x.up,y.up),(x.outward,y.outward)] {
      XCTAssertEqual(p.x,q.x,accuracy:accuracy,file:file,line:line)
      XCTAssertEqual(p.y,q.y,accuracy:accuracy,file:file,line:line)
      XCTAssertEqual(p.z,q.z,accuracy:accuracy,file:file,line:line)
    }
  }
  private func scene(_ size:Double = 100) throws -> (ViewFixture,StudioStore,URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ProjectRepository(root:root)
    var project = Project(name:"Native camera regression")
    var left = try project.makeObject(recipeID:"box")
    left.parameters = ["width":size,"height":size*0.7,"depth":size*0.8,"corner":0]
    left.position = .init(-size*1.8,0,size*0.4)
    var right = left; right.id = UUID(); right.name = "Right box"
    right.position = .init(size*2,0,-size*0.6)
    project.objects = [left,right]
    try repository.save(project)
    let store = StudioStore(repository:repository,seedLibrary:false)
    try store.engine.open(project.id)
    store.showingHome = false
    return (ViewFixture(store:store),store,root)
  }
  func testStudioPointerOrbitPanAndZoomRetainPresentationUntilExplicitTableSwitch() throws {
    let (f,store,root)=try scene()
    defer {f.close();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    store.showSurface(.studio)
    store.studioPreset="Graphite"
    store.synchronizeScene()
    let before=try XCTUnwrap(store.project)
    let builds=f.controller.diagnostics["geometry_builds"] as? Int
    func verifyStudio() {
      XCTAssertEqual(store.mode,.studio)
      XCTAssertEqual(store.studioPreset,"Graphite")
      store.synchronizeScene()
      XCTAssertEqual(f.controller.scene.background.contents as? NSColor,NSColor(hex:"#3E4345"))
    }
    f.drag(30,0)
    verifyStudio()
    f.drag(0,-20,flags:.shift)
    verifyStudio()
    let wheel=try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:2,wheel2:0,wheel3:0))
    f.view.scrollWheel(with:try XCTUnwrap(NSEvent(cgEvent:wheel)))
    verifyStudio()
    XCTAssertNotEqual(store.project?.camera,before.camera)
    XCTAssertEqual(store.project?.objects,before.objects)
    XCTAssertEqual(store.project?.history,before.history)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertEqual(f.controller.diagnostics["geometry_builds"] as? Int,builds)
    store.showSurface(.table)
    XCTAssertEqual(store.mode,.table)
  }

  private func assertProjectVisible(_ f:ViewFixture,
    file:StaticString = #filePath,line:UInt = #line) {
    let width = f.view.bounds.width,height = f.view.bounds.height
    let rightEdge: CGFloat
    if f.controller.store?.mode == .studio { rightEdge = width-264-48 }
    else { rightEdge = f.controller.store?.primary == nil ? width : width-ObjectInspector.width-48 }
    for node in f.controller.objectRoot.childNodes {
      XCTAssertFalse(node.isHidden,file:file,line:line)
      let b = node.boundingBox
      for x in [b.min.x,b.max.x] { for y in [b.min.y,b.max.y] { for z in [b.min.z,b.max.z] {
        let world = node.convertPosition(.init(x,y,z),to:nil)
        let point = f.screen(.init(Double(world.x),Double(world.y),Double(world.z)))
        XCTAssertGreaterThanOrEqual(point.x,-0.01,file:file,line:line)
        XCTAssertLessThanOrEqual(point.x,rightEdge+0.01,file:file,line:line)
        XCTAssertGreaterThanOrEqual(point.y,79.99,file:file,line:line)
        XCTAssertLessThanOrEqual(point.y,height-79.99,file:file,line:line)
      } } }
    }
  }

  func testFirstMouseIsAcceptedAndFreshCardinalAndDiagonalDragsFollowThePointer() {
    let f = ViewFixture(); defer { f.close() }
    XCTAssertTrue(f.view.acceptsFirstMouse(for:nil))
    for (dx,dy) in [(80.0,0.0),(-80,0),(0,80),(0,-80),(60,45),(-60,-45)] {
      f.controller.camera = CameraState(); f.controller.updateCamera()
      let before = f.controller.camera,axis = CameraNavigation.basis(before).outward
      let feature = Vector3(before.target.x+axis.x,before.target.y+axis.y,before.target.z+axis.z)
      let start = f.screen(feature)
      f.drag(dx,dy)
      let end = f.screen(feature)
      if dx != 0 { XCTAssertGreaterThan((end.x-start.x)*dx,0) }
      if dy != 0 { XCTAssertGreaterThan((end.y-start.y)*dy,0) }
      XCTAssertEqual(f.controller.camera.target,before.target)
      XCTAssertEqual(f.controller.camera.distance,before.distance)
      f.drag(-dx,-dy)
      assertAxesEqual(f.controller.camera,before)
    }
  }
  func testNativeHorizontalDragsKeepPitchAndHorizonLevelAcrossRepeatedFullTurns() {
    let f = ViewFixture(); defer { f.close() }
    for pitch in [-1.2, 0.0, 0.7, 1.2] {
      f.controller.camera = CameraState(); f.controller.camera.elevation = pitch
      f.controller.updateCamera()
      let start = f.controller.camera
      for dx in [53.333333333333336, -53.333333333333336] {
        for _ in 0..<120 {
          let before = f.controller.camera
          f.drag(dx, 0)
          XCTAssertEqual(f.controller.camera.elevation, pitch, accuracy: 1e-10)
          XCTAssertNotEqual(CameraNavigation.basis(f.controller.camera).right,
            CameraNavigation.basis(before).right)
          XCTAssertEqual(Double(f.controller.cameraNode.simdWorldRight.y), 0, accuracy: 1e-7)
          XCTAssertGreaterThan(Double(f.controller.cameraNode.simdWorldUp.y), 0)
        }
      }
      assertAxesEqual(f.controller.camera, start, accuracy: 1e-8)
      XCTAssertEqual(f.controller.camera.target, start.target)
      XCTAssertEqual(f.controller.camera.distance, start.distance)
    }
  }
  func testNativeVerticalEndpointsStayUprightAndReverseOnTheFirstMovement() {
    let f = ViewFixture(); defer { f.close() }
    for dy in [80.0, -80.0] {
      f.controller.camera = CameraState(); f.controller.updateCamera()
      let start = f.controller.camera
      for _ in 0..<40 { f.drag(0, dy) }
      let endpoint = f.controller.camera
      XCTAssertEqual(endpoint.elevation, dy > 0 ? -.pi / 2 : .pi / 2, accuracy: 1e-12)
      XCTAssertEqual(Double(f.controller.cameraNode.simdWorldRight.y), 0, accuracy: 1e-7)
      f.drag(0, dy)
      assertAxesEqual(f.controller.camera, endpoint)
      f.drag(80, 0)
      XCTAssertNotEqual(CameraNavigation.basis(f.controller.camera).right,
        CameraNavigation.basis(endpoint).right)
      f.drag(0, dy > 0 ? -4 : 4)
      XCTAssertLessThan(abs(f.controller.camera.elevation), abs(endpoint.elevation))
      XCTAssertGreaterThan(Double(f.controller.cameraNode.simdWorldUp.y), 0)
      XCTAssertEqual(f.controller.camera.target, start.target)
      XCTAssertEqual(f.controller.camera.distance, start.distance)
    }
  }
  func testMostlyHorizontalNativeInputWithSmallVerticalNoiseNeverBanksTheCamera() {
    let f = ViewFixture(); defer { f.close() }
    let start = f.controller.camera
    for step in 0..<160 {
      f.drag(50, step % 2 == 0 ? 0.25 : -0.25)
      XCTAssertEqual(Double(f.controller.cameraNode.simdWorldRight.y), 0, accuracy: 1e-7)
      XCTAssertGreaterThan(Double(f.controller.cameraNode.simdWorldUp.y), 0)
    }
    XCTAssertEqual(f.controller.camera.elevation, start.elevation, accuracy: 1e-10)
    XCTAssertEqual(f.controller.camera.target, start.target)
    XCTAssertEqual(f.controller.camera.distance, start.distance)
  }
  func testShiftDragsPanExactlyInEveryScreenDirectionWithoutRotating() {
    let f = ViewFixture(); defer { f.close() }
    for (dx,dy) in [(83.0,0.0),(-83,0),(0,51),(0,-51),(83,-51)] {
      let before = f.controller.camera,point = before.target
      let start = f.screen(point)
      f.drag(dx,dy,flags:.shift)
      let end = f.screen(point)
      XCTAssertEqual(end.x-start.x,dx,accuracy:0.001)
      XCTAssertEqual(end.y-start.y,dy,accuracy:0.001)
      assertAxesEqual(f.controller.camera,before)
      XCTAssertEqual(f.controller.camera.distance,before.distance)
      f.drag(-dx,-dy,flags:.shift)
      XCTAssertEqual(f.controller.camera.target.x,before.target.x,accuracy:1e-10)
      XCTAssertEqual(f.controller.camera.target.y,before.target.y,accuracy:1e-10)
      XCTAssertEqual(f.controller.camera.target.z,before.target.z,accuracy:1e-10)
    }
  }
  func testPressingAndReleasingShiftDuringOneDragSwitchesOnlyTheCurrentMovement() {
    let f = ViewFixture(); defer { f.close() }
    f.view.mouseDown(with:f.mouse(.leftMouseDown,.init(x:200,y:300)))
    f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:240,y:330)))
    let orbited = f.controller.camera
    let feature = orbited.target,start = f.screen(feature)
    f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:280,y:350),flags:.shift))
    let panned = f.controller.camera,end = f.screen(feature)
    assertAxesEqual(panned,orbited)
    XCTAssertEqual(end.x-start.x,40,accuracy:0.001)
    XCTAssertEqual(end.y-start.y,20,accuracy:0.001)
    f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:300,y:370)))
    XCTAssertEqual(f.controller.camera.target,panned.target)
    XCTAssertNotEqual(CameraNavigation.basis(f.controller.camera).outward,CameraNavigation.basis(panned).outward)
    f.view.mouseUp(with:f.mouse(.leftMouseUp,.init(x:300,y:370)))
  }
  func testOptionAndSpaceDoNotIntroducePanAliases() {
    let f = ViewFixture(); defer { f.close() }
    let before = f.controller.camera
    f.drag(60,30,flags:.option)
    XCTAssertEqual(f.controller.camera.target,before.target)
    XCTAssertNotEqual(CameraNavigation.basis(f.controller.camera).outward,CameraNavigation.basis(before).outward)
    f.controller.camera = before; f.controller.updateCamera()
    let space = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,
      windowNumber:f.window.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",
      isARepeat:false,keyCode:49)!
    f.view.keyDown(with:space)
    f.drag(60,30)
    XCTAssertEqual(f.controller.camera.target,before.target)
    XCTAssertNotEqual(CameraNavigation.basis(f.controller.camera).outward,CameraNavigation.basis(before).outward)
  }
  func testLateAndCancelledDragsNeverReuseAPreviousMouseAnchor() {
    let f = ViewFixture(); defer { f.close() }
    let before = f.controller.camera
    f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:1000,y:20)))
    XCTAssertEqual(f.controller.camera,before)
    f.drag(40,30)
    let ended = f.controller.camera
    f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:1000,y:20)))
    XCTAssertEqual(f.controller.camera,ended)
    f.view.mouseDown(with:f.mouse(.leftMouseDown,.init(x:200,y:300)))
    f.view.cancelPointerInteraction()
    f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:1000,y:20)))
    f.view.mouseUp(with:f.mouse(.leftMouseUp,.init(x:1000,y:20)))
    XCTAssertEqual(f.controller.camera,ended)
  }
  func testNewMouseDownResetsTheAnchorAndThresholdDoesNotLoseMovement() {
    let f = ViewFixture(); defer { f.close() }
    let before = f.controller.camera
    f.drag(40,30,from:.init(x:10,y:10))
    let expected = f.controller.camera
    f.controller.camera = before; f.controller.updateCamera()
    f.drag(40,30,from:.init(x:1000,y:700))
    assertAxesEqual(f.controller.camera,expected)
    f.controller.camera = before; f.controller.updateCamera()
    f.view.mouseDown(with:f.mouse(.leftMouseDown,.init(x:200,y:300)))
    f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:202,y:300)))
    XCTAssertEqual(f.controller.camera,before)
    f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:204,y:300)))
    f.view.mouseUp(with:f.mouse(.leftMouseUp,.init(x:204,y:300)))
    let threshold = f.controller.camera
    f.controller.camera = before; f.controller.updateCamera(); f.drag(4,0)
    assertAxesEqual(f.controller.camera,threshold)
  }
  func testResizeAndResponderLossCancelInFlightDragsWithoutMovingTheCamera() {
    let f = ViewFixture(); defer { f.close() }
    for resize in [false,true] {
      f.view.mouseDown(with:f.mouse(.leftMouseDown,.init(x:200,y:300)))
      let before = f.controller.camera
      if resize { f.view.setFrameSize(.init(width:1100,height:700)) }
      else { _ = f.view.resignFirstResponder() }
      f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:500,y:600)))
      assertAxesEqual(f.controller.camera,before)
      XCTAssertEqual(f.controller.camera.target,before.target)
      XCTAssertEqual(f.controller.camera.distance,before.distance)
    }
  }
  func testScrollWheelZoomPreservesOrientationAndPivotAndReverses() throws {
    let f = ViewFixture(); defer { f.close() }
    let before = f.controller.camera
    for amount in [5,-5] {
      let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,
        wheel1:Int32(amount),wheel2:0,wheel3:0))
      let event = try XCTUnwrap(NSEvent(cgEvent:cg))
      f.view.scrollWheel(with:event)
      if amount > 0 { XCTAssertLessThan(f.controller.camera.distance,before.distance) }
      assertAxesEqual(f.controller.camera,before)
      XCTAssertEqual(f.controller.camera.target,before.target)
    }
    XCTAssertEqual(f.controller.camera.distance,before.distance,accuracy:1e-10)
  }
  func testEveryNamedViewFramesTheWholeProjectAfterPanZoomOrbitSelectionAndIsolation() throws {
    for size in [10.0,1000.0] {
      let (f,store,root) = try scene(size); defer { f.close(); try? FileManager.default.removeItem(at:root) }
      let objects = store.project!.objects,history = store.project!.history
      store.select(objects[0].id)
      let builds = f.controller.geometryBuilds
      for name in ["perspective","overhead","front"] {
        store.isolated = [objects[0].id]; store.synchronizeScene()
        f.controller.pan(dx:900,dy:-500); f.controller.zoom(-180)
        f.controller.orbit(dx:300,dy:900)
        f.controller.preset(name)
        XCTAssertEqual(store.project!.camera,f.controller.camera)
        let axes = CameraNavigation.basis(f.controller.camera)
        let node = f.controller.cameraNode
        for (actual,expected) in [(node.simdWorldRight,axes.right),(node.simdWorldUp,axes.up)] {
          XCTAssertEqual(Double(actual.x),expected.x,accuracy:0.00001)
          XCTAssertEqual(Double(actual.y),expected.y,accuracy:0.00001)
          XCTAssertEqual(Double(actual.z),expected.z,accuracy:0.00001)
        }
        XCTAssertTrue(store.isolated.isEmpty)
        XCTAssertEqual(f.controller.camera.projection,name == "perspective" ? "perspective" : "orthographic")
        XCTAssertNil(f.controller.camera.orientation)
        assertProjectVisible(f)
        let expected = f.controller.camera
        f.controller.pan(dx:-1200,dy:700); f.controller.zoom(350)
        f.controller.orbit(dx:-600,dy:-1100); f.controller.preset(name)
        XCTAssertEqual(f.controller.camera,expected)
        XCTAssertTrue(f.controller.renderer!.camera.worldFromCameraMM == f.controller.cameraPayload().worldFromCameraMM)
        XCTAssertEqual(f.controller.renderer!.camera.projection,f.controller.cameraPayload().projection)
      }
      XCTAssertEqual(f.controller.geometryBuilds,builds)
      XCTAssertEqual(store.project!.objects,objects)
      XCTAssertEqual(store.project!.history,history)
    }
  }
  func testNamedViewAppliesItsOrientationWhenTheFitDistanceDoesNotChange() throws {
    let (f,store,root) = try scene()
    defer { f.close(); try? FileManager.default.removeItem(at:root) }
    f.controller.preset("overhead")
    let topDistance = f.controller.camera.distance
    f.controller.preset("front")
    // This wide scene needs the same fit distance from either direction.
    XCTAssertEqual(f.controller.camera.distance,topDistance,accuracy:1e-10)
    XCTAssertEqual(store.project!.camera,f.controller.camera)
    XCTAssertEqual(store.project!.camera.elevation,0)
    XCTAssertEqual(Double(f.controller.cameraNode.simdWorldUp.y),1,accuracy:1e-6)
    XCTAssertEqual(Double(f.controller.cameraNode.simdWorldRight.x),1,accuracy:1e-6)
    XCTAssertEqual(Double(f.controller.cameraNode.position.y),f.controller.camera.target.y,accuracy:1e-6)
  }
  func testFocusUsesSelectedCenterAndTheNextOrbitKeepsItsPivotWhileFitRecoversAll() throws {
    let (f,store,root) = try scene(); defer { f.close(); try? FileManager.default.removeItem(at:root) }
    store.select(store.project!.objects[0].id); store.synchronizeScene()
    let objects = store.project!.objects,history = store.project!.history
    let builds = f.controller.geometryBuilds
    f.controller.focusSelection()
    let focused = f.controller.camera
    XCTAssertEqual(focused.target.x,objects[0].position.x/100,accuracy:0.001)
    XCTAssertEqual(focused.target.z,objects[0].position.z/100,accuracy:0.001)
    let center = f.screen(focused.target)
    XCTAssertEqual(center.x,600,accuracy:0.001); XCTAssertEqual(center.y,400,accuracy:0.001)
    f.drag(80,-60)
    XCTAssertEqual(f.controller.camera.target,focused.target)
    XCTAssertEqual(f.controller.camera.distance,focused.distance)
    f.drag(70,40,flags:.shift)
    f.controller.fitAll()
    assertProjectVisible(f)
    XCTAssertTrue(f.controller.renderer!.camera.worldFromCameraMM == f.controller.cameraPayload().worldFromCameraMM)
    XCTAssertEqual(f.controller.geometryBuilds,builds)
    XCTAssertEqual(store.project!.objects,objects)
    XCTAssertEqual(store.project!.history,history)
    XCTAssertTrue(f.controller.renderer!.viewport.isPaused);XCTAssertTrue(f.controller.renderer!.viewport.enableSetNeedsDisplay)
  }
  func testNamedProjectViewsKeepTheSamePivotAcrossSelectionsIsolationAndStudio() throws {
    let (f,store,root) = try scene(); defer { f.close(); try? FileManager.default.removeItem(at:root) }
    let objects = store.project!.objects,history = store.project!.history
    let selections:[Set<UUID>] = [[],[objects[0].id],[objects[1].id],Set(objects.map(\.id))]
    let builds = f.controller.geometryBuilds
    for mode in [WorkspaceMode.table,.studio] {
      store.mode = mode
      for name in ["perspective","overhead","front"] {
        store.engine.selection = []; store.isolated = []; store.synchronizeScene()
        f.controller.preset(name)
        XCTAssertEqual(store.project!.camera,f.controller.camera)
        let axes = CameraNavigation.basis(f.controller.camera)
        let node = f.controller.cameraNode
        for (actual,expected) in [(node.simdWorldRight,axes.right),(node.simdWorldUp,axes.up)] {
          XCTAssertEqual(Double(actual.x),expected.x,accuracy:0.00001)
          XCTAssertEqual(Double(actual.y),expected.y,accuracy:0.00001)
          XCTAssertEqual(Double(actual.z),expected.z,accuracy:0.00001)
        }
        let pivot = f.controller.camera.target
        for selection in selections {
          store.engine.selection = selection
          store.isolated = selection
          store.synchronizeScene()
          f.controller.pan(dx:150,dy:-90); f.controller.orbit(dx:120,dy:280)
          f.controller.preset(name)
        XCTAssertEqual(store.project!.camera,f.controller.camera)
        let axes = CameraNavigation.basis(f.controller.camera)
        let node = f.controller.cameraNode
        for (actual,expected) in [(node.simdWorldRight,axes.right),(node.simdWorldUp,axes.up)] {
          XCTAssertEqual(Double(actual.x),expected.x,accuracy:0.00001)
          XCTAssertEqual(Double(actual.y),expected.y,accuracy:0.00001)
          XCTAssertEqual(Double(actual.z),expected.z,accuracy:0.00001)
        }
          // Selection outlines are UI attachments, never part of the project's
          // physical bounds. Their changing size must not shift the orbit pivot.
          XCTAssertEqual(f.controller.camera.target,pivot)
          XCTAssertTrue(store.isolated.isEmpty)
          assertProjectVisible(f)
        }
      }
    }
    XCTAssertEqual(f.controller.geometryBuilds,builds)
    XCTAssertEqual(store.project!.objects,objects)
    XCTAssertEqual(store.project!.history,history)
  }
  func testPresetAndFitCancelAnAlreadyStartedMouseDrag() throws {
    let (f,_,root) = try scene(); defer { f.close(); try? FileManager.default.removeItem(at:root) }
    for named in [true,false] {
      f.view.mouseDown(with:f.mouse(.leftMouseDown,.init(x:200,y:300)))
      if named { f.controller.preset("overhead") } else { f.controller.fitAll() }
      let recovered = f.controller.camera
      f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:600,y:700)))
      f.view.mouseUp(with:f.mouse(.leftMouseUp,.init(x:600,y:700)))
      XCTAssertEqual(f.controller.camera,recovered)
    }
  }
  func testReopeningASavedBankedViewLevelsItsHorizonWithoutMovingItsComposition() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ProjectRepository(root: root)
    var saved = Project(name: "Saved banked view")
    saved.objects = [try saved.makeObject(recipeID: "box")]
    saved.camera.viewportAspect = 1.5
    saved.camera.target = .init(4.5, 2, -7)
    saved.camera.distance = 8.5
    let raw = simd_quatd(angle: 0.8, axis: SIMD3(0, 1, 0))
      * simd_quatd(angle: -0.45, axis: SIMD3(1, 0, 0))
      * simd_quatd(angle: 1.1, axis: SIMD3(0, 0, 1))
    let q = raw.vector
    saved.camera.orientation = CameraOrientation(x: q.x, y: q.y, z: q.z, w: q.w)
    saved.camera.azimuth = 0.8; saved.camera.elevation = 0.45
    saved.schemaVersion = saved.minimumSchemaVersion
    try repository.save(saved)
    let before = try repository.load(saved.id)
    // Recreate the store/controller from disk. Reopening a live store here would
    // correctly flush its old in-memory project over the externally saved fixture.
    let store = StudioStore(repository: repository, seedLibrary: false)
    store.openProject(saved.id)
    let f = ViewFixture(store: store)
    defer { f.close(); try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(f.controller.camera.target, before.camera.target)
    XCTAssertEqual(f.controller.camera.distance, before.camera.distance)
    let expected = raw.act(SIMD3<Double>(0, 0, 1))
    let axes = CameraNavigation.basis(f.controller.camera)
    XCTAssertEqual(axes.outward.x, expected.x, accuracy: 1e-12)
    XCTAssertEqual(axes.outward.y, expected.y, accuracy: 1e-12)
    XCTAssertEqual(axes.outward.z, expected.z, accuracy: 1e-12)
    XCTAssertEqual(Double(f.controller.cameraNode.simdWorldRight.y), 0, accuracy: 1e-7)
    XCTAssertGreaterThan(Double(f.controller.cameraNode.simdWorldUp.y), 0)
    f.drag(60, 0)
    XCTAssertEqual(f.controller.camera.elevation, before.camera.elevation, accuracy: 1e-10)
    XCTAssertEqual(Double(f.controller.cameraNode.simdWorldRight.y), 0, accuracy: 1e-7)
    XCTAssertEqual(f.controller.camera.target, before.camera.target)
    XCTAssertEqual(f.controller.camera.distance, before.camera.distance)
    XCTAssertEqual(store.project!.objects, before.objects)
    XCTAssertEqual(store.project!.history, before.history)
  }

  func testOpeningAnotherProjectDuringADragRejectsLateEventsAndPreservesItsCamera() throws {
    let (f,store,root) = try scene(); defer { f.close(); try? FileManager.default.removeItem(at:root) }
    let firstID = store.project!.id
    var next = Project(name:"Different saved camera")
    var object = try next.makeObject(recipeID:"cylinder")
    object.position = .init(450,25,-700)
    next.objects = [object]
    next.camera = CameraNavigation.orbited(next.camera,dx:350,dy:90,viewportHeight:800)
    next.camera.target = .init(4.5,2,-7)
    next.camera.distance = 8.5
    next.camera.projection = "orthographic"
    next.camera.viewportAspect = 1.5
    next.schemaVersion = next.minimumSchemaVersion
    try store.repository.save(next)
    next = try store.repository.load(next.id)
    for synchronize in [false,true] {
      try store.engine.open(firstID); store.synchronizeScene()
      f.view.mouseDown(with:f.mouse(.leftMouseDown,.init(x:200,y:300)))
      f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:240,y:330)))
      try store.engine.open(next.id)
      if synchronize { store.synchronizeScene() } else { f.controller.resetCamera() }
      let opened = store.project!
      XCTAssertEqual(opened,next)
      XCTAssertEqual(f.controller.camera,opened.camera)
      // These belong to the previous project and must never alter the newly
      // opened composition, either as orbit or as a modifier-changed pan.
      f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:700,y:600)))
      f.view.mouseDragged(with:f.mouse(.leftMouseDragged,.init(x:900,y:100),flags:.shift))
      f.view.mouseUp(with:f.mouse(.leftMouseUp,.init(x:900,y:100),flags:.shift))
      XCTAssertEqual(f.controller.camera,opened.camera)
      XCTAssertEqual(store.project,opened)
      XCTAssertEqual(try store.repository.load(next.id),next)
      if synchronize {
        XCTAssertEqual(f.controller.objectRoot.childNodes.count,1)
        f.drag(40,30)
        XCTAssertNotEqual(CameraNavigation.basis(f.controller.camera).outward,
          CameraNavigation.basis(opened.camera).outward)
        XCTAssertEqual(f.controller.camera.target,opened.camera.target)
        XCTAssertEqual(store.project!.objects,opened.objects)
        XCTAssertEqual(store.project!.history,opened.history)
      }
    }
  }
}

import AppKit
import SceneKit
import Metal
import XCTest
@testable import FormCore
@testable import FormGraphics
@testable import FormApp

@MainActor final class ClothIntegrationTests:XCTestCase {
  private func fixture()throws -> (StudioStore,URL,UUID) {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("cloth31-\(UUID().uuidString)")
    let repository=try ProjectRepository(root:root),store=StudioStore(repository:repository,seedLibrary:false)
    var project=Project(name:"Cloth integration")
    let object=try project.makeObject(recipeID:"clothPanel",parameters:["resolution":6],materialID:"linen")
    project.objects=[object];try repository.save(project);try store.engine.open(project.id);store.showingHome=false
    store.synchronizeScene();return(store,root,object.id)
  }
  private func call(_ store:StudioStore,_ command:String,_ id:UUID,_ extra:[String:Any] = [:])throws -> [String:Any] {
    var args=extra;args["command"]=command;args["object_id"]=id.uuidString
    let value=try store.bridgeClothCall(args)
    return try XCTUnwrap(value as? [String:Any])
  }
  private func node(_ store:StudioStore,_ id:UUID)throws -> SCNNode {try XCTUnwrap(store.scene?.objectRoot.childNode(withName:"object:\(id.uuidString)",recursively:false))}
  func testRuntimeBridgeLeavesDraftCommitNotificationsHistoryFilesAndCameraUntouched()throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    let before=store.project!,undo=store.engine.undoStack,redo=store.engine.redoStack,revision=store.revision,camera=store.scene!.camera,builds=store.scene!.geometryBuilds
    let manifest=store.repository.url(for:before.id).appendingPathComponent("Manifest.json"),bytes=try Data(contentsOf:manifest)
    var fieldCommits=0
    let observer=NotificationCenter.default.addObserver(forName:.formCommitArtworkFields,object:nil,queue:.main) {_ in fieldCommits+=1};defer {NotificationCenter.default.removeObserver(observer)}
    _ = try call(store,"get",id);_ = try call(store,"step",id,["frames":4]);_ = try call(store,"snapshot",id);_ = try call(store,"stop",id)
    XCTAssertEqual(store.cloth.preview.frame?.diagnostics.completedFrames,4)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack,undo);XCTAssertEqual(store.engine.redoStack,redo)
    XCTAssertEqual(store.revision,revision);XCTAssertFalse(store.saving);XCTAssertEqual(fieldCommits,0);XCTAssertEqual(try Data(contentsOf:manifest),bytes)
    XCTAssertEqual(store.scene!.camera,camera);XCTAssertEqual(store.scene!.geometryBuilds,builds)
    _ = try call(store,"reset",id);XCTAssertEqual(store.cloth.preview.frame?.diagnostics.completedFrames,0)
    XCTAssertEqual(store.project,before);XCTAssertEqual(fieldCommits,0);XCTAssertEqual(store.revision,revision)
  }
  func testSourceSettingsAreUndoableAndReopenStoresOnlyInitialDefinition()throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    let original=store.project!,history=original.history.count
    _ = try call(store,"configure",id,["settings":["friction":0.61]])
    XCTAssertEqual(store.project!.objects[0].cloth!.settings.friction,0.61);XCTAssertEqual(store.project!.history.count,history+1)
    _ = try call(store,"step",id,["frames":4]);let moving=try XCTUnwrap(store.cloth.preview.frame)
    XCTAssertEqual(moving.diagnostics.completedFrames,4)
    store.undo();XCTAssertEqual(store.project,original);XCTAssertEqual(store.cloth.preview.frame?.diagnostics.completedFrames,0)
    store.redo();XCTAssertEqual(store.project!.objects[0].cloth!.settings.friction,0.61);XCTAssertEqual(store.cloth.preview.frame?.diagnostics.completedFrames,0)
    store.save();let loaded=try store.repository.load(original.id)
    XCTAssertEqual(loaded.schemaVersion,31);XCTAssertEqual(loaded.objects[0].cloth,store.project!.objects[0].cloth)
    let next=StudioStore(repository:store.repository,seedLibrary:false);try next.engine.open(original.id);next.showingHome=false
    _ = try call(next,"get",id);XCTAssertNil(next.cloth.preview.frame)
    _ = try call(next,"step",id);XCTAssertEqual(next.cloth.preview.frame?.diagnostics.completedFrames,1)
    let objectFile=store.repository.url(for:original.id).appendingPathComponent("Objects/\(id.uuidString).json")
    // Object files are content-addressed; inspect the package bytes rather than assume a name.
    let objects=try FileManager.default.contentsOfDirectory(at:objectFile.deletingLastPathComponent(),includingPropertiesForKeys:nil)
    let content=try objects.map {try String(contentsOf:$0,encoding:.utf8)}.joined()
    XCTAssertFalse(content.contains("completedFrames"));XCTAssertFalse(content.contains("velocitiesMPerSecond"));next.cloth.clear()
  }
  func testActualSurfaceBoundsAndAttachedDecorationFollowMotionAndTemplateResize()throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    var decoration=try store.project!.makeObject(recipeID:"textileLabel",parameters:["width":40,"depth":20]);decoration.position.x=400
    try store.engine.edit("Added label") {$0.objects.append(decoration)};store.changed(save:false)
    _ = try call(store,"attach",decoration.id,["surface_object_id":id.uuidString,"u":0.72,"v":0.6,"offset_mm":2])
    store.synchronizeScene();let label=try node(store,decoration.id),initial=label.position,oldBounds=try XCTUnwrap(store.scene!.clothBounds(for:id)),camera=store.scene!.camera
    _ = try call(store,"step",id,["frames":10])
    XCTAssertGreaterThan(abs(label.position.y-initial.y),0.01)
    let inspection=try call(store,"get",decoration.id),placementData=try XCTUnwrap(inspection["placement"] as? [String:Any]),position=try XCTUnwrap(placementData["positionMm"] as? [String:Double])
    XCTAssertEqual(Double(label.position.y)*100,position["y"]!,accuracy:1e-3)
    let bounds=try XCTUnwrap(store.scene!.clothBounds(for:id));XCTAssertLessThan(bounds.max.y,oldBounds.max.y)
    XCTAssertEqual(store.scene!.camera,camera)
    let attachment=store.project!.objects.first {$0.id==decoration.id}!.clothAttachment!,oldMesh=store.project!.objects[0].cloth!.mesh,uv=try oldMesh.materialPoint(attachment.anchor)
    _ = try store.engine.call("form_update_object",arguments:["object_id":id.uuidString,"parameters":["resolution":8,"width":400]])
    store.changed(save:false);store.synchronizeScene()
    let changed=store.project!,anchor=changed.objects.first {$0.id==decoration.id}!.clothAttachment!.anchor,point=try changed.objects[0].cloth!.mesh.materialPoint(anchor)
    XCTAssertEqual(point.x,uv.x,accuracy:1e-9);XCTAssertEqual(point.y,uv.y,accuracy:1e-9);XCTAssertEqual(anchor.normalOffsetMm,2)
    XCTAssertEqual(store.cloth.preview.frame?.diagnostics.completedFrames,0)
    let current=try XCTUnwrap(store.cloth.placement(of:changed.objects.first {$0.id==decoration.id}!,in:changed))
    XCTAssertEqual(Double(label.position.y)*100,current.positionMm.y,accuracy:1e-3)
  }
  func testSourceMaterialArtworkFontChangesResetButPlacementDoesNotReset()throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    _ = try call(store,"step",id,["frames":2]);let revision=store.cloth.preview.source!.revision
    store.update(store.project!.objects[0],["position":[30,0,20]])
    XCTAssertEqual(store.cloth.preview.frame?.diagnostics.completedFrames,2);XCTAssertEqual(store.cloth.preview.source!.revision,revision)
    store.update(store.project!.objects[0],["color":"#398A71"]);XCTAssertEqual(store.cloth.preview.frame?.diagnostics.completedFrames,0)
    _ = try call(store,"step",id)
    try store.engine.edit("Artwork") {$0.objects[0].artwork = .init(background:"#CC7733",elements:[.init(kind:"text",x:20,y:20,text:"Cloth")])};store.changed(save:false)
    XCTAssertEqual(store.cloth.preview.frame?.diagnostics.completedFrames,0)
    _ = try call(store,"step",id);let source=store.cloth.preview.source!.revision
    GeometryFactory.invalidateFontResources();store.changed(save:false)
    XCTAssertNotEqual(store.cloth.preview.source!.revision,source);XCTAssertEqual(store.cloth.preview.frame?.diagnostics.completedFrames,0)
  }
  func testHomeProjectChangeAndDeletionClearRuntimeAndRejectLateWork()async throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    let tick=expectation(description:"Real cloth runtime publishes a frame")
    let previous=store.cloth.preview.onFrame
    store.cloth.preview.onFrame={mesh,frame in previous?(mesh,frame);if frame.diagnostics.completedFrames==1,frame.diagnostics.status == .running {store.cloth.preview.stop();tick.fulfill()}}
    _ = try call(store,"run",id);await fulfillment(of:[tick],timeout:3)
    store.home();XCTAssertNil(store.cloth.preview.frame);XCTAssertTrue(store.showingHome)
    XCTAssertThrowsError(try call(store,"step",id))
    store.openProject(store.project!.id);_ = try call(store,"step",id)
    var other=Project(name:"Other");other.objects=[try other.makeObject(recipeID:"box")];try store.repository.save(other)
    store.openProject(other.id);XCTAssertNil(store.cloth.preview.frame);XCTAssertNil(store.cloth.preview.source)
    for _ in 0..<50 {await Task.yield()};XCTAssertNil(store.cloth.preview.frame)
  }
  func testOpenSurfacePrintGuardAndInvalidLockedSettingsRollbackBeforeAnyOutput()throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    let before=store.project!
    XCTAssertThrowsError(try PrintMeshBuilder.mesh(object:before.objects[0],project:before,assets:root,configuration:.init())) {XCTAssertTrue($0.localizedDescription.contains("open flexible surface"))}
    store.printing.open(objectID:id);XCTAssertNil(store.printing.mesh);XCTAssertTrue(store.printing.validationError?.contains("open flexible surface")==true)
    XCTAssertThrowsError(try call(store,"configure",id,["settings":["iterations":1000]]));XCTAssertEqual(store.project,before)
    store.update(store.project!.objects[0],["locked":true]);let locked=store.project!
    XCTAssertThrowsError(try call(store,"configure",id,["settings":["friction":0.8]]));XCTAssertEqual(store.project,locked)
    _ = try call(store,"step",id);XCTAssertEqual(store.cloth.preview.frame?.diagnostics.completedFrames,1)
  }
  func testGeneratedContactThicknessRebuildsItsSupportPinAndDeletionIsAtomic()throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    let before=store.project!
    _ = try call(store,"configure",id,["settings":["collisionThicknessMm":1.6]])
    let study=store.project!.objects[0].cloth!;XCTAssertNoThrow(try study.validate())
    XCTAssertEqual(study.mesh.pins[0].targetMm.y,2*before.objects[0]["supportRadius"]+0.8,accuracy:1e-8)
    store.undo();XCTAssertEqual(store.project,before)
    var label=try before.makeObject(recipeID:"textileLabel");label.position.x=400
    try store.engine.edit("Add independent label") {$0.objects.append(label)}
    _ = try call(store,"attach",label.id,["surface_object_id":id.uuidString])
    let attached=store.project!
    XCTAssertThrowsError(try store.engine.call("form_delete_objects",arguments:["object_ids":[id.uuidString]]))
    XCTAssertEqual(store.project,attached)
    _ = try call(store,"detach",label.id)
    _ = try call(store,"step",id)
    _ = try store.engine.call("form_delete_objects",arguments:["object_ids":[id.uuidString]])
    store.changed(save:false);XCTAssertNil(store.cloth.preview.frame);XCTAssertNil(store.cloth.preview.source)
  }
  func testPrintedPanelMaterialCornersMatchCanvasOrientationOnRealMetal()throws {
    guard let device=MTLCreateSystemDefaultDevice() else {throw XCTSkip("Actual cloth texture orientation needs Metal.")}
    var project=Project(name:"Printed orientation")
    var object=try project.makeObject(recipeID:"clothTote",parameters:["width":200,"depth":200,"resolution":4],materialID:"linen")
    object.artwork = .init(background:"#FFFFFF",elements:[
      .init(kind:"rectangle",x:0,y:0,width:100,height:100,color:"#FF0000"),
      .init(kind:"rectangle",x:100,y:0,width:100,height:100,color:"#00FF00"),
      .init(kind:"rectangle",x:0,y:100,width:100,height:100,color:"#0000FF"),
      .init(kind:"rectangle",x:100,y:100,width:100,height:100,color:"#FFFF00")],bleed:0)
    project.objects=[object]
    let cloth=try ClothSceneSurface(object:object,project:project,assets:FileManager.default.temporaryDirectory,textureLimit:256)
    cloth.surface.material.lightingModel = .constant
    let scene=SCNScene();scene.background.contents=NSColor.white;scene.rootNode.addChildNode(cloth.root)
    for (side,z) in [("front",CGFloat(5)),("back",CGFloat(-5))] {
      let camera=SCNNode();camera.camera=SCNCamera();camera.camera!.usesOrthographicProjection=true;camera.camera!.orthographicScale=1.3
      camera.position=SCNVector3(0,1.3,z);camera.eulerAngles.y=z<0 ? .pi:0;scene.rootNode.addChildNode(camera)
      let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
      let image=renderer.snapshot(atTime:0,with:.init(width:512,height:512),antialiasingMode:.none)
      let bitmap=try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
      let expected:[(Int,Int,Double,Double,Double)]=[(150,150,1,0,0),(360,150,0,1,0),(150,360,0,0,1),(360,360,1,1,0)]
      for (x,y,r,g,b) in expected {
        let color=try XCTUnwrap(bitmap.colorAt(x:x,y:y))
        XCTAssertEqual(color.redComponent,r,accuracy:0.08,"Red at Canvas corner \(x),\(y)")
        XCTAssertEqual(color.greenComponent,g,accuracy:0.08,"Green at Canvas corner \(x),\(y)")
        XCTAssertEqual(color.blueComponent,b,accuracy:0.08,"Blue at Canvas corner \(x),\(y)")
      }
      if let directory=ProcessInfo.processInfo.environment["FORM_CLOTH_PROOF_DIR"] {
        let root=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("printed-cloth-\(side)-orientation.png"))
      }
    }
  }
  func testPhysicalMaterialTextureIsBoundedCachedAndMovesWithoutRepaint()throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    try store.engine.edit("Printed textile") {$0.objects[0].artwork = .init(background:"#CB7532",elements:[.init(kind:"text",x:20,y:30,width:140,height:40,text:"NASA / CLOTH",color:"#17334A",fontSize:28)])}
    store.changed(save:false);store.synchronizeScene()
    let object=store.project!.objects[0],a=ClothSceneSurface.material(object:object,project:store.project!,assets:root,textureLimit:256),b=ClothSceneSurface.material(object:object,project:store.project!,assets:root,textureLimit:256)
    let image=try XCTUnwrap(a.diffuse.contents as? NSImage),second=try XCTUnwrap(b.diffuse.contents as? NSImage)
    XCTAssertTrue(image === second);XCTAssertTrue(image.representations.allSatisfy {max($0.pixelsWide,$0.pixelsHigh)<=256})
    let surface=try XCTUnwrap(try node(store,id).childNode(withName:"cloth.surface",recursively:true)),material=try XCTUnwrap(surface.geometry?.firstMaterial),texture=try XCTUnwrap(material.diffuse.contents as? NSImage)
    _ = try call(store,"step",id,["frames":3])
    XCTAssertTrue(surface.geometry?.firstMaterial === material);XCTAssertTrue(surface.geometry?.firstMaterial?.diffuse.contents as? NSImage === texture)
  }

}

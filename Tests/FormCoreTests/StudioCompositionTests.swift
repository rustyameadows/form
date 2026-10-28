import XCTest
@testable import FormCore

final class StudioCompositionTests:XCTestCase {
  private func fixture()throws->OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("scene-core-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));var p=Project(name:"Linked products")
    p.objects=[try p.makeObject(recipeID:"lamp"),try p.makeObject(recipeID:"box")];p.camera.viewportAspect=1.5;engine.project=p;return engine
  }
  private func call(_ engine:OperationEngine,_ command:String,_ arguments:[String:Any]=[:])throws->Any{try engine.call("form_studio_scene",arguments:["command":command].merging(arguments){_,b in b})}
  func testSavedCompositionInstancesDoNotDuplicateDesignAndSurviveUndoReopen()throws {
    let e=try fixture(),original=e.project!,digest=try original.studioDesignDigest()
    _ = try call(e,"create",["name":"Retail shelf"])
    var scene=e.project!.studioPresentation!.scenes![0],copy=scene.instances[0];copy.id=UUID();copy.name="Second lamp";copy.positionMM.x=200;scene.instances.append(copy)
    scene.instances.append(.init(name:"Shelf",prop:.init()));scene.camera.azimuth+=0.5
    _ = try call(e,"save",["scene":try jsonObject(scene)])
    let saved=e.project!;XCTAssertEqual(saved.schemaVersion,54);XCTAssertEqual(saved.objects,original.objects);XCTAssertEqual(saved.camera,original.camera);XCTAssertEqual(try saved.studioDesignDigest(),digest);XCTAssertEqual(saved.studioPresentation!.scenes![0].revision,2)
    try e.flush();XCTAssertEqual(try e.repository.load(saved.id),try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(saved)))
    e.undo();XCTAssertEqual(e.project!.studioPresentation!.scenes![0].instances.count,2);e.redo();XCTAssertEqual(e.project,saved)
    e.undo();e.undo();XCTAssertEqual(e.project,original)
  }
  func testRenderResolutionIsDeterministicPhysicalAndUsesVariantSourcesWithoutMutatingProject()throws {
    let e=try fixture(),p=e.project!;var scene=StudioComposition.fromProject(p)
    var instance=scene.instances[0];instance.positionMM = .init(21,33,-55);instance.rotationDegrees=37;instance.sourceObjectID=p.objects[1].id;instance.materialID="chalk";scene.instances=[instance]
    let a=try scene.resolved(in:p),b=try scene.resolved(in:p)
    XCTAssertEqual(a.project,b.project);XCTAssertEqual(a.visible,[instance.id]);let rendered=try XCTUnwrap(a.project.objects.first{$0.id==instance.id})
    XCTAssertEqual(rendered.recipeID,"box");XCTAssertEqual(rendered.position,instance.positionMM);XCTAssertEqual(rendered.rotation,37);XCTAssertEqual(rendered.parameters,p.objects[1].parameters)
    XCTAssertEqual(Array(a.project.objects.prefix(p.objects.count)),p.objects);XCTAssertEqual(e.project,p)
  }
  func testMissingSourcesStayRepairableAndCannotRender()throws {
    let e=try fixture();_ = try call(e,"create");let scene=e.project!.studioPresentation!.scenes![0]
    try e.edit("Remove source"){$0.objects.removeFirst()};try e.project!.validateArtworkLinks();XCTAssertThrowsError(try scene.resolved(in:e.project!))
    var hidden=scene;hidden.instances[0].visible=false;XCTAssertNoThrow(try hidden.resolved(in:e.project!))
  }
  func testInvalidSaveAndOptimisticConflictAreAtomicAndInspectionHasNoUndo()throws {
    let e=try fixture();_ = try call(e,"create");let before=e.project!,count=e.undoStack.count
    _ = try call(e,"list");_ = try call(e,"get",["scene_id":before.studioPresentation!.scenes![0].id.uuidString]);XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,count)
    var scene=before.studioPresentation!.scenes![0];scene.instances[0].positionMM.x = .infinity
    XCTAssertThrowsError(try call(e,"save",["scene":try jsonObject(scene)]));XCTAssertEqual(e.project,before)
    scene=before.studioPresentation!.scenes![0];scene.name="Changed";_ = try call(e,"save",["scene":try jsonObject(scene)]);let changed=e.project!
    scene.name="Stale";XCTAssertThrowsError(try call(e,"save",["scene":try jsonObject(scene)]));XCTAssertEqual(e.project,changed)
    XCTAssertThrowsError(try call(e,"create",["unexpected":true]));XCTAssertEqual(e.project,changed)
  }
  func testDeletingLastLegacyShotRetainsScenesAndDuplicatingSceneGetsIndependentIDs()throws {
    let e=try fixture();_ = try call(e,"create");let scene=e.project!.studioPresentation!.scenes![0]
    _ = try e.call("form_set_view",arguments:["view":"studio","studio_command":"capture","name":"Old shot"])
    let shot=e.project!.studioPresentation!.shots[0]
    _ = try e.call("form_set_view",arguments:["view":"studio","studio_command":"delete","shot_id":shot.id.uuidString]);XCTAssertEqual(e.project!.studioPresentation!.scenes,[scene])
    _ = try call(e,"duplicate",["scene_id":scene.id.uuidString]);let duplicated=e.project!.studioPresentation!.scenes![1]
    XCTAssertNotEqual(scene.id,duplicated.id);XCTAssertTrue(Set(scene.instances.map(\.id)).isDisjoint(with:Set(duplicated.instances.map(\.id))));XCTAssertEqual(scene.instances.map(\.sourceObjectID),duplicated.instances.map(\.sourceObjectID))
  }
  func testCameraMotionHasExactEndpointsFixedOrbitElevationAndBoundedWork()throws {
    var start=CameraState();start.azimuth=170 * .pi/180;start.elevation=0.3
    var motion=StudioMotion();motion.orbitDegrees=360
    for i in 0...100 {let c=try motion.camera(start:start,fraction:Double(i)/100);XCTAssertEqual(c.elevation,start.elevation);XCTAssertEqual(c.target,start.target);XCTAssertEqual(c.distance,start.distance)}
    XCTAssertEqual(try motion.camera(start:start,fraction:1).azimuth-start.azimuth,2 * .pi,accuracy:1e-12)
    var end=start;end.azimuth = -170 * .pi/180;end.distance=4;end.target = .init(2,3,4);motion.mode = .between;motion.startCamera=start;motion.endCamera=end
    let middle=try motion.camera(start:CameraState(),fraction:0.5);XCTAssertEqual(middle.azimuth,.pi,accuracy:1e-12);XCTAssertEqual(middle.distance,8);XCTAssertEqual(try motion.camera(start:start,fraction:1).target,end.target)
    motion.seconds=21;XCTAssertThrowsError(try motion.validate());motion.seconds=20;motion.fps=30;XCTAssertEqual(motion.frameCount,600);XCTAssertNoThrow(try motion.validate());XCTAssertThrowsError(try motion.camera(start:start,fraction:.nan))
  }
  func testLegacyPresentationDecodesWithoutScenesAndDoesNotRequireSchema54()throws {
    let p=try fixture().project!;let json=try JSONSerialization.data(withJSONObject:["shots":[]]);let value=try JSONDecoder.form.decode(StudioPresentation.self,from:json);XCTAssertNil(value.scenes)
    var old=p;old.studioPresentation=value;XCTAssertLessThan(old.minimumSchemaVersion,54)
  }
}

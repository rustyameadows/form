import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class StudioSheetPoseControlsTests:XCTestCase {
  private func fixture()throws->(StudioStore,StudioCompositionController,UUID) {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("studio-publication-pose-"+UUID().uuidString)
    let store=StudioStore(repository:try .init(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    var project=Project(name:"Independent scene publication controls"),pages=[UUID]()
    for index in 1...8 {
      var object=try project.makeObject(recipeID:"artboard",name:"Page \(index)",parameters:["width":80,"depth":100])
      object.artwork = .init(elements:[.init(kind:"text",x:8,y:10,width:60,height:20,text:"PAGE \(index)",fontSize:14)],bleed:0)
      project.objects.append(object);pages.append(object.id)
    }
    let publication=try PublicationCommands.createPublication(in:&project,name:"Canonical publication",pages:pages)
    _ = try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,openingDegrees:180,activeSpread:1),name:"Shared sheets")
    store.engine.project=project;store.showingHome=false
    let controller=store.studioComposition;controller.newScene()
    let id=try XCTUnwrap(controller.draft?.instances.first?.id);controller.selectInstance(id)
    addTeardownBlock{@MainActor in controller.reset();controller.stage.view=nil;store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return(store,controller,id)
  }
  func testPublicationSliderGestureCreatesOneSceneUndoAndLeavesDesignAndCameraExact()throws {
    let(store,controller,id)=try fixture(),source=try XCTUnwrap(store.project),before=try XCTUnwrap(controller.draft)
    controller.inspectorEditing(true)
    for angle in [30.0,70,120] {
      controller.changeInstance(id:id){instance in var pose=instance.sheetPose ?? .init();pose.openingDegrees=angle;pose.activeSpread=2;instance.sheetPose=pose}
    }
    controller.inspectorEditing(false)
    let edited=try XCTUnwrap(controller.draft)
    XCTAssertEqual(edited.instances.first?.sheetPose?.openingDegrees,120)
    XCTAssertTrue(controller.undoDraft());XCTAssertEqual(controller.draft,before)
    XCTAssertFalse(controller.undoDraft(),"One held slider gesture is one draft checkpoint")
    XCTAssertTrue(controller.redoDraft());XCTAssertEqual(controller.draft,edited)
    XCTAssertEqual(store.project,source);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testDuplicateRetainsPoseThenCanChooseAnotherSpreadIndependently()throws {
    let(store,controller,id)=try fixture(),source=try XCTUnwrap(store.project)
    controller.changeInstance(id:id){$0.sheetPose = .init(openingDegrees:120,activeSpread:1)}
    let cache=StudioCompositionResolutionCache()
    _ = try cache.resolve(try XCTUnwrap(controller.draft),in:source)
    controller.duplicateInstance()
    let duplicate=try XCTUnwrap(controller.selectedInstanceID)
    XCTAssertNotEqual(duplicate,id)
    controller.changeInstance(id:duplicate){$0.sheetPose = .init(openingDegrees:180,activeSpread:3)}
    let scene=try XCTUnwrap(controller.draft)
    XCTAssertEqual(scene.instances.first{$0.id==id}?.sheetPose?.activeSpread,1)
    XCTAssertEqual(scene.instances.first{$0.id==duplicate}?.sheetPose?.activeSpread,3)
    let result=try scene.resolved(in:source)
    let cached=try cache.resolve(scene,in:source)
    XCTAssertEqual(cached.project,result.project);XCTAssertEqual(cached.visible,result.visible)
    XCTAssertEqual(cache.builds,2,"Independent publication poses must invalidate the resolved scene cache")
    var moved=scene;moved.instances[0].positionMM.x+=120;moved.instances[0].rotationDegrees=25
    XCTAssertEqual(try cache.resolve(moved,in:source).project,try moved.resolved(in:source).project)
    XCTAssertEqual(cache.builds,2,"Moving a posed book can reuse its resolved geometry")
    moved.instances[0].sheetPose?.activeSpread=2
    XCTAssertEqual(try cache.resolve(moved,in:source).project,try moved.resolved(in:source).project)
    XCTAssertEqual(cache.builds,3,"Choosing another reader spread must rebuild its resolved sheets")
    XCTAssertEqual(result.visible,Set([id,duplicate]));XCTAssertEqual(store.project,source)
  }
  func testShrunkSourceKeepsSavedPoseWhileControlGetterAndDuplicateUseAvailableLeaf()throws {
    let(store,controller,id)=try fixture()
    controller.changeInstance(id:id){$0.sheetPose = .init(openingDegrees:130,activeSpread:4)}
    controller.save();XCTAssertNil(controller.error)
    let saved=try XCTUnwrap(controller.draft),instance=try XCTUnwrap(saved.instances.first),document=try XCTUnwrap(store.project?.publications?.first)
    let removed=Set(document.pages.suffix(4).map(\.objectID))
    try store.engine.edit("Shorter canonical publication"){project in try PublicationCommands.removePages(in:&project,publicationID:document.id,pageIDs:removed,deleteObjects:true)}
    controller.reconcile()
    let source=try XCTUnwrap(store.project?.objects.first{$0.id==instance.sourceObjectID}),project=try XCTUnwrap(store.project)
    let effective=StudioSheetPoseControls.effectiveSource(instance:instance,source:source,project:project)
    XCTAssertEqual(effective.sheetAssembly?.activeSpread,2);XCTAssertEqual(effective.sheetAssembly?.openingDegrees,130)
    XCTAssertEqual(controller.draft,saved);XCTAssertEqual(project.studioPresentation?.scenes?.first,saved)
    XCTAssertNil(controller.error)
    controller.selectInstance(id);controller.duplicateInstance()
    let copy=try XCTUnwrap(controller.selected),edited=try XCTUnwrap(controller.draft)
    XCTAssertNotEqual(copy.id,id);XCTAssertEqual(copy.sheetPose?.activeSpread,2)
    XCTAssertEqual(edited.instances.first{$0.id==id},instance)
    XCTAssertTrue(controller.undoDraft());XCTAssertEqual(controller.draft,saved)
    XCTAssertEqual(store.project,project,"A view or draft duplicate cannot rewrite saved source/scene metadata")
  }
  func testSaveDuringAnInspectorGestureStartsTheNextUndoAtTheSavedScene()throws {
    let(store,controller,id)=try fixture(),source=try XCTUnwrap(store.project)
    controller.inspectorEditing(true)
    controller.changeInstance(id:id){$0.sheetPose = .init(openingDegrees:75,activeSpread:2)}
    controller.save()
    XCTAssertNil(controller.error)
    let saved=try XCTUnwrap(controller.draft)
    controller.inspectorEditing(false)
    XCTAssertFalse(controller.dirty);XCTAssertFalse(controller.undoDraft())
    controller.changeInstance(id:id){$0.sheetPose?.openingDegrees=120}
    XCTAssertTrue(controller.undoDraft());XCTAssertEqual(controller.draft,saved)
    XCTAssertEqual(store.project?.objects,source.objects);XCTAssertEqual(store.project?.publications,source.publications)
  }
}

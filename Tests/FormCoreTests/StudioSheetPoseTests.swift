import XCTest
@testable import FormCore

final class StudioSheetPoseTests:XCTestCase {
  private func fixture()throws->(Project,UUID) {
    var project=Project(name:"Shared publication, independent presentation poses"),pages=[UUID]()
    for index in 1...12 {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index)",parameters:["width":100,"depth":140])
      page.artwork = .init(elements:[.init(kind:"text",x:10,y:12,width:80,height:25,text:"PAGE \(index)",fontSize:20)],bleed:0)
      project.objects.append(page);pages.append(page.id)
    }
    let document=try PublicationCommands.createPublication(in:&project,name:"Source document",pages:pages)
    let source=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:document,openingDegrees:180,activeSpread:1),name:"Shared physical source")
    return(project,source)
  }
  func testThreeSceneCopiesResolveDifferentSpreadsAndOpeningsFromTheSameSources()throws {
    let(project,source)=try fixture(),before=project
    var scene=StudioComposition(name:"Three distinct spreads",camera:project.camera)
    for(index,spread) in [1,3,5].enumerated() {
      var instance=StudioInstance(name:"Spread \(spread)",sourceObjectID:source,positionMM:.init(Double(index)*250,0,0))
      instance.sheetPose = .init(openingDegrees:[180,120,75][index],activeSpread:spread,bendMM:0)
      scene.instances.append(instance)
    }
    let resolved=try scene.resolved(in:project)
    XCTAssertEqual(resolved.visible,Set(scene.instances.map(\.id)))
    XCTAssertEqual(resolved.project.objects.prefix(project.objects.count).map{$0},project.objects)
    for(index,instance) in scene.instances.enumerated() {
      let object=try XCTUnwrap(resolved.project.objects.first{$0.id==instance.id}),assembly=try resolved.project.resolvedSheetAssembly(object)
      XCTAssertEqual(assembly.activeSpread,[1,3,5][index]);XCTAssertEqual(assembly.openingDegrees,[180,120,75][index])
      XCTAssertEqual(assembly.leaves.filter(\.turned).count,assembly.activeSpread)
      XCTAssertEqual(assembly.leaves[assembly.activeSpread].front?.sourceObjectID,project.publications![0].pages[assembly.activeSpread*2].objectID)
      XCTAssertEqual(assembly.stackThicknessMM,0.72,accuracy:0.000001)
    }
    XCTAssertEqual(project,before)
    let reopened=try JSONDecoder.form.decode(StudioComposition.self,from:JSONEncoder.form.encode(scene))
    XCTAssertEqual(reopened,scene);XCTAssertNoThrow(try reopened.resolved(in:project))
  }
  func testInvalidPoseIsRejectedBeforeSceneSaveAndCanonicalSourceStaysExact()throws {
    let(project,source)=try fixture(),root=FileManager.default.temporaryDirectory.appendingPathComponent("studio-sheet-pose-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try .init(root:root));engine.project=project
    var scene=StudioComposition(name:"Invalid spread",camera:project.camera),instance=StudioInstance(name:"Bound source",sourceObjectID:source)
    instance.sheetPose = .init(openingDegrees:90,activeSpread:7);scene.instances=[instance]
    XCTAssertThrowsError(try engine.call("form_studio_scene",arguments:["command":"save","scene":try jsonObject(scene)]))
    XCTAssertEqual(engine.project,project);XCTAssertTrue(engine.undoStack.isEmpty)
    instance.sheetPose = .init(openingDegrees:181)
    XCTAssertThrowsError(try instance.validate())
    instance.sourceObjectID=project.objects[0].id;instance.sheetPose = .init(openingDegrees:90);scene.instances=[instance]
    XCTAssertThrowsError(try scene.resolved(in:project));XCTAssertEqual(project.objects.first{$0.id==source}?.sheetAssembly?.openingDegrees,180)
  }
  func testAcceptedSceneAfterPageShrinkClampsOnlyEffectivePoseAndStrictlyValidatesNewWrites()throws {
    let(project,source)=try fixture(),folder=FileManager.default.temporaryDirectory.appendingPathComponent("shrinking-publication-pose-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:folder)}
    let engine=OperationEngine(repository:try .init(root:folder));engine.project=project
    var scene=StudioComposition(name:"A remembered opening",camera:project.camera),instance=StudioInstance(name:"Independent copy",sourceObjectID:source)
    instance.sheetPose = .init(openingDegrees:120,activeSpread:5);scene.instances=[instance]
    _=try engine.call("form_studio_scene",arguments:["command":"save","scene":try jsonObject(scene)])
    let saved=try XCTUnwrap(engine.project?.studioPresentation?.scenes?.first),beforeRemoval=try XCTUnwrap(engine.project)
    let document=try XCTUnwrap(engine.project?.publications?.first),remove=Array(document.pages.dropFirst(4)).map(\.objectID)
    _=try engine.call("form_publication",arguments:["command":"remove","publication_id":document.id.uuidString,"page_ids":remove.map(\.uuidString),"delete_objects":true])
    let shrunk=try XCTUnwrap(engine.project),canonical=try XCTUnwrap(shrunk.objects.first{$0.id==source})
    XCTAssertEqual(shrunk.studioPresentation?.scenes?.first,saved,"Source edits must not rewrite saved scene poses")
    XCTAssertEqual(try shrunk.resolvedSheetAssembly(canonical).leaves.count,2)
    let rendered=try saved.resolved(in:shrunk),copy=try XCTUnwrap(rendered.project.objects.first{$0.id==instance.id})
    XCTAssertEqual(copy.sheetAssembly?.activeSpread,2);XCTAssertEqual(copy.sheetAssembly?.openingDegrees,120)
    XCTAssertEqual(saved.instances[0].sheetPose?.activeSpread,5);XCTAssertEqual(shrunk.objects.first{$0.id==source},canonical)
    engine.undo();XCTAssertEqual(engine.project,beforeRemoval);engine.redo();XCTAssertEqual(engine.project,shrunk)
    var cameraEdit=saved;cameraEdit.camera.distance+=1
    _=try engine.call("form_studio_scene",arguments:["command":"save","scene":try jsonObject(cameraEdit)])
    let resaved=try XCTUnwrap(engine.project?.studioPresentation?.scenes?.first)
    XCTAssertEqual(resaved.instances,saved.instances);XCTAssertEqual(resaved.camera,cameraEdit.camera)
    let beforeRejected=try XCTUnwrap(engine.project),undo=engine.undoStack.count
    var changed=resaved;changed.instances[0].sheetPose?.activeSpread=4
    XCTAssertThrowsError(try engine.call("form_studio_scene",arguments:["command":"save","scene":try jsonObject(changed)]))
    var new=resaved;new.id=UUID();new.instances[0].id=UUID()
    XCTAssertThrowsError(try engine.call("form_studio_scene",arguments:["command":"save","scene":try jsonObject(new)]))
    for invalid in [-1,201] {
      var value=instance.sheetPose!;value.activeSpread=invalid
      XCTAssertThrowsError(try value.applying(to:canonical,in:shrunk,clampingSpread:true))
    }
    XCTAssertEqual(engine.project,beforeRejected);XCTAssertEqual(engine.undoStack.count,undo)
    let duplicated=try JSONDecoder.form.decode(StudioComposition.self,from:JSONSerialization.data(withJSONObject:engine.call("form_studio_scene",arguments:["command":"duplicate","scene_id":saved.id.uuidString])))
    XCTAssertEqual(duplicated.instances[0].sheetPose?.activeSpread,2);XCTAssertNoThrow(try duplicated.validateSourcePoses(in:shrunk))
    XCTAssertEqual(engine.project?.studioPresentation?.scenes?.first{$0.id==saved.id},resaved)
    XCTAssertEqual(engine.project?.objects,shrunk.objects);XCTAssertEqual(engine.project?.publications,shrunk.publications)
  }
  func testClosedInstanceRemembersItsSpreadWithoutClosingTheOtherCopy()throws {
    let(project,source)=try fixture()
    var scene=StudioComposition(name:"Closed beside open",camera:project.camera),closed=StudioInstance(name:"Closed",sourceObjectID:source),open=StudioInstance(name:"Open",sourceObjectID:source)
    closed.sheetPose = .init(openingDegrees:0,activeSpread:4);open.sheetPose = .init(openingDegrees:180,activeSpread:2);scene.instances=[closed,open]
    let result=try scene.resolved(in:project)
    let closedSource=try XCTUnwrap(result.project.objects.first{$0.id==closed.id}),openSource=try XCTUnwrap(result.project.objects.first{$0.id==open.id})
    XCTAssertEqual(try result.project.resolvedSheetAssembly(closedSource).leaves.filter(\.turned).count,0)
    XCTAssertEqual(closedSource.sheetAssembly?.activeSpread,4);XCTAssertEqual(openSource.sheetAssembly?.activeSpread,2)
    XCTAssertEqual(openSource.sheetAssembly?.openingDegrees,180);XCTAssertEqual(project.objects.first{$0.id==source}?.sheetAssembly?.activeSpread,1)
  }
}

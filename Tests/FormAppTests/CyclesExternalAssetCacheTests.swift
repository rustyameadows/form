import AppKit
import Foundation
import FormCore
import FormMeshAssets
import LabRendering
import XCTest
@testable import FormApp

@MainActor final class CyclesExternalAssetCacheTests:XCTestCase {
  private func importedObject(in project:Project,assets:URL)throws->ProductObject {
    try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    let source=Data("""
    solid surface
    facet normal 0 1 0
    outer loop
    vertex 0 0 0
    vertex 0 0 30
    vertex 40 0 0
    endloop
    endfacet
    endsolid surface
    """.utf8)
    let document=try STLImporter.importData(source,options:.init(sourceUnit:.millimeter))
    let normalized=try JSONEncoder().encode(document)
    let reference=MeshAssetReference(document:document,sourceAsset:"source.stl",normalizedAsset:"source.mesh.json",normalizedSHA256:MeshAssetHash.sha256(normalized))
    try source.write(to:assets.appendingPathComponent(reference.sourceAsset))
    try normalized.write(to:assets.appendingPathComponent(reference.normalizedAsset))
    var object=try project.makeObject(recipeID:"importedMesh",parameters:["scalePercent":100]);object.meshAsset=reference
    return object
  }
  private func fixture()throws->(Project,TableSceneController,URL) {
    _=NSApplication.shared
    let assets=FileManager.default.temporaryDirectory.appendingPathComponent("cycles-external-"+UUID().uuidString)
    var project=Project(name:"External source contracts");project.objects=[try importedObject(in:project,assets:assets)]
    let scene=TableSceneController();sync(scene,project,assets)
    addTeardownBlock{try? FileManager.default.removeItem(at:assets)}
    return(project,scene,assets)
  }
  private func sync(_ scene:TableSceneController,_ project:Project,_ assets:URL) {
    scene.sync(project,selection:[],isolated:[],showGrid:false,studio:false,preset:"Paper",assets:assets)
  }
  private func expectFailure(_ scene:TableSceneController,file:StaticString=#filePath,line:UInt=#line)async {
    do {_ = try await scene.cyclesSnapshot(settings:.init());XCTFail("A changed or missing source must not reuse cached geometry.",file:file,line:line)}
    catch {XCTAssertFalse(error.localizedDescription.isEmpty,file:file,line:line)}
  }
  func testWarmImportedMeshCacheRevalidatesBothFilesAndRejectsSameSizeReplacement()async throws {
    let (project,scene,assets)=try fixture(),reference=try XCTUnwrap(project.objects[0].meshAsset)
    let first=try await scene.cyclesSnapshot(settings:.init())
    XCTAssertTrue(first.renderables.contains{$0.objectID==project.objects[0].id})
    for name in [reference.sourceAsset,reference.normalizedAsset] {
      let url=assets.appendingPathComponent(name),original=try Data(contentsOf:url)
      let timestamp=try url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate!
      var changed=original;changed[changed.startIndex]^=1;try changed.write(to:url)
      try FileManager.default.setAttributes([.modificationDate:timestamp],ofItemAtPath:url.path)
      await expectFailure(scene)
      try original.write(to:url)
      let restored=try await scene.cyclesSnapshot(settings:.init())
      XCTAssertEqual(restored.revision,first.revision)
      XCTAssertEqual(restored.renderables.first{$0.objectID==project.objects[0].id}?.mesh.positionsMM,first.renderables.first{$0.objectID==project.objects[0].id}?.mesh.positionsMM)
      try FileManager.default.removeItem(at:url)
      await expectFailure(scene)
      try original.write(to:url)
    }
  }
  func testWarmCacheCannotPublishWhenSourceIsDeletedDuringPreparation()async throws {
    let (project,scene,assets)=try fixture()
    _ = try await scene.cyclesSnapshot(settings:.init())
    let url=assets.appendingPathComponent(project.objects[0].meshAsset!.sourceAsset)
    var visited=false
    scene.externalPayloadPreparationCheckpoint={visited=true;try? FileManager.default.removeItem(at:url)}
    await expectFailure(scene);XCTAssertTrue(visited)
  }
  func testProjectEditDuringExternalPreparationStillCancelsSnapshot()async throws {
    let (project,scene,assets)=try fixture()
    var changed=project;changed.objects[0].position.x+=10
    scene.externalPayloadPreparationCheckpoint={self.sync(scene,changed,assets)}
    do {_ = try await scene.cyclesSnapshot(settings:.init());XCTFail("The frozen runtime does not authorize stale authored sources.")}
    catch {guard case CyclesRenderError.cancelled=error else {return XCTFail("Expected source cancellation, received \(error).")}}
  }
  func testTableFinalFreezesClothCameraAndIsolationBeforeExternalAwait()async throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("cycles-freeze-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    defer {store.cloth.preview.reset();store.modelAssets.reset();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    var project=Project(name:"Transient capture"),cloth=try project.makeObject(recipeID:"clothPanel")
    cloth.cloth!.settings.frameStepSeconds=1/60
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    let external=try importedObject(in:project,assets:assets)
    project.objects=[cloth,external];project.camera.viewportAspect=1.5
    store.engine.project=project;store.showingHome=false;store.scene=TableSceneController(store:store);store.synchronizeScene()
    try store.cloth.activate(cloth.id);try store.cloth.preview.stepImmediately(frames:3)
    let live=try XCTUnwrap(store.scene),source=try XCTUnwrap(store.project),initialFrame=try XCTUnwrap(store.cloth.preview.frame)
    let initial=try await live.cyclesSnapshot(settings:.init())
    let initialCloth=try XCTUnwrap(initial.renderables.first{$0.componentID.contains("cloth.surface")})
    let shot=StudioShot(name:"Frozen Table",camera:source.camera,referenceAspect:1.5)
    let initialCamera=live.cameraPayload(size:.init(width:shot.pixels.width,height:shot.pixels.height))
    var checkpointCount=0,advanceError:Error?,expectedProject:Project?
    live.externalPayloadPreparationCheckpoint={
      checkpointCount+=1
      do {try store.cloth.preview.stepImmediately(frames:12)}catch{advanceError=error}
      live.camera.azimuth+=0.6;live.updateCamera()
      live.sync(source,selection:[],isolated:[cloth.id],showGrid:false,studio:false,preset:"Paper",assets:assets)
      expectedProject=store.project
    }
    let frozen=try await StudioShotRenderer().cyclesTableSnapshot(project:source,shot:shot,assets:assets,settings:.init(),live:live)
    XCTAssertNil(advanceError);XCTAssertEqual(checkpointCount,1)
    let after=try XCTUnwrap(store.cloth.preview.frame)
    XCTAssertNotEqual(after,initialFrame,"The controlled preparation wait must actually advance the simulation.")
    let captured=try XCTUnwrap(frozen.renderables.first{$0.componentID==initialCloth.componentID})
    XCTAssertEqual(captured.mesh.positionsMM,initialCloth.mesh.positionsMM)
    XCTAssertEqual(captured.transform,initialCloth.transform)
    XCTAssertEqual(frozen.camera.worldFromCameraMM,initialCamera.worldFromCameraMM)
    XCTAssertTrue(frozen.renderables.contains{$0.objectID==external.id && $0.visible})
    let expected=try XCTUnwrap(expectedProject),current=try XCTUnwrap(store.project)
    XCTAssertTrue(current==expected,"Rendering changed the project beyond the test's deliberate navigation.")
    XCTAssertEqual(try current.studioDesignDigest(),try source.studioDesignDigest())
    XCTAssertEqual(current.camera,expected.camera);XCTAssertEqual(live.camera,expected.camera)
    XCTAssertEqual(current.camera.azimuth,source.camera.azimuth+0.6,accuracy:1e-12)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertThrowsError(try store.studioShots.runtimePreflight(source,shot),"Saved final shots still require committed simulation sources.")
  }
}

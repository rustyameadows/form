import AppKit
import FormCore
import FormMeshAssets
import XCTest
@testable import FormApp

@MainActor final class StudioPreparationRetryTests: XCTestCase {
  func testRecallingSameSceneRetriesMissingModelAfterResourceRecovery() async throws {
    _ = NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("studio-prepare-retry-"+UUID().uuidString)
    let repository=try ProjectRepository(root:directory),store=StudioStore(repository:repository,seedLibrary:false)
    let controller=store.studioComposition
    defer {
      controller.reset();store.modelAssets.reset();store.engine.project=nil
      try? FileManager.default.removeItem(at:directory)
    }
    let mesh=PrintMesh(triangles:[.init(.init(0,0,0),.init(40,0,0),.init(0,30,0))])
    let original=try mesh.binarySTL()
    let document=try STLImporter.importData(original,fileName:"Triangle.stl",options:.init(sourceUnit:.millimeter))
    let normalized=try JSONEncoder().encode(document)
    let reference=MeshAssetReference(document:document,sourceAsset:"original.stl",normalizedAsset:"triangle.mesh.json",normalizedSHA256:MeshAssetHash.sha256(normalized))
    var project=Project(name:"Recoverable external source")
    var object=try project.makeObject(recipeID:"importedMesh",parameters:["scalePercent":100])
    object.meshAsset=reference;project.objects=[object]
    var scene=StudioComposition(name:"Saved mesh scene",camera:project.camera)
    scene.instances=[.init(name:"Triangle instance",sourceObjectID:object.id)]
    project.studioPresentation = .init();project.studioPresentation?.scenes=[scene]
    try repository.save(project)
    let assets=repository.url(for:project.id).appendingPathComponent("Assets")
    try original.write(to:assets.appendingPathComponent(reference.sourceAsset))
    store.engine.project=project
    controller.reconcile()
    for _ in 0..<500 {
      if controller.error != nil {break}
      try await Task.sleep(for:.milliseconds(10))
    }
    XCTAssertNotNil(controller.error,"The native external loader must report the genuinely missing normalized resource")
    XCTAssertTrue(controller.stage.extraRenderables.isEmpty)
    let failedSyncs=controller.stageSyncCount
    try normalized.write(to:assets.appendingPathComponent(reference.normalizedAsset))
    // This is the saved-row action, including the already-current scene. It
    // must retry actual external preparation without requiring a document edit.
    controller.requestScene(scene.id)
    for _ in 0..<500 {
      if !controller.stage.extraRenderables.isEmpty,controller.error==nil {break}
      try await Task.sleep(for:.milliseconds(10))
    }
    XCTAssertNil(controller.error)
    XCTAssertFalse(controller.stage.extraRenderables.isEmpty,"The restored source must reach real native scene payloads")
    XCTAssertTrue(controller.stage.extraRenderables.allSatisfy{$0.objectID==scene.instances[0].id})
    XCTAssertGreaterThan(controller.stageSyncCount,failedSyncs)
    XCTAssertEqual(controller.draft,scene);XCTAssertFalse(controller.dirty)
    XCTAssertEqual(store.project,project);XCTAssertTrue(store.engine.undoStack.isEmpty)
    let completedSyncs=controller.stageSyncCount
    controller.requestScene(scene.id)
    XCTAssertEqual(controller.stageSyncCount,completedSyncs,"Recalling a healthy current scene must keep the fast path")
  }
}

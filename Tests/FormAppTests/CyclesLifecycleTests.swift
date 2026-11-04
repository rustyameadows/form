import AppKit
import XCTest
import FormCore
@testable import FormApp

@MainActor final class CyclesLifecycleTests:XCTestCase {
  func testMissingPhysicalAssetRejectsFinalWithoutCreatingDestination()async throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("cycles-missing-asset-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    defer{store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    var project=Project(name:"Missing render dependency"),object=try project.makeObject(recipeID:"box")
    var material=project.material(object.materialID);material.id="missing-map-material";material.appearance=PhysicalAppearance()
    material.appearance?.textures["roughness"] = .init(asset:"missing-roughness.png",sha256:String(repeating:"a",count:64))
    object.materialID=material.id;project.materials=[material];project.objects=[object]
    store.engine.project=project
    let shot=StudioShot(name:"Missing texture",camera:project.camera,referenceAspect:1.5)
    let output=root.appendingPathComponent("missing-asset.render")
    do {_ = try await store.cycles.renderShot(shot,to:output);XCTFail("Missing physical textures must fail before helper launch or delivery.")}
    catch {XCTAssertTrue(error.localizedDescription.contains("missing") || error.localizedDescription.contains("exist"),error.localizedDescription)}
    XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
    XCTAssertEqual(store.project,project)
    let paths=(FileManager.default.enumerator(atPath:root.path)?.allObjects as? [String]) ?? []
    XCTAssertFalse(paths.contains{$0.contains(".renderpartial")})
  }
  func testNativeFinalShotAndSceneRejectUnpersistedClothWithoutReset()async throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("cycles-lifecycle-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    defer{store.cloth.preview.reset();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    var project=Project(name:"Committed render source"),cloth=try project.makeObject(recipeID:"clothPanel")
    cloth.cloth!.settings.frameStepSeconds=1/60;project.objects=[cloth];project.camera.viewportAspect=1.5
    store.engine.project=project;try store.cloth.activate(cloth.id);try store.cloth.preview.stepImmediately(frames:1)
    let frame=store.cloth.preview.frame,source=store.project
    let shot=StudioShot(name:"Saved subject",camera:project.camera,referenceAspect:1.5)
    var scene=StudioComposition(name:"Saved composition",camera:project.camera)
    scene.instances=[.init(name:"Linked cloth",sourceObjectID:cloth.id)]
    let output=FileManager.default.temporaryDirectory.appendingPathComponent("cycles-no-output-"+UUID().uuidString+".render")
    do {_ = try await store.cycles.renderShot(shot,to:output);XCTFail("Final output must reject unpersisted cloth.")}
    catch {XCTAssertTrue(error.localizedDescription.contains("unpersisted cloth"),error.localizedDescription)}
    do {_ = try await store.cycles.renderScene(scene,to:output,progress:{_ in});XCTFail("Scene output must reject unpersisted cloth.")}
    catch {XCTAssertTrue(error.localizedDescription.contains("unpersisted cloth"),error.localizedDescription)}
    XCTAssertEqual(store.cloth.preview.frame,frame);XCTAssertEqual(store.project,source)
    XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
  }
}

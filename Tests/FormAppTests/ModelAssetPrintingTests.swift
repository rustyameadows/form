import AppKit
import Foundation
import FormCore
import FormMeshAssets
import XCTest
@testable import FormApp

@MainActor final class ModelAssetPrintingTests:XCTestCase {
  private func cube(width:Double=20)->PrintMesh {
    let p:[Vector3]=[.init(0,0,0),.init(width,0,0),.init(width,30,0),.init(0,30,0),.init(0,0,40),.init(width,0,40),.init(width,30,40),.init(0,30,40)]
    let ids=[0,2,1,0,3,2,4,5,6,4,6,7,0,1,5,0,5,4,3,7,6,3,6,2,0,4,7,0,7,3,1,2,6,1,6,5]
    return .init(triangles:stride(from:0,to:ids.count,by:3).map{.init(p[ids[$0]],p[ids[$0+1]],p[ids[$0+2]])})
  }
  private func fixture(open:Bool=false)throws->(StudioStore,ProductObject,URL) {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),repository=try ProjectRepository(root:root),store=StudioStore(repository:repository,seedLibrary:false)
    var project=Project(name:"Visual source print test"),geometry=cube()
    if open {geometry.triangles.removeLast()}
    let source=try geometry.binarySTL(),document=try STLImporter.importData(source,fileName:"Original.stl",options:.init(sourceUnit:.millimeter)),normalized=try JSONEncoder().encode(document)
    let reference=MeshAssetReference(document:document,sourceAsset:"original.stl",normalizedAsset:"source.mesh.json",normalizedSHA256:MeshAssetHash.sha256(normalized)),assets=repository.url(for:project.id).appendingPathComponent("Assets")
    var object=try project.makeObject(recipeID:"importedMesh",parameters:["scalePercent":100]);object.meshAsset=reference;project.objects=[object];try repository.save(project)
    try source.write(to:assets.appendingPathComponent(reference.sourceAsset));try normalized.write(to:assets.appendingPathComponent(reference.normalizedAsset));try store.engine.open(project.id)
    addTeardownBlock { @MainActor in store.printing.resetForProjectChange();store.modelAssets.reset();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return(store,object,assets)
  }
  private func wait(_ printing:PrintCoordinator)async throws {for _ in 0..<400 {if !printing.preparing{return};try await Task.sleep(for:.milliseconds(10))};XCTFail("Source print preparation did not complete")}
  func testActualSourceMeshPreservesPhysicalScaleAndAppliesPrintRotationsOnce()throws {
    let(store,original,assets)=try fixture();var object=original,configuration=PrintConfiguration();object.parameters["scalePercent"]=150
    configuration.component=try XCTUnwrap(PrintMeshBuilder.sourceComponents(object)?.first);configuration.scalePercent=200;configuration.rotation.x=90
    let mesh=try PrintMeshBuilder.sourceMesh(object:object,assets:assets,configuration:configuration)
    XCTAssertEqual(mesh.triangles.count,12);XCTAssertEqual(mesh.size.x,60,accuracy:0.001);XCTAssertEqual(mesh.size.y,90,accuracy:0.001);XCTAssertEqual(mesh.size.z,120,accuracy:0.001)
    var placed=object;placed.position = .init(900,100,500);placed.rotation=120
    let same=try PrintMeshBuilder.sourceMesh(object:placed,assets:assets,configuration:configuration)
    XCTAssertEqual(same.size,mesh.size);XCTAssertNotNil(store.project)
  }
  func testOpenVisualMeshAndCompleteAssemblySelectionAreRejected()throws {
    let(_,object,assets)=try fixture(open:true);var configuration=PrintConfiguration()
    configuration.component=try XCTUnwrap(PrintMeshBuilder.sourceComponents(object)?.first)
    XCTAssertThrowsError(try PrintMeshBuilder.sourceMesh(object:object,assets:assets,configuration:configuration)) {error in XCTAssertTrue(error.localizedDescription.contains("boundary edges"))}
    configuration.component="Complete object"
    XCTAssertThrowsError(try PrintMeshBuilder.sourceMesh(object:object,assets:assets,configuration:configuration)) {error in XCTAssertTrue(error.localizedDescription.contains("one named source component"))}
  }
  func testDetachedPreparationIsStaleSafeAndAppearanceDoesNotInvalidateSource()async throws {
    let(store,object,_)=try fixture();store.printing.open(objectID:object.id)
    XCTAssertTrue(store.printing.preparing);XCTAssertNil(store.printing.mesh);try await wait(store.printing)
    XCTAssertNotNil(store.printing.mesh);XCTAssertNil(store.printing.validationError);XCTAssertTrue(store.printing.log.contains("Self-intersections"))
    let version=store.printing.meshVersion
    try store.engine.edit("Colorway"){$0.objects[0].meshAsset?.materialOverrides=[.init(materialIndex:0,colorHex:"#AABBDD")]};store.changed(save:false)
    XCTAssertFalse(store.printing.preparing);XCTAssertEqual(store.printing.meshVersion,version)
    store.printing.prepare();XCTAssertTrue(store.printing.preparing);store.printing.resetForProjectChange();try await Task.sleep(for:.milliseconds(100))
    XCTAssertNil(store.printing.mesh);XCTAssertNil(store.printing.preparedProjectID);XCTAssertFalse(store.printing.preparing)
  }
}

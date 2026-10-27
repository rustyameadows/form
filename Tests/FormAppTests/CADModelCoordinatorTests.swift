import AppKit
import Foundation
import XCTest
import FormCore
import FormCADModel
@testable import FormApp

@MainActor final class CADModelCoordinatorTests:XCTestCase {
  private func fixture()throws->StudioStore {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("CAD-native-tests-"+UUID().uuidString),repository=try ProjectRepository(root:root),project=Project(name:"Exact CAD test")
    try repository.save(project);let store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(project.id);store.showingHome=false
    addTeardownBlock{try? FileManager.default.removeItem(at:root)};return store
  }
  private func settled(_ job:CADModelReview)async throws {
    for _ in 0..<1000 {if !["preparing","publishing"].contains(job.state){return};try await Task.sleep(nanoseconds:20_000_000)}
    XCTFail("CAD job timed out: \(job.state)");throw FormError.invalid("CAD test timed out.")
  }
  func testNativeExactPreviewPublishesOnceAndUndoRetainsOriginalSourceAssets()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let before=try XCTUnwrap(store.project),job=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(job);try await settled(job)
    XCTAssertEqual(job.state,"ready",job.issue ?? "");XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    // Camera-only changes do not invalidate a design preview.
    store.engine.project!.camera.azimuth+=0.5
    try store.cad.commit(job);try await settled(job);XCTAssertEqual(job.state,"committed",job.issue ?? "");XCTAssertEqual(store.engine.undoStack.count,1)
    let object=try XCTUnwrap(store.project?.objects.first),model=try XCTUnwrap(object.cadModel);XCTAssertEqual(model.name,"Structured enclosure")
    let assets=store.repository.url(for:before.id).appendingPathComponent("Assets"),scene=try await Task.detached{try CADSceneAdapter.load(for:object,assets:assets)}.value
    XCTAssertEqual(scene.count,1);XCTAssertGreaterThan(scene[0].mesh.triangleCount,100)
    store.engine.undo();XCTAssertTrue(try XCTUnwrap(store.project).objects.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath:assets.appendingPathComponent(object.cadRepresentation!.components[0].brepAsset).path))
  }
  func testDesignChangeAndUnpreviewedDraftCannotCommit()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let job=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(job);try await settled(job);XCTAssertEqual(job.state,"ready",job.issue ?? "")
    try job.definition.setParameter("width",value:130);XCTAssertThrowsError(try store.cad.commit(job));XCTAssertTrue(store.project!.objects.isEmpty)
    job.definition=job.prepared!.definition
    try store.engine.edit("Changed source"){p in p.name="Changed design"}
    XCTAssertThrowsError(try store.cad.commit(job));XCTAssertTrue(store.project!.objects.isEmpty)
  }
  func testCancelledAndReopenedProjectCannotPublishLateWorker()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let job=try store.cad.begin(CADModelExamples.clockEnclosure());store.cad.preview(job);store.cad.cancel(job);try await Task.sleep(nanoseconds:100_000_000)
    XCTAssertEqual(job.state,"cancelled");XCTAssertTrue(store.project!.objects.isEmpty)
    let second=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(second);try await settled(second);XCTAssertEqual(second.state,"ready",second.issue ?? "")
    let id=store.project!.id;try store.engine.open(id);XCTAssertThrowsError(try store.cad.commit(second));XCTAssertTrue(store.project!.objects.isEmpty)
  }
  func testDisplayLoadsPreserveBodyOriginAndDetectCorruptExactSource()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let job=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(job);try await settled(job);try store.cad.commit(job);try await settled(job)
    var object=try XCTUnwrap(store.project?.objects.first);object.position = .init(15,25,35);object.rotation=90
    let assets=store.repository.url(for:store.project!.id).appendingPathComponent("Assets"),payload=try await Task.detached{try CADSceneAdapter.load(for:object,assets:assets)}.value
    XCTAssertEqual(payload[0].transform.translationMM.x,15);XCTAssertEqual(payload[0].transform.translationMM.y,25);XCTAssertEqual(payload[0].transform.translationMM.z,35)
    let source=assets.appendingPathComponent(object.cadRepresentation!.components[0].brepAsset);try Data("corrupt exact source".utf8).write(to:source)
    do{_ = try await Task.detached{try CADSceneAdapter.load(for:object,assets:assets)}.value;XCTFail("Corrupt exact source was displayed as verified CAD.")}catch{XCTAssertTrue(error.localizedDescription.contains("SHA-256"))}
  }
  func testMalformedCADArgumentsNeverFallBackToCreatingDefaultGeometry()throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let inputs:[[String:Any]]=[
      ["command":"create","object_id":"bad"],["command":"create","job_id":"bad"],["command":"create","job_id":UUID().uuidString],
      ["command":"parameter","name":"width","value":true],["command":"parameter","values":["width":true]],
      ["command":"parameter","values":"bad"],["command":"create","quality":true],["command":"create","definition":[:],"unexpected":1],
      ["command":"create","object_id":UUID().uuidString,"template":"vase"],["command":1]]
    for args in inputs{XCTAssertThrowsError(try store.cad.call("form_cad",args))}
    XCTAssertTrue(store.project!.objects.isEmpty);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testSharedCADFamilyEditsPreserveVariantAppearanceAndNewModelsDoNotOverlap()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let first=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(first);try await settled(first);try store.cad.commit(first);try await settled(first)
    let original=try XCTUnwrap(store.project?.objects.first)
    _ = try store.engine.call("form_duplicate_object",arguments:["object_id":original.id.uuidString,"mode":"variant","material_id":"aluminum"])
    let variant=try XCTUnwrap(store.project?.objects.last),oldPosition=variant.position
    var definition=try XCTUnwrap(original.cadModel);try definition.setParameter("width",value:150)
    let edit=try store.cad.begin(definition,target:original.id);store.cad.preview(edit);try await settled(edit);try store.cad.commit(edit);try await settled(edit)
    XCTAssertEqual(edit.state,"committed",edit.issue ?? "");let family=store.project!.objects
    XCTAssertEqual(family[0].cadModel,family[1].cadModel);XCTAssertEqual(family[1].materialID,"aluminum");XCTAssertEqual(family[1].position,oldPosition)
    let second=try store.cad.begin(CADModelExamples.vase());store.cad.preview(second);try await settled(second);try store.cad.commit(second);try await settled(second)
    let added=try XCTUnwrap(store.project?.objects.last);XCTAssertGreaterThan(added.position.x,oldPosition.x)
    XCTAssertGreaterThan(added.position.x+added.cadRepresentation!.minimum.x,family.map{$0.position.x+$0.cadRepresentation!.maximum.x}.max()!)
  }

  func testSTEPAssemblyReviewPreservesPinnedBytesHierarchyFaceColorsAndReopens()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FormCADKernelTests/Fixtures/colored-assembly.step")
    let job=try store.cad.begin(CADModelExamples.enclosure());job.sourceUpAxis="z";store.cad.preview(job,importURL:source);try await settled(job)
    XCTAssertEqual(job.state,"ready",job.issue ?? "");let ready=try XCTUnwrap(job.prepared),assembly=try XCTUnwrap(ready.definition.importedAssemblies?.first)
    XCTAssertEqual(ready.representation.components.count,3);XCTAssertEqual(assembly.nodes.count,5);XCTAssertEqual(assembly.sourceUpAxis,"z")
    XCTAssertTrue(assembly.nodes.filter{!$0.assembly}.allSatisfy{$0.outputFingerprint != nil})
    XCTAssertTrue(ready.scene.contains{$0.materials.count>1&&$0.materials.contains{$0.baseColor.z>0.8}})
    // Re-preview uses staged pinned bytes after the original read, not an absent project asset.
    store.cad.preview(job);try await settled(job);XCTAssertEqual(job.state,"ready",job.issue ?? "")
    try store.cad.commit(job);try await settled(job);XCTAssertEqual(job.state,"committed",job.issue ?? "")
    try store.engine.flush();let object=try XCTUnwrap(store.project?.objects.first),reopened=try store.repository.load(store.project!.id)
    XCTAssertEqual(reopened.objects.first?.cadModel,object.cadModel)
    let assets=store.repository.url(for:reopened.id).appendingPathComponent("Assets"),original=try Data(contentsOf:assets.appendingPathComponent(assembly.source.path));let expected=try Data(contentsOf:source);XCTAssertTrue(original==expected)
    let prepared=try await Task.detached{try CADSceneAdapter.prepare(for:object,assets:assets)}.value
    XCTAssertEqual(prepared.renderables.count,3)
    for payload in prepared.renderables{XCTAssertEqual(payload.mesh.parts.reduce(0){$0+$1.triangleIndices.count/3},payload.mesh.triangleCount)}
    var recolored=object;recolored.color="#CC3300";let appearance=CADSceneAdapter.renderables(prepared,for:recolored)
    XCTAssertEqual(appearance.map{$0.mesh.revision},prepared.renderables.map{$0.mesh.revision});XCTAssertTrue(appearance.allSatisfy{$0.materials.allSatisfy{$0.baseColor.x>0.7&&$0.baseColor.z==0}})
    let external=source.deletingLastPathComponent().appendingPathComponent("external-reference.step"),bad=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(bad,importURL:external);try await settled(bad);XCTAssertEqual(bad.state,"failed");XCTAssertEqual(store.project?.objects.count,1)
  }

}

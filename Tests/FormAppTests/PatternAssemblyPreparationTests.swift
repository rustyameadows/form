import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics
@testable import FormApp

@MainActor final class PatternAssemblyPreparationTests:XCTestCase {
  private func fixture()throws -> (StudioStore,URL,UUID) {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("assembly-preparation-\(UUID().uuidString)"),repository=try ProjectRepository(root:root)
    var (project,definition)=try PatternAssemblySamples.roundedPouch();let id=try project.addPatternAssembly(definition)
    try repository.save(project);let store=StudioStore(repository:repository,seedLibrary:false)
    try store.engine.open(project.id);store.showingHome=false;store.synchronizeScene();try store.cloth.activate(id)
    return(store,root,id)
  }
  func testActualNativeWorkerStopResumeAndAtomicReadinessKeepSourceCameraAndHistoryExact()async throws {
    let(store,root,_)=try fixture();defer{store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    let initial=store.cloth.preview.frame!,project=store.project!,undo=store.engine.undoStack,camera=store.scene!.camera,builds=store.scene!.geometryBuilds
    let file=store.repository.url(for:project.id).appendingPathComponent("Manifest.json"),bytes=try Data(contentsOf:file)
    let began=Date();try store.cloth.preview.run()
    while (store.cloth.preview.diagnostics?.preparation?.passes ?? 0)==0,Date().timeIntervalSince(began)<5 {try await Task.sleep(nanoseconds:2_000_000)}
    XCTAssertEqual(store.cloth.preview.diagnostics?.preparation?.status,.preparing)
    let stopBegan=Date();store.cloth.preview.stop();let stopMilliseconds=Date().timeIntervalSince(stopBegan)*1000,stopped=store.cloth.preview.frame!
    XCTAssertEqual(stopped.positionsMm,initial.positionsMm);XCTAssertNotNil(stopped.preparationCandidatePositionsMm)
    XCTAssertEqual(stopped.diagnostics.completedFrames,0);XCTAssertEqual(stopped.diagnostics.elapsedSeconds,0)
    try await Task.sleep(nanoseconds:80_000_000);XCTAssertEqual(store.cloth.preview.frame,stopped)
    try store.cloth.preview.run()
    // The debug solver is deliberately unoptimized; its full-size preparation
    // takes much longer than the separately measured release worker. This is a
    // lifecycle/convergence test, with the same pass/evaluation/readiness gates.
    #if DEBUG
    let preparationTimeoutSeconds=240.0
    #else
    let preparationTimeoutSeconds=30.0
    #endif
    let resumedAt=Date()
    while store.cloth.preview.diagnostics?.preparation?.status != .ready,Date().timeIntervalSince(resumedAt)<preparationTimeoutSeconds {
      if store.cloth.preview.diagnostics?.status == .failed {XCTFail(store.cloth.preview.diagnostics?.lastError ?? "Preparation failed");break}
      try await Task.sleep(nanoseconds:2_000_000)
    }
    store.cloth.preview.stop();let ready=store.cloth.preview.frame!
    guard ready.diagnostics.preparation?.status == .ready else {
      XCTFail("Preparation did not reach its unchanged readiness gate within the \(preparationTimeoutSeconds)s test watchdog: \(ready.diagnostics.preparation?.passes ?? 0) passes, \(ready.diagnostics.preparation?.evaluations ?? 0) evaluations.")
      return
    }
    XCTAssertEqual(ready.diagnostics.preparation?.status,.ready);XCTAssertNotEqual(ready.positionsMm,initial.positionsMm)
    XCTAssertNil(ready.preparationCandidatePositionsMm)
    XCTAssertLessThanOrEqual(ready.diagnostics.preparation!.maximumRelativeError,0.05);XCTAssertLessThanOrEqual(ready.diagnostics.preparation!.p95RelativeError,0.01)
    XCTAssertEqual(store.project,project);XCTAssertEqual(store.engine.undoStack,undo);XCTAssertEqual(store.scene!.camera,camera);XCTAssertEqual(store.scene!.geometryBuilds,builds);XCTAssertEqual(try Data(contentsOf:file),bytes)
    let worker=store.cloth.preview.maximumWorkerMilliseconds,publish=store.cloth.preview.maximumPublishMilliseconds
    store.cloth.preview.reset();XCTAssertEqual(store.cloth.preview.frame,initial)
    if let path=ProcessInfo.processInfo.environment["FORM_ASSEMBLY_PROOF_DIR"] {
      let report:[String:Any]=["preparation_wall_ms":Date().timeIntervalSince(began)*1000,"worker_max_ms":worker,"main_publication_max_ms":publish,"stop_call_ms":stopMilliseconds,"preparation":try jsonObject(ready.diagnostics.preparation),"source_camera_history_and_bytes_unchanged":true,"stop_stale_result_rejected":true,"reset_exact":true]
      try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path).appendingPathComponent("assembly-native-preparation-worker.json"))
    }
  }
  func testSourceUndoDuringActualPreparationRejectsTheOldWorker()async throws {
    let(store,root,id)=try fixture();defer{store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    let before=store.project!,initial=store.cloth.preview.frame!,began=Date()
    try store.cloth.preview.run()
    while (store.cloth.preview.diagnostics?.preparation?.passes ?? 0)==0,Date().timeIntervalSince(began)<5 {try await Task.sleep(nanoseconds:2_000_000)}
    try store.engine.edit("Assembly support pose") {project in
      let index=project.objects.firstIndex{$0.id==id}!
      var declaration=project.objects[index].patternAssembly!;declaration.panels[0].pose.originMm.x+=1
      try project.setPatternAssembly(declaration,for:id)
    }
    store.changed(save:false);store.synchronizeScene();store.undo()
    try await Task.sleep(nanoseconds:80_000_000)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.cloth.preview.frame,initial)
    XCTAssertFalse(store.cloth.preview.isRunning);XCTAssertEqual(store.cloth.preview.diagnostics?.preparation?.passes,0)
  }
  func testInsufficientPreparationBudgetBlocksPhysicalFramesAndKeepsSourceDisplay()throws {
    let(store,root,id)=try fixture();defer{store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    var declaration=store.project!.objects.first{$0.id==id}!.patternAssembly!
    declaration.preparation!.maximumPasses=1
    _ = try store.clothCall(["command":"configure","object_id":id.uuidString,"assembly":try jsonObject(declaration)],source:"Test")
    try store.cloth.activate(id);let source=store.cloth.preview.frame!.positionsMm,project=store.project!,undo=store.engine.undoStack
    XCTAssertThrowsError(try store.cloth.preview.stepImmediately())
    let failed=try XCTUnwrap(store.cloth.preview.frame)
    XCTAssertEqual(failed.diagnostics.status,.failed);XCTAssertEqual(failed.diagnostics.preparation?.status,.failed)
    XCTAssertEqual(failed.diagnostics.completedFrames,0);XCTAssertEqual(failed.diagnostics.elapsedSeconds,0)
    XCTAssertEqual(failed.positionsMm,source);XCTAssertNotNil(failed.preparationCandidatePositionsMm)
    XCTAssertThrowsError(try store.cloth.preview.run());XCTAssertEqual(store.project,project);XCTAssertEqual(store.engine.undoStack,undo)
    store.cloth.preview.reset();XCTAssertEqual(store.cloth.preview.diagnostics?.preparation?.status,.pending);XCTAssertNil(store.cloth.preview.diagnostics?.initialJoin)
  }
}

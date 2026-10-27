import AppKit
import FormCADModel
import FormCore
import Foundation
import XCTest
@testable import FormApp

@MainActor private final class StudioExternalCaptureGate {
  private var continuation:CheckedContinuation<Void,Never>?
  private(set) var entries=0
  func pauseFirst()async {
    entries+=1
    guard entries==1 else{return}
    await withCheckedContinuation{continuation=$0}
  }
  func release(){let pending=continuation;continuation=nil;pending?.resume()}
}

extension StudioShotEditingTests {
  func testQueuedCADCapturesKeepTheirOwnVisibilityLightingSurfacePixelsAndRecords()async throws {
    let store=try fixture()
    defer{store.cad.reset();store.engine.project=nil}
    let job=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(job)
    func settleCAD()async throws {
      for _ in 0..<1000 {
        if !["preparing","publishing"].contains(job.state){return}
        try await Task.sleep(nanoseconds:2_000_000)
      }
      throw FormError.invalid("CAD capture fixture did not finish its exact evaluation.")
    }
    try await settleCAD();XCTAssertEqual(job.state,"ready",job.issue ?? "")
    try store.cad.commit(job);try await settleCAD();XCTAssertEqual(job.state,"committed",job.issue ?? "")
    store.engine.project!.objects[0].color="#D72A2A"
    let cadIndex=try XCTUnwrap(store.project?.objects.firstIndex{$0.cadRepresentation != nil})
    store.engine.project!.objects[cadIndex].color="#2255CC"
    let project=try XCTUnwrap(store.project),assets=store.repository.url(for:project.id).appendingPathComponent("Assets"),historyCount=store.engine.undoStack.count
    var a=shot(store),b=shot(store)
    a.name="Warm original";a.lighting="classic-v1";a.surface="Warm paper";a.visibility = .init(mode:.objects,objectIDs:[project.objects[0].id])
    b.name="Graphite CAD";b.lighting="rim-v1";b.surface="Graphite";b.visibility = .init(mode:.objects,objectIDs:[project.objects[cadIndex].id])
    let firstShot=a,secondShot=b,digest=try project.studioDesignDigest()
    let expectedFirst=try StudioPNG.encode(try await StudioShotRenderer().render(project:project,shot:firstShot,assets:assets,preview:false),designDigest:digest)
    let expectedSecond=try StudioPNG.encode(try await StudioShotRenderer().render(project:project,shot:secondShot,assets:assets,preview:false),designDigest:digest)
    XCTAssertNotEqual(expectedFirst,expectedSecond)
    let gate=StudioExternalCaptureGate(),renderer=store.studioShots.renderer
    renderer.externalPreparationCheckpoint={await gate.pauseFirst()}
    defer{renderer.externalPreparationCheckpoint=nil;gate.release()}
    let firstFolder=store.repository.root.appendingPathComponent("Concurrent-warm.render"),secondFolder=store.repository.root.appendingPathComponent("Concurrent-graphite.render")
    let first=Task{try await store.studioShots.export(firstShot,to:firstFolder)}
    defer{first.cancel();gate.release()}
    for _ in 0..<1000 where gate.entries==0 {try await Task.sleep(nanoseconds:1_000_000)}
    XCTAssertEqual(gate.entries,1,"The first export must be paused inside its verified external CAD load.")
    // A cancelled queued preview must neither replace the active composition nor
    // keep the following export waiting after that composition completes.
    let cancelled=Task{try await renderer.renderResult(project:project,shot:secondShot,assets:assets,preview:true)}
    await Task.yield();cancelled.cancel()
    do{_ = try await cancelled.value;XCTFail("Cancelled queued preview unexpectedly rendered.")}catch{XCTAssertTrue(error is CancellationError)}
    var secondFinished=false
    let second=Task{defer{secondFinished=true};return try await store.studioShots.export(secondShot,to:secondFolder)}
    defer{second.cancel()}
    try await Task.sleep(nanoseconds:20_000_000)
    XCTAssertFalse(secondFinished)
    XCTAssertEqual(gate.entries,1,"A second capture must not change the cached scene while the first awaits CAD preparation.")
    gate.release()
    let firstPNG=try await first.value,secondPNG=try await second.value
    XCTAssertEqual(try Data(contentsOf:firstPNG),expectedFirst)
    XCTAssertEqual(try Data(contentsOf:secondPNG),expectedSecond)
    for (folder,definition,png) in [(firstFolder,firstShot,firstPNG),(secondFolder,secondShot,secondPNG)] {
      let raw=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("render.json"))) as! [String:Any]
      let recorded=try JSONDecoder().decode(StudioShot.self,from:JSONSerialization.data(withJSONObject:try XCTUnwrap(raw["shot"])))
      XCTAssertEqual(recorded,definition)
      XCTAssertEqual(raw["included_object_ids"] as? [String],definition.visibility.objectIDs.map(\.uuidString).sorted())
      XCTAssertEqual(raw["png_sha256"] as? String,StudioRenderFolder.hash(try Data(contentsOf:png)))
      XCTAssertEqual(raw["design_sha256"] as? String,digest)
    }
    XCTAssertEqual(store.project,project);XCTAssertEqual(store.engine.undoStack.count,historyCount)
    // Source changes invalidate the cached external placement/appearance even
    // though the exact mesh asset and this saved shot definition are unchanged.
    store.engine.project!.objects[cadIndex].position.x+=60
    store.engine.project!.objects[cadIndex].rotation+=35
    store.engine.project!.objects[cadIndex].materialID="aluminum"
    store.engine.project!.objects[cadIndex].color="#22AA44"
    let modified=try XCTUnwrap(store.project),modifiedDigest=try modified.studioDesignDigest()
    XCTAssertNotEqual(modifiedDigest,digest)
    let expectedModified=try StudioPNG.encode(try await StudioShotRenderer().render(project:modified,shot:secondShot,assets:assets,preview:false),designDigest:modifiedDigest)
    let modifiedFolder=store.repository.root.appendingPathComponent("Changed-CAD-source.render")
    let modifiedPNG=try await store.studioShots.export(secondShot,to:modifiedFolder)
    XCTAssertEqual(try Data(contentsOf:modifiedPNG),expectedModified)
    let modifiedRecord=try JSONSerialization.jsonObject(with:Data(contentsOf:modifiedFolder.appendingPathComponent("render.json"))) as! [String:Any]
    XCTAssertEqual(modifiedRecord["design_sha256"] as? String,modifiedDigest)
    XCTAssertEqual(store.project,modified);XCTAssertEqual(store.engine.undoStack.count,historyCount)
  }
}

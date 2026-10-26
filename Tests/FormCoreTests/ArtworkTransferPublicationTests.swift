import Foundation
import XCTest
@testable import FormCore

final class ArtworkTransferPublicationTests:XCTestCase {
  private struct Injected:Error {}
  private func folder()throws->URL {let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root}
  private func named(_ value:UInt8)->(String,Data) {let data=Data(repeating:value,count:64);return("image-"+ArtworkTransferBundle.digest(data)+".png",data)}
  func testExclusivePublicationRetryReuseAndOwnedStageCleanup()throws {
    let root=try folder(),(name,data)=named(1),stage=try ArtworkTransferPublication.prepare(directory:root,blobs:[name:data])
    try stage.publish([name:data]);stage.finish("committed");XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(name)),data)
    let retry=try ArtworkTransferPublication.prepare(directory:root,blobs:[name:data]);try retry.publish([name:data]);XCTAssertTrue(retry.published.isEmpty);XCTAssertEqual(retry.reused,[name]);retry.finish("committed")
    let files=try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent(stage.stageName).path);XCTAssertTrue(files.contains("intent.json"));XCTAssertFalse(files.contains(name))
  }
  func testMidPublicationForeignCollisionPreservesPriorAndRetainsExactRecoveryBytes()throws {
    let root=try folder(),pairs=[named(2),named(3)].sorted{$0.0<$1.0},blobs=Dictionary(uniqueKeysWithValues:pairs),foreign=Data("Foreign untouched".utf8)
    try foreign.write(to:root.appendingPathComponent("prior.png"));let stage=try ArtworkTransferPublication.prepare(directory:root,blobs:blobs)
    XCTAssertThrowsError(try stage.publish(blobs,beforeEach:{name,index in if index==1 {try foreign.write(to:root.appendingPathComponent(name))}})) {error in
      let failure=error as! ArtworkTransferPublicationFailure;XCTAssertEqual(failure.retained.map(\.name),[pairs[0].0]);XCTAssertEqual(failure.retained.map(\.bytes),[64])
    }
    XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(pairs[0].0)),pairs[0].1);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(pairs[1].0)),foreign);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("prior.png")),foreign)
  }
  func testForeignReplacementOfAlreadyPublishedPathIsNeverUnlinked()throws {
    let root=try folder(),pairs=[named(4),named(5)].sorted{$0.0<$1.0},blobs=Dictionary(uniqueKeysWithValues:pairs),replacement=Data("Replacement foreign file".utf8),stage=try ArtworkTransferPublication.prepare(directory:root,blobs:blobs)
    XCTAssertThrowsError(try stage.publish(blobs,beforeEach:{_,index in if index==1 {let first=root.appendingPathComponent(pairs[0].0);try FileManager.default.removeItem(at:first);try replacement.write(to:first);throw Injected()}})) {error in
      let failure=error as! ArtworkTransferPublicationFailure;XCTAssertTrue(failure.retained.isEmpty);XCTAssertEqual(failure.changedPublishedPaths,[pairs[0].0])
    }
    XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(pairs[0].0)),replacement)
  }
  func testStageWriteFailureAndAssetDirectoryReplacementDoNotTouchForeignPaths()throws {
    let root=try folder(),(name,data)=named(6);XCTAssertThrowsError(try ArtworkTransferPublication.prepare(directory:root,blobs:[name:data],beforeStage:{_ in throw Injected()}));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(name).path))
    let parent=try folder(),assets=parent.appendingPathComponent("Assets");try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    let stage=try ArtworkTransferPublication.prepare(directory:assets,blobs:[name:data]),moved=parent.appendingPathComponent("OldAssets");try FileManager.default.moveItem(at:assets,to:moved);try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true);try Data([99]).write(to:assets.appendingPathComponent(name))
    XCTAssertThrowsError(try stage.publish([name:data]));XCTAssertEqual(try Data(contentsOf:assets.appendingPathComponent(name)),Data([99]))
  }
  func testStaleDocumentAfterPublicationPreservesExactHistoryAndRecovery()throws {
    let root=try folder(),(name,data)=named(7),stage=try ArtworkTransferPublication.prepare(directory:root,blobs:[name:data])
    var source=Project(name:"Current");let object=try source.ensureCanvasWorkspace();let engine=OperationEngine(repository:try ProjectRepository(root:try folder()));engine.project=source
    var original=Project(name:"Copied");let copied=try original.ensureCanvasWorkspace();let element=ArtworkElement(kind:"rectangle",x:0,y:0);original.objects[0].artwork!.elements=[element]
    let bundle=try ArtworkTransferGraph.capture(project:original,objectID:copied.id,ids:[element.id],readAsset:{_,_ in Data()}),plan=try ArtworkTransferGraph.plan(bundle,into:source,objectID:object.id)
    try stage.publish([name:data]);engine.project!.name="Independent edit";let before=engine.project!,undo=engine.undoStack
    do {try engine.edit("Paste"){$0=try plan.applying(to:$0)};XCTFail("Expected stale rejection")}catch{let failure=stage.failure(error);XCTAssertEqual(failure.retained.map(\.name),[name])}
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack,undo);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(name)),data)
  }
  func testCleanupUsesRetainedPrivateDirectoryDespiteItsPublicNameBeingReplaced()throws {
    let root=try folder(),(name,data)=named(8),stage=try ArtworkTransferPublication.prepare(directory:root,blobs:[name:data])
    let stageURL=root.appendingPathComponent(stage.stageName),moved=root.appendingPathComponent("OwnedMovedStage")
    try FileManager.default.moveItem(at:stageURL,to:moved);try FileManager.default.createDirectory(at:stageURL,withIntermediateDirectories:true)
    let foreign=Data("Foreign replacement staging path".utf8);try foreign.write(to:stageURL.appendingPathComponent(name))
    stage.finish("cancelled")
    XCTAssertEqual(try Data(contentsOf:stageURL.appendingPathComponent(name)),foreign)
    XCTAssertFalse(FileManager.default.fileExists(atPath:moved.appendingPathComponent(name).path))
  }

}

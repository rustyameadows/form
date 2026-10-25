import Foundation
import XCTest
@testable import FormCore

final class ClothSessionTests:XCTestCase {
  private let project=UUID(),object=UUID()
  private func identity(_ revision:String="initial",project:UUID?=nil,object:UUID?=nil)->ClothSourceIdentity {
    .init(projectID:project ?? self.project,objectID:object ?? self.object,revision:revision)
  }
  private func study()throws -> ClothStudy {
    .init(mesh:try ClothMeshes.rectangle(widthMm:240,heightMm:200,columns:6,rows:5,areaDensityKgPerM2:0.2))
  }
  private func running()throws -> ClothSession {
    var session=ClothSession();try session.bind(identity(),study:study());try session.start();return session
  }
  func testPersistedDefinitionRoundTripsWithoutRuntimeAndSettingsChangeDigest()throws {
    var source=try study();let encoded=try JSONEncoder.form.encode(source),decoded=try JSONDecoder.form.decode(ClothStudy.self,from:encoded)
    XCTAssertEqual(decoded,source);XCTAssertEqual(try decoded.digest,try source.digest)
    let json=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
    XCTAssertEqual(Set(json.keys),["mesh","settings","colliders"])
    let digest=try source.digest;source.settings.warpComplianceMPerN *= 2;XCTAssertNotEqual(try source.digest,digest)
    let changed=try source.digest;source.mesh.uv[0].x += 0.01;XCTAssertNotEqual(try source.digest,changed)
    XCTAssertTrue(ClothStudy.unsupportedPrintReason.contains("open flexible surface"))
  }
  func testOnlyRequestedStepsAdvanceAndResultsCannotPublishTwice()throws {
    var session=try running();let initial=try XCTUnwrap(session.frame),job=try session.prepare(frames:3)
    XCTAssertEqual(session.frame,initial);XCTAssertTrue(session.hasPendingWork);XCTAssertThrowsError(try session.prepare())
    let result=job.compute();XCTAssertEqual(session.frame,initial)
    XCTAssertEqual(result.frame.diagnostics.completedFrames,3);XCTAssertTrue(session.accept(result));XCTAssertFalse(session.accept(result))
    let frame=session.frame
    for _ in 0..<100 {_ = session.frame}
    XCTAssertEqual(session.frame,frame);XCTAssertFalse(session.hasPendingWork)
  }
  func testStopAndResetRejectLateWorkWithoutResumingOrMoving()throws {
    var session=try running();let late=try session.prepare(frames:4).compute()
    session.stop();let stopped=session.frame;XCTAssertFalse(session.accept(late));XCTAssertEqual(session.frame,stopped)
    XCTAssertEqual(session.frame?.diagnostics.status,.stopped);XCTAssertThrowsError(try session.prepare())
    try session.start();_ = try session.step(frames:2)
    let resetLate=try session.prepare().compute();session.reset();XCTAssertFalse(session.accept(resetLate))
    XCTAssertEqual(session.frame?.positionsMm,session.mesh?.restPositionsMm);XCTAssertEqual(session.frame?.diagnostics.completedFrames,0)
  }
  func testChangedSourceSettingsProjectAndObjectInvalidateOutstandingWork()throws {
    var session=try running();let oldSource=try session.prepare().compute()
    XCTAssertTrue(try session.bind(identity("edited"),study:study()));XCTAssertFalse(session.accept(oldSource));XCTAssertEqual(session.frame?.diagnostics.status,.stopped)
    try session.start();let oldSettings=try session.prepare().compute();var changed=try study();changed.settings.friction=0.6
    XCTAssertTrue(try session.bind(identity("edited"),study:changed));XCTAssertFalse(session.accept(oldSettings))
    try session.start();let oldProject=try session.prepare().compute()
    XCTAssertTrue(try session.bind(identity("edited",project:UUID()),study:changed));XCTAssertFalse(session.accept(oldProject))
    try session.start();let oldObject=try session.prepare().compute()
    XCTAssertTrue(try session.bind(identity("edited",object:UUID()),study:changed));XCTAssertFalse(session.accept(oldObject))
  }
  func testUndoRestoresInitialStateAndInvalidatesAlreadyComputedFrame()throws {
    var session=try running();_ = try session.step(frames:5);let late=try session.prepare().compute()
    session.sourceHistoryChanged();XCTAssertFalse(session.accept(late))
    XCTAssertEqual(session.frame?.positionsMm,session.mesh?.restPositionsMm);XCTAssertEqual(session.frame?.diagnostics.completedFrames,0)
    XCTAssertEqual(session.frame?.diagnostics.status,.stopped)
    try session.start();_ = try session.step();XCTAssertEqual(session.frame?.diagnostics.completedFrames,1)
  }
  func testIdempotentBindingDoesNotResetAndInvalidReplacementRollsBack()throws {
    var session=try running();_ = try session.step(frames:2);let pending=try session.prepare().compute(),before=session.frame
    XCTAssertFalse(try session.bind(identity(),study:study()));XCTAssertEqual(session.frame,before);XCTAssertTrue(session.hasPendingWork)
    var bad=try study();bad.mesh.massesKg[0] = -1
    XCTAssertThrowsError(try session.bind(identity("bad"),study:bad));XCTAssertEqual(session.frame,before);XCTAssertTrue(session.hasPendingWork)
    XCTAssertTrue(session.accept(pending));XCTAssertEqual(session.frame?.diagnostics.completedFrames,3)
  }
  func testForeignResultsCannotPublishAndStaleResultDoesNotClearCurrentWork()throws {
    var a=try running(),b=try running();let first=try a.prepare().compute(),foreign=try b.prepare().compute()
    XCTAssertFalse(a.accept(foreign));XCTAssertTrue(a.hasPendingWork)
    a.reset();try a.start();let current=try a.prepare(frames:2).compute()
    XCTAssertFalse(a.accept(first));XCTAssertTrue(a.hasPendingWork);XCTAssertTrue(a.accept(current))
    let late=try a.prepare().compute();a.clear();XCTAssertFalse(a.accept(late));XCTAssertNil(a.frame);XCTAssertNil(a.source)
  }
  func testPinChangeRejectsPendingFrameAndResetRestoresDeclaredPins()throws {
    var session=try running();let late=try session.prepare().compute()
    try session.pin(3,toMm:.init(0,200,0));XCTAssertFalse(session.accept(late));XCTAssertEqual(session.frame?.positionsMm[3],.init(0,200,0))
    _ = try session.step();XCTAssertEqual(session.frame?.positionsMm[3],.init(0,200,0))
    session.reset();XCTAssertEqual(session.frame?.pinnedVertices,[]);XCTAssertEqual(session.frame?.positionsMm,session.mesh?.restPositionsMm)
  }
}

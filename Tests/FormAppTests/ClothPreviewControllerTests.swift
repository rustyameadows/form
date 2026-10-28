import XCTest
@testable import FormCore
@testable import FormApp

@MainActor final class ClothPreviewControllerTests:XCTestCase {
  private func source()->ClothSourceIdentity {.init(projectID:UUID(),objectID:UUID(),revision:"initial")}
  private func study()throws -> ClothStudy {.init(mesh:try ClothMeshes.rectangle(widthMm:240,heightMm:200,columns:6,rows:5,areaDensityKgPerM2:0.2))}
  func testManualStepPublishesActualFrameThenStaysStoppedAndResetRestoresSource()async throws {
    let controller=ClothPreviewController(),definition=try study(),identity=source()
    var observed:[ClothFrame]=[];controller.onFrame={_,frame in observed.append(frame)}
    try controller.bind(identity,study:definition);XCTAssertEqual(observed.count,1)
    try await controller.step(frames:3);XCTAssertEqual(controller.frame?.diagnostics.completedFrames,3)
    XCTAssertEqual(controller.frame?.diagnostics.status,.stopped);XCTAssertFalse(controller.isStepping)
    XCTAssertLessThan(controller.frame!.positionsMm[0].y,definition.mesh.restPositionsMm[0].y)
    let count=observed.count,frame=controller.frame
    for _ in 0..<50 {await Task.yield();_ = controller.diagnostics}
    XCTAssertEqual(observed.count,count);XCTAssertEqual(controller.frame,frame)
    XCTAssertFalse(try controller.bind(identity,study:definition));XCTAssertEqual(controller.frame,frame)
    controller.reset();XCTAssertEqual(controller.frame?.positionsMm,definition.mesh.restPositionsMm);XCTAssertEqual(controller.frame?.diagnostics.completedFrames,0)
  }
  func testRunStopsFromPublishedFrameAndDoesNotPublishLateWork()async throws {
    let controller=ClothPreviewController();try controller.bind(source(),study:study())
    let stopped=expectation(description:"Two actual frames then stop")
    controller.onFrame={_,frame in
      if frame.diagnostics.completedFrames==2,frame.diagnostics.status == .running {controller.stop();stopped.fulfill()}
    }
    try controller.run();await fulfillment(of:[stopped],timeout:3)
    let frozen=controller.frame;XCTAssertEqual(frozen?.diagnostics.completedFrames,2);XCTAssertEqual(frozen?.diagnostics.status,.stopped)
    for _ in 0..<100 {await Task.yield()}
    XCTAssertEqual(controller.frame,frozen)
  }
  func testProjectRebindDuringRunningPublicationCannotContinueOldRunner()async throws {
    let controller=ClothPreviewController(),newSource=source(),definition=try study()
    try controller.bind(source(),study:definition)
    let replaced=expectation(description:"Replace source after actual first frame")
    controller.onFrame={_,frame in
      if frame.diagnostics.completedFrames==1,frame.diagnostics.status == .running {
        do {try controller.bind(newSource,study:definition);replaced.fulfill()}catch {XCTFail(error.localizedDescription)}
      }
    }
    try controller.run();await fulfillment(of:[replaced],timeout:3)
    for _ in 0..<100 {await Task.yield()}
    XCTAssertEqual(controller.source,newSource);XCTAssertEqual(controller.frame?.positionsMm,definition.mesh.restPositionsMm)
    XCTAssertEqual(controller.frame?.diagnostics.completedFrames,0);XCTAssertEqual(controller.frame?.diagnostics.status,.stopped)
  }
  func testInvalidManualStepDoesNotChangeFrameOrBusyState()async throws {
    let controller=ClothPreviewController();try controller.bind(source(),study:study());let before=controller.frame
    do {try await controller.step(frames:0);XCTFail("Invalid request accepted")}catch {}
    XCTAssertEqual(controller.frame,before);XCTAssertFalse(controller.isStepping);XCTAssertFalse(controller.isRunning)
    controller.sourceHistoryChanged();XCTAssertEqual(controller.frame?.diagnostics.completedFrames,0)
    controller.clear();XCTAssertNil(controller.frame);XCTAssertNil(controller.diagnostics)
  }
}

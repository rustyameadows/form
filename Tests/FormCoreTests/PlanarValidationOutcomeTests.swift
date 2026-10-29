import Foundation
import XCTest
import FormCADModel
@testable import FormCore

@MainActor final class PlanarValidationOutcomeTests:XCTestCase {
  private func request(_ definition:PlanarConstructionDefinition=ConstructionCommands.example(),count:Int=3) -> PlanarConstructionValidationRequest {
    .init(projectID:UUID(),objectID:UUID(),sourceRevision:"isolated-source",definition:definition,fold:0,opening:0,
      cases:(0..<count).map{.init(name:"case-\($0)",values:["fold":Double($0)])})
  }
  func testCancelledGeometryCasesKeepEveryNameAndValueAndToolReturnsFailedEvidence() async throws {
    let input=request(),work=Task {try input.validateGeometryCases()};work.cancel()
    do{_ = try await work.value;XCTFail("Cancelled geometry cases passed")}
    catch let error as PlanarConstructionValidationInterrupted {
      XCTAssertEqual(error.reason,.cancelled);XCTAssertFalse(error.report.passed)
      XCTAssertEqual(error.report.cases.map(\.name),input.cases.map(\.name))
      XCTAssertEqual(error.report.cases.map(\.values),input.cases.map{input.caseValues($0)})
      XCTAssertTrue(error.report.cases.allSatisfy{$0.outcome == .notRun && !$0.passed})
    } catch {XCTFail("Expected a typed geometry interruption report, got \(error)")}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=Project(name:"Read-only cancelled cases")
    let result=try XCTUnwrap(engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(input.definition)]) as? [String:Any])
    let id=try XCTUnwrap(result["object_id"] as? String),before=engine.project,undo=engine.undoStack.count
    let tool=Task {try engine.call("form_construction",arguments:["command":"validate_cases","object_id":id,
      "cases":input.cases.map{["name":$0.name,"values":$0.values] as [String:Any]}])};tool.cancel()
    let raw=try await tool.value
    let report=try XCTUnwrap(raw as? [String:Any])
    XCTAssertEqual(report["passed"] as? Bool,false);XCTAssertEqual(report["interruption"] as? String,"cancelled")
    let cases=try XCTUnwrap(report["cases"] as? [[String:Any]])
    XCTAssertEqual(cases.compactMap{$0["name"] as? String},input.cases.map(\.name))
    XCTAssertEqual(cases.compactMap{$0["outcome"] as? String},["not_run","not_run","not_run"])
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,undo)
  }
  func testGeometryDeadlineRetainsCurrentAndUnattemptedCasesInsteadOfDroppingTheBatch() throws {
    let input=request()
    var ticks=[0.0,0,0,0,0.1].makeIterator(),last=0.0
    do {
      _ = try input.validateGeometryCases(maximumDurationSeconds:0.05,uptime:{
        if let next=ticks.next(){last=next};return last
      })
      XCTFail("The batch accepted work after its monotonic deadline")
    } catch let error as PlanarConstructionValidationInterrupted {
      XCTAssertEqual(error.reason,.budgetExceeded);XCTAssertEqual(error.report.interruption,.budgetExceeded);XCTAssertFalse(error.report.passed)
      XCTAssertEqual(error.report.cases.map(\.name),input.cases.map(\.name))
      XCTAssertEqual(error.report.cases.map(\.values),input.cases.map{input.caseValues($0)})
      XCTAssertEqual(error.report.cases.map(\.outcome),[.passed,.budgetExceeded,.notRun])
      XCTAssertFalse(try XCTUnwrap(error.report.cases[0].poses).isEmpty)
      XCTAssertFalse(try XCTUnwrap(error.report.cases[1].poses).isEmpty,"The active geometry result remains evidence even when it finishes after deadline")
      XCTAssertNil(error.report.cases[2].poses)
      XCTAssertEqual(error.report.sourceRevision,input.sourceRevision)
    } catch {XCTFail("Expected a typed deadline report, got \(error)")}
  }

}

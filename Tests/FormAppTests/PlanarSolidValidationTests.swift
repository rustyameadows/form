import Foundation
import XCTest
import FormCore
import FormCADModel
@testable import FormApp

@MainActor final class PlanarSolidValidationTests:XCTestCase {
  private actor Counter {var value=0;func next()->Int{value+=1;return value}}
  private final class Gate {
    var entered=false
    var visits=0
    let pauseAt:Int
    var continuation:CheckedContinuation<Void,Never>?
    init(pauseAt:Int=1){self.pauseAt=pauseAt}
    func wait() async {visits+=1;guard visits==pauseAt else{return};entered=true;await withCheckedContinuation{continuation=$0}}
    func release(){continuation?.resume();continuation=nil}
  }
  private func source(triangles:Bool=false) -> PlanarConstructionDefinition {
    let left:[CADExpressionPoint2]=triangles ? [.init(0,0),.init(20,0),.init(20,20)]
      : [.init(0,0),.init(40,0),.init(40,50),.init(0,50)]
    let right:[CADExpressionPoint2]=triangles ? [.init(20,0),.init(40,0),.init(20,20)]
      : [.init(40,0),.init(80,0),.init(80,50),.init(40,50)]
    let x=triangles ? 20.0:40.0,height=triangles ? 20.0:50.0
    return .init(name:"Authored stock-pair study",parameters:[
      .init("stock",triangles ? 0.5:0.4,0.1...1),.init("angle",180,0...180),
      .init("layer",0,0...2),.init("allowance",0,0...1000),.init("expectedGap",0,0...2)],
      size:.init(CADScalar(2*x),CADScalar(height)),stockThickness:"stock",
      panels:[.init(id:"a",name:"A",polygon:left),.init(id:"b",name:"B",polygon:right)],
      hinges:[.init(id:"crease",parentPanelID:"a",childPanelID:"b",start:.init(CADScalar(x),0),
        end:.init(CADScalar(x),CADScalar(height)),angleDegrees:"angle",layerOffsetMM:"layer")],rootPanelID:"a",
      connections:triangles ? nil:[.init(id:"anchor-contact",firstPanelID:"a",secondPanelID:"b",
        firstPoint:.init(20,25),secondPoint:.init(60,25),maximumGapMM:1)],
      solidChecks:[.init(id:"declared-interference",firstPanelID:"a",secondPanelID:"b",metric:.interference,
        relation:.lessThanOrEqual,value:"allowance",message:"Only the declared crease/glue allowance is permitted"),
        .init(id:"declared-gap",firstPanelID:"a",secondPanelID:"b",metric:.clearance,
          relation:.equal,value:"expectedGap",message:"Preserve the authored mating gap",tolerance:1e-6)])
  }
  private func fixture(triangles:Bool=false) throws -> (StudioStore,UUID) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("folded-solids-"+UUID().uuidString)
    let repository=try ProjectRepository(root:root)
    let store=StudioStore(repository:repository,seedLibrary:false)
    store.engine.project=Project(name:"Finite stock checks")
    let result=try XCTUnwrap(store.engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(source(triangles:triangles))]) as? [String:Any])
    let id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(result["object_id"] as? String)))
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    return (store,id)
  }
  private func request(_ store:StudioStore,_ id:UUID,cases:[[String:Any]]?=nil) throws -> PlanarConstructionValidationRequest {
    var args:[String:Any]=["command":"validate_cases","object_id":id.uuidString]
    if let cases{args["cases"]=cases}
    return try ConstructionCommands.validationRequest(project:try XCTUnwrap(store.project),arguments:args)
  }
  private func waitForGate(_ gate:Gate) async throws {
    for _ in 0..<3000 {if gate.entered{return};try await Task.sleep(nanoseconds:1_000_000)}
    XCTFail("Validation did not reach the controlled async checkpoint")
  }
  func testExactInterferenceFindsAnchorFalsePositiveAndContactRepairUsesOneSource() async throws {
    let (store,id)=try fixture()
    try store.engine.edit("Artwork"){p in p.objects[0].artwork = .init(background:"#FFFFFF",elements:[.init(kind:"text",x:5,y:8,text:"Same source")])}
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count,selection=store.engine.selection
    let input=try request(store,id,cases:[
      ["name":"overlapping","values":["layer":0]],
      ["name":"exact-contact","values":["layer":0.4]],
      ["name":"separated","values":["layer":0.7,"expectedGap":0.3]]])
    let report=try await PlanarSolidValidation.run(input)
    XCTAssertFalse(report.passed);XCTAssertEqual(report.cases.map(\.passed),[false,true,true])
    XCTAssertEqual(report.sourceRevision,input.sourceRevision)
    XCTAssertTrue(try XCTUnwrap(report.solidModel).contains("Only explicitly declared"))
    XCTAssertTrue(try XCTUnwrap(report.cases[0].connectionChecks).allSatisfy(\.passed),"Neutral anchors alone miss the physical overlap")
    let collision=try XCTUnwrap(report.cases[0].solidChecks?.first)
    XCTAssertEqual(collision.id,"declared-interference");XCTAssertEqual(collision.units,"mm3")
    XCTAssertEqual(collision.measured,800,accuracy:1e-6);XCTAssertFalse(collision.passed)
    XCTAssertEqual(collision.stockThicknessMM,0.4)
    XCTAssertEqual(try XCTUnwrap(report.cases[1].solidChecks?.first).measured,0,accuracy:1e-7)
    XCTAssertEqual(try XCTUnwrap(report.cases[2].solidChecks?.last).measured,0.3,accuracy:1e-6)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo);XCTAssertEqual(store.engine.selection,selection)
    _ = try store.engine.call("form_construction",arguments:["command":"parameter","object_id":id.uuidString,"values":["layer":0.4]])
    XCTAssertEqual(store.engine.undoStack.count,undo+1)
    let native=try await store.constructionValidationCallAsync(["command":"validate_cases","object_id":id.uuidString])
    XCTAssertEqual((native as? [String:Any])?["passed"] as? Bool,true)
    XCTAssertEqual(store.project?.objects[0].artwork,before.objects[0].artwork)
    try store.engine.flush();let reopened=try store.repository.load(before.id)
    XCTAssertEqual(reopened.objects,store.project?.objects)
    store.engine.undo();XCTAssertEqual(store.project?.objects,before.objects)
  }
  func testDeclaredHingeAllowanceAndUnrelatedTriangularTopologyCompose() async throws {
    let (store,id)=try fixture(triangles:true),before=store.project
    let report=try await PlanarSolidValidation.run(request(store,id,cases:[
      ["name":"overlap","values":["layer":0]],
      ["name":"contact","values":["layer":0.5]],
      ["name":"flat","values":["fold":0]],
      ["name":"allowed-crease","values":["angle":90,"allowance":2]]]))
    XCTAssertEqual(report.cases.map(\.passed),[false,true,true,true])
    XCTAssertEqual(try XCTUnwrap(report.cases[0].solidChecks?.first).measured,100,accuracy:1e-6)
    let crease=try XCTUnwrap(report.cases[3].solidChecks?.first)
    XCTAssertGreaterThan(crease.measured,0);XCTAssertLessThan(crease.measured,2)
    XCTAssertEqual(crease.required,2);XCTAssertTrue(crease.passed)
    XCTAssertEqual(store.project,before)
  }
  func testSupersedingSourceAndProjectChangesRejectLateExactReports() async throws {
    let (store,id)=try fixture(),coordinator=ConstructionValidationCoordinator(),gate=Gate()
    let first=try request(store,id)
    let old=Task {try await coordinator.validate(first,checkpoint:{await gate.wait()}){true}}
    try await waitForGate(gate)
    _ = try store.engine.call("form_construction",arguments:["command":"parameter","object_id":id.uuidString,"values":["layer":0.4]])
    coordinator.projectDidChange(store.project)
    let latest=try request(store,id)
    let report=try await coordinator.validate(latest){ConstructionCommands.validationSourceIsCurrent(latest,in:store.project)}
    XCTAssertTrue(report.passed);XCTAssertNotEqual(report.sourceRevision,first.sourceRevision)
    gate.release()
    do{_ = try await old.value;XCTFail("Superseded exact work was accepted")}catch is CancellationError{}catch{XCTFail("Expected cancellation, got \(error)")}
    let projectGate=Gate()
    let switched=Task {try await coordinator.validate(latest,checkpoint:{await projectGate.wait()}){true}}
    try await waitForGate(projectGate);coordinator.projectDidChange(Project(name:"Other project"));projectGate.release()
    do{_ = try await switched.value;XCTFail("Old project work was accepted")}catch is CancellationError{}catch{XCTFail("Expected cancellation, got \(error)")}
    do{_ = try await coordinator.validate(latest){false};XCTFail("Stale source was accepted")}catch{XCTAssertTrue(error.localizedDescription.contains("obsolete"))}
  }
  func testCancellationAndDeadlineCannotReturnSuccessfulChecks() async throws {
    let (store,id)=try fixture(),input=try request(store,id),before=store.project,undo=store.engine.undoStack.count
    let cancelled=Task {try await PlanarSolidValidation.run(input)};cancelled.cancel()
    do{_ = try await cancelled.value;XCTFail("Cancelled checks passed")}
    catch let error as PlanarConstructionValidationInterrupted {
      XCTAssertEqual(error.reason,.cancelled);XCTAssertFalse(error.report.passed)
      XCTAssertEqual(error.report.cases.map(\.name),input.cases.map(\.name))
      XCTAssertEqual(error.report.cases.map(\.outcome),[.notRun]);XCTAssertEqual(error.report.cases.first?.values,input.caseValues(input.cases[0]))
    } catch{XCTFail("Expected a typed partial report, got \(error)")}
    do {
      _ = try await PlanarSolidValidation.run(input,maximumDurationSeconds:0.2,checkpoint:{try await Task.sleep(nanoseconds:2_000_000_000)})
      XCTFail("Over-budget checks passed")
    } catch let error as PlanarConstructionValidationInterrupted {
      XCTAssertEqual(error.reason,.budgetExceeded);XCTAssertEqual(error.report.interruption,.budgetExceeded)
      XCTAssertFalse(error.report.passed);XCTAssertEqual(error.report.cases.map(\.name),input.cases.map(\.name))
      XCTAssertTrue(error.report.cases.allSatisfy{$0.outcome == .budgetExceeded || $0.outcome == .notRun})
      XCTAssertEqual(error.report.cases.first?.values,input.caseValues(input.cases[0]))
    } catch {XCTFail("Expected a typed deadline report, got \(error)")}
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
  }
  func testInterruptedBatchRetainsCompletedMeasurementsCurrentCaseAndEveryUnattemptedValue() async throws {
    let (store,id)=try fixture(),before=store.project,undo=store.engine.undoStack.count
    let input=try request(store,id,cases:[["name":"completed-contact","values":["layer":0.4]],
      ["name":"interrupted-overlap","values":["layer":0]],
      ["name":"unattempted-gap","values":["layer":0.7,"expectedGap":0.3]]])
    let gate=Gate(pauseAt:2),work=Task {try await PlanarSolidValidation.run(input,checkpoint:{await gate.wait()})}
    try await waitForGate(gate);work.cancel();gate.release()
    do{_ = try await work.value;XCTFail("Cancelled batch was accepted")}
    catch let error as PlanarConstructionValidationInterrupted {
      XCTAssertEqual(error.reason,.cancelled);XCTAssertFalse(error.report.passed)
      XCTAssertEqual(error.report.cases.map(\.outcome),[.passed,.cancelled,.notRun])
      XCTAssertEqual(error.report.cases.map(\.name),input.cases.map(\.name))
      XCTAssertEqual(error.report.cases.map(\.values),input.cases.map{input.caseValues($0)})
      XCTAssertEqual(try XCTUnwrap(error.report.cases[0].solidChecks?.first).measured,0,accuracy:1e-7)
      XCTAssertFalse(try XCTUnwrap(error.report.cases[1].poses).isEmpty,"The interrupted current case retains its prepared geometry evidence")
      XCTAssertNil(error.report.cases[2].poses)
    } catch {XCTFail("Expected a typed partial report, got \(error)")}
    let counter=Counter()
    do {
      _ = try await PlanarSolidValidation.run(input,maximumDurationSeconds:2,checkpoint:{
        if await counter.next()==2 {try await Task.sleep(nanoseconds:5_000_000_000)}
      })
      XCTFail("Over-budget batch was accepted")
    } catch let error as PlanarConstructionValidationInterrupted {
      XCTAssertEqual(error.reason,.budgetExceeded);XCTAssertFalse(error.report.passed)
      XCTAssertEqual(error.report.cases.map(\.outcome),[.passed,.budgetExceeded,.notRun])
      XCTAssertEqual(error.report.cases.map(\.values),input.cases.map{input.caseValues($0)})
      XCTAssertEqual(try XCTUnwrap(error.report.cases[0].solidChecks?.first).measured,0,accuracy:1e-7)
    } catch {XCTFail("Expected a typed deadline report, got \(error)")}
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
  }
}

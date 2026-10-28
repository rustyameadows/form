import Foundation
import XCTest
import FormCADModel
import FormCADModeling

final class CADAgentValidationTests: XCTestCase {
  func testSharedDerivedExpressionsResolveDependenciesAndRejectUnknownCyclesAndDomains() throws {
    let values=try CADDerivedExpressions.resolve(["size":"sqrt(area)","area":"width*width","offset":"sin(pi/2)*size"],variables:["width":12])
    XCTAssertEqual(values["offset"],12)
    XCTAssertEqual(try CADExpression.referencedNames(in:"sqrt(a-b)+min(width,height)"),["a","b","width","height"])
    XCTAssertThrowsError(try CADDerivedExpressions.resolve(["a":"b","b":"a"],variables:[:]))
    XCTAssertThrowsError(try CADDerivedExpressions.resolve(["a":"missing+1"],variables:[:]))
    XCTAssertThrowsError(try CADDerivedExpressions.resolve(["a":"sqrt(-1)"],variables:[:]))
    XCTAssertThrowsError(try CADDerivedExpressions.resolve(["width":"2"],variables:["width":1]))
    XCTAssertThrowsError(try CADDerivedExpressions.resolve(["a":"1/0"],variables:[:]))
    XCTAssertThrowsError(try CADExpression.referencedNames(in:"unknownFunction(width)"))
  }
  private func fixture() -> CADModelDefinition {
    let body = CADFeatureNode(name: "Body", operation: .init(.box,
      values: ["width": "width", "height": 30, "depth": 40]))
    let wall = CADFeatureNode(name: "Open wall", operation: .init(.shell, inputs: [body.id],
      values: ["thickness": "wall"],
      selection: .faceAtCenter(point: .init("width/2", 30, 20), tolerance: 1e-5)))
    return .init(name: "Authored open enclosure", parameters: [
      .init("width", 80, 40...160), .init("wall", 3, 1...20)
    ], features: [body, wall], outputs: [wall.id], requirements: [
      .init(id: "wall-fits", lhs: "wall*2", relation: .lessThan, rhs: "min(width,30)",
        message: "The wall must fit inside the enclosure.")
    ])
  }

  func testConventionalMathIsBoundedAndDomainChecked() throws {
    XCTAssertEqual(try CADExpression.evaluate("sin(radians(30))*20", variables: [:]), 10, accuracy: 1e-10)
    XCTAssertEqual(try CADExpression.evaluate("max(2,min(width,12))", variables: ["width": 25]), 12)
    XCTAssertEqual(try CADExpression.evaluate("clamp(-5,2,10)+sqrt(pow(3,2)+16)", variables: [:]), 7)
    XCTAssertEqual(try CADExpression.evaluate("degrees(atan2(1,1))", variables: [:]), 45, accuracy: 1e-10)
    for value in ["sqrt(-1)", "acos(2)", "pow(10,100)", "clamp(2,5,1)", "min(1)", "abs(1,2)", "exec(1)"] {
      XCTAssertThrowsError(try CADExpression.evaluate(value, variables: [:]), value)
    }
    // Parameter names that happen to be math names retain their old meaning.
    XCTAssertEqual(try CADExpression.evaluate("min+1", variables: ["min": 2]), 3)
  }

  func testSavedRequirementsRejectUnsupportedReadersAndExplainFailedRelation() throws {
    let model = fixture()
    XCTAssertEqual(model.version, 2)
    let data = try JSONEncoder().encode(model)
    XCTAssertEqual(try JSONDecoder().decode(CADModelDefinition.self, from: data), model)
    var invalid = model
    try invalid.setParameter("wall", value: 20)
    XCTAssertNoThrow(try invalid.validatedOrder(checkRequirements: false), "A repairable draft may violate a valid relationship.")
    do {
      _ = try invalid.validatedOrder(); XCTFail("An invalid wall relationship passed.")
    } catch let failure as CADRequirementFailure {
      XCTAssertEqual(failure.requirementID, "wall-fits")
      XCTAssertEqual(failure.lhs, 40); XCTAssertEqual(failure.rhs, 30)
      XCTAssertEqual(failure.parameterValues["wall"], 20)
    }
    invalid.version = 1
    XCTAssertThrowsError(try invalid.validatedOrder())
    var legacy = model
    legacy.requirements = nil; legacy.version = 1
    XCTAssertNoThrow(try legacy.validatedOrder())
  }

  func testParameterCasesFindBoundaryFailuresAndDoNotReplaceAcceptedModel() async throws {
    let model = fixture(), evaluator = CADModelEvaluator()
    let accepted = try await evaluator.evaluate(model)
    let report = try await CADParameterValidation.run(model: model, cases: [
      .init(name: "narrow-valid", values: ["width": 40, "wall": 4]),
      .init(name: "thick-invalid", values: ["width": 40, "wall": 20])
    ])
    XCTAssertFalse(report.allPassed)
    XCTAssertEqual(report.cases.map(\.passed), [true, false])
    XCTAssertEqual(report.cases[1].requirementID, "wall-fits")
    XCTAssertEqual(report.cases[1].values["wall"], 20)
    XCTAssertEqual(report.cases[0].measurements.count, 1)
    XCTAssertTrue(report.cases[0].measurements[0].info.closed)
    let retained = await evaluator.lastValid(modelID: model.id)
    XCTAssertEqual(retained?.revisionHash, accepted.revisionHash)
    XCTAssertEqual(retained?.definition, model)
    let repaired = try await CADParameterValidation.run(model: model, cases: [
      .init(name: "thick-repaired", values: ["width": 40, "wall": 14])
    ])
    XCTAssertTrue(repaired.allPassed)
    XCTAssertEqual(repaired.sourceRevision, accepted.revisionHash)
    let encoded = try JSONEncoder().encode(report)
    XCTAssertFalse(try JSONDecoder().decode(CADParameterValidationReport.self, from: encoded).allPassed)
  }

  func testExtremaAreDeterministicBoundedAndCancellationIsNotSuccess() async throws {
    let model = fixture()
    let cases = try CADParameterValidation.expandedCases(model: model, cases: [], includeExtrema: true)
    XCTAssertEqual(cases.map(\.name), ["default", "width.minimum", "width.maximum", "wall.minimum", "wall.maximum"])
    XCTAssertThrowsError(try CADParameterValidation.expandedCases(model: model, cases: [], includeExtrema: true, maximumCases: 2))
    XCTAssertThrowsError(try CADParameterValidation.expandedCases(model: model, cases: [
      .init(name: "duplicate", values: [:]), .init(name: "duplicate", values: ["wall": 5])
    ]))
    let task = Task { try await CADParameterValidation.run(model: model, cases: [], includeExtrema: true) }
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled validation returned success.") }
    catch is CancellationError {} catch { XCTFail("Cancellation must stay distinguishable: \(error)") }
  }

  func testAuthoredFaceDatumSurvivesDimensionsAndMissingTargetRequiresReview() async throws {
    var model = fixture()
    let evaluator = CADModelEvaluator()
    let first = try await evaluator.evaluate(model)
    XCTAssertTrue(first.durationMS >= 0)
    XCTAssertTrue(first.features.allSatisfy { $0.durationMS >= 0 })
    try model.setParameter("width", value: 100)
    let wider = try await evaluator.evaluate(model)
    XCTAssertEqual(wider.outputs[model.outputs[0]]!.info.size.x, 100, accuracy: 1e-6)
    model.features[1].operation.selection = .faceAtCenter(point: .init(0, 0, 0), tolerance: 1e-5)
    do { _ = try await evaluator.evaluate(model); XCTFail("A missing face datum silently retargeted.") }
    catch let error as CADModelEvaluationFailure {
      XCTAssertEqual(error.featureID, model.features[1].id)
      XCTAssertTrue(error.message.contains("0 faces"))
      XCTAssertEqual(error.parameterValues["width"], 100)
      XCTAssertEqual(error.resolvedValues["thickness"], 3)
      XCTAssertEqual(error.previousValidRevisionHash, wider.revisionHash)
    }
  }

  func testStraightBoundingPlaneEdgesRemainSemanticAfterResize() async throws {
    let base = CADFeatureNode(name: "Box", operation: .init(.box,
      values: ["width": "width", "height": 30, "depth": 40]))
    let finish = CADFeatureNode(name: "Upper edges", operation: .init(.fillet,
      inputs: [base.id], values: ["radius": 1], selection: .straightEdgesAtMaximum(axis: "y")))
    var model = CADModelDefinition(name: "Semantic finish", parameters: [.init("width", 80, 60...120)],
      features: [base, finish], outputs: [finish.id])
    let evaluator = CADModelEvaluator()
    _ = try await evaluator.evaluate(model)
    try model.setParameter("width", value: 100)
    let changed = try await evaluator.evaluate(model)
    XCTAssertTrue(changed.outputs[finish.id]!.info.closed)
    XCTAssertEqual(changed.outputs[finish.id]!.info.size.x, 100, accuracy: 1e-6)
  }

  func testSavedGeometryRequirementsMeasureActualOutputsAndRetainPreviousResultOnFailure() async throws {
    let body = CADFeatureNode(name: "Body", operation: .init(.box,
      values: ["width": "width", "height": 10, "depth": 20]))
    let other = CADFeatureNode(name: "Mating body", operation: .init(.transform,
      inputs: [body.id], matrix: [1,0,0,"width+gap",0,1,0,0,0,0,1,0,0,0,0,1]))
    var model = CADModelDefinition(name: "Measured fit", parameters: [
      .init("width", 40, 20...80), .init("gap", 3, 1...6)
    ], features: [body, other], outputs: [body.id, other.id], outputRequirements: [
      .init(id: "body-width", outputID: body.id, metric: .width, relation: .equal,
        value: "width", message: "Body width must match its parameter.", tolerance: 1e-6),
      .init(id: "one-solid", outputID: body.id, metric: .solids, relation: .equal,
        value: 1, message: "Body must remain one solid."),
      .init(id: "mating-gap", outputID: body.id, otherOutputID: other.id,
        metric: .clearance, relation: .equal, value: "gap",
        message: "The mating clearance must match the gap.", tolerance: 1e-6),
      .init(id: "no-interference", outputID: body.id, otherOutputID: other.id,
        metric: .interference, relation: .lessThanOrEqual, value: 0,
        message: "The parts must not interfere.")
    ])
    XCTAssertEqual(model.version, 2)
    let evaluator = CADModelEvaluator()
    let valid = try await evaluator.evaluate(model)
    XCTAssertEqual(valid.checks.count, 4)
    XCTAssertEqual(valid.checks.first(where: { $0.id == "mating-gap" })!.measured, 3, accuracy: 1e-6)
    let report = try await CADParameterValidation.run(model: model, cases: [
      .init(name: "wide-gap", values: ["width": 80, "gap": 6])
    ])
    XCTAssertTrue(report.allPassed)
    XCTAssertEqual(report.cases[0].checks.count, 4)
    model.outputRequirements![2].value = "gap+1"
    do { _ = try await evaluator.evaluate(model); XCTFail("An incorrect expected clearance passed.") }
    catch let error as CADModelEvaluationFailure {
      XCTAssertEqual(error.requirementID, "mating-gap")
      XCTAssertEqual(error.resolvedValues["measured"]!, 3, accuracy: 1e-6)
      XCTAssertEqual(error.resolvedValues["required"], 4)
      XCTAssertEqual(error.previousValidRevisionHash, valid.revisionHash)
    }
    let retained = await evaluator.lastValid(modelID: model.id)
    XCTAssertEqual(retained?.revisionHash, valid.revisionHash)
  }

  func testAmbiguousAuthoredDatumNeverChoosesOneOfTwoMatchingFaces() async throws {
    let body = CADFeatureNode(name: "Body", operation: .init(.box,
      values: ["width": 20, "height": 30, "depth": 40]))
    let adjacent = CADFeatureNode(name: "Adjacent body", operation: .init(.transform,
      inputs: [body.id], matrix: [1,0,0,20,0,1,0,0,0,0,1,0,0,0,0,1]))
    let assembly = CADFeatureNode(name: "Touching assembly", operation: .init(.assembly,
      inputs: [body.id, adjacent.id]))
    var model = CADModelDefinition(name: "Ambiguous face", features: [body, adjacent, assembly], outputs: [assembly.id])
    let evaluator = CADModelEvaluator()
    let valid = try await evaluator.evaluate(model)
    let opening = CADFeatureNode(name: "Ambiguous opening", operation: .init(.shell,
      inputs: [assembly.id], values: ["thickness": 1],
      selection: .faceAtCenter(point: .init(20, 15, 20), tolerance: 1e-5)))
    model.features.append(opening); model.outputs = [opening.id]
    do { _ = try await evaluator.evaluate(model); XCTFail("Ambiguous faces were silently resolved.") }
    catch let failure as CADModelEvaluationFailure {
      XCTAssertTrue(failure.message.contains("2 faces"))
      XCTAssertEqual(failure.featureID, opening.id)
      XCTAssertEqual(failure.previousValidRevisionHash, valid.revisionHash)
    }
  }
}

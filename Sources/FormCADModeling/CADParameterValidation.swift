import Foundation
import FormCADModel
import FormCADKernel

public struct CADParameterCase: Codable, Equatable, Sendable {
  public var name: String
  public var values: [String: Double]
  public init(name: String, values: [String: Double]) { self.name = name; self.values = values }
}

public struct CADParameterMeasurement: Codable, Sendable {
  public var outputID: UUID
  public var info: CADShapeInfo
}

public struct CADParameterCaseResult: Codable, Sendable {
  public var name: String
  public var values: [String: Double]
  public var passed: Bool
  public var issue: String?
  public var featureID: UUID?
  public var requirementID: String?
  public var measurements: [CADParameterMeasurement]
  public var durationMS: Double
  public var checks: [CADGeometryCheckResult] = []
  public var surfaceIssues: [CADSurfaceResolutionIssue] = []
}

public struct CADParameterValidationReport: Codable, Sendable {
  public var modelID: UUID
  public var sourceRevision: String
  public var cases: [CADParameterCaseResult]
  public var allPassed: Bool
  public var durationMS: Double
  public var units: String = "mm"
  public var coverage: String = "Finite named parameter cases; not a proof over the continuous parameter domain."
}

/// Independent evaluation state: validation cannot replace the user's accepted
/// shapes, source model, review jobs, history or geometric cache.
public enum CADParameterValidation {
  public static func expandedCases(model: CADModelDefinition, cases: [CADParameterCase],
                                   includeExtrema: Bool = false, maximumCases: Int = 64) throws -> [CADParameterCase] {
    guard (1...128).contains(maximumCases), cases.count <= maximumCases,
          Set(cases.map(\.name)).count == cases.count else {
      throw CADModelError("Use 1–128 parameter cases with unique names and a matching case budget.")
    }
    for item in cases {
      guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            item.name.utf8.count <= 128, item.values.count <= 128,
            item.values.allSatisfy({ CADExpression.validName($0.key) && $0.value.isFinite && abs($0.value) <= 1e7 }) else {
        throw CADModelError("Parameter cases require bounded names and finite named values.")
      }
    }
    guard model.parameters.count <= 128 else { throw CADModelError("Parameter-case generation exceeds the model's parameter budget.") }
    var result = cases
    func key(_ values: [String: Double]) -> String {
      var resolved = model.parameterValues
      for (name, value) in values { resolved[name] = value }
      return resolved.keys.sorted().map { "\($0)=\(resolved[$0]!)" }.joined(separator: ";")
    }
    var seen = Set(cases.map { key($0.values) })
    var names = Set(cases.map(\.name))
    func appendGenerated(_ name: String, _ values: [String: Double]) throws {
      guard seen.insert(key(values)).inserted else { return }
      var unique = name
      while names.contains(unique) { unique = "generated." + unique }
      guard unique.utf8.count <= 128 else { throw CADModelError("Generated parameter-case name exceeds its bound.") }
      names.insert(unique); result.append(.init(name: unique, values: values))
      guard result.count <= maximumCases else {
        throw CADModelError("Parameter extrema exceed the case budget. Provide selected explicit combinations or increase maximum_cases up to 128.")
      }
    }
    if includeExtrema {
      try appendGenerated("default", [:])
      for parameter in model.parameters {
        try appendGenerated(parameter.name + ".minimum", [parameter.name: parameter.minimum])
        try appendGenerated(parameter.name + ".maximum", [parameter.name: parameter.maximum])
      }
    }
    if result.isEmpty { result = [.init(name: "default", values: [:])] }
    return result
  }

  public static func run(model: CADModelDefinition, cases: [CADParameterCase],
                         includeExtrema: Bool = false, maximumCases: Int = 64,
                         resourcesAt: URL? = nil, maximumDurationSeconds: Double = 60) async throws -> CADParameterValidationReport {
    guard maximumDurationSeconds.isFinite, (0.01...300).contains(maximumDurationSeconds) else {
      throw CADModelError("Parameter validation requires a finite time budget from 0.01 to 300 seconds.")
    }
    let selected = try expandedCases(model: model, cases: cases, includeExtrema: includeExtrema, maximumCases: maximumCases)
    let revision = try CADModelEvaluator.revisionHash(model)
    let evaluator = CADModelEvaluator(maximumCachedModels: 1, topologyCacheBudgetBytes: 128 * 1024 * 1024)
    let started = ProcessInfo.processInfo.systemUptime
    var reports: [CADParameterCaseResult] = []
    for item in selected {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime - started < maximumDurationSeconds else {
        throw CADModelError("Parameter validation exceeded its time budget; the remaining cases were not evaluated.")
      }
      let caseStarted = ProcessInfo.processInfo.systemUptime
      var draft = model
      var values = model.parameterValues
      for (name, value) in item.values { values[name] = value }
      do {
        for name in item.values.keys.sorted() { try draft.setParameter(name, value: item.values[name]!) }
        let evaluated = try await evaluator.evaluate(draft, resourcesAt: resourcesAt)
        try Task.checkCancellation()
        let measurements = draft.outputs.compactMap { id in
          evaluated.outputs[id].map { CADParameterMeasurement(outputID: id, info: $0.info) }
        }
        reports.append(.init(name: item.name, values: values, passed: evaluated.surfaceIssues.isEmpty,
          issue: evaluated.surfaceIssues.isEmpty ? nil:evaluated.surfaceIssues.map(\.message).joined(separator:"; "),
          measurements: measurements, durationMS: (ProcessInfo.processInfo.systemUptime - caseStarted) * 1000,
          checks: evaluated.checks, surfaceIssues: evaluated.surfaceIssues))
      } catch is CancellationError {
        await evaluator.clear(); throw CancellationError()
      } catch {
        let failure = error as? CADModelEvaluationFailure
        let requirement = error as? CADRequirementFailure
        reports.append(.init(name: item.name, values: values, passed: false,
          issue: error.localizedDescription, featureID: failure?.featureID,
          requirementID: failure?.requirementID ?? requirement?.requirementID,
          measurements: [], durationMS: (ProcessInfo.processInfo.systemUptime - caseStarted) * 1000))
      }
      guard ProcessInfo.processInfo.systemUptime - started <= maximumDurationSeconds else {
        await evaluator.clear()
        throw CADModelError("Parameter validation exceeded its time budget; no complete report was accepted.")
      }
    }
    await evaluator.clear()
    return .init(modelID: model.id, sourceRevision: revision, cases: reports,
      allPassed: reports.allSatisfy(\.passed), durationMS: (ProcessInfo.processInfo.systemUptime - started) * 1000)
  }
}

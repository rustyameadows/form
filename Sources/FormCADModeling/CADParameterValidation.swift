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
  public var outcome: ParameterCaseOutcome? = nil
}

public struct CADParameterValidationReport: Codable, Sendable {
  public var modelID: UUID
  public var sourceRevision: String
  public var cases: [CADParameterCaseResult]
  public var allPassed: Bool
  public var durationMS: Double
  public var units: String = "mm"
  public var coverage: String = "Finite named parameter cases; not a proof over the continuous parameter domain."
  public var interruption: ParameterValidationInterruption? = nil
}

/// Fail closed while retaining every declared case, including interrupted and
/// unattempted work. Tool adapters expose this report on the failed request.
public struct CADParameterValidationInterrupted: Error, LocalizedError, Sendable {
  public let report: CADParameterValidationReport
  public let reason: ParameterValidationInterruption
  public var errorDescription: String? { reason.message }
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
    let started = ProcessInfo.processInfo.systemUptime
    let worker = Task.detached(priority: .userInitiated) {
      try await evaluate(model: model, selected: selected, revision: revision,
        resourcesAt: resourcesAt, maximumDurationSeconds: maximumDurationSeconds, started: started)
    }
    // Cancellation reaches the evaluator's existing kernel progress handler.
    // Await its terminal result so no timed-out geometry keeps accumulating.
    let deadline = Task.detached {
      try await Task.sleep(nanoseconds: UInt64(maximumDurationSeconds * 1_000_000_000))
      worker.cancel()
    }
    defer { deadline.cancel() }
    return try await withTaskCancellationHandler { try await worker.value }
      onCancel: { worker.cancel() }
  }

  private static func evaluate(model: CADModelDefinition, selected: [CADParameterCase], revision: String,
    resourcesAt: URL?, maximumDurationSeconds: Double, started: Double) async throws -> CADParameterValidationReport {
    let evaluator = CADModelEvaluator(maximumCachedModels: 1, topologyCacheBudgetBytes: 128 * 1024 * 1024)
    var reports: [CADParameterCaseResult] = []
    func interruption() -> ParameterValidationInterruption? {
      if ProcessInfo.processInfo.systemUptime - started >= maximumDurationSeconds { return .budgetExceeded }
      return Task.isCancelled ? .cancelled : nil
    }
    func resolvedValues(_ item: CADParameterCase) -> [String:Double] {
      model.parameterValues.merging(item.values) { _, new in new }
    }
    func aborted(_ reason: ParameterValidationInterruption, active: CADParameterCase?, activeDurationMS: Double = 0) -> CADParameterValidationInterrupted {
      var all = reports
      if let active {
        all.append(.init(name: active.name, values: resolvedValues(active), passed: false,
          issue: reason.message, measurements: [], durationMS: activeDurationMS, outcome: reason.caseOutcome))
      }
      for item in selected.dropFirst(all.count) {
        all.append(.init(name: item.name, values: resolvedValues(item), passed: false,
          issue: "Not evaluated because the batch was interrupted.", measurements: [], durationMS: 0, outcome: .notRun))
      }
      return .init(report: .init(modelID: model.id, sourceRevision: revision, cases: all,
        allPassed: false, durationMS: (ProcessInfo.processInfo.systemUptime - started) * 1000,
        interruption: reason), reason: reason)
    }
    for item in selected {
      if let reason = interruption() { await evaluator.clear(); throw aborted(reason, active: nil) }
      let caseStarted = ProcessInfo.processInfo.systemUptime
      var draft = model
      var values = model.parameterValues
      for (name, value) in item.values { values[name] = value }
      do {
        for name in item.values.keys.sorted() { try draft.setParameter(name, value: item.values[name]!) }
        let evaluated = try await evaluator.evaluate(draft, resourcesAt: resourcesAt)
        if let reason = interruption() { throw aborted(reason, active: item,
          activeDurationMS: (ProcessInfo.processInfo.systemUptime - caseStarted) * 1000) }
        let measurements = draft.outputs.compactMap { id in
          evaluated.outputs[id].map { CADParameterMeasurement(outputID: id, info: $0.info) }
        }
        reports.append(.init(name: item.name, values: values, passed: evaluated.surfaceIssues.isEmpty,
          issue: evaluated.surfaceIssues.isEmpty ? nil:evaluated.surfaceIssues.map(\.message).joined(separator:"; "),
          measurements: measurements, durationMS: (ProcessInfo.processInfo.systemUptime - caseStarted) * 1000,
          checks: evaluated.checks, surfaceIssues: evaluated.surfaceIssues,
          outcome: evaluated.surfaceIssues.isEmpty ? .passed : .failed))
      } catch let error as CADParameterValidationInterrupted {
        await evaluator.clear(); throw error
      } catch {
        if let reason = interruption() {
          await evaluator.clear()
          throw aborted(reason, active: item, activeDurationMS: (ProcessInfo.processInfo.systemUptime - caseStarted) * 1000)
        }
        let failure = error as? CADModelEvaluationFailure
        let requirement = error as? CADRequirementFailure
        reports.append(.init(name: item.name, values: values, passed: false,
          issue: error.localizedDescription, featureID: failure?.featureID,
          requirementID: failure?.requirementID ?? requirement?.requirementID,
          measurements: [], durationMS: (ProcessInfo.processInfo.systemUptime - caseStarted) * 1000, outcome: .failed))
      }
      if let reason = interruption() {
        await evaluator.clear()
        throw aborted(reason, active: nil)
      }
    }
    await evaluator.clear()
    return .init(modelID: model.id, sourceRevision: revision, cases: reports,
      allPassed: reports.allSatisfy(\.passed), durationMS: (ProcessInfo.processInfo.systemUptime - started) * 1000)
  }
}

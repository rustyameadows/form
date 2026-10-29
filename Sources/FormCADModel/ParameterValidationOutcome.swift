import Foundation

/// Shared case outcomes for exact, folded and sewn model validation. An
/// interrupted case is distinct from a geometric failure and from work that
/// never started.
public enum ParameterCaseOutcome: String, Codable, Sendable {
  case passed, failed, cancelled
  case budgetExceeded = "budget_exceeded"
  case notRun = "not_run"
}

public enum ParameterValidationInterruption: String, Codable, Sendable {
  case cancelled
  case budgetExceeded = "budget_exceeded"

  public var caseOutcome: ParameterCaseOutcome {
    self == .cancelled ? .cancelled : .budgetExceeded
  }
  public var message: String {
    self == .cancelled
      ? "Parameter validation was cancelled; incomplete cases are explicitly marked."
      : "Parameter validation exceeded its time budget; incomplete cases are explicitly marked."
  }
}

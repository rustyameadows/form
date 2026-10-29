import Foundation

/// A saved relationship between named parameters, checked before kernel work.
public struct CADModelRequirement: Codable, Equatable, Identifiable, Sendable {
  public enum Relation: String, Codable, CaseIterable, Sendable {
    case lessThan = "<", lessThanOrEqual = "<=", equal = "=="
    case greaterThanOrEqual = ">=", greaterThan = ">", notEqual = "!="
  }
  public var id: String
  public var lhs: CADScalar
  public var relation: Relation
  public var rhs: CADScalar
  public var message: String
  public var tolerance: Double?

  public init(id: String, lhs: CADScalar, relation: Relation, rhs: CADScalar,
              message: String, tolerance: Double? = nil) {
    self.id = id; self.lhs = lhs; self.relation = relation; self.rhs = rhs
    self.message = message; self.tolerance = tolerance
  }

  public func validate(using values: [String: Double]) throws {
    let left = try CADExpression.evaluate(lhs.expression, variables: values)
    let right = try CADExpression.evaluate(rhs.expression, variables: values)
    try validateResolved(lhs: left, rhs: right, parameterValues: values)
  }

  public func validateMetadata() throws {
    guard !id.isEmpty, id.utf8.count <= 128, !message.isEmpty, message.utf8.count <= 1024,
          tolerance.map({ $0.isFinite && $0 >= 0 && $0 <= 1 }) ?? true else {
      throw CADModelError("CAD requirements need bounded identities, messages and finite tolerance from 0 to 1.")
    }
  }

  public func validateResolved(lhs left: Double, rhs right: Double, parameterValues values: [String: Double]) throws {
    try validateMetadata()
    guard left.isFinite, right.isFinite else { throw CADModelError("Requirement measurements must be finite.") }
    let epsilon = tolerance ?? 1e-7
    let passes: Bool
    switch relation {
    case .lessThan: passes = left < right
    case .lessThanOrEqual: passes = left <= right
    case .equal: passes = abs(left - right) <= epsilon
    case .greaterThanOrEqual: passes = left >= right
    case .greaterThan: passes = left > right
    case .notEqual: passes = abs(left - right) > epsilon
    }
    guard passes else {
      throw CADRequirementFailure(requirementID: id, message: message,
        lhs: left, relation: relation, rhs: right, parameterValues: values)
    }
  }
}

public struct CADRequirementFailure: LocalizedError, Sendable {
  public let requirementID: String
  public let message: String
  public let lhs: Double
  public let relation: CADModelRequirement.Relation
  public let rhs: Double
  public let parameterValues: [String: Double]
  public var errorDescription: String? {
    "Requirement '\(requirementID)': \(message) (\(lhs) \(relation.rawValue) \(rhs))."
  }
}

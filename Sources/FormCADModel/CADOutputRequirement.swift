import Foundation

/// A numerical property of evaluated geometry. Units follow the metric:
/// millimeters, square/cubic millimeters, or a dimensionless solid count.
public struct CADOutputRequirement: Codable, Equatable, Identifiable, Sendable {
  public enum Metric: String, Codable, CaseIterable, Sendable {
    case width, height, depth, volume, area, solids, clearance, interference
  }
  public var id: String
  public var outputID: UUID
  public var otherOutputID: UUID?
  public var metric: Metric
  public var relation: CADModelRequirement.Relation
  public var value: CADScalar
  public var message: String
  public var tolerance: Double?

  public init(id: String, outputID: UUID, otherOutputID: UUID? = nil, metric: Metric,
              relation: CADModelRequirement.Relation, value: CADScalar,
              message: String, tolerance: Double? = nil) {
    self.id = id; self.outputID = outputID; self.otherOutputID = otherOutputID
    self.metric = metric; self.relation = relation; self.value = value
    self.message = message; self.tolerance = tolerance
  }
  public func validateDefinition(outputs: Set<UUID>, values: [String: Double]) throws {
    try comparison.validateMetadata()
    _ = try CADExpression.evaluate(value.expression, variables: values)
    guard outputs.contains(outputID) else { throw CADModelError("Geometry requirement '\(id)' references a missing output.") }
    if metric == .clearance || metric == .interference {
      guard let otherOutputID, otherOutputID != outputID, outputs.contains(otherOutputID) else {
        throw CADModelError("Clearance/interference requirements need two distinct existing outputs.")
      }
    } else if otherOutputID != nil {
      throw CADModelError("Only clearance/interference requirements accept another output.")
    }
  }
  public func validate(measured: Double, values: [String: Double]) throws {
    try comparison.validateResolved(lhs: measured,
      rhs: CADExpression.evaluate(value.expression, variables: values), parameterValues: values)
  }
  private var comparison: CADModelRequirement {
    .init(id: id, lhs: 0, relation: relation, rhs: value, message: message, tolerance: tolerance)
  }
}

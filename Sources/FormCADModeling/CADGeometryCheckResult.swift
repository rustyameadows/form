import Foundation
import FormCADModel

public struct CADGeometryCheckResult: Codable, Sendable {
  public var id: String
  public var outputID: UUID
  public var otherOutputID: UUID?
  public var metric: CADOutputRequirement.Metric
  public var measured: Double
  public var expected: Double
  public var relation: CADModelRequirement.Relation
  public var tolerance: Double?
}

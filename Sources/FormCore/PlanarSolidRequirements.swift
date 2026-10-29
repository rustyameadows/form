import Foundation
import FormCADModel

/// Explicit conditions on nominal sharp stock slabs derived from the saved
/// panel polygons and resolved rigid poses. A declaration does not imply that
/// undeclared panel pairs are collision-free or exempt intended hinge contact.
public struct PlanarSolidRequirement: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var firstPanelID: String
  public var secondPanelID: String
  public var metric: CADOutputRequirement.Metric
  public var relation: CADModelRequirement.Relation
  public var value: CADScalar
  public var message: String
  public var tolerance: Double?

  public init(id: String, firstPanelID: String, secondPanelID: String,
    metric: CADOutputRequirement.Metric, relation: CADModelRequirement.Relation,
    value: CADScalar, message: String, tolerance: Double? = nil) {
    self.id=id; self.firstPanelID=firstPanelID; self.secondPanelID=secondPanelID
    self.metric=metric; self.relation=relation; self.value=value
    self.message=message; self.tolerance=tolerance
  }
  private var comparison: CADModelRequirement {
    .init(id:id,lhs:0,relation:relation,rhs:value,message:message,tolerance:tolerance)
  }
  public func validateDefinition(panelIDs: Set<String>, values: [String:Double]) throws {
    try comparison.validateMetadata()
    guard metric == .clearance || metric == .interference,
      firstPanelID != secondPanelID, panelIDs.contains(firstPanelID), panelIDs.contains(secondPanelID) else {
      throw FormError.invalid("Solid check '\(id)' needs clearance/interference and two distinct existing panels.")
    }
    let expected=try CADExpression.evaluate(value.expression,variables:values)
    guard expected>=0, expected<=1e12 else {
      throw FormError.invalid("Solid check '\(id)' requires a finite nonnegative expected measurement no greater than 1e12.")
    }
  }
  public func measurement(_ measured: Double, values: [String:Double], stockThicknessMM: Double) throws -> PlanarSolidMeasurement {
    let expected=try CADExpression.evaluate(value.expression,variables:values)
    var passed=true,error:String?
    do {try comparison.validateResolved(lhs:measured,rhs:expected,parameterValues:values)}
    catch let failure as CADRequirementFailure {passed=false;error=failure.localizedDescription}
    return .init(id:id,firstPanelID:firstPanelID,secondPanelID:secondPanelID,metric:metric,
      units:metric == .clearance ? "mm":"mm3",measured:measured,required:expected,
      relation:relation,tolerance:tolerance,message:message,stockThicknessMM:stockThicknessMM,
      passed:passed,error:error)
  }
}

public struct PlanarSolidMeasurement: Codable, Equatable, Sendable {
  public var id: String
  public var firstPanelID: String
  public var secondPanelID: String
  public var metric: CADOutputRequirement.Metric
  public var units: String
  public var measured: Double
  public var required: Double
  public var relation: CADModelRequirement.Relation
  public var tolerance: Double?
  public var message: String
  public var stockThicknessMM: Double
  public var passed: Bool
  public var error: String?
}

import Foundation
import FormCADModel

public struct PlanarParameterCase: Codable, Equatable, Sendable {
  public var name: String
  public var values: [String:Double]
  public init(name:String,values:[String:Double]) {self.name=name;self.values=values}
}

/// A read-only source snapshot. Exact adapters consume the same geometry and
/// pose preparation as Core; the accepted object and artwork are never edited.
public struct PlanarConstructionValidationRequest: Sendable {
  public let projectID: UUID
  public let objectID: UUID
  public let sourceRevision: String
  public let definition: PlanarConstructionDefinition
  public let fold: Double
  public let opening: Double
  public let cases: [PlanarParameterCase]
  public var requiresExactSolids: Bool {definition.solidChecks?.isEmpty == false}

  public init(projectID:UUID,objectID:UUID,sourceRevision:String,
    definition:PlanarConstructionDefinition,fold:Double,opening:Double,cases:[PlanarParameterCase]) {
    self.projectID=projectID;self.objectID=objectID;self.sourceRevision=sourceRevision
    self.definition=definition;self.fold=fold;self.opening=opening;self.cases=cases
  }
  public func prepare(_ item:PlanarParameterCase) -> PlanarPreparedValidationCase {
    var candidate=definition
    var result=PlanarConstructionCaseResult(name:item.name,
      values:definition.values.merging(["fold":fold,"opening":opening]){_,new in new}.merging(item.values){_,new in new},passed:false)
    do {
      let requestedFold=item.values["fold"] ?? fold,requestedOpening=item.values["opening"] ?? opening
      guard requestedFold.isFinite,requestedOpening.isFinite,(0...100).contains(requestedFold),
        (0...100).contains(requestedOpening) else{throw FormError.invalid("Construction pose controls must be 0–100%.")}
      try candidate.setParameters(item.values)
      let net=try candidate.net(),stock=try candidate.number(candidate.stockThickness)
      var paper=PaperConstruction(kind:.authored,
        dimensions:.init(width:candidate.values["width"] ?? net.size.x,
          height:candidate.values["height"] ?? net.size.y,depth:candidate.values["depth"] ?? 1),
        stock:.init(thicknessMM:stock))
      paper.authored=candidate;paper.foldPercent=requestedFold;paper.openingPercent=requestedOpening
      let poses=try paper.resolvedPanels(),connections=try candidate.connectionMeasurements(poses:poses)
      result.values=candidate.values.merging(["fold":requestedFold,"opening":requestedOpening]){_,new in new}
      result.passed=connections.allSatisfy(\.passed);result.sizeMM=[net.size.x,net.size.y]
      result.panels=net.panels.count;result.folds=net.folds.count;result.resolvedPanels=poses.count
      result.poses=poses;result.connectionChecks=connections
      return .init(result:result,definition:candidate,net:net,poses:poses,stockThicknessMM:stock)
    } catch {
      result.error=error.localizedDescription
      if let failure=error as? CADRequirementFailure {
        result.requirementID=failure.requirementID;result.lhs=failure.lhs;result.rhs=failure.rhs
      }
      return .init(result:result,definition:nil,net:nil,poses:[],stockThicknessMM:nil)
    }
  }
  public func validateGeometryCases(maximumDurationSeconds:Double=10) throws -> PlanarConstructionValidationReport {
    guard !requiresExactSolids else {
      throw FormError.invalid("Declared panel-pair solid checks require LAB's installed exact runtime. Use form_construction validate_cases through the app.")
    }
    let started=ProcessInfo.processInfo.systemUptime
    var results:[PlanarConstructionCaseResult]=[]
    for item in cases {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime-started<maximumDurationSeconds else {
        throw FormError.invalid("Construction parameter validation exceeded its time budget; no complete report was accepted.")
      }
      results.append(prepare(item).result)
    }
    guard ProcessInfo.processInfo.systemUptime-started<=maximumDurationSeconds else {
      throw FormError.invalid("Construction parameter validation exceeded its time budget; no complete report was accepted.")
    }
    return report(results:results,durationMS:(ProcessInfo.processInfo.systemUptime-started)*1000)
  }
  public func report(results:[PlanarConstructionCaseResult],durationMS:Double) -> PlanarConstructionValidationReport {
    .init(sourceRevision:sourceRevision,passed:results.count==cases.count && results.allSatisfy(\.passed),
      cases:results,elapsedMS:durationMS,
      solidModel:requiresExactSolids ? "Sharp centered nominal-stock slabs; existing panel polygons at (x,-y), z=±stock/2, transformed by the reported resolved poses. Only explicitly declared pairs/conditions are checked.":nil)
  }
}

public struct PlanarPreparedValidationCase: Sendable {
  public var result: PlanarConstructionCaseResult
  public var definition: PlanarConstructionDefinition?
  public var net: PaperNet?
  public var poses: [PaperResolvedPanel]
  public var stockThicknessMM: Double?
}
public struct PlanarConstructionCaseResult: Codable, Equatable, Sendable {
  public var name: String
  public var values: [String:Double]
  public var passed: Bool
  public var sizeMM: [Double]?
  public var panels: Int?
  public var folds: Int?
  public var resolvedPanels: Int?
  public var poses: [PaperResolvedPanel]?
  public var connectionChecks: [PlanarConnectionMeasurement]?
  public var solidChecks: [PlanarSolidMeasurement]?
  public var error: String?
  public var requirementID: String?
  public var lhs: Double?
  public var rhs: Double?
  enum CodingKeys:String,CodingKey {
    case name,values,passed,panels,folds,poses,error,lhs,rhs
    case sizeMM="size_mm",resolvedPanels="resolved_panels",connectionChecks="connection_checks"
    case solidChecks="solid_checks",requirementID="requirement_id"
  }
  public init(name:String,values:[String:Double],passed:Bool) {self.name=name;self.values=values;self.passed=passed}
}
public struct PlanarConstructionValidationReport: Codable, Equatable, Sendable {
  public var sourceRevision: String
  public var passed: Bool
  public var cases: [PlanarConstructionCaseResult]
  public var elapsedMS: Double
  public var solidModel: String?
  enum CodingKeys:String,CodingKey {
    case passed,cases
    case sourceRevision="source_revision",elapsedMS="elapsed_ms",solidModel="solid_model"
  }
}

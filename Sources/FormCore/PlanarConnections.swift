import Foundation
import FormCADModel

/// Source-panel anchors are canonical millimeter points on each panel's neutral plane.
/// The requirement measures their actual distance after the requested fold/opening.
public struct PlanarConnectionRequirement:Codable,Equatable,Sendable {
  public var id:String
  public var firstPanelID:String
  public var secondPanelID:String
  public var firstPoint:CADExpressionPoint2
  public var secondPoint:CADExpressionPoint2
  public var maximumGapMM:CADScalar
  public init(id:String,firstPanelID:String,secondPanelID:String,firstPoint:CADExpressionPoint2,
    secondPoint:CADExpressionPoint2,maximumGapMM:CADScalar) {
    self.id=id;self.firstPanelID=firstPanelID;self.secondPanelID=secondPanelID
    self.firstPoint=firstPoint;self.secondPoint=secondPoint;self.maximumGapMM=maximumGapMM
  }
}
public struct PlanarConnectionMeasurement:Codable,Equatable,Sendable {
  public var id:String
  public var firstPanelID:String
  public var secondPanelID:String
  public var firstWorld:Vector3
  public var secondWorld:Vector3
  public var gapMM:Double
  public var maximumGapMM:Double
  public var passed:Bool
}
extension PlanarConstructionDefinition {
  public func connectionMeasurements(poses:[PaperResolvedPanel])throws->[PlanarConnectionMeasurement] {
    let variables=try resolvedValues()
    let matrices=Dictionary(poses.map{($0.panelID,$0.flatToWorld)},uniquingKeysWith:{a,_ in a})
    func point(_ source:CADExpressionPoint2,panel:String)throws->Vector3 {
      guard let m=matrices[panel],m.count==16,m.allSatisfy(\.isFinite) else{throw FormError.invalid("Connection anchor panel '\(panel)' has no finite resolved pose.")}
      let x=try CADExpression.evaluate(source.x.expression,variables:variables),y=try CADExpression.evaluate(source.y.expression,variables:variables)
      return .init(m[0]*x-m[1]*y+m[3],m[4]*x-m[5]*y+m[7],m[8]*x-m[9]*y+m[11])
    }
    return try (connections ?? []).map { connection in
      let first=try point(connection.firstPoint,panel:connection.firstPanelID),second=try point(connection.secondPoint,panel:connection.secondPanelID)
      let gap=sqrt(pow(first.x-second.x,2)+pow(first.y-second.y,2)+pow(first.z-second.z,2))
      let maximum=try CADExpression.evaluate(connection.maximumGapMM.expression,variables:variables)
      return .init(id:connection.id,firstPanelID:connection.firstPanelID,secondPanelID:connection.secondPanelID,
        firstWorld:first,secondWorld:second,gapMM:gap,maximumGapMM:maximum,passed:gap<=maximum+1e-7)
    }
  }
}

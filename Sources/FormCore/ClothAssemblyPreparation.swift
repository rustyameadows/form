import Foundation

/// Numerical assembly preparation, separate from physical integration time.
/// Tolerances cannot be loosened beyond the supported prototype readiness gate.
public struct ClothAssemblyPreparation:Codable,Equatable,Sendable {
  public var maximumPasses=16384
  public var maximumEvaluations=160_000_000
  public var maximumRelativeError=0.05
  public var maximumP95RelativeError=0.01
  public init() {}
  public func validate()throws {
    guard (1...16384).contains(maximumPasses),(1000...160_000_000).contains(maximumEvaluations),maximumRelativeError.isFinite,(0.0001...0.05).contains(maximumRelativeError),maximumP95RelativeError.isFinite,(0.0001...0.01).contains(maximumP95RelativeError) else{throw FormError.invalid("Assembly preparation requires bounded passes/work and at most 5% maximum/1% P95 structural length error.")}
  }
}
public enum ClothPreparationStatus:String,Codable,Sendable {case pending,preparing,ready,failed}
public struct ClothPreparationDiagnostics:Codable,Equatable,Sendable {
  public var status=ClothPreparationStatus.pending
  public var passes=0
  public var evaluations=0
  public var maximumRelativeError=0.0
  public var p95RelativeError=0.0
  public var minimumStructuralRatio=1.0
  public var maximumStructuralRatio=1.0
  public var worstPreparationStructuralRatio=1.0
  public var lowestPreparationStructuralRatio=1.0
  public var maximumDistanceErrorMm=0.0
  public var maximumAllowedRelativeError:Double
  public var maximumAllowedP95RelativeError:Double
  public var maximumPasses:Int
  public var maximumEvaluations:Int
  public init(settings:ClothAssemblyPreparation) {
    maximumAllowedRelativeError=settings.maximumRelativeError;maximumAllowedP95RelativeError=settings.maximumP95RelativeError;maximumPasses=settings.maximumPasses;maximumEvaluations=settings.maximumEvaluations
  }
}

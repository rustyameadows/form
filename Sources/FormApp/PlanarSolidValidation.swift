import Foundation
import FormCore
import FormCADModel
import FormCADKernel

/// Exact measurements are ephemeral derived views of the original construction;
/// no CAD source, saved asset, display mesh or artwork document is produced.
enum PlanarSolidValidation {
  private struct Pair: Hashable {
    let first:String,second:String
    init(_ a:String,_ b:String) {first=min(a,b);second=max(a,b)}
  }
  private struct Slab {
    let polygon:[Point2]
    let cutouts:[PaperPanelCutout]?
    let stock:Double
    let shape:CADShape
  }
  static let maximumPairQueries=1024
  static func run(_ request:PlanarConstructionValidationRequest,
    maximumDurationSeconds:Double=10,
    checkpoint:(@Sendable () async throws -> Void)?=nil) async throws -> PlanarConstructionValidationReport {
    guard maximumDurationSeconds.isFinite,(0.01...30).contains(maximumDurationSeconds),
      (1...64).contains(request.cases.count),Set(request.cases.map(\.name)).count==request.cases.count else {
      throw FormError.invalid("Construction exact validation needs 1–64 unique cases and a 0.01–30 second budget.")
    }
    let pairs=Set((request.definition.solidChecks ?? []).map{Pair($0.firstPanelID,$0.secondPanelID)})
    guard pairs.count*request.cases.count<=maximumPairQueries else {
      throw FormError.invalid("Construction exact validation exceeds 1024 declared panel-pair queries; request fewer cases or pairs.")
    }
    let started=ProcessInfo.processInfo.systemUptime
    if Task.isCancelled {throw request.interrupted(.cancelled,completed:[],durationMS:0)}
    let worker=Task.detached(priority:.userInitiated) {
      try await evaluate(request,maximumDurationSeconds:maximumDurationSeconds,started:started,checkpoint:checkpoint)
    }
    let deadline=Task.detached {
      try await Task.sleep(nanoseconds:UInt64(maximumDurationSeconds*1_000_000_000))
      worker.cancel()
    }
    defer {deadline.cancel()}
    // Await the worker's terminal report; cancellation/deadline never loses
    // the current case or leaves accumulating exact geometry behind.
    return try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
  }
  private static func evaluate(_ request:PlanarConstructionValidationRequest,
    maximumDurationSeconds:Double,started:Double,checkpoint:(@Sendable () async throws -> Void)?) async throws -> PlanarConstructionValidationReport {
    let kernel=CADKernel()
    var results:[PlanarConstructionCaseResult]=[],active:PlanarConstructionCaseResult?
    func checkBudget() throws {
      let reason:ParameterValidationInterruption?
      if ProcessInfo.processInfo.systemUptime-started>=maximumDurationSeconds {reason = .budgetExceeded}
      else {reason = Task.isCancelled ? .cancelled:nil}
      if let reason {throw request.interrupted(reason,completed:results,active:active,durationMS:(ProcessInfo.processInfo.systemUptime-started)*1000)}
    }
    // At most one flat slab per stable source panel; geometry-changing cases
    // replace its handle rather than retaining every historical variant.
    var flat:[String:Slab]=[:]
    for item in request.cases {
      active=nil;try checkBudget()
      var prepared=request.prepare(item)
      active=prepared.result;try checkBudget()
      guard let source=prepared.definition,let net=prepared.net,let stock=prepared.stockThicknessMM else {
        results.append(prepared.result);active=nil;continue
      }
      do {
        try await checkpoint?();try checkBudget()
        let checks=source.solidChecks ?? [],values=try source.resolvedValues()
        let needed=Set(checks.flatMap{[$0.firstPanelID,$0.secondPanelID]})
        var posed:[String:CADShape]=[:],measurements:[Pair:CADClearance]=[:]
        let matrices=Dictionary(uniqueKeysWithValues:prepared.poses.map{($0.panelID,$0.flatToWorld)})
        for panel in net.panels where needed.contains(panel.id) {
          try checkBudget()
          let base:CADShape
          if let cached=flat[panel.id],cached.polygon==panel.polygon,cached.cutouts==panel.cutouts,cached.stock==stock {
            base=cached.shape
          } else {
            let profile=try await kernel.profile(outer:panel.polygon.map{.init($0.x,-$0.y)},
              holes:(panel.cutouts ?? []).map{$0.polygon.map{.init($0.x,-$0.y)}},
              plane:.init(origin:.init(0,0,-stock/2),u:.init(1,0,0),v:.init(0,1,0)))
            try checkBudget()
            base=try await kernel.extrude(profile,vector:.init(0,0,stock))
            guard base.info.valid,base.info.closed,base.info.solids==1,base.info.volumeMM3>0 else {
              throw FormError.invalid("Panel '\(panel.id)' did not produce a valid positive-volume nominal-stock slab.")
            }
            flat[panel.id] = .init(polygon:panel.polygon,cutouts:panel.cutouts,stock:stock,shape:base)
          }
          try checkBudget()
          guard let matrix=matrices[panel.id],matrix.count==16,matrix.allSatisfy(\.isFinite) else {
            throw FormError.invalid("Panel '\(panel.id)' has no finite resolved rigid pose.")
          }
          posed[panel.id]=try await kernel.transform(base,rowMajorMatrix:matrix)
        }
        var reports:[PlanarSolidMeasurement]=[]
        for check in checks {
          try checkBudget()
          let pair=Pair(check.firstPanelID,check.secondPanelID),measurement:CADClearance
          if let cached=measurements[pair] {measurement=cached}
          else {
            guard let first=posed[pair.first],let second=posed[pair.second] else {
              throw FormError.invalid("Solid check '\(check.id)' cannot resolve panels '\(check.firstPanelID)' and '\(check.secondPanelID)'.")
            }
            do {measurement=try await kernel.clearance(first,second)}
            catch {try Task.checkCancellation();throw FormError.invalid("Solid check '\(check.id)' (\(pair.first), \(pair.second)): \(error.localizedDescription)")}
            try checkBudget();measurements[pair]=measurement
          }
          reports.append(try check.measurement(check.metric == .clearance ? measurement.distanceMM:measurement.interferenceVolumeMM3,
            values:values,stockThicknessMM:stock))
          prepared.result.solidChecks=reports;active=prepared.result
        }
        prepared.result.solidChecks=reports
        prepared.result.passed = prepared.result.passed && reports.allSatisfy(\.passed)
      } catch let interrupted as PlanarConstructionValidationInterrupted {throw interrupted}
      catch {
        try checkBudget()
        prepared.result.passed=false;prepared.result.error=error.localizedDescription
      }
      prepared.result.outcome=prepared.result.passed ? .passed:.failed
      active=prepared.result;try checkBudget()
      results.append(prepared.result);active=nil
    }
    try checkBudget()
    return request.report(results:results,durationMS:(ProcessInfo.processInfo.systemUptime-started)*1000)
  }
}

/// A newer validation request supersedes an older one, just as CAD evidence is
/// pinned to a source revision. There is no publication or Undo transaction.
@MainActor final class ConstructionValidationCoordinator {
  private var task:Task<PlanarConstructionValidationReport,Error>?
  private var active:PlanarConstructionValidationRequest?
  private var artworkTask:Task<ArtworkConstructionValidationReport,Error>?
  private var activeArtwork:ArtworkConstructionValidationRequest?
  private var generation=0
  func validate(_ request:PlanarConstructionValidationRequest,
    maximumDurationSeconds:Double=10,
    checkpoint:(@Sendable () async throws -> Void)?=nil,
    isCurrent:() -> Bool) async throws -> PlanarConstructionValidationReport {
    cancel();let token=generation
    active=request
    let work=Task {try await PlanarSolidValidation.run(request,
      maximumDurationSeconds:maximumDurationSeconds,checkpoint:checkpoint)}
    task=work
    defer {if token==generation{task=nil;active=nil}}
    func verifyCurrent() throws {
      guard token==generation else{throw CancellationError()}
      guard isCurrent() else {
        throw FormError.invalid("The construction source or project changed; the obsolete validation report was discarded.")
      }
    }
    do {
      let result=try await withTaskCancellationHandler {try await work.value} onCancel:{work.cancel()}
      try verifyCurrent();return result
    } catch {try verifyCurrent();throw error}
  }
  func validate(_ request:ArtworkConstructionValidationRequest,
    maximumDurationSeconds:Double=10,checkpoint:(@Sendable () async throws->Void)?=nil,
    isCurrent:()->Bool) async throws -> ArtworkConstructionValidationReport {
    cancel();let token=generation;activeArtwork=request
    let work=Task {try await request.run(maximumDurationSeconds:maximumDurationSeconds,checkpoint:checkpoint)}
    artworkTask=work
    defer{if token==generation{artworkTask=nil;activeArtwork=nil}}
    func verifyCurrent()throws {
      guard token==generation else{throw CancellationError()}
      guard isCurrent() else{throw FormError.invalid("The artwork source or project changed; the obsolete validation report was discarded.")}
    }
    do {
      let result=try await withTaskCancellationHandler {try await work.value} onCancel:{work.cancel()}
      try verifyCurrent();return result
    } catch {try verifyCurrent();throw error}
  }
  func projectDidChange(_ project:Project?) {
    if let activeArtwork,!activeArtwork.isCurrent(in:project) {cancel();return}
    guard let active else{return}
    if !ConstructionCommands.validationSourceIsCurrent(active,in:project) {cancel()}
  }
  func cancel() {generation+=1;task?.cancel();artworkTask?.cancel();task=nil;active=nil;artworkTask=nil;activeArtwork=nil}
}

extension StudioStore {
  func constructionValidationCallAsync(_ args:[String:Any]) async throws -> Any {
    guard let project=engine.project else{throw FormError.missing("Open a project before validating a construction.")}
    if let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),project.objects.first(where:{$0.id==id})?.artworkParameterBindings?.isEmpty == false {
      return try await constructionValidationCallAsync(ConstructionCommands.artworkValidationRequest(project:project,arguments:args))
    }
    let request=try ConstructionCommands.validationRequest(project:project,arguments:args)
    return try await constructionValidationCallAsync(request)
  }
  func constructionValidationCallAsync(_ request:PlanarConstructionValidationRequest) async throws -> Any {
    guard ConstructionCommands.validationSourceIsCurrent(request,in:engine.project) else {
      throw FormError.invalid("The construction source changed before validation began.")
    }
    do {
      let report=try await constructionValidation.validate(request) { [weak self] in
        ConstructionCommands.validationSourceIsCurrent(request,in:self?.engine.project)
      }
      return try jsonObject(report)
    } catch let interrupted as PlanarConstructionValidationInterrupted {
      // The coordinator rejects obsolete source/project results before this.
      return try jsonObject(interrupted.report)
    }
  }
  func constructionValidationCallAsync(_ request:ArtworkConstructionValidationRequest) async throws -> Any {
    guard request.isCurrent(in:engine.project) else{throw FormError.invalid("The artwork source changed before validation began.")}
    do {
      let report=try await constructionValidation.validate(request){[weak self] in request.isCurrent(in:self?.engine.project)}
      return try jsonObject(report)
    } catch let error as ArtworkConstructionValidationInterrupted {return try jsonObject(error.report)}
  }

}

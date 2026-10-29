import CryptoKit
import Foundation
import FormCADModel

/// Transport value only; the editor's Rect2 remains an ephemeral geometry type.
public struct ArtworkPhysicalBounds:Codable,Equatable,Sendable {
  public var x:Double
  public var y:Double
  public var width:Double
  public var height:Double
  public init(_ rect:Rect2) {x=rect.x;y=rect.y;width=rect.width;height=rect.height}
}
public struct ArtworkPieceMeasurement:Codable,Equatable,Sendable {
  public var elementID:UUID
  public var name:String
  public var stitchBoundsMM:ArtworkPhysicalBounds
  public var cutBoundsMM:ArtworkPhysicalBounds
  public var stitchAreaMM2:Double
  public var cutAreaMM2:Double
  public var seamAllowanceMM:Double
  public var edgeIDs:[UUID]
  public var edgeLengthsMM:[Double]
}
public struct ArtworkSeamMeasurement:Codable,Equatable,Sendable {
  public var id:UUID
  public var name:String
  public var firstLengthMM:Double
  public var secondLengthMM:Double
  public var differenceMM:Double
  public var measurementErrorMM:Double
  public var toleranceMM:Double
  public var conclusive:Bool
  public var passed:Bool
}
public struct ArtworkAssemblyPanelMeasurement:Codable,Equatable,Sendable {
  public var panel:PatternPanelID
  public var sourceOriginMM:Point2
  public var materialSizeMM:Point2
  public var textureOriginMM:Point2
  public var sourceAreaMM2:Double
  public var meshAreaMM2:Double
}
public struct ArtworkAssemblyMeasurement:Codable,Equatable,Sendable {
  public var objectID:UUID
  public var sourceDigest:String
  public var definitionDigest:String
  public var vertices:Int
  public var triangles:Int
  public var seamSamples:Int
  public var operations:Int
  public var boundsMM:ClothBounds
  public var materialBoundsMM:ArtworkPhysicalBounds
  public var panels:[ArtworkAssemblyPanelMeasurement]
}
public struct ArtworkAttachmentMeasurement:Codable,Equatable,Sendable {
  public var objectID:UUID
  public var surfaceObjectID:UUID
  public var anchor:PatternAssemblyAnchor
  public var resolved:ClothSurfaceAnchor
  public var placement:ClothSurfacePlacement
}
public struct ArtworkConstructionCaseResult:Codable,Equatable,Sendable {
  public var name:String
  public var values:[String:Double]
  public var passed:Bool=false
  public var outcome:ParameterCaseOutcome?
  public var pieces:[ArtworkPieceMeasurement]=[]
  public var seams:[ArtworkSeamMeasurement]=[]
  public var assemblies:[ArtworkAssemblyMeasurement]=[]
  public var attachments:[ArtworkAttachmentMeasurement]=[]
  public var error:String?
  public var bindingID:String?
  public var elementID:UUID?
}
public struct ArtworkConstructionValidationReport:Codable,Equatable,Sendable {
  public var sourceRevision:String
  public var passed:Bool
  public var cases:[ArtworkConstructionCaseResult]
  public var elapsedMS:Double
  public var interruption:ParameterValidationInterruption?
  public let scope="Existing canonical artwork fields, actual sewing cut/stitch boundaries and arc-length seams, regenerated declared rest assemblies/material coordinates and attachment anchors. No cloth advance, calibrated fit or manufacturing certification is inferred."
  enum CodingKeys:String,CodingKey {case passed,cases,interruption,scope;case sourceRevision="source_revision",elapsedMS="elapsed_ms"}
}
public struct ArtworkConstructionValidationInterrupted:Error,LocalizedError,Sendable {
  public let report:ArtworkConstructionValidationReport
  public let reason:ParameterValidationInterruption
  public var errorDescription:String? {reason.message}
}

/// One isolated snapshot of the existing artwork owner, Recipe controls and
/// original assembly declarations. It contains no alternate sewing generator.
public struct ArtworkConstructionValidationRequest:Sendable {
  public static let maximumEvidenceUnits=32_768
  public let project:Project
  public let objectID:UUID
  public let sourceRevision:String
  public let cases:[PlanarParameterCase]
  public var projectID:UUID {project.id}
  public init(project:Project,objectID:UUID,cases:[PlanarParameterCase]) throws {
    guard let owner=project.objects.first(where:{$0.id==objectID}),owner.artworkParameterBindings?.isEmpty == false else {
      throw FormError.invalid("Choose an independent canonical artwork owner with saved artwork parameter bindings.")
    }
    _ = try project.artworkBindingParameters(for:owner)
    guard (1...64).contains(cases.count),Set(cases.map(\.name)).count==cases.count,
      cases.allSatisfy({!$0.name.isEmpty && $0.name.utf8.count<=128 && $0.values.values.allSatisfy(\.isFinite)}) else {
      throw FormError.invalid("Use 1–64 uniquely named finite parameter cases.")
    }
    guard (owner.artwork?.elements.filter{$0.sewingPiece != nil}.count ?? 0)<=64,
      project.objects.filter{$0.patternAssembly?.sourceObjectID==objectID}.count<=8 else {
      throw FormError.invalid("A validation snapshot supports up to 64 source pieces and 8 related rest assemblies.")
    }
    let pieces=owner.artwork!.elements.filter{$0.sewingPiece != nil}
    let assemblies=project.objects.filter{$0.patternAssembly?.sourceObjectID==objectID},ids=Set(assemblies.map(\.id))
    let attachments=project.objects.filter{$0.patternAssemblyAttachment.map{ids.contains($0.surfaceObjectID)} == true}
    let edges=pieces.reduce(0){$0+($1.path?.contours.reduce(0){$0+$1.nodes.count} ?? ($1.kind=="polygon" ? $1.sides ?? 5:4))}
    let seams=owner.artwork!.sewingSeams ?? []
    guard pieces.allSatisfy({($0.sewingPiece?.name.utf8.count ?? 0)<=512}),seams.allSatisfy({$0.name.utf8.count<=512}) else {
      throw FormError.invalid("Source piece/seam labels exceed the bounded 512-byte case-evidence label limit.")
    }
    // Bound the combined response, not merely each independent source limit.
    // Weight includes readable field names/labels and scalar/UUID evidence;
    // source curves and generated mesh arrays are never copied into reports.
    let units=cases.count*(32+pieces.count*16+edges+seams.count*16+assemblies.count*64+attachments.count*32)
    guard units<=Self.maximumEvidenceUnits else {
      throw FormError.invalid("The combined case evidence exceeds its 32768-unit bridge budget. Request fewer cases, source pieces or related assemblies/attachments per batch.")
    }
    self.project=project;self.objectID=objectID;self.cases=cases
    sourceRevision=try Self.revision(in:project,objectID:objectID)
  }
  public static func revision(in project:Project,objectID:UUID)throws->String {
    guard let source=project.objects.first(where:{$0.id==objectID}),let recipe=project.recipe(source.recipeID) else {
      throw FormError.missing("The parameterized artwork source or its recipe is missing.")
    }
    let assemblies=project.objects.filter{$0.patternAssembly?.sourceObjectID==objectID}.sorted{$0.id.uuidString<$1.id.uuidString}
    let ids=Set(assemblies.map(\.id))
    let attachments=project.objects.filter{$0.patternAssemblyAttachment.map{ids.contains($0.surfaceObjectID)} == true}.sorted{$0.id.uuidString<$1.id.uuidString}
    struct Snapshot:Encodable {let source:ProductObject;let recipe:Recipe;let assemblies:[ProductObject];let attachments:[ProductObject]}
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    return SHA256.hash(data:try encoder.encode(Snapshot(source:source,recipe:recipe,assemblies:assemblies,attachments:attachments))).map{String(format:"%02x",$0)}.joined()
  }
  public func isCurrent(in candidate:Project?)->Bool {
    guard let candidate,candidate.id==projectID else{return false}
    return (try? Self.revision(in:candidate,objectID:objectID))==sourceRevision
  }
  public func caseValues(_ item:PlanarParameterCase)->[String:Double] {
    guard let object=project.objects.first(where:{$0.id==objectID}),let recipe=project.recipe(object.recipeID) else{return item.values}
    return recipe.defaults.merging(object.parameters){_,new in new}.merging(item.values){_,new in new}
  }
  public func report(_ results:[ArtworkConstructionCaseResult],started:Double,
    interruption:ParameterValidationInterruption?=nil)->ArtworkConstructionValidationReport {
    .init(sourceRevision:sourceRevision,passed:interruption==nil && results.count==cases.count && results.allSatisfy(\.passed),cases:results,
      elapsedMS:(ProcessInfo.processInfo.systemUptime-started)*1000,interruption:interruption)
  }
  private func interrupted(_ reason:ParameterValidationInterruption,completed:[ArtworkConstructionCaseResult],
    active:ArtworkConstructionCaseResult?,started:Double)->ArtworkConstructionValidationInterrupted {
    var results=completed
    if var active {active.passed=false;active.outcome=reason.caseOutcome;active.error=reason.message;results.append(active)}
    for item in cases.dropFirst(results.count) {
      var result=ArtworkConstructionCaseResult(name:item.name,values:caseValues(item));result.outcome = .notRun
      result.error="Not evaluated because the batch was interrupted.";results.append(result)
    }
    return .init(report:report(results,started:started,interruption:reason),reason:reason)
  }
  public func run(maximumDurationSeconds:Double=10,
    checkpoint:(@Sendable () async throws->Void)?=nil) async throws -> ArtworkConstructionValidationReport {
    guard maximumDurationSeconds.isFinite,(0.01...30).contains(maximumDurationSeconds) else {
      throw FormError.invalid("Artwork construction cases need a 0.01–30 second budget.")
    }
    let started=ProcessInfo.processInfo.systemUptime
    if Task.isCancelled {throw interrupted(.cancelled,completed:[],active:nil,started:started)}
    let worker=Task.detached(priority:.userInitiated) {try await evaluate(maximumDurationSeconds:maximumDurationSeconds,started:started,checkpoint:checkpoint)}
    let deadline=Task.detached {try await Task.sleep(nanoseconds:UInt64(maximumDurationSeconds*1_000_000_000));worker.cancel()}
    defer{deadline.cancel()}
    return try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
  }
  private func evaluate(maximumDurationSeconds:Double,started:Double,
    checkpoint:(@Sendable () async throws->Void)?) async throws -> ArtworkConstructionValidationReport {
    var results:[ArtworkConstructionCaseResult]=[],active:ArtworkConstructionCaseResult?
    func check()throws {
      let reason:ParameterValidationInterruption?
      if ProcessInfo.processInfo.systemUptime-started>=maximumDurationSeconds {reason = .budgetExceeded}
      else {reason=Task.isCancelled ? .cancelled:nil}
      if let reason {throw interrupted(reason,completed:results,active:active,started:started)}
    }
    for item in cases {
      active=nil;try check()
      active = .init(name:item.name,values:caseValues(item))
      do {
        try await checkpoint?();try check()
        let result=try measure(item,checkpoint:check,progress:{active=$0})
        active=result;try check();results.append(result);active=nil
      } catch let error as ArtworkConstructionValidationInterrupted {throw error}
      catch {
        try check()
        var result=active ?? .init(name:item.name,values:caseValues(item))
        result.passed=false;result.outcome = .failed;result.error=Self.issue(error.localizedDescription)
        if let failure=error as? ArtworkParameterBindingFailure {result.bindingID=failure.bindingID;result.elementID=failure.elementID}
        results.append(result);active=nil
      }
    }
    try check();return report(results,started:started)
  }
  private static func issue(_ message:String)->String {
    message.utf8.count<=4096 ? message:String(decoding:message.utf8.prefix(4096),as:UTF8.self)+"… (issue text truncated)"
  }
  private func measure(_ item:PlanarParameterCase,checkpoint:()throws->Void,
    progress:(ArtworkConstructionCaseResult)->Void)throws->ArtworkConstructionCaseResult {
    var result=ArtworkConstructionCaseResult(name:item.name,values:caseValues(item)),candidate=project
    let index=candidate.objects.firstIndex{$0.id==objectID}!,recipe=candidate.recipe(candidate.objects[index].recipeID)!
    try recipe.validate(result.values);candidate.objects[index].parameters=result.values
    try candidate.applyArtworkParameterBindings(to:objectID)
    let art=candidate.objects[index].artwork!
    func area(_ contours:[[Point2]])->Double {
      abs(contours.reduce(0){sum,ring in sum+ring.indices.reduce(0){total,i in let a=ring[i],b=ring[(i+1)%ring.count];return total+(a.x*b.y-b.x*a.y)/2}})
    }
    func bounds(_ points:[Point2])throws->ArtworkPhysicalBounds {
      guard let first=points.first else{throw FormError.invalid("The regenerated physical boundary is empty.")}
      return .init(points.dropFirst().reduce(Rect2(first.x,first.y,0,0)){$0.union(.init($1.x,$1.y,0,0))})
    }
    for element in art.elements where element.sewingPiece != nil {
      try checkpoint()
      let shape=try SewingPatterns.geometry(element,in:art)
      result.pieces.append(.init(elementID:element.id,name:shape.piece.name,
        stitchBoundsMM:try bounds(shape.allStitchContours.flatMap{$0}),cutBoundsMM:try bounds(shape.allCutContours.flatMap{$0}),
        stitchAreaMM2:area(shape.allStitchContours),cutAreaMM2:area(shape.allCutContours),seamAllowanceMM:shape.piece.seamAllowance,
        edgeIDs:shape.sourceEdges.compactMap(\.id),edgeLengthsMM:shape.edgeLengths))
      progress(result)
    }
    try checkpoint()
    result.seams=try SewingPatterns.diagnostics(art).map{.init(id:$0.seam.id,name:$0.seam.name,firstLengthMM:$0.firstLength,
      secondLengthMM:$0.secondLength,differenceMM:$0.difference,measurementErrorMM:$0.measurementError,toleranceMM:$0.seam.tolerance,
      conclusive:$0.isConclusive,passed:$0.isConclusive && $0.matches)}
    result.passed=result.seams.allSatisfy(\.passed);progress(result)
    var failures:[String]=[]
    for object in candidate.objects where object.patternAssembly?.sourceObjectID==objectID {
      try checkpoint()
      do {
        let definition=object.patternAssembly!,product=try PatternAssemblyGenerator.generate(definition,in:candidate)
        try checkpoint()
        result.assemblies.append(.init(objectID:object.id,sourceDigest:product.sourceDigest,definitionDigest:product.definitionDigest,
          vertices:product.study.mesh.restPositionsMm.count,triangles:product.study.mesh.triangles.count,seamSamples:product.seamSamples.count,operations:product.operations,
          boundsMM:try ClothBounds(positionsMm:product.study.mesh.restPositionsMm),materialBoundsMM:try bounds(product.materialPointsMm),
          panels:product.panels.map{.init(panel:$0.id,sourceOriginMM:$0.sourceOriginMm,materialSizeMM:$0.materialSizeMm,textureOriginMM:$0.textureOriginMm,
            sourceAreaMM2:$0.sourceAreaMm2,meshAreaMM2:$0.meshAreaMm2)}))
        progress(result)
        let attachments=candidate.objects.filter{$0.patternAssemblyAttachment?.surfaceObjectID==object.id}
        if !attachments.isEmpty {
          let frame=try ClothSolver(mesh:product.study.mesh,settings:definition.settings,preparation:.init()).frame
          for attached in attachments {
            try checkpoint()
            do {
              let declaration=attached.patternAssemblyAttachment!,anchor=try declaration.anchor.resolve(in:product)
              result.attachments.append(.init(objectID:attached.id,surfaceObjectID:object.id,anchor:declaration.anchor,resolved:anchor,
                placement:try anchor.placement(mesh:product.study.mesh,frame:frame)))
            } catch let error as ArtworkConstructionValidationInterrupted {throw error}
            catch {failures.append("Attachment \(attached.id.uuidString): \(error.localizedDescription)")}
            progress(result)
          }
        }
      } catch let error as ArtworkConstructionValidationInterrupted {throw error}
      catch {try checkpoint();failures.append("Assembly \(object.id.uuidString): \(error.localizedDescription)")}
    }
    if !failures.isEmpty {result.passed=false;result.error=Self.issue(failures.joined(separator:"\n"))}
    result.outcome=result.passed ? .passed:.failed;return result
  }
}

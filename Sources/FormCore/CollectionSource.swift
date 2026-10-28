import Foundation
import CryptoKit

public struct CollectionSource:Codable,Equatable,Sendable {
  public var project:Project
  public var plan:CollectionProductionPlan
  public var embroideryJobs:[ProductionJob]
  public var decorationJobs:[DecorationPreparation]
  public init(project:Project,plan:CollectionProductionPlan)throws {
    guard project.objects.count<=CollectionLimits.objects,project.materials.count<=256,project.recipes.count<=256,(project.textStyles?.count ?? 0)<=256,(project.swatches?.count ?? 0)<=256,(project.textStories?.count ?? 0)<=128 else{throw FormError.invalid("The original collection source exceeds its early object/style/material bounds.")}
    let arts=project.objects.compactMap(\.artwork),elements=arts.flatMap(\.elements)
    let sourceCharacters=elements.reduce(0){$0+$1.text.utf8.count}+(project.textStories ?? []).reduce(0){$0+$1.text.utf8.count}
    let nodes=elements.reduce(0){$0+($1.path?.contours.reduce(0){$0+$1.nodes.count} ?? 0)}
    let vertices=project.objects.reduce(0){$0+($1.cloth?.mesh.restPositionsMm.count ?? 0)}
    guard elements.count<=20000,sourceCharacters<=4_000_000,nodes<=200000,vertices<=100000 else{throw FormError.invalid("Collection source exceeds its early20k elements/4 MB text/200k nodes/100k persisted cloth-vertex bound before encoding or rendering.")}
    var copy=project;copy.collectionProduction=nil;copy.studioPresentation=nil;copy.productionJobs=nil;copy.decorationPreparations=nil;copy.camera = .init();copy.history=[];copy.updatedAt=Date(timeIntervalSince1970:0);copy.printSetups=nil
    // Preserve the actual referenced built-in definitions as portable source,
    // rather than relying on a later app's changed preset names/specifications.
    var materialIDs=Set(project.objects.flatMap{[$0.materialID,$0.textile?.liningMaterialID,$0.textile?.trimMaterialID].compactMap{$0}})
    for o in project.objects {
      materialIDs.formUnion(o.patternAssembly?.panels.map{$0.material.id} ?? [])
      materialIDs.formUnion(o.artwork?.elements.compactMap{$0.sewingPiece?.materialID} ?? [])
      if let id=o.artwork?.sewingLayout?.materialID {materialIDs.insert(id)}
    }
    for b in project.garmentBlocks ?? [] {materialIDs.formUnion([b.style.materialID,b.style.elasticMaterialID].compactMap{$0})}
    for id in materialIDs.sorted() where !copy.materials.contains(where:{$0.id==id}) {let material=project.material(id);if material.id==id {copy.materials.append(material)}}
    for id in Set(project.objects.map(\.recipeID)).sorted() where !copy.recipes.contains(where:{$0.id==id}) {if let recipe=project.recipe(id) {copy.recipes.append(recipe)}}
    guard copy.materials.count<=256,copy.recipes.count<=256 else{throw FormError.invalid("Referenced original material/recipe definitions exceed their portable source cap.")}
    copy.schemaVersion=1;copy.schemaVersion=copy.minimumSchemaVersion
    self.project=copy;self.plan=plan
    let wanted=Set(plan.processes.map(\.jobID));embroideryJobs=(project.productionJobs ?? []).filter{wanted.contains($0.id)};decorationJobs=(project.decorationPreparations ?? []).filter{wanted.contains($0.id)}
  }
  public static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  public func data()throws->Data {let data=try JSONEncoder.form.encode(self);guard data.count<=CollectionLimits.fileBytes else{throw FormError.invalid("Collection source JSON exceeds64 MB before capture.")};return data}
}
public struct CollectionArtifact:Codable,Equatable,Sendable {
  public var name:String,digest:String,role:String,provenance:String
  public var bytes:Int
  public init(name:String,data:Data,role:String,provenance:String) {self.name=name;digest=CollectionSource.digest(data);bytes=data.count;self.role=role;self.provenance=provenance}
  public func validate()throws {
    let parts=name.split(separator:"/",omittingEmptySubsequences:false)
    guard !name.isEmpty,name.utf8.count<=512,!name.hasPrefix("/"),!name.contains("\\"),!name.contains(":"),!name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}),digest.utf8.count==64,ProductionJob.validDigest(digest),(1...CollectionLimits.fileBytes).contains(bytes),["source","review","delivery","reference","specification"].contains(role),!provenance.isEmpty,provenance.count<=2000 else{throw FormError.invalid("A collection artifact needs safe relative identity, bounded original bytes and explicit provenance.")}
  }
}
public struct CollectionRevision:Codable,Equatable,Sendable {
  public var plan:CollectionProductionPlan
  public var sourceDigest:String
  public var report:CollectionPreflight
  public var artifacts:[CollectionArtifact]
  public init(plan:CollectionProductionPlan,sourceDigest:String,report:CollectionPreflight,artifacts:[CollectionArtifact]) {self.plan=plan;self.sourceDigest=sourceDigest;self.report=report;self.artifacts=artifacts}
  public func validate()throws {
    try plan.validate()
    guard artifacts.count<=CollectionLimits.files else{throw FormError.invalid("Too many collection artifact descriptors before aggregation.")}
    for a in artifacts {try a.validate()}
    guard sourceDigest.utf8.count==64,ProductionJob.validDigest(sourceDigest),!artifacts.isEmpty,artifacts.count<=CollectionLimits.files,Set(artifacts.map(\.name)).count==artifacts.count,artifacts.reduce(0,{$0+$1.bytes})<=CollectionLimits.totalBytes,
      report.rows.count<=CollectionLimits.rows,report.findings.count<=CollectionLimits.rows,report.occurrences.count<=CollectionLimits.rows,
      artifacts.contains(where:{$0.name=="Source.json" && $0.digest==sourceDigest && $0.role=="source"}),artifacts.contains(where:{$0.name=="Review.pdf" && $0.role=="review"}) else{throw FormError.invalid("The immutable collection revision is incomplete or exceeds aggregate file/row limits.")}
  }
}

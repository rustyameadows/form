import Foundation
import FormCADModel

/// The immutable manufacturing source excludes presentation poses and Canvas
/// placement. It retains editable part definitions, ink, styles and resources.
public struct ConstructionPacketSource:Codable,Equatable,Sendable {
  public var project:Project
  public var ownerID:UUID
  public init(project:Project,ownerID:UUID) {self.project=project;self.ownerID=ownerID}
}
public struct ConstructionPacketModel:Sendable {
  public var ownerID:UUID
  public var name:String
  public var source:PaperConstruction
  public var production:ConstructionProductionDefinition
  public var pieces:[ResolvedConstructionPiece]
  public var layouts:ConstructionLayoutReport
  public var attachments:ResolvedPlanarAttachments
  public var steps:[ConstructionAssemblyStep]
  public var sourceSnapshot:ConstructionPacketSource
  public var sourceData:Data
  public var sourceDigest:String
  public var issues:[ConstructionPacketIssue]
  public var isValid:Bool {!issues.contains{$0.severity == .error}}
  /// Several joint-contact records can use one physical strip. Count the
  /// canonical cut pieces once, retaining every contact in the schedule.
  public var physicalTapeCutCount:Int {
    let ids=Set(attachments.tapes.map(\.componentID))
    return pieces.filter{ids.contains($0.id)}.reduce(0){$0+$1.quantity*production.quantity}
  }

  public init(project:Project,object:ProductObject)throws {
    guard project.objects.contains(where:{$0.id==object.id}),PaperConstruction.isPaper(object) else{throw FormError.invalid("Choose an existing authored planar assembly to prepare construction files.")}
    var paper=try PaperConstruction.definition(for:object)
    guard let definition=paper.authored,definition.version>=4,let production=definition.production else {
      throw FormError.invalid("Configure independent cut pieces and their production materials/instructions before preparing a construction packet.")
    }
    paper.foldPercent=100;paper.openingPercent=0;paper.explosionPercent=nil
    ownerID=object.id;name=object.name;source=paper;self.production=production
    pieces=try ConstructionPieces.resolve(paper)
    layouts=try ConstructionMaterialLayouts.plan(pieces:pieces,production:production)
    attachments=try definition.resolveJointAttachments(stock:paper.stock,foldPercent:100,openingPercent:0,explosionPercent:0,validateEngagement:true)
    let active=Set(pieces.map(\.id))
    let activePanels=Set(pieces.flatMap(\.panelIDs)),values=try definition.resolvedValues()
    let activeJoins=Set(try definition.joins.filter{join in
      guard activePanels.contains(join.firstPanelID),activePanels.contains(join.secondPanelID) else{return false}
      return try join.enabled.map{try FormCADModel.CADExpression.evaluate($0.expression,variables:values)>0.5} ?? true
    }.map(\.id))
    let included=production.steps.filter{$0.componentIDs.isEmpty || !active.isDisjoint(with:Set($0.componentIDs))},includedIDs=Set(included.map(\.id))
    steps=included.map{step in var step=step;step.componentIDs=step.componentIDs.filter(active.contains);step.jointIDs=step.jointIDs.filter(activeJoins.contains);step.after=step.after.filter(includedIDs.contains);return step}
    sourceSnapshot=try Self.snapshot(project:project,object:object)
    sourceData=try JSONEncoder.form.encode(sourceSnapshot)
    guard sourceData.count<=32_000_000 else{throw FormError.invalid("The editable construction snapshot exceeds 32 MB; split its referenced sources.")}
    sourceDigest=ConstructionMaterialLayouts.digest(sourceData)
    issues=layouts.issues
    if steps.isEmpty {issues.append(.init(.error,"assemblyOrder","Author the construction's assembly order before exporting its instructions."))}
    if production.assumptions.isEmpty {issues.append(.init(.warning,"physicalAssumptions","No construction/material allowance assumptions were recorded; physical fit and process approval remain unverified."))}
    if paper.artworkReviewRequired {issues.append(.init(.error,"artworkReview","Review artwork registration after the latest construction change before producing files."))}
    // A bonded cap wrap/inset is not another independent cutting declaration.
    // Do not omit its material silently from an independent-part schedule.
    for panel in paper.authored?.panels ?? [] where panel.features?.wrap != nil || panel.features?.recesses?.contains(where:{$0.insert != nil}) == true {
      issues.append(.init(.error,"implicitMaterialPiece","‘\(panel.name)’ contains wrapping or inserted stock without its own independent cut-piece declaration. Author that material as an identified component before preparing a complete material packet.",pieceIDs:[panel.id]))
    }
  }
  public static func currentSourceDigest(project:Project,object:ProductObject)throws->String {
    ConstructionMaterialLayouts.digest(try JSONEncoder.form.encode(snapshot(project:project,object:object)))
  }
  private static func snapshot(project:Project,object:ProductObject)throws->ConstructionPacketSource {
    let byID=Dictionary(uniqueKeysWithValues:project.objects.map{($0.id,$0)})
    var ids:Set<UUID>=[object.id],processed=Set<UUID>(),relatedPublications=Set<UUID>(),relatedStories=Set<UUID>()
    while true {
      let pending=ids.subtracting(processed)
      for id in pending {
        guard let current=byID[id] else{throw FormError.invalid("An editable construction source is missing; repair its reference before capture.")}
        processed.insert(id)
        if let id=current.artworkSourceID {ids.insert(id)}
        if let id=current.paperConstruction?.insideArtworkSourceID {ids.insert(id)}
        for binding in current.dimensionBindings ?? [] {ids.formUnion(binding.inputs.values.map(\.sourceObjectID))}
        if let definition=current.paperConstruction?.authored {
          ids.formUnion(definition.featureArtworkSourceObjectIDs)
          ids.formUnion((definition.components ?? []).flatMap{[$0.front?.sourceObjectID,$0.back?.sourceObjectID].compactMap{$0}})
        }
        let arts=[current.artwork,current.paperConstruction?.insideArtwork].compactMap{$0}
        for art in arts {
          ids.formUnion(art.elements.compactMap{$0.component?.sourceObjectID})
          ids.formUnion(art.elements.compactMap{$0.objectView?.sourceID})
        }
        if current.sheetAssembly != nil {ids.formUnion(try project.resolvedSheetAssembly(current).sourceObjectIDs)}
      }
      for document in project.publications ?? [] where !ids.isDisjoint(with:Set(document.pages.map(\.objectID))) {
        relatedPublications.insert(document.id);ids.formUnion(document.pages.map(\.objectID));ids.formUnion((document.masters ?? []).map(\.sourceObjectID))
      }
      for story in project.textStories ?? [] where !ids.isDisjoint(with:Set(story.frames.map(\.objectID))) {
        relatedStories.insert(story.id);ids.formUnion(story.frames.map(\.objectID))
      }
      guard ids.count<=1024 else{throw FormError.invalid("A construction packet references more than1024 source objects; split the source dependency scope.")}
      if processed==ids {break}
    }
    var snapshot=project
    snapshot.objects=try ids.sorted{$0.uuidString<$1.uuidString}.map {id in
      guard var value=byID[id] else{throw FormError.invalid("A canonical construction source was removed before capture.")}
      value.position = .init();value.rotation=0;value.canvasProjectionPositions=nil
      value.artwork?.canvasPosition=nil
      if var paper=value.paperConstruction {
        paper.foldPercent=100;paper.openingPercent=0;paper.explosionPercent=nil;paper.insideArtwork?.canvasPosition=nil;value.paperConstruction=paper
        for (key,pose) in ["fold":100.0,"opening":0.0,"explosion":0.0] where value.parameters[key] != nil {value.parameters[key]=pose}
      }
      return value
    }
    let recipes=Set(snapshot.objects.map(\.recipeID));snapshot.recipes=project.recipes.filter{recipes.contains($0.id)}.sorted{$0.id<$1.id}
    let paperRecipes=Set(snapshot.objects.filter{PaperConstruction.isPaper($0)}.map(\.recipeID))
    for index in snapshot.recipes.indices where paperRecipes.contains(snapshot.recipes[index].id) {
      for parameter in snapshot.recipes[index].parameters.indices {
        let key=snapshot.recipes[index].parameters[parameter].id
        if ["fold","opening","explosion"].contains(key) {snapshot.recipes[index].parameters[parameter].value=key == "fold" ? 100:0}
      }
    }
    snapshot.materials=project.materials.sorted{$0.id<$1.id}
    snapshot.publications=project.publications?.filter{relatedPublications.contains($0.id)}
    if snapshot.publications?.isEmpty == true {snapshot.publications=nil}
    snapshot.textStories=project.textStories?.filter{relatedStories.contains($0.id)}
    if snapshot.textStories?.isEmpty == true {snapshot.textStories=nil}
    snapshot.notes=[];snapshot.history=[];snapshot.camera = .init();snapshot.conversationReference=nil;snapshot.printSetups=nil
    snapshot.productionJobs=nil;snapshot.studioPresentation=nil;snapshot.decorationPreparations=nil;snapshot.garmentBlocks=nil;snapshot.collectionProduction=nil
    snapshot.createdAt=Date(timeIntervalSince1970:0);snapshot.updatedAt=snapshot.createdAt
    return .init(project:snapshot,ownerID:object.id)
  }
  public var assetNames:Set<String> {
    var names=Set<String>()
    for object in sourceSnapshot.project.objects {
      if let asset=object.asset {names.insert(asset)}
      if let asset=object.paperTemplateReference?.originalAsset {names.insert(asset)}
      for art in [object.artwork,object.paperConstruction?.insideArtwork].compactMap({$0}) {
        names.formUnion(art.renderedAssetNames);names.formUnion((art.imports ?? []).map(\.asset))
        if let profile=art.outputColorProfile {names.insert(profile.asset)}
      }
    }
    for swatch in sourceSnapshot.project.swatches ?? [] {if let profile=swatch.printInk?.profile {names.insert(profile.asset)}}
    return names
  }
  public func metadata()throws->[String:Any] {
    func json<T:Encodable>(_ value:T)throws->Any {try JSONSerialization.jsonObject(with:JSONEncoder.form.encode(value))}
    return ["source_digest":sourceDigest,"object_id":ownerID.uuidString,"name":name,"units":"mm","valid":isValid,
      "piece_count":pieces.count,"physical_cut_count":pieces.reduce(0){$0+$1.quantity*production.quantity},"production_quantity":production.quantity,"total_tape_cut_count":physicalTapeCutCount,
      "pieces":try json(pieces),"material_layouts":try json(layouts),"assembly_order":try json(steps),"attachments":try json(attachments),"issues":try json(issues),
      "assumptions":production.assumptions,"nominal_geometry":true,"tool_compensation_applied":false,"declared_kerf_mm":production.declaredKerfMM as Any? ?? NSNull(),
      "physical_production_verified":false,"machine_contacted":false,"inventory_deducted":false]
  }
}

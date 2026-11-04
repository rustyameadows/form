import AppKit
import FormCore

struct PartAssemblyPreview {
  var object:ProductObject
  var project:Project
  var activePieces:Int
  var declaredPieces:Int
  var changedPieceNames:[String]
  var changedActivePieceNames:[String]
  var tapeCount:Int
  var stapleCount:Int
  var preflight:PaperPreflight
}

/// Native fields and public MCP use the same Core source and transaction.
@MainActor enum PartAssemblyNativeEditing {
  @discardableResult static func selectTablePart(store:StudioStore,projectID:UUID,objectID:UUID,componentID:String)->Bool {
    guard let project=store.project,project.id==projectID,store.primary?.id==objectID,
      let object=project.objects.first(where:{$0.id==objectID}),let definition=object.paperConstruction?.authored,
      let component=try? definition.activeComponents().first(where:{$0.id==componentID}) else{return false}
    // Explicit Table controls change only the piece highlight. They neither
    // select another owner nor open an inspector or move either camera.
    store.constructionTableTarget=nil
    store.paperSelectionObjectID=objectID;store.paperSelectedPanelID=component.rootPanelID;store.paperSelectedFoldID=nil
    store.changed(save:false);store.synchronizeScene();return true
  }
  static func preview(project:Project,objectID:UUID,definition:PlanarConstructionDefinition)throws->PartAssemblyPreview {
    guard let index=project.objects.firstIndex(where:{$0.id==objectID}),!project.objects[index].locked else {
      throw FormError.missing("Choose an unlocked current construction.")
    }
    var candidate=project,object=project.objects[index],paper=try PaperConstruction.definition(for:object)
    let before=paper.authored;paper.authored=definition
    paper.stock=try PlanarConstructionDefinition.resizedStock(paper.stock,thickness:definition.number(definition.stockThickness))
    try PaperConstructionEngine.validate(paper)
    _=try paper.resolvedPanels()
    let attachments=try definition.resolveJointAttachments(stock:paper.stock,foldPercent:100,openingPercent:0,explosionPercent:0,validateEngagement:true)
    object.paperConstruction=paper;object.parameters=PaperConstructionEngine.parameters(paper);candidate.objects[index]=object
    let recipe=ConstructionSourceEditing.recipe(definition,id:object.recipeID)
    if let i=candidate.recipes.firstIndex(where:{$0.id==recipe.id}){candidate.recipes[i]=recipe}else{candidate.recipes.append(recipe)}
    try candidate.reconcilePhysicalDimensions(previous:project);try candidate.validateArtworkLinks()
    object=candidate.objects[index]
    let preflight=try PaperConstruction.definition(for:object).preflight()
    let old=Dictionary((before?.components ?? []).map{($0.id,$0)},uniquingKeysWith:{$1})
    let dimensionChange=before?.parameters != definition.parameters || before?.derived != definition.derived
    let active=try definition.activeComponents(),activeIDs=Set(active.map(\.id))
    let changed=(definition.components ?? []).filter{dimensionChange || old[$0.id] != $0}
    return .init(object:object,project:candidate,activePieces:active.count,declaredPieces:definition.components?.count ?? 0,
      changedPieceNames:changed.map(\.name),changedActivePieceNames:changed.filter{activeIDs.contains($0.id)}.map(\.name),
      tapeCount:attachments.tapes.reduce(0){$0+$1.quantity},stapleCount:attachments.staples.count,preflight:preflight)
  }
  @discardableResult static func apply(store:StudioStore,projectID:UUID,objectID:UUID,expectedRevision:String,definition:PlanarConstructionDefinition,adopting:Bool=false)->Bool {
    do {
      guard let project=store.project,project.id==projectID,
        let object=project.objects.first(where:{$0.id==objectID}),
        let current=try PaperConstruction.definition(for:object).authored,
        try ConstructionSourceEditing.revision(current)==expectedRevision else {
        throw FormError.invalid("The construction changed while these controls were open. Reload it before applying.")
      }
      _=try preview(project:project,objectID:objectID,definition:definition)
      store.artworkSession.canvas?.finishText()
      if adopting {
        try store.engine.edit("Adopted independent construction parts",source:"Studio"){candidate in
          guard candidate.id==projectID else{throw FormError.invalid("The open project changed before adoption.")}
          try candidate.adoptIndependentConstructionParts(objectID:objectID,expectedRevision:expectedRevision,definition:definition)
        }
      }else{
        _=try store.engine.call("form_construction",arguments:["command":"configure","object_id":objectID.uuidString,"expected_revision":expectedRevision,"definition":try jsonObject(definition)],source:"Studio")
      }
      store.changed();store.synchronizeScene();return true
    }catch{store.error=error.localizedDescription;return false}
  }
  @discardableResult static func importStarter(store:StudioStore,projectID:UUID,starter:ConstructionStarter)->UUID? {
    do {
      guard let project=store.project,project.id==projectID else{throw FormError.invalid("Open the intended project before adding a construction.")}
      let edge=project.tablePresentationObjects.map{$0.position.x+$0.footprintWidth/2}.max()
      let position=Vector3(edge.map{$0+200} ?? 0,0,0)
      var result:ConstructionStarterImportResult?
      try store.engine.edit("Added construction starter",source:"Studio"){candidate in
        guard candidate.id==projectID else{throw FormError.invalid("The open project changed before adding its starter.")}
        result=try candidate.importConstructionStarter(starter,position:position)
      }
      guard let result else{return nil}
      store.engine.selection=[result.objectID];store.changed();store.synchronizeScene();store.scene?.focusSelection()
      return result.objectID
    }catch{store.error=error.localizedDescription;return nil}
  }
  @discardableResult static func createArtwork(store:StudioStore,projectID:UUID,objectID:UUID,componentID:String,side:PaperFinishAssignment.Side,expectedRevision:String)->UUID? {
    do {
      guard store.project?.id==projectID else{throw FormError.invalid("The open project changed before artwork creation.")}
      var id:UUID?
      try store.engine.edit("Created cut-piece artwork",source:"Studio"){candidate in
        guard candidate.id==projectID else{throw FormError.invalid("The open project changed before artwork creation.")}
        id=try candidate.createConstructionPartArtwork(objectID:objectID,componentID:componentID,side:side,expectedRevision:expectedRevision)
      }
      store.changed()
      if let id {
        store.showSurface(.artwork,ensureCanvasIfNeeded:false);store.artworkSession.activate(id)
        store.artworkSession.canvas?.synchronize();_=store.artworkSession.canvas?.fit(frameIDs:[id])
      }
      return id
    }catch{store.error=error.localizedDescription;return nil}
  }
}

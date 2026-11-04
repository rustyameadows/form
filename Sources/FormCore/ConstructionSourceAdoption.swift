import Foundation
import FormCADModel

extension ConstructionSourceEditing {
  /// Deliberate adoption of independent authored roots. No product names or
  /// parameter meanings are inferred, and every original face/source ID stays.
  public static func independentPartsDefinition(_ object:ProductObject)throws->PlanarConstructionDefinition {
    let paper=try PaperConstruction.definition(for:object)
    guard var definition=paper.authored,let components=definition.components,!components.isEmpty else {
      throw FormError.invalid("Choose an authored source with explicit independent cut-piece roots.")
    }
    guard definition.version<4 else{throw FormError.invalid("This source already has independent part controls.")}
    definition.version=4
    let group=PlanarComponentGroupDefinition(id:UUID().uuidString,name:definition.name)
    definition.groups=[group]
    definition.components=components.map {original in
      var piece=original;piece.groupID=group.id;piece.stock=paper.stock
      piece.stockThickness=definition.stockThickness;piece.quantity=1
      return piece
    }
    definition.controls = .init(groups:[.init(id:"dimensions",title:"Construction dimensions")],parameters:definition.parameters.map {
      .init(parameter:$0.name,label:$0.name,group:"dimensions")
    })
    _=try definition.net();return definition
  }
  public static func adoptingIndependentParts(in original:Project,objectID:UUID,expectedRevision:String,definition requested:PlanarConstructionDefinition?=nil)throws->Project {
    guard let index=original.objects.firstIndex(where:{$0.id==objectID}),!original.objects[index].locked,
      let previous=try PaperConstruction.definition(for:original.objects[index]).authored,
      try revision(previous)==expectedRevision else {
      throw FormError.invalid("The construction changed before adoption. Review its current source first.")
    }
    guard previous.version<4,original.objects.filter({$0.designID==original.objects[index].designID}).count==1 else {
      throw FormError.invalid("Adopt an independent authored source before linking shared construction variants.")
    }
    let next=try requested ?? independentPartsDefinition(original.objects[index])
    guard next.version==4,Set(previous.panels.map(\.id)).isSubset(of:Set(next.panels.map(\.id))),
      Set((previous.components ?? []).map(\.id)).isSubset(of:Set((next.components ?? []).map(\.id))) else {
      throw FormError.invalid("Adoption must retain the existing stable board and component identities.")
    }
    _=try next.net();var candidate=original,object=original.objects[index],paper=try PaperConstruction.definition(for:object)
    paper.authored=next;paper.stock=try PlanarConstructionDefinition.resizedStock(paper.stock,thickness:next.number(next.stockThickness))
    paper.annotations.append(.init(kind:.assembly,text:"Adopted the saved independent pieces into editable assembly groups. Existing dimension and clearance meanings are retained; new material, fastening and finished-fit assumptions require explicit review.",view:"assembled"))
    object.paperConstruction=paper;object.parameters=PaperConstructionEngine.parameters(paper)
    candidate.objects[index]=object
    let recipe=recipe(next,id:object.recipeID)
    if let i=candidate.recipes.firstIndex(where:{$0.id==recipe.id}){candidate.recipes[i]=recipe}else{candidate.recipes.append(recipe)}
    try candidate.reconcilePhysicalDimensions(previous:original);try candidate.validateArtworkLinks();return candidate
  }
  /// Adds bounded extrema aliases rather than freezing a source's dimensions.
  /// The flat pattern and upright face continue using the same canonical ink.
  public static func creatingPartArtwork(in original:Project,objectID:UUID,componentID:String,side:PaperFinishAssignment.Side,expectedRevision:String)throws->(Project,UUID) {
    guard let index=original.objects.firstIndex(where:{$0.id==objectID}),!original.objects[index].locked,
      var definition=try PaperConstruction.definition(for:original.objects[index]).authored,
      definition.version>=4,try revision(definition)==expectedRevision,
      let componentIndex=definition.components?.firstIndex(where:{$0.id==componentID}) else {
      throw FormError.invalid("The selected cut piece changed before artwork creation.")
    }
    guard original.objects.filter({$0.designID==original.objects[index].designID}).count==1 else {
      throw FormError.invalid("Create canonical piece artwork before linking shared construction variants.")
    }
    let component=definition.components![componentIndex]
    if let face=side == .outside ? component.front:component.back{return(original,face.sourceObjectID)}
    let owned=Set(try definition.componentPanels()[componentID] ?? []),points=definition.panels.filter{owned.contains($0.id)}.flatMap(\.polygon)
    guard !points.isEmpty else{throw FormError.invalid("The selected cut piece has no source material.")}
    let prefix="source"+String(UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(8))
    var aliases=definition.derived ?? [:]
    var aliasOrdinal=0
    func existing(_ expression:String)->String {
      aliases.keys.sorted().first(where:{aliases[$0]?.expression==expression}) ?? expression
    }
    func named(_ expression:String,_ suffix:String)throws->String {
      if aliases[expression] != nil || definition.parameters.contains(where:{$0.name==expression}) {return expression}
      let reused=existing(expression)
      if reused != expression{return reused}
      guard expression.utf8.count<=256,aliases.count<256 else{throw FormError.invalid("This source exceeds the derived-expression budget. Reuse an existing canonical artwork source or simplify its expressions.")}
      aliasOrdinal+=1;let name=prefix+suffix+String(aliasOrdinal);aliases[name]=CADScalar(expression);return name
    }
    func compound(_ operation:String,_ left:String,_ right:String,_ suffix:String)throws->String {
      var a=existing(left),b=existing(right)
      func expression()->String {operation=="subtract" ? "(\(a))-(\(b))":"\(operation)(\(a),\(b))"}
      if expression().utf8.count>256 {
        // Materialize only overflowing chunks. Simple rectangular patterns need
        // just two final dimension aliases, independent of their vertex count.
        if a.utf8.count>=b.utf8.count {a=try named(a,suffix+"A")}else{b=try named(b,suffix+"B")}
        if expression().utf8.count>256 {a=try named(a,suffix+"A");b=try named(b,suffix+"B")}
      }
      guard expression().utf8.count<=256 else{throw FormError.invalid("This piece needs shorter expressions before creating dynamic artwork extents.")}
      return existing(expression())
    }
    func dimension(_ expressions:[String],axis:String)throws->String {
      let expressions=Array(Set(expressions)).sorted()
      guard var low=expressions.first else{throw FormError.invalid("The selected piece has no source coordinates.")}
      var high=low
      for expression in expressions.dropFirst() {
        low=try compound("min",low,expression,axis+"Min")
        high=try compound("max",high,expression,axis+"Max")
      }
      return try named(compound("subtract",high,low,axis),axis+"Extent")
    }
    let width=try dimension(points.map{$0.x.expression},axis:"X"),height=try dimension(points.map{$0.y.expression},axis:"Y")
    guard aliases.count<=256 else{throw FormError.invalid("This source exceeds the derived-expression budget. Reuse an existing canonical artwork source or simplify its aliases.")}
    definition.derived=aliases
    var artwork=Artwork(background:"#FFFFFF");artwork.backgroundOpacity=0
    let source=ConstructionStarterArtworkSource(name:component.name+(side == .outside ? " / Front artwork":" / Back artwork"),width:CADScalar(width),height:CADScalar(height),artwork:artwork)
    let face=SheetAssemblyFace(sourceObjectID:source.id)
    if side == .outside{definition.components![componentIndex].front=face}else{definition.components![componentIndex].back=face}
    _=try definition.net();var candidate=original,owner=original.objects[index],paper=try PaperConstruction.definition(for:owner)
    paper.authored=definition;owner.paperConstruction=paper;owner.parameters=PaperConstructionEngine.parameters(paper);candidate.objects[index]=owner
    let newRecipe=recipe(definition,id:owner.recipeID)
    if let i=candidate.recipes.firstIndex(where:{$0.id==owner.recipeID}){candidate.recipes[i]=newRecipe}else{candidate.recipes.append(newRecipe)}
    let art=try self.source(source,ownerID:objectID,values:definition.resolvedValues(),project:&candidate)
    candidate.objects.append(art);try candidate.reconcilePhysicalDimensions(previous:original);try candidate.validateArtworkLinks()
    return(candidate,source.id)
  }
}

extension Project {
  public mutating func adoptIndependentConstructionParts(objectID:UUID,expectedRevision:String,definition:PlanarConstructionDefinition?=nil)throws {
    self=try ConstructionSourceEditing.adoptingIndependentParts(in:self,objectID:objectID,expectedRevision:expectedRevision,definition:definition)
  }
  @discardableResult public mutating func createConstructionPartArtwork(objectID:UUID,componentID:String,side:PaperFinishAssignment.Side,expectedRevision:String)throws->UUID {
    let (candidate,id)=try ConstructionSourceEditing.creatingPartArtwork(in:self,objectID:objectID,componentID:componentID,side:side,expectedRevision:expectedRevision);self=candidate;return id
  }
}

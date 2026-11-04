import Foundation
import FormCADModel

/// Saved relationships between physical objects, independent of artwork links.
/// A reference neither consumes its source on the Table nor copies its geometry.
public enum PhysicalDimensionMeasurement:String,Codable,CaseIterable,Sendable {
  case width,height,depth,parameter,trimWidth,trimHeight,textBlockThickness,bindingAllowance,bindingFlexWidth,spineThickness,closedWidth,closedHeight,closedThickness
}
public struct PhysicalDimensionReference:Codable,Equatable,Sendable {
  public var sourceObjectID:UUID
  public var measurement:PhysicalDimensionMeasurement
  public var parameter:String?
  public init(sourceObjectID:UUID,measurement:PhysicalDimensionMeasurement,parameter:String?=nil) {
    self.sourceObjectID=sourceObjectID;self.measurement=measurement;self.parameter=parameter
  }
}
public struct PhysicalDimensionBinding:Codable,Equatable,Sendable {
  public var parameter:String
  public var expression:String
  public var inputs:[String:PhysicalDimensionReference]
  public init(parameter:String,expression:String,inputs:[String:PhysicalDimensionReference]) {
    self.parameter=parameter;self.expression=expression;self.inputs=inputs
  }
}
/// Nonprinting physical regions and explicit translation anchors. Artwork is
/// still canonical: an anchor moves its selected layers by a physical delta;
/// it never scales type, paths, images, borders or unanchored content.
public struct PhysicalArtworkRegion:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var name:String
  public var origin:CADExpressionPoint2
  public var size:CADExpressionPoint2
  public var anchors:[PhysicalArtworkRegionAnchor]?
  public init(id:String,name:String,origin:CADExpressionPoint2,size:CADExpressionPoint2,anchors:[PhysicalArtworkRegionAnchor]?=nil) {
    self.id=id;self.name=name;self.origin=origin;self.size=size;self.anchors=anchors
  }
}
public struct PhysicalArtworkRegionAnchor:Codable,Equatable,Sendable {
  public var elementIDs:[UUID]
  public var horizontal:Double
  public var vertical:Double
  public init(elementIDs:[UUID],horizontal:Double=0,vertical:Double=0) {
    self.elementIDs=elementIDs;self.horizontal=horizontal;self.vertical=vertical
  }
}
public struct ResolvedPhysicalArtworkRegion:Equatable,Sendable {
  public var id:String,name:String
  public var origin:Point2,size:Point2
}

extension Project {
  private var hasPhysicalDimensionRelationships:Bool {
    for index in objects.indices {
      if objects[index].dimensionBindings?.isEmpty == false || objects[index].artworkRegions?.isEmpty == false{return true}
    }
    return false
  }
  private func physicalDimension(_ reference:PhysicalDimensionReference,measurements:inout [UUID:SheetAssemblyMeasurements])throws->Double {
    guard let source=objects.first(where:{$0.id==reference.sourceObjectID}) else{throw FormError.invalid("A dimension source is missing. Repair its relationships before removing it.")}
    if reference.measurement == .parameter {
      guard let key=reference.parameter,let value=source.parameters[key],value.isFinite else{throw FormError.invalid("A dimension reference needs an existing numeric source parameter.")}
      return value
    }
    guard reference.parameter==nil else{throw FormError.invalid("Only parameter measurements accept a parameter key.")}
    if source.sheetAssembly != nil {
      let m:SheetAssemblyMeasurements
      if let cached=measurements[source.id] {m=cached}else{m=try sheetAssemblyMeasurements(source);measurements[source.id]=m}
      switch reference.measurement {
      case .width,.closedWidth:return m.closedWidth
      case .height,.closedHeight:return m.closedHeight
      case .depth,.closedThickness:return m.closedThickness
      case .trimWidth:return m.trimWidth
      case .trimHeight:return m.trimHeight
      case .textBlockThickness:return m.textBlockThickness
      case .bindingAllowance:return m.bindingAllowance
      case .bindingFlexWidth:return m.bindingFlexWidth
      case .spineThickness:return m.spineThickness
      case .parameter:break
      }
    } else {
      if [.closedWidth,.closedHeight,.closedThickness].contains(reference.measurement),PaperConstruction.isPaper(source) {
        var paper=try PaperConstruction.definition(for:source);paper.openingPercent=0
        let net=try paper.net(),poses=try paper.resolvedPanels(foldPercent:100)
        var low=Vector3(.infinity,.infinity,.infinity),high=Vector3(-.infinity,-.infinity,-.infinity)
        let values=try (paper.authored?.resolvedValues() ?? [:]).merging(["fold":100,"opening":0]){_,new in new}
        for panel in net.panels {
          guard let matrix=poses.first(where:{$0.panelID==panel.id})?.flatToWorld else{continue}
          for point in try panel.physicalBoundarySamples(stock:paper.stock,variables:values,worldMatrix:matrix) {
            let p=PaperRigidMatrix.point(matrix,point)
            low = .init(min(low.x,p.x),min(low.y,p.y),min(low.z,p.z));high = .init(max(high.x,p.x),max(high.y,p.y),max(high.z,p.z))
          }
        }
        switch reference.measurement {
        case .closedWidth:return high.x-low.x
        case .closedHeight:return high.y-low.y
        default:return high.z-low.z
        }
      }
      switch reference.measurement {
      case .width:return source.artworkSize.x
      case .height:return source.artworkSize.y
      case .depth:
        if let caliper=source.paperConstruction?.stock.resolvedThicknessMM {return caliper}
        if let value=source.parameters["thickness"],value>0{return value}
      default:break
      }
    }
    throw FormError.invalid("The source does not provide the requested physical measurement.")
  }
  /// Evaluate in dependency order. Artwork links are deliberately absent from
  /// this graph: a cover source may depend on the book it supplies graphics to.
  private func physicalDimensionOrder()throws->[UUID] {
    let byID=Dictionary(uniqueKeysWithValues:objects.map{($0.id,$0)})
    var visited=Set<UUID>(),visiting=Set<UUID>(),order=[UUID]()
    func visit(_ id:UUID)throws {
      if visited.contains(id){return}
      guard let object=byID[id],visiting.insert(id).inserted else{throw FormError.invalid("Physical dimension dependencies contain a cycle or missing object.")}
      let bindings=object.dimensionBindings ?? []
      if !bindings.isEmpty,object.relationship=="variant" || !bindings.isEmpty && objects.contains(where:{$0.id != object.id && $0.designID==object.designID && $0.relationship=="variant"}) {throw FormError.invalid("Detach linked variant parameters before declaring independent physical dimension targets.")}
      guard bindings.count<=32,Set(bindings.map(\.parameter)).count==bindings.count else{throw FormError.invalid("Use at most 32 dimension bindings, once per target parameter.")}
      for binding in bindings {
        guard let recipe=recipe(object.recipeID),recipe.parameters.contains(where:{$0.id==binding.parameter}),
          binding.inputs.count<=64,binding.expression.utf8.count<=256 else{throw FormError.invalid("Dimension bindings need existing target parameters and bounded expressions/inputs.")}
        let names=try CADExpression.referencedNames(in:binding.expression)
        let boundTargets=Set(bindings.map(\.parameter))
        guard names.isDisjoint(with:boundTargets),binding.inputs.keys.allSatisfy({key in
          CADExpression.validName(key) && !object.parameters.keys.contains(key)
        }) else{throw FormError.invalid("Dimension expressions must not read their own derived targets or shadow local parameters.")}
        for reference in binding.inputs.values {try visit(reference.sourceObjectID)}
      }
      if let assembly=object.sheetAssembly,let document=publications?.first(where:{$0.id==assembly.publicationID}) {
        for page in document.pages {try visit(page.objectID)}
      }
      visiting.remove(id);visited.insert(id);order.append(id)
    }
    for object in objects {try visit(object.id)}
    return order
  }
  public func resolvedArtworkRegions(for object:ProductObject)throws->[ResolvedPhysicalArtworkRegion] {
    let regions=object.artworkRegions ?? []
    guard regions.count<=64,Set(regions.map(\.id)).count==regions.count,
      regions.isEmpty || isIndependentFlatArtworkSource(object) else{throw FormError.invalid("Use up to 64 distinct construction regions on an independent canonical artwork source.")}
    var anchored=Set<UUID>()
    return try regions.map{region in
      func number(_ s:CADScalar)throws->Double {try CADExpression.evaluate(s.expression,variables:object.parameters)}
      let origin=try Point2(number(region.origin.x),number(region.origin.y)),size=try Point2(number(region.size.x),number(region.size.y))
      guard !region.id.isEmpty,region.id.utf8.count<=128,!region.name.isEmpty,region.name.utf8.count<=256,
        [origin.x,origin.y,size.x,size.y].allSatisfy({$0.isFinite && abs($0)<=100000}),size.x>0,size.y>0,
        (region.anchors?.count ?? 0)<=256 else{throw FormError.invalid("Construction regions need bounded names and positive physical sizes.")}
      for anchor in region.anchors ?? [] {
        guard (0...1).contains(anchor.horizontal),(0...1).contains(anchor.vertical),!anchor.elementIDs.isEmpty,anchor.elementIDs.count<=256 else{throw FormError.invalid("Region anchors need layer IDs and normalized positions from zero to one.")}
        for id in anchor.elementIDs {
          guard object.artwork?.elements.contains(where:{$0.id==id && $0.parentID==nil})==true,anchored.insert(id).inserted,
            object.artworkParameterBindings?.contains(where:{$0.elementID==id && ($0.property == .x || $0.property == .y)}) != true else{throw FormError.invalid("Anchor top-level layers or groups with one position authority; remove nested/conflicting position bindings.")}
        }
      }
      return .init(id:region.id,name:region.name,origin:origin,size:size)
    }
  }
  public mutating func reconcilePhysicalDimensions(previous:Project)throws {
    guard hasPhysicalDimensionRelationships else{return}
    // Resolve all values into the transaction's candidate, never the open project.
    let order=try physicalDimensionOrder()
    let indices=Dictionary(uniqueKeysWithValues:objects.indices.map{(objects[$0].id,$0)})
    var measurements=[UUID:SheetAssemblyMeasurements]()
    for id in order {
      guard let index=indices[id],!((objects[index].dimensionBindings?.isEmpty ?? true) && (objects[index].artworkRegions?.isEmpty ?? true)) else{continue}
      var parameters=objects[index].parameters
      for binding in objects[index].dimensionBindings ?? [] {
        var variables=parameters
        for (name,reference) in binding.inputs {variables[name]=try physicalDimension(reference,measurements:&measurements)}
        let value=try CADExpression.evaluate(binding.expression,variables:variables)
        guard value.isFinite else{throw FormError.invalid("Derived dimensions must be finite.")}
        parameters[binding.parameter]=value
      }
      if parameters != objects[index].parameters {
        guard !objects[index].locked else{throw FormError.invalid("Unlock a dimension-dependent object before changing its source dimensions.")}
        try recipe(objects[index].recipeID)?.validate(parameters)
        let previousObject=objects[index]
        objects[index].parameters=parameters
        if PaperConstruction.isPaper(objects[index]) {objects[index]=try PaperConstructionEngine.synchronized(objects[index],previous:previousObject)}
      }
      let now=objects[index],old=previous.objects.first{$0.id==id}
      if old?.parameters != now.parameters,now.artworkParameterBindings?.isEmpty==false {try applyArtworkParameterBindings(to:id)}
      let current=try resolvedArtworkRegions(for:objects[index])
      guard let old,old.parameters != objects[index].parameters,old.artworkRegions==objects[index].artworkRegions else{continue}
      let earlier=try previous.resolvedArtworkRegions(for:old)
      for region in objects[index].artworkRegions ?? [] {
        guard let a=earlier.first(where:{$0.id==region.id}),let b=current.first(where:{$0.id==region.id}) else{continue}
        for anchor in region.anchors ?? [] {
          let dx=b.origin.x-a.origin.x+anchor.horizontal*(b.size.x-a.size.x),dy=b.origin.y-a.origin.y+anchor.vertical*(b.size.y-a.size.y)
          guard dx != 0 || dy != 0 else{continue}
          guard !objects[index].locked else{throw FormError.invalid("Unlock an anchored artwork source before changing construction dimensions.")}
          for e in objects[index].artwork!.elements.indices where anchor.elementIDs.contains(objects[index].artwork!.elements[e].id) {
            if let previousElement=old.artwork?.elements.first(where:{$0.id==objects[index].artwork!.elements[e].id}) {
              let affine=previousElement.affine ?? .init(),det=affine.a*affine.d-affine.b*affine.c
              guard abs(det)>1e-12 else{throw FormError.invalid("An anchored layer needs an invertible transform.")}
              let targetX=previousElement.x+(affine.d*dx-affine.c*dy)/det,targetY=previousElement.y+(-affine.b*dx+affine.a*dy)/det
              let edited=objects[index].artwork!.elements[e]
              guard edited.affine==previousElement.affine,
                (edited.x==previousElement.x || abs(edited.x-targetX)<1e-8),
                (edited.y==previousElement.y || abs(edited.y-targetY)<1e-8) else{throw FormError.invalid("Move anchored artwork and change its construction dimensions in separate edits to preserve placement intent.")}
              objects[index].artwork!.elements[e].x=targetX;objects[index].artwork!.elements[e].y=targetY
            }
          }
        }
      }
    }
  }
  public func validatePhysicalDimensions()throws {
    guard hasPhysicalDimensionRelationships else{return}
    var candidate=self
    try candidate.reconcilePhysicalDimensions(previous:self)
    guard zip(objects,candidate.objects).allSatisfy({$0.parameters==$1.parameters && $0.artwork==$1.artwork}) else{throw FormError.invalid("Dependent dimensions are stale. Reconcile the project in its editing transaction.")}
  }
}

extension SheetAssemblyCommands {
  @discardableResult public static func createArtworkSource(in project:inout Project,name:String,size:Point2)throws->UUID {
    guard !name.isEmpty,name.utf8.count<=500 else{throw FormError.invalid("Use a bounded artwork source name.")}
    var source=try project.makeObject(recipeID:"artboard",name:name,parameters:["width":size.x,"depth":size.y])
    source.artwork = .init(background:"#FFFFFF");source.artwork?.backgroundOpacity=0;source.canvasSourceOnly=true
    project.objects.append(source);return source.id
  }
}

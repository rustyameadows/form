import Foundation
import FormCADModel

/// Source-authored manufacturing information for any independently cut planar
/// assembly. A fold guide is deliberately distinct from a score or groove.
public enum ConstructionGuideRole:String,Codable,CaseIterable,Sendable {
  case score,groove,fold,turnIn,seam,glue,orientation,registration,annotation
  public var isToolPath:Bool {self == .score || self == .groove}
}
public struct ConstructionPatternGuide:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var componentID:String
  public var role:ConstructionGuideRole
  public var points:[CADExpressionPoint2]
  public var closed:Bool
  public var label:String
  public init(id:String,componentID:String,role:ConstructionGuideRole,points:[CADExpressionPoint2],closed:Bool=false,label:String="") {
    self.id=id;self.componentID=componentID;self.role=role;self.points=points;self.closed=closed;self.label=label
  }
  /// Guides use the cut piece's local millimeters, including saved alternatives
  /// that are currently disabled. Candidate acceptance and output share this rule.
  public func resolvedPoints(values:[String:Double],bounds:PaperBounds)throws->[Point2] {
    let result:[Point2]
    do {result=try points.map{try Point2(CADExpression.evaluate($0.x.expression,variables:values),CADExpression.evaluate($0.y.expression,variables:values))}}
    catch {throw FormError.invalid("Pattern guide ‘\(id)’ has an invalid coordinate expression: \(error.localizedDescription)")}
    guard result.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.x>=(-1e-7) && $0.y>=(-1e-7) && $0.x<=bounds.width+1e-7 && $0.y<=bounds.height+1e-7}) else {
      throw FormError.invalid("Pattern guide ‘\(id)’ lies outside its actual cut-piece extent.")
    }
    return result
  }
}
public struct ConstructionStockFormat:Codable,Equatable,Identifiable,Sendable {
  public enum Surface:String,Codable,CaseIterable,Sendable {case sheet,roll}
  public enum Grain:String,Codable,CaseIterable,Sendable {case directional,bidirectional,unrestricted}
  public var id:String
  public var name:String
  public var componentIDs:[String]
  public var surface:Surface
  public var widthMM:Double
  public var lengthMM:Double
  public var marginMM:Double
  public var spacingMM:Double
  public var grain:Grain
  public var allowRotation:Bool
  /// An explicitly declared additional purchasing allowance; never silently
  /// changes the physical cut quantity or reported net material area.
  public var wasteAllowanceFraction:Double
  public init(id:String,name:String,componentIDs:[String],surface:Surface = .sheet,widthMM:Double=700,lengthMM:Double=1000,
    marginMM:Double=10,spacingMM:Double=4,grain:Grain = .bidirectional,allowRotation:Bool=true,wasteAllowanceFraction:Double=0) {
    self.id=id;self.name=name;self.componentIDs=componentIDs;self.surface=surface;self.widthMM=widthMM;self.lengthMM=lengthMM
    self.marginMM=marginMM;self.spacingMM=spacingMM;self.grain=grain;self.allowRotation=allowRotation;self.wasteAllowanceFraction=wasteAllowanceFraction
  }
  public func validate()throws {
    guard !id.isEmpty,id.utf8.count<=128,!name.isEmpty,name.utf8.count<=256,
      !componentIDs.isEmpty,componentIDs.count<=128,Set(componentIDs).count==componentIDs.count,
      [widthMM,lengthMM,marginMM,spacingMM,wasteAllowanceFraction].allSatisfy(\.isFinite),
      (50...5000).contains(widthMM),(50...5000).contains(lengthMM),(0...100).contains(marginMM),
      (0.1...500).contains(spacingMM),(0...1).contains(wasteAllowanceFraction),
      widthMM>marginMM*2,lengthMM>marginMM*2 else {
      throw FormError.invalid("A material format needs distinct source pieces, 50–5000 mm stock edges, usable margins, positive spacing and an explicit 0–100% waste allowance.")
    }
  }
}
public struct ConstructionAssemblyStep:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var title:String
  public var componentIDs:[String]
  public var jointIDs:[String]
  public var after:[String]
  public var instructions:String
  public init(id:String,title:String,componentIDs:[String]=[],jointIDs:[String]=[],after:[String]=[],instructions:String) {
    self.id=id;self.title=title;self.componentIDs=componentIDs;self.jointIDs=jointIDs;self.after=after;self.instructions=instructions
  }
}
public struct ConstructionDrawingView:Codable,Equatable,Identifiable,Sendable {
  public enum Projection:String,Codable,CaseIterable,Sendable {case isometric,top,front,side}
  public enum SectionAxis:String,Codable,CaseIterable,Sendable {case x,z}
  public var id:String,title:String
  public var projection:Projection
  public var openingPercent:Double,explosionPercent:Double
  public var componentIDs:[String]?
  public var sectionAxis:SectionAxis?
  public var sectionOffsetMM:CADScalar?
  public init(id:String,title:String,projection:Projection = .isometric,openingPercent:Double=0,explosionPercent:Double=0,
    componentIDs:[String]?=nil,sectionAxis:SectionAxis?=nil,sectionOffsetMM:CADScalar?=nil) {
    self.id=id;self.title=title;self.projection=projection;self.openingPercent=openingPercent;self.explosionPercent=explosionPercent
    self.componentIDs=componentIDs;self.sectionAxis=sectionAxis;self.sectionOffsetMM=sectionOffsetMM
  }
}
public struct ConstructionProductionDefinition:Codable,Equatable,Sendable {
  public var version:Int
  public var materials:[ConstructionStockFormat]
  public var steps:[ConstructionAssemblyStep]
  public var assumptions:[String]
  public var guides:[ConstructionPatternGuide]
  public var views:[ConstructionDrawingView]
  public var foldRoles:[String:ConstructionGuideRole]
  public var quantity:Int
  public var labels:Bool
  public var registrationMarks:Bool
  public var bleedMM:Double
  /// Declared process assumption only. This packet's cut geometry is nominal;
  /// the manifest explicitly records that no cutter compensation was applied.
  public var declaredKerfMM:Double?
  public var processNotes:String
  public init(materials:[ConstructionStockFormat]=[],steps:[ConstructionAssemblyStep]=[],assumptions:[String]=[],
    guides:[ConstructionPatternGuide]=[],views:[ConstructionDrawingView]=[],foldRoles:[String:ConstructionGuideRole]=[:],quantity:Int=1,
    labels:Bool=true,registrationMarks:Bool=false,bleedMM:Double=0,declaredKerfMM:Double?=nil,processNotes:String="") {
    version=1;self.materials=materials;self.steps=steps;self.assumptions=assumptions;self.guides=guides;self.views=views;self.foldRoles=foldRoles
    self.quantity=quantity;self.labels=labels;self.registrationMarks=registrationMarks;self.bleedMM=bleedMM
    self.declaredKerfMM=declaredKerfMM;self.processNotes=processNotes
  }
  private enum CodingKeys:String,CodingKey {case version,materials,steps,assumptions,guides,views,foldRoles,quantity,labels,registrationMarks,bleedMM,declaredKerfMM,processNotes}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    version=try c.decodeIfPresent(Int.self,forKey:.version) ?? 1
    materials=try c.decodeIfPresent([ConstructionStockFormat].self,forKey:.materials) ?? []
    steps=try c.decodeIfPresent([ConstructionAssemblyStep].self,forKey:.steps) ?? []
    assumptions=try c.decodeIfPresent([String].self,forKey:.assumptions) ?? []
    guides=try c.decodeIfPresent([ConstructionPatternGuide].self,forKey:.guides) ?? []
    views=try c.decodeIfPresent([ConstructionDrawingView].self,forKey:.views) ?? []
    foldRoles=try c.decodeIfPresent([String:ConstructionGuideRole].self,forKey:.foldRoles) ?? [:]
    quantity=try c.decodeIfPresent(Int.self,forKey:.quantity) ?? 1;labels=try c.decodeIfPresent(Bool.self,forKey:.labels) ?? true
    registrationMarks=try c.decodeIfPresent(Bool.self,forKey:.registrationMarks) ?? false;bleedMM=try c.decodeIfPresent(Double.self,forKey:.bleedMM) ?? 0
    declaredKerfMM=try c.decodeIfPresent(Double.self,forKey:.declaredKerfMM);processNotes=try c.decodeIfPresent(String.self,forKey:.processNotes) ?? ""
  }
  public func validate(in definition:PlanarConstructionDefinition,context:PlanarAssemblySourceContext?=nil)throws {
    let components=Set(definition.components?.map(\.id) ?? [definition.rootPanelID]),hinges=Set(definition.hinges.map(\.id)),joints=Set(definition.joins.map(\.id))
    guard version==1,materials.count<=64,steps.count<=128,guides.count<=256,views.count<=32,assumptions.count<=64,
      (1...1000).contains(quantity),bleedMM.isFinite,(0...25).contains(bleedMM),
      declaredKerfMM.map({$0.isFinite && (0...10).contains($0)}) ?? true,processNotes.utf8.count<=4000,
      assumptions.allSatisfy({!$0.isEmpty && $0.utf8.count<=2000}),Set(materials.map(\.id)).count==materials.count,
      Set(steps.map(\.id)).count==steps.count,Set(guides.map(\.id)).count==guides.count,Set(views.map(\.id)).count==views.count,
      Set(foldRoles.keys).isSubset(of:hinges),steps.reduce(0,{$0+$1.instructions.utf8.count})<=64000 else {
      throw FormError.invalid("Construction production metadata exceeds its bounded identities, quantity, guides or process assumptions.")
    }
    var assigned=Set<String>()
    for format in materials {
      try format.validate()
      guard Set(format.componentIDs).isSubset(of:components),assigned.isDisjoint(with:Set(format.componentIDs)) else {
        throw FormError.invalid("Each cut piece must target one material format; repair missing or duplicate component IDs in ‘\(format.name)’.")
      }
      assigned.formUnion(format.componentIDs)
    }
    var prior=Set<String>()
    for step in steps {
      guard !step.id.isEmpty,step.id.utf8.count<=128,!step.title.isEmpty,step.title.utf8.count<=256,
        !step.instructions.isEmpty,step.instructions.utf8.count<=8000,
        Set(step.componentIDs).count==step.componentIDs.count,Set(step.componentIDs).isSubset(of:components),
        Set(step.jointIDs).count==step.jointIDs.count,Set(step.jointIDs).isSubset(of:joints),
        Set(step.after).count==step.after.count,Set(step.after).isSubset(of:prior) else {
        throw FormError.invalid("Assembly step ‘\(step.id)’ must reference existing parts/joints and earlier steps, with explicit bounded instructions.")
      }
      prior.insert(step.id)
    }
    guard guides.reduce(0,{$0+$1.points.count})<=4096 else {throw FormError.invalid("Construction guides exceed the 4096-point packet budget.")}
    let guideContext:PlanarAssemblySourceContext?
    if guides.isEmpty {guideContext=nil}
    else {guideContext=try context ?? PlanarAssemblySourceContext(definition)}
    for guide in guides {
      guard !guide.id.isEmpty,guide.id.utf8.count<=128,components.contains(guide.componentID),(2...128).contains(guide.points.count),guide.label.utf8.count<=512 else {
        throw FormError.invalid("Pattern guides need a stable existing piece target, 2–128 points and a bounded label.")
      }
      guard let guideContext,let bounds=guideContext.bounds[guide.componentID] else {throw FormError.invalid("Pattern guide ‘\(guide.id)’ has no physical cut-piece bounds.")}
      _=try guide.resolvedPoints(values:guideContext.values,bounds:bounds)
    }
    for view in views {
      guard !view.id.isEmpty,view.id.utf8.count<=128,!view.title.isEmpty,view.title.utf8.count<=256,
        [view.openingPercent,view.explosionPercent].allSatisfy({$0.isFinite && (0...100).contains($0)}),
        view.componentIDs.map({!$0.isEmpty && Set($0).count==$0.count && Set($0).isSubset(of:components)}) ?? true,
        view.sectionOffsetMM==nil || view.sectionAxis != nil else{throw FormError.invalid("Construction drawing views need bounded poses and existing explicit piece targets; a section offset needs its axis.")}
    }
  }
}

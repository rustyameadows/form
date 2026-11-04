import Foundation

/// Ephemeral construction-review geometry, never artwork, ink or a tool path.
/// Points use the original canonical net until a physical projection maps them.
public struct ConstructionArtworkTechnicalPath:Equatable,Sendable,Identifiable {
  public enum Role:String,Sendable {
    case score,groove,fold,turnIn,seam,glue,orientation,registration,annotation
    case adhesive,glueExclusion,tapeContact,stapleCrown,stapleEntry,stapleExit
  }
  public var id:String,componentID:String,panelID:String?
  public var side:PaperFinishAssignment.Side?
  public var role:Role
  public var points:[Point2]
  public var holes:[[Point2]]
  public var closed:Bool
  public var label:String
  public init(id:String,componentID:String,panelID:String?=nil,side:PaperFinishAssignment.Side?=nil,
    role:Role,points:[Point2],holes:[[Point2]]=[],closed:Bool=false,label:String="") {
    self.id=id;self.componentID=componentID;self.panelID=panelID;self.side=side;self.role=role
    self.points=points;self.holes=holes;self.closed=closed;self.label=label
  }
}

public enum ConstructionArtworkTechnicalGuides {
  /// Resolve once per accepted physical source, not once per readable face.
  /// Presentation poses do not alter manufacturing marks or canonical ink.
  public static func resolve(_ source:PaperConstruction,net supplied:PaperNet?=nil,
    context prepared:PlanarAssemblySourceContext?=nil)throws->[ConstructionArtworkTechnicalPath] {
    guard let definition=source.authored,definition.version>=4 else{return []}
    let net=try supplied ?? source.net(),context=try prepared ?? PlanarAssemblySourceContext(definition,fallbackStock:source.stock)
    let panels=Dictionary(uniqueKeysWithValues:net.panels.map{($0.id,$0)})
    var paths=[ConstructionArtworkTechnicalPath]()
    for guide in definition.production?.guides ?? [] where context.enabledIDs.contains(guide.componentID) {
      guard let bounds=context.bounds[guide.componentID],let role=ConstructionArtworkTechnicalPath.Role(rawValue:guide.role.rawValue) else {continue}
      let local=try guide.resolvedPoints(values:context.values,bounds:bounds)
      paths.append(.init(id:"guide:"+guide.id,componentID:guide.componentID,role:role,
        points:local.map{.init($0.x+bounds.x,$0.y+bounds.y)},closed:guide.closed,label:guide.label))
    }
    func bounded()throws {
      guard paths.count<=32768,paths.reduce(0,{$0+$1.points.count+$1.holes.reduce(0){$0+$1.count}})<=262144 else {
        throw FormError.invalid("Construction review guides exceed the bounded technical-display scope.")
      }
    }
    try bounded()
    guard definition.jointAttachments?.isEmpty == false else{return paths}
    let attachments=try definition.resolveJointAttachments(stock:source.stock,validateEngagement:true)
    func flat(_ points:[Point2],target:ResolvedPlanarJointRegion)throws->[Point2] {
      guard let panel=panels[target.panelID] else{throw FormError.missing("A technical joint mark lost its actual material face.")}
      guard let edge=target.edgeIndex else{return points}
      guard panel.polygon.indices.contains(edge) else{throw FormError.missing("A technical joint mark lost its actual cut edge.")}
      let a=panel.polygon[edge],b=panel.polygon[(edge+1)%panel.polygon.count],length=hypot(b.x-a.x,b.y-a.y)
      return points.map{.init(a.x+(b.x-a.x)*$0.x/length,a.y+(b.y-a.y)*$0.x/length)}
    }
    func region(_ target:ResolvedPlanarJointRegion,id:String,role:ConstructionArtworkTechnicalPath.Role,
      exclusions:[[Point2]]=[],label:String)throws {
      guard let componentID=target.componentID,context.enabledIDs.contains(componentID) else{return}
      let points=try flat(target.coordinatesMM,target:target),holes=try exclusions.map{try flat($0,target:target)}
      paths.append(.init(id:id,componentID:componentID,panelID:target.panelID,
        side:target.edgeIndex==nil ? target.side:nil,role:role,points:points,holes:holes,
        closed:target.edgeIndex==nil,label:label))
      for (index,hole) in holes.enumerated() {
        paths.append(.init(id:id+":exclusion:"+String(index),componentID:componentID,panelID:target.panelID,
          side:target.edgeIndex==nil ? target.side:nil,role:.glueExclusion,points:hole,
          closed:target.edgeIndex==nil,label:"No adhesive · "+label))
      }
    }
    for adhesive in attachments.adhesives {
      try region(adhesive.firstTarget,id:"adhesive:"+adhesive.id+":first",role:.adhesive,exclusions:adhesive.firstExclusionsMM,label:adhesive.identity)
      try region(adhesive.secondTarget,id:"adhesive:"+adhesive.id+":second",role:.adhesive,exclusions:adhesive.secondExclusionsMM,label:adhesive.identity)
    }
    for tape in attachments.tapes {
      try region(tape.firstTarget,id:"tape:"+tape.id+":first",role:.tapeContact,label:"Tape contact · "+tape.id)
      try region(tape.secondTarget,id:"tape:"+tape.id+":second",role:.tapeContact,label:"Tape contact · "+tape.id)
    }
    var closed=source;closed.foldPercent=100;closed.openingPercent=0;closed.explosionPercent=0
    let poses=try PaperConstructionEngine.resolvedPanels(closed,validatedNet:net,sourceContext:context)
    let matrices=Dictionary(uniqueKeysWithValues:poses.map{($0.panelID,$0.flatToWorld)})
    func cross(_ point:Point2,radius:Double,id:String,componentID:String,panelID:String,
      side:PaperFinishAssignment.Side?,role:ConstructionArtworkTechnicalPath.Role) {
      for axis in 0...1 {
        paths.append(.init(id:id+":"+String(axis),componentID:componentID,panelID:panelID,side:side,role:role,
          points:axis==0 ? [.init(point.x-radius,point.y),.init(point.x+radius,point.y)]:[.init(point.x,point.y-radius),.init(point.x,point.y+radius)],
          label:"Fastener placement only; not a drill or punch path"))
      }
    }
    for wire in attachments.staples {
      guard let entry=panels[wire.entryPanelID],let componentID=entry.componentID,
        let matrix=matrices[entry.id] else{throw FormError.missing("A technical fastener mark lost its actual entry face.")}
      let indices=wire.pointsMM.count==6 ? [2,3]:[1,2]
      let crown=indices.map {index -> Point2 in
        let p=PlanarJointGeometry.inversePoint(matrix,wire.pointsMM[index]);return .init(p.x,-p.y)
      }
      paths.append(.init(id:"wire:"+wire.id+":crown",componentID:componentID,panelID:entry.id,side:wire.entrySide,
        role:.stapleCrown,points:crown,label:"Actual crown · "+wire.id))
      let radius=max(0.6,min(1.8,wire.wireWidthMM*2))
      for (index,point) in crown.enumerated() {
        cross(point,radius:radius,id:"wire:"+wire.id+":entry:"+String(index),componentID:componentID,panelID:entry.id,side:wire.entrySide,role:.stapleEntry)
      }
      for (index,boundary) in wire.receivingEntryBoundaries.enumerated() {
        guard let component=boundary.componentID else{continue}
        cross(.init(boundary.panelPointMM.x,-boundary.panelPointMM.y),radius:radius,
          id:"wire:"+wire.id+":receiving:"+String(index),componentID:component,panelID:boundary.panelID,
          side:boundary.surface == .cutEdge ? nil:boundary.surface == .outside ? .outside:.inside,role:.stapleEntry)
      }
      // A buried leg has a geometric through-exit boundary but does not make
      // an exit mark. Only the declared real through termination is displayed.
      if wire.termination != .buried {
        for (index,boundary) in wire.receivingThroughExitBoundaries.enumerated() {
          guard let component=boundary.componentID else{continue}
          cross(.init(boundary.panelPointMM.x,-boundary.panelPointMM.y),radius:radius,
            id:"wire:"+wire.id+":exit:"+String(index),componentID:component,panelID:boundary.panelID,
            side:boundary.surface == .cutEdge ? nil:boundary.surface == .outside ? .outside:.inside,role:.stapleExit)
        }
      }
    }
    try bounded()
    return paths
  }
}

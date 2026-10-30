import Foundation
import FormCADModel

public struct PlanarOpeningDefinition:Codable,Equatable,Sendable {
  public enum Axis:String,Codable,Sendable {case x,y,z}
  public var axis:Axis
  public var width:CADScalar
  public var height:CADScalar
  public var origin:CADExpressionPoint2?
  public init(axis:Axis,width:CADScalar,height:CADScalar,origin:CADExpressionPoint2?=nil) {
    self.axis=axis;self.width=width;self.height=height;self.origin=origin
  }
}
/// A declared usable volume about a component anchor. It is not inferred from a flat net.
public struct PlanarInteriorDefinition:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var name:String
  public var componentID:String
  public var origin:CADExpressionPoint
  public var size:CADExpressionPoint
  public var rotationDegrees:CADExpressionPoint?
  public var opening:PlanarOpeningDefinition?
  public init(id:String,name:String,componentID:String,origin:CADExpressionPoint,size:CADExpressionPoint,
    rotationDegrees:CADExpressionPoint?=nil,opening:PlanarOpeningDefinition?=nil) {
    self.id=id;self.name=name;self.componentID=componentID;self.origin=origin;self.size=size
    self.rotationDegrees=rotationDegrees;self.opening=opening
  }
}
public struct PaperResolvedOpening:Codable,Equatable,Sendable {
  public var axis:PlanarOpeningDefinition.Axis
  public var widthMM:Double
  public var heightMM:Double
  public var originMM:Point2
}
public struct PaperResolvedInterior:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var name:String
  public var componentID:String
  public var origin:Vector3
  public var uAxis:Vector3
  public var vAxis:Vector3
  public var wAxis:Vector3
  public var sizeMM:Vector3
  public var opening:PaperResolvedOpening?
}
/// Eight actual oriented bounds corners, already expressed in the construction-local mm frame.
/// The native adapter obtains these from the referenced object's current physical geometry.
public struct PaperContentsBounds:Codable,Equatable,Sendable {
  public var objectID:UUID
  public var revision:String?
  public var corners:[Vector3]
  public init(objectID:UUID,revision:String?=nil,corners:[Vector3]) {
    self.objectID=objectID;self.revision=revision;self.corners=corners
  }
}
public struct PaperContentsFitResult:Codable,Equatable,Sendable {
  public var sourceObjectID:UUID?
  public var sourceRevision:String?
  public var contentsObjectID:UUID
  public var contentsRevision:String?
  public var interior:PaperResolvedInterior
  public var clearanceMM:Double
  public var minimum:Vector3
  public var maximum:Vector3
  public var containmentPassed:Bool
  public var openingPassed:Bool?
  public var passed:Bool
  public var coverage:String
}

extension PlanarConstructionDefinition {
  func validateComponentsAndInteriors(resolvedPanels:[PaperPanel])throws {
    let components=components ?? [],interiors=interiors ?? []
    guard components.count<=32,Set(components.map(\.id)).count==components.count,
      interiors.count<=64,Set(interiors.map(\.id)).count==interiors.count else {
      throw FormError.invalid("Keep at most 32 uniquely identified components and 64 interiors.")
    }
    let values=try resolvedValues()
    for component in components {
      guard !component.id.isEmpty,component.id.utf8.count<=128,!component.name.isEmpty,component.name.utf8.count<=160,
        let panel=resolvedPanels.first(where:{$0.id==component.rootPanelID}) else {throw FormError.invalid("Each construction component needs a bounded identity and an existing root panel.")}
      let a=try Point2(number(component.anchor.x),number(component.anchor.y))
      guard panel.containsMaterial(a) else {throw FormError.invalid("Component '\(component.id)' anchor must lie on its root panel's remaining material.")}
      // Reject invalid formulas at both endpoints; a specific intermediate pose
      // is independently checked when resolved, without changing source geometry.
      for fold in [0.0,100] {for opening in [0.0,100] {
        let pose=values.merging(["fold":fold,"opening":opening]){_,new in new}
        _ = try PaperRigidMatrix.vector(component.position,values:pose)
        let r=try PaperRigidMatrix.vector(component.rotationDegrees,values:pose)
        guard [r.x,r.y,r.z].allSatisfy({abs($0)<=3600}) else {throw FormError.invalid("Component rotations must remain within ±3600 degrees.")}
      }}
    }
    for interior in interiors {
      guard !interior.id.isEmpty,interior.id.utf8.count<=128,!interior.name.isEmpty,interior.name.utf8.count<=160,
        components.contains(where:{$0.id==interior.componentID}) else {throw FormError.invalid("An interior must identify an existing component and have bounded unique metadata.")}
      _ = try resolvedInteriorLocal(interior,values:values)
    }
  }
  fileprivate func resolvedInteriorLocal(_ definition:PlanarInteriorDefinition,values:[String:Double])throws->(origin:Vector3,size:Vector3,rotation:Vector3,opening:PaperResolvedOpening?) {
    let origin=try PaperRigidMatrix.vector(definition.origin,values:values),size=try PaperRigidMatrix.vector(definition.size,values:values)
    let rotation=try definition.rotationDegrees.map{try PaperRigidMatrix.vector($0,values:values)} ?? .init()
    guard [size.x,size.y,size.z].allSatisfy({$0>0 && $0<=10000}),[rotation.x,rotation.y,rotation.z].allSatisfy({abs($0)<=3600}) else {
      throw FormError.invalid("Interior dimensions must be positive and at most 10000 mm; rotations are bounded.")
    }
    var opening:PaperResolvedOpening?
    if let d=definition.opening {
      let width=try CADExpression.evaluate(d.width.expression,variables:values),height=try CADExpression.evaluate(d.height.expression,variables:values)
      let point=try d.origin.map{try Point2(CADExpression.evaluate($0.x.expression,variables:values),CADExpression.evaluate($0.y.expression,variables:values))} ?? .init(0,0)
      let available:Point2=d.axis == .x ? .init(size.y,size.z):d.axis == .y ? .init(size.x,size.z):.init(size.x,size.y)
      guard width>0,height>0,point.x>=0,point.y>=0,point.x+width<=available.x+1e-7,point.y+height<=available.y+1e-7 else {
        throw FormError.invalid("Interior '\(definition.id)' opening must be a positive rectangle within its declared cross-section.")
      }
      opening = .init(axis:d.axis,widthMM:width,heightMM:height,originMM:point)
    }
    return (origin,size,rotation,opening)
  }
}

extension PaperPanel {
  /// Boundary contact is allowed; removed regions (including their cut edges) are excluded.
  public func containsMaterial(_ point:Point2)->Bool {
    func contains(_ polygon:[Point2],boundary:Bool)->Bool {
      guard polygon.count>=3 else{return false}
      var inside=false,j=polygon.count-1
      for i in polygon.indices {let a=polygon[i],b=polygon[j],dx=b.x-a.x,dy=b.y-a.y,length=hypot(dx,dy)
        if length>0,abs(dx*(point.y-a.y)-dy*(point.x-a.x))/length<=1e-7,
          point.x>=min(a.x,b.x)-1e-7,point.x<=max(a.x,b.x)+1e-7,point.y>=min(a.y,b.y)-1e-7,point.y<=max(a.y,b.y)+1e-7 {return boundary}
        if (a.y>point.y) != (b.y>point.y),point.x<(b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x {inside.toggle()};j=i
      };return inside
    }
    return contains(polygon,boundary:true) && !(cutouts ?? []).contains{contains($0.polygon,boundary:true)}
  }
}

extension PaperConstructionEngine {
  public static func resolvedInteriors(_ source:PaperConstruction)throws->[PaperResolvedInterior] {
    try validate(source)
    guard let definition=source.authored,let interiors=definition.interiors,!interiors.isEmpty else{return []}
    let frames=Dictionary(uniqueKeysWithValues:try resolvedComponents(source).map{($0.id,$0.localToWorld)}),values=try definition.resolvedValues()
    return try interiors.map {d in
      guard let component=frames[d.componentID] else {throw FormError.invalid("Interior '\(d.id)' has no resolved component frame.")}
      let local=try definition.resolvedInteriorLocal(d,values:values)
      let m=PaperRigidMatrix.multiply(component,PaperRigidMatrix.multiply(PaperRigidMatrix.translation(local.origin.x,local.origin.y,local.origin.z),PaperRigidMatrix.rotation(local.rotation.x,local.rotation.y,local.rotation.z)))
      return .init(id:d.id,name:d.name,componentID:d.componentID,origin:PaperRigidMatrix.point(m,.init()),
        uAxis:.init(m[0],m[4],m[8]),vAxis:.init(m[1],m[5],m[9]),wAxis:.init(m[2],m[6],m[10]),sizeMM:local.size,opening:local.opening)
    }
  }
  public static func fitContents(_ source:PaperConstruction,interiorID:String,contents:PaperContentsBounds,
    clearanceMM:Double=0,sourceObjectID:UUID?=nil,sourceRevision:String?=nil)throws->PaperContentsFitResult {
    guard clearanceMM.isFinite,(0...1000).contains(clearanceMM),contents.corners.count==8,
      contents.corners.allSatisfy({[$0.x,$0.y,$0.z].allSatisfy{$0.isFinite && abs($0)<=1_000_000}}),
      sourceObjectID != contents.objectID else {throw FormError.invalid("Contents fit requires another object's eight finite physical bounds corners and a 0–1000 mm clearance.")}
    guard let interior=try resolvedInteriors(source).first(where:{$0.id==interiorID}) else {throw FormError.missing("Declare interior '\(interiorID)' in the construction before testing contents.")}
    var low=Vector3(.infinity,.infinity,.infinity),high=Vector3(-.infinity,-.infinity,-.infinity)
    func dot(_ a:Vector3,_ b:Vector3)->Double {a.x*b.x+a.y*b.y+a.z*b.z}
    for p in contents.corners {
      let delta=Vector3(p.x-interior.origin.x,p.y-interior.origin.y,p.z-interior.origin.z)
      let v=Vector3(dot(delta,interior.uAxis),dot(delta,interior.vAxis),dot(delta,interior.wAxis))
      low = .init(min(low.x,v.x),min(low.y,v.y),min(low.z,v.z));high = .init(max(high.x,v.x),max(high.y,v.y),max(high.z,v.z))
    }
    let c=clearanceMM,e=1e-7,s=interior.sizeMM
    let containment=low.x>=c-e && low.y>=c-e && low.z>=c-e && high.x<=s.x-c+e && high.y<=s.y-c+e && high.z<=s.z-c+e
    let opening=interior.opening.map {o->Bool in
      let minimum:Point2=o.axis == .x ? .init(low.y,low.z):o.axis == .y ? .init(low.x,low.z):.init(low.x,low.y)
      let maximum:Point2=o.axis == .x ? .init(high.y,high.z):o.axis == .y ? .init(high.x,high.z):.init(high.x,high.y)
      return minimum.x>=o.originMM.x+c-e && minimum.y>=o.originMM.y+c-e && maximum.x<=o.originMM.x+o.widthMM-c+e && maximum.y<=o.originMM.y+o.heightMM-c+e
    }
    return .init(sourceObjectID:sourceObjectID,sourceRevision:sourceRevision,contentsObjectID:contents.objectID,
      contentsRevision:contents.revision,interior:interior,clearanceMM:c,minimum:low,maximum:high,
      containmentPassed:containment,openingPassed:opening,passed:containment && (opening ?? true),
      coverage:"Actual oriented object bounds against the author-declared interior and, when present, its opening cross-section at the current lateral position. No continuous insertion path, panel-to-product exact contact, elastic retention, adhesive strength or unlisted volume is inferred.")
  }
}

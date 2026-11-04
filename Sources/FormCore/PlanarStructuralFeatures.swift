import Foundation
import FormCADModel

/// A finite removed region in the physical sheet, shared by mesh, tooling and artwork clipping.
public enum PaperCutoutKind:String,Codable,Sendable {case cutout,window,slot,perforation}
public struct PaperPanelCutout:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var polygon:[Point2]
  public var kind:PaperCutoutKind
  public init(id:String,polygon:[Point2],kind:PaperCutoutKind = .cutout){self.id=id;self.polygon=polygon;self.kind=kind}
}
public struct PlanarCutoutDefinition:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var polygon:[CADExpressionPoint2]
  public var kind:PaperCutoutKind
  public init(id:String,polygon:[CADExpressionPoint2],kind:PaperCutoutKind = .cutout){self.id=id;self.polygon=polygon;self.kind=kind}
}

/// Each component owns one hinge tree. Anchor is on the canonical sheet;
/// position is the assembled anchor in millimeters (X right, Y up, Z toward viewer).
/// Rotation is intrinsic X, then Y, then Z, relative to an upright source panel.
/// Root-pose expressions additionally receive `fold` and `opening` percentages.
public struct PlanarComponentDefinition:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var name:String
  public var rootPanelID:String
  public var anchor:CADExpressionPoint2
  public var position:CADExpressionPoint
  public var rotationDegrees:CADExpressionPoint
  public var groupID:String?
  public var stock:PaperStock?
  public var stockThickness:CADScalar?
  public var quantity:Int?
  public var purpose:String?
  public var front:SheetAssemblyFace?,back:SheetAssemblyFace?
  public var enabled:CADScalar?
  public var finishes:[PaperFinishAssignment]?
  public init(id:String,name:String,rootPanelID:String,anchor:CADExpressionPoint2,
    position:CADExpressionPoint = .init(),rotationDegrees:CADExpressionPoint = .init(),groupID:String?=nil,
    stock:PaperStock?=nil,stockThickness:CADScalar?=nil,quantity:Int?=nil,purpose:String?=nil,
    front:SheetAssemblyFace?=nil,back:SheetAssemblyFace?=nil,enabled:CADScalar?=nil,finishes:[PaperFinishAssignment]?=nil) {
    self.id=id;self.name=name;self.rootPanelID=rootPanelID;self.anchor=anchor
    self.position=position;self.rotationDegrees=rotationDegrees
    self.groupID=groupID;self.stock=stock;self.stockThickness=stockThickness;self.quantity=quantity;self.purpose=purpose
    self.front=front;self.back=back;self.enabled=enabled;self.finishes=finishes
  }
}
public struct PaperResolvedComponent:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var name:String
  public var rootPanelID:String
  /// Maps component-local millimeters about its source anchor into construction-local millimeters.
  public var localToWorld:[Double]
  public init(id:String,name:String,rootPanelID:String,localToWorld:[Double]) {
    self.id=id;self.name=name;self.rootPanelID=rootPanelID;self.localToWorld=localToWorld
  }
}

enum PaperRigidMatrix {
  static let identity:[Double]=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
  static func multiply(_ a:[Double],_ b:[Double])->[Double] {
    var result=[Double](repeating:0,count:16)
    for r in 0..<4 {for c in 0..<4 {for k in 0..<4 {result[r*4+c]+=a[r*4+k]*b[k*4+c]}}}
    return result
  }
  static func translation(_ x:Double,_ y:Double,_ z:Double)->[Double] {[1,0,0,x,0,1,0,y,0,0,1,z,0,0,0,1]}
  static func rotation(_ x:Double,_ y:Double,_ z:Double)->[Double] {
    func axis(_ x:Double,_ y:Double,_ z:Double,_ degrees:Double)->[Double] {
      let a=degrees * .pi/180,c=cos(a),s=sin(a),t=1-c
      return [t*x*x+c,t*x*y-s*z,t*x*z+s*y,0,t*x*y+s*z,t*y*y+c,t*y*z-s*x,0,t*x*z-s*y,t*y*z+s*x,t*z*z+c,0,0,0,0,1]
    }
    return multiply(axis(0,0,1,z),multiply(axis(0,1,0,y),axis(1,0,0,x)))
  }
  static func point(_ m:[Double],_ p:Vector3)->Vector3 {
    .init(m[0]*p.x+m[1]*p.y+m[2]*p.z+m[3],m[4]*p.x+m[5]*p.y+m[6]*p.z+m[7],m[8]*p.x+m[9]*p.y+m[10]*p.z+m[11])
  }
  static func vector(_ p:CADExpressionPoint,values:[String:Double])throws->Vector3 {
    let v=try Vector3(CADExpression.evaluate(p.x.expression,variables:values),CADExpression.evaluate(p.y.expression,variables:values),CADExpression.evaluate(p.z.expression,variables:values))
    guard [v.x,v.y,v.z].allSatisfy({$0.isFinite && abs($0)<=100000}) else {throw FormError.invalid("Construction component coordinates must be finite and bounded to ±100000 mm/degrees.")}
    return v
  }
}

enum PlanarComponentPoseResolver {
  struct Resolution {var panels:[PaperResolvedPanel];var components:[PaperResolvedComponent]}
  static func resolve(_ source:PaperConstruction,net:PaperNet,amount:Double,context:PlanarAssemblySourceContext?=nil)throws->Resolution {
    guard let definition=source.authored,definition.components?.isEmpty == false else {
      throw FormError.invalid("Multi-component construction roots are missing.")
    }
    let sourceValues=try context?.values ?? definition.resolvedValues()
    let actualValues=try definition.poseValues(fold:amount*100,opening:source.openingPercent,explosion:source.explosionPercent ?? 0)
    let closedValues=(definition.version>=4 && amount==1) ? sourceValues:try definition.poseValues(fold:amount*100,opening:0,explosion:0)
    let components=try context.map {prepared in (definition.components ?? []).filter{prepared.enabledIDs.contains($0.id)}} ?? definition.activeComponents(values:sourceValues)
    let actualGroups=try definition.resolvedGroupMatrices(fold:amount*100,opening:source.openingPercent,explosion:source.explosionPercent ?? 0,values:actualValues)
    let closedGroups=try definition.resolvedGroupMatrices(fold:amount*100,opening:0,explosion:0,values:closedValues)
    typealias M=PaperRigidMatrix
    func root(_ component:PlanarComponentDefinition,poseValues:[String:Double],groups:[String:[Double]])throws->(matrix:[Double],anchor:Point2) {
      let anchor=try Point2(CADExpression.evaluate(component.anchor.x.expression,variables:sourceValues),CADExpression.evaluate(component.anchor.y.expression,variables:sourceValues))
      let t=try (context?.stocks[component.id] ?? definition.componentStock(component,fallback:source.stock,values:sourceValues)).resolvedThicknessMM
      let position=try M.vector(component.position,values:poseValues),rotation=try M.vector(component.rotationDegrees,values:poseValues)
      let flat=Vector3(anchor.x-net.size.x/2,t/2,anchor.y-net.size.y/2)
      let blended=Vector3(flat.x+(position.x-flat.x)*amount,flat.y+(position.y-flat.y)*amount,flat.z+(position.z-flat.z)*amount)
      let r=M.rotation(-90+(rotation.x+90)*amount,rotation.y*amount,rotation.z*amount)
      let local=M.multiply(M.translation(blended.x,blended.y,blended.z),M.multiply(r,M.translation(-anchor.x,anchor.y,0)))
      return (M.multiply(component.groupID.flatMap{groups[$0]} ?? M.identity,local),anchor)
    }
    var actual:[String:[Double]]=[:],closed:[String:[Double]]=[:],anchors:[String:Point2]=[:]
    for component in components {
      let a=try root(component,poseValues:actualValues,groups:actualGroups),c=try root(component,poseValues:closedValues,groups:closedGroups)
      actual[component.rootPanelID]=a.matrix;closed[component.rootPanelID]=c.matrix;anchors[component.id]=a.anchor
    }
    var remaining=net.panels.filter{actual[$0.id]==nil}
    for _ in net.panels.indices {if remaining.isEmpty{break};var next:[PaperPanel]=[]
      for panel in remaining {
        guard let parent=panel.parentID,let a=actual[parent],let c=closed[parent],let fold=net.folds.first(where:{$0.id==panel.foldID}) else {next.append(panel);continue}
        func hinge(_ fraction:Double)->[Double] {
          let p=fold.start,dx=fold.end.x-p.x,dy = -fold.end.y+p.y,length=hypot(dx,dy),x=dx/length,y=dy/length
          let angle=fold.angleDegrees * .pi/180*fraction,co=cos(angle),s=sin(angle),v=1-co
          let r:[Double]=[v*x*x+co,v*x*y,s*y,0,v*x*y,v*y*y+co,-s*x,0,-s*y,s*x,co,0,0,0,0,1]
          return M.multiply(M.translation(p.x,-p.y,0),M.multiply(r,M.multiply(M.translation(-p.x,p.y,0),M.translation(0,0,-(fold.layerOffsetMM ?? 0)*fraction))))
        }
        let opening=fold.opensWithTop == true ? 1-source.openingPercent/100:1
        actual[panel.id]=M.multiply(a,hinge(amount*opening));closed[panel.id]=M.multiply(c,hinge(amount))
      };remaining=next
    }
    guard actual.count==net.panels.count else {throw FormError.invalid("Component hinge trees are disconnected or cyclic.")}
    var low=Vector3(.infinity,.infinity,.infinity),high=Vector3(-.infinity,-.infinity,-.infinity)
    let closedFeatureValues=closedValues
    for panel in net.panels {
      let matrix=closed[panel.id]!
      for point in try panel.physicalBoundarySamples(stock:try panel.resolvedStock(fallback:source.stock),variables:closedFeatureValues,worldMatrix:matrix) {
        let v=M.point(matrix,point)
        low = .init(min(low.x,v.x),min(low.y,v.y),min(low.z,v.z));high = .init(max(high.x,v.x),max(high.y,v.y),max(high.z,v.z))
      }
    }
    let ground=M.translation(-(low.x+high.x)/2,-low.y,-(low.z+high.z)/2)
    let resolved=net.panels.map{PaperResolvedPanel(panelID:$0.id,flatToWorld:M.multiply(ground,actual[$0.id]!))}
    let roots=components.map {component->PaperResolvedComponent in
      let a=anchors[component.id]!
      return .init(id:component.id,name:component.name,rootPanelID:component.rootPanelID,
        localToWorld:M.multiply(ground,M.multiply(actual[component.rootPanelID]!,M.translation(a.x,-a.y,0))))
    }
    return .init(panels:resolved,components:roots)
  }
}

extension PaperConstructionEngine {
  public static func resolvedComponents(_ source:PaperConstruction)throws->[PaperResolvedComponent] {
    let net=try net(source)
    guard source.authored?.components?.isEmpty == false else{return []}
    return try PlanarComponentPoseResolver.resolve(source,net:net,amount:source.foldPercent/100).components
  }
}

import Foundation
import FormCADModel
import CFormClipper

/// Authored geometry and connections, independent of any particular product family.
public struct PlanarPanelDefinition: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var role: PaperPanel.Role
  public var polygon: [CADExpressionPoint2]
  public var artworkRotationDegrees: CADScalar?
  public init(id: String, name: String, role: PaperPanel.Role = .body,
    polygon: [CADExpressionPoint2], artworkRotationDegrees: CADScalar? = nil) {
    self.id=id; self.name=name; self.role=role; self.polygon=polygon
    self.artworkRotationDegrees=artworkRotationDegrees
  }
}

public struct PlanarHingeDefinition: Codable, Equatable, Sendable {
  public var id: String
  public var parentPanelID: String
  public var childPanelID: String
  public var start: CADExpressionPoint2
  public var end: CADExpressionPoint2
  public var angleDegrees: CADScalar
  public var layerOffsetMM: CADScalar?
  public var opensWithTop: Bool?
  public init(id: String, parentPanelID: String, childPanelID: String,
    start: CADExpressionPoint2, end: CADExpressionPoint2, angleDegrees: CADScalar,
    layerOffsetMM: CADScalar? = nil, opensWithTop: Bool = false) {
    self.id=id; self.parentPanelID=parentPanelID; self.childPanelID=childPanelID
    self.start=start; self.end=end; self.angleDegrees=angleDegrees
    self.layerOffsetMM=layerOffsetMM; self.opensWithTop=opensWithTop
  }
}

/// Authored connection metadata resolves through the same parameter expressions
/// as panel geometry. PaperJoin remains the numerical result used downstream.
public struct PlanarJoinDefinition: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var firstPanelID: String
  public var secondPanelID: String
  public var kind: String
  public var overlapMM: CADScalar
  public var notes: String
  public init(id: String, name: String, firstPanelID: String, secondPanelID: String,
    kind: String = "glue", overlapMM: CADScalar, notes: String = "") {
    self.id=id; self.name=name; self.firstPanelID=firstPanelID; self.secondPanelID=secondPanelID
    self.kind=kind; self.overlapMM=overlapMM; self.notes=notes
  }
  public init(_ resolved: PaperJoin) {
    self.init(id:resolved.id,name:resolved.name,firstPanelID:resolved.firstPanelID,
      secondPanelID:resolved.secondPanelID,kind:resolved.kind,
      overlapMM:CADScalar(resolved.overlapMM),notes:resolved.notes)
  }
}

public struct PlanarConstructionDefinition: Codable, Equatable, Sendable {
  public var version: Int = 1
  public var name: String
  public var parameters: [CADModelParameter]
  public var size: CADExpressionPoint2
  public var stockThickness: CADScalar
  public var panels: [PlanarPanelDefinition]
  public var hinges: [PlanarHingeDefinition]
  public var joins: [PlanarJoinDefinition]
  public var rootPanelID: String
  public var requirements: [CADModelRequirement]?
  public var derived: [String:CADScalar]?
  public var connections: [PlanarConnectionRequirement]?
  public var solidChecks: [PlanarSolidRequirement]?
  public init(name: String, parameters: [CADModelParameter] = [], size: CADExpressionPoint2,
    stockThickness: CADScalar = 0.35, panels: [PlanarPanelDefinition],
    hinges: [PlanarHingeDefinition] = [], joins: [PlanarJoinDefinition] = [], rootPanelID: String,
    requirements: [CADModelRequirement]? = nil,derived:[String:CADScalar]? = nil,
    connections:[PlanarConnectionRequirement]? = nil, solidChecks:[PlanarSolidRequirement]? = nil) {
    self.name=name; self.parameters=parameters; self.size=size; self.stockThickness=stockThickness
    self.panels=panels; self.hinges=hinges; self.joins=joins; self.rootPanelID=rootPanelID
    self.requirements=requirements;self.derived=derived;self.connections=connections
    self.solidChecks=solidChecks;self.version=solidChecks?.isEmpty == false ? 2:1
  }
  public var values: [String: Double] { Dictionary(parameters.map { ($0.name,$0.value) }, uniquingKeysWith: { a,_ in a }) }
  public func number(_ scalar: CADScalar) throws -> Double {
    try CADExpression.evaluate(scalar.expression,variables:resolvedValues())
  }
  public func resolvedValues()throws->[String:Double] {try CADDerivedExpressions.resolve(derived ?? [:],variables:values)}
  public mutating func setParameters(_ values: [String: Double]) throws {
    var next=parameters
    for (name,value) in values {
      if name=="fold" || name=="opening" {
        guard value.isFinite,(0...100).contains(value) else{throw FormError.invalid("Construction pose controls must be 0–100%.")}
        continue
      }
      guard let i=next.firstIndex(where:{$0.name==name}),value.isFinite,
        value>=next[i].minimum,value<=next[i].maximum else {
        throw FormError.invalid("Unknown or out-of-range construction parameter '\(name)'.")
      }
      next[i].value=value
    }
    parameters=next
  }
  public func net() throws -> PaperNet {
    guard (version==1 || version==2),(version>=2 || solidChecks?.isEmpty != false),!name.isEmpty,name.utf8.count<=160,parameters.count<=64,
      Set(parameters.map(\.name)).count==parameters.count,
      parameters.allSatisfy({CADExpression.validName($0.name) && !["fold","opening"].contains($0.name)
        && [$0.value,$0.minimum,$0.maximum].allSatisfy(\.isFinite)
        && $0.minimum <= $0.value && $0.value <= $0.maximum && abs($0.minimum)<=100000 && abs($0.maximum)<=100000}),
      (1...64).contains(panels.count),hinges.count==panels.count-1,joins.count<=128 else {
      throw FormError.invalid("Construction requires a named bounded definition, up to 64 parameters/panels, and one hinge per non-root panel.")
    }
    guard (requirements?.count ?? 0)<=128,Set((requirements ?? []).map(\.id)).count==(requirements?.count ?? 0),
      panels.reduce(0,{$0+$1.polygon.count})<=2048 else {throw FormError.invalid("Keep construction requirements and polygon complexity bounded.")}
    let variables=try resolvedValues()
    func number(_ scalar:CADScalar)throws->Double {try CADExpression.evaluate(scalar.expression,variables:variables)}
    for requirement in requirements ?? [] {try requirement.validate(using:variables)}
    func point(_ p: CADExpressionPoint2) throws -> Point2 { .init(try number(p.x),try number(p.y)) }
    let extent=try point(size),thickness=try number(stockThickness)
    guard extent.x>0,extent.y>0,extent.x<=10000,extent.y<=10000,
      thickness>=0.01,thickness<=20 else {throw FormError.invalid("Construction size must be 0–10000 mm and stock thickness 0.01–20 mm.")}
    func validID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count<=128 }
    let ids=Set(panels.map(\.id))
    guard ids.count==panels.count,ids.contains(rootPanelID),panels.allSatisfy({validID($0.id) && !$0.name.isEmpty && $0.name.utf8.count<=160}),
      Set(hinges.map(\.id)).count==hinges.count,Set(hinges.map(\.childPanelID)).count==hinges.count else {
      throw FormError.invalid("Construction panel/hinge identities must be unique and include an existing root panel.")
    }
    var resolved: [PaperPanel] = try panels.map { panel in
      guard (3...128).contains(panel.polygon.count) else {throw FormError.invalid("Panel '\(panel.id)' requires 3–128 polygon vertices.")}
      // Collapsed sampled corners (for example radius=0) retain their source
      // declarations while resolving to the ordinary nondegenerate polygon.
      var polygon:[Point2]=[]
      for vertex in try panel.polygon.map(point) {
        if let previous=polygon.last,hypot(vertex.x-previous.x,vertex.y-previous.y)<=1e-7{continue}
        polygon.append(vertex)
      }
      if let first=polygon.first,let last=polygon.last,hypot(first.x-last.x,first.y-last.y)<=1e-7{polygon.removeLast()}
      guard polygon.count>=3,polygon.allSatisfy({$0.x>=(-1e-6) && $0.y>=(-1e-6) && $0.x<=extent.x+1e-6 && $0.y<=extent.y+1e-6}),
        abs(Self.signedArea(polygon))>0.001,!Self.selfIntersects(polygon) else {
        throw FormError.invalid("Panel '\(panel.id)' has an invalid, self-crossing, or out-of-bounds polygon.")
      }
      let rotation=try panel.artworkRotationDegrees.map(number)
      return .init(id:panel.id,name:panel.name,role:panel.role,polygon:polygon,artworkRotationDegrees:rotation)
    }
    var folds: [PaperFold] = []
    for hinge in hinges {
      guard validID(hinge.id),hinge.childPanelID != rootPanelID,hinge.childPanelID != hinge.parentPanelID,
        let child=resolved.firstIndex(where:{$0.id==hinge.childPanelID}),
        let parent=resolved.first(where:{$0.id==hinge.parentPanelID}) else {
        throw FormError.invalid("Hinge '\(hinge.id)' must connect existing distinct parent and child panels.")
      }
      let start=try point(hinge.start),end=try point(hinge.end),angle=try number(hinge.angleDegrees)
      let offset=try hinge.layerOffsetMM.map(number) ?? 0
      guard hypot(end.x-start.x,end.y-start.y)>0.001,abs(angle)<=180,abs(offset)<=20,
        Self.boundaryCovers(start,end,parent.polygon),
        Self.boundaryCovers(start,end,resolved[child].polygon) else {
        throw FormError.invalid("Hinge '\(hinge.id)' must lie on both panel boundaries, with an angle within ±180° and bounded layer offset.")
      }
      resolved[child].parentID=parent.id;resolved[child].foldID=hinge.id
      var fold=PaperFold(id:hinge.id,parentPanelID:parent.id,childPanelID:hinge.childPanelID,start:start,end:end,angleDegrees:angle)
      fold.layerOffsetMM=offset;fold.opensWithTop=hinge.opensWithTop
      folds.append(fold)
    }
    var connected:Set<String>=[rootPanelID]
    for _ in panels.indices { for fold in folds where connected.contains(fold.parentPanelID) {connected.insert(fold.childPanelID)} }
    guard connected==ids else {throw FormError.invalid("Construction hinge graph is disconnected or cyclic.")}
    for i in resolved.indices {for j in resolved.indices where j>i {
      if try Self.overlaps(resolved[i].polygon,resolved[j].polygon) {throw FormError.invalid("Flat construction panels '\(resolved[i].id)' and '\(resolved[j].id)' overlap.")}
    }}
    guard Set(joins.map(\.id)).count==joins.count,joins.allSatisfy({validID($0.id) && ids.contains($0.firstPanelID)
      && ids.contains($0.secondPanelID) && $0.firstPanelID != $0.secondPanelID
      && $0.name.utf8.count<=160 && $0.notes.utf8.count<=2048}) else {
      throw FormError.invalid("Construction joins require unique identities, existing panels and a finite nonnegative overlap.")
    }
    let resolvedJoins: [PaperJoin] = try joins.map { join in
      let overlap=try number(join.overlapMM)
      guard overlap.isFinite,overlap>=0,overlap<=10000 else {
        throw FormError.invalid("Construction join '\(join.id)' requires an overlap within 0–10000 mm.")
      }
      return .init(id:join.id,name:join.name,firstPanelID:join.firstPanelID,
        secondPanelID:join.secondPanelID,kind:join.kind,overlapMM:overlap,notes:join.notes)
    }
    guard (connections?.count ?? 0)<=128,Set((connections ?? []).map(\.id)).count==(connections?.count ?? 0) else {
      throw FormError.invalid("Use up to 128 uniquely identified construction connection requirements.")
    }
    for connection in connections ?? [] {
      guard validID(connection.id),connection.firstPanelID != connection.secondPanelID,
        let first=resolved.first(where:{$0.id==connection.firstPanelID}),
        let second=resolved.first(where:{$0.id==connection.secondPanelID}),
        Self.contains(try point(connection.firstPoint),first.polygon),
        Self.contains(try point(connection.secondPoint),second.polygon),
        (0...10000).contains(try number(connection.maximumGapMM)) else {
        throw FormError.invalid("Connection '\(connection.id)' requires distinct existing panels, anchors in their polygons and a maximum gap within 0–10000 mm.")
      }
    }
    guard (solidChecks?.count ?? 0)<=128,Set((solidChecks ?? []).map(\.id)).count==(solidChecks?.count ?? 0) else {
      throw FormError.invalid("Use up to 128 uniquely identified explicit panel-pair solid checks.")
    }
    for check in solidChecks ?? [] {try check.validateDefinition(panelIDs:ids,values:variables)}
    return PaperNet(size:extent,panels:resolved,folds:folds,joins:resolvedJoins,
      cutEdges:Self.cutEdges(panels:resolved,folds:folds),rootPanelID:rootPanelID)
  }
  private static func signedArea(_ p:[Point2])->Double {p.indices.reduce(0){s,i in let q=p[(i+1)%p.count];return s+p[i].x*q.y-q.x*p[i].y}/2}
  private static func side(_ p:Point2,_ a:Point2,_ b:Point2)->Double {(b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)}
  private static func onSegment(_ p:Point2,_ a:Point2,_ b:Point2)->Bool {
    abs(side(p,a,b))<=1e-6*max(1,hypot(b.x-a.x,b.y-a.y)) && p.x>=min(a.x,b.x)-1e-6 && p.x<=max(a.x,b.x)+1e-6 && p.y>=min(a.y,b.y)-1e-6 && p.y<=max(a.y,b.y)+1e-6
  }
  private static func onBoundary(_ p:Point2,_ polygon:[Point2])->Bool {polygon.indices.contains{onSegment(p,polygon[$0],polygon[($0+1)%polygon.count])}}
  private static func contains(_ p:Point2,_ polygon:[Point2])->Bool {
    if onBoundary(p,polygon){return true}
    var inside=false
    for i in polygon.indices {
      let a=polygon[i],b=polygon[(i+1)%polygon.count]
      if (a.y>p.y) != (b.y>p.y),p.x<(b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x{inside.toggle()}
    };return inside
  }
  private static func boundaryCovers(_ start:Point2,_ end:Point2,_ polygon:[Point2])->Bool {
    let dx=end.x-start.x,dy=end.y-start.y,length2=dx*dx+dy*dy,length=sqrt(length2)
    guard length>0.001 else{return false}
    var intervals:[(Double,Double)]=[]
    for i in polygon.indices {
      let a=polygon[i],b=polygon[(i+1)%polygon.count]
      guard abs(side(a,start,end))/length<=1e-6,abs(side(b,start,end))/length<=1e-6 else{continue}
      let u=((a.x-start.x)*dx+(a.y-start.y)*dy)/length2,v=((b.x-start.x)*dx+(b.y-start.y)*dy)/length2
      let low=max(0,min(u,v)),high=min(1,max(u,v))
      if high>low {intervals.append((low,high))}
    }
    intervals.sort{$0.0<$1.0};var cursor=0.0
    for interval in intervals {
      guard interval.0<=cursor+1e-6/length else{return false}
      cursor=max(cursor,interval.1)
    }
    return cursor>=1-1e-6/length
  }
  private static func crosses(_ a:Point2,_ b:Point2,_ c:Point2,_ d:Point2)->Bool {
    side(c,a,b)*side(d,a,b)<(-1e-10) && side(a,c,d)*side(b,c,d)<(-1e-10)
  }
  private static func selfIntersects(_ p:[Point2])->Bool {
    for i in p.indices {let next=(i+1)%p.count;if hypot(p[i].x-p[next].x,p[i].y-p[next].y)<1e-7{return true}
      for j in p.indices where j>i && j != next && (j+1)%p.count != i {
        if crosses(p[i],p[next],p[j],p[(j+1)%p.count]) || onSegment(p[i],p[j],p[(j+1)%p.count]) || onSegment(p[j],p[i],p[next]) {return true}
      }
    };return false
  }
  private static func overlaps(_ a:[Point2],_ b:[Point2])throws->Bool {
    guard min(a.map(\.x).max()!,b.map(\.x).max()!)>max(a.map(\.x).min()!,b.map(\.x).min()!)+1e-8,
          min(a.map(\.y).max()!,b.map(\.y).max()!)>max(a.map(\.y).min()!,b.map(\.y).min()!)+1e-8 else{return false}
    // Difference remains nonempty and unchanged for disjoint polygons. Empty
    // difference means full coverage; positive-area loss detects containment,
    // concavity and coincident boundaries regardless of vertex subdivision.
    // Compare at the existing Clipper bridge's 0.001 mm precision.
    let quantized=a.map{Point2(($0.x*1000).rounded()/1000,($0.y*1000).rounded()/1000)}
    let sourceArea=abs(signedArea(quantized))
    guard sourceArea>1e-8 else{throw FormError.invalid("Panel geometry is below the polygon kernel's physical precision.")}
    let coordinates=a.flatMap{[$0.x,$0.y]},clips=b.flatMap{[$0.x,$0.y]}
    var count=Int32(a.count),clipCount=Int32(b.count)
    let result=coordinates.withUnsafeBufferPointer {subject in clips.withUnsafeBufferPointer {clip in
      fc_boolean(subject.baseAddress,&count,1,clip.baseAddress,&clipCount,1,0)
    }}
    defer{fc_free(result)}
    if result.status==2{return true} // Empty or over-budget differences cannot prove separation.
    guard result.status==0,result.count>0,let counts=result.counts,let xy=result.coordinates else {
      throw FormError.invalid("Could not validate planar panel separation with the bounded polygon kernel.")
    }
    var at=0,remainingArea=0.0
    for i in 0..<Int(result.count) {
      var polygon:[Point2]=[]
      for _ in 0..<Int(counts[i]) {polygon.append(.init(xy[at],xy[at+1]));at+=2}
      remainingArea+=signedArea(polygon)
    }
    return sourceArea-abs(remainingArea)>1e-7
  }
  private static func cutEdges(panels:[PaperPanel],folds:[PaperFold])->[PaperEdge] {
    var result:[PaperEdge]=[],seen=Set<String>()
    for panel in panels {for i in panel.polygon.indices {
      let a=panel.polygon[i],b=panel.polygon[(i+1)%panel.polygon.count],dx=b.x-a.x,dy=b.y-a.y,length2=dx*dx+dy*dy
      var intervals:[(Double,Double)]=[]
      let length=sqrt(length2)
      for fold in folds where abs(side(fold.start,a,b))/length<=1e-6 && abs(side(fold.end,a,b))/length<=1e-6 {
        let u=((fold.start.x-a.x)*dx+(fold.start.y-a.y)*dy)/length2,v=((fold.end.x-a.x)*dx+(fold.end.y-a.y)*dy)/length2
        let low=max(0,min(u,v)),high=min(1,max(u,v))
        if high-low>1e-8 {intervals.append((low,high))}
      }
      intervals.sort{$0.0<$1.0};var cursor=0.0,segments:[(Double,Double)]=[]
      for interval in intervals {if interval.0>cursor+1e-8{segments.append((cursor,interval.0))};cursor=max(cursor,interval.1)}
      if cursor<1-1e-8{segments.append((cursor,1))}
      for (n,span) in segments.enumerated() {let p=Point2(a.x+dx*span.0,a.y+dy*span.0),q=Point2(a.x+dx*span.1,a.y+dy*span.1)
        let key=[String(format:"%.6f,%.6f",p.x,p.y),String(format:"%.6f,%.6f",q.x,q.y)].sorted().joined(separator:"|")
        if seen.insert(key).inserted{result.append(.init(id:"\(panel.id).cut.\(i).\(n)",panelID:panel.id,start:p,end:q))}
      }
    }};return result
  }
}

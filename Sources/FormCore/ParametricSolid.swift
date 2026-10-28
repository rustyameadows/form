import Foundation

/// Project-authored constructive geometry. No executable code, object categories,
/// global mutable state, or application-specific generator dispatch is involved.
public struct SolidBinding:Codable,Equatable,Sendable {
  public var name:String
  public var expression:String
  public init(_ name:String,_ expression:String){self.name=name;self.expression=expression}
}
public struct SolidNode:Codable,Equatable,Sendable {
  public var kind:String
  public var count:String?
  public var index:String?
  public var bindings:[SolidBinding]?
  public var values:[String:String]?
  public var children:[SolidNode]?
  public init(kind:String,count:String?=nil,index:String?=nil,bindings:[SolidBinding]?=nil,values:[String:String]?=nil,children:[SolidNode]?=nil){self.kind=kind;self.count=count;self.index=index;self.bindings=bindings;self.values=values;self.children=children}
}
public struct EvaluatedSolid:Sendable {
  public var primitives:[(kind:String,values:[String:Double])]
  public var spacing:Double
  public var floorY:Double?
  public var normalizeHeight:Double?
  public var fillVoids:Bool
}
public struct ParametricSolid:Codable,Equatable,Sendable {
  public var spacing:String
  public var floorY:String?
  public var normalizeHeight:String?
  public var fillVoids:Bool?
  public var nodes:[SolidNode]
  public init(spacing:String="0.32",floorY:String?=nil,normalizeHeight:String?=nil,fillVoids:Bool?=nil,nodes:[SolidNode]){self.spacing=spacing;self.floorY=floorY;self.normalizeHeight=normalizeHeight;self.fillVoids=fillVoids;self.nodes=nodes}
  public func evaluate(_ parameters:[String:Double])throws->EvaluatedSolid {
    func expression(_ s:String,_ vars:[String:Double])throws->Double {try Expression.evaluate(s,variables:vars)}
    func identifier(_ s:String)->Bool {s != "pi" && s.range(of:"^[a-zA-Z][a-zA-Z0-9_]{0,47}$",options:.regularExpression) != nil}
    let spacing=try expression(spacing,parameters),floorY=try floorY.map{try expression($0,parameters)},height=try normalizeHeight.map{try expression($0,parameters)}
    guard (0.15...2).contains(spacing),floorY.map({abs($0)<=1000}) ?? true,height.map({(1...1000).contains($0)}) ?? true else{throw FormError.invalid("Solid spacing must be 0.15–2 mm; optional floor within ±1000 mm and normalized height 1–1000 mm.")}
    var result:[(kind:String,values:[String:Double])]=[],visits=0
    func visit(_ node:SolidNode,_ input:[String:Double],_ depth:Int)throws {
      visits+=1;guard visits<=30_000,depth<=12 else{throw FormError.invalid("Solid construction exceeds its node/depth budget.")}
      let count=try expression(node.count ?? "1",input)
      guard count>=0,count<=1000,count.rounded()==count else{throw FormError.invalid("Solid repetition requires a whole count from 0 to 1000.")}
      if node.count != nil {guard let index=node.index,identifier(index),input[index]==nil else{throw FormError.invalid("Repeated solid nodes require a unique local index name.")}}
      guard (node.bindings?.count ?? 0)<=32 else{throw FormError.invalid("Use at most 32 local bindings per node.")}
      for i in 0..<Int(count) {
        var vars=input;if let index=node.index {vars[index]=Double(i)}
        for binding in node.bindings ?? [] {
          guard identifier(binding.name),vars[binding.name]==nil else{throw FormError.invalid("Solid binding names must be unique within their scope.")}
          vars[binding.name]=try expression(binding.expression,vars)
        }
        if node.kind=="group" {
          guard node.values?.isEmpty != false,let children=node.children,!children.isEmpty,children.count<=256 else{throw FormError.invalid("A solid group needs 1–256 children and no primitive values.")}
          for child in children {try visit(child,vars,depth+1)}
        }else {
          guard node.children?.isEmpty != false,let values=node.values else{throw FormError.invalid("Solid primitives require expression values and no children.")}
          let common:Set<String>=["blend"],required:Set<String>,allowed:Set<String>
          switch node.kind {
          case "segment":required=["x","y","z","endX","endY","endZ","radius","endRadius"];allowed=required.union(common).union(["aspect","endAspect","roll"])
          case "ellipsoid":required=["x","y","z","radiusX","radiusY","radiusZ"];allowed=required.union(common).union(["axisX","axisY","axisZ","roll"])
          default:throw FormError.invalid("Solid nodes support group, segment and ellipsoid.")
          }
          guard required.isSubset(of:Set(values.keys)),Set(values.keys).isSubset(of:allowed) else{throw FormError.invalid("Invalid fields for solid \(node.kind).")}
          let v=try values.mapValues{try expression($0,vars)}
          guard v.values.allSatisfy({abs($0)<=1000}),["radius","endRadius","radiusX","radiusY","radiusZ"].allSatisfy({v[$0].map{(0.1...500).contains($0)} ?? true}),(0...3).contains(v["blend"] ?? 0) else{throw FormError.invalid("Solid coordinates are bounded to ±1000 mm, radii to 0.1–500 mm and blending to 0–3 mm.")}
          if node.kind=="segment" {let dx=v["endX"]!-v["x"]!,dy=v["endY"]!-v["y"]!,dz=v["endZ"]!-v["z"]!;guard dx*dx+dy*dy+dz*dz>1e-10,(0.25...1).contains(v["aspect"] ?? 1),(0.25...1).contains(v["endAspect"] ?? 1) else{throw FormError.invalid("A solid segment needs distinct endpoints and cross-section aspects from 0.25 to 1.")}}
          if node.kind=="ellipsoid" {let x=v["axisX"] ?? 0,y=v["axisY"] ?? 1,z=v["axisZ"] ?? 0;guard x*x+y*y+z*z>1e-10 else{throw FormError.invalid("An ellipsoid needs a nonzero axis.")}}
          guard result.count<12000 else{throw FormError.invalid("Solid construction supports at most 12,000 expanded primitives.")};result.append((node.kind,v))
        }
      }
    }
    guard !nodes.isEmpty,nodes.count<=256 else{throw FormError.invalid("Use 1–256 root solid nodes.")}
    for node in nodes {try visit(node,parameters,0)}
    guard !result.isEmpty else{throw FormError.invalid("A solid must produce at least one primitive.")}
    return .init(primitives:result,spacing:spacing,floorY:floorY,normalizeHeight:height,fillVoids:fillVoids ?? false)
  }
}

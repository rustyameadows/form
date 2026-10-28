import Foundation

/// Project-authored constructive geometry. No executable code, object categories,
/// global mutable state, or application-specific generator dispatch is involved.
public struct SolidBinding:Codable,Equatable,Sendable {
  public var name:String
  public var expression:String
  public init(_ name:String,_ expression:String){self.name=name;self.expression=expression}
}
/// A parameterized closed profile swept along a sampled curve. Expressions are
/// document data; the path variable is scoped to this one curve only.
public struct SolidSweep:Codable,Equatable,Sendable {
  public var samples:String
  public var variable:String
  public var bindings:[SolidBinding]?
  public var values:[String:String]
  public var sides:Int?
  public var profile:[[Double]]?
  public var initialNormal:[String]?
  public var smoothProfile:Bool?
  public init(samples:String="16",variable:String="t",bindings:[SolidBinding]?=nil,values:[String:String],sides:Int?=nil,profile:[[Double]]?=nil,initialNormal:[String]?=nil,smoothProfile:Bool?=nil){self.samples=samples;self.variable=variable;self.bindings=bindings;self.values=values;self.sides=sides;self.profile=profile;self.initialNormal=initialNormal;self.smoothProfile=smoothProfile}
}
public struct EvaluatedSolidSweep:Sendable {
  public var sections:[[String:Double]]
  public var profile:[[Double]]?
  public var sides:Int
  public var initialNormal:[Double]?
  public var smoothProfile:Bool
}
public struct SolidNode:Codable,Equatable,Sendable {
  public var kind:String
  public var count:String?
  public var index:String?
  public var bindings:[SolidBinding]?
  public var values:[String:String]?
  public var children:[SolidNode]?
  public var sweep:SolidSweep?
  public init(kind:String,count:String?=nil,index:String?=nil,bindings:[SolidBinding]?=nil,values:[String:String]?=nil,children:[SolidNode]?=nil,sweep:SolidSweep?=nil){self.kind=kind;self.count=count;self.index=index;self.bindings=bindings;self.values=values;self.children=children;self.sweep=sweep}
}
public struct EvaluatedSolid:Sendable {
  public var primitives:[(kind:String,values:[String:Double])]
  public var sweeps:[EvaluatedSolidSweep]
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
  /// Optional project-authored geometry for responsive native editing. Exports
  /// and final evaluation continue to use `nodes` unless explicitly requested.
  public var previewNodes:[SolidNode]?
  public init(spacing:String="0.32",floorY:String?=nil,normalizeHeight:String?=nil,fillVoids:Bool?=nil,nodes:[SolidNode],previewNodes:[SolidNode]?=nil){self.spacing=spacing;self.floorY=floorY;self.normalizeHeight=normalizeHeight;self.fillVoids=fillVoids;self.nodes=nodes;self.previewNodes=previewNodes}
  /// A standalone definition for editing, retaining physical scale and settings.
  /// Removing the alternate nodes makes evaluation and cache identity explicit.
  public var editingPreviewDefinition:ParametricSolid {
    var definition=self
    definition.nodes=previewNodes ?? nodes
    definition.previewNodes=nil
    return definition
  }
  /// Validate both retained representations when accepting project source. An
  /// ordinary evaluation only visits its selected representation once.
  public func validateDefinitions(_ parameters:[String:Double])throws {
    _ = try evaluate(parameters)
    if previewNodes != nil {_ = try evaluate(parameters,useEditingPreview:true)}
  }
  public func evaluate(_ parameters:[String:Double],useEditingPreview:Bool=false)throws->EvaluatedSolid {
    try Task.checkCancellation()
    let selectedNodes=useEditingPreview ? (previewNodes ?? nodes) : nodes
    func expression(_ s:String,_ vars:[String:Double])throws->Double {try Expression.evaluate(s,variables:vars)}
    func identifier(_ s:String)->Bool {s != "pi" && s.range(of:"^[a-zA-Z][a-zA-Z0-9_]{0,47}$",options:.regularExpression) != nil}
    let spacing=try expression(spacing,parameters),floorY=try floorY.map{try expression($0,parameters)},height=try normalizeHeight.map{try expression($0,parameters)}
    guard (0.15...2).contains(spacing),floorY.map({abs($0)<=1000}) ?? true,height.map({(1...1000).contains($0)}) ?? true else{throw FormError.invalid("Solid spacing must be 0.15–2 mm; optional floor within ±1000 mm and normalized height 1–1000 mm.")}
    var result:[(kind:String,values:[String:Double])]=[],sweeps:[EvaluatedSolidSweep]=[],visits=0,estimatedTriangles=0,workUnits=0
    func cancellationCheckpoint()throws {
      workUnits+=1
      if workUnits & 127 == 0 {try Task.checkCancellation()}
    }
    func visit(_ node:SolidNode,_ input:[String:Double],_ depth:Int)throws {
      try cancellationCheckpoint()
      visits+=1;guard visits<=30_000,depth<=12 else{throw FormError.invalid("Solid construction exceeds its node/depth budget.")}
      let count=try expression(node.count ?? "1",input)
      guard count>=0,count<=1000,count.rounded()==count else{throw FormError.invalid("Solid repetition requires a whole count from 0 to 1000.")}
      if node.count != nil {guard let index=node.index,identifier(index),input[index]==nil else{throw FormError.invalid("Repeated solid nodes require a unique local index name.")}}
      else if node.index != nil {throw FormError.invalid("A solid index requires an explicit repeat count.")}
      guard (node.bindings?.count ?? 0)<=32 else{throw FormError.invalid("Use at most 32 local bindings per node.")}
      for i in 0..<Int(count) {
        try cancellationCheckpoint()
        var vars=input;if let index=node.index {vars[index]=Double(i)}
        for binding in node.bindings ?? [] {
          guard identifier(binding.name),vars[binding.name]==nil else{throw FormError.invalid("Solid binding names must be unique within their scope.")}
          vars[binding.name]=try expression(binding.expression,vars)
        }
        if node.kind=="group" {
          guard node.sweep==nil,node.values?.isEmpty != false,let children=node.children,!children.isEmpty,children.count<=256 else{throw FormError.invalid("A solid group needs 1–256 children and no primitive values.")}
          for child in children {try visit(child,vars,depth+1)}
        }else if node.kind=="sweep" {
          guard node.children?.isEmpty != false,node.values?.isEmpty != false,let path=node.sweep,identifier(path.variable),vars[path.variable]==nil,(path.bindings?.count ?? 0)<=32 else{throw FormError.invalid("A sweep requires a curve and a unique path variable, without children or primitive values.")}
          let samples=try expression(path.samples,vars),sides=path.sides ?? 16
          guard (2...128).contains(samples),samples.rounded()==samples,(3...64).contains(sides) else{throw FormError.invalid("A sweep requires 2–128 curve samples and 3–64 profile sides.")}
          if let profile=path.profile {guard path.sides==nil,(3...64).contains(profile.count),profile.allSatisfy({$0.count==2 && $0.allSatisfy({$0.isFinite && abs($0)<=10})}) else{throw FormError.invalid("Use a closed profile of 3–64 finite coordinate pairs within ±10, or an elliptical side count.")};try Self.validateProfile(profile)}
          let profileCount=path.profile?.count ?? sides
          estimatedTriangles+=(Int(samples)-1)*profileCount*2+(profileCount-2)*2
          guard estimatedTriangles<=1_800_000,result.count+sweeps.count<12000 else{throw FormError.invalid("Analytic sweeps exceed the 1.8 million triangle or 12,000 construction budget.")}
          let allowed:Set<String>=["x","y","z","radiusX","radiusY","roll"],required=allowed.subtracting(["roll"])
          guard required.isSubset(of:Set(path.values.keys)),Set(path.values.keys).isSubset(of:allowed) else{throw FormError.invalid("Sweep section expressions require x/y/z/radiusX/radiusY and optional roll.")}
          var sections:[[String:Double]]=[]
          for sample in 0..<Int(samples) {
            try cancellationCheckpoint()
            var local=vars;local[path.variable]=Double(sample)/Double(Int(samples)-1)
            for binding in path.bindings ?? [] {
              guard identifier(binding.name),local[binding.name]==nil else{throw FormError.invalid("Sweep bindings must be unique in their curve scope.")}
              local[binding.name]=try expression(binding.expression,local)
            }
            let section=try path.values.mapValues{try expression($0,local)}
            guard section.values.allSatisfy({abs($0)<=1000}),(0.005...500).contains(section["radiusX"]!),(0.005...500).contains(section["radiusY"]!) else{throw FormError.invalid("Sweep coordinates and roll are bounded to ±1000; positive section radii must be 0.005–500 mm.")}
            if let previous=sections.last {let distance=["x","y","z"].reduce(0.0){$0+pow(section[$1]!-previous[$1]!,2)};guard distance>1e-16 else{throw FormError.invalid("Consecutive sweep curve samples must be distinct.")}}
            sections.append(section)
          }
          let normal:[Double]?
          if let expressions=path.initialNormal {guard expressions.count==3 else{throw FormError.invalid("A sweep initial normal requires three expressions.")};let n=try expressions.map{try expression($0,vars)};guard n.allSatisfy({abs($0)<=1000}),n.reduce(0,{$0+$1*$1})>1e-16 else{throw FormError.invalid("A sweep initial normal must be finite and nonzero.")};normal=n}else{normal=nil}
          let directions=zip(sections,sections.dropFirst()).map{a,b -> [Double] in let d=["x","y","z"].map{b[$0]!-a[$0]!};let length=sqrt(d.reduce(0,{$0+$1*$1}));return d.map{$0/length}}
          func dot(_ a:[Double],_ b:[Double])->Double{zip(a,b).reduce(0,{$0+$1.0*$1.1})}
          if let normal {let first=directions[0],length=dot(normal,normal),projection=dot(normal,first);guard length-projection*projection>1e-16*length else{throw FormError.invalid("The sweep initial normal must not be parallel to the first path segment.")}}
          for (a,b) in zip(directions,directions.dropFirst()) {guard dot(a,b) > -0.999999 else{throw FormError.invalid("A sweep path must not reverse at a section.")}}
          sweeps.append(.init(sections:sections,profile:path.profile,sides:sides,initialNormal:normal,smoothProfile:path.smoothProfile ?? true))
        }else {
          guard node.sweep==nil,node.children?.isEmpty != false,let values=node.values else{throw FormError.invalid("Solid primitives require expression values and no children.")}
          let common:Set<String>=["blend"],required:Set<String>,allowed:Set<String>
          switch node.kind {
          case "segment":required=["x","y","z","endX","endY","endZ","radius","endRadius"];allowed=required.union(common).union(["aspect","endAspect","roll"])
          case "ellipsoid":required=["x","y","z","radiusX","radiusY","radiusZ"];allowed=required.union(common).union(["axisX","axisY","axisZ","roll"])
          default:throw FormError.invalid("Solid nodes support group, segment, ellipsoid and sweep.")
          }
          guard required.isSubset(of:Set(values.keys)),Set(values.keys).isSubset(of:allowed) else{throw FormError.invalid("Invalid fields for solid \(node.kind).")}
          let v=try values.mapValues{try expression($0,vars)}
          guard v.values.allSatisfy({abs($0)<=1000}),["radius","endRadius","radiusX","radiusY","radiusZ"].allSatisfy({v[$0].map{(0.1...500).contains($0)} ?? true}),(0...3).contains(v["blend"] ?? 0) else{throw FormError.invalid("Solid coordinates are bounded to ±1000 mm, radii to 0.1–500 mm and blending to 0–3 mm.")}
          if node.kind=="segment" {let dx=v["endX"]!-v["x"]!,dy=v["endY"]!-v["y"]!,dz=v["endZ"]!-v["z"]!;guard dx*dx+dy*dy+dz*dz>1e-10,(0.25...1).contains(v["aspect"] ?? 1),(0.25...1).contains(v["endAspect"] ?? 1) else{throw FormError.invalid("A solid segment needs distinct endpoints and cross-section aspects from 0.25 to 1.")}}
          if node.kind=="ellipsoid" {let x=v["axisX"] ?? 0,y=v["axisY"] ?? 1,z=v["axisZ"] ?? 0;guard x*x+y*y+z*z>1e-10 else{throw FormError.invalid("An ellipsoid needs a nonzero axis.")}}
          guard result.count+sweeps.count<12000 else{throw FormError.invalid("Solid construction supports at most 12,000 expanded primitives.")};result.append((node.kind,v))
        }
      }
    }
    guard !selectedNodes.isEmpty,selectedNodes.count<=256 else{throw FormError.invalid("Use 1–256 root solid nodes.")}
    for node in selectedNodes {try visit(node,parameters,0)}
    guard !result.isEmpty || !sweeps.isEmpty else{throw FormError.invalid("A solid must produce at least one primitive or sweep.")}
    if !sweeps.isEmpty,floorY != nil {throw FormError.invalid("Planar floor trimming applies to sampled solids only; author capped analytic sweeps above the desired plane.")}
    try Task.checkCancellation()
    return .init(primitives:result,sweeps:sweeps,spacing:spacing,floorY:floorY,normalizeHeight:height,fillVoids:fillVoids ?? false)
  }
  public var hasAnalyticSweeps:Bool {
    func contains(_ nodes:[SolidNode])->Bool{nodes.contains{$0.kind=="sweep" || contains($0.children ?? [])}}
    return contains(nodes)
  }
  private static func validateProfile(_ profile:[[Double]])throws {
    func cross(_ a:[Double],_ b:[Double],_ c:[Double])->Double{(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])}
    func on(_ a:[Double],_ b:[Double],_ p:[Double])->Bool{abs(cross(a,b,p))<1e-10 && p[0]>=min(a[0],b[0])-1e-10 && p[0]<=max(a[0],b[0])+1e-10 && p[1]>=min(a[1],b[1])-1e-10 && p[1]<=max(a[1],b[1])+1e-10}
    var area=0.0
    for i in profile.indices {
      let a=profile[i],b=profile[(i+1)%profile.count]
      guard pow(a[0]-b[0],2)+pow(a[1]-b[1],2)>1e-16 else{throw FormError.invalid("Sweep profile points must be distinct.")}
      guard abs(cross(a,b,profile[(i+2)%profile.count]))>1e-10 else{throw FormError.invalid("Sweep profile corners must not be collinear.")}
      area+=a[0]*b[1]-b[0]*a[1]
      for j in (i+1)..<profile.count where j != i+1 && !(i==0 && j==profile.count-1) {
        let c=profile[j],d=profile[(j+1)%profile.count],abC=cross(a,b,c),abD=cross(a,b,d),cdA=cross(c,d,a),cdB=cross(c,d,b)
        guard !(abC*abD<0 && cdA*cdB<0),!on(a,b,c),!on(a,b,d),!on(c,d,a),!on(c,d,b) else{throw FormError.invalid("A sweep profile must be a simple polygon without intersecting edges.")}
      }
    }
    guard abs(area)>1e-10 else{throw FormError.invalid("A sweep profile must enclose positive area.")}
  }
}

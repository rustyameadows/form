import Foundation

public struct CADModelError: LocalizedError, Sendable {
  public let message:String
  public init(_ message:String){self.message=message}
  public var errorDescription:String?{message}
}
public struct CADScalar: Codable, Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
  public var expression:String
  public init(_ expression:String){self.expression=expression}
  public init(_ value:Double){expression=String(value)}
  public init(stringLiteral value:String){expression=value}
  public init(integerLiteral value:Int){expression=String(value)}
  public init(floatLiteral value:Double){expression=String(value)}
  public init(from decoder:Decoder)throws{let c=try decoder.singleValueContainer();if let number=try? c.decode(Double.self){guard number.isFinite else{throw CADModelError("Use a finite CAD scalar.")};expression=String(number)}else{expression=try c.decode(String.self)}}
  public func encode(to encoder:Encoder)throws{var c=encoder.singleValueContainer();try c.encode(expression)}
}
public struct CADModelVector: Codable, Equatable, Sendable {
  public var x:Double,y:Double,z:Double
  public init(_ x:Double=0,_ y:Double=0,_ z:Double=0){self.x=x;self.y=y;self.z=z}
  public static let xAxis=Self(1,0,0),yAxis=Self(0,1,0),zAxis=Self(0,0,1)
}
public struct CADExpressionPoint: Codable, Equatable, Sendable {
  public var x:CADScalar,y:CADScalar,z:CADScalar
  public init(_ x:CADScalar=0,_ y:CADScalar=0,_ z:CADScalar=0){self.x=x;self.y=y;self.z=z}
}
public struct CADExpressionPoint2: Codable, Equatable, Sendable {
  public var x:CADScalar,y:CADScalar
  public init(_ x:CADScalar,_ y:CADScalar){self.x=x;self.y=y}
}
public struct CADPlaneDefinition: Codable, Equatable, Sendable {
  public var origin:CADExpressionPoint,u:CADModelVector,v:CADModelVector
  public init(origin:CADExpressionPoint = .init(),u:CADModelVector,v:CADModelVector){self.origin=origin;self.u=u;self.v=v}
  public static let xy=Self(u:.xAxis,v:.yAxis),xz=Self(u:.xAxis,v:.init(0,0,-1)),yz=Self(u:.yAxis,v:.zAxis)
}
public struct CADModelCurveSegment: Codable, Equatable, Sendable {
  public enum Kind:String,Codable,Sendable{case line,quadraticBezier,cubicBezier,circularArc}
  public var kind:Kind,start:CADExpressionPoint2,control1:CADExpressionPoint2?,control2:CADExpressionPoint2?,end:CADExpressionPoint2
  public init(_ kind:Kind,start:CADExpressionPoint2,control1:CADExpressionPoint2?=nil,control2:CADExpressionPoint2?=nil,end:CADExpressionPoint2){self.kind=kind;self.start=start;self.control1=control1;self.control2=control2;self.end=end}
}
public enum CADTopologySelection: Codable, Equatable, Sendable {
  case allEdges
  case edges(revisionHash:String,indices:[UInt32])
  case faces(revisionHash:String,indices:[UInt32])
  case faceAtMaximum(axis:String)
  case faceAtMinimum(axis:String)
  case facesAtExtrema(axis:String)
  /// Matches one face's area centroid against an authored parametric datum.
  /// Multiple matches always require review; there is no nearest-face fallback.
  case faceAtCenter(point:CADExpressionPoint,tolerance:Double)
  /// Entire straight edges on the named bounding plane; curved edges require
  /// an explicitly inspected revision selection instead of an inferred target.
  case straightEdgesAtMaximum(axis:String)
  case straightEdgesAtMinimum(axis:String)
}
public struct CADSourceReference: Codable, Equatable, Sendable {
  public var path:String,sha256:String
  public var partPath:String?
  public init(path:String,sha256:String,partPath:String?=nil){self.path=path;self.sha256=sha256;self.partPath=partPath}
}
public enum CADFeatureKind:String,Codable,CaseIterable,Sendable {
  case hole,slot,pocket,boss,offsetProfile,copy,join,box,cylinder,cone,sphere,torus,profile,circleProfile,curveProfile,extrude,extrudeCut,revolve,revolveCut,union,subtract,intersect,fillet,chamfer,shell,sweep,loft,transform,linearPattern,circularPattern,mirror,assembly,importedBRep,importedSTEP
  public var inputRange:ClosedRange<Int>{switch self{case .box,.cylinder,.cone,.sphere,.torus,.profile,.circleProfile,.curveProfile,.importedBRep,.importedSTEP:return 0...0;case .union,.subtract,.intersect,.extrudeCut,.revolveCut,.pocket,.boss,.join:return 2...2;case .loft:return 2...64;case .assembly:return 1...1024;default:return 1...1}}
  public var scalarKeys:Set<String>{switch self{case .hole:return ["radius","depth"];case .slot:return ["length","width","depth"];case .pocket,.boss,.offsetProfile:return ["distance"];case .box:return ["width","height","depth"];case .cylinder:return ["radius","height"];case .cone:return ["bottomRadius","topRadius","height"];case .sphere,.circleProfile:return ["radius"];case .torus:return ["majorRadius","minorRadius"];case .extrude,.extrudeCut:return ["distance"];case .revolve,.revolveCut:return ["angleDegrees"];case .fillet:return ["radius"];case .chamfer:return ["distance"];case .shell:return ["thickness"];case .linearPattern:return ["count"];case .circularPattern:return ["count","angleStepDegrees"];default:return []}}
  public var requiredScalarKeys:Set<String>{switch self{case .revolve,.revolveCut:return [];default:return scalarKeys}}
  public var canSuppressToFirstInput:Bool{[.hole,.slot,.pocket,.boss,.offsetProfile,.copy,.fillet,.chamfer,.shell,.transform,.linearPattern,.circularPattern,.mirror,.extrudeCut,.revolveCut].contains(self)}
}
public struct CADFeatureOperation: Codable, Equatable, Sendable {
  public var kind:CADFeatureKind
  public var inputs:[UUID]
  public var values:[String:CADScalar]
  public var points:[CADExpressionPoint2]?
  public var holes:[[CADExpressionPoint2]]?
  public var curves:[CADModelCurveSegment]?
  public var plane:CADPlaneDefinition?
  public var direction:CADModelVector?
  public var origin:CADExpressionPoint?
  public var vector:CADExpressionPoint?
  public var path:[CADExpressionPoint]?
  public var matrix:[CADScalar]?
  public var selection:CADTopologySelection?
  public var source:CADSourceReference?
  public var ruled:Bool?
  public init(_ kind:CADFeatureKind,inputs:[UUID]=[],values:[String:CADScalar]=[:],points:[CADExpressionPoint2]?=nil,holes:[[CADExpressionPoint2]]?=nil,curves:[CADModelCurveSegment]?=nil,plane:CADPlaneDefinition?=nil,direction:CADModelVector?=nil,origin:CADExpressionPoint?=nil,vector:CADExpressionPoint?=nil,path:[CADExpressionPoint]?=nil,matrix:[CADScalar]?=nil,selection:CADTopologySelection?=nil,source:CADSourceReference?=nil,ruled:Bool?=nil){self.kind=kind;self.inputs=inputs;self.values=values;self.points=points;self.holes=holes;self.curves=curves;self.plane=plane;self.direction=direction;self.origin=origin;self.vector=vector;self.path=path;self.matrix=matrix;self.selection=selection;self.source=source;self.ruled=ruled}
  enum CodingKeys:String,CodingKey{case kind,inputs,values,points,holes,curves,plane,direction,origin,vector,path,matrix,selection,source,ruled}
  public init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);kind=try c.decode(CADFeatureKind.self,forKey:.kind);inputs=try c.decodeIfPresent([UUID].self,forKey:.inputs) ?? [];values=try c.decodeIfPresent([String:CADScalar].self,forKey:.values) ?? [:];points=try c.decodeIfPresent([CADExpressionPoint2].self,forKey:.points);holes=try c.decodeIfPresent([[CADExpressionPoint2]].self,forKey:.holes);curves=try c.decodeIfPresent([CADModelCurveSegment].self,forKey:.curves);plane=try c.decodeIfPresent(CADPlaneDefinition.self,forKey:.plane);direction=try c.decodeIfPresent(CADModelVector.self,forKey:.direction);origin=try c.decodeIfPresent(CADExpressionPoint.self,forKey:.origin);vector=try c.decodeIfPresent(CADExpressionPoint.self,forKey:.vector);path=try c.decodeIfPresent([CADExpressionPoint].self,forKey:.path);matrix=try c.decodeIfPresent([CADScalar].self,forKey:.matrix);selection=try c.decodeIfPresent(CADTopologySelection.self,forKey:.selection);source=try c.decodeIfPresent(CADSourceReference.self,forKey:.source);ruled=try c.decodeIfPresent(Bool.self,forKey:.ruled)}
}
public struct CADFeatureNode: Codable, Equatable, Identifiable, Sendable {
  public var id:UUID,name:String,operation:CADFeatureOperation,suppressed:Bool
  public init(id:UUID=UUID(),name:String,operation:CADFeatureOperation,suppressed:Bool=false){self.id=id;self.name=name;self.operation=operation;self.suppressed=suppressed}
  enum CodingKeys:String,CodingKey{case id,name,operation,suppressed}
  public init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);id=try c.decode(UUID.self,forKey:.id);name=try c.decode(String.self,forKey:.name);operation=try c.decode(CADFeatureOperation.self,forKey:.operation);suppressed=try c.decodeIfPresent(Bool.self,forKey:.suppressed) ?? false}
}
public struct CADModelParameter: Codable, Equatable, Sendable {
  public var name:String,value:Double,minimum:Double,maximum:Double,unit:String
  public init(_ name:String,_ value:Double,_ range:ClosedRange<Double>,unit:String="mm"){self.name=name;self.value=value;minimum=range.lowerBound;maximum=range.upperBound;self.unit=unit}
}
public struct CADModelDefinition: Codable, Equatable, Identifiable, Sendable {
  public var id:UUID,version:Int,revision:Int,name:String,parameters:[CADModelParameter],features:[CADFeatureNode],outputs:[UUID]
  public var assumptions:[String],unresolvedMeasurements:[String]
  public var importedAssemblies:[CADImportedAssembly]?
  public var requirements:[CADModelRequirement]?
  public var outputRequirements:[CADOutputRequirement]?
  public var surfaces:[CADPlanarSurface]?
  public init(id:UUID=UUID(),version:Int=1,revision:Int=0,name:String,parameters:[CADModelParameter]=[],features:[CADFeatureNode],outputs:[UUID],assumptions:[String]=[],unresolvedMeasurements:[String]=[],importedAssemblies:[CADImportedAssembly]?=nil,requirements:[CADModelRequirement]=[],outputRequirements:[CADOutputRequirement]=[],surfaces:[CADPlanarSurface]=[]){self.id=id;self.version=version==1 && (!requirements.isEmpty || !outputRequirements.isEmpty || !surfaces.isEmpty) ? 2:version;self.revision=revision;self.name=name;self.parameters=parameters;self.features=features;self.outputs=outputs;self.assumptions=assumptions;self.unresolvedMeasurements=unresolvedMeasurements;self.importedAssemblies=importedAssemblies;self.requirements=requirements.isEmpty ? nil:requirements;self.outputRequirements=outputRequirements.isEmpty ? nil:outputRequirements;self.surfaces=surfaces.isEmpty ? nil:surfaces}
  enum CodingKeys:String,CodingKey{case id,version,revision,name,parameters,features,outputs,assumptions,unresolvedMeasurements,importedAssemblies,requirements,outputRequirements,surfaces}
  public init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);id=try c.decode(UUID.self,forKey:.id);version=try c.decode(Int.self,forKey:.version);revision=try c.decodeIfPresent(Int.self,forKey:.revision) ?? 0;name=try c.decode(String.self,forKey:.name);parameters=try c.decodeIfPresent([CADModelParameter].self,forKey:.parameters) ?? [];features=try c.decode([CADFeatureNode].self,forKey:.features);outputs=try c.decode([UUID].self,forKey:.outputs);assumptions=try c.decodeIfPresent([String].self,forKey:.assumptions) ?? [];unresolvedMeasurements=try c.decodeIfPresent([String].self,forKey:.unresolvedMeasurements) ?? [];importedAssemblies=try c.decodeIfPresent([CADImportedAssembly].self,forKey:.importedAssemblies);requirements=try c.decodeIfPresent([CADModelRequirement].self,forKey:.requirements);outputRequirements=try c.decodeIfPresent([CADOutputRequirement].self,forKey:.outputRequirements);surfaces=try c.decodeIfPresent([CADPlanarSurface].self,forKey:.surfaces)}
  public var parameterValues:[String:Double]{Dictionary(parameters.map{($0.name,$0.value)},uniquingKeysWith:{$1})}
  public mutating func setParameter(_ name:String,value:Double)throws{guard let i=parameters.firstIndex(where:{$0.name==name}),value.isFinite,value>=parameters[i].minimum,value<=parameters[i].maximum else{throw CADModelError("Unknown or out-of-range CAD parameter '\(name)'.")};if parameters[i].value != value{parameters[i].value=value;revision+=1}}
  /// Validates stable references, expression syntax, bounds and dependency order.
  public func validatedOrder(checkRequirements:Bool=true)throws->[CADFeatureNode]{
    guard (version==1 || version==2),revision>=0,revision<=1_000_000_000,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.utf8.count<=256,parameters.count<=128,features.count>0,features.count<=256,outputs.count>0,outputs.count<=256 else{throw CADModelError("Unsupported CAD model version or bounded graph size.")}
    guard assumptions.count<=128,unresolvedMeasurements.count<=128,(assumptions+unresolvedMeasurements).allSatisfy({$0.utf8.count<=2048}) else{throw CADModelError("Keep model assumptions and unresolved measurements bounded.")}
    try validateImportedAssemblies()
    let names=parameters.map(\.name);guard Set(names).count==names.count else{throw CADModelError("CAD parameter names must be unique.")}
    for p in parameters{guard CADExpression.validName(p.name),p.value.isFinite,p.minimum.isFinite,p.maximum.isFinite,p.minimum<=p.value,p.value<=p.maximum,abs(p.minimum)<=1e7,abs(p.maximum)<=1e7,p.unit.utf8.count<=16 else{throw CADModelError("CAD parameter '\(p.name)' has invalid bounds, name, units or value.")}}
    guard (requirements?.count ?? 0)<=128,Set((requirements ?? []).map(\.id)).count==(requirements?.count ?? 0) else{throw CADModelError("CAD requirements must have unique identities and at most 128 entries.")}
    guard (requirements?.isEmpty != false && outputRequirements?.isEmpty != false && surfaces?.isEmpty != false) || version>=2 else{throw CADModelError("Saved CAD requirements and surfaces require model version 2 so older readers reject unsupported construction data.")}
    for requirement in requirements ?? []{
      if checkRequirements{try requirement.validate(using:parameterValues)}
      else{
        try requirement.validateMetadata()
        _ = try CADExpression.evaluate(requirement.lhs.expression,variables:parameterValues)
        _ = try CADExpression.evaluate(requirement.rhs.expression,variables:parameterValues)
      }
    }
    let checks=outputRequirements ?? []
    guard checks.count<=128,Set(checks.map(\.id)).count==checks.count else{throw CADModelError("Geometry requirements must have unique identities and at most 128 entries.")}
    let requirementIDs=(requirements ?? []).map(\.id)+checks.map(\.id)
    guard Set(requirementIDs).count==requirementIDs.count else{throw CADModelError("Requirement identities must be unique across parameter and geometry checks.")}
    for check in checks{try check.validateDefinition(outputs:Set(outputs),values:parameterValues)}
    let surfaceDefinitions=surfaces ?? []
    guard surfaceDefinitions.count<=64,Set(surfaceDefinitions.map(\.id)).count==surfaceDefinitions.count else{throw CADModelError("Planar surface identities must be unique with at most 64 surfaces per model.")}
    for surface in surfaceDefinitions{guard outputs.contains(surface.outputFeatureID) else{throw CADModelError("Planar surface references a missing output feature.")};_ = try surface.resolved(using:parameterValues)}
    guard Set(features.map(\.id)).count==features.count,Set(outputs).count==outputs.count else{throw CADModelError("CAD feature/output IDs must be unique.")}
    let byID=Dictionary(uniqueKeysWithValues:features.map{($0.id,$0)}),values=parameterValues
    var totalExpressions=0
    for f in features{
      guard !f.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,f.name.utf8.count<=256,f.operation.kind.inputRange.contains(f.operation.inputs.count),Set(f.operation.inputs).count==f.operation.inputs.count,Set(f.operation.values.keys).isSubset(of:f.operation.kind.scalarKeys),f.operation.kind.requiredScalarKeys.isSubset(of:Set(f.operation.values.keys)) else{throw CADModelError("Feature '\(f.name)' has unsupported inputs or scalar fields.")}
      for id in f.operation.inputs{guard byID[id] != nil else{throw CADModelError("Feature '\(f.name)' depends on a missing source feature.")}}
      try f.operation.validatePayload()
      _ = try f.operation.resolved(using:values,count:&totalExpressions)
      guard totalExpressions<=32768 else{throw CADModelError("CAD graph exceeds 32,768 scalar expressions.")}
    }
    var state:[UUID:Int]=[:],ordered:[CADFeatureNode]=[]
    func visit(_ id:UUID,_ depth:Int)throws{guard depth<=256,let f=byID[id] else{throw CADModelError("Missing CAD feature or excessive dependency depth.")};if state[id]==1{throw CADModelError("CAD feature dependency cycle at '\(f.name)'.")};if state[id]==2{return};state[id]=1;for dep in f.operation.inputs{try visit(dep,depth+1)};state[id]=2;ordered.append(f)}
    for f in features{try visit(f.id,0)};for output in outputs{guard byID[output] != nil else{throw CADModelError("CAD output feature is missing.")}}
    return ordered
  }
}

extension CADFeatureOperation {
  /// Replaces scalar expressions by resolved finite literals. Used for selective
  /// feature hashing; unrelated parameter changes cannot invalidate this node.
  public func resolved(using values:[String:Double],count:inout Int)throws->Self {
    func scalar(_ v:CADScalar)throws->CADScalar{count+=1;return CADScalar(try CADExpression.evaluate(v.expression,variables:values))}
    func p2(_ p:CADExpressionPoint2)throws->CADExpressionPoint2{.init(try scalar(p.x),try scalar(p.y))}
    func p3(_ p:CADExpressionPoint)throws->CADExpressionPoint{.init(try scalar(p.x),try scalar(p.y),try scalar(p.z))}
    var result=self
    result.values=try self.values.mapValues(scalar);result.points=try points?.map(p2);result.holes=try holes?.map{try $0.map(p2)};result.origin=try origin.map(p3);result.vector=try vector.map(p3);result.path=try path?.map(p3);result.matrix=try matrix?.map(scalar)
    if var plane{plane.origin=try p3(plane.origin);result.plane=plane}
    if case let .faceAtCenter(point,tolerance)?=selection {
      guard tolerance.isFinite,tolerance>0,tolerance<=1 else{throw CADModelError("Face datum tolerance must be finite, positive and at most 1 mm.")}
      result.selection = .faceAtCenter(point:try p3(point),tolerance:tolerance)
    }
    result.curves=try curves?.map {s in var s=s;s.start=try p2(s.start);s.end=try p2(s.end);s.control1=try s.control1.map(p2);s.control2=try s.control2.map(p2);return s}
    guard (points?.count ?? 0)<=10000,(holes?.count ?? 0)<=64,(path?.count ?? 0)<=10000,(curves?.count ?? 0)<=10000,(holes?.reduce(0,{$0+$1.count}) ?? 0)+(points?.count ?? 0)<=10000 else{throw CADModelError("CAD profile/path exceeds bounded point counts.")}
    if let matrix{guard matrix.count==16 else{throw CADModelError("CAD affine transform needs exactly 16 scalars.")}}
    if let source{if let part=source.partPath{guard part.utf8.count<=511,part.split(separator:"/").count<=65,!part.isEmpty,!part.hasPrefix("/"),!part.hasSuffix("/"),!part.contains("//"),part.utf8.allSatisfy({(48...57).contains($0)||$0==47}) else{throw CADModelError("STEP part selector must be a bounded source occurrence path.")}};guard source.path.utf8.count<=512,!source.path.hasPrefix("/"),!source.path.contains("\\"),!source.path.split(separator:"/").contains(".."),source.sha256.utf8.count==64,source.sha256.utf8.allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}) else{throw CADModelError("CAD source needs a bounded relative path and pinned SHA256.")}}
    if let direction{let n=direction.x*direction.x+direction.y*direction.y+direction.z*direction.z;guard n.isFinite,n>1e-18 else{throw CADModelError("CAD direction must be finite and non-zero.")}}
    if let plane{let u=plane.u,v=plane.v,a=u.x*u.x+u.y*u.y+u.z*u.z,b=v.x*v.x+v.y*v.y+v.z*v.z,d=u.x*v.x+u.y*v.y+u.z*v.z;guard a.isFinite,b.isFinite,d.isFinite,abs(a-1)<1e-10,abs(b-1)<1e-10,abs(d)<1e-10 else{throw CADModelError("CAD plane axes must be orthonormal.")}}
    return result
  }
}

extension CADFeatureOperation {
  public func validatePayload() throws {
    var present=Set<String>();var allowed=Set<String>()
    if points != nil{present.insert("points")};if holes != nil{present.insert("holes")};if curves != nil{present.insert("curves")};if plane != nil{present.insert("plane")};if direction != nil{present.insert("direction")};if origin != nil{present.insert("origin")};if vector != nil{present.insert("vector")};if path != nil{present.insert("path")};if matrix != nil{present.insert("matrix")};if selection != nil{present.insert("selection")};if source != nil{present.insert("source")};if ruled != nil{present.insert("ruled")}
    switch kind {
    case .profile:allowed=["points","holes","plane"];guard let points,points.count>=3 else{throw CADModelError("A profile needs an outer ring with at least three points.")}
    case .circleProfile:allowed=["plane"]
    case .curveProfile:allowed=["curves","plane"];guard let curves,!curves.isEmpty else{throw CADModelError("A curve profile needs connected segments.")};for curve in curves{if curve.kind != .line && curve.control1==nil{throw CADModelError("A curved segment needs its first control point.")};if curve.kind == .cubicBezier && curve.control2==nil{throw CADModelError("A cubic Bezier segment needs two control points.")}}
    case .extrude,.extrudeCut,.pocket,.boss:allowed=["direction"]
    case .hole,.slot:allowed=["plane","direction"]
    case .revolve,.revolveCut:allowed=["direction","origin"]
    case .fillet,.chamfer:allowed=["selection"]
    case .shell:allowed=["selection"];guard selection != nil else{throw CADModelError("Shell requires an explicit removed-face selection.")}
    case .sweep:allowed=["path"];guard let path,path.count>=2 else{throw CADModelError("Sweep requires a path with at least two points.")}
    case .loft:allowed=["ruled"]
    case .transform:allowed=["matrix"];guard matrix?.count==16 else{throw CADModelError("Transform requires sixteen row-major affine scalars.")}
    case .linearPattern:allowed=["vector"];guard vector != nil else{throw CADModelError("Linear pattern requires a physical step vector.")}
    case .circularPattern:allowed=["direction","origin"]
    case .mirror:allowed=["plane"]
    case .importedBRep,.importedSTEP:allowed=["source"];if kind == .importedBRep,source?.partPath != nil{throw CADModelError("BRep import does not accept a STEP part selector.")};guard source != nil else{throw CADModelError("Imported exact geometry requires its pinned source resource.")}
    default:break
    }
    guard present.isSubset(of:allowed) else{throw CADModelError("Feature '\(kind.rawValue)' contains unsupported payload fields: \(present.subtracting(allowed).sorted().joined(separator:", ")).")}
  }
}

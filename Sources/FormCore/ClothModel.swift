import Foundation
import simd

/// Millimeters at geometry boundaries; meters, kilograms, seconds and compliance
/// in m/N inside the solver. These declarations are not calibrated fabric data.
public struct ClothTriangle:Codable,Equatable,Sendable {
  public var a:Int,b:Int,c:Int
  public init(_ a:Int,_ b:Int,_ c:Int) {self.a=a;self.b=b;self.c=c}
}
public enum ClothLinkKind:String,Codable,CaseIterable,Sendable {case warp,weft,shear,bendDistance,seam}
public struct ClothLink:Codable,Equatable,Sendable {
  public var a:Int,b:Int
  public var kind:ClothLinkKind
  public var restLengthMm:Double?
  public init(_ a:Int,_ b:Int,kind:ClothLinkKind,restLengthMm:Double? = nil) {self.a=a;self.b=b;self.kind=kind;self.restLengthMm=restLengthMm}
}
public struct ClothPin:Codable,Equatable,Sendable {
  public var vertex:Int
  public var targetMm:Vector3
  public init(_ vertex:Int,targetMm:Vector3) {self.vertex=vertex;self.targetMm=targetMm}
}
public struct ClothCollider:Codable,Equatable,Sendable {
  public enum Kind:String,Codable,Sendable {case plane,sphere}
  public var kind:Kind
  public var centerMm:Vector3
  public var normal:Vector3
  public var radiusMm:Double
  public static func plane(pointMm:Vector3 = .init(),normal:Vector3 = .init(0,1,0))->Self {.init(kind:.plane,centerMm:pointMm,normal:normal,radiusMm:0)}
  public static func sphere(centerMm:Vector3,radiusMm:Double)->Self {.init(kind:.sphere,centerMm:centerMm,normal:.init(0,1,0),radiusMm:radiusMm)}
  public func validate()throws {
    guard ClothMath.finite(centerMm),ClothMath.maximum(centerMm)<=100000,ClothMath.finite(normal),ClothMath.maximum(normal)<=10000,
      radiusMm.isFinite,(kind == .plane && simd_length(ClothMath.vector(normal))>1e-10 || kind == .sphere && (0.1...10000).contains(radiusMm)) else {throw FormError.invalid("Cloth contacts need finite static planes with nonzero normals or positive bounded spheres.")}
  }
}
public struct ClothSettings:Codable,Equatable,Sendable {
  public var frameStepSeconds=1.0/60
  public var substeps=6
  public var iterations=4
  public var maximumSimulationSeconds=15.0
  public var gravityMPerSecondSquared=Vector3(0,-9.80665,0)
  public var velocityDampingPerSecond=0.8
  public var warpComplianceMPerN=0.000001
  public var weftComplianceMPerN=0.000001
  public var shearComplianceMPerN=0.000002
  /// Two-cell distance proxy, not an angular bending modulus.
  public var bendDistanceComplianceMPerN=0.01
  public var seamComplianceMPerN=0.0
  public var collisionThicknessMm=0.8
  public var friction=0.25
  public init() {}
  public func compliance(_ kind:ClothLinkKind)->Double {
    switch kind {case .warp:return warpComplianceMPerN;case .weft:return weftComplianceMPerN;case .shear:return shearComplianceMPerN;case .bendDistance:return bendDistanceComplianceMPerN;case .seam:return seamComplianceMPerN}
  }
  public func validate()throws {
    guard frameStepSeconds.isFinite,(1.0/240...1.0/30).contains(frameStepSeconds),(1...16).contains(substeps),(1...24).contains(iterations),
      maximumSimulationSeconds.isFinite,(0.05...120).contains(maximumSimulationSeconds),
      ClothMath.finite(gravityMPerSecondSquared),ClothMath.maximum(gravityMPerSecondSquared)<=100,
      velocityDampingPerSecond.isFinite,(0...30).contains(velocityDampingPerSecond),
      [warpComplianceMPerN,weftComplianceMPerN,shearComplianceMPerN,seamComplianceMPerN].allSatisfy({$0.isFinite && ($0==0 || (1e-12...1).contains($0))}),
      bendDistanceComplianceMPerN.isFinite,(bendDistanceComplianceMPerN==0 || (1e-12...100).contains(bendDistanceComplianceMPerN)),
      collisionThicknessMm.isFinite,(0.1...10).contains(collisionThicknessMm),friction.isFinite,(0...1).contains(friction) else {throw FormError.invalid("Use bounded finite cloth settings: 1/240–1/30 s frames, 1–16 substeps, 1–24 iterations, nonnegative declared compliance/damping, and finite contact thickness/friction.")}
  }
}
public struct ClothMesh:Codable,Equatable,Sendable {
  public static let maximumVertices=4096
  public static let maximumTriangles=8192
  public static let maximumLinks=32768
  public var restPositionsMm:[Vector3]
  public var massesKg:[Double]
  public var triangles:[ClothTriangle]
  public var uv:[Point2]
  public var panelIDs:[Int]?
  public var links:[ClothLink]
  public var pins:[ClothPin]
  public var initialVelocitiesMPerSecond:[Vector3]?
  public init(restPositionsMm:[Vector3],massesKg:[Double],triangles:[ClothTriangle] = [],uv:[Point2] = [],links:[ClothLink] = [],pins:[ClothPin] = []) {
    self.restPositionsMm=restPositionsMm;self.massesKg=massesKg;self.triangles=triangles;self.uv=uv;self.links=links;self.pins=pins
  }
  public func validate()throws {
    let count=restPositionsMm.count
    guard (1...Self.maximumVertices).contains(count),massesKg.count==count,
      restPositionsMm.allSatisfy({ClothMath.finite($0) && ClothMath.maximum($0)<=100000}),massesKg.allSatisfy({$0.isFinite && (1e-12...100).contains($0)}),massesKg.reduce(0,+)<=100,
      triangles.count<=Self.maximumTriangles,links.count<=Self.maximumLinks,pins.count<=count,
      uv.isEmpty || (uv.count==count && uv.allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<=10000 && abs($0.y)<=10000})),
      initialVelocitiesMPerSecond==nil || (initialVelocitiesMPerSecond!.count==count && initialVelocitiesMPerSecond!.allSatisfy({ClothMath.finite($0) && ClothMath.maximum($0)<=100})),
      panelIDs.map({$0.count==count && $0.allSatisfy({(0...63).contains($0)})}) ?? true,
      Set(pins.map(\.vertex)).count==pins.count else {throw FormError.invalid("Cloth needs finite positive masses, bounded geometry/UVs/velocities, and distinct pinned vertices.")}
    for triangle in triangles {
      guard [triangle.a,triangle.b,triangle.c].allSatisfy({(0..<count).contains($0)}),Set([triangle.a,triangle.b,triangle.c]).count==3 else {throw FormError.invalid("Cloth triangle indices must identify three existing vertices.")}
      if let panelIDs {guard panelIDs[triangle.a]==panelIDs[triangle.b],panelIDs[triangle.a]==panelIDs[triangle.c] else {throw FormError.invalid("Cloth triangles cannot cross independent material panels.")}}
      let a=ClothMath.vector(restPositionsMm[triangle.a])/1000,b=ClothMath.vector(restPositionsMm[triangle.b])/1000,c=ClothMath.vector(restPositionsMm[triangle.c])/1000
      guard simd_length(simd_cross(b-a,c-a))>1e-14 else {throw FormError.invalid("The cloth rest mesh contains a degenerate triangle.")}
    }
    var pairs=Set<String>()
    for link in links {
      guard (0..<count).contains(link.a),(0..<count).contains(link.b),link.a != link.b,
        pairs.insert("\(min(link.a,link.b)):\(max(link.a,link.b)):\(link.kind.rawValue)").inserted,
        link.restLengthMm.map({$0.isFinite && (0...200000).contains($0)}) ?? true else {throw FormError.invalid("Cloth links need distinct valid pairs and finite rest lengths.")}
      let rest=link.restLengthMm ?? simd_distance(ClothMath.vector(restPositionsMm[link.a]),ClothMath.vector(restPositionsMm[link.b]))
      guard link.kind == .seam || rest>1e-7 else {throw FormError.invalid("Only seam constraints may have coincident rest endpoints.")}
    }
    for pin in pins {guard (0..<count).contains(pin.vertex),ClothMath.finite(pin.targetMm),ClothMath.maximum(pin.targetMm)<=100000 else {throw FormError.invalid("Cloth pins need valid finite vertex targets.")}}
  }
  /// Lump triangle area/3 into each vertex, using true kg/m² and meter geometry.
  public static func masses(positionsMm:[Vector3],triangles:[ClothTriangle],areaDensityKgPerM2:Double)throws -> [Double] {
    guard areaDensityKgPerM2.isFinite,(0.01...5).contains(areaDensityKgPerM2),!positionsMm.isEmpty,positionsMm.count<=maximumVertices,triangles.count<=maximumTriangles else {throw FormError.invalid("Declare finite 0.01–5 kg/m² areal mass for a bounded cloth mesh.")}
    var result=[Double](repeating:0,count:positionsMm.count)
    for triangle in triangles {
      guard [triangle.a,triangle.b,triangle.c].allSatisfy({positionsMm.indices.contains($0)}) else {throw FormError.invalid("Invalid cloth triangle mass indices.")}
      let a=ClothMath.vector(positionsMm[triangle.a])/1000,b=ClothMath.vector(positionsMm[triangle.b])/1000,c=ClothMath.vector(positionsMm[triangle.c])/1000
      let share=simd_length(simd_cross(b-a,c-a))*0.5*areaDensityKgPerM2/3
      result[triangle.a]+=share;result[triangle.b]+=share;result[triangle.c]+=share
    }
    guard result.allSatisfy({$0.isFinite && $0>0}) else {throw FormError.invalid("Every cloth vertex needs positive incident area or an explicit mass.")};return result
  }
}
public enum ClothMeshes {
  /// Rectangular sheet; UVs remain attached to rest-material coordinates.
  public static func rectangle(widthMm:Double,heightMm:Double,columns:Int,rows:Int,areaDensityKgPerM2:Double,
    originMm:Vector3 = .init(0,150,0),uAxis:Vector3 = .init(1,0,0),vAxis:Vector3 = .init(0,0,1))throws -> ClothMesh {
    guard widthMm.isFinite,heightMm.isFinite,(20...2000).contains(widthMm),(20...2000).contains(heightMm),(1...63).contains(columns),(1...63).contains(rows),
      ClothMath.finite(originMm),ClothMath.maximum(originMm)<=100000,ClothMath.finite(uAxis),ClothMath.finite(vAxis),
      abs(simd_length(ClothMath.vector(uAxis))-1)<1e-8,abs(simd_length(ClothMath.vector(vAxis))-1)<1e-8,abs(simd_dot(ClothMath.vector(uAxis),ClothMath.vector(vAxis)))<1e-8 else {throw FormError.invalid("Use 20–2000 mm panels, 1–63 cells per axis, and orthonormal material axes.")}
    var positions:[Vector3]=[],uv:[Point2]=[],triangles:[ClothTriangle]=[],links:[ClothLink]=[]
    let origin=ClothMath.vector(originMm),u=ClothMath.vector(uAxis),v=ClothMath.vector(vAxis)
    func index(_ x:Int,_ y:Int)->Int {y*(columns+1)+x}
    for y in 0...rows {for x in 0...columns {
      let s=Double(x)/Double(columns),t=Double(y)/Double(rows)
      positions.append(ClothMath.point(origin+u*((s-0.5)*widthMm)+v*((t-0.5)*heightMm)));uv.append(.init(s,t))
      if x>0 {links.append(.init(index(x-1,y),index(x,y),kind:.warp))}
      if y>0 {links.append(.init(index(x,y-1),index(x,y),kind:.weft))}
      if x>0,y>0 {links.append(.init(index(x-1,y-1),index(x,y),kind:.shear));links.append(.init(index(x,y-1),index(x-1,y),kind:.shear))}
      if x>1 {links.append(.init(index(x-2,y),index(x,y),kind:.bendDistance))}
      if y>1 {links.append(.init(index(x,y-2),index(x,y),kind:.bendDistance))}
    }}
    for y in 0..<rows {for x in 0..<columns {
      let a=index(x,y),b=index(x+1,y),c=index(x,y+1),d=index(x+1,y+1)
      if (x+y)%2==0 {triangles += [.init(a,c,b),.init(b,c,d)]} else {triangles += [.init(a,c,d),.init(a,d,b)]}
    }}
    let masses=try ClothMesh.masses(positionsMm:positions,triangles:triangles,areaDensityKgPerM2:areaDensityKgPerM2)
    var result=ClothMesh(restPositionsMm:positions,massesKg:masses,triangles:triangles,uv:uv,links:links);result.panelIDs=[Int](repeating:0,count:positions.count);try result.validate();return result
  }
  /// Two separate panels joined by explicit point-distance seams. This is a
  /// prototype, without self-collision, sewing allowances or calibrated fitting.
  public static func seamedPanels(widthMm:Double,heightMm:Double,columns:Int,rows:Int,areaDensityKgPerM2:Double)throws -> ClothMesh {
    guard columns>=2,rows>=2 else {throw FormError.invalid("Seamed panels need at least two cells per axis for distinct open-top handle pins.")}
    var front=try rectangle(widthMm:widthMm,heightMm:heightMm,columns:columns,rows:rows,areaDensityKgPerM2:areaDensityKgPerM2,originMm:.init(0,heightMm*0.65,30),vAxis:.init(0,-1,0))
    let back=try rectangle(widthMm:widthMm,heightMm:heightMm,columns:columns,rows:rows,areaDensityKgPerM2:areaDensityKgPerM2,originMm:.init(0,heightMm*0.65,-30),vAxis:.init(0,-1,0)),offset=front.restPositionsMm.count
    front.panelIDs=[Int](repeating:0,count:offset)+[Int](repeating:1,count:offset)
    front.restPositionsMm += back.restPositionsMm;front.massesKg += back.massesKg;front.uv += back.uv.map {.init(1-$0.x,$0.y)}
    front.triangles += back.triangles.map {.init($0.a+offset,$0.c+offset,$0.b+offset)}
    front.links += back.links.map {.init($0.a+offset,$0.b+offset,kind:$0.kind,restLengthMm:$0.restLengthMm)}
    for row in 0...rows {for col in 0...columns where row==rows || col==0 || col==columns {
      let vertex=row*(columns+1)+col;front.links.append(.init(vertex,vertex+offset,kind:.seam,restLengthMm:0))
    }}
    let middle=columns/2
    front.pins=[.init(middle,targetMm:front.restPositionsMm[middle]),.init(offset+middle,targetMm:front.restPositionsMm[offset+middle])]
    try front.validate();return front
  }
}
enum ClothMath {
  static func vector(_ p:Vector3)->SIMD3<Double> {.init(p.x,p.y,p.z)}
  static func point(_ p:SIMD3<Double>)->Vector3 {.init(p.x,p.y,p.z)}
  static func finite(_ p:Vector3)->Bool {p.x.isFinite && p.y.isFinite && p.z.isFinite}
  static func maximum(_ p:Vector3)->Double {max(abs(p.x),abs(p.y),abs(p.z))}
  static func finite(_ p:SIMD3<Double>)->Bool {p.x.isFinite && p.y.isFinite && p.z.isFinite}
}

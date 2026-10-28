import Foundation

public struct CADSurfacePoint2: Codable, Equatable, Sendable {
  public var x: Double, y: Double
  public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// An authored physical artwork frame on exactly one planar output face.
/// Origin and axes define readable artwork coordinates in model millimeters.
public struct CADPlanarSurface: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var outputFeatureID: UUID
  public var selection: CADTopologySelection
  public var origin: CADExpressionPoint
  public var uAxis: CADModelVector
  public var vAxis: CADModelVector
  public var width: CADScalar
  public var height: CADScalar
  public var boundary: [CADExpressionPoint2]?

  public init(id: String, name: String, outputFeatureID: UUID, selection: CADTopologySelection,
              origin: CADExpressionPoint, uAxis: CADModelVector, vAxis: CADModelVector,
              width: CADScalar, height: CADScalar, boundary: [CADExpressionPoint2]? = nil) {
    self.id = id; self.name = name; self.outputFeatureID = outputFeatureID
    self.selection = selection; self.origin = origin; self.uAxis = uAxis; self.vAxis = vAxis
    self.width = width; self.height = height; self.boundary = boundary
  }

  public func resolved(using values: [String: Double]) throws -> CADResolvedPlanarSurface {
    guard !id.isEmpty, id.utf8.count <= 128, !name.isEmpty, name.utf8.count <= 256 else {
      throw CADModelError("Planar surfaces require bounded stable identities and names.")
    }
    switch selection {
    case .allEdges, .edges, .straightEdgesAtMaximum, .straightEdgesAtMinimum:
      throw CADModelError("A planar artwork surface must select a face.")
    case .facesAtExtrema:
      throw CADModelError("A planar artwork surface requires one face, not both extrema.")
    case .faceAtMaximum(let axis), .faceAtMinimum(let axis):
      guard ["x","y","z"].contains(axis) else{throw CADModelError("A planar face selector needs an x, y or z axis.")}
    case let .faceAtCenter(point,tolerance):
      guard tolerance.isFinite,tolerance>0,tolerance<=1 else{throw CADModelError("Face datum tolerance must be finite, positive and at most 1 mm.")}
      for scalar in [point.x,point.y,point.z]{_ = try CADExpression.evaluate(scalar.expression,variables:values)}
    case let .faces(hash,indices):
      guard hash.utf8.count==64,hash.utf8.allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}),indices.count==1,indices[0]>0 else {
        throw CADModelError("A pinned artwork surface needs one positive face index and its feature fingerprint.")
      }
    }
    func dot(_ a: CADModelVector, _ b: CADModelVector) -> Double { a.x*b.x+a.y*b.y+a.z*b.z }
    guard [uAxis.x,uAxis.y,uAxis.z,vAxis.x,vAxis.y,vAxis.z].allSatisfy(\.isFinite),
          abs(dot(uAxis,uAxis)-1) < 1e-10, abs(dot(vAxis,vAxis)-1) < 1e-10,
          abs(dot(uAxis,vAxis)) < 1e-10 else {
      throw CADModelError("Planar artwork frame axes must be finite, orthogonal unit vectors.")
    }
    func number(_ scalar: CADScalar) throws -> Double { try CADExpression.evaluate(scalar.expression, variables: values) }
    let w = try number(width), h = try number(height)
    guard w > 0, h > 0 else { throw CADModelError("Planar artwork width and height must be positive millimeters.") }
    let points = try boundary?.map { CADSurfacePoint2(try number($0.x),try number($0.y)) }
      ?? [.init(0,0),.init(w,0),.init(w,h),.init(0,h)]
    guard (3...128).contains(points.count), points.allSatisfy({$0.x >= -1e-7 && $0.y >= -1e-7 && $0.x <= w+1e-7 && $0.y <= h+1e-7}) else {
      throw CADModelError("A planar surface boundary needs 3–128 points inside its physical frame.")
    }
    try CADSurfaceBoundary.validate(points)
    return .init(id:id,name:name,outputFeatureID:outputFeatureID,faceIndex:0,fingerprint:"",
      origin:.init(try number(origin.x),try number(origin.y),try number(origin.z)),
      uAxis:uAxis,vAxis:vAxis,width:w,height:h,boundary:points)
  }
}

private enum CADSurfaceBoundary {
  static func validate(_ points:[CADSurfacePoint2]) throws {
    func cross(_ a:CADSurfacePoint2,_ b:CADSurfacePoint2,_ c:CADSurfacePoint2)->Double{(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)}
    let area=points.indices.reduce(0.0){sum,i in let a=points[i],b=points[(i+1)%points.count];return sum+a.x*b.y-b.x*a.y}/2
    guard abs(area)>1e-8 else{throw CADModelError("A planar surface boundary needs positive physical area.")}
    for i in points.indices {
      let a=points[i],b=points[(i+1)%points.count]
      guard hypot(a.x-b.x,a.y-b.y)>1e-7 else{throw CADModelError("A planar surface boundary contains a repeated point or zero-length edge.")}
      for j in points.indices where j>i && j != (i+1)%points.count && i != (j+1)%points.count {
        let c=points[j],d=points[(j+1)%points.count]
        if min(a.x,b.x)<=max(c.x,d.x)+1e-10 && min(c.x,d.x)<=max(a.x,b.x)+1e-10 &&
           min(a.y,b.y)<=max(c.y,d.y)+1e-10 && min(c.y,d.y)<=max(a.y,b.y)+1e-10 &&
           cross(a,b,c)*cross(a,b,d)<=1e-10 && cross(c,d,a)*cross(c,d,b)<=1e-10 {
          throw CADModelError("A planar surface boundary cannot cross or touch itself.")
        }
      }
    }
  }
}

/// Persisted renderer-neutral result. A face index is meaningful only together
/// with the producing feature fingerprint retained here.
public struct CADResolvedPlanarSurface: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var outputFeatureID: UUID
  public var faceIndex: UInt32
  public var fingerprint: String
  public var origin: CADModelVector
  public var uAxis: CADModelVector
  public var vAxis: CADModelVector
  public var width: Double
  public var height: Double
  public var boundary: [CADSurfacePoint2]
  public init(id:String,name:String,outputFeatureID:UUID,faceIndex:UInt32,fingerprint:String,
              origin:CADModelVector,uAxis:CADModelVector,vAxis:CADModelVector,
              width:Double,height:Double,boundary:[CADSurfacePoint2]) {
    self.id=id;self.name=name;self.outputFeatureID=outputFeatureID;self.faceIndex=faceIndex;self.fingerprint=fingerprint
    self.origin=origin;self.uAxis=uAxis;self.vAxis=vAxis;self.width=width;self.height=height;self.boundary=boundary
  }
  public func validate() throws {
    let source=CADPlanarSurface(id:id,name:name,outputFeatureID:outputFeatureID,
      selection:.faces(revisionHash:fingerprint,indices:[faceIndex]),
      origin:.init(CADScalar(origin.x),CADScalar(origin.y),CADScalar(origin.z)),uAxis:uAxis,vAxis:vAxis,
      width:CADScalar(width),height:CADScalar(height),
      boundary:boundary.map{.init(CADScalar($0.x),CADScalar($0.y))})
    _ = try source.resolved(using:[:])
  }
}

public struct CADSurfaceResolutionIssue: Codable, Equatable, Identifiable, Sendable {
  public var surfaceID: String
  public var outputFeatureID: UUID
  public var code: String
  public var message: String
  public var id: String { surfaceID }
  public init(surfaceID:String,outputFeatureID:UUID,code:String,message:String) {
    self.surfaceID=surfaceID;self.outputFeatureID=outputFeatureID;self.code=code;self.message=message
  }
}

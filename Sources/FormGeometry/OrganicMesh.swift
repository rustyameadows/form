import CFormMesher
import Foundation
import simd

/// A per-request probe shared by Swift workers and the mesher's dispatch slices.
/// It owns no task, document, native view or global cancellation state.
public final class OrganicMeshCancellation: @unchecked Sendable {
  private let lock=NSLock()
  private var cancelled=false
  public init() {}
  public func cancel() {lock.lock();cancelled=true;lock.unlock()}
  public var isCancelled:Bool {lock.lock();defer{lock.unlock()};return cancelled}
}

/// Bounded, deterministic solid union. Millimeter input/output. Indexed vertices
/// are shared across tetrahedra, including diagonal grid edges and the flat sole.
public struct OrganicSolid {
  private var shapes:[FMOrganicShape]=[]
  public init(){}
  public mutating func segment(_ a:SIMD3<Double>,_ b:SIMD3<Double>,_ startRadius:Double,_ endRadius:Double,aspect:Double=1,endAspect:Double=1,roll:Double=0,blend:Double=0) {
    let delta=b-a,length=simd_length(delta);guard length>1e-8 else{return};let w=delta/length
    let helper=abs(w.y)<0.95 ? SIMD3<Double>(0,1,0):SIMD3<Double>(1,0,0),initial=simd_normalize(simd_cross(helper,w)),other=simd_cross(w,initial),u=initial*cos(roll)+other*sin(roll),v=simd_cross(w,u)
    shapes.append(.init(cx:a.x,cy:a.y,cz:a.z,ux:u.x,uy:u.y,uz:u.z,vx:v.x,vy:v.y,vz:v.z,wx:w.x,wy:w.y,wz:w.z,rx:startRadius,ry:endRadius,rz:aspect,length:length,blend:blend,end_aspect:endAspect,kind:1))
  }
  public mutating func ellipsoid(_ center:SIMD3<Double>,radii:SIMD3<Double>,axis:SIMD3<Double> = .init(0,1,0),roll:Double=0,blend:Double=0) {
    let w=simd_normalize(axis),helper=abs(w.y)<0.95 ? SIMD3<Double>(0,1,0):SIMD3<Double>(1,0,0)
    let initial=simd_normalize(simd_cross(helper,w)),other=simd_cross(w,initial),u=initial*cos(roll)+other*sin(roll),v=simd_cross(w,u)
    shapes.append(.init(cx:center.x,cy:center.y,cz:center.z,ux:u.x,uy:u.y,uz:u.z,vx:v.x,vy:v.y,vz:v.z,wx:w.x,wy:w.y,wz:w.z,rx:radii.x,ry:radii.y,rz:radii.z,length:0,blend:blend,end_aspect:1,kind:0))
  }
  public var shapeCount:Int {shapes.count}
  public func mesh(spacing:Double,floorY:Double?=nil,fillVoids:Bool=false,cancellation:OrganicMeshCancellation?=nil)throws->(positions:[SIMD3<Double>],indices:[UInt32]) {
    try Task.checkCancellation()
    if cancellation?.isCancelled==true {throw CancellationError()}
    var result=FMOrganicMesh()
    let code=withExtendedLifetime(cancellation) {
      shapes.withUnsafeBufferPointer { values in
        if let cancellation {
          return fm_organic_mesh_cancellable(values.baseAddress,values.count,spacing,floorY == nil ? 0:1,floorY ?? 0,fillVoids ? 1:0,
            {raw in guard let raw else{return 0};return Unmanaged<OrganicMeshCancellation>.fromOpaque(raw).takeUnretainedValue().isCancelled ? 1:0},
            Unmanaged.passUnretained(cancellation).toOpaque(),&result)
        }
        return fm_organic_mesh(values.baseAddress,values.count,spacing,floorY == nil ? 0:1,floorY ?? 0,fillVoids ? 1:0,&result)
      }
    }
    defer{fm_free_organic_mesh(&result)}
    if code == -4 || cancellation?.isCancelled==true {throw CancellationError()}
    try Task.checkCancellation()
    guard code==0,let p=result.xyz,let i=result.indices else {throw NSError(domain:"LAB.OrganicSolid",code:Int(code),userInfo:[NSLocalizedDescriptionKey:"The bounded organic mesh could not be constructed (\(code))."])}
    return ((0..<result.vertex_count).map{.init(p[$0*3],p[$0*3+1],p[$0*3+2])},Array(UnsafeBufferPointer(start:i,count:result.index_count)))
  }
}

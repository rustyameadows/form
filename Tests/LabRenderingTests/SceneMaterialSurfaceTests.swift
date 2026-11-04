import Foundation
import XCTest
import LabRendering
import simd

private func surface(columns:Int=8,rows:Int=4,bent:Bool=false,limits:SceneMaterialSurface.Limits = .init())throws->SceneMaterialSurface {
  var uv=[SIMD2<Double>](),p=[SIMD3<Double>](),n=[SIMD3<Double>](),tri=[SIMD3<UInt32>]()
  let angle=20.0*Double.pi/180,c=cos(angle),s=sin(angle)
  for row in 0...rows {for col in 0...columns {
    let x = -80+160*Double(col)/Double(columns),z = -60+120*Double(row)/Double(rows)
    uv.append(.init(x*c+z*s,-x*s+z*c))
    p.append(bent ? .init(80*sin(x/80),80*(1-cos(x/80)),z):.init(x,0,z))
    n.append(bent ? .init(-sin(x/80),cos(x/80),0):.init(0,1,0))
    if row<rows,col<columns {let a=UInt32(row*(columns+1)+col),b=a+1,d=a+UInt32(columns+1),e=d+1;tri += [.init(a,d,b),.init(b,d,e)]}
  }}
  return try .init(revision:"surface",coordinatesMM:uv,positionsMM:p,normals:n,triangles:tri,normalOffsetMM:0.45,limits:limits)
}
private func box()->SceneMeshPayload {
  let x=40.0,z=30.0,h=0.25
  let faces:[[SIMD3<Double>]]=[
    [.init(-x,h,-z),.init(-x,h,z),.init(x,h,z),.init(x,h,-z)],
    [.init(-x,-h,-z),.init(x,-h,-z),.init(x,-h,z),.init(-x,-h,z)],
    [.init(-x,-h,-z),.init(-x,-h,z),.init(-x,h,z),.init(-x,h,-z)],
    [.init(x,-h,-z),.init(x,h,-z),.init(x,h,z),.init(x,-h,z)],
    [.init(-x,-h,-z),.init(-x,h,-z),.init(x,h,-z),.init(x,-h,-z)],
    [.init(-x,-h,z),.init(x,-h,z),.init(x,h,z),.init(-x,h,z)]]
  var mesh=SceneMeshPayload(id:"closed",revision:"1",positionsMM:[],parts:[])
  for (i,face) in faces.enumerated() {
    let base=UInt32(mesh.positionsMM.count),normal=SIMD3<Float>(simd_normalize(simd_cross(face[1]-face[0],face[2]-face[0])))
    mesh.positionsMM+=face;mesh.normals+=Array(repeating:normal,count:4)
    mesh.uvs += [.init(0,0),.init(0,1),.init(1,1),.init(1,0)]
    mesh.uvs1 += [.init(0.2,0.3),.init(0.2,0.8),.init(0.7,0.8),.init(0.7,0.3)]
    mesh.parts.append(.init(materialIndex:min(i,2),triangleIndices:[base,base+1,base+2,base,base+2,base+3],semanticID:"face\(i)"))
  }
  return mesh
}
private func point(_ keys:[SIMD3<Double>],_ t:Double)->SIMD3<Double> {
  let x=min(1,max(0,t))*Double(keys.count-1),i=min(keys.count-2,Int(x)),u=x-Double(i)
  let a=keys[max(0,i-1)],b=keys[i],c=keys[i+1],d=keys[min(keys.count-1,i+2)]
  return b+(c-a)*(u/2)+(a*2-b*5+c*4-d)*(u*u/2)+(-a+b*3-c*3+d)*(u*u*u/2)
}
final class SceneMaterialSurfaceTests:XCTestCase {
  private func area(_ mesh:SceneMeshPayload)->Double {
    mesh.parts.reduce(0){sum,part in sum+stride(from:0,to:part.triangleIndices.count,by:3).reduce(0){value,i in
      let a=mesh.positionsMM[Int(part.triangleIndices[i])],b=mesh.positionsMM[Int(part.triangleIndices[i+1])],c=mesh.positionsMM[Int(part.triangleIndices[i+2])]
      return value+simd_length(simd_cross(b-a,c-a))/2
    }}
  }
  private func hitDistance(_ origin:SIMD3<Double>,_ normal:SIMD3<Double>,mesh:SceneMeshPayload,part:Int)throws->Double {
    var closest=Double.infinity;let indices=mesh.parts[part].triangleIndices,direction = -normal
    for i in stride(from:0,to:indices.count,by:3) {
      let a=mesh.positionsMM[Int(indices[i])],b=mesh.positionsMM[Int(indices[i+1])],c=mesh.positionsMM[Int(indices[i+2])],ab=b-a,ac=c-a,p=simd_cross(direction,ac),det=simd_dot(ab,p)
      if abs(det)<1e-12 {continue}
      let delta=origin-a,u=simd_dot(delta,p)/det,q=simd_cross(delta,ab),v=simd_dot(direction,q)/det,t=simd_dot(ac,q)/det
      if u>=(-1e-8),v>=(-1e-8),u+v<=1+1e-8,t>=0 {closest=min(closest,t)}
    }
    return try XCTUnwrap(closest.isFinite ? closest:nil,"The needle ray must meet the actual tessellated backing.")
  }
  func testFlatClippingRetainsVerticalSidesCaliperMaterialsAndUVsWithoutWelding()throws {
    let mapping=try surface(),source=box(),result=try mapping.deform(source)
    XCTAssertEqual(result.parts.map(\.materialIndex),source.parts.map(\.materialIndex))
    XCTAssertEqual(result.parts.map(\.semanticID),source.parts.map(\.semanticID))
    XCTAssertTrue(result.parts.allSatisfy{!$0.triangleIndices.isEmpty},"Zero projected-area side faces retain their nonzero physical area.")
    XCTAssertEqual(area(result),area(source),accuracy:1e-7)
    XCTAssertEqual(result.positionsMM.map(\.y).min()!,0.2,accuracy:1e-10);XCTAssertEqual(result.positionsMM.map(\.y).max()!,0.7,accuracy:1e-10)
    for i in result.positionsMM.indices {
      XCTAssertEqual(result.uvs1[i].x,result.uvs[i].x*0.5+0.2,accuracy:1e-6)
      XCTAssertEqual(result.uvs1[i].y,result.uvs[i].y*0.5+0.3,accuracy:1e-6)
      XCTAssertEqual(simd_length(result.normals[i]),1,accuracy:1e-6)
    }
    func key(_ p:SIMD3<Double>)->String {[p.x,p.y,p.z].map{String(Int64(($0*1e7).rounded()))}.joined(separator:",")}
    var edges=[String:Int]()
    for part in result.parts {let ids=part.triangleIndices
      for i in stride(from:0,to:ids.count,by:3) {for edge in 0..<3 {
        let a=key(result.positionsMM[Int(ids[i+edge])]),b=key(result.positionsMM[Int(ids[i+(edge+1)%3])])
        edges[[a,b].sorted().joined(separator:"|") ,default:0]+=1
      }}
    }
    XCTAssertTrue(edges.values.allSatisfy{$0==2},"Clipping/refinement must not introduce an open edge or a T-junction in a closed backing.")
    XCTAssertEqual(source.positionsMM,box().positionsMM)
  }
  func testCurvedMappingCertifiesNativeInterpolationAndContactWithActualBacking()throws {
    let mapping=try surface(columns:64,rows:32,bent:true),backing=try mapping.deform(box())
    let heights=[0.0,0.10725,0.143,0.10725,0.0],source=(0..<5).map{SIMD3<Double>(-25+Double($0)*12.5,0.305+heights[$0],0)}
    let mapped=try mapping.deformCurve(source)
    XCTAssertGreaterThan(mapped.count,source.count);XCTAssertLessThanOrEqual(mapped.count,mapping.limits.maximumKeysPerCurve)
    var maximumError=0.0
    for i in 0...2048 {let t=Double(i)/2048;maximumError=max(maximumError,simd_distance(try mapping.position(point(source,t)),point(mapped,t)))}
    XCTAssertLessThanOrEqual(maximumError,mapping.limits.toleranceMM+1e-9)
    for t in [0.0,0.5,1.0] {
      let local=point(source,t),base=try mapping.position(local),normal=simd_normalize(try mapping.position(local+SIMD3(0,1,0))-base)
      let distance=try hitDistance(point(mapped,t),normal,mesh:backing,part:0)
      if t==0.5 {XCTAssertGreaterThan(distance-0.11,0)}
      else {XCTAssertEqual(distance,0.055,accuracy:mapping.limits.toleranceMM*2);XCTAssertLessThan(distance-0.11,0)}
    }
    XCTAssertLessThan(backing.triangleCount,10_000,"Refinement follows parent cells rather than indiscriminately subdividing the complete sheet.")
  }
  func testDenseShortCurvesShareTheUnchangedWorkBudgetWithoutDroppingSourceKeys()throws {
    let mapping=try surface(columns:64,rows:32,bent:true)
    var budget=mapping.makeBudget(),sourceKeys=0,outputKeys=0
    _=try mapping.deform(box(),budget:&budget)
    // Many original keys within each short strand occur after local contact
    // clearance. They must not each trigger every neighboring edge's root search.
    for strand in 0..<1200 {
      let x = -35+Double(strand%25)*2.8,z = -24+Double(strand/25)*0.9
      let source=(0..<29).map {key in
        let t=Double(key)/28
        return SIMD3<Double>(x+2*t,0.305+0.15*sin(t*Double.pi),z)
      }
      let mapped=try mapping.deformCurve(source,budget:&budget)
      sourceKeys+=source.count;outputKeys+=mapped.count
      let subdivisions=(mapped.count-1)/(source.count-1)
      XCTAssertGreaterThanOrEqual(subdivisions,1)
      for key in source.indices {
        XCTAssertLessThan(simd_distance(mapped[key*subdivisions],try mapping.position(source[key])),1e-10)
      }
      if strand.isMultiple(of:113) {
        for i in 0...64 {
          let t=Double(i)/64
          XCTAssertLessThanOrEqual(simd_distance(point(mapped,t),try mapping.position(point(source,t))),mapping.limits.toleranceMM+1e-9)
        }
      }
    }
    XCTAssertEqual(sourceKeys,34_800)
    XCTAssertGreaterThanOrEqual(outputKeys,sourceKeys)
    XCTAssertEqual(mapping.limits.maximumWork,16_000_000)
    XCTAssertLessThan(budget.work,mapping.limits.maximumWork/2,"The complete dense source and backing must fit with headroom; do not increase the cap or simplify source strands.")
  }
  func testNarrowMaterialHoleCannotBeBridgedBetweenCurveKeysOrByBacking()throws {
    let x=[-10.0,1,1.02,10],z=[-2.0,2],uv=z.flatMap{z in x.map{SIMD2($0,z)}}
    let p=uv.map{SIMD3($0.x,0,$0.y)},n=Array(repeating:SIMD3<Double>(0,1,0),count:8)
    let mapping=try SceneMaterialSurface(revision:"hole",coordinatesMM:uv,positionsMM:p,normals:n,triangles:[.init(0,4,1),.init(1,4,5),.init(2,6,3),.init(3,6,7)],normalOffsetMM:0)
    let curve=(0..<5).map{SIMD3<Double>(-5+Double($0)*2.5,0.1,0)}
    XCTAssertThrowsError(try mapping.deformCurve(curve)) {XCTAssertTrue($0.localizedDescription.contains("hole"))}
    let mesh=SceneMeshPayload(id:"spanning",revision:"1",positionsMM:[.init(-5,0,-1),.init(-5,0,1),.init(5,0,0)],parts:[.init(triangleIndices:[0,1,2])])
    XCTAssertThrowsError(try mapping.deform(mesh)) {XCTAssertTrue($0.localizedDescription.contains("hole"))}
  }
  func testOverlappingAndDiscontinuousMaterialChartsRejectExplicitly()throws {
    let uv:[SIMD2<Double>]=[.init(0,0),.init(1,0),.init(0,1)],p=uv.map{SIMD3($0.x,0,$0.y)},n=Array(repeating:SIMD3<Double>(0,1,0),count:3)
    XCTAssertThrowsError(try SceneMaterialSurface(revision:"overlap",coordinatesMM:uv+uv,positionsMM:p+p,normals:n+n,triangles:[.init(0,2,1),.init(3,5,4)],normalOffsetMM:0)) {XCTAssertTrue($0.localizedDescription.contains("overlapping"))}
    let other:[SIMD2<Double>]=[.init(1,0),.init(1,1),.init(0,1)],shifted=other.map{SIMD3($0.x,2,$0.y)}
    XCTAssertThrowsError(try SceneMaterialSurface(revision:"slit",coordinatesMM:uv+other,positionsMM:p+shifted,normals:n+n,triangles:[.init(0,2,1),.init(3,5,4)],normalOffsetMM:0)) {XCTAssertTrue($0.localizedDescription.contains("discontinuous"))}
  }
  func testInteriorOffsetInversionRejectsEvenWhenAllVertexDeterminantsArePositive()throws {
    let c=sqrt(1-0.01*0.01),h=(1+c)/2
    let mapping=try SceneMaterialSurface(revision:"fold",coordinatesMM:[.init(-0.01,-0.01),.init(0.01,-0.01),.init(0.01,0.01)],positionsMM:[.init(-0.01,0,-0.01),.init(0.01,0,-0.01),.init(0.01,0,0.01)],normals:[.init(0.01,c,0),.init(-0.01,c,0),.init(-0.01,c,0)],triangles:[.init(0,2,1)],normalOffsetMM:h)
    let source=SceneMeshPayload(id:"plane",revision:"1",positionsMM:[.init(-0.01,0,-0.01),.init(0.01,0,0.01),.init(0.01,0,-0.01)],parts:[.init(triangleIndices:[0,1,2])])
    XCTAssertThrowsError(try mapping.deform(source)) {XCTAssertTrue($0.localizedDescription.contains("folds through"))}
  }
  func testAggregateGeometryCurveKeyAndCancellationBudgetsFailWithoutCoarseFallback()async throws {
    let baseline=try surface().deform(box()).triangleCount
    var limits=SceneMaterialSurface.Limits();limits.maximumTriangles=baseline*2-1
    let mapping=try surface(limits:limits);var budget=mapping.makeBudget()
    _=try mapping.deform(box(),budget:&budget)
    XCTAssertThrowsError(try mapping.deform(box(),budget:&budget)) {XCTAssertTrue($0.localizedDescription.contains("budget"))}
    limits = .init();limits.maximumKeysPerCurve=5
    let bent=try surface(columns:64,rows:32,bent:true,limits:limits),curve=(0..<5).map{SIMD3<Double>(-25+Double($0)*12.5,0.5,0)}
    XCTAssertThrowsError(try bent.deformCurve(curve)) {XCTAssertTrue($0.localizedDescription.contains("key budget"))}
    let task=Task.detached {try mapping.deform(box())};task.cancel()
    do {_=try await task.value;XCTFail("Cancelled preparation must not publish a derived mesh.")}catch {XCTAssertTrue(error is CancellationError)}
  }
}

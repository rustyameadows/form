import Foundation
import XCTest
@testable import FormCore

final class AssemblyMesherTests:XCTestCase {
  func testConcavePanelPreservesActualHoleAreaAndConformingBoundary()throws {
    let outer:[Point2]=[.init(0,0),.init(120,0),.init(120,40),.init(60,40),.init(60,100),.init(0,100)],hole:[Point2]=[.init(15,15),.init(45,15),.init(45,35),.init(15,35)]
    let mesh=try AssemblyMesher.mesh(contours:[outer,hole],maximumEdgeMm:14)
    XCTAssertEqual(mesh.areaMm2,7800,accuracy:1e-6);XCTAssertEqual(mesh.boundaries.count,2)
    XCTAssertLessThanOrEqual(mesh.maximumEdgeMm,14+1e-8);XCTAssertGreaterThan(mesh.minimumTriangleAreaMm2,0)
    for triangle in mesh.triangles {
      let a=mesh.points[triangle.a],b=mesh.points[triangle.b],c=mesh.points[triangle.c],x=(a.x+b.x+c.x)/3,y=(a.y+b.y+c.y)/3
      XCTAssertFalse(x>15 && x<45 && y>15 && y<35);XCTAssertFalse(x>60 && y>40)
    }
    let degrees=mesh.triangles.flatMap{[Edge($0.a,$0.b),Edge($0.b,$0.c),Edge($0.c,$0.a)]}.reduce(into:[Edge:Int]()) {$0[$1,default:0]+=1}
    let boundary=Set(mesh.boundaries.flatMap{ring in ring.indices.map{Edge(ring[$0],ring[($0+1)%ring.count])}})
    XCTAssertEqual(Set(degrees.filter{$0.value==1}.map(\.key)),boundary);XCTAssertTrue(degrees.values.allSatisfy{$0==1 || $0==2})
  }
  func testCollinearSeamSamplesAreRecoveredAsActualMassCarryingVertices()throws {
    let points:[Point2]=[.init(0,0),.init(20,0),.init(40,0),.init(100,0),.init(100,40),.init(0,40)]
    let mesh=try AssemblyMesher.mesh(contours:[points],maximumEdgeMm:100)
    XCTAssertEqual(Set(mesh.triangles.flatMap{[$0.a,$0.b,$0.c]}),Set(mesh.points.indices))
    XCTAssertEqual(Array(mesh.points.prefix(points.count)),points);XCTAssertEqual(mesh.areaMm2,4000,accuracy:1e-8)
    let mass=try ClothMesh.masses(positionsMm:mesh.points.map{.init($0.x,$0.y,0)},triangles:mesh.triangles,areaDensityKgPerM2:0.2)
    XCTAssertTrue(mass.allSatisfy{$0>0});XCTAssertEqual(mass.reduce(0,+),0.0008,accuracy:1e-14)
  }
  func testRoundedPouchMeshUsesSourceCurvesAndIndependentCurveAreaIntegral()throws {
    let source=try SewingPatternTemplates.roundedPouch(),art=source.artwork,panel=art.elements[0],geometry=try SewingPatterns.geometry(panel,in:art)
    let mesh=try AssemblyMesher.mesh(contours:geometry.allStitchContours,maximumEdgeMm:16)
    let contour=panel.path!.contours[0],expected=abs(curveArea(contour)),perimeter=geometry.edgeLengths.reduce(0,+)
    XCTAssertLessThan(abs(mesh.areaMm2-expected),perimeter*SewingCurveLimits.contourToleranceMM)
    XCTAssertLessThan(mesh.areaMm2,panel.width*panel.height-500)
    XCTAssertGreaterThan(mesh.points.count,50);XCTAssertLessThanOrEqual(mesh.maximumEdgeMm,16+1e-8)
    XCTAssertLessThan(mesh.operations,8_000_000)
    if let directory=ProcessInfo.processInfo.environment["FORM_ASSEMBLY_PROOF_DIR"] {
      let root=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
      let data:[String:Any]=["points":try jsonObject(mesh.points),"triangles":try jsonObject(mesh.triangles),"source_curve_area_mm2":expected,"mesh_area_mm2":mesh.areaMm2,"area_difference_mm2":abs(mesh.areaMm2-expected),"boundary_points":geometry.allStitchContours.reduce(0){$0+$1.count},"vertices":mesh.points.count,"faces":mesh.triangles.count,"max_edge_mm":mesh.maximumEdgeMm,"operations":mesh.operations]
      try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("rounded-pouch-mesh.json"))
    }
  }
  func testMesherIsDeterministicAcrossCallsAndPreservesReversedRingInput()throws {
    let points:[Point2]=[.init(0,0),.init(160,0),.init(160,90),.init(60,120),.init(0,90)]
    let a=try AssemblyMesher.mesh(contours:[points],maximumEdgeMm:18),b=try AssemblyMesher.mesh(contours:[points],maximumEdgeMm:18),c=try AssemblyMesher.mesh(contours:[points.reversed()],maximumEdgeMm:18)
    XCTAssertEqual(a,b);XCTAssertEqual(a.areaMm2,c.areaMm2,accuracy:1e-7);XCTAssertLessThanOrEqual(c.maximumEdgeMm,18+1e-8)
  }
  func testInvalidHoleTouchingCrossingAndWorkBudgetsFailExplicitly()throws {
    let square:[Point2]=[.init(0,0),.init(100,0),.init(100,100),.init(0,100)]
    XCTAssertThrowsError(try AssemblyMesher.mesh(contours:[[.init(0,0),.init(100,100),.init(0,100),.init(100,0)]]))
    XCTAssertThrowsError(try AssemblyMesher.mesh(contours:[square,[.init(95,20),.init(105,20),.init(105,40),.init(95,40)]]))
    XCTAssertThrowsError(try AssemblyMesher.mesh(contours:[square,[.init(0,20),.init(20,20),.init(20,40),.init(0,40)]]))
    XCTAssertThrowsError(try AssemblyMesher.mesh(contours:[square],maximumVertices:3))
    XCTAssertThrowsError(try AssemblyMesher.mesh(contours:[square],maximumEdgeMm:2,maximumVertices:20))
    XCTAssertThrowsError(try AssemblyMesher.mesh(contours:[square],maximumEdgeMm:4,workLimit:1000))
    var invalid=square;invalid[0].x = .nan;XCTAssertThrowsError(try AssemblyMesher.mesh(contours:[invalid]))
    XCTAssertNoThrow(try AssemblyMesher.mesh(contours:[square],maximumEdgeMm:20))
  }
  private struct Edge:Hashable {let a:Int,b:Int;init(_ x:Int,_ y:Int){a=min(x,y);b=max(x,y)}}
  /// Independent exact integral 1/2 ∫(x y' - y x')dt over the original cubic controls.
  private func curveArea(_ contour:VectorContour)->Double {
    func coefficients(_ p0:Double,_ p1:Double,_ p2:Double,_ p3:Double)->[Double] {[p0,3*(p1-p0),3*(p2-2*p1+p0),p3-3*p2+3*p1-p0]}
    var total=0.0
    for i in contour.nodes.indices {
      let a=contour.nodes[i],b=contour.nodes[(i+1)%contour.nodes.count],p=a.outgoing ?? a.anchor,q=b.incoming ?? b.anchor,x=coefficients(a.anchor.x,p.x,q.x,b.anchor.x),y=coefficients(a.anchor.y,p.y,q.y,b.anchor.y)
      for u in 0..<4 {for v in 1..<4 {total+=(x[u]*Double(v)*y[v]-y[u]*Double(v)*x[v])/Double(u+v)}}
    };return total/2
  }
}

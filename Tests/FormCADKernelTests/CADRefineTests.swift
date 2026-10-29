import Foundation
import XCTest
import FormCADKernel

final class CADRefineTests:XCTestCase {
  private func folder()throws->URL {
    let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
    addTeardownBlock{try? FileManager.default.removeItem(at:url)}
    return url
  }

  /// Uniform periodic cubic B-spline control polygons expressed as ordinary
  /// Bezier spans. This exercises authored C2 joins without a special primitive.
  private func ring(count:Int,rx:Double,rz:Double,flutes:Int=0,depth:Double=0,y:Double=0)->[CADCurveSegment] {
    let controls=(0..<count).map {i->CADPoint3 in
      let t=Double(i)*2*Double.pi/Double(count),relief=depth*cos(Double(flutes)*t)
      return .init((rx+relief)*cos(t),y,(rz+relief)*sin(t))
    }
    return (0..<count).map {i in
      let a=controls[(i+count-1)%count],b=controls[i],c=controls[(i+1)%count],d=controls[(i+2)%count]
      return .init(.cubicBezier,start:(a+b*4+c)*(1.0/6),control1:(b*2+c)*(1.0/3),control2:(b+c*2)*(1.0/3),end:(b+c*4+d)*(1.0/6))
    }
  }

  /// Exact polynomial Green integral and independent adaptive Simpson arc
  /// length. Neither uses kernel topology, quadrature or its published report.
  private func areaAndPerimeter(_ curves:[CADCurveSegment])->(Double,Double) {
    var area=0.0,length=0.0
    for c in curves {
      func coefficients(_ a:Double,_ b:Double,_ c:Double,_ d:Double)->[Double]{[a,3*(b-a),3*(c-2*b+a),d-3*c+3*b-a]}
      let x=coefficients(c.start.x,c.control1.x,c.control2.x,c.end.x),z=coefficients(c.start.z,c.control1.z,c.control2.z,c.end.z)
      for i in 0..<4{for j in 1..<4{area += (x[i]*Double(j)*z[j]-z[i]*Double(j)*x[j])/Double(i+j)/2}}
      func speed(_ t:Double)->Double {
        let q=1-t,dx=3*q*q*(c.control1.x-c.start.x)+6*q*t*(c.control2.x-c.control1.x)+3*t*t*(c.end.x-c.control2.x)
        let dz=3*q*q*(c.control1.z-c.start.z)+6*q*t*(c.control2.z-c.control1.z)+3*t*t*(c.end.z-c.control2.z)
        return hypot(dx,dz)
      }
      func integrate(_ a:Double,_ b:Double,_ fa:Double,_ fm:Double,_ fb:Double,_ whole:Double,_ eps:Double,_ remaining:Int)->Double {
        let m=(a+b)/2,l=speed((a+m)/2),r=speed((m+b)/2),left=(m-a)*(fa+4*l+fm)/6,right=(b-m)*(fm+4*r+fb)/6,delta=left+right-whole
        if remaining==0 || abs(delta)<=15*eps{return left+right+delta/15}
        return integrate(a,m,fa,l,fm,left,eps/2,remaining-1)+integrate(m,b,fm,r,fb,right,eps/2,remaining-1)
      }
      let a=speed(0),m=speed(0.5),b=speed(1)
      length += integrate(0,1,a,m,b,(a+4*m+b)/6,1e-11/Double(curves.count),20)
    }
    return (abs(area),length)
  }

  func testRefinePreservesC2ProfileGeometrySourceAndClosedLoft()async throws {
    let kernel=CADKernel(),root=try folder(),curves=ring(count:16,rx:25,rz:15),source=try await kernel.curveProfile(curves)
    let before=root.appendingPathComponent("before.brep"),after=root.appendingPathComponent("after.brep")
    try await kernel.writeBRep(source,to:before)
    let refined=try await kernel.refine(source),expected=areaAndPerimeter(curves)
    XCTAssertEqual(source.info.edges,16);XCTAssertEqual(refined.info.edges,1)
    XCTAssertTrue(refined.info.valid)
    XCTAssertEqual(refined.info.areaMM2,expected.0,accuracy:1e-6)
    XCTAssertEqual(refined.info.size.x,source.info.size.x,accuracy:1e-7)
    XCTAssertEqual(refined.info.size.z,source.info.size.z,accuracy:1e-7)
    let edges=try await kernel.edges(refined)
    XCTAssertEqual(try XCTUnwrap(edges.first).lengthMM,expected.1,accuracy:1e-5)
    let upper=try await kernel.translated(refined,by:.init(0,40,0)),body=try await kernel.loft([refined,upper])
    XCTAssertTrue(body.info.valid && body.info.closed)
    XCTAssertEqual(body.info.volumeMM3,expected.0*40,accuracy:1e-5)
    try await kernel.writeBRep(source,to:after)
    XCTAssertEqual(try Data(contentsOf:before),try Data(contentsOf:after))
    // Refine is explicit; the original curve source retains all authored spans.
    XCTAssertEqual(source.info.edges,16)
  }

  func testCorrugatedAndOrdinaryShellsMatchIndependentParallelCurveFormula()async throws {
    let kernel=CADKernel(),root=try folder()
    let cases=[(96,30.0,30.0,16,0.1,40.0,0.8),(16,25.0,15.0,0,0.0,50.0,2.4)]
    for (index,item) in cases.enumerated() {
      let (count,rx,rz,flutes,depth,height,wall)=item,curves=ring(count:count,rx:rx,rz:rz,flutes:flutes,depth:depth)
      let (area,perimeter)=areaAndPerimeter(curves)
      if index==0{XCTAssertEqual(area,2823.401624433307,accuracy:1e-8);XCTAssertEqual(perimeter,188.45339196859803,accuracy:1e-8)}
      let profile=try await kernel.curveProfile(curves),refined=try await kernel.refine(profile)
      let middle=try await kernel.translated(refined,by:.init(0,height/2,0)),upper=try await kernel.translated(refined,by:.init(0,height,0))
      let body=try await kernel.loft([refined,middle,upper]),faces=try await kernel.faces(body)
      let top=try XCTUnwrap(faces.first{abs($0.minimum.y-height)<1e-6 && abs($0.maximum.y-height)<1e-6})
      let shell=try await kernel.shell(body,removingFaces:[top.index],thickness:wall)
      let inside=area-perimeter*wall+Double.pi*wall*wall
      let expectedVolume=area*height-inside*(height-wall)
      let expectedArea=perimeter*height+(perimeter-2*Double.pi*wall)*(height-wall)+2*area
      XCTAssertTrue(shell.info.valid && shell.info.closed)
      XCTAssertLessThan(shell.info.faces,12)
      // Bounds/physical integrals accompany the topology assertion. Accuracy is
      // below the physical uncertainty of the existing 1e-7 mm trim tolerance.
      XCTAssertEqual(shell.info.size.y,height,accuracy:1e-6)
      XCTAssertEqual(shell.info.volumeMM3,expectedVolume,accuracy:0.001)
      XCTAssertEqual(shell.info.areaMM2,expectedArea,accuracy:0.001)
      let saved=root.appendingPathComponent("shell-\(index).brep")
      try await kernel.writeBRep(shell,to:saved)
      let reopened=try await kernel.readBRep(from:saved)
      XCTAssertEqual(reopened.info.volumeMM3,expectedVolume,accuracy:0.001)
      XCTAssertEqual(reopened.info.areaMM2,expectedArea,accuracy:0.001)
      XCTAssertEqual(reopened.info.maximumToleranceMM,shell.info.maximumToleranceMM,accuracy:1e-12)
      let unchanged=root.appendingPathComponent("shell-\(index)-after.brep")
      _ = try await kernel.tessellate(shell,quality:.preview)
      try await kernel.writeBRep(shell,to:unchanged)
      XCTAssertEqual(try Data(contentsOf:saved),try Data(contentsOf:unchanged))
    }
  }

  func testRefineSolidRetainsMachinedHoleAndInputGeometry()async throws {
    let kernel=CADKernel(),root=try folder(),left=try await kernel.box(width:20,height:10,depth:10)
    let right=try await kernel.translated(left,by:.init(20,0,0)),joined=try await kernel.boolean(.union,left,right)
    let cylinder=try await kernel.cylinder(radius:2,height:20),tool=try await kernel.translated(cylinder,by:.init(10,-5,5))
    let drilled=try await kernel.boolean(.subtract,joined,tool),before=root.appendingPathComponent("drilled-before.brep")
    try await kernel.writeBRep(drilled,to:before)
    let refined=try await kernel.refine(drilled)
    XCTAssertTrue(refined.info.valid && refined.info.closed)
    XCTAssertEqual(refined.info.volumeMM3,4000-40*Double.pi,accuracy:1e-6)
    XCTAssertEqual(refined.info.areaMM2,1800+32*Double.pi,accuracy:1e-6)
    XCTAssertEqual(refined.info.size,.init(40,10,10))
    XCTAssertLessThan(refined.info.faces,drilled.info.faces)
    let after=root.appendingPathComponent("drilled-after.brep")
    try await kernel.writeBRep(drilled,to:after)
    XCTAssertEqual(try Data(contentsOf:before),try Data(contentsOf:after))
  }

  func testOffsetBSplineMassPreservesHolesTrimDomainsAndOrientation()async throws {
    let kernel=CADKernel(),root=try folder(),fixtures=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    // Exact 20×12×5 prism minus a 6×4 through-hole. The offset B-spline
    // supporting surface has internal U/V knots crossed by the hole's trims.
    let source=try await kernel.readBRep(from:fixtures.appendingPathComponent("offset-bspline-holed.brep"))
    XCTAssertTrue(source.info.valid && source.info.closed)
    XCTAssertEqual(source.info.volumeMM3,1080,accuracy:1e-8)
    XCTAssertEqual(source.info.areaMM2,852,accuracy:1e-8)
    XCTAssertEqual(source.info.size.x,20,accuracy:1e-6)
    XCTAssertEqual(source.info.size.y,12,accuracy:1e-6)
    XCTAssertEqual(source.info.size.z,5,accuracy:1e-6)
    let faces=try await kernel.faces(source)
    XCTAssertTrue(faces.contains{$0.surfaceType==9},"The fixture must retain its actual OffsetSurface supporting geometry.")
    let before=root.appendingPathComponent("before.brep"),after=root.appendingPathComponent("after.brep")
    try await kernel.writeBRep(source,to:before)
    let fresh=try await kernel.readBRep(from:before)
    XCTAssertEqual(fresh.info,source.info)
    _ = try await kernel.tessellate(source,quality:.preview)
    try await kernel.writeBRep(source,to:after)
    XCTAssertEqual(try Data(contentsOf:before),try Data(contentsOf:after))
    do {
      _ = try await kernel.readBRep(from:fixtures.appendingPathComponent("offset-bspline-holed-reversed.brep"))
      XCTFail("Signed -1080 mm³ must still reject as an inward-oriented solid.")
    }catch let error as CADKernelError{XCTAssertEqual(error.code,.invalidTopology)}
  }
}

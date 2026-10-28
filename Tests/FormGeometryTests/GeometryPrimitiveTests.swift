import AppKit
import XCTest
@testable import FormGeometry
import simd

final class GeometryPrimitiveTests:XCTestCase {
  private struct Point:Hashable {let x:Int64,y:Int64,z:Int64;init(_ p:MeshVector3){x=Int64((p.x*1e9).rounded());y=Int64((p.y*1e9).rounded());z=Int64((p.z*1e9).rounded())}}
  private struct Edge:Hashable {let a:Int,b:Int;init(_ a:Int,_ b:Int){self.a=min(a,b);self.b=max(a,b)}}
  private func audit(_ geometry:MeshGeometry,file:StaticString=#filePath,line:UInt=#line)->Double {
    let positions=geometry.sources(for:.vertex)[0].vectors;var points:[Point:Int]=[:],remap:[Int]=[],edges:[Edge:Int]=[:];var volume=0.0
    for p in positions {let key=Point(p);if let index=points[key]{remap.append(index)}else{let index=points.count;points[key]=index;remap.append(index)}}
    for element in geometry.elements where element.primitiveType == .triangles {
      let indices=element.indices.map{Int($0)}
      for i in stride(from:0,to:indices.count,by:3) {let a=indices[i],b=indices[i+1],c=indices[i+2];XCTAssertTrue(a<positions.count && b<positions.count && c<positions.count,file:file,line:line);let p=positions[a].simd,q=positions[b].simd,r=positions[c].simd
        XCTAssertGreaterThan(simd_length_squared(simd_cross(q-p,r-p)),1e-28,file:file,line:line);volume += simd_dot(p,simd_cross(q,r))/6
        for (x,y) in [(a,b),(b,c),(c,a)]{edges[.init(remap[x],remap[y]),default:0]+=1}
      }
    }
    let broken=edges.filter{$0.value != 2}
    XCTAssertTrue(!edges.isEmpty && broken.isEmpty,"Every welded edge must have two adjacent faces; \(broken.count) invalid edges, counts \(Dictionary(grouping:broken.values,by:{$0}).mapValues(\.count))",file:file,line:line)
    XCTAssertGreaterThan(volume,0,file:file,line:line)
    let normals=geometry.sources(for:.normal)[0].vectors;XCTAssertEqual(normals.count,positions.count,file:file,line:line);XCTAssertTrue(normals.allSatisfy{abs(simd_length($0.simd)-1)<1e-8},file:file,line:line)
    return volume
  }
  func testAnalyticPrimitiveDisplayMeshesAreClosedOutwardAndPhysicallyBounded() {
    let box=MeshBox(width:1.8,height:1.66,length:0.54,chamferRadius:0.014),cylinder=MeshCylinder(radius:0.5,height:2),sphere=MeshSphere(radius:0.8),cone=MeshCone(topRadius:0,bottomRadius:0.8,height:1.5),torus=MeshTorus(ringRadius:1.2,pipeRadius:0.3)
    for geometry in [box,cylinder,sphere,cone,torus] as [MeshGeometry] {_ = audit(geometry)}
    XCTAssertEqual(box.boundingBox.max.x-box.boundingBox.min.x,1.8,accuracy:1e-10)
    XCTAssertEqual(box.boundingBox.max.y-box.boundingBox.min.y,1.66,accuracy:1e-10)
    XCTAssertEqual(cylinder.boundingBox.max.y-cylinder.boundingBox.min.y,2,accuracy:1e-10)
    XCTAssertEqual(audit(cylinder),Double.pi*0.5,accuracy:0.002)
  }
  func testExtrudedHoleAndRoundedProfileRemainClosedWithoutGPUPreparation() {
    let path=NSBezierPath(roundedRect:.init(x:-0.8,y:-0.6,width:1.6,height:1.2),xRadius:0.15,yRadius:0.15)
    path.windingRule = .evenOdd;path.appendOval(in:.init(x:-0.1,y:-0.1,width:0.2,height:0.2))
    let shape=MeshShape(path:path,extrusionDepth:0.12);shape.chamferRadius=0.006
    _=audit(shape);XCTAssertNil(shape.diagnostic)
    XCTAssertEqual(shape.boundingBox.max.z-shape.boundingBox.min.z,0.12,accuracy:1e-10)
    let positions=shape.sources(for:.vertex)[0].vectors
    XCTAssertTrue(positions.contains{abs($0.z)>0.054 && abs($0.z)<0.06-1e-7},"A real rolled edge must have intermediate section points")
  }
  func testGraphTransformsCloneReuseAndRevisionDoNotMutateSourceGeometry() {
    let parent=MeshNode(),child=MeshNode(geometry:MeshCylinder(radius:0.3,height:1.2));child.position = .init(1,2,3);parent.position = .init(4,0,0);parent.addChildNode(child)
    let before=child.geometry!.sources(for:.vertex)[0].data,revision=child.geometry!.resourceRevision
    let clone=parent.clone();XCTAssertTrue(clone.childNodes[0].geometry === child.geometry)
    XCTAssertEqual(child.convertPosition(.init(),to:nil),.init(5,2,3))
    child.eulerAngles.y = .pi/2
    XCTAssertEqual(child.geometry!.sources(for:.vertex)[0].data,before);XCTAssertEqual(child.geometry!.resourceRevision,revision)
    let local=MeshVector3(0.2,0.3,0.4),world=child.convertPosition(local,to:nil),roundtrip=child.convertPosition(world,from:nil)
    XCTAssertEqual(roundtrip.x,local.x,accuracy:1e-12);XCTAssertEqual(roundtrip.y,local.y,accuracy:1e-12);XCTAssertEqual(roundtrip.z,local.z,accuracy:1e-12)
  }
}

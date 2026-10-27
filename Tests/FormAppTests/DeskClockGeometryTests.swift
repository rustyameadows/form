import XCTest
import FormGeometry
@testable import FormApp
@testable import FormCore

@MainActor final class DeskClockGeometryTests:XCTestCase {
  func testEveryPhysicalComponentIsClosedOrientedAndFitsBedAtRealSize()throws {
    let p=Project(name:"Print geometry"),o=try p.makeObject(recipeID:"deskClock"),assets=FileManager.default.temporaryDirectory
    for component in DeskClockDesign.components {
      var c=PrintConfiguration();c.component=component;c.rotation.x=component=="Foot (print 4)" ? 0:90
      let mesh=try PrintMeshBuilder.mesh(object:o,project:p,assets:assets,configuration:c)
      XCTAssertLessThan(mesh.triangles.count,45000,component)
      var edges:[String:Int]=[:],volume=0.0,nondegenerate=0
      func key(_ p:Vector3)->String {"\(Int((p.x*10000).rounded())),\(Int((p.y*10000).rounded())),\(Int((p.z*10000).rounded()))"}
      let prepared=mesh.centered(on:.init());try prepared.validate(on:.init())
      let bytes=try prepared.binarySTL()
      func exportedVertex(_ offset:Int)->Vector3 {bytes.withUnsafeBytes {b in .init(Double(b.loadUnaligned(fromByteOffset:offset,as:Float.self)),Double(b.loadUnaligned(fromByteOffset:offset+4,as:Float.self)),Double(b.loadUnaligned(fromByteOffset:offset+8,as:Float.self)))}}
      let exported=(0..<mesh.triangles.count).map{i -> MeshTriangle in let offset=84+i*50+12;return .init(exportedVertex(offset),exportedVertex(offset+12),exportedVertex(offset+24))}
      for t in exported {
        let a=t.a,b=t.b,c=t.c,ab=Vector3(b.x-a.x,b.y-a.y,b.z-a.z),ac=Vector3(c.x-a.x,c.y-a.y,c.z-a.z)
        let cross=Vector3(ab.y*ac.z-ab.z*ac.y,ab.z*ac.x-ab.x*ac.z,ab.x*ac.y-ab.y*ac.x)
        if cross.x*cross.x+cross.y*cross.y+cross.z*cross.z<1e-12 {continue};nondegenerate+=1
        for (l,r) in [(a,b),(b,c),(c,a)] {let k=[key(l),key(r)].sorted().joined(separator:"|");edges[k,default:0]+=1}
        volume += (a.x*(b.y*c.z-b.z*c.y)+a.y*(b.z*c.x-b.x*c.z)+a.z*(b.x*c.y-b.y*c.x))/6
      }
      XCTAssertGreaterThan(nondegenerate,10,component);XCTAssertTrue(edges.values.allSatisfy{$0==2},"\(component): \(Dictionary(grouping:edges.values,by:{$0}).mapValues(\.count))");XCTAssertGreaterThan(volume,0,component)
      try mesh.centered(on:.init()).validate(on:.init())
      if component=="Case shell" {XCTAssertGreaterThan(mesh.size.x,175);XCTAssertLessThan(mesh.size.x,181);XCTAssertEqual(mesh.size.z,54,accuracy:0.01)}
    }
    XCTAssertThrowsError(try PrintMeshBuilder.mesh(object:o,project:p,assets:assets,configuration:.init()))
  }
  func testUprightDialMapsPhysicalTopToArtworkTop()throws {
    let p=Project(name:"Upright dial");var o=try p.makeObject(recipeID:"deskClock")
    o.artwork=Artwork(elements:[.init(kind:"text",x:80,y:15,text:"12"),.init(kind:"text",x:85,y:130,text:"6")])
    let node=GeometryFactory.object(o,project:p,assets:FileManager.default.temporaryDirectory)
    let geometry=try XCTUnwrap(node.childNode(withName:"deskClock.Artwork",recursively:true)?.geometry)
    let positions=try XCTUnwrap(geometry.sources(for:.vertex).first),uv=try XCTUnwrap(geometry.sources(for:.texcoord).first)
    func value(_ source:MeshGeometrySource,_ index:Int,_ component:Int)->Double {
      source.data.withUnsafeBytes {bytes in let offset=source.dataOffset+index*source.dataStride+component*source.bytesPerComponent;return source.bytesPerComponent==4 ? Double(bytes.loadUnaligned(fromByteOffset:offset,as:Float.self)):bytes.loadUnaligned(fromByteOffset:offset,as:Double.self)}
    }
    var top=0,bottom=0
    for i in 0..<positions.vectorCount {
      let y=value(positions,i,1),v=value(uv,i,1)
      if y>0.5 {top+=1;XCTAssertLessThan(v,0.5)}
      if y < -0.5 {bottom+=1;XCTAssertGreaterThan(v,0.5)}
    }
    XCTAssertGreaterThan(top,10);XCTAssertGreaterThan(bottom,10)
  }
  func testHandChangesReuseGeometryAndPreserveUprightCase()throws {
    let p=Project(name:"Clock"),o=try p.makeObject(recipeID:"deskClock"),assets=FileManager.default.temporaryDirectory
    let before=GeometryFactory.object(o,project:p,assets:assets);var changed=o;changed.parameters["hour"]=3;changed.parameters["minute"]=30
    XCTAssertEqual(GeometryFactory.geometryParameters(o),GeometryFactory.geometryParameters(changed))
    let after=GeometryFactory.object(changed,project:p,assets:assets)
    XCTAssertEqual(before.childNode(withName:"deskClock.Case shell",recursively:true)?.geometry,after.childNode(withName:"deskClock.Case shell",recursively:true)?.geometry)
    XCTAssertEqual(Double(after.childNode(withName:"deskClock.Minute hand",recursively:true)!.eulerAngles.z),-Double.pi,accuracy:1e-6)
  }
}

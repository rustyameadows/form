import XCTest
import FormGeometry
import FormMeshAssets
import simd
@testable import FormApp
@testable import FormCore

@MainActor final class SolidRecipeGeometryTests:XCTestCase {
  func testFusedRoundedJunctionHasOneClosedOutwardSurface()throws {
    let d=ParametricSolid(spacing:"0.3",floorY:"0",normalizeHeight:"40",nodes:[
      .init(kind:"ellipsoid",values:["x":"0","y":"0","z":"0","radiusX":"12","radiusY":"10","radiusZ":"3"]),
      .init(kind:"segment",values:["x":"0","y":"0","z":"0","endX":"0","endY":"24","endZ":"0","radius":"4","endRadius":"3","blend":"0.5"]),
      .init(kind:"group",count:"4",index:"i",bindings:[.init("angle","i*2*pi/4")],children:[.init(kind:"segment",values:["x":"0","y":"18","z":"0","endX":"cos(angle)*10","endY":"28","endZ":"sin(angle)*10","radius":"2.5","endRadius":"1.2","blend":"0.3"])])
    ])
    let start=Date(),mesh=try SolidRecipeGeometry.surface(d,parameters:[:])
    let report=try MeshTopology.inspect(.init(id:"junction",positionsMM:mesh.positions.map{.init($0.x,$0.y,$0.z)},normals:[],indices:mesh.indices),maximumTriangles:2_000_000)
    XCTAssertTrue(report.isClosedOrientedSurface,"\(report)");XCTAssertGreaterThan(report.signedVolumeMM3,100)
    XCTAssertEqual(mesh.positions.map(\.y).min()!,0,accuracy:1e-10);XCTAssertEqual(mesh.positions.map(\.y).max()!,40,accuracy:1e-10)
    var parent=Array(mesh.positions.indices)
    func find(_ n:Int)->Int{var i=n;while parent[i] != i{parent[i]=parent[parent[i]];i=parent[i]};return i}
    for i in stride(from:0,to:mesh.indices.count,by:3){let a=find(Int(mesh.indices[i]));for j in 1...2{parent[find(Int(mesh.indices[i+j]))]=a}}
    XCTAssertEqual(Set(mesh.indices.map{find(Int($0))}).count,1)
    let repeated=try SolidRecipeGeometry.surface(d,parameters:[:]);XCTAssertEqual(repeated.positions,mesh.positions);XCTAssertEqual(repeated.indices,mesh.indices)
    print("SOLID junction triangles=\(mesh.indices.count/3) seconds=\(Date().timeIntervalSince(start))")
  }
  func testOrientedTrimmedEllipsoidAndPrintUseSamePhysicalSurface()throws {
    let definition=ParametricSolid(spacing:"0.4",floorY:"-2",nodes:[.init(kind:"ellipsoid",values:["x":"0","y":"0","z":"0","radiusX":"10","radiusY":"5","radiusZ":"15","axisX":"1","axisY":"1","axisZ":"0","roll":"pi/4"])])
    let recipe=Recipe("roundedBody","Rounded body","cube","",[.init("size","Size",1,0.5...2)],solid:definition)
    var project=Project(name:"Generic solid");project.recipes=[recipe];let object=try project.makeObject(recipeID:recipe.id)
    let source=try SolidRecipeGeometry.surface(definition,parameters:object.parameters),node=GeometryFactory.object(object,project:project,assets:FileManager.default.temporaryDirectory)
    XCTAssertFalse(node.childNodes.isEmpty)
    let mesh=try PrintMeshBuilder.mesh(object:object,project:project,assets:FileManager.default.temporaryDirectory,configuration:.init())
    XCTAssertEqual(mesh.triangles.count,source.indices.count/3)
    XCTAssertEqual(mesh.size.z,source.positions.map(\.y).max()! - source.positions.map(\.y).min()!,accuracy:1e-8)
    XCTAssertEqual(source.positions.map(\.y).min()!,-2,accuracy:1e-5)
  }
  func testExplicitVoidFillingPreservesExteriorAndRemovesOnlyEnclosedAir()throws {
    var solid=OrganicSolid()
    for x in [-5.0,5] {for y in [-5.0,5] {for z in [-5.0,5] {solid.ellipsoid(.init(x,y,z),radii:.init(repeating:7.5))}}}
    let open=try solid.mesh(spacing:0.4),filled=try solid.mesh(spacing:0.4,fillVoids:true)
    func report(_ mesh:(positions:[SIMD3<Double>],indices:[UInt32]))throws->MeshTopologyReport {
      try MeshTopology.inspect(.init(id:"rounded-volume",positionsMM:mesh.positions.map{.init($0.x,$0.y,$0.z)},normals:[],indices:mesh.indices),maximumTriangles:2_000_000)
    }
    let a=try report(open),b=try report(filled)
    XCTAssertTrue(a.isClosedOrientedSurface,"\(a)");XCTAssertTrue(b.isClosedOrientedSurface,"\(b)");XCTAssertGreaterThan(b.signedVolumeMM3,a.signedVolumeMM3)
    XCTAssertLessThan(filled.indices.count,open.indices.count)
  }
  func testVariableEllipticalSweepKeepsRoundedEndsAndClosedTopology()throws {
    var solid=OrganicSolid();solid.segment(.init(0,0,0),.init(0,0,20),3,0.6,aspect:0.3,endAspect:1,roll:0.4)
    let mesh=try solid.mesh(spacing:0.25)
    let report=try MeshTopology.inspect(.init(id:"fin",positionsMM:mesh.positions.map{.init($0.x,$0.y,$0.z)},normals:[],indices:mesh.indices),maximumTriangles:2_000_000)
    XCTAssertTrue(report.isClosedOrientedSurface,"\(report)");XCTAssertGreaterThan(report.signedVolumeMM3,30)
  }
  func testAnalyticConstructionPreservesProfileNormalsPhysicalScaleAndExport()throws {
    let definition=ParametricSolid(normalizeHeight:"120",nodes:[.init(kind:"sweep",sweep:.init(samples:"16",variable:"u",values:["x":"3*sin(u*pi/2)","y":"40*u","z":"0","radiusX":"mix(6,2,u)","radiusY":"1"],profile:[[-1,-0.5],[-0.8,-1],[0.8,-1],[1,-0.5],[1,0.5],[0.8,1],[-0.8,1],[-1,0.5]],initialNormal:["1","0","0"],smoothProfile:false))])
    let recipe=Recipe("formedStrip","Formed strip","cube","",[.init("length","Length",1,0.5...2)],solid:definition)
    var project=Project(name:"Profile construction");project.recipes=[recipe];let object=try project.makeObject(recipeID:recipe.id)
    let mesh=try SolidRecipeGeometry.surface(definition,parameters:object.parameters)
    XCTAssertEqual(mesh.normals.count,mesh.positions.count)
    XCTAssertTrue(mesh.normals.allSatisfy{abs(simd_length($0)-1)<1e-9})
    XCTAssertEqual(mesh.positions.map(\.y).max()!-mesh.positions.map(\.y).min()!,120,accuracy:1e-9)
    let report=try MeshTopology.inspect(.init(id:"formed",positionsMM:mesh.positions.map{.init($0.x,$0.y,$0.z)},normals:[],indices:mesh.indices),maximumTriangles:2_000_000)
    XCTAssertTrue(report.isClosedOrientedSurface,"\(report)");XCTAssertGreaterThan(report.signedVolumeMM3,0)
    let print=try PrintMeshBuilder.mesh(object:object,project:project,assets:FileManager.default.temporaryDirectory,configuration:.init())
    XCTAssertEqual(print.triangles.count,mesh.indices.count/3);XCTAssertEqual(print.size.z,120,accuracy:1e-8)
  }
}

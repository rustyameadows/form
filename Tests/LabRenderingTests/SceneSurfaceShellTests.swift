import XCTest
import AppKit
import ImageIO
import simd
@testable import LabRendering

final class SceneSurfaceShellTests:XCTestCase {
  private func plane()->SceneMeshPayload {
    .init(id:"plane",revision:"1",positionsMM:[.init(0,0,0),.init(10,0,0),.init(10,10,0),.init(0,10,0)],
      normals:Array(repeating:.init(0,0,1),count:4),uvs:[.init(0,0),.init(1,0),.init(1,1),.init(0,1)],
      uvs1:[.init(0.2,0.3),.init(0.8,0.3),.init(0.8,0.7),.init(0.2,0.7)],parts:[.init(triangleIndices:[0,1,2,0,2,3])])
  }
  func testPlaneHasExactCaliperReversedBackAndFourBoundaryWalls()throws {
    let source=plane(),shell=try SceneSurfaceShell.build(source,surfaces:[0:.init(thicknessMM:0.5,backMaterialIndex:1,edgeMaterialIndex:2)],materialCount:3)
    XCTAssertEqual(shell.triangleCount,12);XCTAssertEqual(shell.positionsMM.count,24)
    XCTAssertEqual(shell.parts.map(\.materialIndex),[0,1,2]);XCTAssertEqual(shell.parts[2].triangleIndices.count,24)
    XCTAssertEqual(Array(shell.uvs.prefix(4)),source.uvs);XCTAssertEqual(Array(shell.uvs1[4..<8]),source.uvs1)
    for i in 0..<4 {
      XCTAssertEqual(shell.positionsMM[i].z,0.25,accuracy:1e-12);XCTAssertEqual(shell.positionsMM[i+4].z,-0.25,accuracy:1e-12)
      XCTAssertEqual(shell.normals[i],.init(0,0,1));XCTAssertEqual(shell.normals[i+4],.init(0,0,-1))
    }
    XCTAssertEqual(shell.parts[1].triangleIndices,[6,5,4,7,6,4])
    XCTAssertTrue(shell.normals.dropFirst(8).allSatisfy{abs($0.z)<1e-6})
    XCTAssertEqual(source.positionsMM,plane().positionsMM);XCTAssertEqual(source.triangleCount,2)
  }
  func testCurvedCoincidentPanelsStayIndependentWithOwnCaliperAndUVs()throws {
    let positions:[SIMD3<Double>]=[.init(0,0,0),.init(10,0,2),.init(20,0,0),.init(0,10,0),.init(10,10,2),.init(20,10,0)]
    let uv:[SIMD2<Float>]=[.init(0,0),.init(0.5,0),.init(1,0),.init(0,1),.init(0.5,1),.init(1,1)]
    let indices:[UInt32]=[0,1,4,0,4,3,1,2,5,1,5,4]
    let source=SceneMeshPayload(id:"panels",revision:"1",positionsMM:positions+positions,uvs:uv+uv,uvs1:uv.map{1-$0}+uv,
      parts:[.init(materialIndex:0,triangleIndices:indices),.init(materialIndex:3,triangleIndices:indices.map{$0+6})])
    let shell=try SceneSurfaceShell.build(source,surfaces:[0:.init(thicknessMM:0.4,backMaterialIndex:1,edgeMaterialIndex:2),3:.init(thicknessMM:0.8,backMaterialIndex:4,edgeMaterialIndex:5)],materialCount:6)
    XCTAssertEqual(shell.triangleCount,40);XCTAssertEqual(shell.positionsMM.count,72)
    for i in 0..<12 {XCTAssertEqual(simd_distance(shell.positionsMM[i],shell.positionsMM[i+12]),i<6 ? 0.4:0.8,accuracy:1e-10)}
    XCTAssertEqual(Array(shell.uvs.prefix(12)),source.uvs);XCTAssertEqual(Array(shell.uvs1[12..<24]),source.uvs1)
    XCTAssertNotEqual(shell.normals[0],shell.normals[2]);XCTAssertEqual(shell.parts.filter{$0.semanticID=="physical-cut-edge"}.count,2)
  }
  func testNonManifoldOrInconsistentSourceEdgesAreRejected()throws {
    var source=plane();source.parts[0].triangleIndices += [0,1,3]
    XCTAssertThrowsError(try SceneSurfaceShell.build(source,surfaces:[0:.init(thicknessMM:1,backMaterialIndex:1,edgeMaterialIndex:2)],materialCount:3))
  }
  func testPartsWithoutCaliperKeepTheirOriginalPositions()throws {
    var source=plane();source.parts.append(.init(materialIndex:3,triangleIndices:[0,1,2]))
    let shell=try SceneSurfaceShell.build(source,surfaces:[0:.init(thicknessMM:1,backMaterialIndex:1,edgeMaterialIndex:2)],materialCount:4)
    let part=try XCTUnwrap(shell.parts.first{$0.materialIndex==3})
    XCTAssertEqual(part.triangleIndices.map{shell.positionsMM[Int($0)]},[source.positionsMM[0],source.positionsMM[1],source.positionsMM[2]])
  }
  func testNativeRendererShowsIndependentReverseAndCutEdge()async throws {
    guard let path=ProcessInfo.processInfo.environment["LAB_CYCLES_TEST_HELPER"] else {throw XCTSkip("Set LAB_CYCLES_TEST_HELPER for rendered shell material validation.")}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("shell-render-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
    let mesh=try SceneSurfaceShell.build(plane(),surfaces:[0:.init(thicknessMM:2,backMaterialIndex:1,edgeMaterialIndex:2)],materialCount:3)
    let materials=[SIMD4<Float>(1,0,0,1),.init(0,0,1,1),.init(0,1,0,1)].enumerated().map{SceneMaterialPayload(id:"surface-\($0.offset)",baseColor:$0.element,unlit:true)}
    let service=CyclesRenderService(helperURL:URL(fileURLWithPath:path))
    for (eye,expected) in [(SIMD3<Double>(5,5,-30),"back"),(SIMD3<Double>(30,5,0),"edge")] {
      let scene=SceneSnapshot(revision:expected,renderables:[.init(componentID:"shell",objectID:UUID(),mesh:mesh,materials:materials)],camera:.looking(from:eye,at:.init(5,5,0),projection:.orthographic(verticalSpanMM:14)))
      let job=try await service.start(snapshot:scene,settings:.init(width:64,height:64,samples:4,denoise:false,device:.cpu),outputDirectory:root)
      var result:SceneRenderResult?
      for try await event in job.events {if case .completed(let value)=event {result=value}}
      let imageSource=try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(result).pngURL as CFURL,nil))
      let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource,0,nil))
      let context=try XCTUnwrap(CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image,in:CGRect(x:0,y:0,width:64,height:64))
      let pixels=try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self),offset=32*256+32*4
      XCTAssertLessThan(pixels[offset],12)
      if expected=="back" {XCTAssertGreaterThan(pixels[offset+2],242);XCTAssertLessThan(pixels[offset+1],12)}
      else {XCTAssertGreaterThan(pixels[offset+1],242);XCTAssertLessThan(pixels[offset+2],12)}
    }
  }
}

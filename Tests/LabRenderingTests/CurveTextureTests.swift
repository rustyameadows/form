import XCTest
import AppKit
import ImageIO
@testable import LabRendering

final class CurveTextureTests:XCTestCase {
  private func temporary()throws->URL {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("curve-textures-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root
  }
  private func image(width:Int=2)throws->CGImage {
    let bytes:[UInt8]=width==1 ? [255,0,0,255]:[255,0,0,255,0,0,255,255]
    return try XCTUnwrap(CGImage(width:width,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.last.rawValue),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
  }
  private func curve()->SceneCurvePayload {
    .init(id:"strand",revision:"1",objectID:UUID(),pointsMM:[.init(0,0,0),.init(3,4,0),.init(20,0,0),.init(20,0,12)],radiiMM:Array(repeating:0.2,count:4),firstKey:[0,2],material:.init(id:"thread"))
  }
  func testCurveCoordinatesUsePhysicalArcAndResetAtEachIndependentStrand()throws {
    var value=curve();let uv=try value.resolvedTextureCoordinatesMM()
    XCTAssertEqual(uv,[.init(0,0),.init(5,0),.init(0,0),.init(12,0)])
    value.transform.scale = .init(repeating:2)
    XCTAssertEqual(try value.resolvedTextureCoordinatesMM(),[.init(0,0),.init(10,0),.init(0,0),.init(24,0)])
    value.uvs1MM=[.zero];XCTAssertThrowsError(try value.validate())
    value.uvs1MM=[];value.pointsMM[1].x = .infinity;XCTAssertThrowsError(try value.validate())
    value=curve();value.firstKey=[0];value.pointsMM=[.init(0,0,0),.init(1,1,0),.init(2,0,0),.init(3,1,0)]
    XCTAssertGreaterThan(try value.resolvedTextureCoordinatesMM()[1].x,Float(sqrt(2)))
  }
  func testMissingMeshUVsFailClearlyWhileConstantMapsAndUnusedSlotsRemainValid()throws {
    let root=try temporary()
    var material=SceneMaterialPayload(id:"mapped");material.baseColorTexture = .init(image:try image(),revision:"map",uvIndex:1)
    var mesh=SceneMeshPayload(id:"mesh",revision:"1",positionsMM:[.zero,.init(10,0,0),.init(0,10,0)],parts:[.init(triangleIndices:[0,1,2])])
    func write(_ materials:[SceneMaterialPayload])throws {
      let snapshot=SceneSnapshot(revision:"1",renderables:[.init(componentID:"surface",objectID:UUID(),mesh:mesh,materials:materials)],camera:.looking(from:.init(0,0,100),at:.zero))
      _=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(width:16,height:16),jobID:UUID(),directory:root)
    }
    XCTAssertThrowsError(try write([material])){XCTAssertTrue($0.localizedDescription.contains("UV1"))}
    XCTAssertNoThrow(try write([.init(id:"unused test"),material]))
    material.baseColorTexture = .init(image:try image(width:1),revision:"constant",uvIndex:1)
    XCTAssertNoThrow(try write([material]))
    material.baseColorTexture = .init(image:try image(),revision:"map",uvIndex:0)
    XCTAssertThrowsError(try write([material]))
    mesh.uvs=[.zero,.init(1,0),.init(0,1)];XCTAssertNoThrow(try write([material]))
  }
  func testCurveManifestIncludesArcBufferAndRejectsMissingUV1AndTrueDisplacement()throws {
    let root=try temporary();var value=curve()
    func write()throws->[String:Any] {
      let snapshot=SceneSnapshot(revision:"1",renderables:[],curves:[value],camera:.looking(from:.init(0,0,100),at:.zero))
      let url=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(width:16,height:16),jobID:UUID(),directory:root)
      return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
    }
    let raw=try write(),curves=try XCTUnwrap(raw["curves"] as? [[String:Any]]),uv=try XCTUnwrap(curves[0]["uvs"] as? [String:Any])
    XCTAssertEqual(uv["count"] as? Int,4)
    let data=try Data(contentsOf:root.appendingPathComponent(uv["path"] as! String))
    XCTAssertEqual(data.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:8,as:Float.self)},5)
    value.material.baseColorTexture = .init(image:try image(),revision:"map",uvIndex:1)
    XCTAssertThrowsError(try write())
    value.uvs1MM=try value.resolvedTextureCoordinatesMM();XCTAssertNoThrow(try write())
    value.material.physicalAppearance=ScenePhysicalAppearance();value.material.physicalAppearance?.displacementScaleMM=0.1
    value.material.physicalAppearance?.textures[.displacement] = .init(image:try image(width:1),revision:"height",encoding:.data)
    XCTAssertThrowsError(try write()){XCTAssertTrue($0.localizedDescription.contains("triangle surfaces"))}
  }
  func testNativeCurveTextureRepeatsAlongPhysicalLengthAndUsesUV1()async throws {
    guard let path=ProcessInfo.processInfo.environment["LAB_CYCLES_TEST_CURVE_UV_HELPER"] else {throw XCTSkip("Set a native helper with curve millimeter UV support for shader validation.")}
    let root=try temporary(),service=CyclesRenderService(helperURL:URL(fileURLWithPath:path))
    var texture=SceneTexturePayload(image:try image(),revision:"red-blue",encoding:.srgb);texture.scale = .init(0.1,1)
    var material=SceneMaterialPayload(id:"mapped strand",unlit:true);material.baseColorTexture=texture
    var value=SceneCurvePayload(id:"straight",revision:"1",objectID:UUID(),pointsMM:(-10...10).map{.init(Double($0),0,0)},radiiMM:Array(repeating:1,count:21),firstKey:[0],material:material)
    for uvIndex in 0...1 {
      value.material.baseColorTexture?.uvIndex=uvIndex
      if uvIndex==1 {value.uvs1MM=try value.resolvedTextureCoordinatesMM().map{.init(20-$0.x,$0.y)}}
      let snapshot=SceneSnapshot(revision:"uv\(uvIndex)",renderables:[],curves:[value],camera:.looking(from:.init(0,0,100),at:.zero,projection:.orthographic(verticalSpanMM:10)))
      let job=try await service.start(snapshot:snapshot,settings:.init(width:384,height:128,samples:16,denoise:false,device:.cpu),outputDirectory:root)
      var result:SceneRenderResult?
      for try await event in job.events {if case .completed(let value)=event {result=value}}
      let source=try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(result).pngURL as CFURL,nil)),image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
      let context=try XCTUnwrap(CGContext(data:nil,width:384,height:128,bitsPerComponent:8,bytesPerRow:1536,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image,in:CGRect(x:0,y:0,width:384,height:128));let bytes=try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
      for (index,x) in [96,160,224,288].enumerated() {
        let offset=64*1536+x*4,red=(index+uvIndex).isMultiple(of:2)
        XCTAssertGreaterThan(bytes[offset+(red ? 0:2)],220,"UV\(uvIndex) sample\(index)")
        XCTAssertLessThan(bytes[offset+(red ? 2:0)],80,"UV\(uvIndex) sample\(index)")
      }
    }
  }
}

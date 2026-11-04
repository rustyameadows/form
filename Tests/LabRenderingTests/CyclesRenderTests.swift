import XCTest
import AppKit
import ImageIO
import CryptoKit
@testable import LabRendering

final class CyclesRenderTests:XCTestCase {
  private func temporary()throws->URL {
    let url=FileManager.default.temporaryDirectory.appendingPathComponent("lab-cycles-tests-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);addTeardownBlock{try? FileManager.default.removeItem(at:url)};return url
  }
  private func scene()->SceneSnapshot {
    let mesh=SceneMeshPayload(id:"triangle",revision:"1",positionsMM:[.init(0,0,0),.init(100,0,0),.init(0,100,0)],parts:[.init(triangleIndices:[0,1,2])])
    return .init(revision:"source-v1",renderables:[.init(componentID:"surface",objectID:UUID(),mesh:mesh,materials:[.init(id:"material")])],camera:.looking(from:.init(0,0,300),at:.zero))
  }
  private func helper(in root:URL,body:String)throws->URL {
    let url=root.appendingPathComponent("helper")
    try ("#!/usr/bin/python3\nimport sys, json, os, time, base64\n"+body).write(to:url,atomically:true,encoding:.utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path);return url
  }
  func testManifestKeepsMillimetersSlotsAndConvertsCameraDirection()throws {
    let root=try temporary();var snapshot=scene()
    snapshot.renderables[0].materials.append(.init(id:"blue",baseColor:.init(0,0,1,1)))
    snapshot.renderables[0].mesh.parts[0].materialIndex=1
    let url=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(width:32,height:16),jobID:UUID(),directory:root)
    let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]),meshes=try XCTUnwrap(raw["meshes"] as? [[String:Any]])
    let positions=try XCTUnwrap(meshes[0]["positions"] as? [String:Any]),positionData=try Data(contentsOf:root.appendingPathComponent(positions["path"] as! String))
    XCTAssertEqual(positionData.count,9*8);XCTAssertEqual(positionData.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:3*8,as:Double.self)},100)
    let slots=try XCTUnwrap(meshes[0]["materialIndices"] as? [String:Any]),slotData=try Data(contentsOf:root.appendingPathComponent(slots["path"] as! String))
    XCTAssertEqual(slotData.withUnsafeBytes{$0.loadUnaligned(as:UInt32.self)},1)
    let camera=try XCTUnwrap(raw["camera"] as? [String:Any]),matrix=try XCTUnwrap(camera["transform"] as? [Double])
    XCTAssertEqual(matrix[10],-1);XCTAssertEqual(matrix[14],0)
    XCTAssertEqual(raw["originMM"] as? [Double],[0,0,300])
    XCTAssertEqual((meshes[0]["transform"] as? [Double])?[14],-300)
  }
  func testInvalidGeometryAndCurvePartitionAreRejected()throws {
    let root=try temporary();var snapshot=scene();snapshot.renderables[0].mesh.positionsMM[0].x = .nan
    XCTAssertThrowsError(try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(),jobID:UUID(),directory:root))
    let curve=SceneCurvePayload(id:"curve",revision:"1",objectID:UUID(),pointsMM:[.zero,.init(1,0,0),.init(2,0,0)],radiiMM:[0.1,0.1,0.1],firstKey:[0,1],material:.init(id:"thread"))
    XCTAssertThrowsError(try curve.validate())
  }
  func testMaskedFinishFactorsStaySeparateFromSubstrateMapsAndInheritedOptics()throws {
    let root=try temporary(),context=try XCTUnwrap(CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red:0.4,green:0.4,blue:0.4,alpha:1));context.fill(CGRect(x:0,y:0,width:1,height:1))
    let texture=SceneTexturePayload(image:try XCTUnwrap(context.makeImage()),revision:"constant",encoding:.data)
    var snapshot=scene(),stock=ScenePhysicalAppearance();stock.sheen=0.3;stock.textures[.roughness]=texture;stock.textures[.metallic]=texture
    snapshot.renderables[0].materials[0].physicalAppearance=stock
    snapshot.renderables[0].materials[0].physicalLayers=[.init(mask:texture,roughness:0.18,metallic:1)]
    let url=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(width:16,height:16),jobID:UUID(),directory:root)
    let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
    let material=try XCTUnwrap((raw["materials"] as? [[String:Any]])?.first),layer=try XCTUnwrap((material["physicalLayers"] as? [[String:Any]])?.first)
    XCTAssertNil(layer["appearance"]);XCTAssertEqual(layer["roughness"] as? Double,0.18);XCTAssertEqual(layer["metallic"] as? Double,1)
    XCTAssertNotNil((material["textures"] as? [String:Any])?["roughness"]);XCTAssertEqual(material["sheen"] as? Double,0.3)
    snapshot.renderables[0].materials[0].physicalLayers[0].metallic = .nan
    XCTAssertThrowsError(try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(),jobID:UUID(),directory:root))
  }
  func testInstancesReuseMeshBuffersAndMaterialSlots()throws {
    let root=try temporary();var snapshot=scene(),second=snapshot.renderables[0]
    second.componentID="second";second.transform.translationMM = .init(200,0,0);snapshot.renderables.append(second)
    let url=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(width:16,height:16),jobID:UUID(),directory:root)
    let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]),meshes=try XCTUnwrap(raw["meshes"] as? [[String:Any]]),materials=try XCTUnwrap(raw["materials"] as? [[String:Any]])
    XCTAssertEqual((meshes[0]["positions"] as? [String:Any])?["path"] as? String,(meshes[1]["positions"] as? [String:Any])?["path"] as? String)
    XCTAssertEqual(materials.count,1)
    XCTAssertEqual((meshes[1]["transform"] as? [Double])?[12],200)
  }
  private func verifiedTextureBytes(width:Int=1,height:Int=1)throws->Data {
    let words=[UInt16](repeating:32768,count:width*height)
    let image=try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:16,bitsPerPixel:16,bytesPerRow:width*2,
      space:CGColorSpace(name:CGColorSpace.genericGrayGamma2_2)!,bitmapInfo:[.byteOrder16Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue)],
      provider:CGDataProvider(data:words.withUnsafeBytes{Data($0)} as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let data=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination));return data as Data
  }
  func testVerifiedRepeatedHighDepthMapsStayWithinTransferBudgetWithoutDownsampling()throws {
    let root=try temporary(),data=try verifiedTextureBytes(width:2048,height:2048),digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    var snapshot=scene();snapshot.renderables=[]
    for index in 0..<18 {
      // Deliberately decode separate CGImages. Object identity cannot deduplicate
      // these 18 × 64 MiB transfers; verified byte identity must do so instead.
      let source=try SceneTextureSource(data:data,expectedSHA256:digest)
      var item=scene().renderables[0],texture=SceneTexturePayload(source:source,encoding:.data)
      item.componentID="instance-\(index)";item.mesh.uvs=[.zero,.init(1,0),.init(0,1)]
      texture.scale = .init(Double(index+1),2);texture.offset.x=Double(index)/20
      item.materials[0].id="surface-\(index)";item.materials[0].roughnessTexture=texture;snapshot.renderables.append(item)
    }
    let url=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(purpose:.preview,width:32,height:32),jobID:UUID(),directory:root)
    let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]),materials=try XCTUnwrap(raw["materials"] as? [[String:Any]])
    let maps=try materials.map{try XCTUnwrap(($0["textures"] as? [String:Any])?["roughness"] as? [String:Any])}
    XCTAssertEqual(Set(maps.compactMap{$0["path"] as? String}).count,1)
    XCTAssertEqual(maps.count,18);XCTAssertEqual(maps.last?["scale"] as? [Double],[18,2])
    XCTAssertEqual(maps.first?["width"] as? Int,2048);XCTAssertEqual(maps.first?["height"] as? Int,2048)
    let path=try XCTUnwrap(maps.first?["path"] as? String)
    XCTAssertEqual(try root.appendingPathComponent(path).resourceValues(forKeys:[.fileSizeKey]).fileSize,2048*2048*16)
  }
  func testVerifiedTextureReuseSeparatesEncodingAndCannotAliasChangedImageOrUnverifiedRevision()throws {
    let root=try temporary(),data=try verifiedTextureBytes(),digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    XCTAssertThrowsError(try SceneTextureSource(data:data,expectedSHA256:String(repeating:"0",count:64)))
    let source=try SceneTextureSource(data:data,expectedSHA256:digest)
    var snapshot=scene(),color=SceneTexturePayload(source:source,encoding:.srgb),numeric=SceneTexturePayload(source:source,encoding:.data)
    color.rotationDegrees=30;numeric.wrapS = .mirror;numeric.offset = .init(0.2,0.7)
    snapshot.renderables[0].materials[0].baseColorTexture=color;snapshot.renderables[0].materials[0].roughnessTexture=numeric
    let independent=try SceneTextureSource(data:data,expectedSHA256:digest)
    snapshot.renderables[0].materials[0].normalTexture = .init(image:independent.image,revision:digest,encoding:.data)
    var changed=numeric;changed.image=independent.image
    XCTAssertNil(changed.verifiedContentSHA256)
    snapshot.renderables[0].materials[0].metallicTexture=changed
    let url=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(width:16,height:16),jobID:UUID(),directory:root)
    let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]),material=try XCTUnwrap((raw["materials"] as? [[String:Any]])?.first),maps=try XCTUnwrap(material["textures"] as? [String:[String:Any]])
    XCTAssertNotEqual(maps["baseColor"]?["path"] as? String,maps["roughness"]?["path"] as? String)
    XCTAssertNotEqual(maps["normal"]?["path"] as? String,maps["roughness"]?["path"] as? String)
    XCTAssertEqual(maps["normal"]?["path"] as? String,maps["metallic"]?["path"] as? String)
    XCTAssertEqual(maps["roughness"]?["wrapS"] as? String,"mirror")
    let colorData=try Data(contentsOf:root.appendingPathComponent(try XCTUnwrap(maps["baseColor"]?["path"] as? String)))
    let numericData=try Data(contentsOf:root.appendingPathComponent(try XCTUnwrap(maps["roughness"]?["path"] as? String)))
    XCTAssertEqual(colorData.withUnsafeBytes{$0.loadUnaligned(as:Float.self)},0.21405,accuracy:0.0002)
    XCTAssertEqual(numericData.withUnsafeBytes{$0.loadUnaligned(as:Float.self)},0.5,accuracy:0.0002)
  }
  func testPhysicalOverridesDoNotWriteDeadTexturesAndKeepNormalDetailArtworkAndEmissionFallback()throws {
    let root=try temporary(),data=try verifiedTextureBytes(),digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    func texture(_ name:String)throws->SceneTexturePayload {
      let image=try SceneTextureSource(data:data,expectedSHA256:digest).image
      return .init(image:image,revision:name,encoding:.data)
    }
    var snapshot=scene(),material=snapshot.renderables[0].materials[0],physical=ScenePhysicalAppearance()
    material.baseColorTexture=try texture("unused-color");material.roughnessTexture=try texture("unused-roughness")
    material.metallicTexture=try texture("unused-metallic")
    // An overridden base map cannot impose a coordinate set the final shader
    // never reads. The physical maps below are constant UV0 images.
    let larger=try verifiedTextureBytes(width:2),largeDigest=SHA256.hash(data:larger).map{String(format:"%02x",$0)}.joined()
    material.baseColorTexture = .init(source:try SceneTextureSource(data:larger,expectedSHA256:largeDigest),uvIndex:1)
    material.normalTexture=try texture("normal-base");material.artworkTexture=try texture("artwork")
    material.emissiveTexture=try texture("emission-fallback")
    for channel in [ScenePhysicalTextureChannel.baseColor,.roughness,.metallic,.normal] {
      physical.textures[channel] = .init(source:try SceneTextureSource(data:data,expectedSHA256:digest),encoding:channel == .baseColor ? .srgb:.data)
    }
    material.physicalAppearance=physical
    material.physicalLayers=[.init(mask:try texture("finish-mask"),appearance:physical)]
    snapshot.renderables[0].materials=[material]
    let manifest=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(width:16,height:16),jobID:UUID(),directory:root)
    let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any]),resolved=try XCTUnwrap((raw["materials"] as? [[String:Any]])?.first),maps=try XCTUnwrap(resolved["textures"] as? [String:[String:Any]])
    for key in ["normal","normalDetail","artwork","emission"] {XCTAssertNotNil(maps[key],key)}
    XCTAssertNotEqual(maps["normal"]?["path"] as? String,maps["normalDetail"]?["path"] as? String)
    var referenced=Set<String>()
    func visit(_ value:Any) {
      if let object=value as? [String:Any] {
        if let path=object["path"] as? String,path.hasPrefix("texture-") {referenced.insert(path)}
        object.values.forEach(visit)
      } else if let values=value as? [Any] {values.forEach(visit)}
    }
    visit(raw)
    let emitted=Set(try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).map(\.lastPathComponent).filter{$0.hasPrefix("texture-")})
    XCTAssertEqual(emitted,referenced,"Overridden substrate maps must not consume files or the transfer budget.")
    // Replacing emission later must remove its fallback file too.
    snapshot.renderables[0].materials[0].physicalAppearance?.textures[.emission]=physical.textures[.baseColor]
    let second=try temporary()
    _=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(width:16,height:16),jobID:UUID(),directory:second)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:second,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("texture-")}.count,emitted.count-1)
  }
  func testLargeWorldTranslationIsRebasedBeforeFloatConversion()throws {
    let root=try temporary();var snapshot=scene();let offset=SIMD3<Double>(1e9,2e9,-1e9)
    snapshot.renderables[0].transform.translationMM=offset
    snapshot.camera = .looking(from:offset+SIMD3(0,0,300),at:offset)
    let url=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(width:16,height:16),jobID:UUID(),directory:root)
    let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]),meshes=try XCTUnwrap(raw["meshes"] as? [[String:Any]]),matrix=try XCTUnwrap(meshes[0]["transform"] as? [Double])
    XCTAssertEqual(Array(matrix[12...14]),[0,0,-300])
    XCTAssertEqual(raw["originMM"] as? [Double],[1e9,2e9,-1e9+300])
  }
  func testFloatingPointEnvironmentRetainsValuesAboveOne()throws {
    let root=try temporary();var values:[Float]=[4,2,1,1,0.125,0.25,0.5,1]
    let data=values.withUnsafeMutableBytes{Data($0)},provider=try XCTUnwrap(CGDataProvider(data:data as CFData))
    let image=try XCTUnwrap(CGImage(width:1,height:2,bitsPerComponent:32,bitsPerPixel:128,bytesPerRow:16,space:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!,bitmapInfo:[.floatComponents,.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue)],provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    var snapshot=scene();snapshot.environment.texture = .init(image:image,revision:"hdr",encoding:.linear)
    let url=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(width:32,height:32),jobID:UUID(),directory:root)
    let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]),background=try XCTUnwrap(raw["background"] as? [String:Any]),texture=try XCTUnwrap(background["texture"] as? [String:Any])
    XCTAssertEqual(texture["format"] as? String,"rgba32f")
    let pixels=try Data(contentsOf:root.appendingPathComponent(texture["path"] as! String))
    XCTAssertEqual(pixels.withUnsafeBytes{$0.loadUnaligned(as:Float.self)},4,accuracy:0.0001)
    XCTAssertEqual(pixels.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:16,as:Float.self)},0.125,accuracy:0.0001)
  }
  func testSixteenBitMonochromePNGPreservesNumericSamplesAndRowOrientation()throws {
    let source=try temporary()
    let words:[UInt16]=[16384,49152]
    let provider=try XCTUnwrap(CGDataProvider(data:words.withUnsafeBytes{Data($0)} as CFData))
    let original=try XCTUnwrap(CGImage(width:1,height:2,bitsPerComponent:16,bitsPerPixel:16,bytesPerRow:2,
      space:CGColorSpace(name:CGColorSpace.genericGrayGamma2_2)!,bitmapInfo:[.byteOrder16Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue)],
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let png=source.appendingPathComponent("gray16.png")
    let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,original,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let decoded=try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL,nil))
    let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded,0,nil))
    XCTAssertEqual(image.bitsPerComponent,16);XCTAssertEqual(image.colorSpace?.model,.monochrome)
    for encoding in [SceneTextureEncoding.data,.linear] {
      let root=try temporary();var snapshot=scene()
      snapshot.environment.texture = .init(image:image,revision:"numeric-gray",encoding:encoding)
      let url=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(width:16,height:16),jobID:UUID(),directory:root)
      let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
      let background=try XCTUnwrap(raw["background"] as? [String:Any]),texture=try XCTUnwrap(background["texture"] as? [String:Any])
      XCTAssertEqual(texture["format"] as? String,"rgba32f")
      XCTAssertEqual(texture["colorSpace"] as? String,encoding.rawValue)
      let pixels=try Data(contentsOf:root.appendingPathComponent(texture["path"] as! String))
      XCTAssertEqual(pixels.count,32)
      for row in 0..<2 {
        for channel in 0..<3 {
          let actual=pixels.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:(row*4+channel)*4,as:Float.self)}
          XCTAssertEqual(actual,Float(words[row])/65535,accuracy:0.0002,"Numeric gray must not acquire a gamma transfer or channel tint.")
        }
        XCTAssertEqual(pixels.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:(row*4+3)*4,as:Float.self)},1)
      }
    }
  }
  private func decodedSRGBPixels(_ image:CGImage)throws->[Float] {
    let root=try temporary();var snapshot=scene()
    snapshot.environment.texture = .init(image:image,revision:"declared-srgb",encoding:.srgb)
    let url=try CyclesSceneManifest.write(snapshot:snapshot,settings:.init(width:16,height:16),jobID:UUID(),directory:root)
    let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
    let background=try XCTUnwrap(raw["background"] as? [String:Any]),texture=try XCTUnwrap(background["texture"] as? [String:Any])
    XCTAssertEqual(texture["format"] as? String,"rgba32f");XCTAssertEqual(texture["colorSpace"] as? String,"linear")
    let data=try Data(contentsOf:root.appendingPathComponent(texture["path"] as! String))
    XCTAssertEqual(data.count,image.width*image.height*16)
    return stride(from:0,to:data.count,by:4).map{offset in data.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:offset,as:Float.self)}}
  }
  func testHighDepthSRGBOverridesEmbeddedP3AndDecodesAfterUnpremultiplication()throws {
    let words:[UInt16]=[52428,26214,13107,65535,32768,8192,2048,32768]
    let provider=try XCTUnwrap(CGDataProvider(data:words.withUnsafeBytes{Data($0)} as CFData))
    let image=try XCTUnwrap(CGImage(width:2,height:1,bitsPerComponent:16,bitsPerPixel:64,bytesPerRow:16,
      space:CGColorSpace(name:CGColorSpace.displayP3)!,bitmapInfo:[.byteOrder16Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue)],
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let actual=try decodedSRGBPixels(image)
    // Independent IEC sRGB reference for straight RGB [0.8,0.4,0.2] and
    // [1,0.25,0.0625]. The embedded P3 primaries must not alter those values.
    let expected:[Float]=[0.6038273388553378,0.13286832155381798,0.033104766570885055,1,
      1,0.05087608817155679,0.005155668399032601,0.5000076295109483]
    for index in expected.indices {XCTAssertEqual(actual[index],expected[index],accuracy:0.000002)}
  }
  func testHighDepthGraySRGBUsesExactPiecewiseTransferInsteadOfEmbeddedGamma()throws {
    let words:[UInt16]=[1024,2650,2651,32768]
    let provider=try XCTUnwrap(CGDataProvider(data:words.withUnsafeBytes{Data($0)} as CFData))
    let image=try XCTUnwrap(CGImage(width:1,height:4,bitsPerComponent:16,bitsPerPixel:16,bytesPerRow:2,
      space:CGColorSpace(name:CGColorSpace.genericGrayGamma2_2)!,bitmapInfo:[.byteOrder16Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue)],
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let actual=try decodedSRGBPixels(image)
    // Includes samples on each side of the 0.04045 transfer boundary.
    let expected:[Float]=[0.0012093837788093758,0.0031297529432078577,0.0031309385166837663,0.2140482022981852]
    for row in expected.indices {
      for channel in 0..<3 {XCTAssertEqual(actual[row*4+channel],expected[row],accuracy:0.0000002)}
      XCTAssertEqual(actual[row*4+3],1)
    }
  }
  func testHighDepthSRGBRejectsOverflowAfterDecodingFiniteSamples()throws {
    let values:[Float]=[1e20,1,1,1]
    let provider=try XCTUnwrap(CGDataProvider(data:values.withUnsafeBytes{Data($0)} as CFData))
    let image=try XCTUnwrap(CGImage(width:1,height:1,bitsPerComponent:32,bitsPerPixel:128,bytesPerRow:16,
      space:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!,bitmapInfo:[.floatComponents,.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue)],
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    XCTAssertThrowsError(try decodedSRGBPixels(image)) {error in
      XCTAssertTrue(error.localizedDescription.contains("Decoded render texture values must be finite"),error.localizedDescription)
    }
  }
  func testFinalJobRejectsPreviewAndCancellationFinishesStream()async throws {
    let root=try temporary(),url=try helper(in:root,body:"time.sleep(30)\n"),service=CyclesRenderService(helperURL:url)
    let job=try await service.start(snapshot:scene(),settings:.init(width:16,height:16),outputDirectory:root)
    do {_ = try await service.start(snapshot:scene(),settings:.init(purpose:.preview,width:16,height:16),outputDirectory:root);XCTFail("Preview must not interrupt final output.")}
    catch {XCTAssertTrue(error is CyclesRenderError)}
    await service.cancel(jobID:job.id)
    do {for try await _ in job.events {};XCTFail("Cancelled stream must terminate with cancellation.")}catch{}
    let status=await service.status(jobID:job.id);XCTAssertEqual(status?.state,.cancelled)
  }
  func testNewPreviewCancelsPriorPreviewWithoutAcceptingOldEvents()async throws {
    let root=try temporary(),url=try helper(in:root,body:"time.sleep(30)\n"),service=CyclesRenderService(helperURL:url)
    let first=try await service.start(snapshot:scene(),settings:.init(purpose:.preview,width:16,height:16),outputDirectory:root)
    let second=try await service.start(snapshot:scene(),settings:.init(purpose:.preview,width:16,height:16),outputDirectory:root)
    let old=await service.status(jobID:first.id),current=await service.currentJobID
    XCTAssertEqual(old?.state,.cancelled);XCTAssertEqual(current,second.id)
    await service.cancel(jobID:second.id)
  }
  func testReviewAndViewportBudgetsStayBelowFinalOutputResolution()throws {
    XCTAssertThrowsError(try SceneRenderSettings(purpose:.preview,width:1281,height:1280).validate())
    XCTAssertThrowsError(try SceneRenderSettings(purpose:.review,width:1280,height:1281).validate())
    XCTAssertNoThrow(try SceneRenderSettings(purpose:.final,width:3000,height:2000).validate())
  }
  func testFinalPreemptsReviewWhileReviewPreemptsLivePreview()async throws {
    let root=try temporary(),url=try helper(in:root,body:"time.sleep(30)\n"),service=CyclesRenderService(helperURL:url)
    let live=try await service.start(snapshot:scene(),settings:.init(purpose:.preview,width:16,height:16),outputDirectory:root)
    let review=try await service.start(snapshot:scene(),settings:.init(purpose:.review,width:16,height:16),outputDirectory:root)
    let liveStatus=await service.status(jobID:live.id);XCTAssertEqual(liveStatus?.state,.cancelled)
    do {_ = try await service.start(snapshot:scene(),settings:.init(purpose:.preview,width:16,height:16),outputDirectory:root);XCTFail("Live preview cannot interrupt an explicit review.")}catch{}
    let final=try await service.start(snapshot:scene(),settings:.init(purpose:.final,width:16,height:16),outputDirectory:root)
    let reviewStatus=await service.status(jobID:review.id);XCTAssertEqual(reviewStatus?.state,.cancelled)
    await service.cancel(jobID:final.id)
  }
  func testHelperCannotPublishFileOutsideJobDirectory()async throws {
    let root=try temporary(),url=try helper(in:root,body:"print(json.dumps({'type':'frame','framePath':'../outside.png'}), flush=True)\n"),service=CyclesRenderService(helperURL:url)
    let job=try await service.start(snapshot:scene(),settings:.init(width:16,height:16),outputDirectory:root)
    do {for try await _ in job.events {};XCTFail("Outside output must be rejected.")}catch{}
    let status=await service.status(jobID:job.id);XCTAssertEqual(status?.state,.failed)
  }
  func testCompletedFilesArePublishedOnlyAfterSuccessfulHelperExit()async throws {
    let root=try temporary()
    let context=try XCTUnwrap(CGContext(data:nil,width:2,height:1,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    let image=try XCTUnwrap(context.makeImage()),data=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let body="""
    m=json.load(open(sys.argv[2]))
    d=m['outputDirectory']
    open(os.path.join(d,'frame.png'),'wb').write(base64.b64decode('\((data as Data).base64EncodedString())'))
    open(os.path.join(d,'linear.exr'),'wb').write(bytes([0x76,0x2f,0x31,0x01,0,0,0,0]))
    print(json.dumps({'type':'frame','jobID':m['jobID'],'framePath':'frame.png','sample':1}),flush=True)
    print(json.dumps({'type':'completed','jobID':m['jobID'],'finalPNG':'frame.png','finalEXR':'linear.exr','sample':2,'device':'CPU','engineVersion':'protocol-test'}),flush=True)
    time.sleep(0.05)
    """
    let url=try helper(in:root,body:body),service=CyclesRenderService(helperURL:url)
    let job=try await service.start(snapshot:scene(),settings:.init(width:2,height:1,samples:2),outputDirectory:root)
    var completed:CyclesRenderResult?,sawFrame=false
    for try await event in job.events {switch event {case .frame:sawFrame=true;case .completed(let result):completed=result;case .progress:break}}
    XCTAssertTrue(sawFrame);XCTAssertEqual(completed?.device,"CPU");XCTAssertEqual(completed?.sourceRevision,"source-v1")
    let status=await service.status(jobID:job.id);XCTAssertEqual(status?.state,.completed)
  }
  func testShortProgressAndFramesArriveBeforeHelperCanComplete()async throws {
    let root=try temporary()
    let context=try XCTUnwrap(CGContext(data:nil,width:2,height:1,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    let image=try XCTUnwrap(context.makeImage()),data=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let body="""
    m=json.load(open(sys.argv[2]));d=m['outputDirectory']
    def acknowledged(name):
        deadline=time.monotonic()+5
        while not os.path.exists(os.path.join(d,name)):
            if time.monotonic()>deadline: sys.exit(9)
            time.sleep(.01)
    print(json.dumps({'type':'progress','jobID':m['jobID'],'sample':1,'totalSamples':2,'device':'cpu','phase':'rendering'}),flush=True)
    acknowledged('progress-received')
    open(os.path.join(d,'frame.png'),'wb').write(base64.b64decode('\((data as Data).base64EncodedString())'))
    open(os.path.join(d,'linear.exr'),'wb').write(bytes([0x76,0x2f,0x31,0x01,0,0,0,0]))
    print(json.dumps({'type':'frame','jobID':m['jobID'],'framePath':'frame.png','sample':1}),flush=True)
    acknowledged('frame-received')
    print(json.dumps({'type':'completed','jobID':m['jobID'],'finalPNG':'frame.png','finalEXR':'linear.exr','sample':2,'device':'cpu','engineVersion':'protocol-test'}),flush=True)
    """
    let url=try helper(in:root,body:body),service=CyclesRenderService(helperURL:url)
    let job=try await service.start(snapshot:scene(),settings:.init(width:2,height:1,samples:2),outputDirectory:root)
    var sawProgress=false,sawFrame=false,sawCompletion=false
    for try await event in job.events {
      switch event {
      case .progress(let progress) where progress.sample==1:
        sawProgress=true;try Data().write(to:job.directory.appendingPathComponent("progress-received"))
      case .frame:
        sawFrame=true;try Data().write(to:job.directory.appendingPathComponent("frame-received"))
      case .completed:sawCompletion=true
      default:break
      }
    }
    XCTAssertTrue(sawProgress);XCTAssertTrue(sawFrame);XCTAssertTrue(sawCompletion)
  }
  func testAutomaticCPUFallbackIsLimitedToMetalInitializationBeforeSampling()async throws {
    let root=try temporary()
    let context=try XCTUnwrap(CGContext(data:nil,width:2,height:1,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    let image=try XCTUnwrap(context.makeImage()),data=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    for (index,device,category,sample,shouldRetry) in [
      (0,SceneRenderSettings.Device.auto,"metalInitialization",0,true),
      (1,.metal,"metalInitialization",0,false),
      (2,.auto,"scene",0,false),
      (3,.auto,"metalInitialization",1,false)
    ] {
      let attempts=root.appendingPathComponent("attempts-\(index)")
      let body="""
      m=json.load(open(sys.argv[2]))
      with open('\(attempts.path)','a') as f: f.write(m['device']+'\\n')
      if m['device'] != 'cpu':
          print(json.dumps({'type':'progress','device':'metal','sample':\(sample)}),flush=True)
          print(json.dumps({'type':'error','device':'metal','category':'\(category)','message':'Failed to compile library: test'}),flush=True)
          sys.exit(1)
      d=m['outputDirectory']
      open(os.path.join(d,'frame.png'),'wb').write(base64.b64decode('\((data as Data).base64EncodedString())'))
      open(os.path.join(d,'linear.exr'),'wb').write(bytes([0x76,0x2f,0x31,0x01,0,0,0,0]))
      print(json.dumps({'type':'completed','jobID':m['jobID'],'finalPNG':'frame.png','finalEXR':'linear.exr','sample':2,'device':'cpu','engineVersion':'protocol-test','denoiser':'none'}),flush=True)
      """
      let url=try helper(in:root,body:body),service=CyclesRenderService(helperURL:url)
      let job=try await service.start(snapshot:scene(),settings:.init(width:2,height:1,samples:2,device:device),outputDirectory:root)
      var completed:SceneRenderResult?
      do {for try await event in job.events {if case .completed(let result)=event {completed=result}};XCTAssertTrue(shouldRetry)}catch{XCTAssertFalse(shouldRetry)}
      let invocations=try String(contentsOf:attempts,encoding:.utf8).split(separator:"\n")
      XCTAssertEqual(invocations.count,shouldRetry ? 2:1)
      if shouldRetry {XCTAssertEqual(completed?.device,"cpu");XCTAssertNotNil(completed?.fallbackReason)}
    }
  }
  func testActualMetalInitializationFailureRetriesAutoOnceAndPreservesExplicitChoice()async throws {
    guard let path=ProcessInfo.processInfo.environment["LAB_CYCLES_TEST_INIT_FAILURE_HELPER"] else {throw XCTSkip("Set an isolated helper with intentionally failing Metal kernels to test device initialization recovery.")}
    let root=try temporary(),service=CyclesRenderService(helperURL:URL(fileURLWithPath:path))
    let capabilities=try await service.capabilities()
    guard capabilities.devices.contains(where:{$0.lowercased().contains("metal")}) else {throw XCTSkip("Metal hardware must be accessible for this recovery test.")}
    let job=try await service.start(snapshot:scene(),settings:.init(width:32,height:32,samples:2,denoise:false,device:.auto),outputDirectory:root)
    var result:SceneRenderResult?
    for try await event in job.events {if case .completed(let value)=event {result=value}}
    XCTAssertEqual(result?.device.lowercased(),"cpu");XCTAssertTrue(result?.fallbackReason?.contains("Metal initialization failed") == true)
    XCTAssertNotNil(result?.preparationSeconds);XCTAssertNotNil(result?.renderSeconds);XCTAssertEqual(result?.denoiser,"none")
    let explicit=try await service.start(snapshot:scene(),settings:.init(width:32,height:32,samples:2,denoise:false,device:.metal),outputDirectory:root)
    do {for try await _ in explicit.events {};XCTFail("An explicit Metal selection must report its initialization failure.")}catch {XCTAssertTrue(error.localizedDescription.contains("compile library"),error.localizedDescription)}
  }
  /// Opt-in packaged-engine test. Lifecycle tests above use a protocol fixture;
  /// this gate requires actual Cycles and inspects its rendered pixels.
  func testBundledCyclesProducesRealProgressiveSurfaceAndCurvePixels()async throws {
    guard let path=ProcessInfo.processInfo.environment["LAB_CYCLES_TEST_HELPER"] else{throw XCTSkip("Set LAB_CYCLES_TEST_HELPER to the installed native helper for engine integration.")}
    let root=try temporary(),service=CyclesRenderService(helperURL:URL(fileURLWithPath:path))
    let capabilities=try await service.capabilities();XCTAssertFalse(capabilities.devices.isEmpty)
    var snapshot=scene();snapshot.camera = .looking(from:.init(50,35,300),at:.init(50,35,0),projection:.orthographic(verticalSpanMM:150))
    snapshot.renderables[0].materials[0].baseColor = .init(0.8,0.1,0.1,1)
    snapshot.environment = .init(color:.init(repeating:0.6),strength:1)
    snapshot.curves=[.init(id:"physical-thread",revision:"1",objectID:UUID(),pointsMM:[.init(20,20,2),.init(25,25,8),.init(35,25,8),.init(40,20,2)],radiiMM:[1,1,1,1],firstKey:[0],material:.init(id:"thread",baseColor:.init(0.1,0.8,0.1,1)))]
    let job=try await service.start(snapshot:snapshot,settings:.init(width:128,height:128,samples:16,denoise:false,device:.cpu),outputDirectory:root)
    var result:CyclesRenderResult?,frames=0
    for try await event in job.events {switch event {case .frame:frames+=1;case .completed(let value):result=value;case .progress:break}}
    let final=try XCTUnwrap(result);XCTAssertGreaterThan(frames,0);XCTAssertEqual(final.width,128)
    let image=try XCTUnwrap(CGImageSourceCreateWithURL(final.pngURL as CFURL,nil)).flatImage()
    let color=try XCTUnwrap(NSBitmapImageRep(cgImage:image).colorAt(x:64,y:64)?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(color.redComponent,color.greenComponent+0.05)
    XCTAssertGreaterThan((try final.exrURL.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0,1024)
  }
  func testBundledCyclesArtworkAlphaOverPreservesPrintedColor()async throws {
    guard let path=ProcessInfo.processInfo.environment["LAB_CYCLES_TEST_HELPER"] else{throw XCTSkip("Set LAB_CYCLES_TEST_HELPER to exercise native shader composition.")}
    let root=try temporary(),service=CyclesRenderService(helperURL:URL(fileURLWithPath:path))
    let bytes:[UInt8]=[255,0,0,255,0,0,0,0],provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
    let image=try XCTUnwrap(CGImage(width:2,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    var material=SceneMaterialPayload(id:"blue substrate",baseColor:.init(0,0,1,1),unlit:true)
    material.artworkTexture = .init(image:image,revision:"red print",wrapS:.clamp,wrapT:.clamp,encoding:.srgb)
    let mesh=SceneMeshPayload(id:"quad",revision:"1",positionsMM:[.init(-50,-50,0),.init(50,-50,0),.init(50,50,0),.init(-50,50,0)],normals:Array(repeating:.init(0,0,1),count:4),uvs:[.init(0,1),.init(1,1),.init(1,0),.init(0,0)],parts:[.init(triangleIndices:[0,1,2,0,2,3])])
    let snapshot=SceneSnapshot(revision:"print-over-substrate",renderables:[.init(componentID:"face",objectID:UUID(),mesh:mesh,materials:[material])],camera:.looking(from:.init(0,0,300),at:.zero,projection:.orthographic(verticalSpanMM:120)))
    let job=try await service.start(snapshot:snapshot,settings:.init(width:128,height:128,samples:8,denoise:false,device:.cpu),outputDirectory:root)
    var output:CyclesRenderResult?
    for try await event in job.events {if case .completed(let result)=event {output=result}}
    let result=try XCTUnwrap(output),pixels=try XCTUnwrap(CGImageSourceCreateWithURL(result.pngURL as CFURL,nil)).flatImage(),rep=NSBitmapImageRep(cgImage:pixels)
    let printed=try XCTUnwrap(rep.colorAt(x:30,y:64)?.usingColorSpace(.sRGB)),bare=try XCTUnwrap(rep.colorAt(x:98,y:64)?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(printed.redComponent,0.8);XCTAssertLessThan(printed.blueComponent,0.1)
    XCTAssertGreaterThan(bare.blueComponent,0.8);XCTAssertLessThan(bare.redComponent,0.1)
  }
  func testBundledCyclesIntegerAndFloatingTexturesKeepTheSameTopRow()async throws {
    guard let path=ProcessInfo.processInfo.environment["LAB_CYCLES_TEST_HELPER"] else{throw XCTSkip("Set LAB_CYCLES_TEST_HELPER to verify texture row order through actual Cycles.")}
    let root=try temporary(),service=CyclesRenderService(helperURL:URL(fileURLWithPath:path))
    let words:[UInt16]=[64*257,64*257,192*257,192*257]
    let grayProvider=try XCTUnwrap(CGDataProvider(data:words.withUnsafeBytes{Data($0)} as CFData))
    let gray=try XCTUnwrap(CGImage(width:2,height:2,bitsPerComponent:16,bitsPerPixel:16,bytesPerRow:4,
      space:CGColorSpace(name:CGColorSpace.genericGrayGamma2_2)!,bitmapInfo:[.byteOrder16Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue)],
      provider:grayProvider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let rgba:[UInt8]=[64,64,64,255,64,64,64,255,192,192,192,255,192,192,192,255]
    let provider=try XCTUnwrap(CGDataProvider(data:Data(rgba) as CFData))
    let rgb=try XCTUnwrap(CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.last.rawValue),
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let mesh=SceneMeshPayload(id:"two-row-panel",revision:"1",positionsMM:[.init(-50,-50,0),.init(50,-50,0),.init(50,50,0),.init(-50,50,0)],
      normals:Array(repeating:.init(0,0,1),count:4),uvs:[.init(0,1),.init(1,1),.init(1,0),.init(0,0)],parts:[.init(triangleIndices:[0,1,2,0,2,3])])
    var rows=[[CGFloat]]()
    for (index,image) in [rgb,gray].enumerated() {
      var material=SceneMaterialPayload(id:"numeric-pattern",baseColor:.init(repeating:1),unlit:true)
      material.baseColorTexture = .init(image:image,revision:"row-pattern-\(index)",wrapS:.clamp,wrapT:.clamp,encoding:.data)
      let snapshot=SceneSnapshot(revision:"format-comparison-\(index)",renderables:[.init(componentID:"face",objectID:UUID(),mesh:mesh,materials:[material])],
        camera:.looking(from:.init(0,0,300),at:.zero,projection:.orthographic(verticalSpanMM:120)))
      let job=try await service.start(snapshot:snapshot,settings:.init(width:128,height:128,samples:8,denoise:false,device:.cpu),outputDirectory:root)
      var output:CyclesRenderResult?
      for try await event in job.events {if case .completed(let result)=event {output=result}}
      let result=try XCTUnwrap(output),renderedImage=try XCTUnwrap(CGImageSourceCreateWithURL(result.pngURL as CFURL,nil)).flatImage(),bitmap=NSBitmapImageRep(cgImage:renderedImage)
      rows.append(try [30,98].map{try XCTUnwrap(bitmap.colorAt(x:64,y:$0)?.usingColorSpace(.sRGB)).redComponent})
    }
    XCTAssertLessThan(rows[0][0],rows[0][1]-0.2,"The source's dark top row must remain above its light bottom row.")
    for row in 0..<2 {XCTAssertEqual(rows[0][row],rows[1][row],accuracy:0.005,"Changing component precision must preserve orientation and numeric encoding.")}
  }
  func testBundledCyclesDeclaredSRGBMatchesAcrossPrecisionAndEmbeddedProfiles()async throws {
    guard let path=ProcessInfo.processInfo.environment["LAB_CYCLES_TEST_HELPER"] else{throw XCTSkip("Set LAB_CYCLES_TEST_HELPER to verify declared encoding across texture precisions.")}
    let root=try temporary(),service=CyclesRenderService(helperURL:URL(fileURLWithPath:path))
    let mesh=SceneMeshPayload(id:"constant-surface",revision:"1",positionsMM:[.init(-100,-100,0),.init(100,-100,0),.init(0,100,0)],parts:[.init(triangleIndices:[0,1,2])])
    for monochrome in [false,true] {
      var colors=[[CGFloat]]()
      for depth in [8,16] {
        let bytes:Data
        if depth==8 {bytes=Data(monochrome ? [128]:[204,102,51,255])}
        else {let words:[UInt16]=monochrome ? [128*257]:[52428,26214,13107,65535];bytes=words.withUnsafeBytes{Data($0)}}
        let components=monochrome ? 1:4
        let space=CGColorSpace(name:monochrome ? CGColorSpace.genericGrayGamma2_2:CGColorSpace.displayP3)!
        let order=depth==16 ? CGBitmapInfo.byteOrder16Little.rawValue:(monochrome ? 0:CGBitmapInfo.byteOrder32Big.rawValue)
        let alpha=monochrome ? CGImageAlphaInfo.none:CGImageAlphaInfo.premultipliedLast
        let provider=try XCTUnwrap(CGDataProvider(data:bytes as CFData))
        let image=try XCTUnwrap(CGImage(width:1,height:1,bitsPerComponent:depth,bitsPerPixel:depth*components,bytesPerRow:depth/8*components,
          space:space,bitmapInfo:.init(rawValue:order|alpha.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        var material=SceneMaterialPayload(id:"declared-srgb",baseColor:.init(repeating:1),unlit:true)
        material.baseColorTexture = .init(image:image,revision:"\(monochrome)-\(depth)",encoding:.srgb)
        let snapshot=SceneSnapshot(revision:"precision-\(monochrome)-\(depth)",renderables:[.init(componentID:"surface",objectID:UUID(),mesh:mesh,materials:[material])],
          camera:.looking(from:.init(0,0,300),at:.zero,projection:.orthographic(verticalSpanMM:20)))
        let job=try await service.start(snapshot:snapshot,settings:.init(width:16,height:16,samples:8,denoise:false,device:.cpu),outputDirectory:root)
        var output:CyclesRenderResult?
        for try await event in job.events {if case .completed(let result)=event {output=result}}
        let result=try XCTUnwrap(output),rendered=try XCTUnwrap(CGImageSourceCreateWithURL(result.pngURL as CFURL,nil)).flatImage()
        // Inspect encoded PNG samples directly. NSBitmapImageRep.colorAt can
        // assign calibrated RGB and apply another transfer on conversion.
        let numericSpace=CGColorSpace(name:CGColorSpace.linearSRGB)!
        let numeric=try XCTUnwrap(rendered.copy(colorSpace:numericSpace))
        let bitmap=try XCTUnwrap(CGContext(data:nil,width:rendered.width,height:rendered.height,bitsPerComponent:8,bytesPerRow:rendered.width*4,
          space:numericSpace,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(numeric,in:CGRect(x:0,y:0,width:rendered.width,height:rendered.height))
        let samples=try XCTUnwrap(bitmap.data).assumingMemoryBound(to:UInt8.self),offset=(8*rendered.width+8)*4
        XCTAssertEqual(samples[offset+3],255)
        colors.append((0..<3).map{CGFloat(samples[offset+$0])/255})
      }
      let expected:[CGFloat]=monochrome ? Array(repeating:128/255,count:3):[0.8,0.4,0.2]
      for channel in 0..<3 {
        XCTAssertEqual(colors[0][channel],expected[channel],accuracy:1.1/255)
        XCTAssertEqual(colors[1][channel],expected[channel],accuracy:1.1/255)
        XCTAssertEqual(colors[0][channel],colors[1][channel],accuracy:1.1/255,"Declared encoding must override embedded profiles at both precisions.")
      }
    }
  }
}

private extension CGImageSource {
  func flatImage()throws->CGImage {try XCTUnwrap(CGImageSourceCreateImageAtIndex(self,0,nil))}
}

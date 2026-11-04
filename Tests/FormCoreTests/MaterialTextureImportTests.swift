import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import FormCore

final class MaterialTextureImportTests:XCTestCase {
  private func fixture()throws->OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("material-texture-"+UUID().uuidString)
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=Project(name:"Texture import")
    addTeardownBlock {try? FileManager.default.removeItem(at:root)};return engine
  }
  private func image(width:Int,height:Int,bits:Int=8,components:Int=1,values:[Float],floating:Bool=false,straightAlpha:Bool=false)throws->CGImage {
    let bytesPerComponent=bits/8
    var bytes=Data(count:width*height*components*bytesPerComponent)
    bytes.withUnsafeMutableBytes { raw in
      for index in 0..<(width*height*components) {
        let value=values[index%values.count],offset=index*bytesPerComponent
        if floating {raw.storeBytes(of:value.bitPattern.littleEndian,toByteOffset:offset,as:UInt32.self)}
        else if bits==16 {raw.storeBytes(of:UInt16(value).littleEndian,toByteOffset:offset,as:UInt16.self)}
        else {raw[offset]=UInt8(value)}
      }
    }
    let alpha:CGImageAlphaInfo=components==4 ? (straightAlpha ? .last:.premultipliedLast):.none
    var info=CGBitmapInfo(rawValue:alpha.rawValue)
    if bits==16 {info.insert(.byteOrder16Little)}
    if floating {info.formUnion([.floatComponents,.byteOrder32Little])}
    let space=CGColorSpace(name:components==1 ? CGColorSpace.genericGrayGamma2_2:(floating ? CGColorSpace.extendedLinearSRGB:CGColorSpace.sRGB))!
    return try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:bits,bitsPerPixel:bits*components,bytesPerRow:width*components*bytesPerComponent,space:space,bitmapInfo:info,provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
  }
  private func write(_ image:CGImage,to url:URL)throws {
    let type=url.pathExtension=="tiff" ? "public.tiff":"public.png"
    let writer=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,type as CFString,1,nil))
    CGImageDestinationAddImage(writer,image,nil);XCTAssertTrue(CGImageDestinationFinalize(writer))
  }
  private func decode(_ url:URL)throws->CGImage {
    let source=try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
  }
  private func imported(_ engine:OperationEngine,path:URL,maximum:Int?,encoding:String="data")throws->([String:Any],URL) {
    var args:[String:Any]=["command":"import_texture","path":path.path,"color_space":encoding]
    if let maximum {args["max_dimension"]=maximum}
    let response=try engine.call("form_material",arguments:args)
    let result=try XCTUnwrap(response as? [String:Any])
    let reference=try XCTUnwrap(result["texture"] as? [String:Any]),name=try XCTUnwrap(reference["asset"] as? String)
    return (result,engine.repository.url(for:engine.project!.id).appendingPathComponent("Assets").appendingPathComponent(name))
  }
  /// Read encoded components without drawing or applying a color transform.
  private func sample(_ image:CGImage,x:Int=0,y:Int=0,component:Int=0)throws->Float {
    let bytes=try XCTUnwrap(image.dataProvider?.data) as Data,componentBytes=image.bitsPerComponent/8
    let offset=y*image.bytesPerRow+(x*(image.bitsPerPixel/image.bitsPerComponent)+component)*componentBytes
    let order=image.bitmapInfo.intersection(.byteOrderMask),big=order == .byteOrder16Big || order == .byteOrder32Big
    return bytes.withUnsafeBytes { raw in
      if componentBytes==1 {return Float(raw[offset])}
      if componentBytes==2 {let word=raw.loadUnaligned(fromByteOffset:offset,as:UInt16.self);return Float(big ? UInt16(bigEndian:word):UInt16(littleEndian:word))}
      let word=raw.loadUnaligned(fromByteOffset:offset,as:UInt32.self);return Float(bitPattern:big ? UInt32(bigEndian:word):UInt32(littleEndian:word))
    }
  }

  func testDefaultImportKeepsExactOriginalBytesAndNoProjectEdit()throws {
    let engine=try fixture(),before=engine.project!,path=engine.repository.root.appendingPathComponent("source.png")
    try write(image(width:9,height:3,values:[64,128,192]),to:path)
    let original=try Data(contentsOf:path),(result,target)=try imported(engine,path:path,maximum:nil)
    XCTAssertEqual(try Data(contentsOf:target),original);XCTAssertEqual(try Data(contentsOf:path),original)
    XCTAssertEqual((result["resampling"] as? [String:Any])?["applied"] as? Bool,false)
    XCTAssertEqual(engine.project,before);XCTAssertTrue(engine.undoStack.isEmpty)
    let (_,noUpscale)=try imported(engine,path:path,maximum:100)
    XCTAssertEqual(noUpscale,target)
  }
  func testAspectRatioContentAddressingAndSourceProvenance()throws {
    let engine=try fixture(),path=engine.repository.root.appendingPathComponent("source.png")
    try write(image(width:12,height:8,values:[20,80,140,200]),to:path)
    let original=try Data(contentsOf:path),(result,target)=try imported(engine,path:path,maximum:6)
    XCTAssertEqual(result["width"] as? Int,6);XCTAssertEqual(result["height"] as? Int,4)
    let originalRecord=try XCTUnwrap(result["original"] as? [String:Any]),derived=try XCTUnwrap(result["derived"] as? [String:Any])
    XCTAssertEqual(originalRecord["width"] as? Int,12);XCTAssertEqual(originalRecord["height"] as? Int,8)
    XCTAssertEqual(originalRecord["sha256"] as? String,SHA256.hash(data:original).map{String(format:"%02x",$0)}.joined())
    XCTAssertNotEqual(originalRecord["sha256"] as? String,derived["sha256"] as? String)
    XCTAssertEqual(try Data(contentsOf:path),original)
    let (_,again)=try imported(engine,path:path,maximum:6);XCTAssertEqual(target,again)
    let fitted=try MaterialTextureResampler.dimensions(width:4096,height:4099,maximum:4096)
    XCTAssertEqual(fitted.0,4093);XCTAssertEqual(fitted.1,4096);XCTAssertLessThanOrEqual(fitted.0*fitted.1,16_777_216)
  }
  func testSixteenBitGrayResamplingPreservesNumericMidpointAndPrecision()throws {
    let engine=try fixture(),path=engine.repository.root.appendingPathComponent("gray16.png")
    try write(image(width:2,height:2,bits:16,values:[16384,49152]),to:path)
    let (result,target)=try imported(engine,path:path,maximum:1),decoded=try decode(target)
    XCTAssertEqual(decoded.bitsPerComponent,16);XCTAssertEqual(decoded.colorSpace?.model,.monochrome)
    XCTAssertEqual(try sample(decoded),32768,accuracy:1,"Numeric averaging must not apply the image's gamma-2.2 color transform.")
    XCTAssertEqual((result["derived"] as? [String:Any])?["bits_per_component"] as? Int,16)
    // A value not representable in 8 bits must survive a constant image exactly.
    try write(image(width:4,height:2,bits:16,values:[12345]),to:path)
    let (_,constant)=try imported(engine,path:path,maximum:2)
    XCTAssertEqual(try sample(decode(constant)),12345)
  }
  func testSRGBColorChannelsAndRowOrientationStayUnchanged()throws {
    let engine=try fixture(),path=engine.repository.root.appendingPathComponent("color.png")
    try write(image(width:4,height:2,components:3,values:[64,128,192]),to:path)
    let (result,target)=try imported(engine,path:path,maximum:2,encoding:"srgb"),decoded=try decode(target)
    XCTAssertEqual((result["texture"] as? [String:Any])?["colorSpace"] as? String,"srgb")
    XCTAssertEqual(decoded.bitsPerComponent,8)
    for (component,value) in [64,128,192].enumerated() {XCTAssertEqual(try sample(decoded,component:component),Float(value),accuracy:1)}
    let rows=try image(width:4,height:4,values:Array(repeating:Float(20),count:8)+Array(repeating:Float(220),count:8))
    let resized=try MaterialTextureResampler.resize(rows,width:2,height:2)
    let source=try XCTUnwrap(CGImageSourceCreateWithData(resized.bytes as CFData,nil)),output=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
    XCTAssertLessThan(try sample(output,y:0),try sample(output,y:1),"Resampling must not vertically flip the texture.")
  }
  func testColorFiltersInLinearLightAndDoesNotLeakHiddenTransparentRGB()throws {
    let engine=try fixture(),path=engine.repository.root.appendingPathComponent("color.png")
    try write(image(width:2,height:2,components:3,values:[0,0,0,255,255,255]),to:path)
    let (_,target)=try imported(engine,path:path,maximum:1,encoding:"srgb")
    XCTAssertEqual(try sample(decode(target)),188,accuracy:1,"Half linear radiance encodes around 188, not 128, in sRGB.")
    try write(image(width:2,height:2,components:4,values:[255,0,0,255,0,0,255,0],straightAlpha:true),to:path)
    let (_,alphaTarget)=try imported(engine,path:path,maximum:1,encoding:"srgb"),decoded=try decode(alphaTarget)
    XCTAssertEqual(try sample(decoded,component:0),255,accuracy:1)
    XCTAssertEqual(try sample(decoded,component:2),0,accuracy:1,"Invisible blue must not tint the filtered opaque red edge.")
    XCTAssertEqual(try sample(decoded,component:3),128,accuracy:1)
  }
  func testBigEndianSixteenBitAndPaddedBGRAChannels()throws {
    let words:[UInt16]=Array(repeating:UInt16(12345).bigEndian,count:8)
    let gray=try XCTUnwrap(CGImage(width:4,height:2,bitsPerComponent:16,bitsPerPixel:16,bytesPerRow:8,
      space:CGColorSpace(name:CGColorSpace.genericGrayGamma2_2)!,bitmapInfo:[.byteOrder16Big,CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue)],
      provider:CGDataProvider(data:words.withUnsafeBytes{Data($0)} as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let resized=try MaterialTextureResampler.resize(gray,width:2,height:1)
    let decoded=try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(resized.bytes as CFData,nil)!,0,nil))
    XCTAssertEqual(try sample(decoded),12345)
    var pixels=Data(count:24*2)
    for y in 0..<2 {for x in 0..<4 {let offset=y*24+x*4;pixels[offset]=192;pixels[offset+1]=128;pixels[offset+2]=64;pixels[offset+3]=255}}
    let bgra=try XCTUnwrap(CGImage(width:4,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:24,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],
      provider:CGDataProvider(data:pixels as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let output=try MaterialTextureResampler.resize(bgra,width:2,height:1,encoding:.srgb)
    let rgb=try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(output.bytes as CFData,nil)!,0,nil))
    XCTAssertEqual(rgb.width,2);XCTAssertEqual(rgb.height,1);XCTAssertEqual(rgb.bitsPerComponent,8)
    for (component,value) in [64,128,192].enumerated() {XCTAssertEqual(try sample(rgb,component:component),Float(value),accuracy:1)}
  }
  func testFloatingPointResamplingRetainsHDRRangeOrExplicitlyRejectsEncoder()throws {
    let input=try image(width:4,height:2,bits:32,components:4,values:[4,2,0.125,1],floating:true)
    do {
      let result=try MaterialTextureResampler.resize(input,width:2,height:1)
      XCTAssertEqual(result.fileExtension,"tiff");XCTAssertTrue(result.floatingPoint);XCTAssertEqual(result.bitsPerComponent,32)
      let source=try XCTUnwrap(CGImageSourceCreateWithData(result.bytes as CFData,nil)),output=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
      XCTAssertEqual(output.bitsPerComponent,32);XCTAssertTrue(output.bitmapInfo.contains(.floatComponents))
      XCTAssertEqual(try sample(output),4,accuracy:0.00001);XCTAssertEqual(try sample(output,component:2),0.125,accuracy:0.00001)
    }catch {
      // ImageIO encoder availability is platform-specific. A reported unsupported
      // conversion is valid; a silently clipped or 8-bit HDR asset never is.
      XCTAssertTrue(String(describing:error).contains("unsupported") || String(describing:error).contains("losslessly"),String(describing:error))
    }
  }
  func testBudgetsAndInvalidOptionsRejectBeforeCreatingAssets()throws {
    let engine=try fixture(),path=engine.repository.root.appendingPathComponent("wide.png")
    try write(image(width:8193,height:1,values:[128]),to:path)
    XCTAssertThrowsError(try imported(engine,path:path,maximum:4096))
    XCTAssertThrowsError(try MaterialTextureResampler.dimensions(width:8192,height:4097,maximum:4096))
    let invalid:[Any]=[0,4097,1.5,true,"2048",NSNull()]
    for value in invalid {
      XCTAssertThrowsError(try engine.call("form_material",arguments:["command":"import_texture","path":path.path,"max_dimension":value]))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath:engine.repository.url(for:engine.project!.id).appendingPathComponent("Assets").path))
    let schema=try XCTUnwrap(MCP.tools.first{($0["name"] as? String)=="form_material"}?["inputSchema"] as? [String:Any])
    let properties=try XCTUnwrap(schema["properties"] as? [String:Any]),maximum=try XCTUnwrap(properties["max_dimension"] as? [String:Any])
    XCTAssertEqual(maximum["maximum"] as? Int,4096)
  }
  func testCorruptedDerivedAssetIsNotOverwrittenAndFailedConversionAddsNothing()throws {
    let engine=try fixture(),path=engine.repository.root.appendingPathComponent("source.png")
    try write(image(width:4,height:2,values:[64]),to:path)
    let (_,target)=try imported(engine,path:path,maximum:2),corrupt=Data("corrupted derived asset".utf8)
    try corrupt.write(to:target)
    XCTAssertThrowsError(try imported(engine,path:path,maximum:2));XCTAssertEqual(try Data(contentsOf:target),corrupt)
    let other=try fixture(),unsupported=other.repository.root.appendingPathComponent("indexed.png")
    // A valid 1-bit source remains eligible for exact-byte import, but the
    // opt-in resampler must explicitly reject unsupported component precision.
    let data=Data([0xAA,0x55]),space=CGColorSpaceCreateDeviceGray()
    let oneBit=try XCTUnwrap(CGImage(width:8,height:2,bitsPerComponent:1,bitsPerPixel:1,bytesPerRow:1,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    try write(oneBit,to:unsupported)
    // Some ImageIO decoders promote 1-bit PNG to 8-bit. Only expect rejection
    // when the decoder actually exposes the unsupported source layout.
    if try decode(unsupported).bitsPerComponent==1 {
      XCTAssertThrowsError(try imported(other,path:unsupported,maximum:2))
      XCTAssertFalse(FileManager.default.fileExists(atPath:other.repository.url(for:other.project!.id).appendingPathComponent("Assets").path))
    } else {
      XCTAssertThrowsError(try MaterialTextureResampler.resize(oneBit,width:2,height:1))
    }
  }
}

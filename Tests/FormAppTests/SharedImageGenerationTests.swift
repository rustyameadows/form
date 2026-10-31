import AppKit
import ImageIO
import XCTest
import FormCore
@testable import FormApp

@MainActor final class SharedImageGenerationTests:XCTestCase {
  private func png(_ color:NSColor)throws->Data {
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:48,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    let context=try XCTUnwrap(NSGraphicsContext(bitmapImageRep:bitmap))
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
    color.setFill();CGRect(x:0,y:0,width:64,height:48).fill();NSGraphicsContext.restoreGraphicsState()
    return try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
  }
  private func request(prompt:String="A quiet geometric landscape",references:[StudioGenerationReference]=[],images:[StudioGenerationReferenceImage]=[],failure:StudioGenerationFailureFixture = .none)->StudioGenerationRequest {
    var options=StudioImageGenerationOptions();options.size = .small;options.failureFixture=failure
    return .init(prompt:prompt,style:"Warm restrained colors",references:references,options:options,source:.canvas,referenceImages:images)
  }
  private func metadata(_ data:Data)throws->[CFString:Any] {
    let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
    let properties=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
    return try XCTUnwrap(properties[kCGImagePropertyPNGDictionary] as? [CFString:Any])
  }
  func testCanvasPromptOnlyNeedsNoSceneAndProducesDeterministicExplicitDemoPNG()async throws {
    let provider=LocalStudioImageGenerationProvider(delayNanoseconds:0),value=request()
    XCTAssertNil(value.inputPNG);XCTAssertNil(value.context)
    var progress:[Double]=[]
    let first=try await provider.generate(value){progress.append($0)}
    let second=try await provider.generate(value,progress:{_ in})
    XCTAssertEqual(first,second);XCTAssertEqual(first.count,1)
    let data=try XCTUnwrap(first.first),bitmap=try XCTUnwrap(NSBitmapImageRep(data:data))
    XCTAssertEqual(bitmap.pixelsWide,512);XCTAssertEqual(bitmap.pixelsHigh,341)
    let properties=try metadata(data)
    XCTAssertEqual(properties[kCGImagePropertyPNGTitle] as? String,"LOCAL DEMO")
    XCTAssertEqual(properties[kCGImagePropertyPNGDescription] as? String,"Sample artwork · no AI request")
    XCTAssertEqual(progress.last,1);XCTAssertEqual(progress,progress.sorted())
    XCTAssertTrue(StudioGenerationConfigurationRegistry.models.allSatisfy{$0.title.contains("Local demo")})
    XCTAssertEqual(StudioGenerationModel.sunburst.rawValue,"gpt-image-2.5-sunburst","Historical configuration keys remain decodable")
  }
  func testFrozenReferencesAffectVisibleCollageWithoutAStudioCapture()async throws {
    let id=UUID(),descriptor=StudioGenerationReference(assetID:id,role:.subject)
    let red=try png(.red),blue=try png(.blue),provider=LocalStudioImageGenerationProvider(delayNanoseconds:0)
    let redRequest=request(references:[descriptor],images:[.init(assetID:id,name:"Selected artwork",png:red)])
    let blueRequest=request(references:[descriptor],images:[.init(assetID:id,name:"Selected artwork",png:blue)])
    let redOutput=try await provider.generate(redRequest,progress:{_ in})
    let blueOutput=try await provider.generate(blueRequest,progress:{_ in})
    let a=try XCTUnwrap(redOutput.first),b=try XCTUnwrap(blueOutput.first)
    XCTAssertNotEqual(a,b)
    let redBitmap=try XCTUnwrap(NSBitmapImageRep(data:a)),blueBitmap=try XCTUnwrap(NSBitmapImageRep(data:b))
    let redCenter=try XCTUnwrap(redBitmap.colorAt(x:redBitmap.pixelsWide/2,y:redBitmap.pixelsHigh/2)?.usingColorSpace(.sRGB))
    let blueCenter=try XCTUnwrap(blueBitmap.colorAt(x:blueBitmap.pixelsWide/2,y:blueBitmap.pixelsHigh/2)?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(redCenter.redComponent,0.9);XCTAssertLessThan(redCenter.blueComponent,0.1)
    XCTAssertGreaterThan(blueCenter.blueComponent,0.9);XCTAssertLessThan(blueCenter.redComponent,0.1)
    XCTAssertEqual(try metadata(a)[kCGImagePropertyPNGDescription] as? String,"Reference collage · no AI request")
    XCTAssertNil(redRequest.inputPNG);XCTAssertNil(redRequest.context)
  }
  func testReferenceNameAcceptsFullCanvasUnicodeLimitAndRejectsOneCharacterBeyondIt()async throws {
    let name=String(repeating:"🎨",count:500),id=UUID(),image=try png(.orange)
    XCTAssertEqual(name.utf8.count,2000)
    let descriptor=StudioGenerationReference(assetID:id,role:.style),provider=LocalStudioImageGenerationProvider(delayNanoseconds:0)
    let accepted=request(references:[descriptor],images:[.init(assetID:id,name:name,png:image)])
    let output=try await provider.generate(accepted,progress:{_ in})
    XCTAssertEqual(output.count,1)
    let rejected=request(references:[descriptor],images:[.init(assetID:id,name:name+"🎨",png:image)])
    do {_ = try await provider.generate(rejected,progress:{_ in});XCTFail("An over-limit reference label was accepted")}
    catch {XCTAssertTrue(error is StudioGenerationError)}
  }
  func testEighthReferencePixelsRemainVisibleInTheAcceptedEightImageCollage()async throws {
    let descriptors=(0..<8).map{_ in StudioGenerationReference(assetID:UUID(),role:.composition)}
    let neutral=try png(.white),red=try png(.red),blue=try png(.blue)
    func images(last:Data)->[StudioGenerationReferenceImage] {
      descriptors.enumerated().map{index,value in
        .init(assetID:value.assetID,name:"Reference \(index+1)",png:index==7 ? last:neutral)
      }
    }
    let provider=LocalStudioImageGenerationProvider(delayNanoseconds:0)
    let redOutput=try await provider.generate(request(references:descriptors,images:images(last:red)),progress:{_ in})
    let blueOutput=try await provider.generate(request(references:descriptors,images:images(last:blue)),progress:{_ in})
    let a=try XCTUnwrap(redOutput.first),b=try XCTUnwrap(blueOutput.first)
    XCTAssertNotEqual(a,b,"Only the eighth reference's bytes changed; descriptors and the demo seed are identical.")
    func pixels(_ data:Data)throws->(width:Int,height:Int,rgba:[UInt8]) {
      let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
      let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
      let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
      var rgba=[UInt8](repeating:0,count:image.width*image.height*4)
      try rgba.withUnsafeMutableBytes { buffer in
        let context=try XCTUnwrap(CGContext(data:buffer.baseAddress,width:image.width,height:image.height,
          bitsPerComponent:8,bytesPerRow:image.width*4,space:space,
          bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy);context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
      }
      return(image.width,image.height,rgba)
    }
    let first=try pixels(a),second=try pixels(b)
    XCTAssertEqual(first.width,second.width);XCTAssertEqual(first.height,second.height)
    var changed=0,minX=first.width,maxX=0,minY=first.height,maxY=0
    for y in 0..<first.height {for x in 0..<first.width {
      let offset=(y*first.width+x)*4
      guard first.rgba[offset+3]>230,second.rgba[offset+3]>230,
        (0..<3).contains(where:{abs(Int(first.rgba[offset+$0])-Int(second.rgba[offset+$0]))>32}) else{continue}
      changed+=1;minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y)
    }}
    XCTAssertGreaterThan(changed,100,"The eighth reference must change visible decoded pixels, not only PNG metadata.")
    XCTAssertLessThan(changed,first.width*first.height/10,"Only one reference tile changes.")
    XCTAssertLessThan(maxX-minX,first.width/3);XCTAssertLessThan(maxY-minY,first.height/3)
    XCTAssertGreaterThan(minX,first.width/3);XCTAssertLessThan(maxX,first.width*2/3,"The eighth tile is in the middle column.")
  }
  func testMissingDuplicateMalformedAndOversizedReferenceInputsFailBeforeProgress()async throws {
    let id=UUID(),valid=try png(.green),descriptor=StudioGenerationReference(assetID:id,role:.composition)
    let values=[
      request(references:[descriptor]),
      request(images:[.init(assetID:id,name:"Unmatched",png:valid)]),
      request(references:[descriptor,descriptor],images:[.init(assetID:id,name:"Duplicated",png:valid)]),
      request(references:[descriptor],images:[.init(assetID:id,name:"Malformed",png:Data("not a PNG".utf8))]),
      request(references:[descriptor],images:[.init(assetID:id,name:"Oversized",png:Data(count:StudioGenerationDemoRenderer.maximumImageBytes+1))]),
      request(prompt:"   "),request(prompt:String(repeating:"x",count:8001))]
    let provider=LocalStudioImageGenerationProvider(delayNanoseconds:0)
    for value in values {
      var progressed=false
      do {_ = try await provider.generate(value){_ in progressed=true};XCTFail("Invalid input was accepted")}
      catch {XCTAssertTrue(error is StudioGenerationError)}
      XCTAssertFalse(progressed)
    }
  }
  func testEachDemoFailureAndCancellationReturnsNoImages()async throws {
    let provider=LocalStudioImageGenerationProvider(delayNanoseconds:0)
    for failure in [StudioGenerationFailureFixture.authentication,.rateLimit,.offline,.refused] {
      do {_ = try await provider.generate(request(failure:failure),progress:{_ in});XCTFail("Expected fixture failure")}
      catch StudioGenerationError.fixture(let actual) {XCTAssertEqual(actual,failure)}
    }
    let delayed=LocalStudioImageGenerationProvider(delayNanoseconds:1_000_000_000),value=request()
    let work=Task{try await delayed.generate(value,progress:{_ in})}
    await Task.yield();work.cancel()
    do {_ = try await work.value;XCTFail("Cancelled local demo returned images")}
    catch {XCTAssertTrue(error is CancellationError)}
  }
  func testCanvasAndStudioRequestsCannotAccidentallyImpersonateEachOther()async throws {
    let provider=LocalStudioImageGenerationProvider(delayNanoseconds:0),image=try png(.white)
    let canvas=StudioGenerationRequest(inputPNG:image,prompt:"Draft",style:"",references:[],options:.init(),source:.canvas)
    let scene=StudioGenerationRequest(prompt:"Draft",style:"",references:[],options:.init())
    for value in [canvas,scene] {
      do {_ = try await provider.generate(value,progress:{_ in});XCTFail("Wrong input source was accepted")}
      catch {XCTAssertTrue(error is StudioGenerationError)}
    }
  }
  func testPromptLibraryIsSharedProjectScopedAndPreservesConcurrentSurfaceSaves()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("shared-generation-prompts-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let id=UUID(),canvas=ImageGenerationPromptLibrary(root:root,projectID:id),studio=ImageGenerationPromptLibrary(root:root,projectID:id)
    let first=try canvas.save(name:"Quiet geometry",prompt:"A warm abstract landscape")
    XCTAssertEqual(studio.savedPresets,[first],"Already-open Studio/Canvas snapshots receive project-specific changes")
    let second=try studio.save(name:"Product light",prompt:"Soft studio lighting")
    XCTAssertEqual(canvas.savedPresets,[first,second]);XCTAssertNil(canvas.error)
    let bytes=try Data(contentsOf:canvas.file),foreign=ImageGenerationPromptLibrary(root:root,projectID:UUID())
    XCTAssertTrue(foreign.savedPresets.isEmpty)
    try foreign.save(name:"Foreign",prompt:"Different project")
    XCTAssertEqual(try Data(contentsOf:canvas.file),bytes)
    try canvas.remove(id:first.id);XCTAssertEqual(studio.savedPresets,[second])
    XCTAssertEqual(ImageGenerationPromptLibrary(root:root,projectID:id).savedPresets,[second])
    let builtin=try XCTUnwrap(StudioGenerationPromptPreset.builtins.first)
    let copied=try studio.save(name:builtin.name,prompt:builtin.prompt)
    XCTAssertNotEqual(copied.id,builtin.id)
    let reopened=ImageGenerationPromptLibrary(root:root,projectID:id)
    XCTAssertTrue(reopened.savedPresets.contains(copied),"An explicit user save of a builtin must survive reopening")
    XCTAssertEqual(reopened.presets(including:StudioGenerationPromptPreset.builtins).filter{$0.name==builtin.name}.count,1)
  }
  func testLegacyPromptFileKeepsBytesUntilExplicitEditAndCorruptionCannotBeOverwritten()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("legacy-generation-prompts-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let id=UUID(),library=ImageGenerationPromptLibrary(root:root,projectID:id)
    let saved=StudioGenerationPromptPreset(id:UUID(),name:"My direction",prompt:"Retain this request")
    let original=try JSONEncoder.form.encode(StudioGenerationPromptPreset.builtins+[saved])
    try FileManager.default.createDirectory(at:library.file.deletingLastPathComponent(),withIntermediateDirectories:true)
    try original.write(to:library.file)
    library.reload();XCTAssertEqual(library.savedPresets,[saved])
    XCTAssertEqual(library.presets(including:StudioGenerationPromptPreset.builtins),StudioGenerationPromptPreset.builtins+[saved])
    XCTAssertEqual(try Data(contentsOf:library.file),original)
    let corrupt=Data("keep these damaged bytes".utf8);try corrupt.write(to:library.file)
    library.reload();XCTAssertNotNil(library.error);XCTAssertEqual(library.savedPresets,[saved])
    XCTAssertThrowsError(try library.save(name:"New",prompt:"Must not replace unreadable data"))
    XCTAssertThrowsError(try library.remove(id:saved.id));XCTAssertEqual(try Data(contentsOf:library.file),corrupt)
  }
}

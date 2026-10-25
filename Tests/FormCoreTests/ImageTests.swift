import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FormCore
@testable import FormGraphics

final class ImageTests: XCTestCase {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FORM-image-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
    addTeardownBlock { try? FileManager.default.removeItem(at:url) }
    return url
  }
  @MainActor private func fixture(_ folder:URL, type:UTType = .png, orientation:Int = 1) throws -> URL {
    let context = CGContext(data:nil,width:120,height:80,bitsPerComponent:8,bytesPerRow:480,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bytes = context.data!.assumingMemoryBound(to:UInt8.self)
    for y in 0..<80 { for x in 0..<120 {
      let rgb: [UInt8] = y < 40 ? (x < 60 ? [255,0,0] : [0,255,0]) : (x < 60 ? [0,0,255] : [255,255,0])
      let i = y*480+x*4
      bytes[i] = rgb[0]; bytes[i+1] = rgb[1]; bytes[i+2] = rgb[2]; bytes[i+3] = 255
    } }
    let url = folder.appendingPathComponent(UUID().uuidString+"."+(type.preferredFilenameExtension ?? "png"))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,type.identifier as CFString,1,nil))
    CGImageDestinationAddImage(destination,context.makeImage()!,[kCGImagePropertyOrientation:orientation] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }
  private func project(_ asset:String = "fixture.png") throws -> (Project,UUID,UUID) {
    var p = Project(name:"Images"), o = try Project(name:"Images").makeObject(recipeID:"artboard")
    let e = ArtworkElement(kind:"image",x:10,y:10,width:60,height:40,asset:asset)
    o.artwork = .init(background:"#FFFFFF",elements:[e],bleed:0); p.objects = [o]
    return (p,o.id,e.id)
  }
  @MainActor private func render(_ e:ArtworkElement,assets:URL,mask:ArtworkElement? = nil) -> NSBitmapImageRep {
    ArtworkRenderer.image(.init(background:"#FFFFFF",elements:[e]+[mask].compactMap{$0},bleed:0),
      width:100,height:100,assets:assets,pixelsPerMM:2).representations[0] as! NSBitmapImageRep
  }
  @MainActor private func pixel(_ image:NSBitmapImageRep,_ x:Int,_ y:Int) -> NSColor {
    let c = image.colorAt(x:x*2,y:y*2)!
    return NSColor(colorSpace:image.colorSpace,components:[c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent],count:4).usingColorSpace(.sRGB)!
  }

  func testStrictImagePatchesAreAtomicAndPreserveUnchangedValues() throws {
    var (p,id,e) = try project()
    try ImageCommands.apply(in:&p,objectID:id,ids:[e],crop:["x":0.25,"width":0.5],adjustments:["saturation":0.4])
    let before = p
    for bad: Any in [["x":true],["width":0.001],["x":0.9],["height":Double.nan],["unknown":1],"bad"] {
      XCTAssertThrowsError(try ImageCommands.apply(in:&p,objectID:id,ids:[e],crop:bad))
      XCTAssertEqual(p,before)
    }
    for bad: Any in [["contrast":true],["contrast":4.1],["saturation":-1],["brightness":Double.infinity],["unknown":0]] {
      XCTAssertThrowsError(try ImageCommands.apply(in:&p,objectID:id,ids:[e],adjustments:bad)); XCTAssertEqual(p,before)
    }
    try ImageCommands.apply(in:&p,objectID:id,ids:[e],adjustments:["contrast":1.2])
    XCTAssertEqual(p.objects[0].artwork!.elements[0].imageAdjustments?.saturation,0.4)
    try ImageCommands.apply(in:&p,objectID:id,ids:[e],reset:true)
    XCTAssertNil(p.objects[0].artwork!.elements[0].imageCrop)
    XCTAssertNil(p.objects[0].artwork!.elements[0].imageAdjustments)
  }
  func testLockedAncestorsWrongKindsAndLockedSourcesRejectImageEdits() throws {
    var (p,id,e) = try project()
    p.objects[0].locked = true
    XCTAssertThrowsError(try ImageCommands.apply(in:&p,objectID:id,ids:[e],reset:true))
    p.objects[0].locked = false
    var g = ArtworkElement(kind:"group",x:0,y:0,width:100,height:100); g.locked = true
    p.objects[0].artwork!.elements[0].parentID = g.id; p.objects[0].artwork!.elements.append(g)
    XCTAssertThrowsError(try ImageCommands.apply(in:&p,objectID:id,ids:[e],reset:true))
    XCTAssertThrowsError(try ImageCommands.apply(in:&p,objectID:id,ids:[g.id],reset:true))
  }
  func testPartialSettingsDecodeDefaultsAndIdentitySignatures() throws {
    let crop = try JSONDecoder().decode(ImageCrop.self,from:Data("{\"width\":0.5}".utf8))
    XCTAssertEqual(crop,.init(width:0.5))
    let adjustments = try JSONDecoder().decode(ImageAdjustments.self,from:Data("{\"saturation\":0}".utf8))
    XCTAssertEqual(adjustments.contrast,1)
    var e = ArtworkElement(kind:"image",x:0,y:0,width:10,height:10,asset:"x.png")
    let plain = Artwork(elements:[e]).renderDefinition
    e.imageCrop = .full; e.imageAdjustments = .init()
    XCTAssertEqual(Artwork(elements:[e]).renderDefinition,plain)
    e.kind = "rectangle"
    XCTAssertThrowsError(try validateArtwork(.init(elements:[e])))
  }
  func testCropFillingZoomAndMovementStayInsideOriginal() {
    let crop = ImageCrop.filling(pixelWidth:200,pixelHeight:100,width:100,height:100)
    XCTAssertEqual(crop,.init(x:0.25,width:0.5))
    XCTAssertEqual(crop.moved(dx:2,dy:-2),.init(x:0.5,width:0.5))
    let zoom = crop.zoomed(0.5,anchor:.init(0.2,0.8))
    XCTAssertEqual(zoom.x,0.3,accuracy:1e-10); XCTAssertEqual(zoom.y,0.4,accuracy:1e-10)
    for factor in [0.0001,0.5,1.5,100] {
      let value = crop.zoomed(factor,anchor:.init(1,1))
      XCTAssertEqual(value.width/value.height,crop.width/crop.height,accuracy:1e-10)
      XCTAssertGreaterThanOrEqual(value.width,0.01-1e-12)
      XCTAssertLessThanOrEqual(value.x+value.width,1)
      XCTAssertLessThanOrEqual(value.y+value.height,1)
    }
  }
  @MainActor func testTopLeftCropUsesOriginalQuadrantsAndKeepsFrameClipping() throws {
    let dir = try folder(), url = try fixture(dir)
    var e = ArtworkElement(kind:"image",x:10,y:10,width:60,height:40,asset:url.lastPathComponent)
    let full = render(e,assets:dir)
    XCTAssertGreaterThan(pixel(full,20,20).redComponent,0.98)
    XCTAssertGreaterThan(pixel(full,20,40).blueComponent,0.98)
    e.imageCrop = .init(x:0.5,width:0.5)
    let cropped = render(e,assets:dir)
    XCTAssertGreaterThan(pixel(cropped,20,20).greenComponent,0.98)
    XCTAssertGreaterThan(pixel(cropped,20,40).redComponent,0.98)
    XCTAssertGreaterThan(pixel(cropped,20,40).greenComponent,0.98)
    XCTAssertEqual(pixel(cropped,8,20).redComponent,1,accuracy:0.01)
    XCTAssertEqual(pixel(cropped,72,20).blueComponent,1,accuracy:0.01)
    XCTAssertEqual(e.width,60)
  }
  @MainActor func testRasterAdjustmentsChangePixelsAndPreserveOriginalBytes() throws {
    let dir = try folder(), url = try fixture(dir), original = try Data(contentsOf:url)
    var e = ArtworkElement(kind:"image",x:10,y:10,width:60,height:40,asset:url.lastPathComponent)
    e.imageAdjustments = .init(saturation:0)
    let gray = pixel(render(e,assets:dir),20,20)
    XCTAssertEqual(gray.redComponent,gray.greenComponent,accuracy:0.01)
    XCTAssertEqual(gray.greenComponent,gray.blueComponent,accuracy:0.01)
    e.imageAdjustments = .init(brightness:0.1,contrast:0)
    let flat = pixel(render(e,assets:dir),20,20)
    XCTAssertEqual(flat.redComponent,0.6,accuracy:0.015)
    XCTAssertEqual(flat.greenComponent,0.6,accuracy:0.015)
    XCTAssertEqual(try Data(contentsOf:url),original)
  }
  @MainActor func testVectorMaskClipsCroppedAdjustedImageAfterItsOwnFrame() throws {
    let dir = try folder(),url = try fixture(dir)
    var e = ArtworkElement(kind:"image",x:10,y:10,width:60,height:40,asset:url.lastPathComponent)
    let mask = ArtworkElement(kind:"ellipse",x:10,y:10,width:60,height:40)
    e.clipID = mask.id; e.imageCrop = .init(x:0.5,width:0.5); e.imageAdjustments = .init(saturation:0)
    let image = render(e,assets:dir,mask:mask)
    XCTAssertEqual(pixel(image,11,11).redComponent,1,accuracy:0.01)
    XCTAssertLessThan(pixel(image,40,30).blueComponent,0.95)
  }
  @MainActor func testImageIOOrientationSwapsDimensionsAndIsAppliedOnce() throws {
    let dir = try folder(),url = try fixture(dir,type:.jpeg,orientation:6)
    let info = try ImageRenderer.info(url)
    XCTAssertEqual(info.width,80); XCTAssertEqual(info.height,120); XCTAssertTrue(info.oriented)
    let image = try ImageRenderer.bitmap(url,requestedEdge:120)
    XCTAssertEqual(image.width,80); XCTAssertEqual(image.height,120)
    let rep = NSBitmapImageRep(cgImage:image)
    let topLeft = rep.colorAt(x:10,y:10)!
    XCTAssertGreaterThan(topLeft.blueComponent,0.95)
    let topRight = rep.colorAt(x:70,y:10)!
    XCTAssertGreaterThan(topRight.redComponent,0.95)
  }
  func testEffectiveDPIIncludesCropRotationScaleAndShear() {
    let info = ImageAssetInfo(width:300,height:300,frames:1,format:"png",oriented:false)
    var e = ArtworkElement(kind:"image",x:0,y:0,width:25.4,height:25.4)
    XCTAssertEqual(info.effectiveDPI(e,transform:.init()),300,accuracy:1e-8)
    XCTAssertEqual(info.effectiveDPI(e,transform:.rotation(37)),300,accuracy:1e-8)
    XCTAssertEqual(info.effectiveDPI(e,transform:.scale(2,2)),150,accuracy:1e-8)
    XCTAssertEqual(info.effectiveDPI(e,transform:.init(c:1)),300/((1+sqrt(5))/2),accuracy:1e-8)
    e.imageCrop = .init(width:0.25)
    XCTAssertEqual(info.effectiveDPI(e,transform:.init()),75,accuracy:1e-8)
  }
  @MainActor func testDecodeCacheReusesPlacementAndCropIndependentPixels() throws {
    let dir = try folder(),url = try fixture(dir)
    let a = try ImageRenderer.bitmap(url,requestedEdge:120), before = ImageRenderer.diagnostics
    let b = try ImageRenderer.bitmap(url,requestedEdge:120)
    XCTAssertTrue(a === b)
    XCTAssertEqual(ImageRenderer.diagnostics["builds"] as? Int,before["builds"] as? Int)
    XCTAssertEqual(ImageRenderer.diagnostics["cache_hits"] as? Int,(before["cache_hits"] as! Int)+1)
  }
  @MainActor func testSVGPreservesOriginalBytesCropAndLiveColorAdjustments() throws {
    let dir = try folder(),url = try fixture(dir)
    var e = ArtworkElement(kind:"image",x:10,y:10,width:60,height:40,asset:url.lastPathComponent)
    e.imageCrop = .init(x:0.2,y:0.1,width:0.5,height:0.8)
    e.imageAdjustments = .init(brightness:0.1,contrast:1.2,saturation:0.4)
    let svg = try SVGRenderer.document(.init(elements:[e]),width:100,height:100,assets:dir)
    XCTAssertTrue(svg.contains("viewBox=\"0.2 0.1 0.5 0.8\""))
    XCTAssertTrue(svg.contains("feColorMatrix type=\"matrix\""))
    XCTAssertTrue(svg.contains(try Data(contentsOf:url).base64EncodedString()))
    XCTAssertTrue(svg.contains("color-interpolation-filters=\"sRGB\""))
  }
  @MainActor func testPNGJPEGAndTIFFDecodeWithConsistentOrientedDimensions() throws {
    let dir = try folder()
    for type:UTType in [.png,.jpeg,.tiff,.gif,.heic,.bmp] {
      guard (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(type.identifier) else { continue }
      let url = try fixture(dir,type:type)
      let info = try ImageRenderer.info(url)
      XCTAssertEqual(info.width,120); XCTAssertEqual(info.height,80)
      let image = try ImageRenderer.bitmap(url,requestedEdge:120)
      XCTAssertEqual(image.width,120); XCTAssertEqual(image.height,80)
    }
  }
  @MainActor func testResolutionGuardUsesCropAndIgnoresHiddenImages() throws {
    let dir = try folder(),url = try fixture(dir)
    var e = ArtworkElement(kind:"image",x:0,y:0,width:500,height:500,asset:url.lastPathComponent)
    // A small original never needs an oversized decode, even at large output size.
    XCTAssertNoThrow(try ImageRenderer.validateOutput(e,assets:dir,pixelsPerMM:100,transform:.init()))
    e.hidden = true
    XCTAssertNoThrow(try ArtworkRenderer.validateAppearanceOutput(.init(elements:[e]),assets:dir,pixelsPerMM:100))
  }
  @MainActor func testOutputLimitRejectsLargeDecodesBeforeAllocation() throws {
    let dir = try folder(),url = dir.appendingPathComponent("wide.png")
    let context = CGContext(data:nil,width:10000,height:4,bitsPerComponent:8,bytesPerRow:10000,
      space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,context.makeImage()!,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    let e = ArtworkElement(kind:"image",x:0,y:0,width:500,height:0.2,asset:url.lastPathComponent)
    XCTAssertThrowsError(try ImageRenderer.validateOutput(e,assets:dir,pixelsPerMM:100,transform:.init()))
    XCTAssertNoThrow(try ImageRenderer.validateOutput(e,assets:dir,pixelsPerMM:1,transform:.init()))
  }
  @MainActor func testInvalidatingAnExternalSourceReadsItsUpdatedPixels() throws {
    let dir = try folder(),url = try fixture(dir)
    let first = try ImageRenderer.bitmap(url,requestedEdge:120)
    let changed = CGContext(data:nil,width:4,height:4,bitsPerComponent:8,bytesPerRow:16,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    changed.setFillColor(NSColor.green.cgColor); changed.fill(CGRect(x:0,y:0,width:4,height:4))
    let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,changed.makeImage()!,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    ImageRenderer.invalidate(url)
    let second = try ImageRenderer.bitmap(url,requestedEdge:120)
    XCTAssertFalse(first === second)
    XCTAssertEqual(second.width,4)
    XCTAssertGreaterThan(NSBitmapImageRep(cgImage:second).colorAt(x:1,y:1)!.greenComponent,0.95)
  }
  @MainActor func testAdjustmentsPreserveTransparencyAndUnpremultipliedColor() throws {
    let dir = try folder(),url = dir.appendingPathComponent("transparent.png")
    let context = CGContext(data:nil,width:4,height:4,bitsPerComponent:8,bytesPerRow:16,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bytes = context.data!.assumingMemoryBound(to:UInt8.self)
    for i in 0..<16 { bytes[i*4] = 128; bytes[i*4+1] = 0; bytes[i*4+2] = 0; bytes[i*4+3] = 128 }
    let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,context.makeImage()!,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    let bitmap = try ImageRenderer.bitmap(url,adjustments:.init(brightness:0.1,saturation:0),requestedEdge:4)
    let sample = NSBitmapImageRep(cgImage:bitmap).colorAt(x:1,y:1)!
    XCTAssertEqual(sample.alphaComponent,128/255.0,accuracy:0.01)
    XCTAssertEqual(sample.redComponent,0.313,accuracy:0.015)
    XCTAssertEqual(sample.redComponent,sample.greenComponent,accuracy:0.01)
  }
  @MainActor func testWebPDecodeOnTheSupportedMac() throws {
    let dir = try folder(),url = dir.appendingPathComponent("sample.webp")
    let bytes = try XCTUnwrap(Data(base64Encoded:"UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEAAUAmJaQAA3AA/v89WAAAAA=="))
    try bytes.write(to:url)
    let info = try ImageRenderer.info(url)
    XCTAssertEqual(info.width,1); XCTAssertEqual(info.height,1)
    let decoded = try ImageRenderer.bitmap(url,requestedEdge:1)
    XCTAssertEqual(decoded.width,1); XCTAssertEqual(decoded.height,1)
  }
  @MainActor func testAnimatedGIFPreservesFrameCountAndUsesItsFirstFrame() throws {
    let dir = try folder(),source = try fixture(dir),url = dir.appendingPathComponent("animated.gif")
    let input = CGImageSourceCreateWithURL(source as CFURL,nil)!
    let first = CGImageSourceCreateImageAtIndex(input,0,nil)!
    let context = CGContext(data:nil,width:120,height:80,bitsPerComponent:8,bytesPerRow:480,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.green.cgColor); context.fill(CGRect(x:0,y:0,width:120,height:80))
    let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.gif.identifier as CFString,2,nil)!
    let properties = [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.1]] as CFDictionary
    CGImageDestinationAddImage(destination,first,properties)
    CGImageDestinationAddImage(destination,context.makeImage()!,properties)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    XCTAssertEqual(try ImageRenderer.info(url).frames,2)
    let bitmap = try ImageRenderer.bitmap(url,requestedEdge:120)
    XCTAssertGreaterThan(NSBitmapImageRep(cgImage:bitmap).colorAt(x:10,y:10)!.redComponent,0.95)
  }
  func testSchemaNineRoundTripAndAtomicImageBatchRollback() throws {
    let dir = try folder(),repo = try ProjectRepository(root:dir),engine = OperationEngine(repository:repo)
    let (p,id,e) = try project(); engine.project = p
    _ = try engine.call("form_edit_image",arguments:["object_id":id.uuidString,"element_ids":[e.uuidString],"crop":["width":0.5]])
    XCTAssertEqual(engine.project!.minimumSchemaVersion,9)
    try engine.flush(); let loaded = try repo.load(p.id)
    XCTAssertEqual(try JSONEncoder.form.encode(loaded),try JSONEncoder.form.encode(engine.project!))
    XCTAssertEqual(loaded.objects,engine.project!.objects)
    let before = engine.project
    XCTAssertThrowsError(try engine.call("form_batch",arguments:["operations":[
      ["name":"form_edit_image","arguments":["object_id":id.uuidString,"element_ids":[e.uuidString],"adjustments":["saturation":0]]],
      ["name":"form_edit_image","arguments":["object_id":id.uuidString,"element_ids":[e.uuidString],"crop":["width":-1]]],
    ]]))
    XCTAssertEqual(engine.project,before)
    engine.undo(); XCTAssertEqual(engine.project,p)
  }
}

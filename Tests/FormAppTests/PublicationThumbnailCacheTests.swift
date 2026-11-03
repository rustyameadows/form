import AppKit
import FormCore
import FormGraphics
import ImageIO
import XCTest
@testable import FormApp

@MainActor final class PublicationThumbnailCacheTests:XCTestCase {
  private func directory()throws->URL {
    let value=FileManager.default.temporaryDirectory.appendingPathComponent("publication-thumbnails-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:value,withIntermediateDirectories:true)
    addTeardownBlock{try? FileManager.default.removeItem(at:value)};return value
  }
  private func artwork()->Artwork {Artwork(elements:[.init(kind:"rectangle",x:2,y:2,width:6,height:6,color:"#214E9B")])}
  func testSelectionReuseAndEveryExplicitRenderInputInvalidatesWithoutCrossProjectReuse()throws {
    let assets=try directory(),other=try directory(),project=UUID(),page=UUID()
    var fonts=0,requests:[PublicationThumbnailCache.Request]=[]
    let cache=PublicationThumbnailCache(fontRevision:{fonts},renderer:{requests.append($0);return NSImage(size:.init(width:1,height:1))})
    var art=artwork();let original=art
    func image(_ projectID:UUID?=nil,_ objectID:UUID?=nil,_ width:Double=10,_ height:Double=10,_ path:URL?=nil,_ paper:String?=nil,_ edge:Int=200)->NSImage? {
      cache.image(projectID:projectID ?? project,objectID:objectID ?? page,artwork:art,width:width,height:height,assets:path ?? assets,paperColor:paper,maximumPixelSize:edge)
    }
    let first=try XCTUnwrap(image());XCTAssertTrue(first === image());XCTAssertEqual(requests.count,1)
    art.elements[0].color="#E24E35";_ = image();XCTAssertEqual(requests.count,2)
    art=original;XCTAssertTrue(first === image(),"Undo to identical resolved data may reuse its exact previous preview")
    _ = image(UUID());_ = image(project,UUID());_ = image(project,page,11);_ = image(project,page,10,12)
    _ = image(project,page,10,10,other);_ = image(project,page,10,10,nil,"#D0A060")
    _ = image(project,page,10,10,nil,nil,201);XCTAssertEqual(requests.count,9)
    fonts+=1;_ = image();XCTAssertEqual(requests.count,10)
    XCTAssertEqual(requests.last?.artwork,original);XCTAssertEqual(art,original)
  }
  func testResolvedGlobalStoryAndFrameGeometryAreInIdentityEvenWhenSavedEncodingIsIdentical()throws {
    let assets=try directory(),project=UUID(),page=UUID()
    let cache=PublicationThumbnailCache(renderer:{_ in NSImage(size:.init(width:1,height:1))})
    var frame=ArtworkElement(kind:"text",x:1,y:1,width:8,height:8,text:"")
    let frameID=StoryFrameID(objectID:page,elementID:frame.id)
    let source=ArtworkElement(kind:"text",x:0,y:0,width:8,height:8,text:"Original source",fontSize:12)
    let story=TextStory(source:source,frames:[frameID])
    var reference=StoryFrameReference(storyID:story.id)
    reference.resolved = .init(story:story,frames:[.init(frame:frameID,width:8,height:8,pageY:0)],baselineGrid:nil,language:nil)
    reference.frame=frameID;frame.storyFrame=reference
    var art=Artwork(elements:[frame]);let original=art,saved=try JSONEncoder.form.encode(art)
    func image()->NSImage? {cache.image(projectID:project,objectID:page,artwork:art,width:10,height:10,assets:assets)}
    let first=try XCTUnwrap(image())
    art.elements[0].storyFrame!.resolved!.story.text="Changed global source"
    XCTAssertEqual(try JSONEncoder.form.encode(art),saved)
    _ = image();XCTAssertEqual(cache.renderCount,2)
    art.elements[0].storyFrame!.resolved!.frames[0].width=7
    _ = image();XCTAssertEqual(cache.renderCount,3)
    art=original;XCTAssertTrue(first === image());XCTAssertEqual(cache.renderCount,3)
  }
  func testActualResolvedMasterAndPageNumberEditsInvalidateAndUndoReusesSource()throws {
    let assets=try directory();var project=Project(name:"Master preview")
    var page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140]);page.artwork=artwork()
    var master=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140])
    master.artwork=Artwork(elements:[.init(kind:"text",x:5,y:5,width:80,height:15,text:"PAGE {{page.number}}",fontSize:12)])
    project.objects=[page,master]
    let id=try PublicationCommands.createPublication(in:&project,name:"Master preview",pages:[page.id])
    project.publications![0].masters=[.init(name:"Running furniture",sourceObjectID:master.id)]
    let before=project,cache=PublicationThumbnailCache(renderer:{_ in NSImage(size:.init(width:1,height:1))})
    func image()throws->NSImage? {
      let art=try XCTUnwrap(project.surfaceArtwork(project.objects[0]))
      return cache.image(projectID:project.id,objectID:page.id,artwork:art,width:100,height:140,assets:assets)
    }
    let first=try XCTUnwrap(image())
    project.objects[1].artwork!.elements[0].text="FOLIO {{page.number}}";_ = try image();XCTAssertEqual(cache.renderCount,2)
    project=before;XCTAssertTrue(first === (try image()))
    project.publications![0].numbering = .init(start:7);_ = try image();XCTAssertEqual(cache.renderCount,3)
    XCTAssertEqual(project.publications?.first?.id,id)
  }
  func testReferencedAssetBytesDeletionRepairAndUnchangedMetadataCannotReturnOldPixels()throws {
    let assets=try directory(),file=assets.appendingPathComponent("source.dat"),project=UUID(),page=UUID()
    let old=Data("red01".utf8),new=Data("blue1".utf8);try old.write(to:file)
    let date=try XCTUnwrap(try file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate)
    let art=Artwork(elements:[.init(kind:"image",x:0,y:0,width:10,height:10,asset:file.lastPathComponent)])
    let cache=PublicationThumbnailCache(renderer:{_ in NSImage(size:.init(width:1,height:1))})
    func image()->NSImage? {cache.image(projectID:project,objectID:page,artwork:art,width:10,height:10,assets:assets)}
    let first=try XCTUnwrap(image());_ = image();XCTAssertEqual(cache.renderCount,1)
    try Data("Unrelated".utf8).write(to:assets.appendingPathComponent("unused.dat"));_ = image();XCTAssertEqual(cache.renderCount,1)
    try new.write(to:file);try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:file.path)
    XCTAssertEqual(old.count,new.count);_ = image();XCTAssertEqual(cache.renderCount,2)
    try FileManager.default.removeItem(at:file);_ = image();XCTAssertEqual(cache.renderCount,3)
    try old.write(to:file);XCTAssertTrue(first === image());XCTAssertEqual(cache.renderCount,3)
  }
  func testBoundedLRUEvictsLeastRecentlyUsedAndKeepsByteBudget()throws {
    let assets=try directory(),project=UUID(),a=UUID(),b=UUID(),c=UUID(),art=artwork()
    let cache=PublicationThumbnailCache(capacity:2,renderer:{_ in NSImage(size:.init(width:1,height:1))})
    func image(_ id:UUID)->NSImage? {cache.image(projectID:project,objectID:id,artwork:art,width:10,height:10,assets:assets)}
    let first=try XCTUnwrap(image(a));_ = image(b);_ = image(a);_ = image(c)
    XCTAssertEqual(cache.count,2);XCTAssertTrue(first === image(a));XCTAssertEqual(cache.renderCount,3)
    _ = image(b);XCTAssertEqual(cache.renderCount,4);XCTAssertEqual(cache.count,2)
    let memory=PublicationThumbnailCache(capacity:1000,renderer:{_ in NSImage(size:.init(width:1,height:1))})
    for _ in 0..<20 {_ = memory.image(projectID:project,objectID:UUID(),artwork:art,width:10,height:10,assets:assets,maximumPixelSize:1024)}
    XCTAssertLessThanOrEqual(memory.count,128);XCTAssertLessThanOrEqual(memory.retainedBytes,32*1024*1024)
    XCTAssertEqual(memory.count,8)
    memory.removeAll();XCTAssertEqual(memory.count,0);XCTAssertEqual(memory.retainedBytes,0)
  }
  private func png(_ red:CGFloat,_ green:CGFloat,_ blue:CGFloat)throws->Data {
    let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
    let context=try XCTUnwrap(CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,
      space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    // The convenience CGColor(red:...) initializer is device RGB. Declaring
    // both the paint and the encoded image as sRGB makes literal expectations
    // independent of this Mac's display/device profile.
    context.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[red,green,blue,1])))
    context.fill(.init(x:0,y:0,width:2,height:2))
    let data=NSMutableData()
    let destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,try XCTUnwrap(context.makeImage()),nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let encoded=data as Data
    let source=try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData,nil))
    let decoded=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
    let expected=[red,green,blue,1].map{UInt8(($0*255).rounded())}
    XCTAssertEqual(try pixel(NSImage(cgImage:decoded,size:.init(width:2,height:2)),1,1),expected,
      "The portable source fixture itself must contain its declared sRGB pixels")
    return encoded
  }
  private func pixel(_ image:NSImage,_ x:Int,_ y:Int)throws->[UInt8] {
    let source=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)),w=source.width,h=source.height
    let context=try XCTUnwrap(CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
    context.draw(source,in:.init(x:0,y:0,width:w,height:h))
    let data=try XCTUnwrap(context.data?.assumingMemoryBound(to:UInt8.self)),i=(y*w+x)*4
    return Array(UnsafeBufferPointer(start:data+i,count:4))
  }
  func testActualRendererCompositesStockUnderTransparentArtAndRefreshesWarmRasterBytes()throws {
    let assets=try directory(),project=UUID(),page=UUID(),cache=PublicationThumbnailCache()
    var art=artwork();art.backgroundOpacity=0;let before=art
    let first=try XCTUnwrap(cache.image(projectID:project,objectID:page,artwork:art,width:10,height:10,assets:assets,paperColor:"#D0A060",maximumPixelSize:20))
    XCTAssertEqual(try pixel(first,1,1),[208,160,96,255]);XCTAssertEqual(try pixel(first,10,10),[33,78,155,255])
    let second=try XCTUnwrap(cache.image(projectID:project,objectID:page,artwork:art,width:10,height:10,assets:assets,paperColor:"#607F90",maximumPixelSize:20))
    XCTAssertEqual(try pixel(second,1,1),[96,127,144,255]);XCTAssertEqual(try pixel(second,10,10),[33,78,155,255]);XCTAssertEqual(art,before)
    let translucent=try XCTUnwrap(cache.image(projectID:project,objectID:page,artwork:art,width:10,height:10,assets:assets,paperColor:"#D0A060",paperOpacity:0.5,maximumPixelSize:20))
    let tint=try pixel(translucent,1,1)
    for (actual,expected) in zip(tint,[232,208,176,255]) {XCTAssertEqual(Double(actual),Double(expected),accuracy:1)}
    XCTAssertEqual(try pixel(translucent,10,10),[33,78,155,255]);XCTAssertEqual(art,before)
    let file=assets.appendingPathComponent("source.png");try png(1,0,0).write(to:file)
    let imageArt=Artwork(elements:[.init(kind:"image",x:0,y:0,width:10,height:10,asset:file.lastPathComponent)])
    let red=try XCTUnwrap(cache.image(projectID:project,objectID:page,artwork:imageArt,width:10,height:10,assets:assets,maximumPixelSize:20))
    XCTAssertEqual(try pixel(red,10,10),[255,0,0,255])
    try png(0,0,1).write(to:file)
    let blue=try XCTUnwrap(cache.image(projectID:project,objectID:page,artwork:imageArt,width:10,height:10,assets:assets,maximumPixelSize:20))
    XCTAssertEqual(try pixel(blue,10,10),[0,0,255,255])
  }
  func testActualEffectedImageRefreshesAfterSamePathAssetReplacement()throws {
    let assets=try directory(),file=assets.appendingPathComponent("effect-source.png"),project=UUID(),page=UUID()
    try png(1,0,0).write(to:file)
    var paint=ArtworkElement(kind:"image",x:0,y:0,width:10,height:10,asset:file.lastPathComponent)
    var blur=ArtworkBlur();blur.enabled=true;blur.radius=0.25;paint.blur=blur
    let art=Artwork(elements:[paint]),before=art,cache=PublicationThumbnailCache()
    func image()throws->NSImage {try XCTUnwrap(cache.image(projectID:project,objectID:page,artwork:art,width:10,height:10,assets:assets,maximumPixelSize:40))}
    let first=try image(),red=try pixel(first,20,20)
    XCTAssertGreaterThan(red[0],240);XCTAssertLessThan(red[2],16)
    XCTAssertTrue(first === (try image()));XCTAssertEqual(cache.renderCount,1)
    // The same artwork/path has a warm appearance raster, not just a decoded
    // image. Refreshing only ImageRenderer's metadata would retain red here.
    try png(0,0,1).write(to:file)
    let second=try image(),blue=try pixel(second,20,20)
    XCTAssertGreaterThan(blue[2],240);XCTAssertLessThan(blue[0],16)
    XCTAssertEqual(cache.renderCount,2);XCTAssertEqual(art,before)
  }
  func testInvalidPreviewInputsDoNotInvokeRendererOrAllocateEntries()throws {
    let assets=try directory(),cache=PublicationThumbnailCache(renderer:{_ in XCTFail("Invalid input reached rendering");return nil})
    for(width,height,edge,color) in [(Double.nan,10.0,200,"#FFFFFF"),(10,.infinity,200,"#FFFFFF"),(0,10,200,"#FFFFFF"),(10,10,2048,"#FFFFFF"),(10,10,200,"not a color")] {
      XCTAssertNil(cache.image(projectID:UUID(),objectID:UUID(),artwork:artwork(),width:width,height:height,assets:assets,paperColor:color,maximumPixelSize:edge))
    }
    XCTAssertEqual(cache.renderCount,0);XCTAssertEqual(cache.count,0)
  }
}

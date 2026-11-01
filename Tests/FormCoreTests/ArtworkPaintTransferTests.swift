import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class ArtworkPaintTransferTests:XCTestCase {
  private func raster()throws->Data {
    var pixels=[UInt8]()
    for y in 0..<20 {for _ in 0..<20 {pixels += y<10 ? [255,0,0,255]:[0,0,255,255]}}
    let provider=try XCTUnwrap(CGDataProvider(data:Data(pixels) as CFData))
    let image=try XCTUnwrap(CGImage(width:20,height:20,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:80,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    return try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]))
  }
  func testRichTextPaintResourcesSurviveTransferRemappingStoryAndRecopy()throws {
    let bytes=try raster(),name="image-"+ArtworkTransferBundle.digest(bytes)+".png"
    let image=ArtworkPaint(kind:"image",asset:name,imageTransform:.scale(0.5,0.5),imageRepeat:true)
    var gradient=ArtworkGradient(kind:"linear",start:.init(0,0),end:.init(1,0),stops:[.init(0,"#F00000"),.init(1,"#0000F0")])
    gradient.transform = .rotation(10)
    var text=ArtworkElement(kind:"text",x:10,y:10,width:100,height:40,text:"Image / gradient",fontSize:24)
    text.paintStack=[.init(image)]
    text.textRuns=[.init(location:8,length:8,typography:.init(),fontSize:24,color:"#000000")]
    text.textRuns![0].paintStack=[.init(.init(kind:"gradient",gradient:gradient))]
    let art=Artwork(elements:[text]),bundle=try ArtworkTransferBundle.external(artwork:art,selection:[text.id],assets:[name:bytes],application:"Figma")
    XCTAssertEqual(try ArtworkTransferPreflight.validate(bundle).rasterPixels,400)
    var project=Project(name:"Paint resources");let owner=try project.ensureCanvasWorkspace()
    let plan=try ArtworkTransferGraph.plan(ArtworkTransferBundle.decode(bundle.encoded()),into:project,objectID:owner.id)
    let copied=try ArtworkTransferGraph.capture(project:plan.project,objectID:owner.id,ids:plan.selection,readAsset:{name,_ in try XCTUnwrap(plan.assetWrites[name])})
    XCTAssertEqual(copied.blobs.values.first,bytes)
    let pasted=try XCTUnwrap(plan.project.canvasWorkspace?.artwork?.elements.first)
    XCTAssertEqual(pasted.renderedAssetNames,[name])
    XCTAssertEqual(pasted.paintStack,text.paintStack)
    XCTAssertEqual(pasted.textRuns?[0].paintStack?[0].paint.gradient?.stops.map(\.color),gradient.stops.map(\.color))
    XCTAssertNotEqual(pasted.textRuns?[0].paintStack?[0].paint.gradient?.stops.map(\.id),gradient.stops.map(\.id))
    let story=TextStory(source:pasted)
    XCTAssertEqual(story.sourceElement.paintStack,pasted.paintStack)
    XCTAssertEqual(story.sourceElement.textRuns,pasted.textRuns)
    XCTAssertEqual(plan.project.minimumSchemaVersion,58)
    let restored=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(plan.project))
    XCTAssertEqual(restored.objects,plan.project.objects)
  }
  func testPaintValidationRejectsOpaqueSourcesWrongKindsAndUnboundedStacks()throws {
    var text=ArtworkElement(kind:"text",x:0,y:0,text:"Bad paint")
    text.paintStack=[.init(.init(kind:"image",asset:"source-private.figma"))]
    XCTAssertThrowsError(try validateArtwork(.init(elements:[text])))
    text.paintStack=[.init(.init(kind:"solid",asset:"image.png"))]
    XCTAssertThrowsError(try validateArtwork(.init(elements:[text])))
    text.paintStack=Array(repeating:.init(.init()),count:17)
    XCTAssertThrowsError(try validateArtwork(.init(elements:[text])))
    text.paintStack=[.init(.init(kind:"image",asset:"image.png",imageTransform:.scale(0,1)))]
    XCTAssertThrowsError(try validateArtwork(.init(elements:[text])))
  }
  func testTiledImagePaintOrientationAndSVGRemainNative()throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
    try raster().write(to:dir.appendingPathComponent("image.png"))
    var shape=ArtworkElement(kind:"rectangle",x:0,y:0,width:40,height:40)
    shape.paintStack=[.init(.init(kind:"image",asset:"image.png",imageTransform:.scale(0.5,0.5),imageRepeat:true))]
    let art=Artwork(elements:[shape]),image=ArtworkRenderer.image(art,width:40,height:40,assets:dir,pixelsPerMM:2)
    let rep=try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
    for x in [10,50] {
      XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x:x,y:10)).redComponent,0.9)
      XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x:x,y:30)).blueComponent,0.9)
      XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x:x,y:50)).redComponent,0.9)
    }
    let svg=try SVGRenderer.document(art,width:40,height:40,assets:dir)
    XCTAssertTrue(svg.contains("<pattern"));XCTAssertTrue(svg.contains("data:image/png;base64,"))
    XCTAssertEqual(shape.kind,"rectangle");XCTAssertEqual(shape.paintStack?.first?.paint.asset,"image.png")
  }
  func testCompoundPaintSVGKeepsHolesAndSkipsRetainedDisabledStroke()throws {
    let path=CGMutablePath();path.addRect(.init(x:0,y:0,width:40,height:40));path.addRect(.init(x:10,y:10,width:20,height:20))
    var element=try VectorGeometry.element(from:path,color:"#CC0000");element.path!.evenOdd=true
    var disabled=ArtworkStroke(color:"#000000",width:3);disabled.enabled=false
    element.paintStack=[.init(.init(color:"#CC0000")),.init(.init(color:"#000000"),stroke:disabled)]
    let svg=try SVGRenderer.document(.init(elements:[element]),width:40,height:40,assets:FileManager.default.temporaryDirectory)
    XCTAssertTrue(svg.contains("fill-rule=\"evenodd\""));XCTAssertFalse(svg.contains("fill=\"#000000\""))
  }
  func testPaintedOutsideStrokeContributesToEffectAndExportBounds()throws {
    var element=ArtworkElement(kind:"rectangle",x:0,y:0,width:40,height:40)
    var stroke=ArtworkStroke(color:"#000000",width:6);stroke.alignment="outside";stroke.join="round"
    element.paintStack=[.init(.init(color:"#0022CC"),stroke:stroke)]
    var blur=ArtworkBlur();blur.radius=0.25;element.blur=blur
    let art=Artwork(elements:[element]),tree=ArtworkRenderTree(art,assets:FileManager.default.temporaryDirectory,production:true,excluding:[])
    let bounds=tree.localBounds(element)
    XCTAssertEqual(bounds.minX,-7,accuracy:1e-6);XCTAssertEqual(bounds.maxX,47,accuracy:1e-6)
    XCTAssertTrue(element.hasVisualOverflow);XCTAssertGreaterThanOrEqual(art.visualBounds(of:element).width,54)
  }
}

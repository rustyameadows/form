import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class ArtworkEffectStackTests: XCTestCase {
  private func image(_ rect:CGRect = .init(x:20,y:20,width:24,height:24),alpha:Double=1)->CGImage {
    let context=CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red:1,green:1,blue:1,alpha:alpha));context.fill(rect)
    return context.makeImage()!
  }
  private func pixel(_ image:CGImage,_ x:Int,_ y:Int)->NSColor {
    NSBitmapImageRep(cgImage:image).colorAt(x:x,y:y)!
  }
  private func count(_ image:CGImage)->Int {
    let bitmap=NSBitmapImageRep(cgImage:image)
    var result=0
    for y in 0..<image.height {for x in 0..<image.width {if bitmap.colorAt(x:x,y:y)!.alphaComponent>0.9 {result+=1}}}
    return result
  }
  func testOrderedLayersKeepBackdropBlendSeparateAndNeverCastFromEarlierShadows() throws {
    let stack=ArtworkEffectStack(effects:[.init(kind:"drop-shadow",offset:.init(8,0),color:"#FF0000",blendMode:"multiply"),
      .init(kind:"drop-shadow",offset:.init(-8,0),color:"#0000FF",blendMode:"screen"),.init(kind:"inner-shadow",offset:.init(3,0))])
    let raster=try EffectStackRenderer.render(source:image(),stack:stack,density:1)
    XCTAssertEqual(raster.behind.map(\.blendMode),["multiply","screen"]);XCTAssertEqual(raster.above.count,1)
    XCTAssertGreaterThan(pixel(raster.behind[0].image,50,30).redComponent,0.98)
    XCTAssertEqual(pixel(raster.behind[1].image,50,30).alphaComponent,0,accuracy:0.01)
    XCTAssertGreaterThan(pixel(raster.behind[1].image,14,30).blueComponent,0.98)
    XCTAssertEqual(pixel(raster.content,50,30).alphaComponent,0,accuracy:0.01)
    XCTAssertEqual(raster.byteCost,64*64*4*4)
    let backdrop=CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    backdrop.setFillColor(CGColor(red:0,green:1,blue:1,alpha:1));backdrop.fill(.init(x:0,y:0,width:64,height:64))
    backdrop.setBlendMode(AppearanceRenderer.blend(raster.behind[0].blendMode))
    backdrop.draw(raster.behind[0].image,in:.init(x:0,y:0,width:64,height:64))
    let mixed=pixel(backdrop.makeImage()!,50,30)
    XCTAssertLessThan(mixed.redComponent,0.02);XCTAssertLessThan(mixed.greenComponent,0.02)
    XCTAssertLessThan(mixed.blueComponent,0.02,"Red Multiply over cyan must use the destination, not a flattened transparent layer")
  }
  func testPaintOutlineIgnoresPartialPaintAlphaAndKnockoutUsesItsOwnCoverage() throws {
    let source=image(alpha:0.2),coverage=image(),effect=ArtworkEffect(kind:"drop-shadow",color:"#FF0000")
    let legacy=try EffectStackRenderer.render(source:source,stack:.init(effects:[effect]),density:1)
    let outlined=try EffectStackRenderer.render(source:source,casting:coverage,knockout:coverage,
      stack:.init(coverage:"paint-outline",effects:[effect]),density:1)
    XCTAssertEqual(pixel(legacy.behind[0].image,30,30).alphaComponent,0.2,accuracy:0.02)
    XCTAssertEqual(pixel(outlined.behind[0].image,30,30).alphaComponent,1,accuracy:0.01)
    var cut=effect;cut.knockout=true;cut.offset = .init(10,0)
    let result=try EffectStackRenderer.render(source:source,casting:coverage,knockout:coverage,
      stack:.init(coverage:"paint-outline",effects:[cut]),density:1)
    XCTAssertEqual(pixel(result.behind[0].image,35,30).alphaComponent,0,accuracy:0.01)
    XCTAssertEqual(pixel(result.behind[0].image,50,30).alphaComponent,1,accuracy:0.01)
  }
  func testSignedSpreadGrowsAndErodesCoverageBeforeOffset() throws {
    let source=image()
    let positive=try EffectStackRenderer.render(source:source,stack:.init(effects:[.init(kind:"drop-shadow",spread:3)]),density:1)
    let negative=try EffectStackRenderer.render(source:source,stack:.init(effects:[.init(kind:"drop-shadow",spread:-3)]),density:1)
    XCTAssertGreaterThan(count(positive.behind[0].image),count(source))
    XCTAssertLessThan(count(negative.behind[0].image),count(source))
    XCTAssertGreaterThan(pixel(positive.behind[0].image,18,30).alphaComponent,0.9)
    XCTAssertLessThan(pixel(negative.behind[0].image,21,30).alphaComponent,0.1)
  }
  func testInnerShadowUsesTranslatedInverseAndRemainsInsideCoverage() throws {
    let raster=try EffectStackRenderer.render(source:image(),stack:.init(effects:[.init(kind:"inner-shadow",offset:.init(4,0),color:"#FF0000")]),density:1)
    XCTAssertEqual(raster.above.count,1);XCTAssertTrue(raster.behind.isEmpty)
    let shadow=raster.above[0].image
    XCTAssertGreaterThan(pixel(shadow,21,30).alphaComponent,0.9)
    XCTAssertEqual(pixel(shadow,30,30).alphaComponent,0,accuracy:0.01)
    XCTAssertEqual(pixel(shadow,18,30).alphaComponent,0,accuracy:0.01)
    let spread=try EffectStackRenderer.render(source:image(),stack:.init(effects:[.init(kind:"inner-shadow",spread:3)]),density:1)
    XCTAssertGreaterThan(pixel(spread.above[0].image,21,30).alphaComponent,0.9)
    XCTAssertEqual(pixel(spread.above[0].image,30,30).alphaComponent,0,accuracy:0.01)
  }
  func testForegroundBlurEnclosesShadowAndEditableSourceTogether() throws {
    let raster=try EffectStackRenderer.render(source:image(.init(x:10,y:20,width:10,height:10)),
      stack:.init(effects:[.init(kind:"drop-shadow",offset:.init(20,0),color:"#FF0000"),.init(kind:"blur",blur:2)]),density:1)
    XCTAssertTrue(raster.behind.isEmpty);XCTAssertTrue(raster.above.isEmpty)
    XCTAssertGreaterThan(pixel(raster.content,42,38).alphaComponent,0.01,"The shadow, not only the source, must blur")
    XCTAssertLessThan(pixel(raster.content,30,38).alphaComponent,0.9)
  }
  func testOutlineRequiresBothSameSizeMasksAndBoundsBudgetFailsBeforeRendering() throws {
    let stack=ArtworkEffectStack(coverage:"paint-outline",effects:[.init(kind:"drop-shadow")])
    XCTAssertThrowsError(try EffectStackRenderer.render(source:image(),stack:stack,density:1))
    XCTAssertThrowsError(try EffectStackRenderer.render(source:image(),casting:image(),knockout:image(),stack:stack,density:.infinity))
    XCTAssertThrowsError(try EffectStackRenderer.render(source:image(),stack:.init(effects:[.init(kind:"drop-shadow",blur:50)]),density:1e100))
    let many=ArtworkEffectStack(effects:Array(repeating:.init(kind:"drop-shadow"),count:16))
    XCTAssertLessThan(EffectStackRenderer.maximumPixelsPerRender(many),EffectStackRenderer.maximumPixelsPerRender(stack))
    XCTAssertLessThanOrEqual(EffectStackRenderer.maximumPixelsPerRender(many)*22,32_000_000)
  }
  func testModelBoundsValidationAndLosslessCodable() throws {
    let stack=ArtworkEffectStack(coverage:"paint-outline",effects:[.init(kind:"drop-shadow",offset:.init(8,-2),blur:1,spread:2,
      color:"#AA2244",opacity:0.4,blendMode:"multiply",knockout:true),.init(kind:"inner-shadow",blur:3)])
    try stack.validate()
    let bounds=stack.expandedBounds(.init(0,0,10,10))
    XCTAssertEqual(bounds,.init(0,-8,24,22))
    XCTAssertEqual(try JSONDecoder().decode(ArtworkEffectStack.self,from:JSONEncoder().encode(stack)),stack)
    XCTAssertThrowsError(try ArtworkEffectStack(effects:Array(repeating:.init(kind:"blur"),count:17)).validate())
    XCTAssertThrowsError(try ArtworkEffectStack(effects:[.init(kind:"drop-shadow",blur:.nan)]).validate())
    XCTAssertThrowsError(try ArtworkEffectStack(effects:[.init(kind:"blur",spread:1)]).validate())
  }
  func testSilhouetteProxiesPreserveLiveGeometryAndIgnoreZeroPaints() throws {
    var text=ArtworkElement(kind:"text",x:0,y:0,width:30,height:20,text:"A😀",color:"#FF0000")
    text.opacity=0.1;text.fillOpacity=0.2
    let live=try XCTUnwrap(EffectSilhouetteRenderer.element(text,knockout:false))
    XCTAssertEqual(live.text,"A😀");XCTAssertNil(live.path);XCTAssertNil(live.opacity);XCTAssertEqual(live.fillOpacity,1)
    XCTAssertEqual(text.fillOpacity,0.2)
    var stops=[GradientStop(0,"#FF0000"),GradientStop(1,"#0000FF")]
    stops[0].opacity=0;stops[1].opacity=0
    text.paintStack=[.init(.init(kind:"gradient",gradient:.init(kind:"linear",stops:stops)))]
    XCTAssertEqual(EffectSilhouetteRenderer.element(text,knockout:false)?.paintStack,[])
    XCTAssertEqual(EffectSilhouetteRenderer.element(text,knockout:true)?.paintStack?.count,1)
    text.opacity=0;XCTAssertNil(EffectSilhouetteRenderer.element(text,knockout:false))
    var shape=ArtworkElement(kind:"rectangle",x:0,y:0,width:10,height:10);shape.fillEnabled=false
    shape.stroke = .init(width:2);shape.stroke?.opacity=0
    XCTAssertNil(EffectSilhouetteRenderer.element(shape,knockout:false)?.stroke)
    XCTAssertEqual(EffectSilhouetteRenderer.element(shape,knockout:true)?.fillEnabled,true)
    shape.paintStack=[.init(.init(color:"#FFFFFF"),stroke:shape.stroke)]
    XCTAssertEqual(EffectSilhouetteRenderer.element(shape,knockout:false)?.paintStack,[])
  }
  func testCurvedSpreadUsesAnalyticOutlinesAndStrokeRings() throws {
    var ellipse=ArtworkElement(kind:"ellipse",x:0,y:0,width:24,height:24)
    let grown=try XCTUnwrap(EffectSilhouetteRenderer.spreadPath(ellipse,spread:3,inner:false))
    XCTAssertEqual(grown.boundingBoxOfPath,CGRect(x:-3,y:-3,width:30,height:30))
    XCTAssertFalse(grown.contains(.init(x:-2,y:-2)),"Ellipse spread must retain an oval rather than square dilation corners")
    let shrunk=try XCTUnwrap(EffectSilhouetteRenderer.spreadPath(ellipse,spread:3,inner:true))
    XCTAssertEqual(shrunk.boundingBoxOfPath,CGRect(x:3,y:3,width:18,height:18))
    XCTAssertTrue(try XCTUnwrap(EffectSilhouetteRenderer.spreadPath(ellipse,spread:20,inner:true)).isEmpty)
    ellipse.fillEnabled=false;ellipse.stroke = .init(width:4)
    let ring=try XCTUnwrap(EffectSilhouetteRenderer.spreadPath(ellipse,spread:3,inner:false))
    XCTAssertFalse(ring.contains(.init(x:12,y:12)));XCTAssertTrue(ring.contains(.init(x:-4,y:12)))
    XCTAssertNil(EffectSilhouetteRenderer.spreadPath(ellipse,spread:3,inner:true))
  }
  func testPreparedSpreadIsUsedOnceAndInnerInvertsPreparedCoverage() throws {
    let source=image(),expanded=image(.init(x:16,y:16,width:32,height:32))
    var calls=0
    let result=try EffectStackRenderer.render(source:source,casting:source,knockout:source,
      stack:.init(coverage:"paint-outline",effects:[.init(kind:"drop-shadow",spread:4)]),density:1,
      spreadCoverage:{_ in calls+=1;return expanded})
    XCTAssertEqual(calls,1);XCTAssertEqual(pixel(result.behind[0].image,17,30).alphaComponent,1,accuracy:0.01)
    XCTAssertEqual(pixel(result.behind[0].image,14,30).alphaComponent,0,accuracy:0.01,"Prepared coverage must not be dilated twice")
    let shrunk=image(.init(x:24,y:24,width:16,height:16))
    let inner=try EffectStackRenderer.render(source:source,casting:source,knockout:source,
      stack:.init(coverage:"paint-outline",effects:[.init(kind:"inner-shadow",spread:4)]),density:1,
      spreadCoverage:{_ in shrunk})
    XCTAssertEqual(pixel(inner.above[0].image,21,30).alphaComponent,1,accuracy:0.01)
    XCTAssertEqual(pixel(inner.above[0].image,30,30).alphaComponent,0,accuracy:0.01)
  }
}

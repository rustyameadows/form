import AppKit
import XCTest
@testable import FormApp

@MainActor final class CanvasGenerationPixelSizeTests: XCTestCase {
  func testCustomRatiosUseSharedResolutionWithoutChangingStudioPresets() throws {
    for size in StudioGenerationSize.allCases {
      for shape in StudioGenerationAspect.allCases {
        var options = StudioImageGenerationOptions(); options.size = size; options.aspect = shape
        let request = StudioGenerationRequest(prompt:"Fixture",style:"",references:[],options:options)
        XCTAssertNil(request.canvasOutputPixels)
        XCTAssertEqual(request.outputPixels.width,options.pixels.width)
        XCTAssertEqual(request.outputPixels.height,options.pixels.height)
        XCTAssertNoThrow(try request.validateOutputPixels())
      }
      let custom = try StudioGenerationPixelSize.canvas(widthMM:117,heightMM:234,size:size)
      XCTAssertEqual(custom.width,size.longEdge/2); XCTAssertEqual(custom.height,size.longEdge)
      let wide = try StudioGenerationPixelSize.canvas(widthMM:800,heightMM:100,size:size)
      XCTAssertEqual(wide.width,size.longEdge); XCTAssertEqual(wide.height,size.longEdge/8)
      let tall = try StudioGenerationPixelSize.canvas(widthMM:100,heightMM:800,size:size)
      XCTAssertEqual(tall.width,size.longEdge/8); XCTAssertEqual(tall.height,size.longEdge)
    }
    for dimensions in [(0.0,20.0),(Double.infinity,20),(Double.nan,20),(1,9),(9,1),(-1,2)] {
      XCTAssertThrowsError(try StudioGenerationPixelSize.canvas(widthMM:dimensions.0,heightMM:dimensions.1,size:.small))
    }
  }
  func testCustomOutputIsBoundedAndRejectedForStudioRatherThanChangingSceneShape() throws {
    var options = StudioImageGenerationOptions(); options.size = .small
    for pixels in [StudioGenerationPixelSize(width:0,height:512),.init(width:32,height:512),
      .init(width:1024,height:1024),.init(width:Int.max,height:512),.init(width:100,height:100)] {
      let request = StudioGenerationRequest(prompt:"Fixture",style:"",references:[],options:options,
        source:.canvas,canvasOutputPixels:pixels)
      XCTAssertThrowsError(try StudioGenerationDemoRenderer.prepare(request))
      XCTAssertThrowsError(try StudioGenerationDemoRenderer.render(request,input:.init(scene:nil,references:[]),index:0))
    }
    let studio = StudioGenerationRequest(prompt:"Fixture",style:"",references:[],options:options,
      canvasOutputPixels:.init(width:512,height:512))
    XCTAssertThrowsError(try studio.validateOutputPixels())
  }
  func testLocalProviderProducesExactCustomPixelsIncludingBothExtremeShapes() async throws {
    var options = StudioImageGenerationOptions(); options.size = .small
    for pixels in [StudioGenerationPixelSize(width:512,height:204),.init(width:64,height:512),.init(width:512,height:64)] {
      let request = StudioGenerationRequest(prompt:"Custom shape",style:"",references:[],options:options,
        source:.canvas,canvasOutputPixels:pixels)
      let result = try await LocalStudioImageGenerationProvider(delayNanoseconds:0).generate(request,progress:{_ in})
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data:XCTUnwrap(result.first)))
      XCTAssertEqual(bitmap.pixelsWide,pixels.width); XCTAssertEqual(bitmap.pixelsHigh,pixels.height)
    }
  }
}

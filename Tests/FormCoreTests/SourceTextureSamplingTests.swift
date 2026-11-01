import Foundation
import FormGraphics
import XCTest

final class SourceTextureSamplingTests: XCTestCase {
  func testWholeCaptureBudgetIsSharedRatherThanRepeatedPerSurface() throws {
    let targets = (0..<64).map { SourceTextureSamplingTarget(id:String($0),sourceWidth:100,sourceHeight:70,
      projectedEdgePixels:6000,visibleWeight:1_000_000) }
    let result = try SourceTextureSampling.allocate(targets,pixelBudget:1_000_000)
    XCTAssertEqual(result.count,64)
    XCTAssertLessThanOrEqual(result.values.reduce(0){$0+$1.maximumPixels},1_000_000)
    for plan in result.values {
      let size = try plan.rasterSize(width:100,height:70)
      XCTAssertLessThanOrEqual(size.width*size.height,plan.maximumPixels)
      XCTAssertLessThan(size.width,6000)
    }
    XCTAssertEqual(result,try SourceTextureSampling.allocate(Array(targets.reversed()),pixelBudget:1_000_000))
    let fullCapture = try SourceTextureSampling.allocate(targets)
    let charged = fullCapture.values.reduce(0){$0+$1.maximumPixels}*SourceTextureSampling.chargedBytesPerPixel
    XCTAssertLessThanOrEqual(charged,SourceTextureSampling.maximumSourceBytes)
  }
  func testVisibleFaceGetsDetailWhileReverseAndOffscreenKeepSmallFallback() throws {
    let targets: [SourceTextureSamplingTarget] = [
      .init(id:"front",sourceWidth:96,sourceHeight:24,projectedEdgePixels:4096,visibleWeight:2_000_000),
      .init(id:"back",sourceWidth:96,sourceHeight:24,projectedEdgePixels:4096,visibleWeight:0),
      .init(id:"offscreen",sourceWidth:96,sourceHeight:24,projectedEdgePixels:8000,visibleWeight:0),
    ]
    let result = try SourceTextureSampling.allocate(targets)
    let front = try XCTUnwrap(result["front"]),back = try XCTUnwrap(result["back"])
    XCTAssertGreaterThan(try front.rasterSize(width:96,height:24).width,2048)
    XCTAssertLessThanOrEqual(back.maximumPixels,64)
    XCTAssertLessThanOrEqual(try XCTUnwrap(result["offscreen"]).maximumPixels,64)
  }
  func testRasterSizePreservesAspectAndCapsFiniteExtremeDimensions() throws {
    let plan = SourceTextureRasterPlan(maximumEdge:8192,maximumPixels:800_000)
    for (width,height) in [(96.0,24.0),(1.0,100_000.0),(1e150,1e149)] {
      let size = try plan.rasterSize(width:width,height:height)
      XCTAssertGreaterThan(size.width,0);XCTAssertGreaterThan(size.height,0)
      XCTAssertLessThanOrEqual(max(size.width,size.height),8192)
      XCTAssertLessThanOrEqual(size.width*size.height,800_000)
      if width/height > 0.01 {
        // Each floored axis may lose less than one pixel. A short-axis pixel
        // corresponds to aspect pixels on the long axis; a fixed ratio epsilon
        // would reject correct, deliberately bounded integer raster sizes.
        let aspect = width/height
        XCTAssertEqual(Double(size.width),Double(size.height)*aspect,accuracy:max(1,aspect))
      }
    }
    XCTAssertThrowsError(try plan.rasterSize(width:.nan,height:1))
    XCTAssertThrowsError(try SourceTextureRasterPlan(maximumEdge:8193,maximumPixels:100).rasterSize(width:1,height:1))
    XCTAssertThrowsError(try SourceTextureSampling.allocate([.init(id:"bad",sourceWidth:1,sourceHeight:1,
      projectedEdgePixels:.infinity,visibleWeight:1)]))
  }
  func testSamplingIntentRoundTripsWithoutChangingResolutionOrFinalPurpose() throws {
    let plan = SourceTextureSamplingPlan(raster:.init(maximumEdge:4096,maximumPixels:1_000_000),
      surfaces:[SourceTextureSamplingPlan.paperFace("panel",inside:false):.init(maximumEdge:3072,maximumPixels:900_000)],
      isFinalCapture:true)
    let decoded = try JSONDecoder().decode(SourceTextureSamplingPlan.self,from:JSONEncoder().encode(plan))
    XCTAssertEqual(decoded,plan)
    XCTAssertTrue(decoded.isFinalCapture)
    XCTAssertFalse(SourceTextureSamplingPlan(raster:plan.raster).isFinalCapture)
  }
}

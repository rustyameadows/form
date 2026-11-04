import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class PaperTextureSamplingTests:XCTestCase {
  func testMagnifiedPlainWeaveNormalsFollowIndependentWarpAndWeftRatherThanDiagonalWaves()throws {
    let maps=try PaperSurfaceRasterizer.make(rect:.init(x:0,y:0,width:9,height:9),netSize:.init(9,9),profile:.init(texture:.linen,color:"#244747",roughness:0.9,textureScaleMM:0.9,textureDepthMM:0.035),color:"#244747",grain:.parallelWidth,artwork:nil,finishes:[],assets:FileManager.default.temporaryDirectory,maximumEdge:256,pixelBudget:256*256)
    let image=try XCTUnwrap(maps.normal.cgImage(forProposedRect:nil,context:nil,hints:nil)),data=try XCTUnwrap(image.dataProvider?.data),pixels=try XCTUnwrap(CFDataGetBytePtr(data))
    var xMeans=[Double](repeating:0,count:image.width),yMeans=[Double](repeating:0,count:image.height),total=0.0
    for y in 0..<image.height {for x in 0..<image.width {
      let p=y*image.bytesPerRow+x*4,nx=Double(pixels[p])-128,ny=Double(pixels[p+1])-128
      xMeans[x]+=nx/Double(image.height);yMeans[y]+=ny/Double(image.width);total+=nx*nx+ny*ny
    }}
    let coherent=xMeans.reduce(0){$0+$1*$1}*Double(image.height)+yMeans.reduce(0){$0+$1*$1}*Double(image.width)
    XCTAssertGreaterThan(total/Double(image.width*image.height),10,"Magnified cloth retains its real material depth.")
    XCTAssertGreaterThan(coherent/total,0.5,"Plain weave must preserve orthogonal yarn normals; a saddle/product field creates diagonal bands even with perfect mipmaps.")
  }
  func testUnresolvedPhysicalThreadsCannotBecomeCoarseColorOrNormalBands()throws {
    func maps(_ texture:PaperSurfaceProfile.Texture,span:Double,edge:Int)throws->PaperSurfaceRasterizer.Maps {
      try PaperSurfaceRasterizer.make(rect:.init(x:3.7,y:8.3,width:span,height:span),netSize:.init(200,200),
        profile:.init(texture:texture,color:"#9C927B",roughness:0.8,textureScaleMM:0.8,textureDepthMM:0.035),
        color:"#9C927B",grain:.parallelWidth,artwork:nil,finishes:[],assets:FileManager.default.temporaryDirectory,
        maximumEdge:edge,pixelBudget:edge*edge)
    }
    func channels(_ image:NSImage)throws->[[UInt8]] {
      let image=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)),data=try XCTUnwrap(image.dataProvider?.data),bytes=try XCTUnwrap(CFDataGetBytePtr(data))
      return (0..<3).map{channel in (0..<image.height).flatMap{y in (0..<image.width).map{x in bytes[y*image.bytesPerRow+x*4+channel]}}}
    }
    for texture in [PaperSurfaceProfile.Texture.laid,.linen] {
      // One physical millimeter per texel cannot resolve a 0.8mm thread.
      let coarse=try maps(texture,span:128,edge:128),normal=try channels(coarse.normal)
      XCTAssertEqual(Set(normal[0]),[128]);XCTAssertEqual(Set(normal[1]),[128]);XCTAssertEqual(Set(normal[2]),[255])
      for channel in try channels(coarse.color) {XCTAssertEqual(Set(channel).count,1,"Unresolved substrate texture must average away rather than draw false low-frequency bands.")}
      let close=try maps(texture,span:8,edge:256),fine=try channels(close.normal)
      let energy=sqrt(zip(fine[0],fine[1]).reduce(0.0){sum,pair in sum+pow(Double(pair.0)-128,2)+pow(Double(pair.1)-128,2)}/Double(fine[0].count))
      XCTAssertGreaterThan(energy,3,"A magnified physical surface must retain real tooth instead of globally disabling its material.")
      XCTAssertNotEqual(coarse.revision,close.revision)
    }
  }
  func testAnisotropicFootprintOnlyFiltersTheUnresolvedPhysicalDirection() {
    let profile=PaperSurfaceProfile(texture:.laid,roughness:0.9,textureScaleMM:0.8,textureDepthMM:0.04)
    let footprint=Point2(1.6,0.004)
    let across=PaperSurfaceRasterizer.toothHeight(x:0.31,y:0.2,profile:profile,grain:.parallelWidth,footprintMM:footprint)
    let along=PaperSurfaceRasterizer.toothHeight(x:0.31,y:0.2,profile:profile,grain:.parallelHeight,footprintMM:footprint)
    XCTAssertGreaterThan(abs(across),profile.textureDepthMM*0.3,"A wide texel must preserve laid lines resolved along its narrow axis.")
    XCTAssertEqual(along,0,accuracy:1e-14,"Rotating grain into the unresolved axis must not alias.")
    var scaled=profile;scaled.textureScaleMM*=3
    XCTAssertEqual(across,PaperSurfaceRasterizer.toothHeight(x:0.93,y:0.6,profile:scaled,grain:.parallelWidth,footprintMM:.init(4.8,0.012)),accuracy:1e-14,"Coordinates and footprint scale together in physical millimeters.")
  }
  func testFineFootprintRetainsAuthoredToothAndCutoffRemainsFiniteAndContinuous() {
    for texture in [PaperSurfaceProfile.Texture.laid,.linen,.cotton] {
      let profile=PaperSurfaceProfile(texture:texture,roughness:0.85,textureScaleMM:0.8,textureDepthMM:0.03)
      var fineError=0.0,energy=0.0
      for i in 0..<64 {
        let x=Double(i)*0.037+0.19,y=Double(i)*0.061+0.23
        let exact=PaperSurfaceRasterizer.toothHeight(x:x,y:y,profile:profile,grain:.parallelWidth)
        let fine=PaperSurfaceRasterizer.toothHeight(x:x,y:y,profile:profile,grain:.parallelWidth,footprintMM:.init(0.004,0.004))
        fineError+=pow(fine-exact,2);energy+=pow(exact,2)
        let before=PaperSurfaceRasterizer.toothHeight(x:x,y:y,profile:profile,grain:.parallelWidth,footprintMM:.init(0.399999,0.399999))
        let after=PaperSurfaceRasterizer.toothHeight(x:x,y:y,profile:profile,grain:.parallelWidth,footprintMM:.init(0.400001,0.400001))
        XCTAssertTrue(before.isFinite && after.isFinite);XCTAssertEqual(before,after,accuracy:1e-6)
      }
      XCTAssertLessThan(sqrt(fineError/energy),0.01,"Fine physical samples retain the established material rather than changing its millimeter scale or contrast.")
    }
  }
}

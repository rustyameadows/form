import AppKit
import FormCore
import FormGeometry
import XCTest
@testable import FormApp

@MainActor final class PaperShoulderRenderingTests:XCTestCase {
  func testPhysicalShoulderRadiusUsesBothPixelDimensionsAndSurvivesResolutionChanges() {
    func profile(width:Int,height:Int,dx:Double,dy:Double,vertical:Bool)->[Float] {
      let values=(0..<width*height).map {i->Float in (vertical ? i/width>=height/2:i%width>=width/2) ? 1:0}
      return PaperSurfaceRasterizer.reliefShoulder(values,width:width,height:height,dx:dx,dy:dy,radiusMM:0.2)
    }
    let wide=profile(width:800,height:20,dx:0.01,dy:0.1,vertical:false)
    let tall=profile(width:20,height:800,dx:0.1,dy:0.01,vertical:true)
    let higher=profile(width:1600,height:20,dx:0.005,dy:0.1,vertical:false)
    for offset in [-0.3,-0.1,0.0,0.1,0.3] {
      let a=wide[10*800+400+Int(offset/0.01)]
      let b=tall[(400+Int(offset/0.01))*20+10]
      let c=higher[10*1600+800+Int(offset/0.005)]
      XCTAssertEqual(a,b,accuracy:1e-6,"Physical axes must agree even when pixels are ten times taller than wide.")
      XCTAssertEqual(a,c,accuracy:0.015,"Higher quality must not narrow the shoulder.")
    }
    XCTAssertEqual(wide[10*800+410],0.875,accuracy:0.015,"A tent shoulder has a smooth ramp, not a one-texel wall.")
    XCTAssertEqual(wide[10*800+370],0);XCTAssertEqual(wide[10*800+430],1)
    let tiny:[Float]=[0,0,1,1]
    XCTAssertEqual(PaperSurfaceRasterizer.reliefShoulder(tiny,width:4,height:1,dx:0.01,dy:0.01,radiusMM:0),tiny)
    let broad=PaperSurfaceRasterizer.reliefShoulder(tiny,width:4,height:1,dx:0.001,dy:0.001,radiusMM:2)
    XCTAssertTrue(broad.allSatisfy{$0.isFinite && (0...1).contains($0)})
    let constant=[Float](repeating:1,count:800*3)
    for radius in [1e-9,1e-15,Double.leastNonzeroMagnitude] {
      XCTAssertEqual(PaperSurfaceRasterizer.reliefShoulder(constant,width:800,height:3,dx:0.01,dy:0.1,radiusMM:radius),constant,
        "A tiny valid radius must not corrupt a constant surface through prefix-sum cancellation.")
    }
  }
  func testShoulderChangesOnlyReliefAndLeavesCrispPaintAndFinishMasks()throws {
    let mark=ArtworkElement(kind:"rectangle",x:4,y:4,width:8,height:8,color:"#FFFFFF")
    var artwork=Artwork(elements:[mark]);artwork.backgroundOpacity=0
    var finish=PaperFinishAssignment(name:"Stamped mark",kind:.foil,elementIDs:[mark.id],color:"#C69741",heightMM:0.12,roughness:0.2,metallic:1)
    func maps(_ finish:PaperFinishAssignment)throws->PaperSurfaceRasterizer.Maps {
      try PaperSurfaceRasterizer.make(rect:.init(x:0,y:0,width:16,height:16),netSize:.init(16,16),
        profile:.init(texture:.smooth,textureDepthMM:0),color:"#FFFFFF",grain:.unknown,artwork:artwork,
        finishes:[finish],assets:FileManager.default.temporaryDirectory,maximumEdge:512,pixelBudget:512*512)
    }
    func bytes(_ image:NSImage)throws->Data {
      let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
      return try XCTUnwrap(cg.dataProvider?.data) as Data
    }
    let legacy=try maps(finish)
    finish.shoulderRadiusMM=0
    let sharp=try maps(finish)
    finish.shoulderRadiusMM=0.2
    let soft=try maps(finish)
    XCTAssertNotEqual(soft.finishReliefMM,sharp.finishReliefMM)
    XCTAssertNotEqual(soft.reliefRevision,sharp.reliefRevision)
    XCTAssertEqual(soft.finishReliefMM?.max(),0.12)
    for pair in [(soft.color,sharp.color),(soft.metallic,sharp.metallic),(soft.roughness,sharp.roughness),
                 (soft.physicalLayers[0].mask,sharp.physicalLayers[0].mask)] {
      XCTAssertEqual(try bytes(pair.0),try bytes(pair.1),"Relief shoulders must not grow or blur printed/foil artwork.")
    }
    XCTAssertNotEqual(try bytes(soft.physicalNormal),try bytes(sharp.physicalNormal))
    finish.shoulderRadiusMM=nil
    XCTAssertTrue(try maps(finish) === legacy,"Removing the explicit shoulder restores the exact cached legacy result.")
  }
  func testEdgeOnlyVariantsReuseImmutableFaceRasters()throws {
    var profile=PaperSurfaceProfile(texture:.cotton,textureScaleMM:0.7,textureDepthMM:0.01)
    func maps()throws->PaperSurfaceRasterizer.Maps {
      try PaperSurfaceRasterizer.make(rect:.init(x:0,y:0,width:21,height:17),netSize:.init(21,17),
        profile:profile,color:"#FAF9F7",grain:.parallelWidth,artwork:nil,finishes:[],
        assets:FileManager.default.temporaryDirectory,maximumEdge:256,pixelBudget:65_536)
    }
    let original=try maps(),builds=PaperSurfaceRasterizer.builds
    profile.edgeAppearance=PhysicalAppearance();profile.edgeAppearance?.normalStrength=0.25
    let first=try maps()
    profile.edgeAppearance?.normalStrength=0.5
    let second=try maps()
    XCTAssertTrue(first === original);XCTAssertTrue(second === original)
    XCTAssertEqual(PaperSurfaceRasterizer.builds,builds,"Independent edges must not duplicate the unchanged face image resources.")
  }
}

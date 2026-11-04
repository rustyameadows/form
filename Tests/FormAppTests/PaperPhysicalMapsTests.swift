import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class PaperPhysicalMapsTests:XCTestCase {
  private func bytes(_ image:NSImage)throws->([UInt8],Int,Int) {
    let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)),data=try XCTUnwrap(cg.dataProvider?.data)
    return (Array(UnsafeBufferPointer(start:CFDataGetBytePtr(data),count:CFDataGetLength(data))),cg.width,cg.height)
  }
  private func maps(_ art:Artwork?,profile:PaperSurfaceProfile = .init(texture:.cotton,roughness:0.8,textureDepthMM:0.02),finishes:[PaperFinishAssignment]=[])throws->PaperSurfaceRasterizer.Maps {
    try PaperSurfaceRasterizer.make(rect:.init(x:0,y:0,width:20,height:20),netSize:.init(20,20),profile:profile,color:"#E8DFC9",grain:.unknown,artwork:art,finishes:finishes,assets:FileManager.default.temporaryDirectory,maximumEdge:128,pixelBudget:128*128)
  }
  func testSourcePaintAlphaOverSubstrateReproducesLegacyInkAndFoil()throws {
    var ink=ArtworkElement(kind:"rectangle",x:2,y:2,width:8,height:8,color:"#2244CC");ink.opacity=0.4
    let foil=ArtworkElement(kind:"rectangle",x:6,y:6,width:8,height:8,color:"#DD8833")
    var art=Artwork(background:"#FFFFFF",elements:[ink,foil]);art.backgroundOpacity=0
    let finish=PaperFinishAssignment(name:"Metallic overlay",kind:.foil,elementIDs:[foil.id],color:"#DD8833",opacity:0.6)
    let result=try maps(art,finishes:[finish]),merged=try bytes(result.color).0,substrate=try bytes(result.substrate).0,paint=try bytes(XCTUnwrap(result.artwork)).0
    XCTAssertEqual(paint[3],0,"Unprinted substrate must remain transparent in the source overlay.")
    for pixel in stride(from:0,to:paint.count,by:4) {
      let alpha=Double(paint[pixel+3])/255
      for channel in 0..<3 {
        let reconstructed=Double(paint[pixel+channel])+Double(substrate[pixel+channel])*(1-alpha)
        XCTAssertEqual(reconstructed,Double(merged[pixel+channel]),accuracy:2)
      }
    }
    XCTAssertEqual(try bytes(maps(nil).substrate).0,substrate)
  }
  func testPhysicalNormalReplacesToothButRetainsFinishReliefAndMaskOrder()throws {
    let first=ArtworkElement(kind:"rectangle",x:2,y:2,width:6,height:6,color:"#222222")
    let second=ArtworkElement(kind:"rectangle",x:12,y:12,width:4,height:4,color:"#222222")
    var art=Artwork(background:"#FFFFFF",elements:[first,second]);art.backgroundOpacity=0
    var appearance=PhysicalAppearance();appearance.textures["normal"] = .init(asset:"normal.png",sha256:String(repeating:"a",count:64))
    var profile=PaperSurfaceProfile(texture:.cotton,roughness:0.8,textureDepthMM:0.02);profile.appearance=appearance
    var emboss=PaperFinishAssignment(name:"Relief",kind:.emboss,elementIDs:[first.id],heightMM:0.12,opacity:0.4)
    emboss.appearance=PhysicalAppearance();emboss.appearance!.coat=0.7
    var ink=PaperFinishAssignment(name:"Second response",kind:.flatInk,elementIDs:[second.id]);ink.appearance=PhysicalAppearance();ink.appearance!.sheen=0.9
    let result=try maps(art,profile:profile,finishes:[emboss,ink])
    let ordinary=try bytes(result.normal).0,physical=try bytes(result.physicalNormal).0
    XCTAssertNotEqual(ordinary,physical)
    // A blank corner is flat, while the raised boundary still changes normals.
    XCTAssertEqual(physical[0],128);XCTAssertEqual(physical[1],128);XCTAssertEqual(physical[2],255)
    XCTAssertTrue(stride(from:0,to:physical.count,by:4).contains{abs(Int(physical[$0])-128)>8 || abs(Int(physical[$0+1])-128)>8})
    XCTAssertEqual(result.physicalLayers.count,2)
    XCTAssertEqual(result.physicalLayers[0].appearance?.coat,0.7);XCTAssertEqual(result.physicalLayers[1].appearance?.sheen,0.9)
    let mask=try bytes(result.physicalLayers[0].mask),center=(32*mask.1+32)*4
    XCTAssertEqual(Double(mask.0[center])/255,0.4,accuracy:1.0/255);XCTAssertEqual(mask.0[0],0)
    var legacy=profile;legacy.appearance=nil
    let unchanged=try maps(art,profile:legacy,finishes:[emboss,ink])
    XCTAssertEqual(try bytes(result.color).0,try bytes(unchanged.color).0)
    XCTAssertEqual(ordinary,try bytes(unchanged.normal).0)
  }
  func testEveryFinishCarriesFactorsWithoutBakingCoverageIntoPhysicalSubstrate()throws {
    let shape=ArtworkElement(kind:"rectangle",x:2,y:2,width:8,height:8,color:"#BB8833")
    var art=Artwork(background:"#FFFFFF",elements:[shape]);art.backgroundOpacity=0
    var profile=PaperSurfaceProfile(texture:.smooth,roughness:0.8,textureDepthMM:0)
    profile.appearance=PhysicalAppearance();profile.appearance?.sheen=0.3
    let finish=PaperFinishAssignment(name:"Partial conductor",kind:.foil,elementIDs:[shape.id],opacity:0.4)
    let result=try maps(art,profile:profile,finishes:[finish]),blank=try maps(nil,profile:profile)
    let layer=try XCTUnwrap(result.physicalLayers.first)
    XCTAssertEqual(result.physicalLayers.count,1);XCTAssertNil(layer.appearance,"No optical override inherits the substrate response.")
    XCTAssertEqual(layer.roughness,0.18);XCTAssertEqual(layer.metallic,1)
    XCTAssertEqual(try bytes(result.physicalRoughness).0,try bytes(blank.physicalRoughness).0)
    XCTAssertEqual(try bytes(result.physicalMetallic).0,try bytes(blank.physicalMetallic).0)
    XCTAssertNotEqual(try bytes(result.roughness).0,try bytes(result.physicalRoughness).0,"Fast retains its combined finish map.")
    let mask=try bytes(layer.mask),center=(32*mask.1+32)*4
    XCTAssertEqual(Double(mask.0[center])/255,0.4,accuracy:1.0/255)
    var disabled=finish;disabled.enabled=false
    XCTAssertTrue(try maps(art,profile:profile,finishes:[disabled]).physicalLayers.isEmpty)
    let crowded=try maps(art,profile:profile,finishes:Array(repeating:finish,count:17))
    XCTAssertTrue(crowded.physicalLayerOverflow);XCTAssertEqual(crowded.physicalLayers.count,16)
  }
}

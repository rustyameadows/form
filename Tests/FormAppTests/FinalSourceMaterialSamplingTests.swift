import AppKit
import FormGeometry
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class FinalSourceMaterialSamplingTests: XCTestCase {
  func testSewnPanelAndNestedRepeatUseFinalDensityWithoutChangingPhysicalSource() throws {
    var project=Project(name:"Physical material sampling")
    var tile=try project.makeObject(recipeID:"artboard",parameters:["width":16,"depth":16])
    tile.artwork=Artwork(background:"#FFFFFF",elements:[.init(kind:"rectangle",x:0,y:0,width:8,height:16,color:"#223355")])
    project.objects=[tile]
    var material=Material("sample-fabric","Sample fabric","Fabric","#FFFFFF")
    material.fabric = .init(composition:"Declared test fabric",structure:.woven)
    material.fabric?.pattern = .init(sourceObjectID:tile.id)
    project.materials=[material]
    let panel=PatternAssemblyPanel(id:.init(elementID:UUID(),copy:1),panelIndex:0,name:"Panel",sourceOriginMm:.init(),
      materialSizeMm:.init(96,24),material:material,densityGSM:180,textureOriginMm:.init(),vertexIndices:[],sourceAreaMm2:2304,meshAreaMm2:2304)
    let source=Artwork(elements:[.init(kind:"text",x:2,y:2,width:80,height:5,text:"Material coordinates remain editable",color:"#111111",fontSize:3)])
    let before=project,plan=SourceTextureRasterPlan(maximumEdge:3072,maximumPixels:3072*768)
    let image=try AssemblyMaterialRenderer.texture(panel:panel,source:source,project:project,
      assets:FileManager.default.temporaryDirectory,fontRevision:0,sampling:plan)
    let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
    XCTAssertEqual(cg.width,3072);XCTAssertEqual(cg.height,768)
    let preview=try AssemblyMaterialRenderer.texture(panel:panel,source:source,project:project,
      assets:FileManager.default.temporaryDirectory,fontRevision:0)
    XCTAssertLessThanOrEqual(try XCTUnwrap(preview.cgImage(forProposedRect:nil,context:nil,hints:nil)).width,1024)
    let resolved=try XCTUnwrap(project.resolvedFabricPattern(materialID:material.id))
    let fineTile=FabricPatternRenderer.texture(resolved,assets:FileManager.default.temporaryDirectory,
      sampling:.init(maximumEdge:512,maximumPixels:512*512))
    let legacyTile=FabricPatternRenderer.texture(resolved,assets:FileManager.default.temporaryDirectory)
    XCTAssertEqual(try XCTUnwrap(fineTile.cgImage(forProposedRect:nil,context:nil,hints:nil)).width,512)
    XCTAssertEqual(try XCTUnwrap(legacyTile.cgImage(forProposedRect:nil,context:nil,hints:nil)).width,320)
    XCTAssertEqual(project,before)
  }
  func testEmbroideryFinalSamplingKeepsExactNeedleProgramAndBoundedPreview() throws {
    var project=Project(name:"Needle material sampling")
    var patch=try project.makeObject(recipeID:"textilePatch",parameters:["width":96,"depth":24,"corner":2])
    let line=ArtworkElement(kind:"line",x:8,y:12,width:80,height:0.1,color:"#223355")
    patch.artwork=Artwork(elements:[line],bleed:0)
    let region=EmbroideryRegion(elementIDs:[line.id],method:.running)
    patch.textile?.embroidery = .init(threads:[.init(name:"Blue",color:"#223355")],regions:[region])
    project.objects=[patch]
    let before=project,plan=SourceTextureRasterPlan(maximumEdge:3072,maximumPixels:3072*768)
    let high=try EmbroiderySurface.resources(object:patch,project:project,sampling:plan)
    let preview=try EmbroiderySurface.resources(object:patch,project:project)
    XCTAssertEqual(high.pixelsWide,3072);XCTAssertEqual(high.pixelsHigh,768)
    XCTAssertLessThanOrEqual(preview.pixelsWide,1024)
    XCTAssertEqual(high.program,preview.program)
    XCTAssertEqual(high.program.sourceDigest,preview.program.sourceDigest)
    XCTAssertEqual(project,before)
  }
}

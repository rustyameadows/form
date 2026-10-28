import AppKit
import FormGeometry
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class AssemblyMaterialTests:XCTestCase {
  private let assets=FileManager.default.temporaryDirectory
  private func panel(origin:Point2 = .init(100,80),size:Point2 = .init(100,80))->PatternAssemblyPanel {
    .init(id:.init(elementID:UUID(),copy:1),panelIndex:0,name:"Physical sample",sourceOriginMm:origin,materialSizeMm:size,material:.init("test-fabric","Test fabric","Fabric","#202020"),densityGSM:180,textureOriginMm:.init(),vertexIndices:[],sourceAreaMm2:size.x*size.y,meshAreaMm2:size.x*size.y)
  }
  private func color(_ image:NSImage,x:Double,y:Double,panel:PatternAssemblyPanel)throws -> NSColor {
    let bitmap=try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
    let px=Int(x/panel.materialSizeMm.x*Double(bitmap.pixelsWide)),py=Int(y/panel.materialSizeMm.y*Double(bitmap.pixelsHigh))
    // Read encoded components with the CGImage's actual sRGB space. AppKit's
    // colorAt returns a Generic RGB NSColor even for this sRGB bitmap.
    XCTAssertEqual(bitmap.cgImage?.colorSpace?.name,CGColorSpace.sRGB)
    var components=[UInt](repeating:0,count:4);bitmap.getPixel(&components,atX:px,y:py)
    return NSColor(srgbRed:Double(components[0])/255,green:Double(components[1])/255,blue:Double(components[2])/255,alpha:Double(components[3])/255)
  }
  func testOnlyExplicitPrintableDecorationDrawsAtSourcePhysicalCoordinates()throws {
    let p=panel()
    var construction=ArtworkElement(kind:"rectangle",x:100,y:80,width:100,height:80,color:"#00FF00")
    construction.sewingPiece = .init(name:"Never implicit ink") // Legacy print role deliberately omitted.
    var red=ArtworkElement(kind:"rectangle",x:110,y:95,width:20,height:10,color:"#FF0000");red.productionRole="print"
    var guide=ArtworkElement(kind:"rectangle",x:150,y:100,width:30,height:30,color:"#0000FF");guide.productionRole="guide"
    var stitch=ArtworkElement(kind:"rectangle",x:180,y:100,width:10,height:30,color:"#FFFF00");stitch.productionRole="stitch"
    let art=Artwork(background:"#FFFFFF",elements:[construction,red,guide,stitch])
    let filtered=try AssemblyMaterialRenderer.decoration(art)
    XCTAssertEqual(filtered.elements.map(\.id),[red.id]);XCTAssertEqual(filtered.backgroundOpacity,0)
    let image=try AssemblyMaterialRenderer.texture(panel:p,source:art,project:Project(name:"Physical print"),assets:assets,fontRevision:0,textureLimit:1000)
    let ink=try color(image,x:20,y:20,panel:p),base=try color(image,x:60,y:30,panel:p)
    let expectedInk=try XCTUnwrap(FormColor.color("#FF0000").usingColorSpace(.sRGB)),expectedBase=try XCTUnwrap(FormColor.color("#202020").usingColorSpace(.sRGB))
    XCTAssertEqual(ink.redComponent,expectedInk.redComponent,accuracy:0.005);XCTAssertEqual(ink.greenComponent,expectedInk.greenComponent,accuracy:0.005)
    XCTAssertEqual(base.redComponent,expectedBase.redComponent,accuracy:0.005);XCTAssertEqual(base.greenComponent,base.redComponent,accuracy:0.001)
    // A20mm stripe remains20mm when the panel grows; it is never fitted to the frame.
    var wider=p;wider.materialSizeMm.x=200
    let bigger=try AssemblyMaterialRenderer.texture(panel:wider,source:art,project:Project(name:"Physical print"),assets:assets,fontRevision:0,textureLimit:1000)
    XCTAssertGreaterThan(try color(bigger,x:29,y:20,panel:wider).redComponent,0.99)
    XCTAssertLessThan(try color(bigger,x:31,y:20,panel:wider).redComponent,0.2)
    var elsewhere=p;elsewhere.sourceOriginMm.x=300
    let other=try AssemblyMaterialRenderer.texture(panel:elsewhere,source:art,project:Project(name:"Physical print"),assets:assets,fontRevision:0)
    XCTAssertLessThan(try color(other,x:20,y:20,panel:elsewhere).redComponent,0.2)
    let bitmap=try XCTUnwrap(other.representations.first as? NSBitmapImageRep)
    XCTAssertLessThanOrEqual(max(bitmap.pixelsWide,bitmap.pixelsHigh),AssemblyMaterialRenderer.maximumTextureEdge)
  }
  func testTextureCacheTracksActualInkFontsMaterialAndLiveRepeatSource()throws {
    AssemblyMaterialRenderer.invalidate()
    var p=panel(),project=Project(name:"Dependencies")
    var ink=ArtworkElement(kind:"rectangle",x:110,y:95,width:20,height:10,color:"#FF0000");ink.productionRole="print"
    var guide=ArtworkElement(kind:"rectangle",x:150,y:100,width:30,height:30,color:"#0000FF");guide.productionRole="guide"
    var art=Artwork(elements:[ink,guide])
    func image(_ panel:PatternAssemblyPanel,_ art:Artwork,_ project:Project,_ revision:Int=0)throws -> NSImage {try AssemblyMaterialRenderer.texture(panel:panel,source:art,project:project,assets:assets,fontRevision:revision)}
    let original=try image(p,art,project),builds=AssemblyMaterialRenderer.textureBuilds
    var nonvisual=p;nonvisual.densityGSM=500;nonvisual.panelIndex=3;nonvisual.name="Renamed copy"
    XCTAssertTrue(try image(nonvisual,art,project) === original)
    art.elements[1].x+=5;XCTAssertTrue(try image(p,art,project) === original)
    XCTAssertEqual(AssemblyMaterialRenderer.textureBuilds,builds)
    art.elements[0].color="#00FF00";XCTAssertFalse(try image(p,art,project) === original)
    let font=try image(p,art,project,1);XCTAssertFalse(try image(p,art,project,2) === font)
    let beforeMaterial=try image(p,art,project);p.material.color="#707070";XCTAssertFalse(try image(p,art,project) === beforeMaterial)
    var tile=try project.makeObject(recipeID:"artboard",parameters:["width":10,"depth":10]);tile.artwork=Artwork(elements:[.init(kind:"rectangle",x:0,y:0,width:5,height:5,color:"#E01234")]);project.objects=[tile]
    p.material.fabric = .init(composition:"Synthetic test",structure:.woven);p.material.fabric?.pattern = .init(sourceObjectID:tile.id)
    let repeated=try image(p,art,project)
    project.objects[0].artwork!.elements[0].color="#22CCFF"
    XCTAssertFalse(try image(p,art,project) === repeated)
  }
  func testPanelMaterialsAndFixedUVsSurviveActualSolverUpdates()throws {
    let (project,definition)=try PatternAssemblySamples.roundedPouch(),product=try PatternAssemblyGenerator.generate(definition,in:project)
    let source=project.objects[0].artwork!
    var byPanel:[Int:MeshMaterial]=[:]
    for p in product.panels {byPanel[p.panelIndex]=try AssemblyMaterialRenderer.material(panel:p,source:source,project:project,assets:assets,fontRevision:0)}
    let builds=AssemblyMaterialRenderer.textureBuilds
    var solver=try ClothSolver(mesh:product.study.mesh,settings:product.study.settings,colliders:product.study.colliders,preparation:product.study.preparation)
    let surface=try ClothSurface(mesh:product.study.mesh,frame:solver.frame,panelMaterials:byPanel,fallbackMaterial:MeshMaterial()),first=try XCTUnwrap(surface.node.geometry),uv=try XCTUnwrap(first.sources(for:.texcoord).first)
    XCTAssertEqual(first.elements.count,4);XCTAssertEqual(first.materials.count,4)
    XCTAssertEqual(first.elements.reduce(0){$0+$1.primitiveCount},product.study.mesh.triangles.count)
    for p in product.panels {
      XCTAssertTrue(first.materials[p.panelIndex].name!.contains(p.id.key))
      let raw=first.elements[p.panelIndex].data
      let indices=raw.withUnsafeBytes{Array($0.bindMemory(to:UInt32.self))}
      XCTAssertTrue(indices.allSatisfy{product.study.mesh.panelIDs![Int($0)]==p.panelIndex})
    }
    try solver.start();try finishAssemblyPreparation(&solver);try solver.advance();try surface.update(solver.frame)
    let after=try XCTUnwrap(surface.node.geometry)
    XCTAssertTrue(after.sources(for:.texcoord).first === uv)
    for i in first.materials.indices {XCTAssertTrue(first.materials[i] === after.materials[i]);XCTAssertTrue(first.elements[i] === after.elements[i])}
    XCTAssertEqual(AssemblyMaterialRenderer.textureBuilds,builds)
  }
}

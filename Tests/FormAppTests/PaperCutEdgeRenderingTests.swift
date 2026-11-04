import AppKit
import CryptoKit
import FormCore
import FormCADModel
import FormGeometry
import FormGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FormApp

@MainActor final class PaperCutEdgeRenderingTests:XCTestCase {
  private func panel(width:Double=40,height:Double=25)->PaperPanel {
    .init(id:"face",name:"Panel",role:.body,polygon:[.init(0,0),.init(width,0),.init(width,height),.init(0,height)],
      cutouts:[.init(id:"window",polygon:[.init(5,5),.init(12,5),.init(12,10),.init(5,10)],kind:.window)])
  }
  private func fixture(stock:PaperStock)throws->(Project,ProductObject) {
    var project=Project(name:"Cut wall mapping"),object=try project.makeObject(recipeID:"paperEnvelope")
    let p=panel(),definition=PlanarConstructionDefinition(name:"Perforated panel",size:.init(40,25),stockThickness:CADScalar(stock.resolvedThicknessMM),panels:[
      .init(id:p.id,name:p.name,polygon:p.polygon.map{.init(CADScalar($0.x),CADScalar($0.y))},cutouts:(p.cutouts ?? []).map{.init(id:$0.id,polygon:$0.polygon.map{.init(CADScalar($0.x),CADScalar($0.y))},kind:$0.kind)})],rootPanelID:p.id)
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:40,height:25,depth:stock.resolvedThicknessMM),stock:stock,foldPercent:0);paper.authored=definition
    object.paperConstruction=paper;object.parameters=PaperConstructionEngine.parameters(paper)
    project.objects=[object];return(project,object)
  }
  private func geometry(stock:PaperStock,assets:URL=FileManager.default.temporaryDirectory)throws->MeshGeometry {
    let (project,object)=try fixture(stock:stock),root=try PaperGeometry.make(object,project:project,assets:assets,limit:128)
    return try XCTUnwrap(root.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true)?.geometry)
  }
  func testMillimeterChartRetainsAllGeometryAndFaceUVsAcrossCalipersAndContours()throws {
    for (width,caliper) in [(20.0,0.12),(40,0.8),(80,2.4)] {
      let p=panel(width:width),size=Point2(width,25)
      let legacy=try PaperGeometry.panelMesh(p,netSize:size,thicknessMM:caliper)
      let edge=try PaperGeometry.panelMesh(p,netSize:size,thicknessMM:caliper,physicalEdgeUV:true)
      for semantic:MeshGeometrySource.Semantic in [.vertex,.normal] {XCTAssertEqual(legacy.sources(for:semantic).first?.data,edge.sources(for:semantic).first?.data)}
      XCTAssertEqual(legacy.elements.map(\.data),edge.elements.map(\.data))
      let points=try XCTUnwrap(edge.sources(for:.vertex).first).vectors,uv=try XCTUnwrap(edge.sources(for:.texcoord).first).points
      let oldUV=try XCTUnwrap(legacy.sources(for:.texcoord).first).points
      for index in Set(edge.elements[0].indices+edge.elements[1].indices) {XCTAssertEqual(uv[Int(index)],oldUV[Int(index)])}
      var outer=[Double](),hole=[Double]()
      for index in Set(edge.elements[2].indices) {
        let i=Int(index),p=points[i];XCTAssertEqual(uv[i].y,p.z*100+caliper/2,accuracy:1e-9)
        if p.x*100>4 && p.x*100<13 && -p.y*100>4 && -p.y*100<11 {hole.append(uv[i].x)}else{outer.append(uv[i].x)}
      }
      XCTAssertEqual(outer.min()!,0,accuracy:1e-9);XCTAssertEqual(outer.max()!,2*(width+25),accuracy:1e-8)
      XCTAssertEqual(hole.min()!,0,accuracy:1e-9);XCTAssertEqual(hole.max()!,24,accuracy:1e-8)
      let indices=edge.elements[2].indices
      for i in stride(from:0,to:indices.count,by:3) {
        let a=uv[Int(indices[i])],b=uv[Int(indices[i+1])],c=uv[Int(indices[i+2])]
        XCTAssertGreaterThan(abs((b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)),1e-12,"Every bevel and wall triangle needs a noncollapsed chart.")
      }
    }
  }
  func testEdgeOpticsDoNotReplaceFaceMaterialsAndPlyRepeatsUseOwnCaliper()throws {
    var face=PhysicalAppearance(),edge=PhysicalAppearance(),override=PhysicalAppearance();face.coat=0.8;edge.sheen=0.35;override.sheen=0.7
    var texture=PhysicalTextureReference(asset:"edge.png",sha256:String(repeating:"a",count:64));texture.scaleMM = .init(0.8,0.12);edge.textures["roughness"]=texture
    var profile=PaperSurfaceProfile(texture:.smooth);profile.appearance=face;profile.edgeAppearance=edge
    var ply=PaperSurfaceProfile();ply.edgeAppearance=override
    var stock=PaperStock(thicknessMM:0.8,profile:profile);stock.plies=[.init(name:"Base",color:"#222222",thicknessMM:0.3),.init(name:"Face",color:"#EEEEEE",thicknessMM:0.5,profile:ply)]
    let mesh=try geometry(stock:stock)
    XCTAssertEqual(mesh.materials[0].physicalAppearance?.coat,0.8);XCTAssertEqual(mesh.materials[1].physicalAppearance?.coat,0.8)
    XCTAssertNil(mesh.materials[0].physicalAppearance?.textures["roughness"])
    XCTAssertEqual(mesh.materials[2].physicalAppearance?.sheen,0.35);XCTAssertEqual(mesh.materials[3].physicalAppearance?.sheen,0.7)
    XCTAssertEqual(mesh.materials[2].physicalAppearance?.textures["roughness"]?.scale,.init(1/0.8,1/0.12))
    let uv=try XCTUnwrap(mesh.sources(for:.texcoord).first).points
    for (slot,caliper) in [(2,0.3),(3,0.5)] {
      let values=Set(mesh.elements[slot].indices).map{uv[Int($0)].y}
      XCTAssertEqual(values.min()!,0,accuracy:1e-10);XCTAssertEqual(values.max()!,caliper,accuracy:1e-10)
    }
    stock.profile!.edgeAppearance=nil;stock.plies![1].profile!.edgeAppearance=nil
    let legacy=try geometry(stock:stock)
    XCTAssertNil(legacy.materials[2].physicalAppearance);XCTAssertNil(legacy.materials[3].physicalAppearance)
    XCTAssertEqual(mesh.sources(for:.vertex).first?.data,legacy.sources(for:.vertex).first?.data)
    XCTAssertEqual(mesh.elements.map(\.data),legacy.elements.map(\.data))
  }
  func testEdgeTexturesUseVerifiedBytesAndRejectChangedOrMissingAssets()throws {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("edge-assets-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:folder)}
    let bytes=Data([128,128,255,255]),provider=try XCTUnwrap(CGDataProvider(data:bytes as CFData))
    let image=try XCTUnwrap(CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let url=folder.appendingPathComponent("edge.png"),destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let hash=SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()
    var optics=PhysicalAppearance();optics.textures["normal"] = .init(asset:"edge.png",sha256:hash)
    var profile=PaperSurfaceProfile();profile.edgeAppearance=optics
    let mesh=try geometry(stock:.init(thicknessMM:0.6,profile:profile),assets:folder),source=try XCTUnwrap(mesh.materials[2].physicalAppearance)
    XCTAssertNotNil(try GeometryPayloadAdapter.physicalPayload(source,assets:folder).textures[.normal])
    try Data([0,1,2]).write(to:url);XCTAssertThrowsError(try GeometryPayloadAdapter.physicalPayload(source,assets:folder))
    try FileManager.default.removeItem(at:url);XCTAssertThrowsError(try GeometryPayloadAdapter.physicalPayload(source,assets:folder))
  }
  func testAdvancedPocketSlicesRetainInheritedEdgesAndFlexInterpolatesPhysicalUVs()throws {
    var inherited=PhysicalAppearance(),local=PhysicalAppearance();inherited.sheen=0.24;local.sheen=0.81
    var stockProfile=PaperSurfaceProfile();stockProfile.edgeAppearance=inherited
    var frontProfile=PaperSurfaceProfile();frontProfile.edgeAppearance=local
    let back=PaperPly(name:"Back",color:"#223344",thicknessMM:0.4,profile:.init(texture:.linen))
    let front=PaperPly(name:"Front",color:"#EEEEDD",thicknessMM:0.6,profile:frontProfile)
    let stock=PaperStock(thicknessMM:1,profile:stockProfile,plies:[back,front])
    let features=try SheetPanelFeatures(recesses:[.init(id:"pocket",origin:.init(15,20),size:.init(40,50),depthMM:0.7)])
      .resolved(size:.init(100,140),stock:stock,variables:[:],face:{_,_ in nil})
    let plane=ResolvedSheetAssemblyPlane(id:"panel",name:"Panel",size:.init(100,140),positionMM:.init(),rotationDegrees:.init(),stock:stock,front:nil,back:nil,finishes:[],features:features.1)
    let layers=try SheetPanelLayerGeometry.layers(plane)
    XCTAssertEqual(layers.map{$0.stock.profile?.edgeAppearance?.sheen},[0.81,0.24,0.24])
    for (layer,caliper) in zip(layers,[0.6,0.1,0.3]) {XCTAssertEqual(layer.stock.resolvedThicknessMM,caliper,accuracy:1e-9)}
    let size=Point2(40,25),base=try PaperGeometry.panelMesh(panel(),netSize:size,thicknessMM:0.8,physicalEdgeUV:true)
    let bent=try SheetPanelFlexGeometry.make(base,size:size,edge:"left",widthMM:8,angleDegrees:70,final:false)
    let uv=try XCTUnwrap(bent.sources(for:.texcoord).first).points,indices=bent.elements[2].indices
    let edgeUV=Set(indices).map{uv[Int($0)]}
    XCTAssertEqual(edgeUV.map(\.x).max()!,130,accuracy:1e-8)
    XCTAssertEqual(edgeUV.map(\.y).max()!,0.8,accuracy:1e-9)
    for i in stride(from:0,to:indices.count,by:3) {
      let a=uv[Int(indices[i])],b=uv[Int(indices[i+1])],c=uv[Int(indices[i+2])]
      XCTAssertGreaterThan(abs((b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)),1e-15)
    }
  }
}

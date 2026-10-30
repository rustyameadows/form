import AppKit
import FormCore
import FormGeometry
import FormGraphics
import LabRendering
import simd
import XCTest
@testable import FormApp

@MainActor final class PaperAppearanceRenderingTests:XCTestCase {
  private let assets=FileManager.default.temporaryDirectory
  private func pixel(_ image:NSImage,_ x:Double,_ y:Double)throws->[Double] {
    let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)),data=try XCTUnwrap(cg.dataProvider?.data)
    let bytes=try XCTUnwrap(CFDataGetBytePtr(data)),i=min(cg.height-1,max(0,Int(y*Double(cg.height))))*cg.bytesPerRow+min(cg.width-1,max(0,Int(x*Double(cg.width))))*4
    return (0..<3).map{Double(bytes[i+$0])/255}
  }
  private func maps(_ artwork:Artwork?,finishes:[PaperFinishAssignment]=[],profile:PaperSurfaceProfile = .init(texture:.smooth,roughness:0.9,textureDepthMM:0),edge:Int=256)throws->PaperSurfaceRasterizer.Maps {
    try PaperSurfaceRasterizer.make(rect:.init(x:0,y:0,width:20,height:20),netSize:.init(20,20),profile:profile,color:"#FFFFFF",grain:.unknown,artwork:artwork,finishes:finishes,assets:assets,maximumEdge:edge,pixelBudget:edge*edge)
  }
  func testCanonicalFinishMasksMoveWithEditableArtworkAndBlindWorkDoesNotPrintItsFill()throws {
    let foil=ArtworkElement(kind:"rectangle",x:2,y:2,width:4,height:4,color:"#222222"),blind=ArtworkElement(kind:"rectangle",x:10,y:2,width:4,height:4,color:"#000000")
    var art=Artwork(background:"#FFFFFF",elements:[foil,blind]);art.backgroundOpacity=0
    let saved=art,finishes:[PaperFinishAssignment]=[
      .init(name:"Gold mark",kind:.foil,elementIDs:[foil.id],color:"#CA9A3D",roughness:0.16),
      .init(name:"Blind type",kind:.emboss,elementIDs:[blind.id],heightMM:0.12)]
    let original=try maps(art,finishes:finishes)
    XCTAssertEqual(try pixel(original.metallic,0.2,0.2)[0],1,accuracy:1.0/255)
    XCTAssertEqual(try pixel(original.roughness,0.2,0.2)[0],0.16,accuracy:1.0/255)
    XCTAssertEqual(try pixel(original.metallic,0.6,0.2)[0],0,accuracy:1.0/255)
    XCTAssertGreaterThan(try pixel(original.color,0.6,0.2)[0],0.99,"Blind source black is an editable tooling outline, not printed black ink.")
    XCTAssertEqual(art,saved,"Deriving viewing maps cannot rewrite the canonical artwork.")
    let normal=try XCTUnwrap(original.normal.cgImage(forProposedRect:nil,context:nil,hints:nil)),normalBytes=try XCTUnwrap(normal.dataProvider?.data)
    let bytes=try XCTUnwrap(CFDataGetBytePtr(normalBytes))
    XCTAssertTrue(stride(from:0,to:CFDataGetLength(normalBytes),by:4).contains{abs(Int(bytes[$0])-128)>12 || abs(Int(bytes[$0+1])-128)>12},"The blind boundary needs a relief normal, not only a changed label.")
    art.elements[0].x=12;art.elements[0].y=12
    let edited=try maps(art,finishes:finishes)
    XCTAssertNotEqual(edited.revision,original.revision)
    XCTAssertEqual(try pixel(edited.metallic,0.2,0.2)[0],0,accuracy:1.0/255)
    XCTAssertEqual(try pixel(edited.metallic,0.7,0.7)[0],1,accuracy:1.0/255)
    XCTAssertEqual(art.elements[0].id,foil.id)
    XCTAssertTrue(try maps(art,finishes:finishes) === edited,"Unchanged resolved source and process settings reuse the same derived maps.")
  }
  func testPaperTextureUsesPhysicalCoordinatesAndPreservesFineSourceAtHigherBoundedQuality()throws {
    let profile=PaperSurfaceProfile(texture:.linen,roughness:0.9,textureScaleMM:0.8,textureDepthMM:0.035)
    var scaled=profile;scaled.textureScaleMM*=2
    XCTAssertEqual(PaperSurfaceRasterizer.toothHeight(x:3.25,y:6.7,profile:profile,grain:.unknown),PaperSurfaceRasterizer.toothHeight(x:6.5,y:13.4,profile:scaled,grain:.unknown),accuracy:1e-14)
    let fields=PaperSurfaceProfile.Texture.allCases.map{texture->Double in var value=profile;value.texture=texture;return PaperSurfaceRasterizer.toothHeight(x:3.25,y:6.7,profile:value,grain:.parallelWidth)}
    XCTAssertEqual(Set(fields).count,PaperSurfaceProfile.Texture.allCases.count)
    let line=ArtworkElement(kind:"rectangle",x:4,y:4,width:0.1,height:10,color:"#000000")
    var art=Artwork(background:"#FFFFFF",elements:[line]);art.backgroundOpacity=0
    let low=try maps(art,edge:128),high=try maps(art,edge:512)
    XCTAssertEqual(high.width,512);XCTAssertEqual(high.height,512);XCTAssertGreaterThan(high.width,low.width)
    XCTAssertLessThan(try pixel(high.color,4.05/20,0.4)[0],0.1,"A 0.1mm vector rule remains multiple source pixels at the requested close-up quality.")
    XCTAssertThrowsError(try PaperSurfaceRasterizer.make(rect:.init(x:0,y:0,width:0,height:20),netSize:.init(20,20),profile:profile,color:"#FFFFFF",grain:.unknown,artwork:nil,finishes:[],assets:assets,maximumEdge:512,pixelBudget:1))
  }
  func testRegisteredMaskRetainsAncestorTransformsAndClipDependenciesWithoutOtherPaint()throws {
    var group=ArtworkElement(kind:"group",x:2,y:3,width:10,height:10);group.rotation=23;group.contentSize = .init(10,10);group.opacity=0.6
    var clip=ArtworkElement(kind:"rectangle",x:1,y:1,width:4,height:4,color:"#FFFFFF");clip.parentID=group.id;clip.hidden=true
    var target=ArtworkElement(kind:"rectangle",x:0,y:0,width:8,height:8,color:"#FF0000");target.parentID=group.id;target.clipID=clip.id;target.opacity=0.5
    let unrelated=ArtworkElement(kind:"rectangle",x:12,y:0,width:8,height:8,color:"#00FF00")
    let original=Artwork(background:"#FF00FF",elements:[group,clip,target,unrelated])
    let mask=try PaperSurfaceRasterizer.maskArtwork(original,elementIDs:[target.id],paintColor:"#000000")
    XCTAssertEqual(Set(mask.elements.map(\.id)),[group.id,clip.id,target.id]);XCTAssertEqual(mask.backgroundOpacity,0)
    XCTAssertEqual(mask.elements.first{$0.id==group.id}?.localTransform,group.localTransform)
    XCTAssertEqual(mask.elements.first{$0.id==target.id}?.clipID,clip.id)
    XCTAssertEqual(mask.elements.first{$0.id==target.id}?.color,"#000000")
    XCTAssertEqual(mask.elements.first{$0.id==target.id}?.opacity,0.5)
    XCTAssertEqual(mask.elements.first{$0.id==group.id}?.opacity,0.6)
    XCTAssertEqual(original.elements[2].color,"#FF0000")
    var reference=original;reference.elements.removeAll{$0.id==unrelated.id};reference.backgroundOpacity=0
    func bitmap(_ art:Artwork)throws->NSBitmapImageRep {
      let image=ArtworkRenderer.image(art,width:20,height:20,assets:assets,pixelsPerMM:16)
      return NSBitmapImageRep(cgImage:try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)))
    }
    let expected=try bitmap(reference),actual=try bitmap(mask)
    var maximumAlpha=0.0
    for y in stride(from:0,to:actual.pixelsHigh,by:4) {for x in stride(from:0,to:actual.pixelsWide,by:4) {
      let before=Double(try XCTUnwrap(expected.colorAt(x:x,y:y)).alphaComponent)
      let after=Double(try XCTUnwrap(actual.colorAt(x:x,y:y)).alphaComponent)
      maximumAlpha=max(maximumAlpha,after);XCTAssertEqual(after,before,accuracy:1.0/255,"Recoloring a tooling mask must preserve rendered clipped group/element alpha.")
    }}
    XCTAssertEqual(maximumAlpha,0.3,accuracy:1.0/255)
  }
  func testOrdinaryPrintUsesTheSameInkColorOpacityAndExcludesFoilAndBlindMasks()throws {
    let ink=ArtworkElement(kind:"rectangle",x:2,y:2,width:4,height:4,color:"#FF0000"),foil=ArtworkElement(kind:"rectangle",x:10,y:2,width:4,height:4,color:"#CCAA33"),blind=ArtworkElement(kind:"rectangle",x:2,y:10,width:4,height:4,color:"#000000")
    var art=Artwork(background:"#FFFFFF",elements:[ink,foil,blind]);art.backgroundOpacity=0
    let original=art,finishes:[PaperFinishAssignment]=[
      .init(name:"Spot blue",kind:.screenPrint,elementIDs:[ink.id],color:"#0000FF",opacity:0.4),
      .init(name:"Foil only",kind:.foil,elementIDs:[foil.id]),
      .init(name:"Blind only",kind:.deboss,elementIDs:[blind.id],depthMM:0.05)]
    let print=try PaperSurfaceRasterizer.printArtwork(art,finishes:finishes)
    XCTAssertEqual(print.elements.map(\.id),[ink.id]);XCTAssertEqual(print.elements[0].color,"#0000FF");XCTAssertEqual(print.elements[0].opacity,0.4)
    let rendered=try maps(art,finishes:finishes)
    let blue=try pixel(rendered.color,0.2,0.2)
    XCTAssertEqual(blue[0],0.6,accuracy:0.015);XCTAssertEqual(blue[1],0.6,accuracy:0.015);XCTAssertEqual(blue[2],1,accuracy:0.005)
    var withExplicitInk=finishes;withExplicitInk.append(.init(name:"Intentional ink under foil",kind:.flatInk,elementIDs:[foil.id],color:"#334455"))
    let retained=try PaperSurfaceRasterizer.printArtwork(art,finishes:withExplicitInk)
    XCTAssertEqual(Set(retained.elements.map(\.id)),[ink.id,foil.id]);XCTAssertEqual(retained.elements.first{$0.id==foil.id}?.color,"#334455")
    var disabled=finishes;disabled[2].enabled=false
    XCTAssertTrue(try PaperSurfaceRasterizer.printArtwork(art,finishes:disabled).elements.contains{$0.id==blind.id})
    XCTAssertEqual(art,original)
  }
  func testBondedPlyEdgesHaveActualIndependentCalipersAndStableAppearanceOnlyGeometry()throws {
    var project=Project(name:"Duplex render proof"),object=try project.makeObject(recipeID:"paperEnvelope")
    object.artwork=nil;object.color=nil;object.parameters["fold"]=0
    var paper=try PaperConstruction.definition(for:object)
    paper.stock.plies=[.init(name:"Back black",color:"#171717",thicknessMM:0.2),.init(name:"Front red",color:"#A11D2A",thicknessMM:0.4)]
    paper.stock.thicknessMM=0.6;object.parameters["stock"]=0.6;object.paperConstruction=paper;project.objects=[object]
    func front(_ value:ProductObject)throws->MeshGeometry {
      let root=try PaperGeometry.make(value,project:project,assets:assets,limit:128)
      return try XCTUnwrap(root.childNode(withName:PaperGeometry.panelPrefix+"front",recursively:true)?.geometry)
    }
    let mesh=try front(object),vertices=try XCTUnwrap(mesh.sources(for:.vertex).first).vectors
    XCTAssertEqual(mesh.materials.count,4);XCTAssertEqual(mesh.elements.count,4)
    XCTAssertEqual((vertices.map(\.z).max()!-vertices.map(\.z).min()!)*100,0.6,accuracy:1e-9)
    for (slot,expected) in [(2,(-0.3,-0.1)),(3,(-0.1,0.3))] {
      let z=mesh.elements[slot].indices.map{vertices[Int($0)].z*100}
      XCTAssertEqual(try XCTUnwrap(z.min()),expected.0,accuracy:1e-9);XCTAssertEqual(try XCTUnwrap(z.max()),expected.1,accuracy:1e-9)
    }
    let frontColor=try pixel(try XCTUnwrap(mesh.materials[0].diffuse.contents as? NSImage),0.5,0.5),backColor=try pixel(try XCTUnwrap(mesh.materials[1].diffuse.contents as? NSImage),0.5,0.5)
    XCTAssertGreaterThan(frontColor[0],frontColor[1]+0.3);XCTAssertLessThan(backColor[0],0.15)
    object.paperConstruction!.stock.plies![1].color="#254B99";project.objects=[object]
    let edited=try front(object)
    XCTAssertEqual(edited.name,mesh.name);XCTAssertTrue(edited.sources[0] === mesh.sources[0])
    let editedColor=try pixel(try XCTUnwrap(edited.materials[0].diffuse.contents as? NSImage),0.5,0.5)
    XCTAssertGreaterThan(editedColor[2],editedColor[0]+0.2)
  }
  func testPanelWindowIsMissingPhysicalMaterialAndChangesTheMeshIdentity()throws {
    let panel=PaperPanel(id:"window",name:"Window card",role:.body,polygon:[.init(0,0),.init(40,0),.init(40,40),.init(0,40)],cutouts:[.init(id:"opening",polygon:[.init(10,10),.init(30,10),.init(30,30),.init(10,30)],kind:.window)])
    let mesh=try PaperGeometry.panelMesh(panel,netSize:.init(40,40),thicknessMM:0.4),vertices=try XCTUnwrap(mesh.sources(for:.vertex).first).vectors
    func covers(_ p:SIMD2<Double>,_ a:MeshVector3,_ b:MeshVector3,_ c:MeshVector3)->Bool {
      func cross(_ a:SIMD2<Double>,_ b:SIMD2<Double>)->Double{a.x*b.y-a.y*b.x}
      let aa=SIMD2(a.x,a.y),bb=SIMD2(b.x,b.y),cc=SIMD2(c.x,c.y),d=cross(bb-aa,cc-aa)
      guard abs(d)>1e-20 else{return false};let u=cross(p-aa,cc-aa)/d,v=cross(bb-aa,p-aa)/d;return u>=0 && v>=0 && u+v<=1
    }
    let windowCenter=SIMD2<Double>(0.2,-0.2),stockPoint=SIMD2<Double>(0.05,-0.05)
    for slot in [0,1] {
      let indices=mesh.elements[slot].indices
      var coversWindow=false,coversStock=false
      for i in stride(from:0,to:indices.count,by:3) {
        let a=vertices[Int(indices[i])],b=vertices[Int(indices[i+1])],c=vertices[Int(indices[i+2])]
        coversWindow = coversWindow || covers(windowCenter,a,b,c)
        coversStock = coversStock || covers(stockPoint,a,b,c)
      }
      XCTAssertFalse(coversWindow,"A real window is absent from both physical faces.")
      XCTAssertTrue(coversStock,"The neighboring stock must still contain actual face triangles.")
    }
    var filled=panel;filled.cutouts=nil
    XCTAssertNotEqual(mesh.name,try PaperGeometry.panelMesh(filled,netSize:.init(40,40),thicknessMM:0.4).name)
  }
  func testProceduralFinishTexturesKeepTheirMetallicScaleAndOpaqueStockInTheNativeBridge()throws {
    let mark=ArtworkElement(kind:"rectangle",x:2,y:2,width:8,height:8,color:"#000000")
    var art=Artwork(background:"#FFFFFF",elements:[mark]);art.backgroundOpacity=0
    let maps=try maps(art,finishes:[.init(name:"Foil",kind:.foil,elementIDs:[mark.id],color:"#D3AC55")])
    let material=MeshMaterial();material.diffuse.contents=maps.color;material.normal.contents=maps.normal;material.roughness.contents=maps.roughness;material.metalness.contents=maps.metallic
    let box=MeshBox(width:1,height:1,length:1,chamferRadius:0);box.materials=[material]
    let scene=MeshScene(),node=MeshNode(geometry:box);node.name="object:"+UUID().uuidString;scene.rootNode.addChildNode(node)
    let payload=try XCTUnwrap(GeometryPayloadAdapter().renderables(scene:scene).first),value=try XCTUnwrap(payload.materials.first)
    XCTAssertEqual(value.metallic,1);XCTAssertEqual(value.roughness,1)
    XCTAssertNotNil(value.metallicTexture);XCTAssertNotNil(value.roughnessTexture);XCTAssertNotNil(value.normalTexture)
    XCTAssertEqual(value.alphaMode,.opaque,"Fully opaque paper must not enter transparent sorting merely because it uses a finish atlas.")
    material.transparency=0.55
    XCTAssertEqual(try XCTUnwrap(GeometryPayloadAdapter().renderables(scene:scene).first?.materials.first).alphaMode,.blend)
  }
}

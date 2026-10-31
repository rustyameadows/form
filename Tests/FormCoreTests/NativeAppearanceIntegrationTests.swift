import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class NativeAppearanceIntegrationTests:XCTestCase {
  private let assets=FileManager.default.temporaryDirectory
  private func rect(_ x:Double,_ y:Double,_ width:Double,_ height:Double,_ color:String)->ArtworkElement {
    ArtworkElement(kind:"rectangle",x:x,y:y,width:width,height:height,color:color)
  }
  private func pixels(_ elements:[ArtworkElement],background:String="#00FFFF",opacity:Double=1)->NSBitmapImageRep {
    var art=Artwork(elements:elements,bleed:0);art.background=background;art.backgroundOpacity=opacity
    return ArtworkRenderer.image(art,width:60,height:60,assets:assets,pixelsPerMM:4).representations[0] as! NSBitmapImageRep
  }
  private func pixel(_ rep:NSBitmapImageRep,_ x:Double,_ y:Double)throws->NSColor {
    // ArtworkRenderer's bitmap is already sRGB. colorAt exposes its channels
    // as NSCalibratedRGB; converting that tag again shifts pure red/green.
    try XCTUnwrap(rep.colorAt(x:Int(x*4),y:Int(y*4)))
  }
  func testNativeAdvancedGradientRequiresCompatibleProjectSchema()throws {
    for kind in ["angular","diamond"] {
      var project=Project(name:"Native appearance schema")
      let owner=try project.ensureCanvasWorkspace()
      let index=try XCTUnwrap(project.objects.firstIndex{$0.id==owner.id})
      var shape=rect(0,0,20,20,"#FFFFFF")
      shape.gradient = .init(kind:kind,stops:[.init(0,"#FF0000"),.init(1,"#0000FF")])
      project.objects[index].artwork!.elements=[shape]
      XCTAssertEqual(project.minimumSchemaVersion,58)
    }
  }
  func testShadowBlendUsesActualBackdropUntilExplicitNormalIsolation()throws {
    var shape=rect(10,10,10,10,"#FFFFFF")
    shape.effectStack = .init(coverage:"paint-outline",effects:[.init(kind:"drop-shadow",offset:.init(15,0),color:"#FF0000",blendMode:"multiply")])
    let pass=try pixel(pixels([shape]),30,15)
    XCTAssertLessThan(pass.redComponent,0.03);XCTAssertLessThan(pass.greenComponent,0.03);XCTAssertLessThan(pass.blueComponent,0.03)
    shape.isolatedBlending=true
    let isolated=try pixel(pixels([shape]),30,15)
    XCTAssertGreaterThan(isolated.redComponent,0.97);XCTAssertLessThan(isolated.greenComponent,0.03)
    XCTAssertEqual(try pixel(pixels([shape]),15,15).redComponent,1,accuracy:0.01)
  }
  func testPassThroughEffectGroupKeepsChildBlendLiveAndAppliesLayerAlphaOnce()throws {
    var group=ArtworkElement(kind:"group",x:0,y:0,width:40,height:40)
    group.effectStack = .init(coverage:"paint-outline",effects:[.init(kind:"drop-shadow",offset:.init(0,15),color:"#0000FF")])
    var shape=rect(10,10,10,10,"#FF0000");shape.parentID=group.id;shape.blendMode="multiply"
    let pass=try pixel(pixels([group,shape]),15,15)
    XCTAssertLessThan(pass.redComponent,0.03);XCTAssertLessThan(pass.greenComponent,0.03);XCTAssertLessThan(pass.blueComponent,0.03)
    group.isolatedBlending=true
    let isolated=try pixel(pixels([group,shape]),15,15)
    XCTAssertGreaterThan(isolated.redComponent,0.97);XCTAssertLessThan(isolated.greenComponent,0.03)
    group.opacity=0.5
    let faded=pixels([group,shape],opacity:0)
    XCTAssertEqual(try pixel(faded,15,15).alphaComponent,0.5,accuracy:0.015)
    XCTAssertEqual(try pixel(faded,15,30).alphaComponent,0.5,accuracy:0.015)
  }
  func testCurvedSpreadCaptureRetainsEllipseAndSourceOrientation()throws {
    var shape=ArtworkElement(kind:"ellipse",x:20,y:20,width:20,height:20,color:"#FFFFFF")
    shape.effectStack = .init(coverage:"paint-outline",effects:[.init(kind:"drop-shadow",spread:4,color:"#FF0000")])
    let rep=pixels([shape],opacity:0)
    XCTAssertEqual(try pixel(rep,17,30).redComponent,1,accuracy:0.02)
    XCTAssertGreaterThan(try pixel(rep,17,30).alphaComponent,0.98)
    XCTAssertLessThan(try pixel(rep,17,17).alphaComponent,0.02)
    XCTAssertEqual(try pixel(rep,30,30).greenComponent,1,accuracy:0.02)
    shape.effectStack?.effects[0].offset = .init(0,-12)
    let shifted=pixels([shape],opacity:0)
    XCTAssertGreaterThan(try pixel(shifted,30,8).alphaComponent,0.98)
    XCTAssertLessThan(try pixel(shifted,30,45).alphaComponent,0.02)
  }
  func testEffectSilhouetteClipsOverlappingChildrenOnce()throws {
    var group=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20)
    group.effectStack = .init(coverage:"paint-outline",effects:[.init(kind:"drop-shadow",offset:.init(0,25))])
    var mask=rect(0,0,40,20,"#FFFFFF");mask.hidden=true;mask.opacity=0.5;mask.parentID=group.id
    var content=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20);content.parentID=group.id;content.clipID=mask.id;content.clipMode="alpha"
    var left=rect(0,0,28,20,"#FF0000"),right=rect(12,0,28,20,"#0000FF")
    left.parentID=content.id;right.parentID=content.id
    let rep=pixels([group,mask,content,left,right],opacity:0)
    for x in [4.0,20,36] {
      XCTAssertEqual(try pixel(rep,x,10).alphaComponent,0.5,accuracy:0.015)
      XCTAssertEqual(try pixel(rep,x,35).alphaComponent,0.5,accuracy:0.015)
    }
  }
  func testFailedEffectPreviewKeepsEditableContentButStrictOutputFails()throws {
    var shape=rect(10,10,10,10,"#FF0000")
    shape.effectStack = .init(effects:[.init(kind:"unknown")])
    XCTAssertGreaterThan(try pixel(pixels([shape],opacity:0),15,15).alphaComponent,0.98)
    XCTAssertThrowsError(try ArtworkRenderer.validateAppearanceOutput(.init(elements:[shape]),assets:assets,pixelsPerMM:4))
  }
  func testStackStrokeOpacityMultipliesPaintOpacityInPixelsAndExport()throws {
    var shape=rect(10,10,20,20,"#FFFFFF"),stroke=ArtworkStroke(width:4)
    stroke.opacity=0.5
    shape.paintStack=[.init(.init(color:"#FF0000",opacity:0.4),stroke:stroke)]
    XCTAssertEqual(try pixel(pixels([shape],opacity:0),10,20).alphaComponent,0.2,accuracy:0.015)
    let svg=try SVGRenderer.fragment(.init(elements:[shape]),width:60,height:60,assets:assets)
    XCTAssertTrue(svg.contains("opacity=\"0.2\""))
    shape.paintStack?[0].stroke?.opacity=0
    XCTAssertEqual(try pixel(pixels([shape],opacity:0),10,20).alphaComponent,0,accuracy:0.01)
  }
  func testNestedCaptureLimitPropagatesAndReleasesBudgetAfterFailure()throws {
    func nested(_ depth:Int)->ArtworkMaskRenderer.Coverage? {
      ArtworkMaskRenderer.coverage(mode:"alpha",bounds:.init(x:0,y:0,width:4,height:4),
        signature:Data(UUID().uuidString.utf8),pixelsPerMM:1){c in
        if depth>0 {_ = nested(depth-1)}
        c.setFillColor(NSColor.white.cgColor);c.fill(.init(x:0,y:0,width:4,height:4))
      }
    }
    XCTAssertNil(nested(20),"An inner budget failure must invalidate every outer capture, rather than cache incomplete coverage")
    XCTAssertNotNil(nested(2),"Every failed capture must release its reservation")
    var shape=rect(0,0,4,4,"#FFFFFF")
    shape.effectStack = .init(effects:[.init(kind:"drop-shadow")])
    XCTAssertThrowsError(try NativeEffectCompositor.raster(shape,signature:Data(UUID().uuidString.utf8),
      bounds:.init(x:0,y:0,width:4,height:4),pixelsPerMM:1,strict:true,
      content:{_ in _ = nested(20)},silhouette:{_,_ in}))
    let reservation=try ArtworkRasterBudget.reserve(ArtworkRasterBudget.maximumBytes)
    XCTAssertThrowsError(try ArtworkRasterBudget.reserve(1))
    ArtworkRasterBudget.release(reservation)
    XCTAssertNotNil(nested(0))
  }
  func testSVGPreservesNativeContentWithSeparateEffectsAndComputedMaskAlpha()throws {
    var mask=ArtworkElement(kind:"group",x:0,y:0,width:40,height:40);mask.hidden=true;mask.opacity=0.5
    var ink=rect(0,0,40,15,"#FFFFFF");ink.parentID=mask.id
    var shape=rect(0,0,40,40,"#FF0000");shape.clipID=mask.id;shape.clipMode="alpha"
    shape.effectStack = .init(coverage:"paint-outline",effects:[.init(kind:"inner-shadow",offset:.init(2,0),color:"#0000FF")])
    let art=Artwork(elements:[mask,ink,shape])
    try ArtworkRenderer.validateAppearanceOutput(art,assets:assets,pixelsPerMM:4)
    let svg=try SVGRenderer.fragment(art,width:40,height:40,assets:assets)
    XCTAssertTrue(svg.contains("mask-type:alpha"));XCTAssertTrue(svg.contains("<path"))
    XCTAssertTrue(svg.contains("mix-blend-mode:normal"))
    let prefix="data:image/png;base64,",start=try XCTUnwrap(svg.range(of:prefix))
    let end=try XCTUnwrap(svg[start.upperBound...].firstIndex(of:"\""))
    let data=try XCTUnwrap(Data(base64Encoded:String(svg[start.upperBound..<end])))
    let bitmap=try XCTUnwrap(NSBitmapImageRep(data:data))
    let top=try XCTUnwrap(bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/5))
    let bottom=try XCTUnwrap(bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh*4/5))
    // The exporter crops the image to painted mask bounds (height 15), so both
    // rows lie inside its ink. Transparency below comes from its SVG extent.
    XCTAssertEqual(top.alphaComponent,0.5,accuracy:0.015);XCTAssertEqual(bottom.alphaComponent,0.5,accuracy:0.015)
    let tree=ArtworkRenderTree(art,assets:assets,production:true,excluding:[])
    let coverage=try XCTUnwrap(tree.maskCoverage(mask,mode:"alpha",density:300/25.4))
    XCTAssertEqual(coverage.bounds.height,15,accuracy:0.1)
    let maskStart=try XCTUnwrap(svg.range(of:"<mask id="))
    let maskEnd=try XCTUnwrap(svg[maskStart.lowerBound...].firstIndex(of:">"))
    XCTAssertTrue(svg[maskStart.lowerBound..<maskEnd].contains("height=\"\(coverage.bounds.height)\""))
    XCTAssertEqual(try pixel(pixels([mask,ink,shape],opacity:0),20,32).alphaComponent,0,accuracy:0.01)
    XCTAssertEqual(art.elements[0].kind,"group");XCTAssertEqual(art.elements[2].effectStack?.effects.count,1)
  }
}

import AppKit
import FormCore
import FormGraphics
import XCTest

@MainActor final class NativeGradientTests:XCTestCase {
  private func gradient(_ kind:String)->ArtworkGradient {
    .init(kind:kind,start:.init(0.5,0.5),end:.init(1,0.5),stops:[.init(0,"#FF0000"),.init(1,"#0000FF")])
  }
  func testAngularCoordinatesAndDiamondDistanceRespectAffineTransforms()throws {
    var angular=gradient("angular")
    let size=CGSize(width:20,height:20)
    XCTAssertEqual(NativeGradientRenderer.position(angular,size:size,point:.init(19,10)),0,accuracy:1e-8)
    XCTAssertEqual(NativeGradientRenderer.position(angular,size:size,point:.init(10,19)),0.25,accuracy:1e-8)
    XCTAssertEqual(NativeGradientRenderer.position(angular,size:size,point:.init(1,10)),0.5,accuracy:1e-8)
    XCTAssertEqual(NativeGradientRenderer.position(angular,size:size,point:.init(10,1)),0.75,accuracy:1e-8)
    angular.transform = .init(a:2,b:0.25,c:0.4,d:0.7,tx:12,ty:-2)
    let mapped=angular.transform!.apply(.init(10,19))
    XCTAssertEqual(NativeGradientRenderer.position(angular,size:size,point:mapped),0.25,accuracy:1e-8)
    let diamond=gradient("diamond")
    XCTAssertEqual(NativeGradientRenderer.position(diamond,size:size,point:.init(12,13)),0.5,accuracy:1e-8)
    XCTAssertEqual(NativeGradientRenderer.position(diamond,size:size,point:.init(20,20)),1,accuracy:1e-8)
  }
  func testNativeAngularAndDiamondPixelsRetainEditableGradientAndSVGClip()throws {
    for kind in ["angular","diamond"] {
      var shape=ArtworkElement(kind:"ellipse",x:0,y:0,width:20,height:20)
      shape.gradient=gradient(kind)
      let art=Artwork(elements:[shape]);try validateArtwork(art)
      let image=ArtworkRenderer.image(art,width:20,height:20,assets:FileManager.default.temporaryDirectory,pixelsPerMM:10)
      let rep=try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
      let near=try XCTUnwrap(rep.colorAt(x:105,y:105)).usingColorSpace(.sRGB)!
      if kind == "diamond" {XCTAssertGreaterThan(near.redComponent,0.8)}
      let lower=try XCTUnwrap(rep.colorAt(x:100,y:170)).usingColorSpace(.sRGB)!
      if kind == "angular" {XCTAssertGreaterThan(lower.redComponent,lower.blueComponent)}
      else {XCTAssertGreaterThan(lower.blueComponent,lower.redComponent)}
      let svg=try SVGRenderer.document(art,width:20,height:20,assets:FileManager.default.temporaryDirectory)
      XCTAssertTrue(svg.contains("clipPath"));XCTAssertTrue(svg.contains("data:image/png;base64,"))
      XCTAssertFalse(svg.contains("<linearGradient"))
      let copy=try JSONDecoder().decode(Artwork.self,from:JSONEncoder().encode(art))
      XCTAssertEqual(copy.elements[0].gradient,shape.gradient);XCTAssertEqual(copy.elements[0].kind,"ellipse")
    }
  }
  func testDuplicateStopsKeepHardColorBoundary()throws {
    var g=gradient("diamond")
    g.stops=[.init(0,"#FF0000"),.init(0.5,"#FF0000"),.init(0.5,"#0000FF"),.init(1,"#0000FF")]
    let data=try NativeGradientRenderer.png(g,size:.init(width:20,height:20),bounds:.init(x:0,y:0,width:20,height:20),pixelsPerMM:20)
    let image=try XCTUnwrap(NSBitmapImageRep(data:data))
    XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x:280,y:200)).redComponent,0.95)
    XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x:320,y:200)).blueComponent,0.95)
  }
  func testGradientOutputRefusesSilentResolutionReduction()throws {
    XCTAssertThrowsError(try NativeGradientRenderer.png(gradient("angular"),size:.init(width:1000,height:1000),bounds:.init(x:0,y:0,width:1000,height:1000)))
  }
  func testFigmaAngularDiamondAndPaintedVectorStrokesMapWithoutOutlining()throws {
    func paint(_ kind:String)->FigmaValue {.object(["type":.string(kind),"stops":.array([
      .object(["position":.double(0),"color":.object(["r":.double(1),"g":.double(0),"b":.double(0)])]),
      .object(["position":.double(1),"color":.object(["r":.double(0),"g":.double(0),"b":.double(1)])])])])}
    let nodes:[FigmaValue]=["GRADIENT_ANGULAR","GRADIENT_DIAMOND"].enumerated().map {index,kind in
      .object(["guid":.string("shape\(index)"),"type":.string("RECTANGLE"),"size":.object(["x":.double(100),"y":.double(40)]),
        "fillPaints":.array([]),"strokePaints":.array([paint(kind)]),"strokeWeight":.double(3),"strokeAlign":.string("OUTSIDE")])
    }
    let result=try FigmaArtworkImporter.read(.init(message:.object(["nodeChanges":.array(nodes)])))
    XCTAssertEqual(result.issues.filter{$0.severity=="error"},[])
    let shapes=result.artwork.elements.filter{$0.kind=="rectangle"}
    XCTAssertEqual(shapes.count,2)
    XCTAssertEqual(shapes.compactMap{$0.paintStack?.first?.paint.gradient?.kind},["angular","diamond"])
    XCTAssertTrue(shapes.allSatisfy{$0.path==nil && $0.paintStack?.first?.stroke?.alignment=="outside"})
    let bundle=try ArtworkTransferBundle.external(artwork:result.artwork,selection:result.selectedRootIDs,assets:result.assets,application:"figma")
    try bundle.validate()
  }
}

import AppKit
import FormCore
import FormGraphics
import XCTest

@MainActor final class FigmaBooleanPaintTests:XCTestCase {
  private func solid(_ color:String)->FigmaValue {
    .object(["type":.string("SOLID"),"color":.object(["r":.double(color=="red" ? 1:0),"g":.double(color=="green" ? 1:0),"b":.double(color=="blue" ? 1:0)])])
  }
  private func read(_ fields:[String:FigmaValue],blobs:[Data]=[])throws->FigmaArtworkImportResult {
    var root:[String:FigmaValue]=["guid":.string("boolean"),"type":.string("BOOLEAN_OPERATION"),"booleanOperation":.string("SUBTRACT"),"size":.object(["x":.double(100),"y":.double(100)])]
    root.merge(fields){_,new in new}
    let a:FigmaValue = .object(["guid":.string("a"),"type":.string("RECTANGLE"),"parentIndex":.object(["guid":.string("boolean"),"position":.string("a")]),"size":.object(["x":.double(100),"y":.double(100)])])
    let b:FigmaValue = .object(["guid":.string("b"),"type":.string("ELLIPSE"),"parentIndex":.object(["guid":.string("boolean"),"position":.string("b")]),"size":.object(["x":.double(40),"y":.double(40)]),"transform":.object(["m00":.double(1),"m11":.double(1),"m02":.double(30),"m12":.double(30)])])
    return try FigmaArtworkImporter.read(.init(message:.object(["nodeChanges":.array([.object(root),a,b]),"blobs":.array(blobs.map{.object(["bytes":.data($0)])})])))
  }
  func testBooleanKeepsAllPaintsStrokeAndEditableOperands()throws {
    let gradient:FigmaValue = .object(["type":.string("GRADIENT_LINEAR"),"stops":.array([
      .object(["position":.double(0),"color":solid("red")["color"]!]),.object(["position":.double(1),"color":solid("blue")["color"]!])])])
    let result=try read(["fillPaints":.array([solid("red"),solid("green")]),"strokePaints":.array([gradient]),"strokeWeight":.double(2)])
    XCTAssertEqual(result.issues.filter{$0.severity=="error"},[])
    let root=try XCTUnwrap(result.artwork.elements.first{$0.booleanOperation != nil}),stack=try XCTUnwrap(root.paintStack)
    XCTAssertEqual(stack.count,3);XCTAssertEqual(stack[0].paint.color,"#FF0000");XCTAssertEqual(stack[1].paint.color,"#00FF00")
    XCTAssertEqual(stack[2].paint.kind,"gradient");XCTAssertEqual(stack[2].stroke?.width,2*25.4/96)
    XCTAssertEqual(result.artwork.elements.filter{$0.parentID==root.id}.count,2)
    let proxy=try BooleanGeometry.proxy(root,in:result.artwork)
    XCTAssertEqual(proxy.paintStack,stack)
    XCTAssertFalse(VectorGeometry.path(proxy).contains(.init(x:50*25.4/96,y:50*25.4/96)))
    let bundle=try ArtworkTransferBundle.external(artwork:result.artwork,selection:result.selectedRootIDs,assets:result.assets,application:"figma")
    try bundle.validate()
  }
  func testBooleanImagePaintRetainsEmbeddedAssetAndEmptyPaintRemainsInvisible()throws {
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    for y in 0..<2 {for x in 0..<2 {bitmap.setColor(.red,atX:x,y:y)}}
    let bytes=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
    let image:FigmaValue = .object(["type":.string("IMAGE"),"image":.object(["dataBlob":.uint(0)]),"imageScaleMode":.string("FILL")])
    let result=try read(["fillPaints":.array([image])],blobs:[bytes]),root=try XCTUnwrap(result.artwork.elements.first{$0.booleanOperation != nil})
    XCTAssertEqual(result.issues.filter{$0.severity=="error"},[])
    XCTAssertEqual(root.paintStack?.first?.paint.kind,"image")
    XCTAssertEqual(root.renderedAssetNames,Set(result.assets.keys))
    XCTAssertEqual(try BooleanGeometry.proxy(root,in:result.artwork).paintStack,root.paintStack)
    let empty=try read([:]),invisible=try XCTUnwrap(empty.artwork.elements.first{$0.booleanOperation != nil})
    XCTAssertEqual(invisible.paintStack,[]);XCTAssertEqual(invisible.fillEnabled,false)
    XCTAssertThrowsError(try read(["booleanOperation":.uint(99)]))
  }
}

import AppKit
import XCTest
import FormCore
import FormGraphics

@MainActor final class FigmaTiledStrokeTests:XCTestCase {
  private func imported(strokeOpacity:Double)throws->FigmaArtworkImportResult {
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    for y in 0..<2 {for x in 0..<2 {bitmap.setColor(.blue,atX:x,y:y)}}
    let bytes=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
    let image:FigmaValue = .object(["type":.string("IMAGE"),"image":.object(["dataBlob":.uint(0)]),"imageScaleMode":.string("TILE")])
    // PASS_THROUGH maps to the native default normal blend. It exercises the
    // fill/stroke coalescing path that previously hid a tiled fill's stroke.
    let stroke:FigmaValue = .object(["type":.string("SOLID"),"color":.object(["r":.double(1),"g":.double(0),"b":.double(0)]),"opacity":.double(strokeOpacity),"blendMode":.string("PASS_THROUGH")])
    let node:FigmaValue = .object(["guid":.object(["sessionID":.uint(1),"localID":.uint(1)]),"type":.string("RECTANGLE"),
      "name":.string("Tiled blue / red edge"),"size":.object(["x":.double(100),"y":.double(60)]),
      "transform":.object(["m00":.double(1),"m01":.double(0),"m02":.double(20),"m10":.double(0),"m11":.double(1),"m12":.double(20)]),
      "fillPaints":.array([image]),"strokePaints":.array([stroke]),"strokeWeight":.double(12)])
    return try FigmaArtworkImporter.read(.init(message:.object(["nodeChanges":.array([node]),"blobs":.array([.object(["bytes":.data(bytes)])])])))
  }
  private func verify(strokeOpacity:Double)throws {
    let result=try imported(strokeOpacity:strokeOpacity)
    XCTAssertFalse(result.issues.contains{$0.severity=="error"})
    let fill=try XCTUnwrap(result.artwork.elements.first{$0.paintStack?.first?.paint.imageRepeat==true})
    let stroke=try XCTUnwrap(result.artwork.elements.first{$0.stroke != nil})
    XCTAssertNotEqual(fill.id,stroke.id);XCTAssertNil(fill.stroke)
    XCTAssertEqual(stroke.stroke?.opacity ?? -1,strokeOpacity,accuracy:1e-9)
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    for(name,bytes) in result.assets {try bytes.write(to:root.appendingPathComponent(name))}
    var art=result.artwork;art.backgroundOpacity=0
    let rendered=ArtworkRenderer.image(art,width:40,height:30,assets:root,pixelsPerMM:8)
    let bitmap=try XCTUnwrap(rendered.representations.first as? NSBitmapImageRep)
    let transform=art.worldTransform(fill)
    func pixel(_ x:Double,_ y:Double)throws->NSColor {
      let point=transform.apply(.init(x,y))
      return try XCTUnwrap(bitmap.colorAt(x:Int((point.x*8).rounded()),y:Int((point.y*8).rounded()))?.usingColorSpace(.deviceRGB))
    }
    let edge=try pixel(0.4,fill.height/2),middle=try pixel(fill.width/2,fill.height/2)
    XCTAssertEqual(edge.redComponent,strokeOpacity,accuracy:0.06,"The red stroke must remain visible over the tiled blue fill")
    XCTAssertGreaterThan(middle.blueComponent,0.95);XCTAssertLessThan(middle.redComponent,0.05)
    XCTAssertEqual(middle.alphaComponent,1,accuracy:0.02)
  }
  func testTiledImageFillRetainsSeparateVisibleOpaqueStroke()throws {try verify(strokeOpacity:1)}
  func testTiledImageFillRetainsSeparateVisiblePartialOpacityStroke()throws {try verify(strokeOpacity:0.5)}
}

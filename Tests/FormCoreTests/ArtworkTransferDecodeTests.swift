import AppKit
import Foundation
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class ArtworkTransferDecodeTests:XCTestCase {
  private func bundle(_ name:String,_ data:Data,provenance:Bool=false)throws->ArtworkTransferBundle {
    var project=Project(name:"Decoded transfer"),object=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":100])
    let element=ArtworkElement(kind:provenance ? "rectangle":"image",x:0,y:0,asset:provenance ? nil:name)
    var art=Artwork(elements:[element]);if provenance {art.imports=[.init(asset:name,name:"Original source",width:100,height:100)]};object.artwork=art;project.objects=[object]
    return try ArtworkTransferGraph.capture(project:project,objectID:object.id,ids:[element.id],readAsset:{_,_ in data})
  }
  func testRasterPixelsAndMalformedDecodeStayBounded()throws {
    let context=CGContext(data:nil,width:4,height:3,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bytes=try XCTUnwrap(NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:]))
    XCTAssertEqual(try ArtworkTransferPreflight.validate(bundle("source.png",bytes)).rasterPixels,12)
    XCTAssertThrowsError(try ArtworkTransferPreflight.validate(bundle("broken.png",Data("broken raster".utf8))))
  }
  func testPlainSVGPassesWhileActiveExternalAndEscapedContentRejects()throws {
    let prefix="<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20mm\" height=\"10mm\" viewBox=\"0 0 20 10\">"
    let source=prefix+"<rect width=\"20\" height=\"10\" fill=\"#225588\"/></svg>"
    XCTAssertGreaterThan(try ArtworkTransferPreflight.validate(bundle("source.svg",Data(source.utf8))).vectorElements,0)
    for body in ["<script>alert(1)</script>","<image href=\"https://example.invalid/a.png\"/>","<use href=\"#self\" id=\"self\"/>","<rect width=\"20\" height=\"10\" style=\"fill:url(https://example.invalid/a)\"/>"] {
      XCTAssertThrowsError(try ArtworkTransferPreflight.validate(bundle("unsafe.svg",Data((prefix+body+"</svg>").utf8))))
    }
  }
  private func flatPDF()->Data {
    let content="0 0 1 rg 10 10 50 50 re f\n"
    let objects=["<< /Type /Catalog /Pages 2 0 R >>","<< /Type /Pages /Kids [3 0 R] /Count 1 >>","<< /Type /Page /Parent 2 0 R /MediaBox [0 0 120 80] /Resources << >> /Contents 4 0 R >>","<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream"]
    var output="%PDF-1.4\n",offsets=[Int]()
    for (index,object) in objects.enumerated() {offsets.append(output.utf8.count);output+="\(index+1) 0 obj\n\(object)\nendobj\n"}
    let start=output.utf8.count;output+="xref\n0 5\n0000000000 65535 f \n";for offset in offsets {output+=String(format:"%010d 00000 n \n",offset)}
    output+="trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n";return Data(output.utf8)
  }
  func testFlatUncompressedPDFPassesAndCompressedEscapedFiltersRejectBeforeExposure()throws {
    XCTAssertGreaterThan(try ArtworkTransferPreflight.validate(bundle("source.pdf",flatPDF())).rasterPixels,0)
    for name in ["/Filter /FlateDecode","/Fi#6cter /FlateDecode","/Type /XObject","/OpenAction 1 0 R"] {XCTAssertThrowsError(try ArtworkTransferPreflight.validate(bundle("unsupported.pdf",Data(("%PDF-1.4\n"+name).utf8))))}
  }
  func testProvenanceOnlyOriginalsRemainOpaqueExactBytes()throws {
    let raw=Data("<!DOCTYPE svg [<!ENTITY external SYSTEM 'file:///unread'>]><svg/>".utf8),copy=try bundle("original.svg",raw,provenance:true),result=try ArtworkTransferPreflight.validate(copy)
    XCTAssertEqual(result.opaqueProvenance,["original.svg"]);XCTAssertEqual(copy.blobs["original.svg"],raw);XCTAssertEqual(result.rasterPixels,0);XCTAssertEqual(result.vectorElements,0)
  }
}

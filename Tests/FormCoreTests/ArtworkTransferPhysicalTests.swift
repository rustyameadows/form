import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class ArtworkTransferPhysicalTests:XCTestCase {
  private func project(_ name:String)throws->(Project,UUID) {var p=Project(name:name);let frame=try p.ensureCanvasWorkspace();return(p,frame.id)}
  func testPrivatePasteboardAndSourceDeletedImageGiveIdenticalRenderedGeometry()throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),sourceAssets=root.appendingPathComponent("source"),targetAssets=root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at:sourceAssets,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:targetAssets,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
    let context=CGContext(data:nil,width:16,height:16,bitsPerComponent:8,bytesPerRow:64,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.orange.cgColor);context.fill(.init(x:0,y:0,width:16,height:16));context.setFillColor(NSColor.blue.cgColor);context.fill(.init(x:0,y:0,width:8,height:8))
    let bitmap=NSBitmapImageRep(cgImage:context.makeImage()!),png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:])),name="original.png";try png.write(to:sourceAssets.appendingPathComponent(name))
    var(p,id)=try project("Source");var group=ArtworkElement(kind:"group",x:40,y:25,width:100,height:80);group.contentSize = .init(100,80);group.rotation=19;group.opacity=0.7
    var mask=ArtworkElement(kind:"ellipse",x:0,y:0,width:90,height:70);mask.parentID=group.id
    var image=ArtworkElement(kind:"image",x:5,y:5,width:85,height:65,asset:name);image.parentID=group.id;image.clipID=mask.id;image.imageCrop = .init(x:0.1,y:0.2,width:0.8,height:0.7)
    var art=Artwork(background:"#FFFFFF",elements:[group,mask,image],bleed:0);art.backgroundOpacity=0;art.unit = .mm;try p.setArtwork(art,for:id)
    let source=try JSONEncoder.form.encode(p)
    let bundle=try ArtworkTransferGraph.capture(project:p,objectID:id,ids:[image.id],readAsset:{name,limit in try XCTUnwrap(ArtworkTransferIO.readAsset(directory:sourceAssets,name:name,limit:limit))})
    let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};let type=NSPasteboard.PasteboardType("studio.form.artwork-transfer.prototype")
    board.clearContents();XCTAssertTrue(board.setData(try bundle.encoded(),forType:type));let portable=try ArtworkTransferBundle.decode(XCTUnwrap(board.data(forType:type)))
    func pdf(_ artwork:Artwork,_ assets:URL)throws->Data {
      let data=NSMutableData();let consumer=CGDataConsumer(data:data)!,points=72.0/25.4
      var box=CGRect(x:0,y:0,width:200*points,height:150*points);let context=CGContext(consumer:consumer,mediaBox:&box,nil)!
      context.beginPDFPage(nil);context.translateBy(x:0,y:box.height);context.scaleBy(x:points,y:-points)
      NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
      ArtworkRenderer.draw(artwork,width:200,height:150,assets:assets);NSGraphicsContext.restoreGraphicsState();context.endPDFPage();context.closePDF();return data as Data
    }
    let beforePDF=try pdf(art,sourceAssets),beforeSVG=try SVGRenderer.document(art,width:200,height:150,assets:sourceAssets)
    let before=ArtworkRenderer.image(art,width:200,height:150,assets:sourceAssets,pixelsPerMM:2,opaqueBackground:true)
    try FileManager.default.removeItem(at:sourceAssets)
    let(destination,target)=try project("Destination"),plan=try ArtworkTransferGraph.plan(portable,into:destination,objectID:target,offset:.init(),existingAsset:{name,limit in try ArtworkTransferIO.readAsset(directory:targetAssets,name:name,limit:limit)})
    for (name,data) in plan.assetWrites {try data.write(to:targetAssets.appendingPathComponent(name))}
    let pasted=plan.project.canvasWorkspace!.artwork!,after=ArtworkRenderer.image(pasted,width:200,height:150,assets:targetAssets,pixelsPerMM:2,opaqueBackground:true)
    func pixels(_ image:NSImage)throws->Data {let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)),context=CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;context.draw(cg,in:.init(x:0,y:0,width:cg.width,height:cg.height));return Data(bytes:context.data!,count:cg.width*cg.height*4)}
    func encodedPNG(_ image:NSImage)throws->Data {let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)));return try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))}
    let afterPDF=try pdf(pasted,targetAssets),afterSVG=try SVGRenderer.document(pasted,width:200,height:150,assets:targetAssets)
    XCTAssertEqual(try pixels(before),try pixels(after));XCTAssertEqual(try JSONEncoder.form.encode(p),source);XCTAssertEqual(plan.assetWrites.values.first,png)
    if let directory=ProcessInfo.processInfo.environment["FORM_TRANSFER_PROOF_DIR"] {let path=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true);try encodedPNG(before).write(to:path.appendingPathComponent("before.png"));try encodedPNG(after).write(to:path.appendingPathComponent("after.png"));try beforePDF.write(to:path.appendingPathComponent("before.pdf"));try afterPDF.write(to:path.appendingPathComponent("after.pdf"));try Data(beforeSVG.utf8).write(to:path.appendingPathComponent("before.svg"));try Data(afterSVG.utf8).write(to:path.appendingPathComponent("after.svg"));let report:[String:Any] = ["source_json_sha256":ArtworkTransferBundle.digest(source),"original_image_sha256":ArtworkTransferBundle.digest(png),"portable_image_sha256":ArtworkTransferBundle.digest(plan.assetWrites.values.first!),"source_directory_deleted":true,"pixels_identical":true,"private_pasteboard_only":true,"bundle_bytes":try bundle.encoded().count,"added_component_count":plan.addedComponentIDs.count];try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:path.appendingPathComponent("report.json"))}
  }
  func testDescriptorReaderCapsMissingFilesAndSymlinks()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
    try Data(repeating:1,count:40).write(to:root.appendingPathComponent("asset.png"));XCTAssertThrowsError(try ArtworkTransferIO.readAsset(directory:root,name:"asset.png",limit:39));XCTAssertEqual(try ArtworkTransferIO.readAsset(directory:root,name:"asset.png",limit:40)?.count,40)
    try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link.png"),withDestinationURL:root.appendingPathComponent("asset.png"));XCTAssertThrowsError(try ArtworkTransferIO.readAsset(directory:root,name:"link.png",limit:40));XCTAssertThrowsError(try ArtworkTransferIO.readAsset(directory:root,name:"../asset.png",limit:40));XCTAssertNil(try ArtworkTransferIO.readAsset(directory:root,name:"missing.png",limit:40))
  }
}

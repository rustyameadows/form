import AppKit
import CryptoKit
import FormCore
import FormGraphics
import ImageIO
import XCTest
@testable import FormApp

@MainActor final class CanvasGenerationReferenceCaptureTests:XCTestCase {
  private func repository()throws->ProjectRepository {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("canvas-reference-test-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    return try ProjectRepository(root:root)
  }
  private func sheet(_ art:Artwork,width:Double=100,height:Double=50)throws->(Project,UUID) {
    var project=Project(name:"Reference source"),object=try projectObject(width:width,height:height)
    object.artwork=art;project.objects=[object];return(project,object.id)
  }
  private func projectObject(width:Double,height:Double)throws->ProductObject {
    try Project(name:"Factory").makeObject(recipeID:"artboard",parameters:["width":width,"depth":height])
  }
  private func rectangle(_ x:Double,_ y:Double,_ width:Double,_ height:Double,_ color:String,parent:UUID?=nil)->ArtworkElement {
    var value=ArtworkElement(kind:"rectangle",x:x,y:y,width:width,height:height,color:color);value.parentID=parent;return value
  }
  private func color(_ image:CanvasGenerationReferenceImage,_ x:Int,_ y:Int)throws->NSColor {
    let source=try XCTUnwrap(CGImageSourceCreateWithData(image.png as CFData,nil))
    let bitmap=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
    let sample=try XCTUnwrap(bitmap.cropping(to:CGRect(x:x,y:y,width:1,height:1)))
    let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
    var bytes=[UInt8](repeating:0,count:4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context=try XCTUnwrap(CGContext(data:buffer.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
        space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
      context.setBlendMode(.copy);context.draw(sample,in:CGRect(x:0,y:0,width:1,height:1))
    }
    let alpha=Double(bytes[3])/255
    guard alpha>0 else{return .clear}
    return NSColor(srgbRed:Double(bytes[0])/255/alpha,green:Double(bytes[1])/255/alpha,
      blue:Double(bytes[2])/255/alpha,alpha:alpha)
  }
  private func png(_ rgba:[UInt8])throws->Data {
    let provider=try XCTUnwrap(CGDataProvider(data:Data(rgba) as CFData))
    let image=try XCTUnwrap(CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    return try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]))
  }
  private func pdf(top:[CGFloat])throws->Data {
    let data=NSMutableData(),space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
    var box=CGRect(x:0,y:0,width:100,height:50)
    let consumer=try XCTUnwrap(CGDataConsumer(data:data))
    let context=try XCTUnwrap(CGContext(consumer:consumer,mediaBox:&box,nil))
    context.beginPDFPage(nil)
    context.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:top)))
    context.fill(CGRect(x:0,y:25,width:100,height:25))
    context.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[0,0,1,1])))
    context.fill(CGRect(x:0,y:0,width:100,height:25))
    context.endPDFPage();context.closePDF()
    return data as Data
  }
  private func verifyPlacedVectorReference(_ filename:String,original:Data,replacement:Data)throws {
    let repository=try repository()
    var element=ArtworkElement(kind:"image",x:0,y:0,width:100,height:50);element.asset=filename
    let(project,id)=try sheet(.init(elements:[element],bleed:0),width:100,height:50)
    let before=project,assets=repository.url(for:project.id).appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    let file=assets.appendingPathComponent(filename);try original.write(to:file)
    let reference=CanvasGenerationReference(objectID:id,elementIDs:[element.id],title:filename)
    let first=try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:reference,longEdge:200)
    XCTAssertEqual(first.width,200);XCTAssertEqual(first.height,100)
    XCTAssertEqual(try color(first,100,20).redComponent,1,accuracy:0.02)
    XCTAssertEqual(try color(first,100,20).blueComponent,0,accuracy:0.02)
    XCTAssertEqual(try color(first,100,80).blueComponent,1,accuracy:0.02,"Placed vector documents retain their top/bottom orientation.")
    XCTAssertEqual(try color(first,100,80).alphaComponent,1,accuracy:0.02)
    XCTAssertEqual(try Data(contentsOf:file),original)
    let frozen=first.png
    try replacement.write(to:file,options:.atomic)
    let second=try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:reference,longEdge:200)
    XCTAssertEqual(first.png,frozen)
    XCTAssertNotEqual(first.pngSHA256,second.pngSHA256);XCTAssertNotEqual(first.sourceSHA256,second.sourceSHA256)
    XCTAssertEqual(try color(second,100,20).greenComponent,1,accuracy:0.02)
    XCTAssertEqual(try color(second,100,20).redComponent,0,accuracy:0.02)
    XCTAssertEqual(try color(second,100,80).blueComponent,1,accuracy:0.02)
    XCTAssertEqual(try Data(contentsOf:file),replacement);XCTAssertEqual(project,before)
    try FileManager.default.removeItem(at:file)
    XCTAssertEqual(try color(first,100,20).redComponent,1,accuracy:0.02,"The captured PNG remains usable after the source file disappears.")
    XCTAssertEqual(first.png,frozen)
  }

  func testPlacedPDFReferenceCapturesPixelsAndFreezesSourceBytes()throws {
    try verifyPlacedVectorReference("placed.pdf",original:pdf(top:[1,0,0,1]),replacement:pdf(top:[0,1,0,1]))
  }

  func testPlacedSVGReferenceCapturesPixelsAndFreezesSourceBytes()throws {
    func svg(_ top:String)->Data {
      Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"50\" viewBox=\"0 0 100 50\"><rect width=\"100\" height=\"25\" fill=\"\(top)\"/><rect y=\"25\" width=\"100\" height=\"25\" fill=\"#0000FF\"/></svg>".utf8)
    }
    try verifyPlacedVectorReference("placed.svg",original:svg("#FF0000"),replacement:svg("#00FF00"))
  }

  func testLockedArtboardCapturePreservesBackgroundOrientationBoundsAndSource()throws {
    let repository=try repository()
    var art=Artwork(background:"#102030",elements:[rectangle(10,5,20,10,"#FF0000")],bleed:0)
    var(project,id)=try sheet(art);project.objects[0].locked=true;project.objects[0].artwork!.elements[0].locked=true
    try repository.save(project)
    let before=project,saved=try repository.load(project.id)
    let engine=OperationEngine(repository:repository);engine.project=project
    let reference=CanvasGenerationReference(objectID:id,title:"Locked artboard")
    let captured=try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:reference,longEdge:200)
    let expectedBackground=try XCTUnwrap(FormColor.color(art.background).usingColorSpace(.sRGB))
    XCTAssertEqual(captured.width,200);XCTAssertEqual(captured.height,100)
    XCTAssertEqual(try color(captured,30,20).redComponent,1,accuracy:0.01)
    XCTAssertEqual(try color(captured,30,80).redComponent,expectedBackground.redComponent,accuracy:0.01,"Image coordinates must preserve the Canvas top edge.")
    XCTAssertEqual(try color(captured,30,80).greenComponent,expectedBackground.greenComponent,accuracy:0.01)
    XCTAssertEqual(try color(captured,30,80).blueComponent,expectedBackground.blueComponent,accuracy:0.01)
    XCTAssertEqual(try color(captured,180,80).alphaComponent,1,accuracy:0.01)
    XCTAssertEqual(captured.pngSHA256,SHA256.hash(data:captured.png).map{String(format:"%02x",$0)}.joined())
    XCTAssertEqual(project,before);XCTAssertEqual(engine.project,before);XCTAssertTrue(engine.undoStack.isEmpty)
    XCTAssertEqual(try repository.load(project.id),saved)
    art.backgroundOpacity=0;project.objects[0].artwork=art
    let transparent=try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:reference,longEdge:200)
    XCTAssertEqual(try color(transparent,180,80).alphaComponent,0)
    XCTAssertNotEqual(captured.sourceSHA256,transparent.sourceSHA256)
  }

  func testSelectedSubgroupKeepsAncestorScaleOpacityAndAlphaClipWithoutSiblingInk()throws {
    let repository=try repository();var project=Project(name:"Subgroup")
    let workspace=try project.ensureCanvasWorkspace()
    var parent=ArtworkElement(kind:"group",x:30,y:20,width:40,height:20)
    parent.affine = .scale(2,1);parent.opacity=0.5;parent.locked=true
    var target=ArtworkElement(kind:"group",x:0,y:0,width:40,height:20);target.parentID=parent.id
    var mask=rectangle(0,0,20,20,"#FFFFFF",parent:parent.id);mask.hidden=true
    target.clipID=mask.id;target.clipMode="alpha"
    let red=rectangle(0,0,30,20,"#FF0000",parent:target.id),blue=rectangle(10,0,30,20,"#0000FF",parent:target.id)
    let unrelated=rectangle(0,0,40,20,"#00FF00",parent:parent.id)
    project.objects[0].artwork!.elements=[parent,mask,target,red,blue,unrelated]
    let before=project,reference=CanvasGenerationReference(objectID:workspace.id,elementIDs:[target.id],title:"Clipped subgroup")
    let image=try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:reference,longEdge:160)
    XCTAssertEqual(image.width,160);XCTAssertEqual(image.height,40)
    XCTAssertEqual(try color(image,20,20).redComponent,1,accuracy:0.01)
    XCTAssertEqual(try color(image,20,20).alphaComponent,0.5,accuracy:0.02)
    XCTAssertEqual(try color(image,60,20).blueComponent,1,accuracy:0.01)
    XCTAssertEqual(try color(image,60,20).alphaComponent,0.5,accuracy:0.02,"Overlapping children are masked and attenuated once.")
    XCTAssertEqual(try color(image,120,20).alphaComponent,0)
    XCTAssertEqual(project,before)
  }

  func testSelectedArtboardAssetRemainsClippedToTrimAndWorkspaceShadowHasRoom()throws {
    let repository=try repository(),shape=rectangle(-10,5,30,10,"#FF0000")
    let(project,id)=try sheet(.init(elements:[shape],bleed:0),width:40,height:20)
    let cropped=try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,
      reference:.init(objectID:id,elementIDs:[shape.id],title:"Trimmed asset"),longEdge:100)
    XCTAssertEqual(cropped.width,100);XCTAssertEqual(cropped.height,50)
    XCTAssertEqual(try color(cropped,5,25).redComponent,1,accuracy:0.01)
    var canvas=Project(name:"Shadow");let workspace=try canvas.ensureCanvasWorkspace()
    var shaded=rectangle(20,30,10,10,"#FF0000"),shadow=ArtworkShadow()
    shadow.offset = .init(6,0);shadow.blur=0;shadow.opacity=1;shadow.color="#000000";shaded.shadow=shadow
    canvas.objects[0].artwork!.elements=[shaded]
    let image=try CanvasGenerationReferenceCapture.capture(project:canvas,repository:repository,
      reference:.init(objectID:workspace.id,elementIDs:[shaded.id],title:"Shadow"),longEdge:160)
    XCTAssertEqual(image.width,160);XCTAssertEqual(image.height,100)
    XCTAssertEqual(try color(image,40,50).redComponent,1,accuracy:0.01)
    XCTAssertEqual(try color(image,140,50).alphaComponent,1,accuracy:0.01)
    XCTAssertEqual(try color(image,140,50).redComponent,0,accuracy:0.01)
  }

  func testImageBytesAreFrozenAndAssetChangesChangeOnlyLaterSnapshots()throws {
    let repository=try repository();var image=ArtworkElement(kind:"image",x:0,y:0,width:20,height:10);image.asset="reference.png"
    let(project,id)=try sheet(.init(elements:[image],bleed:0),width:20,height:10)
    let assets=repository.url(for:project.id).appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    let file=assets.appendingPathComponent("reference.png");try png([255,0,0,255]).write(to:file)
    let reference=CanvasGenerationReference(objectID:id,elementIDs:[image.id],title:"Image")
    let first=try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:reference,longEdge:100)
    let frozen=first.png;try png([0,0,255,255]).write(to:file,options:.atomic)
    let second=try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:reference,longEdge:100)
    XCTAssertEqual(first.png,frozen);XCTAssertNotEqual(first.pngSHA256,second.pngSHA256);XCTAssertNotEqual(first.sourceSHA256,second.sourceSHA256)
    XCTAssertEqual(try color(first,50,25).redComponent,1,accuracy:0.01)
    XCTAssertEqual(try color(second,50,25).blueComponent,1,accuracy:0.01)
    XCTAssertEqual(try Data(contentsOf:file),try png([0,0,255,255]))
    try FileManager.default.removeItem(at:file)
    XCTAssertThrowsError(try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:reference))
    XCTAssertEqual(first.png,frozen,"A provider can continue using its captured bytes after the source is removed.")
  }

  func testDenseSelectedGroupCaptureIsDeterministicAndBounded()throws {
    let repository=try repository();var project=Project(name:"Dense Canvas")
    let workspace=try project.ensureCanvasWorkspace()
    let parent=ArtworkElement(kind:"group",x:120,y:60,width:400,height:200)
    var group=ArtworkElement(kind:"group",x:30,y:25,width:200,height:150);group.parentID=parent.id
    var elements=[parent,group]
    for row in 0..<15 {for column in 0..<20 {
      elements.append(rectangle(Double(column)*10,Double(row)*10,10,10,(row+column)%2==0 ? "#FF0000":"#0000FF",parent:group.id))
    }}
    elements.append(rectangle(0,0,400,200,"#00FF00",parent:parent.id))
    project.objects[0].artwork!.elements=elements
    let before=project,reference=CanvasGenerationReference(objectID:workspace.id,elementIDs:[group.id,elements[2].id],title:"Dense group")
    let first=try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:reference,longEdge:512)
    let second=try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:reference,longEdge:512)
    XCTAssertEqual(first.width,512);XCTAssertEqual(first.height,384)
    XCTAssertEqual(first.png,second.png);XCTAssertEqual(first.sourceSHA256,second.sourceSHA256)
    XCTAssertEqual(try color(first,8,8).redComponent,1,accuracy:0.01)
    XCTAssertLessThan(first.png.count,CanvasGenerationReferenceCapture.maximumPNGBytes)
    XCTAssertEqual(project,before)
  }

  func testReferenceInventoryAndCaptureRejectStaleHiddenUnsupportedAndOversizedChoices()throws {
    let repository=try repository();var project=Project(name:"Inventory")
    let workspace=try project.ensureCanvasWorkspace()
    var hidden=ArtworkElement(kind:"group",x:0,y:0,width:20,height:10);hidden.hidden=true
    var child=ArtworkElement(kind:"image",x:0,y:0,width:20,height:10);child.asset="unused.png";child.parentID=hidden.id
    project.objects[0].artwork!.elements=[hidden,child]
    var definition=try project.makeObject(recipeID:"artboard",name:"Support",parameters:["width":20,"depth":10])
    definition.componentDefinition=true;definition.canvasSourceOnly=true;definition.artwork = .init(elements:[rectangle(0,0,20,10,"#00FFFF")],bleed:0)
    project.objects.append(definition)
    var instance=ArtworkElement(kind:"group",x:40,y:50,width:20,height:10);instance.component = .init(sourceObjectID:definition.id)
    instance.contentSize = .init(20,10)
    project.objects[0].artwork!.elements.append(instance)
    var linked=try project.makeObject(recipeID:"artboard",name:"Linked");linked.artworkSourceID=definition.id;project.objects.append(linked)
    XCTAssertNoThrow(try project.validateArtworkLinks(),"The inventory fixture must be valid authored component artwork before capture resolves it.")
    let choices=CanvasGenerationReferenceCapture.choices(in:project)
    XCTAssertEqual(choices.map(\.elementIDs),[[instance.id]])
    let captured=try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:try XCTUnwrap(choices.first),longEdge:100)
    XCTAssertEqual(try color(captured,50,25).greenComponent,1,accuracy:0.01)
    for reference in [CanvasGenerationReference(objectID:workspace.id,title:"Unbounded"),
      .init(objectID:workspace.id,elementIDs:[child.id],title:"Hidden"),.init(objectID:definition.id,title:"Definition"),
      .init(objectID:linked.id,title:"Linked"),.init(objectID:UUID(),title:"Deleted"),
      .init(objectID:workspace.id,elementIDs:[UUID()],title:"Deleted layer")] {
      XCTAssertThrowsError(try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:reference))
    }
    XCTAssertThrowsError(try CanvasGenerationReferenceCapture.capture(project:project,repository:repository,reference:choices[0],longEdge:2049))
  }

  func testReferenceTitlesBoundCombinedNamesAndUnicodeWithoutChangingSource()throws {
    var group=ArtworkElement(kind:"group",x:0,y:0,width:20,height:10)
    group.name=String(repeating:"L",count:500)
    var(project,id)=try sheet(.init(elements:[group],bleed:0))
    project.objects[0].name=String(repeating:"A",count:500)
    let before=project,choices=CanvasGenerationReferenceCapture.choices(in:project)
    let selected=try XCTUnwrap(choices.first{$0.elementIDs==[group.id]})
    XCTAssertEqual(selected.title,String(repeating:"L",count:500))
    XCTAssertEqual(selected.objectID,id);XCTAssertEqual(project,before)
    let family="👨‍👩‍👧‍👦",longUnicode=String(repeating:family,count:500)
    let reference=CanvasGenerationReference(objectID:id,elementIDs:[group.id],title:longUnicode)
    XCTAssertLessThanOrEqual(reference.title.count,500)
    XCTAssertLessThanOrEqual(reference.title.utf8.count,2_000)
    XCTAssertEqual(reference.title,String(repeating:family,count:2_000/family.utf8.count),"Do not split a composed character at the byte boundary.")
    XCTAssertEqual(CanvasGenerationReference(objectID:id,title:" \n\t ").title,"Canvas reference")
    XCTAssertEqual(CanvasGenerationReference(objectID:id,title:"A"+String(repeating:"\u{301}",count:2_001)).title,"Canvas reference")
  }
}

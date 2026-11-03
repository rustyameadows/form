import AppKit
import XCTest
import CryptoKit
@testable import FormCore
@testable import FormGraphics


private final class PhysicalPDFContentCollector {
  var streams=[String](),visited=Set<String>()
  func add(_ stream:CGPDFStreamRef) {
    guard visited.count<128,visited.insert(String(describing:stream)).inserted else{return}
    var format=CGPDFDataFormat.raw
    if let data=CGPDFStreamCopyData(stream,&format),let text=String(data:data as Data,encoding:.isoLatin1){streams.append(text)}
    var resources:CGPDFDictionaryRef?
    if let dictionary=CGPDFStreamGetDictionary(stream),CGPDFDictionaryGetDictionary(dictionary,"Resources",&resources),let resources {collect(resources)}
  }
  func collect(_ resources:CGPDFDictionaryRef) {
    var objects:CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(resources,"XObject",&objects),let objects else{return}
    CGPDFDictionaryApplyFunction(objects,{_,object,context in
      guard let context else{return}
      let owner=Unmanaged<PhysicalPDFContentCollector>.fromOpaque(context).takeUnretainedValue()
      var stream:CGPDFStreamRef?
      if CGPDFObjectGetValue(object,.stream,&stream),let stream {
        var subtype:UnsafePointer<CChar>?
        if let dictionary=CGPDFStreamGetDictionary(stream),CGPDFDictionaryGetName(dictionary,"Subtype",&subtype),let subtype,String(cString:subtype)=="Form" {owner.add(stream)}
      }
    },Unmanaged.passUnretained(self).toOpaque())
  }
}

@MainActor final class PublicationPhysicalOutputTests:XCTestCase {
  private func fixture()throws->(Project,UUID,UUID,URL) {
    let assets=FileManager.default.temporaryDirectory.appendingPathComponent("physical-publication-output-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:assets)}
    let profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"));try profile.store(in:assets)
    var project=Project(name:"Letter pages on ledger parents"),ids=[UUID]()
    let black=try SwatchCommands.save(in:&project,name:"Black only",color:"#000000",printInk:.init(kind:.processCMYK,components:.init(0,0,0,1),profile:profile.reference))
    for index in 1...8 {
      var object=try project.makeObject(recipeID:"artboard",name:"Page \(index)",parameters:["width":215.9,"depth":279.4])
      var text=ArtworkElement(kind:"text",x:14,y:20,width:180,height:30,text:"PAGE \(index)",color:"#000000",fontSize:24);text.fillSwatchID=black
      var art=Artwork(elements:[text],bleed:0);art.backgroundOpacity=0;art.outputColorProfile=profile.reference;object.artwork=art
      project.objects.append(object);ids.append(object.id)
    }
    // An actual color raster on a white page must not prevent a neighboring
    // colored reader page from producing its independent K-only physical crop.
    let bitmap=try XCTUnwrap(CGContext(data:nil,width:8,height:8,bitsPerComponent:8,bytesPerRow:32,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.setFillColor(CGColor(red:0.05,green:0.1,blue:1,alpha:1));bitmap.fill(.init(x:0,y:0,width:8,height:8))
    let image=NSBitmapImageRep(cgImage:try XCTUnwrap(bitmap.makeImage()))
    try XCTUnwrap(image.representation(using:.png,properties:[:])).write(to:assets.appendingPathComponent("color.png"))
    project.objects[2].artwork!.elements.append(.init(kind:"image",x:14,y:65,width:90,height:90,asset:"color.png"))
    let id=try PublicationCommands.createPublication(in:&project,name:"Mixed physical intent",pages:ids)
    let pages=project.publications![0].pages
    var colored=PaperStock(thicknessMM:0.22);colored.profile = .init();colored.profile!.color="#D6B766"
    let white=PaperStock(thicknessMM:0.1)
    let parents=[SheetAssemblyParentSheet(frontPageIDs:[pages[7].id,pages[0].id],backPageIDs:[pages[1].id,pages[6].id],stock:colored,sizeMM:.init(431.8,279.4),printIntent:.blackOnly),
      SheetAssemblyParentSheet(frontPageIDs:[pages[5].id,pages[2].id],backPageIDs:[pages[3].id,pages[4].id],stock:white,sizeMM:.init(431.8,279.4),printIntent:.color)]
    var definition=SheetAssemblyDefinition(publicationID:id,stock:white);definition.binding = .init(style:.saddleStitch);definition.parentSheets=parents
    let assembly=try SheetAssemblyCommands.create(in:&project,definition:definition,name:"Declared edition")
    return(project,id,assembly,assets)
  }
  func testActualMixedInkPDFUsesExactLedgerSidesAndRetainsEveryLetterSourceOnce()throws {
    let(project,id,objectID,assets)=try fixture(),before=project,assembly=try XCTUnwrap(project.objects.first{$0.id==objectID})
    let plan=try PublicationOutput.physicalArrangement(project,documentID:id,assembly:assembly,layout:.booklet)
    XCTAssertEqual(plan.sides.count,4);XCTAssertEqual(plan.sides.map{$0.placements.map(\.sourcePage)},[[8,1],[2,7],[6,3],[4,5]])
    XCTAssertEqual(PublicationOutput.physicalPreflight(project,documentID:id,assembly:assembly,assets:assets,layout:.booklet)["can_export"] as? Bool,true)
    let data=try PublicationOutput.physicalPDF(project,documentID:id,assembly:assembly,assets:assets,outlineText:true,layout:.booklet)
    if let path=ProcessInfo.processInfo.environment["LAB_PHYSICAL_PRINT_EVIDENCE_DIR"] {
      let directory=URL(fileURLWithPath:path,isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
      try data.write(to:directory.appendingPathComponent("mixed-ink-ledger.pdf"))
    }
    let pdf=try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data:data as CFData))))
    XCTAssertEqual(pdf.numberOfPages,4)
    for index in 1...4 {
      let page=try XCTUnwrap(pdf.page(at:index))
      XCTAssertEqual(page.getBoxRect(.mediaBox).width,1224,accuracy:0.001);XCTAssertEqual(page.getBoxRect(.mediaBox).height,792,accuracy:0.001)
      XCTAssertEqual(page.getBoxRect(.trimBox),page.getBoxRect(.mediaBox));XCTAssertEqual(page.getBoxRect(.bleedBox),page.getBoxRect(.mediaBox))
    }
    XCTAssertEqual(project,before)
  }
  func testColoredStockRejectsPaintedSubstrateAndChromaticInkWithoutChangingSource()throws {
    var(project,id,objectID,assets)=try fixture(),assembly=try XCTUnwrap(project.objects.first{$0.id==objectID})
    project.objects[0].artwork!.background="#D6B766";project.objects[0].artwork!.backgroundOpacity=1
    XCTAssertEqual(PublicationOutput.physicalPreflight(project,documentID:id,assembly:assembly,assets:assets,layout:.booklet)["can_export"] as? Bool,false)
    project.objects[0].artwork!.backgroundOpacity=0
    project.objects[0].artwork!.elements[0].fillSwatchID=nil;project.objects[0].artwork!.elements[0].color="#FF0000"
    let before=project
    XCTAssertThrowsError(try PublicationOutput.physicalPDF(project,documentID:id,assembly:assembly,assets:assets,layout:.booklet))
    XCTAssertEqual(project,before)
    XCTAssertEqual(PublicationOutput.physicalPreflight(project,documentID:id,assembly:assembly,assets:assets,layout:.spreads,previewOnly:true)["can_export"] as? Bool,true)
  }
  func testDifferentPhysicalEditionsRequireAnExplicitStockChoice()throws {
    var(project,id,objectID,_)=try fixture()
    var other=try XCTUnwrap(project.objects.first{$0.id==objectID});other.id=UUID();other.designID=UUID();other.name="Another paper edition"
    other.sheetAssembly!.parentSheets![0].printIntent = .color;project.objects.append(other)
    XCTAssertThrowsError(try PublicationOutput.physicalAssembly(project,documentID:id))
    XCTAssertEqual(try PublicationOutput.physicalAssembly(project,documentID:id,objectID:objectID)?.id,objectID)
  }
  private func raster(_ page:CGPDFPage)throws->Data {
    let box=page.getBoxRect(.mediaBox),width=Int(box.width.rounded()),height=Int(box.height.rounded())
    let context=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray:1,alpha:1));context.fill(.init(x:0,y:0,width:width,height:height));context.drawPDFPage(page)
    return Data(bytes:try XCTUnwrap(context.data),count:context.bytesPerRow*height)
  }
  private func firstPage(_ data:Data)throws->CGPDFPage {
    let document=try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data:data as CFData))))
    return try XCTUnwrap(document.page(at:1))
  }
  func testVisibleOffTrimStrokeIsRetainedAndOffTrimBooleanOperandCannotChangeItsResult()throws {
    var(project,id,objectID,assets)=try fixture();let assembly=try XCTUnwrap(project.objects.first{$0.id==objectID})
    let baseline=try raster(firstPage(PublicationOutput.physicalPDF(project,documentID:id,assembly:assembly,assets:assets,layout:.pages)))
    let black=try XCTUnwrap(project.swatches?.first{$0.name=="Black only"}?.id)
    var line=ArtworkElement(kind:"line",x:-1,y:70,width:0.001,height:60,color:"#000000")
    line.stroke = .init(color:"#000000",width:4);line.stroke!.swatchID=black
    project.objects[0].artwork!.elements.append(line)
    let withStroke=try raster(firstPage(PublicationOutput.physicalPDF(project,documentID:id,assembly:assembly,assets:assets,layout:.pages)))
    var newDark=0
    // Original type starts14mm into the page; only the real4mm-wide line can
    // add ink in this leftmost3mm strip, despite its negative frame position.
    for y in 0..<792 {for x in 0..<8 {
      let offset=(y*612+x)*4
      if withStroke[offset]<80,baseline[offset]>220{newDark+=1}
    }}
    XCTAssertGreaterThan(newDark,100)
    project.objects[0].artwork!.elements.removeLast()
    var group=ArtworkElement(kind:"group",x:30,y:80,width:100,height:80,color:"#000000")
    group.booleanOperation="intersect";group.fillSwatchID=black
    var inside=ArtworkElement(kind:"rectangle",x:0,y:0,width:30,height:30,color:"#000000");inside.parentID=group.id;inside.fillSwatchID=black
    var outside=ArtworkElement(kind:"rectangle",x:-100,y:0,width:20,height:30,color:"#000000");outside.parentID=group.id;outside.fillSwatchID=black
    project.objects[0].artwork!.elements += [group,inside,outside]
    let withEmptyIntersection=try raster(firstPage(PublicationOutput.physicalPDF(project,documentID:id,assembly:assembly,assets:assets,layout:.pages)))
    XCTAssertEqual(withEmptyIntersection,baseline,"The outside operand makes the intersection empty. Dropping that operand must never print the remaining inside rectangle.")
  }
  func testEvenTinyDeclaredChromaticInkIsRejectedForActualKOnlyStock()throws {
    var(project,id,objectID,assets)=try fixture();let assembly=try XCTUnwrap(project.objects.first{$0.id==objectID})
    let index=try XCTUnwrap(project.swatches?.firstIndex{$0.name=="Black only"})
    project.swatches![index].printInk!.components.cyan=1e-12
    XCTAssertEqual(PublicationOutput.physicalPreflight(project,documentID:id,assembly:assembly,assets:assets,layout:.booklet)["can_export"] as? Bool,false)
    XCTAssertThrowsError(try PublicationOutput.physicalPDF(project,documentID:id,assembly:assembly,assets:assets,layout:.booklet))
  }
  func testFinalCatalogRetainsSelectedICCIntentAndQuartzKeepsExactKPaintNumbers()throws {
    let(project,id,objectID,assets)=try fixture(),assembly=try XCTUnwrap(project.objects.first{$0.id==objectID})
    let profile=try ICCOutputProfile(reference:try XCTUnwrap(project.objects[0].artwork?.outputColorProfile),assets:assets)
    let data=try PublicationOutput.physicalPDF(project,documentID:id,assembly:assembly,assets:assets,outlineText:true,layout:.booklet)
    let document=try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data:data as CFData))))
    var intents:CGPDFArrayRef?;XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(document.catalog),"OutputIntents",&intents))
    var intent:CGPDFDictionaryRef?;XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(intents),0,&intent))
    var identifier:CGPDFStringRef?;XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(intent),"OutputConditionIdentifier",&identifier))
    XCTAssertEqual(CGPDFStringCopyTextString(try XCTUnwrap(identifier)) as String?,"FORM-ICC-"+profile.reference.sha256)
    var stream:CGPDFStreamRef?;XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(intent),"DestOutputProfile",&stream))
    var format=CGPDFDataFormat.raw;let embedded=try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream),&format)) as Data
    XCTAssertEqual(SHA256.hash(data:embedded).map{String(format:"%02x",$0)}.joined(),profile.reference.sha256)
    for index in 1...2 {
      let page=try XCTUnwrap(document.page(at:index)),collector=PhysicalPDFContentCollector()
      var content:CGPDFStreamRef?;XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(page.dictionary),"Contents",&content));collector.add(try XCTUnwrap(content))
      var resources:CGPDFDictionaryRef?
      if CGPDFDictionaryGetDictionary(try XCTUnwrap(page.dictionary),"Resources",&resources),let resources {collector.collect(resources)}
      let commands=collector.streams.joined(separator:"\n") as NSString
      let number="([-+]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+))"
      let pattern=Array(repeating:number,count:4).joined(separator:"\\s+")+"\\s+(?:scn|sc|k)\\b"
      let matches=try NSRegularExpression(pattern:pattern).matches(in:commands as String,range:NSRange(location:0,length:commands.length))
      XCTAssertFalse(matches.isEmpty,"Actual colored-stock sides must retain explicit four-channel paint operators.")
      for match in matches {
        let channels=(1...4).map{Double(commands.substring(with:match.range(at:$0)))!}
        XCTAssertEqual(Array(channels.prefix(3)),[0,0,0],"Labeling the final catalog must not reconvert or tint actualK source paints.")
      }
    }
  }

}

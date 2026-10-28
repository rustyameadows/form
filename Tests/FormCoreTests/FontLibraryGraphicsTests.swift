import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class FontLibraryGraphicsTests:XCTestCase {
  func testInstalledCatalogSearchActualFaceIdentityLazyPreviewCacheAndTiming() throws {
    FontLibraryCatalog.invalidate();let begin=Date(),faces=FontLibraryCatalog.faces,cold=Date().timeIntervalSince(begin)*1000
    XCTAssertGreaterThan(faces.count,100);XCTAssertEqual(Set(faces.map(\.id)).count,faces.count)
    XCTAssertTrue(FontLibraryCatalog.search("Georgia Bold").allSatisfy{$0.family.contains("Georgia") && $0.style.localizedCaseInsensitiveContains("Bold")})
    let exact=try XCTUnwrap(faces.first{$0.name=="Georgia-BoldItalic"})
    XCTAssertTrue(FontLibraryCatalog.search(exact.name).contains(exact))
    let builds=FontLibraryCatalog.diagnostics["preview_builds"] as! Int
    for _ in 0..<5 {for face in faces.prefix(12) {let preview=try XCTUnwrap(FontLibraryCatalog.preview(face.name));XCTAssertEqual(preview.fontName,face.name)}}
    XCTAssertEqual((FontLibraryCatalog.diagnostics["preview_builds"] as! Int)-builds,12)
    XCTAssertEqual(FontLibraryCatalog.diagnostics["preview_cache_limit"] as? Int,128)
    var samples:[Double]=[]
    for _ in 0..<20 {let t=Date();_ = FontLibraryCatalog.search("Bold");samples.append(Date().timeIntervalSince(t)*1000)}
    let report:[String:Any]=["faces":faces.count,"families":Set(faces.map(\.family)).count,"cold_index_ms":cold,"warm_query_median_ms":samples.sorted()[10],"visible_preview_builds":12,"diagnostics":FontLibraryCatalog.diagnostics]
    print("FONT33_MEASUREMENT",report)
    if let directory=ProcessInfo.processInfo.environment["FORM_FONT_PROOF_DIR"] {
      let folder=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("font-catalog-measurement.json"))
    }
  }
  func testMissingFontReportIncludesInheritedMarkersAndUnresolvedExactChoicesInPhysicalArtwork() throws {
    var p=try Samples.fieldGuide(),source=p.textStories![0].sourceElement
    source.listItems?[0].fontName="FORM Missing Marker"
    source.glyphOverrides=[.init(location:0,sourceText:"P",glyph:.init(fontName:"FORM Missing Glyph",glyphID:12,glyphName:"P",fontSignature:String(repeating:"a",count:64)))]
    try PublicationCommands.setSource(in:&p,storyID:p.textStories![0].id,source:source)
    let art=try XCTUnwrap(p.surfaceArtwork(p.objects[1]))
    XCTAssertEqual(Set(FontCatalog.missing(in:art)),["FORM Missing Marker","FORM Missing Glyph"])
    let fonts=FontLibraryCatalog.usage(p)
    XCTAssertTrue(fonts.contains{$0["font_name"] as? String=="FORM Missing Marker" && $0["available"] as? Bool==false})
    XCTAssertTrue(fonts.contains{$0["font_name"] as? String=="FORM Missing Glyph" && $0["exact_glyph_count"] as? Int==1})
    XCTAssertFalse(GlyphEngine.issues(source).isEmpty)
  }
  func testPhysicalActualFaceSpecimenKeepsSourceAndFontAssignments() throws {
    let names=["Baskerville","Georgia","HelveticaNeue-Medium","Menlo-Regular","Skia","HoeflerText-Regular"]
    func text(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ value:String,_ size:Double,_ face:String,_ color:String)->ArtworkElement {
      var e=ArtworkElement(kind:"text",x:x,y:y,width:w,height:h,text:value,color:color,fontSize:size);e.typography=Typography();e.typography!.fontName=face;e.typography!.kerningMode="metrics";return e
    }
    var art=Artwork(background:"#F5F1E6",bleed:0)
    art.elements=[text(12,12,156,7,"FORM / TYPE LIBRARY",8,"Menlo-Regular","#A55A36"),text(12,24,156,17,"The character of a face",27,"Baskerville","#243C35"),text(12,44,156,9,"Installed on this Mac. Chosen explicitly. Kept editable.",11,"Georgia","#243C35")]
    for (i,name) in names.enumerated() {
      let y=62+Double(i)*25
      art.elements.append(text(12,y,156,6,String(format:"%02d",i+1)+" / "+name,7,"Menlo-Regular","#A55A36"))
      art.elements.append(text(12,y+7,156,15,"Light, matter & form. 0123456789",22,name,"#243C35"))
    }
    art.elements.append(text(12,218,156,6,"ACTUAL FACE STUDY / 180 × 230 MM",7,"Menlo-Regular","#A55A36"))
    let before=art,factor=TypographyEngine.pointsPerMM,data=NSMutableData();var box=CGRect(x:0,y:0,width:180*factor,height:230*factor)
    let context=try XCTUnwrap(CGContext(consumer:CGDataConsumer(data:data)!,mediaBox:&box,nil))
    context.beginPDFPage(nil);context.translateBy(x:0,y:box.height);context.scaleBy(x:factor,y:-factor)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
    ArtworkRenderer.draw(art,width:180,height:230,assets:FileManager.default.temporaryDirectory)
    NSGraphicsContext.restoreGraphicsState();context.endPDFPage();context.closePDF()
    let pdf=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:data as CFData)!)),page=try XCTUnwrap(pdf.page(at:1))
    XCTAssertEqual(page.getBoxRect(.mediaBox).width,180*factor,accuracy:0.001);XCTAssertEqual(page.getBoxRect(.mediaBox).height,230*factor,accuracy:0.001)
    XCTAssertEqual(art,before);XCTAssertTrue(FontCatalog.missing(in:art).isEmpty)
    if let directory=ProcessInfo.processInfo.environment["FORM_FONT_PROOF_DIR"] {
      let folder=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      try (data as Data).write(to:folder.appendingPathComponent("font-library-specimen.pdf"))
      try JSONEncoder.form.encode(art).write(to:folder.appendingPathComponent("font-library-specimen.json"))
    }
  }
  func testDocumentUsageAndReplacementMeasureTwoHundredRichObjectsAndSharedStoryWithoutSourceLoss() throws {
    var p=try Samples.fieldGuide();let names=["Georgia","Baskerville","HelveticaNeue-Medium","Menlo-Regular","Skia","HoeflerText-Regular","FORM Missing Face"]
    for i in 0..<200 {
      var e=ArtworkElement(kind:"text",x:10,y:10,width:100,height:30,text:"Original words stay editable. Clear notes preserve intent.",fontSize:12)
      var type=Typography();type.fontName=names[i%names.count];e.typography=type
      e.textRuns=(0..<4).map {n in var t=type;t.fontName=names[(i+n)%names.count];return .init(location:n*8,length:8,typography:t,fontSize:12,color:"#243C35")}
      p.objects[0].artwork!.elements.append(e)
    }
    let before=p,start=Date(),report=FontLibraryCatalog.usage(p),usageMS=Date().timeIntervalSince(start)*1000
    let replaceStart=Date(),changed=try FontUsage.replacing(in:p,from:"FORM Missing Face",to:"Georgia"),replacementMS=Date().timeIntervalSince(replaceStart)*1000
    XCTAssertTrue(report.contains{$0["font_name"] as? String=="FORM Missing Face" && $0["available"] as? Bool==false})
    XCTAssertEqual(p,before);XCTAssertEqual(changed.objects[0].artwork!.elements.map(\.text),p.objects[0].artwork!.elements.map(\.text))
    XCTAssertEqual(changed.textStories,p.textStories);XCTAssertFalse(FontUsage.uses(in:changed).contains{$0.fontName=="FORM Missing Face"})
    let measurement:[String:Any]=["text_objects":200,"rich_spans":800,"shared_stories":1,"usage_assignments":FontUsage.uses(in:p).count,"usage_ms":usageMS,"replacement_ms":replacementMS]
    print("FONT33_DOCUMENT_MEASUREMENT",measurement)
    if let directory=ProcessInfo.processInfo.environment["FORM_FONT_PROOF_DIR"] {try JSONSerialization.data(withJSONObject:measurement,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:directory).appendingPathComponent("font-document-measurement.json"))}
  }

  func testPreviewCoverageUsesActualFaceCharactersAndLabelsCustomFallback() throws {
    for name in ["AlBayan","AlNile","Georgia","AppleColorEmoji"] {
      guard let font=NSFont(name:name,size:18) else{continue}
      let preview=FontLibraryCatalog.previewText(FontLibraryCatalog.defaultPreview,font:font)
      if !preview.usesFallback {XCTAssertTrue(CharacterSet(charactersIn:preview.text).subtracting(.whitespacesAndNewlines).isSubset(of:font.coveredCharacterSet))}
      let custom=FontLibraryCatalog.previewText("A𐍈😀",font:font)
      XCTAssertEqual(custom.text,"A𐍈😀")
      XCTAssertEqual(custom.usesFallback,!CharacterSet(charactersIn:custom.text).isSubset(of:font.coveredCharacterSet))
    }
  }

}

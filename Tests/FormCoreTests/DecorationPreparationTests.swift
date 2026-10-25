import AppKit
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class DecorationPreparationTests:XCTestCase {
  private func fixture(_ elements:[ArtworkElement])throws -> (Project,UUID,URL) {
    let assets=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    addTeardownBlock{try? FileManager.default.removeItem(at:assets)}
    var p=Project(name:"Decoration study"),o=try p.makeObject(recipeID:"artboard",name:"Physical artwork",parameters:["width":100,"depth":80])
    var art=Artwork(elements:elements);art.backgroundOpacity=0;art.bleed=0;o.artwork=art;p.objects=[o]
    return(p,o.id,assets)
  }
  private func rect(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ color:String)->ArtworkElement {.init(kind:"rectangle",x:x,y:y,width:w,height:h,color:color)}
  private func region(_ plan:DecorationGeometry,_ key:String)throws->CGPath {try XCTUnwrap(plan.regions.first{$0.paintKey=="rgb:"+key}?.path)}
  func testOptionsAreExplicitFiniteAndProcessSpecific()throws {
    let htv=DecorationPreparationOptions(process:.htv),dtf=DecorationPreparationOptions(process:.dtf)
    XCTAssertTrue(htv.mirror);XCTAssertFalse(dtf.mirror);XCTAssertTrue(dtf.includeUnderbaseReference);XCTAssertFalse(htv.includeBackground)
    try htv.validate();try dtf.validate()
    var bad=dtf;bad.dpi = .nan;XCTAssertThrowsError(try bad.validate())
    bad=dtf;bad.weedMargin=3;XCTAssertThrowsError(try bad.validate())
    bad=htv;bad.includeUnderbaseReference=true;XCTAssertThrowsError(try bad.validate())
  }
  func testVisibleMaterialRegionsRespectInterleavedLayerOrderAndUnionInternalOverlaps()throws {
    let(p,id,assets)=try fixture([rect(0,0,100,80,"#0000FF"),rect(20,20,60,40,"#FF0000"),rect(40,30,20,20,"#0000FF")])
    let before=p,plan=try DecorationGeometry(project:p,objectID:id,options:.init(process:.htv),assets:assets)
    XCTAssertTrue(plan.canExport);XCTAssertEqual(plan.regions.count,2)
    let blue=try region(plan,"#0000FF"),red=try region(plan,"#FF0000")
    XCTAssertTrue(blue.contains(.init(x:10,y:10)));XCTAssertTrue(blue.contains(.init(x:50,y:40)))
    XCTAssertFalse(red.contains(.init(x:50,y:40)));XCTAssertTrue(red.contains(.init(x:30,y:40)));XCTAssertFalse(blue.contains(.init(x:30,y:40)))
    XCTAssertEqual(p,before)
    let(q,qid,a)=try fixture([rect(10,10,40,30,"#0000FF"),rect(30,10,40,30,"#0000FF")])
    let union=try DecorationGeometry(project:q,objectID:qid,options:.init(process:.htv),assets:a)
    var closes=0;try region(union,"#0000FF").applyWithBlock{if $0.pointee.type == .closeSubpath {closes+=1}}
    XCTAssertEqual(closes,1,"Overlapping same-material silhouettes must not leave duplicate internal cut boundaries")
  }
  func testNestedClipsAndEvenOddCounterAreAppliedToActualCutRegions()throws {
    let blue=rect(0,0,100,80,"#0000FF")
    var outer=rect(10,10,50,60,"#000000");outer.hidden=true
    var group=ArtworkElement(kind:"group",x:0,y:0,width:100,height:80);group.clipID=outer.id
    var mask=ArtworkElement(kind:"path",x:20,y:20,width:60,height:40);mask.parentID=group.id
    mask.path = .init(width:60,height:40,contours:[.init([.init(.init(0,0)),.init(.init(60,0)),.init(.init(60,40)),.init(.init(0,40))]),.init([.init(.init(20,10)),.init(.init(40,10)),.init(.init(40,30)),.init(.init(20,30))])],evenOdd:true)
    var red=rect(0,0,100,80,"#FF0000");red.parentID=group.id;red.clipID=mask.id
    let(p,id,assets)=try fixture([blue,outer,group,mask,red]),plan=try DecorationGeometry(project:p,objectID:id,options:.init(process:.htv),assets:assets)
    let cut=try region(plan,"#FF0000"),under=try region(plan,"#0000FF")
    XCTAssertTrue(cut.contains(.init(x:30,y:25)));XCTAssertFalse(cut.contains(.init(x:50,y:40)));XCTAssertFalse(cut.contains(.init(x:70,y:25)))
    XCTAssertTrue(under.contains(.init(x:50,y:40)));XCTAssertTrue(under.contains(.init(x:70,y:25)))
  }
  func testZeroTintAndWhiteShowThroughClearPreviousContentInsteadOfLeavingOldInk()throws {
    var(p,id,assets)=try fixture([rect(0,0,100,80,"#0000FF"),rect(20,20,20,20,"#FFFFFF"),rect(60,20,20,20,"#FFFFFF")])
    let profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"));try profile.store(in:assets)
    let ink=ProductionInk(kind:.spot,components:.init(0,0.5,1,0),profile:profile.reference,spotName:"Zero requested ink",tint:0)
    let zero=try SwatchCommands.save(in:&p,name:"Zero tint",color:"#FFFFFF",printInk:ink);p.objects[0].artwork!.elements[2].fillSwatchID=zero
    var options=DecorationPreparationOptions(process:.dtf);options.whitePolicy = .showThrough
    let plan=try DecorationGeometry(project:p,objectID:id,options:options,assets:assets)
    XCTAssertTrue(plan.canExport);XCTAssertFalse(plan.silhouette.contains(.init(x:30,y:30)));XCTAssertFalse(plan.silhouette.contains(.init(x:70,y:30)))
    XCTAssertFalse(try region(plan,"#0000FF").contains(.init(x:70,y:30)))
    options.whitePolicy = .printOpaqueWhite
    let white=try DecorationGeometry(project:p,objectID:id,options:options,assets:assets)
    XCTAssertTrue(white.silhouette.contains(.init(x:30,y:30)));XCTAssertFalse(white.silhouette.contains(.init(x:70,y:30)))
    let image=try DecorationOutput.rgba(plan,dpi:127),bitmap=NSBitmapImageRep(cgImage:image)
    XCTAssertEqual(bitmap.colorAt(x:150,y:150)!.alphaComponent,0,accuracy:0.01)
    XCTAssertEqual(bitmap.colorAt(x:350,y:150)!.alphaComponent,0,accuracy:0.01)
    XCTAssertGreaterThan(bitmap.colorAt(x:50,y:50)!.alphaComponent,0.99)
    if let dir=ProcessInfo.processInfo.environment["FORM_DECORATION_PROOF_DIR"] {
      let output=URL(fileURLWithPath:dir).appendingPathComponent("knockout");try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
      options.dpi=127
      let proof=try DecorationGeometry(project:p,objectID:id,options:options,assets:assets),bundle=try DecorationOutput.generate(proof,project:p,assets:assets)
      for file in bundle.files {try file.data.write(to:output.appendingPathComponent(file.name))}
    }
  }
  func testUnsupportedPaintAndFractionalHTVTintDoNotBecomeGuessedSilhouettes()throws {
    var(p,id,assets)=try fixture([rect(10,10,40,30,"#0000FF")])
    p.objects[0].artwork!.elements[0].opacity=0.5
    XCTAssertFalse(try DecorationGeometry(project:p,objectID:id,options:.init(process:.htv),assets:assets).canExport)
    p.objects[0].artwork!.elements[0].opacity=nil
    let profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"));try profile.store(in:assets)
    let ink=ProductionInk(kind:.spot,components:.init(0,0.5,1,0),profile:profile.reference,spotName:"Orange",tint:0.5)
    let swatch=try SwatchCommands.save(in:&p,name:"Orange50",color:"#E5C7A5",printInk:ink);p.objects[0].artwork!.elements[0].fillSwatchID=swatch
    XCTAssertFalse(try DecorationGeometry(project:p,objectID:id,options:.init(process:.htv),assets:assets).canExport)
    var options=DecorationPreparationOptions(process:.dtf)
    XCTAssertFalse(try DecorationGeometry(project:p,objectID:id,options:options,assets:assets).canExport)
    options.convertSpotAlternates=true
    let plan=try DecorationGeometry(project:p,objectID:id,options:options,assets:assets);XCTAssertTrue(plan.canExport)
    XCTAssertThrowsError(try DecorationOutput.rgba(plan,dpi:.nan))
  }
  func testMirrorAndWeedFrameProduceActualSizeCutSVGWithoutScalingOrTextLoss()throws {
    var triangle=ArtworkElement(kind:"path",x:10,y:10,width:20,height:30,color:"#15324B")
    triangle.path = .init(width:20,height:30,contours:[.init([.init(.init(0,0)),.init(.init(20,0)),.init(.init(0,30))])])
    let(p,id,assets)=try fixture([triangle]);var options=DecorationPreparationOptions(process:.htv);options.weedMargin=4
    let plan=try DecorationGeometry(project:p,objectID:id,options:options,assets:assets),r=plan.regions[0],path=plan.deliveryPath(r.path)
    XCTAssertEqual(plan.pageWidth,108);XCTAssertEqual(plan.pageHeight,88)
    XCTAssertTrue(path.contains(.init(x:92,y:18)));XCTAssertFalse(path.contains(.init(x:16,y:18)))
    let svg=try DecorationOutput.cutSVG(plan,region:r)
    XCTAssertTrue(svg.contains("width=\"108.0mm\""));XCTAssertTrue(svg.contains("height=\"88.0mm\""))
    XCTAssertTrue(svg.contains("id=\"weed-border\""));XCTAssertFalse(svg.contains("<text"));XCTAssertFalse(svg.contains("transform=\"scale"))
  }
  func testDTFProcessDeliveryHasRealCMYKButOriginalSpotsRemainInSource()throws {
    var(p,id,assets)=try fixture([rect(10,10,40,30,"#D46A32")])
    let profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"));try profile.store(in:assets)
    p.objects[0].artwork!.outputColorProfile=profile.reference
    let ink=ProductionInk(kind:.spot,components:.init(0.1,0.4,0.8,0.2),profile:profile.reference,spotName:"Original Orange",tint:0.5)
    let swatch=try SwatchCommands.save(in:&p,name:"Original ink",color:profile.inkPreview(ink),printInk:ink);p.objects[0].artwork!.elements[0].fillSwatchID=swatch
    let before=p;var options=DecorationPreparationOptions(process:.dtf);options.convertSpotAlternates=true;options.colorDelivery = .profiledProcess
    let plan=try DecorationGeometry(project:p,objectID:id,options:options,assets:assets),bundle=try DecorationOutput.generate(plan,project:p,assets:assets)
    let color=try XCTUnwrap(bundle.files.first{$0.name=="Color-Process.pdf"});XCTAssertEqual(color.role,"delivery")
    let pdf=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:color.data as CFData)!)),page=pdf.page(at:1)!
    var resources:CGPDFDictionaryRef?,spaces:CGPDFDictionaryRef?,array:CGPDFArrayRef?
    XCTAssertTrue(CGPDFDictionaryGetDictionary(page.dictionary!,"Resources",&resources));XCTAssertTrue(CGPDFDictionaryGetDictionary(resources!,"ColorSpace",&spaces))
    XCTAssertTrue(CGPDFDictionaryGetArray(spaces!,"Process",&array));XCTAssertFalse(CGPDFDictionaryGetArray(spaces!,"Ink0",&array))
    XCTAssertEqual(page.getBoxRect(.trimBox).width/TypographyEngine.pointsPerMM,100,accuracy:1e-9)
    XCTAssertEqual(p,before);XCTAssertEqual(plan.source.swatches.first!.printInk,ink)
    XCTAssertEqual(bundle.files.first{$0.name=="Reference-color.png"}?.role,"reference")
    let imageData=try XCTUnwrap(bundle.files.first{$0.name=="Reference-color.png"}?.data)
    let imageSource=try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData,nil)),properties=CGImageSourceCopyPropertiesAtIndex(imageSource,0,nil)! as NSDictionary
    let encodedX=(properties[kCGImagePropertyDPIWidth] as! NSNumber).doubleValue,encodedY=(properties[kCGImagePropertyDPIHeight] as! NSNumber).doubleValue
    XCTAssertEqual(encodedX,bundle.report["encoded_dpi_x"] as! Double,accuracy:0.02);XCTAssertEqual(encodedY,bundle.report["encoded_dpi_y"] as! Double,accuracy:0.02)
    XCTAssertEqual(Double(properties[kCGImagePropertyPixelWidth] as! Int)/encodedX*25.4,100,accuracy:0.01)
    XCTAssertEqual(Double(properties[kCGImagePropertyPixelHeight] as! Int)/encodedY*25.4,80,accuracy:0.01)
    XCTAssertTrue(bundle.files.contains{$0.name=="Reference-underbase.svg" && $0.role=="reference"})
    if let dir=ProcessInfo.processInfo.environment["FORM_DECORATION_PROOF_DIR"] {
      let output=URL(fileURLWithPath:dir).appendingPathComponent("process");try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
      for file in bundle.files {try file.data.write(to:output.appendingPathComponent(file.name))}
      try JSONEncoder.form.encode(plan.source).write(to:output.appendingPathComponent("Source.json"))
    }
  }
  func testRealMerchandiseZonesAndNASAArtworkProducePhysicalHTVAndDTFHandoffProofs()throws {
    let p=try Samples.merchandiseCollection(),before=p
    let assets=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:assets)}
    let tee=try XCTUnwrap(p.objects.first{$0.name=="Tee / field-division direct art"}),cap=try XCTUnwrap(p.objects.first{$0.name=="Cap / conforming NASA front art"})
    let capSource=try p.decorationSourceSnapshot(objectID:cap.id)
    XCTAssertEqual(capSource.target?.surface,.cylindricalBand);XCTAssertEqual(capSource.width,96);XCTAssertEqual(capSource.height,30)
    for process in [DecorationProcess.htv,.dtf] {
      let plan=try DecorationGeometry(project:p,objectID:tee.id,options:.init(process:process),assets:assets)
      XCTAssertTrue(plan.canExport,plan.issues.map(\.message).joined(separator:"; "))
      XCTAssertEqual(plan.source.target?.surface,.planar);XCTAssertEqual(plan.width,240);XCTAssertEqual(plan.height,200)
      let bundle=try DecorationOutput.generate(plan,project:p,assets:assets)
      XCTAssertTrue(bundle.files.contains{$0.role=="delivery"})
      XCTAssertTrue(plan.source.objects.contains{$0.artwork?.elements.contains{$0.text=="NASA"}==true})
      if let dir=ProcessInfo.processInfo.environment["FORM_DECORATION_PROOF_DIR"] {
        let output=URL(fileURLWithPath:dir).appendingPathComponent(process.rawValue);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for file in bundle.files {try file.data.write(to:output.appendingPathComponent(file.name))}
        try JSONSerialization.data(withJSONObject:bundle.report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("Report.json"))
        try JSONEncoder.form.encode(plan.source).write(to:output.appendingPathComponent("Source.json"))
      }
    }
    XCTAssertEqual(p,before)
  }

  func testSourceSnapshotPreservesSingleRichStoryStylesComponentOwnersAndOriginalWords()throws {
    var(p,id,_)=try fixture([rect(20,45,40,20,"#15324B")])
    var first=ArtworkElement(kind:"text",x:10,y:10,width:80,height:25,text:"Orbital office",color:"#15324B",fontSize:14)
    var type=Typography();type.fontName="Georgia";type.caseTreatment="uppercase";type.features=[1:3];type.variations=[2003265652:1.2]
    first.typography=type
    let glyph=try GlyphCatalog.glyph(fontName:"Georgia",id:Int(CTFontGetGlyphWithName(NSFont(name:"Georgia",size:14)! as CTFont,"O" as CFString)))
    first.glyphOverrides=[.init(location:0,sourceText:"O",glyph:glyph)]
    let style=ArtworkTextStyle(name:"Original caption",typography:type,fontSize:14);p.textStyles=[style];first.textStyle = .init(styleID:style.id)
    first.textRuns=[.init(location:0,length:7,typography:type,fontSize:15,color:"#15324B")]
    p.objects[0].artwork!.elements.insert(first,at:0)
    var second=try p.makeObject(recipeID:"artboard",name:"Second story frame",parameters:["width":100,"depth":80])
    var next=first;next.id=UUID();next.text="Assembly notes";next.textRuns=nil;next.glyphOverrides=nil;second.artwork = .init(elements:[next]);p.objects.append(second)
    let story=try PublicationCommands.createStory(in:&p,frames:[.init(objectID:id,elementID:first.id),.init(objectID:second.id,elementID:next.id)])
    let mark=p.objects[0].artwork!.elements.last!.id,component=try ComponentCommands.create(in:&p,objectID:id,elements:[mark],name:"Reusable mark")
    let before=p,snapshot=try p.decorationSourceSnapshot(objectID:id)
    XCTAssertEqual(snapshot.stories,p.textStories);XCTAssertEqual(snapshot.stories.first?.id,story)
    XCTAssertEqual(snapshot.stories.first?.text,"Orbital office\nAssembly notes");XCTAssertEqual(snapshot.textStyles,[style])
    XCTAssertEqual(Set(snapshot.objects.map(\.id)),[id,second.id,component.source])
    XCTAssertEqual(snapshot.objects.first{$0.id==id}?.artwork?.elements.first?.storyFrame?.storyID,story)
    XCTAssertEqual(snapshot.objects.first{$0.id==id}?.artwork?.elements.first?.text,"")
    XCTAssertEqual(snapshot.stories.first?.glyphOverrides?.first?.glyph,glyph)
    XCTAssertEqual(snapshot.stories.first?.sourceElement.typography?.features,[1:3]);XCTAssertEqual(snapshot.stories.first?.sourceElement.typography?.variations,[2003265652:1.2])
    XCTAssertEqual(p,before)
  }
  func testBoundedNativePlanPerformanceOnRealMerchandiseCollection()throws {
    let p=try Samples.merchandiseCollection(),before=p,id=try XCTUnwrap(p.objects.first{$0.name=="Tee / field-division direct art"}?.id)
    let assets=FileManager.default.temporaryDirectory
    var times:[Double]=[]
    for _ in 0..<12 {
      let start=CFAbsoluteTimeGetCurrent(),plan=try DecorationGeometry(project:p,objectID:id,options:.init(process:.htv),assets:assets)
      XCTAssertTrue(plan.canExport);times.append((CFAbsoluteTimeGetCurrent()-start)*1000)
    }
    let sorted=times.sorted(),median=sorted[sorted.count/2],p95=sorted[max(0,Int(ceil(Double(sorted.count)*0.95))-1)]
    if let dir=ProcessInfo.processInfo.environment["FORM_DECORATION_PROOF_DIR"] {
      try FileManager.default.createDirectory(atPath:dir,withIntermediateDirectories:true)
      try JSONSerialization.data(withJSONObject:["fixture":"real merchandise collection / tee NASA artwork","samples":times.count,"percentile_method":"nearest rank","median_ms":median,"p95_ms":p95,"max_ms":sorted.last!,"objects":p.objects.count],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:dir).appendingPathComponent("performance.json"))
    }
    XCTAssertLessThan(median,2000,"A bounded vector preparation must remain practical; record timings independently of this broad stall guard")
    XCTAssertEqual(p,before)
  }

}

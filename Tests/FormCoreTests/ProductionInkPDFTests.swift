import AppKit
import CryptoKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class ProductionInkPDFTests:XCTestCase {
  private func fixture() throws -> (Project,InkPrintPage,URL) {
    let assets=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:assets)}
    let profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"));try profile.store(in:assets)
    var p=Project(name:"COLOR / A declared intent"),art=Artwork(background:"#FFFFFF",bleed:3);art.backgroundOpacity=0;art.outputColorProfile=profile.reference
    var tints:[UUID]=[]
    for value in [0.0,0.25,0.5,0.75,1] {
      let ink=ProductionInk(kind:.spot,components:.init(0,0.65,1,0.05),profile:profile.reference,spotName:"FORM Orange",tint:value)
      tints.append(try SwatchCommands.save(in:&p,name:"Orange \(value)",color:profile.inkPreview(ink),printInk:ink))
    }
    let cyan=try SwatchCommands.save(in:&p,name:"Cyan",color:"#00A8D1",printInk:.init(kind:.processCMYK,components:.init(1,0,0,0),profile:profile.reference))
    let quarter=try SwatchCommands.save(in:&p,name:"Cyan25",color:"#BEE6EF",printInk:.init(kind:.processCMYK,components:.init(0.25,0,0,0),profile:profile.reference))
    let mixed=try SwatchCommands.save(in:&p,name:"Four components",color:"#B47B49",printInk:.init(kind:.processCMYK,components:.init(0.1,0.45,0.8,0.2),profile:profile.reference))
    let varnish=try SwatchCommands.save(in:&p,name:"White alternate",color:"#FFFFFF",printInk:.init(kind:.spot,components:.init(0,0,0,0),profile:profile.reference,spotName:"FORM Varnish"))
    func rectangle(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ id:UUID)->ArtworkElement {var e=ArtworkElement(kind:"rectangle",x:x,y:y,width:w,height:h);e.fillSwatchID=id;return e}
    for (i,id) in tints.enumerated() {art.elements.append(rectangle(12+31*Double(i),16,25,13,id))}
    for (i,value) in [0.0,0.25,0.5,0.75,1].enumerated() {
      let ink=ProductionInk(kind:.processCMYK,components:.init(value,0,0,0),profile:profile.reference)
      let id=try SwatchCommands.save(in:&p,name:"Cyan ramp \(i)",color:profile.inkPreview(ink),printInk:ink)
      art.elements.append(rectangle(12+31*Double(i),37,25,13,id))
    }
    func label(_ x:Double,_ y:Double,_ width:Double,_ value:String,_ size:Double=7)->ArtworkElement {
      var e=ArtworkElement(kind:"text",x:x,y:y,width:width,height:5,text:value,color:"#243C35",fontSize:size)
      e.typography=Typography();e.typography!.fontName="Menlo-Regular";return e
    }
    art.elements.append(label(12,5,156,"FORM / COLORANTS IN PRACTICE",9))
    for (i,value) in [0,25,50,75,100].enumerated() {
      art.elements.append(label(12+31*Double(i),31,27,"ORANGE \(value)%",6))
      art.elements.append(label(12+31*Double(i),52,27,"CYAN \(value)%",6))
    }
    art.elements.append(label(12,110,156,"180 × 120 MM / 3 MM BLEED / OPAQUE NORMAL KNOCKOUT / UNSCREENED MAPS",6))
    art.elements.append(rectangle(12,65,64,38,cyan))
    var outer=rectangle(18,68,52,32,cyan);outer.hidden=true
    let group=ArtworkElement(kind:"group",x:0,y:0,width:180,height:120)
    var clipped=group;clipped.clipID=outer.id
    var mask=ArtworkElement(kind:"path",x:20,y:70,width:48,height:28);mask.parentID=group.id
    mask.path = .init(width:48,height:28,contours:[.init([.init(.init(0,0)),.init(.init(48,0)),.init(.init(48,28)),.init(.init(0,28))]),.init([.init(.init(14,8)),.init(.init(34,8)),.init(.init(34,20)),.init(.init(14,20))])],evenOdd:true)
    var orange=rectangle(12,65,64,38,tints[2]);orange.parentID=group.id;orange.clipID=mask.id
    art.elements += [outer,clipped,mask,orange,rectangle(59,82,17,12,quarter),rectangle(80,65,12,38,cyan),rectangle(82,70,8,25,varnish),rectangle(94,65,64,38,mixed)]
    var triangleMask=ArtworkElement(kind:"path",x:106,y:73,width:42,height:22)
    triangleMask.path = .init(width:42,height:22,contours:[.init([.init(.init(0,0)),.init(.init(42,0)),.init(.init(21,22))])]);triangleMask.hidden=true
    var triangle=rectangle(106,73,42,22,tints[3]);triangle.clipID=triangleMask.id
    art.elements += [triangleMask,triangle,rectangle(160,65,18,38,cyan)]
    var glyph=ArtworkElement(kind:"text",x:164,y:72,width:16,height:28,text:"O",fontSize:48);glyph.typography=Typography();glyph.typography!.fontName="Georgia";glyph.typography!.frameMode="point";glyph.fillSwatchID=tints[4]
    art.elements.append(glyph)
    try p.validateSwatches();try validateArtwork(art)
    return(p,.init(name:"COLOR / Opaque colorants",artwork:art,width:180,height:120),assets)
  }
  private func dictionary(_ page:CGPDFPage)->CGPDFDictionaryRef {
    var resources:CGPDFDictionaryRef?;precondition(CGPDFDictionaryGetDictionary(page.dictionary!,"Resources",&resources));return resources!
  }
  func testRealICCBasedSeparationResourcesRawCMYKAndPhysicalPositiveInkMapPages() throws {
    let(p,page,assets)=try fixture(),before=p,source=page.artwork
    let composite=try ProductionInkPDF.export(project:p,pages:[page],assets:assets,mode:.composite),plates=try ProductionInkPDF.export(project:p,pages:[page],assets:assets,mode:.plates)
    let pdf=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:composite.data as CFData)!)),first=try XCTUnwrap(pdf.page(at:1))
    var spaces:CGPDFDictionaryRef?;XCTAssertTrue(CGPDFDictionaryGetDictionary(dictionary(first),"ColorSpace",&spaces))
    for key in ["Ink0","Ink1"] {
      var array:CGPDFArrayRef?;XCTAssertTrue(CGPDFDictionaryGetArray(spaces!,key,&array))
      var type:UnsafePointer<CChar>?;XCTAssertTrue(CGPDFArrayGetName(array!,0,&type));XCTAssertEqual(String(cString:type!),"Separation")
      var alternate:CGPDFArrayRef?;XCTAssertTrue(CGPDFArrayGetArray(array!,2,&alternate));XCTAssertTrue(CGPDFArrayGetName(alternate!,0,&type));XCTAssertEqual(String(cString:type!),"ICCBased")
      var stream:CGPDFStreamRef?;XCTAssertTrue(CGPDFArrayGetStream(alternate!,1,&stream))
      var n:CGPDFInteger=0;XCTAssertTrue(CGPDFDictionaryGetInteger(CGPDFStreamGetDictionary(stream!)!,"N",&n));XCTAssertEqual(n,4)
      var format=CGPDFDataFormat.raw;let data=CGPDFStreamCopyData(stream!,&format)! as Data
      XCTAssertEqual(SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),page.artwork.outputColorProfile!.sha256)
    }
    var content:CGPDFStreamRef?;XCTAssertTrue(CGPDFDictionaryGetStream(first.dictionary!,"Contents",&content));var format=CGPDFDataFormat.raw
    let commands=String(data:CGPDFStreamCopyData(content!,&format)! as Data,encoding:.utf8)!
    XCTAssertTrue(commands.contains("/Process cs 0.1 0.45 0.8 0.2 scn"));XCTAssertTrue(commands.contains("/Ink0 cs 0 scn"));XCTAssertTrue(commands.contains("/Ink1 cs 1 scn"))
    XCTAssertTrue(commands.contains("W* n"));XCTAssertTrue(commands.contains("W n"))
    let separated=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:plates.data as CFData)!));XCTAssertEqual(separated.numberOfPages,6)
    for i in 1...6 {
      let output=separated.page(at:i)!,trim=output.getBoxRect(.trimBox)
      XCTAssertEqual(trim.width/TypographyEngine.pointsPerMM,180,accuracy:1e-9);XCTAssertEqual(trim.height/TypographyEngine.pointsPerMM,120,accuracy:1e-9)
      XCTAssertEqual(output.getBoxRect(.mediaBox).width/TypographyEngine.pointsPerMM,186,accuracy:1e-9)
    }
    XCTAssertEqual(p,before);XCTAssertEqual(page.artwork,source)
    if let dir=ProcessInfo.processInfo.environment["FORM_INK_PROOF_DIR"] {
      let folder=URL(fileURLWithPath:dir);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      try composite.data.write(to:folder.appendingPathComponent("production-inks-composite.pdf"));try plates.data.write(to:folder.appendingPathComponent("production-inks-plates.pdf"))
      try JSONSerialization.data(withJSONObject:composite.report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("production-inks-report.json"))
      let glyph=source.elements.last!,path=try TypographyEngine.outlinePaintRuns(glyph).first!.path
      var t=glyph.localTransform.cg;let world=path.copy(using:&t)!,box=world.boundingBoxOfPath
      let points:[String:Any]=["counter":[box.midX,box.midY],"ring":[box.minX+box.width*0.07,box.midY]]
      try JSONSerialization.data(withJSONObject:points).write(to:folder.appendingPathComponent("production-ink-glyph-points.json"))
    }
  }
  func testUnsupportedPaintAndProfileMismatchAreVisibleAndNeverSilentlyFlattened() throws {
    let(p,page,assets)=try fixture();var modified=page
    modified.artwork.elements[0].opacity=0.5
    let report=ProductionInkPDF.preflight(project:p,pages:[modified],assets:assets)
    XCTAssertEqual(report["can_export"] as? Bool,false);XCTAssertThrowsError(try ProductionInkPDF.export(project:p,pages:[modified],assets:assets,mode:.composite))
    modified=page;modified.artwork.outputColorProfile=nil
    XCTAssertEqual(ProductionInkPDF.preflight(project:p,pages:[modified],assets:assets)["can_export"] as? Bool,false)
    modified=page;var gradient=ArtworkGradient();gradient.stops=[.init(0,"#000000"),.init(1,"#FFFFFF")]
    modified.artwork.elements[0].gradient=gradient
    XCTAssertEqual(ProductionInkPDF.preflight(project:p,pages:[modified],assets:assets)["can_export"] as? Bool,false)
    for variant in ["image","blend","fill_alpha","stroke_alpha","blur"] {
      modified=page
      switch variant {
      case "image":modified.artwork.elements[0].kind="image"
      case "blend":modified.artwork.elements[0].blendMode="multiply"
      case "fill_alpha":modified.artwork.elements[0].fillOpacity=0.25
      case "stroke_alpha":modified.artwork.elements[0].stroke=ArtworkStroke();modified.artwork.elements[0].stroke!.opacity=0.5
      default:modified.artwork.elements[0].blur=ArtworkBlur()
      }
      XCTAssertEqual(ProductionInkPDF.preflight(project:p,pages:[modified],assets:assets)["can_export"] as? Bool,false,variant)
    }
    var malformed=p;malformed.swatches![0].printInk!.spotName=nil
    XCTAssertEqual(ProductionInkPDF.preflight(project:malformed,pages:[page],assets:assets)["can_export"] as? Bool,false,"Malformed declarations must report an issue before traversing paints")
    var mismatched=p
    mismatched.swatches![0].printInk!.profile.sha256=String(repeating:"b",count:64)
    mismatched.swatches![0].printInk!.profile.asset="icc-"+String(repeating:"b",count:64)+".icc"
    XCTAssertEqual(ProductionInkPDF.preflight(project:mismatched,pages:[page],assets:assets)["can_export"] as? Bool,false)
  }
  func testPDFNumbersRetainTinyDeclaredComponentsWithoutUnsupportedExponentSyntax() {
    for value in [1e-20,Double.leastNonzeroMagnitude,0.12345678901234567,1.0,-1e-8] {
      let output=ProductionInkPDF.number(value);XCTAssertFalse(output.lowercased().contains("e"));XCTAssertEqual(Double(output),value)
    }
    XCTAssertEqual(ProductionInkPDF.pdfName("FORM / Orange #1"),"FORM#20#2F#20Orange#20#231")
  }
}

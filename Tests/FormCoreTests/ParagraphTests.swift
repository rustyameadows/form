import AppKit
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

final class ParagraphTests: XCTestCase {
  private func text(_ content:String="A\tB\tC\tD\t12.5") -> ArtworkElement {
    var e=ArtworkElement(kind:"text",x:0,y:0,width:190,height:80,text:content,color:"#222222",fontSize:12)
    var t=Typography();t.fontName="Menlo-Regular";t.kerningMode="metrics";e.typography=t;return e
  }
  @MainActor private func line(_ e:ArtworkElement,millimeters:Bool=false)->CTLine {
    let factor=millimeters ? 1 : TypographyEngine.pointsPerMM
    let frame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(TypographyEngine.attributed(e,millimeters:millimeters)),CFRange(),CGPath(rect:.init(x:0,y:0,width:e.width*factor,height:e.height*factor),transform:nil),nil)
    return (CTFrameGetLines(frame) as! [CTLine])[0]
  }
  func testActualLeftCenterRightAndDecimalTabPositionsInPointsAndMillimeters() async throws {
    await MainActor.run {
      var e=text()
      e.typography!.tabStops=[.init(location:60),.init(location:120,alignment:"center"),.init(location:180,alignment:"right"),.init(location:240,alignment:"decimal")]
      let l=line(e)
      let width=CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string:"C",attributes:TypographyEngine.attributes(e.typography!,size:12,color:e.color,millimeters:false))),nil,nil,nil)
      XCTAssertEqual(CTLineGetOffsetForStringIndex(l,2,nil),60,accuracy:1e-6)
      XCTAssertEqual(CTLineGetOffsetForStringIndex(l,4,nil),120-width/2,accuracy:1e-6)
      XCTAssertEqual(CTLineGetOffsetForStringIndex(l,6,nil),180-width,accuracy:1e-6)
      XCTAssertEqual(CTLineGetOffsetForStringIndex(l,10,nil)+width/2,240,accuracy:1e-6)
      let mm=line(e,millimeters:true)
      for i in [2,4,6,10] { XCTAssertEqual(CTLineGetOffsetForStringIndex(mm,i,nil)*TypographyEngine.pointsPerMM,CTLineGetOffsetForStringIndex(l,i,nil),accuracy:1e-5) }
      e.text="A\t12,5";e.typography!.tabStops=[.init(location:120,alignment:"decimal",decimalSeparator:",")]
      XCTAssertEqual(CTLineGetOffsetForStringIndex(line(e),4,nil)+width/2,120,accuracy:1e-6)
      e.text="A\tB\tC";e.typography!.tabStops=[];e.typography!.defaultTabInterval=36
      XCTAssertEqual(CTLineGetOffsetForStringIndex(line(e),2,nil),36,accuracy:1e-6)
      XCTAssertEqual(CTLineGetOffsetForStringIndex(line(e),4,nil),72,accuracy:1e-6)
      let svg=try? SVGRenderer.document(.init(elements:[e]),width:190,height:80,assets:URL(fileURLWithPath:"/tmp"),outlineText:false)
      XCTAssertNotNil(svg);XCTAssertFalse(svg!.contains("<text "))
    }
  }
  func testParagraphRangeExpandsWithoutChangingRichCharactersOrOtherParagraphs() throws {
    var e=text("A😀\tB\nSecond\tline")
    var smaller=e.typography!;smaller.tracking=0.7
    e.textRuns=[.init(location:0,length:3,typography:smaller,fontSize:8,color:"#CC3300")]
    var a=Artwork(elements:[e]);let old=a
    try ArtworkCommands.apply("paragraph",to:&a,ids:[e.id],arguments:["location":3,"length":0,
      "typography":["tabStops":[["location":80.0,"alignment":"right"]],"hyphenation":0.5]])
    let runs=a.elements[0].textRuns!
    XCTAssertEqual(runs[0].fontSize,8);XCTAssertEqual(runs[0].color,"#CC3300")
    XCTAssertEqual(runs[0].typography.tracking,0.7)
    XCTAssertTrue(runs.filter{$0.location<6}.allSatisfy{$0.typography.tabStops?.first?.location==80 && $0.typography.hyphenation==0.5})
    XCTAssertTrue(runs.filter{$0.location>=6}.allSatisfy{$0.typography.tabStops==nil && $0.typography.hyphenation==0})
    XCTAssertEqual(a.elements[0].text,old.elements[0].text)
    for range in [(1,1),(2,0),(-1,0),(999,0)] {
      let before=a
      XCTAssertThrowsError(try ArtworkCommands.apply("paragraph",to:&a,ids:[e.id],arguments:["location":range.0,"length":range.1,"typography":["leading":20.0]]))
      XCTAssertEqual(a,before)
    }
  }
  func testInvalidTabsUnknownPropertiesLockedTargetsAndBatchRollback() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    var p=Project(name:"Paragraphs");var o=try p.makeObject(recipeID:"artboard");let e=text()
    o.artwork = .init(elements:[e]);p.objects=[o];engine.project=p
    for raw:[String:Any] in [
      ["tabStops":[["location":-1,"alignment":"left"]]],
      ["tabStops":[["location":20,"alignment":"decimal","decimalSeparator":"x"]]],
      ["tabStops":[["location":20,"alignment":"left"],["location":20,"alignment":"right"]]],
      ["defaultTabInterval":-1],["fontName":"Georgia"],
    ] {
      XCTAssertThrowsError(try engine.call("form_edit_artwork",arguments:["command":"paragraph","object_id":o.id.uuidString,"element_ids":[e.id.uuidString],"typography":raw]))
      XCTAssertEqual(engine.project,p)
    }
    XCTAssertThrowsError(try engine.call("form_batch",arguments:["operations":[
      ["name":"form_edit_artwork","arguments":["command":"paragraph","object_id":o.id.uuidString,"element_ids":[e.id.uuidString],"typography":["leading":20.0]]],
      ["name":"form_edit_artwork","arguments":["command":"paragraph","object_id":o.id.uuidString,"element_ids":[e.id.uuidString],"typography":["tabStops":[["location":1,"alignment":"bad"]]]]],
    ]]))
    XCTAssertEqual(engine.project,p);XCTAssertTrue(engine.undoStack.isEmpty)
    p.objects[0].locked=true;engine.project=p
    XCTAssertThrowsError(try engine.call("form_edit_artwork",arguments:["command":"paragraph","object_id":o.id.uuidString,"element_ids":[e.id.uuidString],"typography":["leading":20.0]]))
    var t=Typography();t.tabStops=(0..<65).map{.init(location:Double($0*10))}
    XCTAssertThrowsError(try validateTypography(t))
  }
  func testStylesRetainIndependentParagraphTabsAndExplicitOverridesReset() throws {
    var p=Project(name:"Styles");var o=try p.makeObject(recipeID:"artboard");let e=text("First\trow\nSecond\trow")
    o.artwork = .init(elements:[e]);p.objects=[o]
    var type=e.typography!;type.tabStops=[.init(location:72)]
    let body=try TextStyleCommands.save(in:&p,name:"Body",typography:type,fontSize:12)
    let caption=try TextStyleCommands.save(in:&p,name:"Caption",typography:e.typography!,fontSize:8)
    try TextStyleCommands.apply(in:&p,objectID:o.id,ids:[e.id],styleID:body)
    try TextStyleCommands.apply(in:&p,objectID:o.id,ids:[e.id],styleID:caption,location:0,length:5)
    var art=p.objects[0].artwork!
    try ArtworkCommands.apply("paragraph",to:&art,ids:[e.id],arguments:["location":0,"length":5,"typography":["tabStops":[["location":84,"alignment":"left"]]]])
    try p.setArtwork(art,for:o.id)
    XCTAssertEqual(p.objects[0].artwork!.elements[0].textRuns![0].paragraphStyle?.overrides,["tabStops"])
    type.tabStops=[.init(location:96)]
    try TextStyleCommands.save(in:&p,id:body,name:"Body",typography:type,fontSize:12)
    XCTAssertEqual(p.objects[0].artwork!.elements[0].textRuns![0].typography.tabStops?.first?.location,84)
    try TextStyleCommands.apply(in:&p,objectID:o.id,ids:[e.id],styleID:body,mode:"reset")
    let run=p.objects[0].artwork!.elements[0].textRuns![0]
    XCTAssertEqual(run.fontSize,8);XCTAssertEqual(run.typography.tabStops?.first?.location,96)
    XCTAssertEqual(run.paragraphStyle?.overrides,[])
  }
  func testNativeMetadataPreservesPreciseTabsDefaultsDirectionAndHyphenation() async throws {
    try await MainActor.run {
      for custom in [false,true] {
        var e=text();e.typography!.hyphenation=0.3;e.typography!.direction="rtl"
        if custom {e.typography!.tabStops=[.init(location:72.123456789,alignment:"decimal",decimalSeparator:",")];e.typography!.defaultTabInterval=28.123456789}
        let original=e.typography!
        for _ in 0..<4 {
          let spans=TypographyEngine.spans(from:TypographyEngine.attributed(e),fallback:original)
          XCTAssertTrue(spans.allSatisfy{$0.typography==original})
          e.textRuns=spans
        }
      }
      var a=Artwork(elements:[text()])
      try ArtworkCommands.apply("paragraph",to:&a,ids:[a.elements[0].id],arguments:["typography":["tabStops":[],"defaultTabInterval":36]])
      try ArtworkCommands.apply("paragraph",to:&a,ids:[a.elements[0].id],arguments:["typography":["tabStops":NSNull(),"defaultTabInterval":NSNull()]])
      XCTAssertFalse(a.elements[0].typography!.usesCustomTabs)
    }
  }
  func testSchemaFourteenDetectsRichTabsHyphenationAndUnusedStyles() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let repo=try ProjectRepository(root:root)
    var p=Project(name:"Paragraphs");var o=try p.makeObject(recipeID:"artboard");var e=text()
    o.artwork = .init(elements:[e]);p.objects=[o];try repo.save(p)
    XCTAssertEqual(try repo.load(p.id).schemaVersion,13)
    var type=e.typography!;type.tabStops=[]
    e.textRuns=[.init(location:0,length:1,typography:type,fontSize:12,color:e.color)]
    p.objects[0].artwork!.elements=[e];try repo.save(p)
    XCTAssertEqual(try repo.load(p.id).schemaVersion,14)
    XCTAssertEqual(try repo.load(p.id).objects,p.objects)
    p.objects=[];type.tabStops=nil;type.hyphenation=1
    p.textStyles=[.init(name:"Hyphenated",typography:type)];XCTAssertEqual(p.minimumSchemaVersion,14)
    let legacy=try JSONDecoder.form.decode(Typography.self,from:Data("{}".utf8))
    XCTAssertNil(legacy.tabStops);XCTAssertNil(legacy.defaultTabInterval)
  }
  private let paragraph="Extraordinary photographic observations illuminate the relationship between objects and light."
  @MainActor private func reference(_ e:ArtworkElement)->(NSTextStorage,NSLayoutManager,NSTextContainer) {
    let storage=NSTextStorage(attributedString:TypographyEngine.attributed(e)),layout=NSLayoutManager()
    let box=NSTextContainer(size:.init(width:e.width*TypographyEngine.pointsPerMM,height:100000));box.lineFragmentPadding=0
    layout.addTextContainer(box);storage.addLayoutManager(layout);layout.ensureLayout(for:box)
    return(storage,layout,box)
  }
  func testHyphenationProducesRealAdditionalGlyphsAndMatchesNativeTextKitComposition() async throws {
    try await MainActor.run {
      var e=text(paragraph);e.width=130/TypographyEngine.pointsPerMM;e.height=80;e.fontSize=16
      e.typography!.fontName="Georgia";e.typography!.hyphenation=1
      let (storage,layout,box)=reference(e)
      XCTAssertGreaterThan(layout.numberOfGlyphs,storage.length)
      XCTAssertEqual(TypographyEngine.measured(e,points:true).height,layout.usedRect(for:box).height,accuracy:1e-6)
      var no=e;no.typography!.hyphenation=0
      XCTAssertLessThan(TypographyEngine.measured(e).height,TypographyEngine.measured(no).height)
      let before=e.text
      let outlined=try TypographyEngine.outlines(e)
      XCTAssertFalse(outlined.isEmpty);XCTAssertEqual(e.text,before)
      let svg=try SVGRenderer.document(.init(elements:[e]),width:100,height:100,assets:URL(fileURLWithPath:"/tmp"),outlineText:false)
      XCTAssertFalse(svg.contains("<text "));XCTAssertTrue(svg.contains("<path"))
    }
  }
  func testHyphenatedDrawAndOutlinesAgreeAndCacheRetainsPlacement() async throws {
    try await MainActor.run {
      var e=text(paragraph);e.width=46;e.height=80;e.fontSize=16
      e.typography!.fontName="Georgia";e.typography!.hyphenation=1
      let original=ArtworkRenderer.image(.init(background:"#FFFFFF",elements:[e],bleed:0),width:60,height:85,assets:URL(fileURLWithPath:"/tmp"),pixelsPerMM:4).representations[0] as! NSBitmapImageRep
      let paths=try TypographyEngine.outlines(e)
      let converted=try VectorGeometry.element(from:paths,color:e.color)
      let outlined=ArtworkRenderer.image(.init(background:"#FFFFFF",elements:[converted],bleed:0),width:60,height:85,assets:URL(fileURLWithPath:"/tmp"),pixelsPerMM:4).representations[0] as! NSBitmapImageRep
      var sum=0.0,count=0
      for y in 0..<original.pixelsHigh {for x in 0..<original.pixelsWide {
        let a=original.colorAt(x:x,y:y)!,b=outlined.colorAt(x:x,y:y)!
        if min(a.redComponent,b.redComponent)<0.95 {sum+=abs(a.redComponent-b.redComponent);count+=1}
      }}
      print("Hyphenated native/outline foreground error: \(sum/Double(count))")
      XCTAssertGreaterThan(count,1000);XCTAssertLessThan(sum/Double(count),0.13)
      let builds=TypographyEngine.diagnostics["paragraph_layout_builds"] as! Int
      e.x=50;_=TypographyEngine.measured(e)
      XCTAssertEqual(TypographyEngine.diagnostics["paragraph_layout_builds"] as! Int,builds)
      e.height=5;XCTAssertTrue(TypographyEngine.overflows(e))
      XCTAssertTrue(try TypographyEngine.outlines(e).isEmpty)
    }
  }
}

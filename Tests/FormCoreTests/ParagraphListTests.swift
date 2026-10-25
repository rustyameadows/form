import AppKit
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class ParagraphListTests:XCTestCase {
  private func text(_ value:String="Prepare materials\nInspect the finish\nAssemble carefully")->ArtworkElement {
    var e=ArtworkElement(kind:"text",x:0,y:0,width:80,height:60,text:value,color:"#24353D",fontSize:16)
    e.typography=Typography();e.typography!.fontName="Georgia";return e
  }
  func testListCommandsRetainRichSourceAndStableItemIdentityThroughNestingAndRemoval() throws {
    var e=text();e.textRuns=[.init(location:0,length:7,typography:e.typography!,fontSize:20,color:"#A55135")]
    var art=Artwork(elements:[e]);let source=art
    try ArtworkCommands.apply("list",to:&art,ids:[e.id],arguments:["marker":"decimal"])
    let items=try XCTUnwrap(art.elements[0].listItems);XCTAssertEqual(items.count,3)
    XCTAssertEqual(art.elements[0].text,e.text);XCTAssertEqual(art.elements[0].textRuns,e.textRuns)
    let second=items[1]
    try ArtworkCommands.apply("list",to:&art,ids:[e.id],arguments:["list_action":"indent","location":second.location,"length":2])
    XCTAssertEqual(art.elements[0].listItems![1].id,second.id);XCTAssertEqual(art.elements[0].listItems![1].level,1)
    try ArtworkCommands.apply("list",to:&art,ids:[e.id],arguments:["list_action":"remove","location":second.location,"length":2])
    XCTAssertEqual(art.elements[0].listItems?.count,2);XCTAssertEqual(art.elements[0].text,source.elements[0].text)
    XCTAssertThrowsError(try ArtworkCommands.apply("list",to:&art,ids:[e.id],arguments:["marker":"roman"]))
  }
  func testNumberingContinuesAcrossTextObjectsWithRestartAndNestedCounters() throws {
    let list=UUID();var first=text("First\nSecond"),second=text("Third\nNested\nFourth\nRestart\nNext")
    try ParagraphLists.edit(&first.listItems,text:first.text,marker:.decimal,listID:list)
    try ParagraphLists.edit(&second.listItems,text:second.text,marker:.decimal,listID:list)
    second.listItems![1].level=1;second.listItems![3].restart=7
    let art=Artwork(elements:[first,second]).resolvingLists
    XCTAssertEqual(art.elements[0].listItems!.map(\.resolvedNumber),[1,2])
    XCTAssertEqual(art.elements[1].listItems!.map(\.resolvedNumber),[3,1,4,7,8])
    XCTAssertEqual(Artwork(elements:[first,second]).renderDefinition.elements[1].listItems![0].restart,3)
    let selection=try Artwork(elements:[first,second]).exporting([second.id]).artwork
    XCTAssertEqual(selection.resolvingLists.elements[0].listItems![0].resolvedNumber,3)
    let encoded=try JSONEncoder.form.encode(art)
    XCTAssertFalse(String(decoding:encoded,as:UTF8.self).contains("resolvedNumber"))
    let before=try JSONEncoder.form.encode(art.renderDefinition)
    var changed=Artwork(elements:[first,second]);changed.elements[0].listItems![0].restart=9
    let after=try JSONEncoder.form.encode(changed.resolvingLists.renderDefinition)
    XCTAssertNotEqual(before,after,"Effective cross-frame numbers must invalidate encoded physical render keys.")
  }
  func testSchemaRoundTripAndAtomicMCPUndoPreserveOriginalWords() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let repo=try ProjectRepository(root:root),engine=OperationEngine(repository:repo)
    var p=Project(name:"List"),o=try p.makeObject(recipeID:"artboard");let e=text()
    o.artwork=Artwork(elements:[e]);p.objects=[o];engine.project=p
    _=try engine.call("form_edit_artwork",arguments:["object_id":o.id.uuidString,"command":"list","element_ids":[e.id.uuidString],"marker":"bullet"])
    let listed=engine.project!;XCTAssertEqual(listed.minimumSchemaVersion,23)
    try repo.save(listed);XCTAssertEqual(try repo.load(p.id).objects,listed.objects)
    XCTAssertThrowsError(try engine.call("form_batch",arguments:["operations":[
      ["name":"form_edit_artwork","arguments":["object_id":o.id.uuidString,"command":"list","element_ids":[e.id.uuidString],"list_action":"indent"]],
      ["name":"form_edit_artwork","arguments":["object_id":o.id.uuidString,"command":"list","element_ids":[e.id.uuidString],"level":7]]]]))
    XCTAssertEqual(engine.project,listed);engine.undo();XCTAssertEqual(engine.project,p)
  }
  func testSharedNativeMarkersHaveActualInkAndOutlinesOnCorrectLTRAndRTLSides() throws {
    for rtl in [false,true] {
      var e=text(rtl ? "افحص المواد\nابدأ التجميع":"Inspect materials\nBegin assembly")
      e.typography!.direction=rtl ? "rtl":"ltr"
      try ParagraphLists.edit(&e.listItems,text:e.text,marker:.decimal)
      let attributed=TypographyEngine.attributed(e,preservingSource:true)
      XCTAssertEqual(attributed.string,e.text);XCTAssertTrue(TypographyEngine.usesParagraphLayout(e))
      let storage=PublicationTextStorage();storage.setAttributedString(attributed)
      let layout=PublicationLayoutManager(),box=NSTextContainer(size:.init(width:e.width*TypographyEngine.pointsPerMM,height:100000));box.lineFragmentPadding=0
      storage.addLayoutManager(layout);layout.addTextContainer(box);layout.ensureLayout(for:box)
      let ink=PublicationLists.ink(layout:layout,glyphRange:layout.glyphRange(for:box));XCTAssertEqual(ink.count,2)
      XCTAssertEqual(PublicationLists.items(from:TextCase.source(attributed).text),e.listItems)
      let boundary=rtl ? e.width*TypographyEngine.pointsPerMM-24:24.0
      for marker in ink {
        if rtl {
          XCTAssertGreaterThan(marker.path.boundingBox.minX,boundary)
          let paragraph=(storage.string as NSString).paragraphRange(for:NSRange(location:marker.character,length:0))
          let glyphRange=layout.glyphRange(forCharacterRange:paragraph,actualCharacterRange:nil)
          var body=CGRect.null
          for index in glyphRange.location..<NSMaxRange(glyphRange) where !layout.propertyForGlyph(at:index).contains(.controlCharacter) {
            let char=layout.characterIndexForGlyph(at:index),font=layout.fontForGeneratedGlyph(index) ?? storage.attribute(.font,at:char,effectiveRange:nil) as! NSFont
            let position=layout.location(forGlyphAt:index),line=layout.lineFragmentRect(forGlyphAt:index,effectiveRange:nil)
            if let path=CTFontCreatePathForGlyph(font as CTFont,CGGlyph(layout.glyph(at:index)),nil) {
              body=body.union(path.boundingBox.applying(CGAffineTransform(a:1,b:0,c:0,d:-1,tx:line.minX+position.x,ty:line.minY+position.y)))
            }
          }
          XCTAssertGreaterThan(marker.path.boundingBox.minX,body.maxX,"RTL markers must sit beside the body rather than overprint it: \(body), \(marker.path.boundingBox)")
        }
        else {XCTAssertLessThan(marker.path.boundingBox.maxX,boundary)}
      }
      let outlines=try TypographyEngine.outlines(e);XCTAssertFalse(outlines.isEmpty)
      let svg=try SVGRenderer.document(.init(elements:[e]),width:100,height:80,assets:FileManager.default.temporaryDirectory,outlineText:false)
      XCTAssertFalse(svg.contains("<text "));XCTAssertTrue(svg.contains("<path"))
    }
  }
  func testCaseMappingsAndNativeInteroperabilityKeepGeneratedMarkersOutOfSource() throws {
    var e=text("straße\nI\u{301}");e.typography!.caseTreatment="uppercase";e.typography!.language="lt"
    try ParagraphLists.edit(&e.listItems,text:e.text,marker:.bullet)
    let native=TypographyEngine.attributed(e,preservingSource:true),source=TextCase.source(native).text
    XCTAssertEqual(native.string,e.text.uppercased(with:Locale(identifier:"lt")));XCTAssertEqual(source.string,e.text)
    XCTAssertEqual(PublicationLists.items(from:source),e.listItems)
    let style=source.attribute(.paragraphStyle,at:0,effectiveRange:nil) as! NSParagraphStyle
    XCTAssertEqual(style.textLists.count,1);XCTAssertEqual(style.headIndent,24)
    let spans=TypographyEngine.spans(from:source,fallback:e.typography!)
    XCTAssertTrue(spans.allSatisfy{$0.typography.leftIndent==0 && $0.typography.firstLineIndent==0})
    var art=Artwork(elements:[e]);try ArtworkCommands.apply("duplicate",to:&art,ids:[e.id])
    XCTAssertTrue(Set(art.elements[0].listItems!.map(\.id)).isDisjoint(with:Set(art.elements[1].listItems!.map(\.id))))
    XCTAssertNotEqual(art.elements[0].listItems!.first!.listID,art.elements[1].listItems!.first!.listID)
  }
}

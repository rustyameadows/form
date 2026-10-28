import AppKit
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class GlyphRenderingTests: XCTestCase {
  private func text(_ string: String = "QUILL") -> ArtworkElement {
    var e = ArtworkElement(kind:"text",x:5,y:5,width:150,height:40,text:string,color:"#243846",fontSize:48)
    var type = Typography();type.fontName="HoeflerText-Regular";type.kerningMode="metrics"
    e.typography=type;return e
  }
  private func q() throws -> FontGlyph {
    let font=NSFont(name:"HoeflerText-Regular",size:48)!
    let id=CTFontGetGlyphWithName(font as CTFont,"Q.alt" as CFString)
    XCTAssertGreaterThan(id,0)
    return try GlyphCatalog.glyph(fontName:font.fontName,id:Int(id))
  }
  private func glyphs(_ value: NSAttributedString) -> [CGGlyph] {
    let line=CTLineCreateWithAttributedString(value)
    return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run in
      var ids=[CGGlyph](repeating:0,count:CTRunGetGlyphCount(run));CTRunGetGlyphs(run,CFRange(),&ids);return ids
    }
  }
  func testActualAlternateDiscoveryAndRepertoirePaging() throws {
    let e=text(),choices=try GlyphCatalog.alternates(fontName:e.typography!.fontName,text:e.text,range:NSRange(location:0,length:1),typography:e.typography!)
    XCTAssertTrue(choices.contains{$0.glyph.glyphName=="Q.alt" && !$0.current})
    XCTAssertTrue(choices.contains{$0.current})
    let page=try GlyphCatalog.repertoire(fontName:"HoeflerText-Regular",offset:3,limit:7)
    XCTAssertEqual((page["glyphs"] as? [[String:Any]])?.count,7)
    let found=try GlyphCatalog.repertoire(fontName:"HoeflerText-Regular",query:"Q.alt")
    let exact=(found["glyphs"] as! [[String:Any]]).compactMap{$0["glyph"] as? [String:Any]}.first{$0["glyphName"] as? String == "Q.alt"}!
    XCTAssertEqual(exact["glyphName"] as? String,"Q.alt")
    XCTAssertEqual(try GlyphCatalog.repertoire(fontName:"HoeflerText-Regular",query:"gid:\(q().glyphID)")["total"] as? Int,1)
    XCTAssertEqual(try GlyphCatalog.repertoire(fontName:"HoeflerText-Regular",query:"U+0051")["total"] as? Int,1)
    XCTAssertThrowsError(try GlyphCatalog.repertoire(fontName:"Missing FORM face"))
    XCTAssertThrowsError(try GlyphCatalog.repertoire(fontName:"HoeflerText-Regular",limit:129))
    XCTAssertThrowsError(try GlyphCatalog.alternates(fontName:"HoeflerText-Regular",text:"😀",range:NSRange(location:1,length:1)))
    XCTAssertThrowsError(try GlyphEngine.applying(nil,range:NSRange(location:1,length:1),to:TypographyEngine.sourceAttributed(text("😀"))))
    XCTAssertThrowsError(try GlyphCatalog.alternates(fontName:"HoeflerText-Regular",text:"Q\nQ",range:NSRange(location:0,length:3)))
  }
  func testAlternatesDoNotStealALigatureFromOutsideTheSelectedSource() throws {
    let e=text("fi")
    let ligature=glyphs(TypographyEngine.attributed(e)).first!
    let choices=try GlyphCatalog.alternates(fontName:e.typography!.fontName,text:e.text,range:NSRange(location:0,length:1),typography:e.typography!)
    XCTAssertFalse(choices.contains{$0.glyph.glyphID==ligature})
    let ffi=try GlyphCatalog.alternates(fontName:"Baskerville",text:"ffi",range:NSRange(location:0,length:3))
    XCTAssertTrue(ffi.contains{$0.glyph.glyphName=="f_f_i"})
  }
  func testCoreTextAndTextKitRenderTheChosenGlyphWhileRetainingOriginalLetters() throws {
    var e=text(),plain=glyphs(TypographyEngine.attributed(e));let glyph=try q()
    e.glyphOverrides=[.init(location:0,sourceText:"Q",glyph:glyph)]
    let native=TypographyEngine.attributed(e,preservingSource:true),production=TypographyEngine.attributed(e)
    XCTAssertEqual(e.text,"QUILL");XCTAssertEqual(production.string,e.text)
    plain[0]=CGGlyph(glyph.glyphID);XCTAssertEqual(glyphs(native),plain);XCTAssertEqual(glyphs(production),plain)
    let storage=NSTextStorage(attributedString:native),layout=NSLayoutManager(),container=NSTextContainer(size:NSSize(width:1000,height:1000))
    storage.addLayoutManager(layout);layout.addTextContainer(container);layout.ensureLayout(for:container)
    XCTAssertEqual(layout.glyph(at:0),NSGlyph(glyph.glyphID))
    XCTAssertNil(production.attribute(GlyphEngine.overrideKey,at:0,effectiveRange:nil))
    XCTAssertNil(production.attribute(TextCase.sourceKey,at:0,effectiveRange:nil))
    XCTAssertNotNil(production.attribute(.glyphInfo,at:0,effectiveRange:nil))
    let again=GlyphEngine.normalizedNative(TextCase.source(native).text)
    XCTAssertTrue(again.isEqual(to:native))
    GlyphEngine.invalidate()
    XCTAssertTrue(GlyphEngine.nativeEqual(GlyphEngine.normalizedNative(TextCase.source(native).text),native))
    XCTAssertNoThrow(try NSKeyedArchiver.archivedData(withRootObject:native,requiringSecureCoding:true))
  }
  func testCaseExpansionAndRichSourceMetadataSurviveCanonicalNativeRoundTrips() throws {
    var e=text("ßQ");e.typography!.caseTreatment="uppercase"
    e.glyphOverrides=[.init(location:1,sourceText:"Q",glyph:try q())]
    let native=TypographyEngine.attributed(e,preservingSource:true)
    XCTAssertEqual(native.string,"SSQ")
    let source=TextCase.source(native).text
    XCTAssertEqual(source.string,"ßQ");XCTAssertEqual(GlyphEngine.overrides(from:source),e.glyphOverrides)
    XCTAssertEqual(glyphs(native).last,CGGlyph(try q().glyphID))
    XCTAssertTrue(GlyphEngine.normalizedNative(source).isEqual(to:native))
    let clear=try GlyphEngine.applying(nil,range:NSRange(location:1,length:1),to:source)
    e.glyphOverrides=nil
    XCTAssertTrue(clear.isEqual(to:TypographyEngine.attributed(e,preservingSource:true)))
  }
  func testFontMismatchAndMixedSourcePaintRejectProductionWithoutLosingIntent() throws {
    var e=text("QQ");let choice=GlyphOverride(location:0,sourceText:"QQ",glyph:try q())
    e.glyphOverrides=[choice]
    e.textRuns=[.init(location:1,length:1,typography:e.typography!,fontSize:48,color:"#AA3300")]
    XCTAssertThrowsError(try GlyphEngine.validateSelection(e,choice:choice))
    e.textRuns=nil;e.typography!.fontName="Baskerville"
    XCTAssertFalse(GlyphEngine.issues(e).isEmpty)
    XCTAssertThrowsError(try GlyphEngine.validateOutput(e))
    XCTAssertThrowsError(try TypographyEngine.outlines(e))
    let assets=FileManager.default.temporaryDirectory
    XCTAssertThrowsError(try ArtworkRenderer.validateAppearanceOutput(Artwork(elements:[e]),assets:assets,pixelsPerMM:3))
    e.hidden=true
    XCTAssertNoThrow(try ArtworkRenderer.validateAppearanceOutput(Artwork(elements:[e]),assets:assets,pixelsPerMM:3))
    e.hidden=nil;e.typography!.fontName="HoeflerText-Regular"
    XCTAssertTrue(GlyphEngine.issues(e).isEmpty)
  }
  func testNamedResolutionChecksNamesAndUnnamedResolutionRequiresTheExactFontVersion() throws {
    let font=NSFont(name:"HoeflerText-Regular",size:48)!,original=try q()
    var changed=original;changed.fontSignature=String(repeating:"a",count:64);changed.glyphID=2
    XCTAssertEqual(try GlyphCatalog.resolve(changed,font:font),CGGlyph(original.glyphID))
    changed=original;changed.glyphID=2
    XCTAssertThrowsError(try GlyphCatalog.resolve(changed,font:font))
    changed=original;changed.glyphName=nil;changed.fontSignature=String(repeating:"b",count:64)
    XCTAssertThrowsError(try GlyphCatalog.resolve(changed,font:font))
    let signature=try GlyphCatalog.signature(font.fontName)
    FontCatalog.invalidate();XCTAssertEqual(try GlyphCatalog.signature(font.fontName),signature)
  }
  func testGlyphChangesInvalidateBothLayoutsAndOutlinesKeepTheEditableSource() throws {
    var e=text("Q")
    for hyphenation in [0.0,0.8] {
      e.typography!.hyphenation=hyphenation;e.glyphOverrides=nil
      let before=SVGRenderer.data(try TypographyEngine.outlines(e))
      e.glyphOverrides=[.init(location:0,sourceText:"Q",glyph:try q())]
      let after=SVGRenderer.data(try TypographyEngine.outlines(e))
      XCTAssertNotEqual(before,after)
      let art=Artwork(elements:[e]);let result=try ArtworkOutlines.convert(art,ids:[e.id],mode:"text")
      XCTAssertEqual(result.artwork.elements.first?.text,"Q")
      XCTAssertEqual(result.artwork.elements.first?.glyphOverrides,e.glyphOverrides)
      XCTAssertEqual(result.artwork.elements.first?.hidden,true)
      XCTAssertTrue(result.created.allSatisfy{$0.kind=="path"})
      let svg=try SVGRenderer.document(art,width:160,height:50,assets:FileManager.default.temporaryDirectory,outlineText:false)
      XCTAssertFalse(svg.contains("<text"));XCTAssertTrue(svg.contains("<path"))
    }
  }
  func testPointSwashesKeepTheirFullInkAtLeftCenterAndRightAlignment() throws {
    var area=text("Q");area.width=200;area.height=60
    area.glyphOverrides=[.init(location:0,sourceText:"Q",glyph:try q())]
    let expected=try TypographyEngine.outlines(area).boundingBoxOfPath
    for alignment in ["left","center","right"] {
      var point=area;point.typography!.frameMode="point";point.typography!.alignment=alignment;point.width=1
      let measured=TypographyEngine.measured(point)
      point.width=measured.width+0.5
      point.height=max(point.fontSize/TypographyEngine.pointsPerMM*1.4,measured.height+0.5)
      let ink=try TypographyEngine.outlines(point).boundingBoxOfPath
      XCTAssertEqual(ink.width,expected.width,accuracy:1e-5)
      XCTAssertGreaterThanOrEqual(ink.minX,-1e-5)
      XCTAssertLessThanOrEqual(ink.maxX,point.width)
      XCTAssertFalse(TypographyEngine.overflows(point))
      XCTAssertNotNil(TypographyEngine.pointGlyphContainerWidth(point))
    }
  }
  func testExplicitGlyphsKeepVariableAxesAndRespondToWeightChanges() throws {
    var e=text("Q");e.typography!.fontName="Skia";e.typography!.variations=[2003265652:0.6]
    let font=TypographyEngine.font(e.typography!,size:e.fontSize)
    let id=CTFontGetGlyphWithName(font as CTFont,"q.superior" as CFString)
    XCTAssertGreaterThan(id,0)
    let selected=try GlyphCatalog.glyph(fontName:font.fontName,id:Int(id))
    e.glyphOverrides=[.init(location:0,sourceText:"Q",glyph:selected)]
    let thin=SVGRenderer.data(try TypographyEngine.outlines(e))
    e.typography!.variations=[2003265652:2.5]
    XCTAssertEqual(glyphs(TypographyEngine.attributed(e)).first,id)
    let heavy=SVGRenderer.data(try TypographyEngine.outlines(e))
    XCTAssertNotEqual(thin,heavy)
    let recovered=TypographyEngine.spans(from:TextCase.source(TypographyEngine.attributed(e,preservingSource:true)).text,fallback:e.typography!)[0]
    XCTAssertEqual(recovered.typography.variations,e.typography!.variations)
  }
  func testBitmapGlyphRemainsNativeButExplicitVectorConversionRejectsIt() throws {
    var e=text("😀");e.typography!.fontName="AppleColorEmoji"
    let original=TypographyEngine.attributed(e),id=glyphs(original).first!
    let font=(CTRunGetAttributes((CTLineGetGlyphRuns(CTLineCreateWithAttributedString(original)) as! [CTRun])[0]) as NSDictionary)[kCTFontAttributeName] as! NSFont
    let selected=try GlyphCatalog.glyph(fontName:font.fontName,id:Int(id))
    e.glyphOverrides=[.init(location:0,sourceText:e.text,glyph:selected)]
    let unicode=try GlyphCatalog.repertoire(fontName:font.fontName,query:"U+1F600")
    XCTAssertEqual((((unicode["glyphs"] as! [[String:Any]]).first?["glyph"] as? [String:Any])?["glyphID"] as? Int),Int(id))
    XCTAssertEqual(glyphs(TypographyEngine.attributed(e)),[id])
    XCTAssertNoThrow(try GlyphEngine.validateOutput(e))
    XCTAssertThrowsError(try GlyphEngine.validateOutput(e,outlines:true))
    XCTAssertThrowsError(try TypographyEngine.outlines(e))
    XCTAssertNil(TypographyEngine.attributed(e).attribute(GlyphEngine.renderKey,at:0,effectiveRange:nil))
  }
  func testAttributedPasteDuplicatesChoiceIDsSafelyAndPartialSourceEditsClearBrokenChoices() throws {
    var e=text("Q");e.glyphOverrides=[.init(location:0,sourceText:"Q",glyph:try q())]
    let single=TypographyEngine.attributed(e,preservingSource:true),pasted=NSMutableAttributedString(attributedString:single)
    pasted.append(single)
    let choices=GlyphEngine.overrides(from:TextCase.source(pasted).text)
    XCTAssertEqual(choices.map(\.location),[0,1]);XCTAssertEqual(Set(choices.map(\.id)).count,2)
    let edited=NSMutableAttributedString(attributedString:single)
    edited.replaceCharacters(in:NSRange(location:0,length:1),with:"X")
    let normalized=GlyphEngine.normalizedNative(TextCase.source(edited).text)
    XCTAssertTrue(GlyphEngine.overrides(from:TextCase.source(normalized).text).isEmpty)
    XCTAssertNil(normalized.attribute(.glyphInfo,at:0,effectiveRange:nil))
  }
}

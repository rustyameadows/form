import AppKit
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class CharacterPositionGraphicsTests:XCTestCase {
  private func element(_ words:String="12abQ",face:String=".AppleSystemUIFont",position:CharacterPosition? = .superscript)->ArtworkElement {
    var e=ArtworkElement(kind:"text",x:0,y:0,width:180,height:60,text:words,fontSize:36),t=Typography();t.fontName=face;t.baseline=3;t.characterPosition=position;t.kerningMode="metrics";e.typography=t;return e
  }
  private func coordinate(_ font:NSFont)->Double? {(CTFontCopyVariation(font as CTFont) as? [NSNumber:NSNumber])?[NSNumber(value:OpticalSizing.axisID)]?.doubleValue}
  private func first(_ e:ArtworkElement)throws->(NSAttributedString,CharacterTypography.Resolution,NSFont) {
    let a=TypographyEngine.attributed(e,preservingSource:true);return(a,try XCTUnwrap(CharacterTypography.records(in:a).first?.1),try XCTUnwrap(a.attribute(.font,at:0,effectiveRange:nil) as? NSFont))
  }
  func testNilPositionUsesLegacyFontAndAttributedValuesExactly()throws {
    var e=element(position:nil);e.typography!.features=[10:1];let before=e
    let a=TypographyEngine.attributed(e,preservingSource:true),raw=TypographyEngine.sourceAttributed(e)
    XCTAssertTrue(CharacterTypography.records(in:a).isEmpty);XCTAssertTrue(CharacterTypography.authored(a) === a)
    XCTAssertEqual(a.attribute(.font,at:0,effectiveRange:nil) as? NSFont,raw.attribute(.font,at:0,effectiveRange:nil) as? NSFont)
    XCTAssertEqual(TypographyEngine.spans(from:a,fallback:e.typography!).first?.typography,e.typography);XCTAssertEqual(e,before)
  }
  func testRealCompleteFontFormsAndWholeSpanFallbackNeverLeaveQAtNormalSize()throws {
    let supported=try first(element("12ab"));XCTAssertEqual(supported.1.method,"font-authored");XCTAssertEqual(supported.2.pointSize,36);XCTAssertEqual(supported.1.offsetPoints,0)
    let mixed=try first(element());XCTAssertEqual(mixed.1.method,"geometric-fallback-v1");XCTAssertEqual(mixed.2.pointSize,23.4,accuracy:1e-10);XCTAssertEqual(mixed.1.displayBaseline,15.6,accuracy:1e-10)
    for i in 0..<mixed.0.length {XCTAssertEqual((mixed.0.attribute(.font,at:i,effectiveRange:nil) as? NSFont)?.pointSize ?? 0,23.4,accuracy:1e-10)}
    let unsupported=try first(element(face:"Georgia"));XCTAssertEqual(unsupported.1.method,"geometric-fallback-v1")
  }
  func testNativeRoundtripsRestoreNominalSizeManualBaselineDormantFeaturesAndAxes()throws {
    var e=element(face:"Georgia");e.typography!.features=[10:2,37:1];e.typography!.variations=[OpticalSizing.axisID:72];e.typography!.tracking=1.25;let before=e
    for _ in 0..<4 {
      let native=TypographyEngine.attributed(e,preservingSource:true),runs=TypographyEngine.spans(from:native,fallback:e.typography!)
      XCTAssertTrue(runs.allSatisfy{$0.fontSize==36 && $0.typography==before.typography!})
      e.textRuns=runs
    }
    XCTAssertEqual(e.text,before.text);XCTAssertEqual(e.typography,before.typography)
    let attrs=try first(before).0.attributes(at:0,effectiveRange:nil),changed=NSMutableAttributedString(string:before.text,attributes:attrs)
    changed.addAttribute(.baselineOffset,value:16.6,range:NSRange(location:0,length:changed.length))
    let source=TypographyEngine.spans(from:changed,fallback:before.typography!);XCTAssertEqual(source[0].typography.baseline,4,accuracy:1e-10);XCTAssertEqual(source[0].fontSize,36)
  }
  func testOpticalContextUsesRealDerivedPointsIndependentOfMillimetersAndPreviewScale()throws {
    var e=element();e.typography!.opticalSizing = .init(.automatic);e.typography!.variations=[OpticalSizing.axisID:72]
    let point=try first(e),mm=TypographyEngine.attributed(e,millimeters:true,preservingSource:true),mmFont=try XCTUnwrap(mm.attribute(.font,at:0,effectiveRange:nil) as? NSFont)
    XCTAssertEqual(coordinate(point.2),23.4);XCTAssertEqual(coordinate(mmFont),23.4)
    let p=CTLineGetTypographicBounds(CTLineCreateWithAttributedString(point.0),nil,nil,nil),m=CTLineGetTypographicBounds(CTLineCreateWithAttributedString(mm),nil,nil,nil)
    XCTAssertEqual(m*TypographyEngine.pointsPerMM,p,accuracy:1e-8)
    let recovered=TypographyEngine.spans(from:mm,fallback:e.typography!);XCTAssertEqual(recovered[0].fontSize,36);XCTAssertEqual(recovered[0].typography.baseline,3)
    e.typography!.opticalSizing = .init(.explicit,points:72);XCTAssertEqual(coordinate(try first(e).2),72)
    e.typography!.opticalSizing = .init(.none);XCTAssertNil(coordinate(try first(e).2))
    e.typography!.opticalSizing = .init(.automatic);e.text="12ab";XCTAssertEqual(coordinate(try first(e).2),36)
  }
  func testExactNondefaultGlyphKeepsItsIdentityThroughPositionAndNativeSourceRecovery()throws {
    var e=element("Q",face:"Georgia");let f=NSFont(name:"Georgia",size:36)!;let id=Int(CTFontGetGlyphWithName(f as CTFont,"ampersand" as CFString));XCTAssertGreaterThan(id,0)
    let glyph=try GlyphCatalog.glyph(fontName:"Georgia",id:id),choice=GlyphOverride(location:0,sourceText:"Q",glyph:glyph);e.glyphOverrides=[choice]
    try GlyphEngine.validateOutput(e,outlines:true)
    let native=TypographyEngine.attributed(e,preservingSource:true);XCTAssertEqual(GlyphEngine.overrides(from:native),[choice]);XCTAssertEqual(try first(e).1.method,"geometric-fallback-v1")
    let line=CTLineCreateWithAttributedString(native),run=(CTLineGetGlyphRuns(line) as! [CTRun])[0];var actual:CGGlyph=0;CTRunGetGlyphs(run,CFRange(location:0,length:1),&actual);XCTAssertEqual(Int(actual),id)
    let source=TypographyEngine.spans(from:TextCase.source(native).text,fallback:e.typography!);XCTAssertEqual(source[0].fontSize,36);XCTAssertEqual(source[0].typography.baseline,3)
    XCTAssertEqual(e.glyphOverrides,[choice])
  }
  func testCoverageWorkLimitsAndComplexTextKeepCompleteOriginalSource()throws {
    for words in [String(repeating:"12ab",count:1100),"a"+String(repeating:"\u{301}",count:200),"مرحبا क्ष 👩🏽‍🚀 e\u{301}"] {
      let e=element(words),result=try first(e);XCTAssertEqual(result.1.method,"geometric-fallback-v1");XCTAssertEqual(result.0.string,words)
      XCTAssertEqual(TypographyEngine.spans(from:result.0,fallback:e.typography!).first?.fontSize,36)
    }
    XCTAssertEqual(CharacterTypography.diagnostics["coverage_cache_limit"] as? Int,512)
  }
  func testFirstWordPositionDoesNotShrinkOrRaiseTheGeneratedListMarker()throws {
    var e=element("First normal",position:nil);e.listItems=[.init(location:0,marker:.decimal,restart:1)];let base=e
    var type=e.typography!;type.characterPosition = .superscript;e.textRuns=[.init(location:0,length:5,typography:type,fontSize:36,color:e.color)]
    func marker(_ value:ArtworkElement,preservingSource:Bool=true)throws->(CGRect,Double) {
      let text=TypographyEngine.attributed(value,preservingSource:preservingSource),storage=NSTextStorage(attributedString:text),layout=PublicationLayoutManager(),container=NSTextContainer(size:.init(width:500,height:500));defer{withExtendedLifetime(storage){}}
      container.lineFragmentPadding=0;layout.addTextContainer(container);storage.addLayoutManager(layout);layout.ensureLayout(for:container)
      let bodyBaseline=layout.location(forGlyphAt:layout.glyphIndexForCharacter(at:6)).y
      return(try XCTUnwrap(PublicationLists.ink(layout:layout,glyphRange:layout.glyphRange(for:container)).first?.path.boundingBoxOfPath),bodyBaseline)
    }
    let expected=try marker(base),actual=try marker(e),physical=try marker(e,preservingSource:false)
    // Native auto line metrics can change fractionally; the marker must retain
    // nominal size and its baseline relative to the actual unpositioned body.
    XCTAssertEqual(actual.0.minY-actual.1,expected.0.minY-expected.1,accuracy:1e-8);XCTAssertEqual(actual.0.width,expected.0.width,accuracy:1e-8);XCTAssertEqual(actual.0.height,expected.0.height,accuracy:1e-8);XCTAssertEqual(actual.0,physical.0)
  }
  func testComplexScriptFallbackUsesActualGeneratedFacesAfterGlyphInsertionInFramesAndStories()throws {
    let e=element("مرحبا क्ष e\u{301}",position:.subscript),before=e
    let a=TypographyEngine.attributed(e),storage=NSTextStorage(attributedString:a),layout=PublicationLayoutManager(),container=NSTextContainer(size:.init(width:180*TypographyEngine.pointsPerMM,height:1000))
    defer{withExtendedLifetime(storage){}}
    container.lineFragmentPadding=0;layout.addTextContainer(container);storage.addLayoutManager(layout);layout.ensureLayout(for:container)
    let arabicGlyph=(0..<layout.numberOfGlyphs).first{layout.characterIndexForGlyph(at:$0)==4}!
    XCTAssertTrue(layout.fontForGeneratedGlyph(arabicGlyph)?.fontName.contains("Arabic")==true)
    XCTAssertFalse(try TypographyEngine.outlinePaintRuns(e).isEmpty);XCTAssertEqual(e,before)
    var p=Project(name:"Complex linked source"),first=try p.makeObject(recipeID:"artboard",parameters:["width":210,"depth":150]),second=try p.makeObject(recipeID:"artboard",parameters:["width":210,"depth":150]),capacity=e
    capacity.id=UUID();capacity.text="";capacity.textRuns=nil;first.artwork = .init(elements:[e]);second.artwork = .init(elements:[capacity]);p.objects=[first,second]
    _ = try PublicationCommands.createStory(in:&p,frames:[.init(objectID:first.id,elementID:e.id),.init(objectID:second.id,elementID:capacity.id)])
    let original=p,art=try XCTUnwrap(p.surfaceArtwork(p.objects[0])),frame=try XCTUnwrap(art.elements.first)
    XCTAssertFalse(try PublicationStoryLayout.outlines(frame).isEmpty);XCTAssertEqual(p,original)
  }

  func testConflictingGeneratedFontIdentityRejectsOutlinesRatherThanChoosingAFace()throws {
    let storage=NSTextStorage(string:"a",attributes:[.font:NSFont.systemFont(ofSize:36)]),layout=PublicationLayoutManager(),container=NSTextContainer(size:.init(width:200,height:100));defer{withExtendedLifetime(storage){}}
    layout.addTextContainer(container);storage.addLayoutManager(layout);layout.ensureLayout(for:container)
    var glyph=CGGlyph(truncatingIfNeeded:layout.glyph(at:0)),property=layout.propertyForGlyph(at:0),character=0
    let fonts=[NSFont.systemFont(ofSize:36),try XCTUnwrap(NSFont(name:"Georgia",size:36))]
    for font in fonts {layout.setGlyphs(&glyph,properties:&property,characterIndexes:&character,font:font,forGlyphRange:.init(location:0,length:1))}
    XCTAssertNil(layout.fontForGeneratedGlyph(0));XCTAssertThrowsError(try layout.outlineFont(forGlyphAt:0,authored:fonts[0]));XCTAssertEqual(storage.string,"a")
  }

  func testOneCompleteSourceClusterCanRetainDifferentFontsForDistinctGeneratedGlyphs()throws {
    let first=NSFont.systemFont(ofSize:36),second=try XCTUnwrap(NSFont(name:"Georgia",size:36)),storage=NSTextStorage(string:"a\u{301}",attributes:[.font:first]),layout=PublicationLayoutManager(),container=NSTextContainer(size:.init(width:200,height:100));defer{withExtendedLifetime(storage){}}
    layout.addTextContainer(container);storage.addLayoutManager(layout);layout.ensureLayout(for:container)
    XCTAssertGreaterThanOrEqual(layout.numberOfGlyphs,2)
    var a=CTFontGetGlyphWithName(first as CTFont,"a" as CFString),accent=CTFontGetGlyphWithName(second as CTFont,"acute" as CFString),property=NSLayoutManager.GlyphProperty(),character=0
    XCTAssertNotEqual(a,accent);XCTAssertGreaterThan(accent,0)
    layout.setGlyphs(&a,properties:&property,characterIndexes:&character,font:first,forGlyphRange:.init(location:0,length:1))
    layout.setGlyphs(&accent,properties:&property,characterIndexes:&character,font:second,forGlyphRange:.init(location:1,length:1))
    XCTAssertEqual(layout.characterIndexForGlyph(at:0),0);XCTAssertEqual(layout.characterIndexForGlyph(at:1),0)
    XCTAssertEqual(try layout.outlineFont(forGlyphAt:0,authored:first),first);XCTAssertEqual(try layout.outlineFont(forGlyphAt:1,authored:first),second);XCTAssertEqual(storage.string,"a\u{301}")
  }

  func testRepeatedPositionPreviewUsesBoundedCoverageCacheWithoutRewritingSource()throws {
    CharacterTypography.invalidate();let fixtures=(0..<240).map{element("Flight \($0) / Original & Q",position:$0.isMultiple(of:2) ? .superscript:.subscript)},before=fixtures
    var times:[Double]=[];let initial=CharacterTypography.diagnostics["coverage_cluster_checks"] as! Int
    for _ in 0..<3 {let start=ProcessInfo.processInfo.systemUptime;for e in fixtures {_=TypographyEngine.attributed(e,preservingSource:true)};times.append((ProcessInfo.processInfo.systemUptime-start)*1000)}
    let diagnostics=CharacterTypography.diagnostics;XCTAssertEqual(fixtures,before);XCTAssertGreaterThanOrEqual(diagnostics["coverage_hits"] as! Int,480);XCTAssertLessThanOrEqual((diagnostics["coverage_cluster_checks"] as! Int)-initial,240*256)
    if let path=ProcessInfo.processInfo.environment["FORM_CHARACTER_POSITION_PROOF_DIR"] {
      let root=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
      try JSONSerialization.data(withJSONObject:["text_sources":240,"passes_ms":times,"coverage":diagnostics,"no_source_mutation":true],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("Performance.json"))
    }
  }

}

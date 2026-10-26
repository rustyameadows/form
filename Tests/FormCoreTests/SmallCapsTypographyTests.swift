import AppKit
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class SmallCapsTypographyTests:XCTestCase {
  private func element(_ face:String="Baskerville",words:String="orbital")->ArtworkElement {
    var e=ArtworkElement(kind:"text",x:0,y:0,width:180,height:50,text:words,fontSize:36),type=Typography();type.fontName=face;type.features=[37:1];e.typography=type;return e
  }
  private func glyphs(_ a:NSAttributedString)->[Int] {
    (CTLineGetGlyphRuns(CTLineCreateWithAttributedString(a)) as! [CTRun]).flatMap{run in var ids=[CGGlyph](repeating:0,count:CTRunGetGlyphCount(run));CTRunGetGlyphs(run,CFRange(),&ids);return ids.map(Int.init)}
  }
  func testSupportedFontUsesAuthoredFormsWithoutChangingWordsOrNominalSize()throws {
    let e=element(),a=TypographyEngine.attributed(e,preservingSource:true),reports=SmallCapsTypography.reports(in:a);var plain=e;plain.typography!.features=[:]
    XCTAssertTrue(reports.contains{["supported","partial"].contains($0.status)});XCTAssertNotEqual(glyphs(a),glyphs(TypographyEngine.attributed(plain,preservingSource:true)));XCTAssertEqual(a.string,e.text);XCTAssertEqual((a.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.pointSize,36)
    XCTAssertNil(e.typography?.characterPosition)
  }
  func testUnsupportedFontDoesNotInventUppercaseOrShrinkSourceAndReportsCoverage()throws {
    let e=element("Georgia"),a=TypographyEngine.attributed(e,preservingSource:true);var plain=e;plain.typography!.features=[:]
    XCTAssertTrue(SmallCapsTypography.reports(in:a).contains{$0.status=="unavailable"});XCTAssertEqual(glyphs(a),glyphs(TypographyEngine.attributed(plain,preservingSource:true)));XCTAssertEqual(a.string,"orbital");XCTAssertEqual((a.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.pointSize,36)
  }
  func testCaseExpansionAndExactGlyphRemainSourceAuthoritative()throws {
    var e=element(".AppleSystemUIFont",words:"ßi");e.typography!.caseTreatment="uppercase"
    let display=TypographyEngine.attributed(e,preservingSource:true);XCTAssertEqual(display.string,"SSI");XCTAssertEqual(TextCase.source(display).text.string,e.text);XCTAssertTrue(SmallCapsTypography.reports(in:display).allSatisfy{$0.status=="not_applicable"})
    e=element("Georgia",words:"i");let font=NSFont(name:"Georgia",size:36)!,id=Int(CTFontGetGlyphWithName(font as CTFont,"ampersand" as CFString)),choice=GlyphOverride(location:0,sourceText:"i",glyph:try GlyphCatalog.glyph(fontName:"Georgia",id:id));e.glyphOverrides=[choice]
    let chosen=TypographyEngine.attributed(e,preservingSource:true);XCTAssertEqual(GlyphEngine.overrides(from:chosen),[choice]);XCTAssertTrue(SmallCapsTypography.reports(in:chosen).contains{$0.status=="exact_glyph"});XCTAssertEqual(glyphs(chosen),[id])
  }
  func testLiveSVGRequestUsesActualGlyphOutlinesAndPreservesEditableSource()throws {
    let e=element(),art=Artwork(elements:[e]),before=try JSONEncoder.form.encode(art)
    let svg=try SVGRenderer.document(art,width:180,height:70,assets:FileManager.default.temporaryDirectory,outlineText:false)
    XCTAssertFalse(svg.contains("<text"));XCTAssertTrue(svg.contains("<path"));XCTAssertEqual(try JSONEncoder.form.encode(art),before)
  }
}

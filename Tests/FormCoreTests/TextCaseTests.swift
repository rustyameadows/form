import AppKit
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

final class TextCaseTests:XCTestCase {
  private func element(_ text:String)->ArtworkElement {
    var e=ArtworkElement(kind:"text",x:0,y:0,width:160,height:90,text:text,color:"#243846",fontSize:24)
    var type=Typography();type.fontName="Georgia";type.kerningMode="metrics";e.typography=type;return e
  }
  func testPerCharacterCasePreservesSourceAndMixedFontColorAfterExpansion() async throws {
    await MainActor.run {
      var e=element("Straße / İSTANBUL / NASA")
      var upper=e.typography!;upper.caseTreatment="uppercase"
      var lower=e.typography!;lower.caseTreatment="lowercase"
      e.textRuns=[.init(location:0,length:6,typography:upper,fontSize:28,color:"#CC4400"),
        .init(location:9,length:8,typography:lower,fontSize:16,color:"#3344AA")]
      let display=TypographyEngine.attributed(e,preservingSource:true),recovered=TextCase.source(display)
      XCTAssertEqual(display.string,"STRASSE / i\u{307}stanbul / NASA")
      XCTAssertEqual(TypographyEngine.caseTreatments(in:display),["uppercase","lowercase","original"])
      XCTAssertEqual(recovered.text.string,e.text)
      let runs=TypographyEngine.spans(from:recovered.text,fallback:e.typography!)
      XCTAssertEqual(runs.first!.fontSize,28)
      XCTAssertEqual(runs.first!.color,"#CC4400")
      XCTAssertEqual(runs.last!.typography.caseTreatment,"original")
      XCTAssertTrue(TypographyEngine.displayingCase(recovered.text).isEqual(to:display))
      for _ in 0..<5 { XCTAssertEqual(TextCase.source(TypographyEngine.displayingCase(recovered.text)).text.string,e.text) }
    }
  }
  func testSourceDisplayRangesAndFormattingAnExpandedLetter() async throws {
    await MainActor.run {
      var e=element("aß😀z");e.typography!.caseTreatment="uppercase"
      let display=TypographyEngine.attributed(e,preservingSource:true),mapping=TextCase.source(display)
      XCTAssertEqual(display.string,"ASS😀Z")
      XCTAssertEqual(mapping.displayRange(NSRange(location:1,length:1)),NSRange(location:1,length:2))
      XCTAssertEqual(mapping.sourceRange(NSRange(location:2,length:1)),NSRange(location:1,length:1))
      XCTAssertEqual(mapping.sourceRange(NSRange(location:2,length:0)),NSRange(location:2,length:0))
      XCTAssertEqual(mapping.displayRange(NSRange(location:2,length:2)),NSRange(location:3,length:2))
      XCTAssertEqual(TextCase.expandedDisplayRange(NSRange(location:2,length:1),in:display),NSRange(location:1,length:2))
      XCTAssertEqual(mapping.sourceRange(NSRange(location:5,length:1)),NSRange(location:4,length:1))
    }
  }
  func testCaseContextAcrossRichRunsAndCombiningSupplementaryLetters() async throws {
    await MainActor.run {
      var e=element("ΟΣ ΑΣ Ι İ E\u{301} 𐐀")
      e.typography!.caseTreatment="lowercase"
      var type=e.typography!;type.underline=true
      e.textRuns=[.init(location:1,length:1,typography:type,fontSize:30,color:"#CC4400")]
      let display=TypographyEngine.attributed(e,preservingSource:true)
      XCTAssertEqual(display.string,(e.text as NSString).lowercased)
      XCTAssertTrue(display.string.hasPrefix("ος ας"))
      XCTAssertEqual(TextCase.source(display).text.string,e.text)
      XCTAssertEqual((display.attribute(.font,at:1,effectiveRange:nil) as! NSFont).pointSize,30)
    }
  }
  func testManualPairsAfterExpandedLettersAndFollowingOffsetsRemainIndependent() async throws {
    await MainActor.run {
      var e=element("aß av");e.typography!.caseTreatment="uppercase";e.typography!.tracking=2
      e.typography!.pairKerning=[1:-3,3:-1]
      let display=TypographyEngine.attributed(e,preservingSource:true)
      XCTAssertNil(display.attribute(TypographyEngine.pairKey,at:1,effectiveRange:nil))
      XCTAssertEqual((display.attribute(TypographyEngine.pairKey,at:2,effectiveRange:nil) as! NSNumber).doubleValue,-3)
      XCTAssertEqual((display.attribute(.tracking,at:1,effectiveRange:nil) as! NSNumber).doubleValue,2)
      XCTAssertEqual((display.attribute(.tracking,at:2,effectiveRange:nil) as! NSNumber).doubleValue,-1)
      let recovered=TextCase.source(display).text
      let runs=TypographyEngine.spans(from:recovered,fallback:e.typography!)
      XCTAssertTrue(runs.allSatisfy{$0.typography.tracking==2})
      XCTAssertEqual(runs.flatMap{$0.typography.pairKerning}.reduce(into:[Int:Double]()){$0[$1.key]=$1.value},[1:-3,3:-1])
      let refreshed=NSMutableAttributedString(attributedString:display)
      TypographyEngine.refreshNativeMetadata(runs,in:refreshed)
      XCTAssertEqual((refreshed.attribute(TypographyEngine.pairKey,at:2,effectiveRange:nil) as! NSNumber).doubleValue,-3)
      XCTAssertEqual(TextCase.source(refreshed).text.string,e.text)
    }
  }
  func testPartialDeletionBreaksOnlyEditedExpansionAndLeavesOtherSourceLetters() async throws {
    await MainActor.run {
      var e=element("Straße");e.typography!.caseTreatment="uppercase"
      let edited=NSMutableAttributedString(attributedString:TypographyEngine.attributed(e,preservingSource:true))
      edited.deleteCharacters(in:NSRange(location:4,length:1))
      XCTAssertEqual(TextCase.source(edited).text.string,"StraSe")
      XCTAssertEqual(TypographyEngine.displayingCase(TextCase.source(edited).text).string,"STRASE")
    }
  }
  func testNormalCaseRestoresOriginalWordsWithoutLosingRichAttributes() async throws {
    await MainActor.run {
      var e=element("Straße İSTANBUL");e.typography!.caseTreatment="uppercase"
      let source=TextCase.source(TypographyEngine.attributed(e,preservingSource:true)).text
      var normal=e.typography!;normal.caseTreatment="original"
      let reset=NSMutableAttributedString(attributedString:source)
      let attrs=TypographyEngine.attributes(normal,size:24,color:e.color,millimeters:false)
      reset.setAttributes(attrs,range:NSRange(location:0,length:reset.length))
      XCTAssertEqual(TypographyEngine.displayingCase(reset).string,e.text)
    }
  }
  func testExternalFormattingWithinExpansionRetainsBothDisplayedCharacterFormats() async throws {
    await MainActor.run {
      var e=element("ß");e.typography!.caseTreatment="uppercase"
      let display=NSMutableAttributedString(attributedString:TypographyEngine.attributed(e,preservingSource:true))
      display.addAttribute(.foregroundColor,value:NSColor.red,range:NSRange(location:1,length:1))
      let recovered=TextCase.source(display)
      XCTAssertEqual(recovered.text.string,"SS")
      XCTAssertNotEqual(recovered.text.attribute(.foregroundColor,at:0,effectiveRange:nil) as! NSColor,
        recovered.text.attribute(.foregroundColor,at:1,effectiveRange:nil) as! NSColor)
    }
  }
  func testCaseProvenanceDoesNotChangeShapedLigaturesOrFontKerning() async throws {
    await MainActor.run {
      var e=element("OFFICE AVATAR STRASSE");e.typography!.caseTreatment="lowercase";e.typography!.fontName="Baskerville"
      let native=TypographyEngine.attributed(e,preservingSource:true),rendered=TypographyEngine.attributed(e)
      let a=CTLineCreateWithAttributedString(native),b=CTLineCreateWithAttributedString(rendered)
      XCTAssertEqual(CTLineGetGlyphCount(a),CTLineGetGlyphCount(b))
      for i in 0...rendered.length {XCTAssertEqual(CTLineGetOffsetForStringIndex(a,i,nil),CTLineGetOffsetForStringIndex(b,i,nil),accuracy:1e-6)}
      XCTAssertNil(rendered.attribute(TextCase.sourceKey,at:0,effectiveRange:nil))
    }
  }
  func testMalformedEphemeralProvenanceCannotReadOutsideText() async throws {
    try await MainActor.run {
      var e=element("a");e.typography!.caseTreatment="uppercase"
      let valid=TypographyEngine.attributed(e,preservingSource:true).attribute(TextCase.sourceKey,at:0,effectiveRange:nil) as! Data
      var raw=try JSONSerialization.jsonObject(with:valid) as! [String:Any]
      raw["source"]=""
      let data=try JSONSerialization.data(withJSONObject:raw)
      let text=NSAttributedString(string:"A",attributes:[TextCase.sourceKey:data])
      XCTAssertEqual(TextCase.source(text).text.string,"A")
      XCTAssertNil(TextCase.source(text).text.attribute(TextCase.sourceKey,at:0,effectiveRange:nil))
    }
  }
  func testManualPairAttributeBoundariesCannotSplitSupplementarySourceLetters() async throws {
    await MainActor.run {
      var e=element("a𐐨😀ß");e.typography!.caseTreatment="uppercase";e.typography!.tracking=1
      e.typography!.pairKerning=[2:-1,4:-2,5:-3]
      let display=TypographyEngine.attributed(e,preservingSource:true)
      let source=TextCase.source(display).text
      XCTAssertEqual(display.string,"A𐐀😀SS")
      XCTAssertEqual(source.string,e.text)
      let spans=TypographyEngine.spans(from:source,fallback:e.typography!)
      XCTAssertTrue(spans.allSatisfy{$0.typography.tracking==1})
      XCTAssertEqual(spans.flatMap{$0.typography.pairKerning}.reduce(into:[Int:Double]()){$0[$1.key]=$1.value},[2:-1,4:-2,5:-3])
    }
  }
}

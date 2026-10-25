import AppKit
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class ParagraphLanguageTests:XCTestCase {
  private func element(_ text:String="I İstanbul ΟΣ") -> ArtworkElement {
    var e=ArtworkElement(kind:"text",x:0,y:0,width:90,height:50,text:text,color:"#26323C",fontSize:16)
    var t=Typography();t.fontName="HelveticaNeue";t.kerningMode="metrics";e.typography=t;return e
  }
  func testLanguageCanonicalizationLimitsValidationAndSchemaRoundTrip() throws {
    XCTAssertEqual(try ParagraphLanguage.canonical("en_US"),"en-US")
    XCTAssertThrowsError(try ParagraphLanguage.canonical("en<script>"))
    XCTAssertThrowsError(try HyphenationLimits(minimumPrefix:0).validate())
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let repo=try ProjectRepository(root:root)
    var p=Project(name:"Language"),frame=try p.makeObject(recipeID:"artboard")
    var e=element();e.typography!.hyphenationLimits = .init(minimumWordLength:8,minimumPrefix:3,minimumSuffix:4)
    frame.artwork = Artwork(elements:[e]);frame.artwork!.language="de";p.objects=[frame]
    try repo.save(p);let loaded=try repo.load(p.id)
    XCTAssertEqual(loaded.schemaVersion,20);XCTAssertEqual(loaded.objects,p.objects)
    let raw=String(data:try JSONEncoder.form.encode(loaded),encoding:.utf8)!
    XCTAssertFalse(raw.contains("inheritedLanguage"));XCTAssertFalse(raw.contains("studio.form.documentLanguage"))
    let legacy=try JSONDecoder.form.decode(Typography.self,from:Data("{}".utf8))
    XCTAssertNil(legacy.language);XCTAssertNil(legacy.hyphenationLimits)
  }
  func testDocumentAndParagraphCommandsPreserveSourcePaintAndUndo() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));var p=Project(name:"Language"),frame=try p.makeObject(recipeID:"artboard")
    var e=element("First word\nSecond word");var rich=e.typography!;rich.tracking=1.1
    e.textRuns=[.init(location:0,length:5,typography:rich,fontSize:22,color:"#B45A34")]
    frame.artwork = .init(elements:[e]);p.objects=[frame];engine.project=p
    _=try engine.call("form_edit_artwork",arguments:["object_id":frame.id.uuidString,"command":"language","language":"de_DE"])
    XCTAssertEqual(engine.project!.objects[0].artwork!.language,"de-DE")
    XCTAssertEqual(engine.project!.objects[0].artwork!.elements,[e]);engine.undo();XCTAssertEqual(engine.project,p)
    _=try engine.call("form_edit_artwork",arguments:["object_id":frame.id.uuidString,"command":"paragraph","element_ids":[e.id.uuidString],"location":1,"length":2,"typography":["language":"tr","hyphenationLimits":["minimumWordLength":7,"minimumPrefix":3,"minimumSuffix":2]]])
    let changed=engine.project!.objects[0].artwork!.elements[0]
    XCTAssertEqual(changed.text,e.text);XCTAssertEqual(changed.textRuns!.first!.fontSize,22);XCTAssertEqual(changed.textRuns!.first!.color,"#B45A34")
    XCTAssertTrue(changed.textRuns!.filter{$0.location<11}.allSatisfy{$0.typography.language=="tr"})
    XCTAssertTrue(changed.textRuns!.filter{$0.location>=11}.allSatisfy{$0.typography.language==nil})
    engine.undo();XCTAssertEqual(engine.project,p)
    p.objects[0].locked=true;engine.project=p
    XCTAssertThrowsError(try engine.call("form_edit_artwork",arguments:["object_id":frame.id.uuidString,"command":"language","language":"fr"]))
  }
  func testLocaleCaseExpansionDeletionAndContextRetainOriginalSource() throws {
    for (language,text,treatment) in [("tr","I\u{307} I i ı İ","lowercase"),("az","I\u{307} I i","lowercase"),("lt","I\u{301} J\u{301}","lowercase"),("lt","i\u{307}\u{301}","uppercase"),("el","ΟΣ ΟΣΑ","lowercase")] {
      var e=element(text);e.typography!.language=language;e.typography!.caseTreatment=treatment
      let expected=treatment=="uppercase" ? text.uppercased(with:Locale(identifier:language)):text.lowercased(with:Locale(identifier:language))
      let native=TypographyEngine.attributed(e,preservingSource:true),production=TypographyEngine.attributed(e)
      XCTAssertEqual(native.string,expected,language);XCTAssertEqual(production.string,expected,language)
      let restored=TextCase.source(native)
      XCTAssertEqual(restored.text.string,text,language)
      XCTAssertTrue(GlyphEngine.nativeEqual(GlyphEngine.normalizedNative(restored.text),native),language)
      XCTAssertEqual(restored.sourceRange(NSRange(location:0,length:native.length)),NSRange(location:0,length:text.utf16.count))
    }
  }
  func testLocaleCombiningMarkDeletionPreservesHiddenRichFormattingAndOriginalRestoration() throws {
    var e=element("i\u{307}\u{301}");e.typography!.language="lt";e.typography!.caseTreatment="uppercase"
    var accent=e.typography!;accent.fontName="Georgia-Italic";accent.tracking=0.7
    e.textRuns=[.init(location:1,length:1,typography:accent,fontSize:12,color:"#C34D2E")]
    let native=TypographyEngine.attributed(e,preservingSource:true)
    XCTAssertEqual(native.string,"I\u{301}")
    let recovered=TextCase.source(native).text
    XCTAssertEqual(recovered.string,e.text)
    XCTAssertEqual(FormColor.hex(recovered.attribute(.foregroundColor,at:1,effectiveRange:nil) as! NSColor),"#C34D2E")
    XCTAssertEqual((recovered.attribute(.font,at:1,effectiveRange:nil) as! NSFont).pointSize,12)
    let original=NSMutableAttributedString(attributedString:recovered)
    original.enumerateAttributes(in:NSRange(location:0,length:original.length)) {attrs,range,_ in
      let spans=TypographyEngine.spans(from:NSAttributedString(string:"A",attributes:attrs),fallback:e.typography!)
      var type=spans[0].typography;type.caseTreatment="original"
      original.addAttributes(TypographyEngine.attributes(type,size:spans[0].fontSize,color:spans[0].color,millimeters:false),range:range)
    }
    XCTAssertEqual(TypographyEngine.displayingCase(original).string,e.text)
  }
  func testDocumentLanguageInheritanceShapesCaseWithoutBecomingALocalOverride() throws {
    var e=element("I");e.typography!.caseTreatment="lowercase"
    let inherited=e.inheritingLanguage("tr"),native=TypographyEngine.attributed(inherited,preservingSource:true)
    XCTAssertEqual(native.string,"ı")
    let source=TextCase.source(native).text,spans=TypographyEngine.spans(from:source,fallback:e.typography!)
    XCTAssertEqual(spans[0].typography,e.typography!)
    XCTAssertEqual(source.attribute(LanguageHyphenation.languageKey,at:0,effectiveRange:nil) as? String,"tr")
    var art=Artwork(elements:[e]);art.language="tr"
    let svg=try SVGRenderer.document(art,width:90,height:50,assets:FileManager.default.temporaryDirectory,outlineText:false)
    XCTAssertTrue(svg.contains("ı"));XCTAssertEqual(e.text,"I")
  }
  func testActualDictionaryCandidatesRespectLanguageAndCharacterLimits() throws {
    let text="Donaudampfschifffahrtsgesellschaft",range=NSRange(location:0,length:text.utf16.count)
    XCTAssertTrue(LanguageHyphenation.dictionaryAvailable("en"));XCTAssertTrue(LanguageHyphenation.dictionaryAvailable("de"))
    XCTAssertEqual(LanguageHyphenation.candidate(in:text,before:29,range:range,language:"en"),24)
    XCTAssertEqual(LanguageHyphenation.candidate(in:text,before:29,range:range,language:"de"),28)
    XCTAssertEqual(LanguageHyphenation.candidate(in:text,before:29,range:range,language:"de",limits:.init(minimumWordLength:5,minimumPrefix:2,minimumSuffix:7)),24)
    XCTAssertEqual(LanguageHyphenation.candidate(in:text,before:29,range:range,language:"zz-ZZ"),NSNotFound)
    XCTAssertEqual(LanguageHyphenation.candidate(in:text,before:29,range:range,language:"de",limits:.init(minimumWordLength:40)),NSNotFound)
    XCTAssertEqual(LanguageHyphenation.candidate(in:"😀"+text,before:31,range:NSRange(location:2,length:range.length),language:"de"),30)
  }
  func testChosenDictionaryAndLimitsDriveActualTextKitGlyphs() throws {
    var e=element("Donaudampfschifffahrtsgesellschaft");e.typography!.hyphenation=1
    func breaks(_ language:String,limits:HyphenationLimits?=nil,width:Double)->[Int] {
      var type=e.typography!;type.language=language;type.hyphenationLimits=limits
      let s=PublicationTextStorage();s.setAttributedString(NSAttributedString(string:e.text,attributes:TypographyEngine.attributes(type,size:16,color:e.color,millimeters:false)))
      let layout=NSLayoutManager(),box=NSTextContainer(size:.init(width:width,height:10000));box.lineFragmentPadding=0
      s.addLayoutManager(layout);layout.addTextContainer(box);layout.ensureLayout(for:box)
      var result:[Int]=[]
      layout.enumerateLineFragments(forGlyphRange:layout.glyphRange(for:box)){_,_,_,range,_ in result.append(NSMaxRange(layout.characterRange(forGlyphRange:range,actualGlyphRange:nil)))}
      return result
    }
    let differences=(50...230).contains{breaks("en",width:Double($0)) != breaks("de",width:Double($0))}
    XCTAssertTrue(differences,"The explicit dictionary must change actual line breaks at some width.")
    XCTAssertNotEqual(breaks("de",width:90),breaks("de",limits:.init(minimumWordLength:40),width:90))
    e.typography!.language="de";e.width=90/TypographyEngine.pointsPerMM
    let forced=TypographyEngine.measured(e)
    e.typography!.hyphenationLimits = .init(minimumWordLength:40)
    XCTAssertNotEqual(TypographyEngine.measured(e),forced)
    XCTAssertEqual(e.text,"Donaudampfschifffahrtsgesellschaft")
    XCTAssertFalse(try TypographyEngine.outlines(e).isEmpty)
  }
}

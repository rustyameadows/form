import XCTest
@testable import FormCore

final class FontLibraryTests:XCTestCase {
  private func fixture() throws -> Project {
    var p=try Samples.fieldGuide(),source=p.textStories![0].sourceElement
    source.typography!.fontName="FORM-Missing-Regular";source.typography!.features=[21:0];source.typography!.variations=[123:2]
    source.textRuns?.removeAll();source.listItems?[0].fontName="FORM-Missing-Regular"
    try PublicationCommands.setSource(in:&p,storyID:p.textStories![0].id,source:source)
    var hidden=ArtworkElement(kind:"text",x:10,y:10,width:40,height:20,text:"Recover Q",fontSize:14)
    hidden.typography=source.typography;hidden.hidden=true
    hidden.glyphOverrides=[.init(location:8,sourceText:"Q",glyph:.init(fontName:"FORM-Missing-Regular",glyphID:12,glyphName:"Q.alt",fontSignature:String(repeating:"a",count:64)))]
    hidden.textRuns=[.init(location:0,length:7,typography:source.typography!,fontSize:16,color:"#123456")]
    p.objects[0].artwork!.elements.append(hidden)
    p.textStyles=[.init(name:"Body",typography:source.typography!,fontSize:11)]
    try p.validateArtworkLinks();return p
  }
  func testCompleteUsageFindsStoriesStylesRichRecoverableMarkersAndExactGlyphs() throws {
    let p=try fixture(),before=p,uses=FontUsage.uses(in:p).filter{$0.fontName=="FORM-Missing-Regular"}
    XCTAssertEqual(Set(uses.map(\.kind)),["text","rich_span","recoverable_text","list_marker","exact_glyph","text_style"])
    XCTAssertEqual(p,before);XCTAssertFalse(uses.contains{$0.owner.isEmpty})
    XCTAssertTrue(uses.contains{$0.storyID != nil});XCTAssertTrue(uses.contains{$0.styleID != nil})
  }
  func testProjectReplacementKeepsAllOriginalWordsFeaturesAxesIDsAndExactGlyphMetadata() throws {
    let p=try fixture(),changed=try FontUsage.replacing(in:p,from:"FORM-Missing-Regular",to:"Georgia")
    XCTAssertEqual(changed.textStories![0].text,p.textStories![0].text)
    XCTAssertEqual(changed.textStories![0].typography?.features,[21:0]);XCTAssertEqual(changed.textStories![0].typography?.variations,[123:2])
    XCTAssertEqual(changed.textStories![0].frames,p.textStories![0].frames);XCTAssertEqual(changed.textStories![0].listItems?.map(\.id),p.textStories![0].listItems?.map(\.id))
    XCTAssertEqual(changed.objects[0].artwork!.elements.last?.glyphOverrides,p.objects[0].artwork!.elements.last?.glyphOverrides)
    XCTAssertEqual(changed.textStyles?.first?.id,p.textStyles?.first?.id)
    let remaining=FontUsage.uses(in:changed).filter{$0.fontName=="FORM-Missing-Regular"};XCTAssertEqual(remaining.map(\.kind),["exact_glyph"])
    XCTAssertEqual(changed.schemaVersion,p.schemaVersion);try changed.validateArtworkLinks()
  }
  func testLockedAssignmentRejectsTheWholeReplacementAndLeavesOriginal() throws {
    var p=try fixture();p.objects[0].locked=true;let before=p
    XCTAssertThrowsError(try FontUsage.replacing(in:p,from:"FORM-Missing-Regular",to:"Georgia"));XCTAssertEqual(p,before)
    XCTAssertEqual(try FontUsage.replacing(in:p,from:"Not assigned",to:"Georgia"),p)
  }
  func testFontOnlySourceRangesRetainWordsColorsFeaturesAxesAndDoNotExpandToParagraphs() throws {
    var e=ArtworkElement(kind:"text",x:0,y:0,width:100,height:20,text:"A😀B\nNext",fontSize:14)
    var t=Typography();t.fontName="Skia";t.features=[1:3];t.variations=[123:2];e.typography=t
    var art=Artwork(elements:[e]);let original=art
    try FontCommands.assign(&art,ids:[e.id],arguments:["font_name":"Georgia","location":1,"length":2])
    let runs=art.elements[0].textRuns!
    XCTAssertEqual(runs.first{$0.location==1}?.length,2);XCTAssertEqual(runs.first{$0.location==1}?.typography.fontName,"Georgia")
    XCTAssertTrue(runs.allSatisfy{$0.typography.features==t.features && $0.typography.variations==t.variations})
    XCTAssertEqual(art.elements[0].text,e.text);XCTAssertEqual(art.elements[0].color,e.color)
    var invalid=original;XCTAssertThrowsError(try FontCommands.assign(&invalid,ids:[e.id],arguments:["font_name":"Georgia","location":2,"length":1]));XCTAssertEqual(invalid,original)
  }
  func testLongUnicodeStoryOffsetsUseActualUtf16LengthRatherThanCharacterLimit() throws {
    var e=ArtworkElement(kind:"text",x:0,y:0,width:100,height:100,text:String(repeating:"😀",count:50001)+"A",fontSize:12)
    e.typography=Typography();e.typography!.fontName="Georgia"
    var art=Artwork(elements:[e])
    try FontCommands.assign(&art,ids:[e.id],arguments:["font_name":"Baskerville","location":100002,"length":1],maxTextCharacters:100000)
    XCTAssertEqual(art.elements[0].text,e.text)
    XCTAssertEqual(art.elements[0].textRuns?.last?.typography.fontName,"Baskerville")
    XCTAssertEqual(art.elements[0].textRuns?.last?.location,100002)
  }

}

import Foundation
import XCTest
@testable import FormCore

final class CharacterPositionTests:XCTestCase {
  private func text(_ words:String="H12abQO")->ArtworkElement {
    var e=ArtworkElement(kind:"text",x:0,y:0,width:160,height:40,text:words,fontSize:36)
    var t=Typography();t.fontName="Georgia";t.baseline=3;t.features=[10:1,37:1];t.variations=[OpticalSizing.axisID:72];e.typography=t;return e
  }
  func testOmissionPreservesExactLegacyAssignmentsAndDoesNotAdvanceSchema()throws {
    let e=text(),data=try JSONEncoder.form.encode(e);XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("characterPosition"))
    XCTAssertEqual(try JSONDecoder.form.decode(ArtworkElement.self,from:data),e)
    var p=Project(name:"Legacy");var o=try p.makeObject(recipeID:"artboard");o.artwork = .init(elements:[e]);p.objects=[o]
    XCTAssertLessThan(p.minimumSchemaVersion,47)
  }
  func testWholePositionPreservesNominalSizeBaselineFeaturesAxesAndExactGlyphChoice()throws {
    var e=text();e.glyphOverrides=[.init(location:1,sourceText:"1",glyph:.init(fontName:"Georgia",glyphID:20,fontSignature:String(repeating:"a",count:64)))];let before=e
    var art=Artwork(elements:[e]);try ArtworkCommands.apply("character_position",to:&art,ids:[e.id],arguments:["position":"superscript"])
    let after=art.elements[0];XCTAssertEqual(after.text,before.text);XCTAssertEqual(after.fontSize,36);XCTAssertEqual(after.typography?.baseline,3);XCTAssertEqual(after.typography?.features,before.typography?.features);XCTAssertEqual(after.typography?.variations,before.typography?.variations);XCTAssertEqual(after.glyphOverrides,before.glyphOverrides);XCTAssertEqual(after.typography?.characterPosition,.superscript)
    try ArtworkCommands.apply("character_position",to:&art,ids:[e.id],arguments:["position":NSNull()]);XCTAssertEqual(art.elements,[before])
  }
  func testCompleteGraphemeRangesPreserveSourceSpansAndRejectPartialClustersAtomically()throws {
    let words="Ae\u{301}👩🏽‍🚀🇺🇸क्षZ",e=text(words);var art=Artwork(elements:[e])
    let source=words as NSString,accent=source.range(of:"e\u{301}"),emoji=source.range(of:"👩🏽‍🚀"),flag=source.range(of:"🇺🇸"),indic=source.range(of:"क्ष")
    for range in [accent,emoji,flag,indic] {
      XCTAssertTrue(CharacterPositionCommands.isCompleteRange(range,in:words))
      try ArtworkCommands.apply("character_position",to:&art,ids:[e.id],arguments:["position":"subscript","location":range.location,"length":range.length])
      XCTAssertEqual(art.elements[0].text,words);XCTAssertTrue(art.elements[0].textRuns!.contains{$0.location==range.location && $0.length==range.length && $0.typography.characterPosition == .subscript})
    }
    let saved=art
    for range in [NSRange(location:accent.location,length:1),NSRange(location:emoji.location,length:2),NSRange(location:flag.location,length:2),NSRange(location:indic.location,length:1)] {
      XCTAssertThrowsError(try ArtworkCommands.apply("character_position",to:&art,ids:[e.id],arguments:["position":"normal","location":range.location,"length":range.length]));XCTAssertEqual(art,saved)
    }
    XCTAssertTrue(CharacterPositionCommands.isCompleteRange(.init(location:emoji.location,length:0),in:words,allowCaret:true));XCTAssertFalse(CharacterPositionCommands.isCompleteRange(.init(location:emoji.location+2,length:0),in:words,allowCaret:true))
  }
  func testMalformedValuesLockedTextAndCommandWorkLimitsRejectWithoutPartialWrites()throws {
    let e=text();var art=Artwork(elements:[e]);let before=art
    for arguments:[String:Any] in [["position":true],["position":"raise"],["position":"superscript","location":0],["position":"superscript","location":0,"length":1.5],["position":"superscript","location":true,"length":1],["position":"superscript","location":0,"length":0]] {
      XCTAssertThrowsError(try ArtworkCommands.apply("character_position",to:&art,ids:[e.id],arguments:arguments));XCTAssertEqual(art,before)
    }
    art.elements[0].locked=true;XCTAssertThrowsError(try ArtworkCommands.apply("character_position",to:&art,ids:[e.id],arguments:["position":"superscript"]))
    var long=e;long.text=String(repeating:"x",count:CharacterPositionCommands.maximumCommandUTF16+1);var large=Artwork(elements:[long]);XCTAssertThrowsError(try CharacterPositionCommands.assign(&large,ids:[long.id],arguments:["position":"superscript"],maxTextCharacters:CharacterPositionCommands.maximumCommandUTF16+1));XCTAssertNil(large.elements[0].typography?.characterPosition)
  }
  func testReusableCharacterStyleInheritanceOverridesAndResetKeepNominalSource()throws {
    var p=Project(name:"Styles");var o=try p.makeObject(recipeID:"artboard");let e=text();o.artwork = .init(elements:[e]);p.objects=[o]
    var type=e.typography!;type.characterPosition = .superscript;let id=try TextStyleCommands.save(in:&p,name:"Footnote",typography:type,fontSize:36)
    try TextStyleCommands.apply(in:&p,objectID:o.id,ids:[e.id],styleID:id)
    var art=p.objects[0].artwork!;try CharacterPositionCommands.assign(&art,ids:[e.id],arguments:["position":"subscript","location":1,"length":2]);try p.setArtwork(art,for:o.id)
    XCTAssertTrue(p.objects[0].artwork!.elements[0].textRuns!.first{$0.location==1}!.textStyle!.overrides.contains("characterPosition"))
    type.characterPosition = .normal;_ = try TextStyleCommands.save(in:&p,id:id,name:"Footnote",typography:type,fontSize:36)
    let changed=p.objects[0].artwork!.elements[0];XCTAssertEqual(changed.textRuns!.first{$0.location==1}?.typography.characterPosition,.subscript);XCTAssertEqual(changed.fontSize,36);XCTAssertEqual(changed.typography?.baseline,3)
    try TextStyleCommands.apply(in:&p,objectID:o.id,ids:[e.id],mode:"reset");XCTAssertTrue((p.objects[0].artwork!.elements[0].textRuns ?? []).allSatisfy{$0.typography.characterPosition == .normal})
  }
  func testSharedStoryCommandChangesOneGlobalSourceAndRetainsPhysicalFrames()throws {
    var p=Project(name:"One story");var first=try p.makeObject(recipeID:"artboard"),second=try p.makeObject(recipeID:"artboard");let source=text("H12abQO\nOriginal instruction")
    first.artwork = .init(elements:[source]);var capacity=source;capacity.id=UUID();capacity.text="";second.artwork = .init(elements:[capacity]);p.objects=[first,second]
    let id=try PublicationCommands.createStory(in:&p,frames:[.init(objectID:first.id,elementID:source.id),.init(objectID:second.id,elementID:capacity.id)]),frames=p.objects
    XCTAssertTrue(try PublicationCommands.editText(in:&p,objectID:first.id,ids:[source.id],command:"character_position",arguments:["position":"superscript","location":1,"length":2]))
    XCTAssertEqual(p.objects,frames);XCTAssertEqual(p.textStories![0].id,id);XCTAssertEqual(p.textStories![0].text,source.text);XCTAssertEqual(p.textStories![0].textRuns?.first{$0.location==1}?.typography.characterPosition,.superscript)
  }
  func testSchema47IncludesHiddenRecoverableTextAndUnusedStylesAndReopens()throws {
    var p=Project(name:"Recovery");var o=try p.makeObject(recipeID:"artboard"),e=text();e.hidden=true;e.typography?.characterPosition = .normal;o.artwork = .init(elements:[e]);p.objects=[o]
    XCTAssertEqual(p.minimumSchemaVersion,47)
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)};let repository=try ProjectRepository(root:root);try repository.save(p);let reopened=try repository.load(p.id);XCTAssertEqual(reopened.objects,p.objects);XCTAssertEqual(reopened.schemaVersion,47)
    p.objects=[];var type=Typography();type.characterPosition = .superscript;p.textStyles=[.init(name:"Unused but retained",typography:type)];XCTAssertEqual(p.minimumSchemaVersion,47)
  }
  func testRawVerticalStyleEditIntentionallyRestoresFontOnlyBehaviorWithExactUndo()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));var p=Project(name:"Font-only style"),type=Typography();type.characterPosition = .superscript;type.baseline=3;type.variations=[OpticalSizing.axisID:72]
    let id=try TextStyleCommands.save(in:&p,name:"Authored position",typography:type,fontSize:36);engine.project=p;let before=engine.project!
    _ = try engine.call("form_text_style",arguments:["command":"update","style_id":id.uuidString,"typography":["features":["10":2]]])
    let after=engine.project!.textStyles![0];XCTAssertNil(after.typography.characterPosition);XCTAssertEqual(after.typography.features,[10:2]);XCTAssertEqual(after.typography.baseline,3);XCTAssertEqual(after.typography.variations,[OpticalSizing.axisID:72]);XCTAssertEqual(after.fontSize,36)
    engine.undo();XCTAssertEqual(engine.project,before)
  }
  func testExcessivePositionSourceSpansRejectBeforeChangingArtwork()throws {
    var e=text(String(repeating:"x",count:4097));e.textRuns=(0..<4097).map{.init(location:$0,length:1,typography:e.typography!,fontSize:36,color:e.color)}
    var art=Artwork(elements:[e]);let before=art
    XCTAssertThrowsError(try CharacterPositionCommands.assign(&art,ids:[e.id],arguments:["position":"superscript"]));XCTAssertEqual(art,before)
  }

}

import XCTest
@testable import FormCore

final class GlyphOverrideTests:XCTestCase {
  private let glyph=FontGlyph(fontName:"HoeflerText-Regular",glyphID:815,glyphName:"Q.alt",fontSignature:String(repeating:"a",count:64))
  private func element(_ text:String="Quill 😀") -> ArtworkElement {.init(kind:"text",x:0,y:0,width:100,height:40,text:text)}
  func testGlyphAssignmentRetainsSourceAndAllCharacterFormatting() throws {
    var e=element();var type=Typography();type.tracking=2
    e.textRuns=[.init(location:0,length:1,typography:type,fontSize:36,color:"#CC4400")]
    var art=Artwork(elements:[e]);let original=art
    try ArtworkCommands.apply("glyph",to:&art,ids:[e.id],arguments:["location":0,"length":1,"glyph":try jsonObject(glyph)])
    XCTAssertEqual(art.elements[0].text,e.text);XCTAssertEqual(art.elements[0].textRuns,e.textRuns)
    XCTAssertEqual(art.elements[0].glyphOverrides?.first?.sourceText,"Q")
    let applied=art
    try ArtworkCommands.apply("glyph",to:&art,ids:[e.id],arguments:["location":0,"length":1,"glyph":try jsonObject(glyph)])
    XCTAssertEqual(art,applied)
    try ArtworkCommands.apply("glyph",to:&art,ids:[e.id],arguments:["glyph":NSNull()])
    XCTAssertEqual(art,original)
  }
  func testRangesAndInvalidGlyphMetadataRejectWithoutMutation() throws {
    let e=element();var art=Artwork(elements:[e]);let original=art
    for args:[String:Any] in [
      ["location":-1,"length":1,"glyph":try jsonObject(glyph)],
      ["location":7,"length":1,"glyph":try jsonObject(glyph)],
      ["location":true,"length":1,"glyph":try jsonObject(glyph)],
      ["location":0,"length":1.5,"glyph":try jsonObject(glyph)],
      ["location":0,"length":1,"glyph":["fontName":"Font","glyphID":0,"fontSignature":"x"]],
      ["glyph":try jsonObject(glyph)],
    ] {
      XCTAssertThrowsError(try ArtworkCommands.apply("glyph",to:&art,ids:[e.id],arguments:args));XCTAssertEqual(art,original)
    }
    var bad=e;bad.glyphOverrides=[.init(location:0,sourceText:"X",glyph:glyph)]
    XCTAssertThrowsError(try validateArtwork(Artwork(elements:[bad])))
  }
  func testReplacingOverlapAndScopedClearRetainOtherChoices() throws {
    var e=element("Quill Q");e.glyphOverrides=[.init(location:0,sourceText:"Q",glyph:glyph),.init(location:6,sourceText:"Q",glyph:glyph)]
    var art=Artwork(elements:[e]);let second=e.glyphOverrides![1]
    try ArtworkCommands.apply("glyph",to:&art,ids:[e.id],arguments:["location":0,"length":2,"glyph":try jsonObject(glyph)])
    XCTAssertEqual(art.elements[0].glyphOverrides?.count,2)
    XCTAssertEqual(art.elements[0].glyphOverrides?.last,second)
    try ArtworkCommands.apply("glyph",to:&art,ids:[e.id],arguments:["location":0,"length":1,"glyph":NSNull()])
    XCTAssertEqual(art.elements[0].glyphOverrides,[second])
  }
  func testGlyphBatchValidationCallbackAndUndoAreAtomic() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    var p=Project(name:"Glyphs");var o=try p.makeObject(recipeID:"artboard");let e=element();o.artwork=Artwork(elements:[e]);p.objects=[o];engine.project=p
    let args:[String:Any]=["command":"glyph","object_id":o.id.uuidString,"element_ids":[e.id.uuidString],"location":0,"length":1,"glyph":try jsonObject(glyph)]
    engine.onPrepareGlyph={_,_ in throw FormError.invalid("Missing font glyph")}
    XCTAssertThrowsError(try engine.call("form_edit_artwork",arguments:args));XCTAssertEqual(engine.project,p);XCTAssertTrue(engine.undoStack.isEmpty)
    engine.onPrepareGlyph=nil
    _=try engine.call("form_edit_artwork",arguments:args);XCTAssertEqual(engine.project?.schemaVersion,15)
    engine.undo();XCTAssertEqual(engine.project,p)
    p.objects[0].locked=true;engine.project=p
    XCTAssertThrowsError(try engine.call("form_edit_artwork",arguments:args));XCTAssertEqual(engine.project,p)
  }
  func testSchemaFifteenRoundTripAndLegacyOptionalDefaults() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let repo=try ProjectRepository(root:root);var p=Project(name:"Glyphs");var o=try p.makeObject(recipeID:"artboard");var e=element()
    e.glyphOverrides=[.init(location:0,sourceText:"Q",glyph:glyph)];o.artwork=Artwork(elements:[e]);p.objects=[o];try repo.save(p)
    let loaded=try repo.load(p.id);XCTAssertEqual(loaded.schemaVersion,15);XCTAssertEqual(loaded.objects,p.objects)
    e.glyphOverrides=nil;let decoded=try JSONDecoder.form.decode(ArtworkElement.self,from:JSONEncoder.form.encode(e));XCTAssertNil(decoded.glyphOverrides)
  }
}

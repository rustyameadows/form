import AppKit
import CoreText
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class GlyphEditingTests: XCTestCase {
  private func editor(_ string:String="Q",uppercase:Bool=false) throws -> (NSWindow,CanvasTextView,FontGlyph) {
    _=NSApplication.shared
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:300),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let view=CanvasTextView(frame:window.contentView!.bounds);view.isRichText=true;view.allowsUndo=true
    window.contentView=view;window.makeFirstResponder(view)
    view.undoManager?.groupsByEvent=false
    var e=ArtworkElement(kind:"text",x:0,y:0,width:100,height:40,text:string,color:"#243846",fontSize:36)
    var type=Typography();type.fontName="HoeflerText-Regular";type.caseTreatment=uppercase ? "uppercase":"original";e.typography=type
    view.textStorage?.setAttributedString(TypographyEngine.attributed(e,preservingSource:true))
    view.typingAttributes=TypographyEngine.attributes(type,size:36,color:e.color,millimeters:false)
    let font=NSFont(name:type.fontName,size:36)!
    let glyph=try GlyphCatalog.glyph(fontName:font.fontName,id:Int(CTFontGetGlyphWithName(font as CTFont,"Q.alt" as CFString)))
    return(window,view,glyph)
  }
  private func choices(_ view:CanvasTextView)->[GlyphOverride] {
    GlyphEngine.overrides(from:TextCase.source(view.attributedString()).text)
  }
  func testGlyphAssignmentIsOneNativeUndoAndKeepsOriginalCaseSource() throws {
    let (window,view,glyph)=try editor("q",uppercase:true);defer{window.close()}
    let original=NSAttributedString(attributedString:view.attributedString())
    try view.applyGlyph(glyph,sourceRange:NSRange(location:0,length:1))
    let applied=NSAttributedString(attributedString:view.attributedString())
    XCTAssertEqual(view.string,"Q");XCTAssertEqual(TextCase.source(applied).text.string,"q")
    XCTAssertEqual(choices(view).first?.glyph,glyph)
    try view.applyGlyph(glyph,sourceRange:NSRange(location:0,length:1))
    XCTAssertTrue(view.attributedString().isEqual(to:applied))
    view.undoManager?.undo();XCTAssertTrue(view.attributedString().isEqual(to:original));XCTAssertTrue(choices(view).isEmpty)
    view.undoManager?.redo();XCTAssertTrue(view.attributedString().isEqual(to:applied))
    try view.applyGlyph(nil,sourceRange:NSRange(location:0,length:1));XCTAssertTrue(view.attributedString().isEqual(to:original))
    view.undoManager?.undo();XCTAssertTrue(view.attributedString().isEqual(to:applied))
  }
  func testTypingBeforeAndAfterAChoiceShiftsItWithoutInheritingItsGlyph() throws {
    let (window,view,glyph)=try editor();defer{window.close()}
    try view.applyGlyph(glyph,sourceRange:NSRange(location:0,length:1));let original=choices(view).first!
    view.setSelectedRange(NSRange(location:0,length:0));view.insertText("X",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(view.string,"XQ");XCTAssertEqual(choices(view).map(\.location),[1]);XCTAssertEqual(choices(view).first?.id,original.id)
    view.breakUndoCoalescing()
    view.setSelectedRange(NSRange(location:2,length:0));view.insertText("Q",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(view.string,"XQQ");XCTAssertEqual(choices(view).map(\.location),[1])
    XCTAssertNil(view.attributedString().attribute(.glyphInfo,at:2,effectiveRange:nil))
    view.undoManager?.undo();XCTAssertEqual(view.string,"XQ")
    view.undoManager?.undo();XCTAssertEqual(view.string,"Q");XCTAssertEqual(choices(view),[original])
  }
  func testReplacingTheSourceDropsItsChoiceAndNativeUndoRestoresIt() throws {
    let (window,view,glyph)=try editor();defer{window.close()}
    try view.applyGlyph(glyph,sourceRange:NSRange(location:0,length:1));let original=NSAttributedString(attributedString:view.attributedString())
    view.setSelectedRange(NSRange(location:0,length:1));view.insertText("A",replacementRange:NSRange(location:NSNotFound,length:0))
    XCTAssertEqual(view.string,"A");XCTAssertTrue(choices(view).isEmpty)
    XCTAssertNil(view.attributedString().attribute(.glyphInfo,at:0,effectiveRange:nil))
    view.undoManager?.undo()
    let restored=view.attributedString()
    XCTAssertTrue(GlyphEngine.nativeEqual(restored,original))
  }
  func testPointTextGlyphAssignmentAndClearResizeInTheSameUndoTransaction() throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    var p=Project(name:"Point glyph"),o=try p.makeObject(recipeID:"artboard")
    var e=ArtworkElement(kind:"text",x:10,y:10,width:100,height:40,text:"Q",fontSize:48)
    var type=Typography();type.fontName="HoeflerText-Regular";type.frameMode="point";e.typography=type
    let initial=TypographyEngine.measured(e);e.width=max(1,initial.width+0.5);e.height=max(e.fontSize/TypographyEngine.pointsPerMM*1.4,initial.height+0.5)
    o.artwork=Artwork(elements:[e]);p.objects=[o];store.engine.project=p
    let font=TypographyEngine.font(type,size:48)
    let glyph=try GlyphCatalog.glyph(fontName:font.fontName,id:Int(CTFontGetGlyphWithName(font as CTFont,"Q.alt" as CFString)))
    let args:[String:Any]=["command":"glyph","object_id":o.id.uuidString,"element_ids":[e.id.uuidString],"location":0,"length":1,"glyph":try jsonObject(glyph)]
    _=try store.engine.call("form_edit_artwork",arguments:args)
    let changed=store.project!.editableArtwork(store.project!.objects[0])!.elements[0]
    XCTAssertNotEqual(changed.width,e.width)
    XCTAssertEqual(changed.width,TypographyEngine.measured(changed).width+0.5,accuracy:1e-7)
    XCTAssertEqual(changed.x,e.x);XCTAssertEqual(changed.y,e.y)
    let applied=store.project!
    var clear=args;clear["glyph"]=NSNull()
    _=try store.engine.call("form_edit_artwork",arguments:clear)
    XCTAssertEqual(store.project!.editableArtwork(store.project!.objects[0])!.elements[0],e)
    store.engine.undo();XCTAssertEqual(store.project,applied)
    store.engine.undo();XCTAssertEqual(store.project,p)
  }
  func testFontDiscoverySupportsLargePagesAndRejectsBooleanRanges() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    let result=try store.graphicsCall("form_font_features",["font_name":"HoeflerText-Regular","command":"glyphs","offset":30000,"limit":48]) as! [String:Any]
    XCTAssertTrue((result["glyphs"] as! [[String:Any]]).isEmpty)
    XCTAssertThrowsError(try store.graphicsCall("form_font_features",["font_name":"HoeflerText-Regular","command":"glyphs","offset":true]))
    XCTAssertThrowsError(try store.graphicsCall("form_font_features",["font_name":"HoeflerText-Regular","command":"alternates","text":"Q","location":true,"length":1]))
    let legacy=try store.graphicsCall("form_font_features",["font_name":"HoeflerText-Regular"]) as! [String:Any]
    XCTAssertFalse((legacy["features"] as! [[String:Any]]).isEmpty)
    XCTAssertNil(store.project)
  }
  func testUnresolvedGlyphBlocksArtworkAndPhysicalExportsBeforeWritingFiles() async throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    var p=Project(name:"Unresolved glyph"),o=try p.makeObject(recipeID:"artboard")
    var e=ArtworkElement(kind:"text",x:0,y:0,width:50,height:30,text:"Q",fontSize:36)
    var type=Typography();type.fontName="Baskerville";e.typography=type
    let font=NSFont(name:"HoeflerText-Regular",size:36)!
    let glyph=try GlyphCatalog.glyph(fontName:font.fontName,id:Int(CTFontGetGlyphWithName(font as CTFont,"Q.alt" as CFString)))
    e.glyphOverrides=[.init(location:0,sourceText:"Q",glyph:glyph)]
    o.artwork=Artwork(elements:[e]);p.objects=[o];store.engine.project=p
    for format in ["png","pdf"] {
      let path=root.appendingPathComponent("physical."+format)
      do {_ = try await store.exportAsync(format:format,arguments:["object_id":o.id.uuidString,"path":path.path]);XCTFail("Unresolved glyph unexpectedly exported physical \(format).")}
      catch {XCTAssertFalse(error.localizedDescription.contains("asynchronous export route"))}
      XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
      let artwork=root.appendingPathComponent("artwork."+format)
      XCTAssertThrowsError(try store.exportArtwork(object:o,arguments:["format":format,"path":artwork.path]))
      XCTAssertFalse(FileManager.default.fileExists(atPath:artwork.path))
    }
    XCTAssertEqual(store.project,p)
  }
  func testMarkedInputStaysUnforcedAndRejectsPaletteChangesDuringComposition() throws {
    let (window,view,glyph)=try editor();defer{window.close()}
    try view.applyGlyph(glyph,sourceRange:NSRange(location:0,length:1))
    view.undoManager?.beginUndoGrouping()
    defer {view.undoManager?.endUndoGrouping()}
    view.setMarkedText("a",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:0,length:1))
    XCTAssertTrue(view.hasMarkedText());XCTAssertEqual(view.string,"a")
    XCTAssertNil(view.attributedString().attribute(.glyphInfo,at:0,effectiveRange:nil))
    XCTAssertThrowsError(try view.applyGlyph(glyph,sourceRange:NSRange(location:0,length:1)))
    view.unmarkText();view.didChangeText()
    XCTAssertTrue(choices(view).isEmpty);XCTAssertEqual(view.string,"a")
  }
}

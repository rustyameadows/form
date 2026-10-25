import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

final class TextStyleTests: XCTestCase {
  private func fixture() throws -> (Project, UUID, UUID, UUID) {
    var p = Project(name: "Reusable typography")
    var sheet = try p.makeObject(recipeID: "artboard", parameters: ["width": 150, "depth": 100])
    var text = ArtworkElement(kind: "text", x: 10, y: 10, width: 120, height: 40,
      text: "A😀B body", color: "#263C64", fontSize: 20)
    text.typography = .init()
    sheet.artwork = .init(background: "#FFFFFF", elements: [text], bleed: 0)
    p.objects = [sheet]
    var type = Typography(); type.fontName = "Baskerville"; type.leading = 26
    type.tracking = 0.5; type.paragraphAfter = 8
    type.setIndependentFeature(1, selector: 4, value: true)
    let style = try TextStyleCommands.save(in: &p, name: "Body", typography: type, fontSize: 20)
    return (p, sheet.id, text.id, style)
  }
  private func art(_ p: Project, _ id: UUID) -> Artwork { p.objects.first { $0.id == id }!.artwork! }

  func testAssignKeepsContentColorGeometryFrameBehaviorAndPairPositions() throws {
    var (p, sheet, text, style) = try fixture()
    var a = art(p, sheet)
    a.elements[0].typography?.frameMode = "point"
    a.elements[0].typography?.verticalAlignment = "middle"
    a.elements[0].typography?.pairKerning = [1: -2]
    let before = a.elements[0]
    try p.setArtwork(a, for: sheet)
    try TextStyleCommands.apply(in: &p, objectID: sheet, ids: [text], styleID: style)
    let value = art(p, sheet).elements[0]
    XCTAssertEqual(value.text, before.text); XCTAssertEqual(value.color, before.color)
    XCTAssertEqual(value.x, before.x); XCTAssertEqual(value.width, before.width)
    XCTAssertEqual(value.textStyle?.styleID, style)
    XCTAssertEqual(value.typography?.fontName, "Baskerville")
    XCTAssertEqual(value.typography?.leading, 26)
    XCTAssertEqual(value.typography?.frameMode, "point")
    XCTAssertEqual(value.typography?.verticalAlignment, "middle")
    XCTAssertEqual(value.typography?.pairKerning, [1: -2])
  }

  func testExplicitOverridesSurviveCoincidingStyleValuesAndLaterUpdates() throws {
    var (p, sheet, text, style) = try fixture()
    try TextStyleCommands.apply(in: &p, objectID: sheet, ids: [text], styleID: style)
    var a = art(p, sheet); a.elements[0].fontSize = 26
    try p.setArtwork(a, for: sheet)
    XCTAssertEqual(art(p, sheet).elements[0].textStyle?.overrides, ["fontSize"])
    var type = p.textStyles![0].typography; type.tracking = 1.5
    try TextStyleCommands.save(in: &p, id: style, name: "Body", typography: type, fontSize: 26)
    try TextStyleCommands.save(in: &p, id: style, name: "Body", typography: type, fontSize: 30)
    XCTAssertEqual(art(p, sheet).elements[0].fontSize, 26)
    XCTAssertEqual(art(p, sheet).elements[0].typography?.tracking, 1.5)
    try TextStyleCommands.apply(in: &p, objectID: sheet, ids: [text], mode: "reset")
    XCTAssertEqual(art(p, sheet).elements[0].fontSize, 30)
    XCTAssertEqual(art(p, sheet).elements[0].textStyle?.overrides, [])
  }

  func testRangeAssignmentAndResetPreserveOutsideSpansAndRejectSplitSurrogates() throws {
    var (p, sheet, text, style) = try fixture()
    let original = art(p, sheet).elements[0]
    try TextStyleCommands.apply(in: &p, objectID: sheet, ids: [text], styleID: style, location: 1, length: 2)
    let runs = art(p, sheet).elements[0].textRuns!
    XCTAssertEqual(runs.map(\.location), [0, 1, 3])
    XCTAssertEqual(runs.map(\.length), [1, 2, 6])
    XCTAssertNil(runs[0].textStyle); XCTAssertEqual(runs[1].textStyle?.styleID, style)
    XCTAssertNil(runs[2].textStyle)
    XCTAssertEqual(runs[0].typography, original.typography)
    let before = p
    XCTAssertThrowsError(try TextStyleCommands.apply(in: &p, objectID: sheet, ids: [text], styleID: style, location: 1, length: 1))
    XCTAssertEqual(p, before)
  }

  func testSwatchRangePreservesTheTextStyle() throws {
    var (p, sheet, text, style) = try fixture()
    try TextStyleCommands.apply(in: &p, objectID: sheet, ids: [text], styleID: style)
    let swatch = try SwatchCommands.save(in: &p, name: "Accent", color: "#D45A37")
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [text], target: "text_range", swatchID: swatch, location: 3, length: 1)
    XCTAssertTrue(art(p, sheet).elements[0].textRuns!.allSatisfy { $0.textStyle?.styleID == style })
    XCTAssertEqual(art(p, sheet).elements[0].textRuns?[1].swatchID, swatch)
    XCTAssertTrue(art(p, sheet).elements[0].textRuns!.allSatisfy { $0.textStyle?.overrides.isEmpty == true })
  }

  func testLinkedConsumersAndUnrelatedResourcesStayUnchangedOnStyleUpdate() throws {
    var (p, sheet, text, style) = try fixture()
    try TextStyleCommands.apply(in: &p, objectID: sheet, ids: [text], styleID: style)
    let box = try p.makeObject(recipeID: "box")
    let unrelated = try p.makeObject(recipeID: "lamp")
    p.objects += [box, unrelated]
    try p.linkArtwork(box.id, sourceID: sheet)
    let before = p.objects
    var type = p.textStyles![0].typography; type.leading = 30
    try TextStyleCommands.save(in: &p, id: style, name: "Body", typography: type, fontSize: 22)
    XCTAssertNotEqual(p.objects[0], before[0])
    XCTAssertEqual(p.objects[1], before[1]); XCTAssertEqual(p.objects[2], before[2])
    XCTAssertEqual(p.surfaceArtwork(p.objects[1])!.elements[0].fontSize, 22)
    let objects = p.objects
    try TextStyleCommands.save(in: &p, id: style, name: "Body / renamed", typography: type, fontSize: 22)
    XCTAssertEqual(p.objects, objects)
  }

  func testInvalidNamesReferencesAndPropertiesAreAtomic() throws {
    var (p, sheet, text, style) = try fixture()
    let before = p
    XCTAssertThrowsError(try TextStyleCommands.save(in: &p, name: " body ", typography: .init(), fontSize: 20))
    XCTAssertEqual(p, before)
    XCTAssertThrowsError(try TextStyleCommands.apply(in: &p, objectID: sheet, ids: [text], styleID: UUID()))
    XCTAssertEqual(p, before)
    try TextStyleCommands.apply(in: &p, objectID: sheet, ids: [text], styleID: style)
    p.objects[0].artwork!.elements[0].textStyle?.overrides = ["invalid"]
    XCTAssertThrowsError(try p.validateArtworkLinks())
    p.objects[0].artwork!.elements[0].textStyle = .init(styleID: UUID())
    XCTAssertThrowsError(try p.validateArtworkLinks())
  }

  func testEngineBatchUndoRedoAndSchemaTwelveRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root: root)
    let engine = OperationEngine(repository: repository)
    var (p, sheet, text, style) = try fixture()
    try TextStyleCommands.apply(in: &p, objectID: sheet, ids: [text], styleID: style)
    engine.project = p
    let update: [String: Any] = ["command": "update", "style_id": style.uuidString, "font_size": 28.0, "typography": ["tracking": 2.0]]
    try engine.call("form_text_style", arguments: update)
    XCTAssertEqual(art(engine.project!, sheet).elements[0].fontSize, 28)
    engine.undo(); XCTAssertEqual(engine.project, p)
    engine.redo(); XCTAssertEqual(art(engine.project!, sheet).elements[0].fontSize, 28)
    let before = engine.project
    XCTAssertThrowsError(try engine.call("form_batch", arguments: ["operations": [
      ["name":"form_text_style", "arguments": update],
      ["name":"form_text_style", "arguments": ["command":"delete", "style_id":UUID().uuidString]],
    ]]))
    XCTAssertEqual(engine.project, before)
    try engine.flush()
    let reopened = try repository.load(p.id)
    XCTAssertEqual(reopened.schemaVersion, 12)
    XCTAssertEqual(reopened.objects, engine.project!.objects)
    XCTAssertEqual(reopened.textStyles, engine.project!.textStyles)
  }

  func testDetachmentAndDeletionRetainIdenticalRenderedInk() async throws {
    try await MainActor.run {
      var (p, sheet, text, style) = try fixture()
      try TextStyleCommands.apply(in: &p, objectID: sheet, ids: [text], styleID: style)
      @MainActor func image(_ value: Project) -> Data {
        let art = value.surfaceArtwork(value.objects[0])!
        let im = ArtworkRenderer.image(art, width:150,height:100,assets:URL(fileURLWithPath:"/tmp"),pixelsPerMM:2)
        let rep = im.representations[0] as! NSBitmapImageRep
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow*rep.pixelsHigh)
      }
      let original = image(p)
      var detached = p
      try TextStyleCommands.apply(in: &detached, objectID: sheet, ids: [text], mode: "detach")
      XCTAssertEqual(image(detached), original)
      try TextStyleCommands.delete(in: &p, id: style)
      XCTAssertEqual(image(p), original)
      XCTAssertNil(art(p, sheet).elements[0].textStyle)
    }
  }

  func testNativeTextMetadataDoesNotInventOverridesForWordSpacingAndAxes() async throws {
    try await MainActor.run {
      var (p, sheet, text, style) = try fixture()
      var type = p.textStyles![0].typography
      type.fontName = "Skia"; type.wordSpacing = 2; type.variations = [2003265652:1.8,2003072104:1.12]
      try TextStyleCommands.save(in: &p, id: style, name: "Body", typography: type, fontSize:20)
      try TextStyleCommands.apply(in: &p, objectID: sheet, ids: [text], styleID: style)
      let e = art(p, sheet).elements[0]
      let attributed = TypographyEngine.attributed(e)
      let spans = TypographyEngine.spans(from: attributed, fallback: type)
      XCTAssertTrue(spans.allSatisfy { $0.textStyle == e.textStyle })
      XCTAssertTrue(spans.allSatisfy { $0.typography.tracking == type.tracking })
      var a = art(p, sheet); a.elements[0].textRuns = spans
      try p.setArtwork(a, for: sheet)
      XCTAssertEqual(art(p, sheet).elements[0].textRuns!.compactMap { $0.textStyle?.overrides }.filter { !$0.isEmpty }, [])
    }
  }

  func testNativeSpacingAndManualPairPositionsRoundTripWithoutTrackingDrift() async throws {
    await MainActor.run {
      var e = ArtworkElement(kind:"text",x:0,y:0,width:100,height:30,text:"A B AV",color:"#222222",fontSize:24)
      var type = Typography(); type.tracking = 0.5; type.wordSpacing = 2; type.pairKerning = [4:-1.5]
      e.typography = type
      let original = TypographyEngine.attributed(e)
      let originalInk = try? TypographyEngine.outlines(e)
      for _ in 0..<4 {
        e.textRuns = TypographyEngine.spans(from: TypographyEngine.attributed(e), fallback:type)
        XCTAssertTrue(e.textRuns!.allSatisfy { $0.typography.tracking == 0.5 })
        let after = TypographyEngine.attributed(e)
        for i in 0..<after.length {
          XCTAssertEqual(after.attribute(.kern,at:i,effectiveRange:nil) as? Double,
            original.attribute(.kern,at:i,effectiveRange:nil) as? Double)
        }
        XCTAssertEqual(try? TypographyEngine.outlines(e), originalInk)
      }
      let attrs = original.attributes(at:4,effectiveRange:nil)
      let inspected = TypographyEngine.spans(from:NSAttributedString(string:"A",attributes:attrs),fallback:type,utf16Offset:4)[0]
      XCTAssertEqual(inspected.typography.pairKerning, [4:-1.5])
    }
  }

  func testNativeUndoMetadataCanRestoreUnmodifiedStyleLinks() async throws {
    try await MainActor.run {
      var (p,sheet,text,style) = try fixture()
      try TextStyleCommands.apply(in:&p,objectID:sheet,ids:[text],styleID:style)
      let original = art(p,sheet).elements[0]
      let attributed = NSMutableAttributedString(attributedString:TypographyEngine.attributed(original))
      attributed.addAttribute(.font,value:TypographyEngine.font(original.typography!,size:30),range:NSRange(location:0,length:attributed.length))
      var a = art(p,sheet)
      a.elements[0].textRuns = TypographyEngine.spans(from:attributed,fallback:original.typography!)
      try p.setArtwork(a,for:sheet)
      XCTAssertEqual(art(p,sheet).elements[0].textRuns![0].textStyle?.overrides,["fontSize"])
      // Undo supplies the original attribute metadata, including its clean link.
      a = art(p,sheet)
      a.elements[0].textRuns = TypographyEngine.spans(from:TypographyEngine.attributed(original),fallback:original.typography!)
      try p.setArtwork(a,for:sheet)
      XCTAssertTrue(art(p,sheet).elements[0].textRuns!.allSatisfy { $0.textStyle?.overrides.isEmpty == true })
    }
  }

  func testCreateAndAssignAreOneUndoAndMalformedRangesDoNotApplyWholeText() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let engine = OperationEngine(repository:try ProjectRepository(root:root))
    let (p,sheet,text,_) = try fixture(); engine.project = p
    try engine.call("form_text_style",arguments:["command":"create","name":"Caption","font_size":9.0,
      "object_id":sheet.uuidString,"element_ids":[text.uuidString],"location":3,"length":1])
    XCTAssertEqual(engine.undoStack.count,1)
    XCTAssertEqual(art(engine.project!,sheet).elements[0].textRuns![1].fontSize,9)
    engine.undo(); XCTAssertEqual(engine.project,p)
    XCTAssertThrowsError(try engine.call("form_text_style",arguments:["command":"detach","object_id":sheet.uuidString,
      "element_ids":[text.uuidString],"location":"3","length":1]))
    XCTAssertEqual(engine.project,p)
  }
  func testPartialRangeStylePreservesItsParagraphAndWholeTextUsesTheStyleParagraph() throws {
    var (p,sheet,text,body) = try fixture()
    try TextStyleCommands.apply(in:&p,objectID:sheet,ids:[text],styleID:body)
    var caption = Typography(); caption.fontName = "Menlo-Regular"; caption.tracking = 0.8
    let style = try TextStyleCommands.save(in:&p,name:"Caption",typography:caption,fontSize:8)
    try TextStyleCommands.apply(in:&p,objectID:sheet,ids:[text],styleID:style,location:3,length:1)
    let selected = art(p,sheet).elements[0].textRuns![1]
    XCTAssertEqual(selected.typography.fontName,"Menlo-Regular")
    XCTAssertEqual(selected.typography.leading,26)
    XCTAssertEqual(selected.typography.paragraphAfter,8)
    XCTAssertEqual(selected.textStyle?.overrides,[])
    XCTAssertEqual(selected.textStyle?.characterOnly,true)
    XCTAssertEqual(selected.paragraphStyle?.styleID,body)
    var changed = p.textStyles!.first { $0.id == body }!.typography
    changed.leading = 30
    try TextStyleCommands.save(in:&p,id:body,name:"Body",typography:changed,fontSize:22)
    let inherited = art(p,sheet).elements[0].textRuns![1]
    XCTAssertEqual(inherited.fontSize,8)
    XCTAssertEqual(inherited.typography.leading,30)
    caption.leading = 99
    try TextStyleCommands.save(in:&p,id:style,name:"Caption",typography:caption,fontSize:9)
    XCTAssertEqual(art(p,sheet).elements[0].textRuns![1].fontSize,9)
    XCTAssertEqual(art(p,sheet).elements[0].textRuns![1].typography.leading,30)
    try TextStyleCommands.apply(in:&p,objectID:sheet,ids:[text],styleID:style,location:0,length:9)
    XCTAssertTrue(art(p,sheet).elements[0].textRuns!.allSatisfy { $0.typography.leading == 99 && $0.textStyle?.overrides.isEmpty == true })
  }
  func testResetHandlesIndependentParagraphOverridesAndStyleFilter() throws {
    var (p,sheet,text,body) = try fixture()
    try TextStyleCommands.apply(in:&p,objectID:sheet,ids:[text],styleID:body)
    let caption = try TextStyleCommands.save(in:&p,name:"Caption",typography:.init(),fontSize:8)
    try TextStyleCommands.apply(in:&p,objectID:sheet,ids:[text],styleID:caption,location:3,length:1)
    var a = art(p,sheet)
    a.elements[0].textRuns![1].fontSize = 11
    a.elements[0].textRuns![1].typography.leading = 19
    try p.setArtwork(a,for:sheet)
    XCTAssertEqual(art(p,sheet).elements[0].textRuns![1].paragraphStyle?.overrides,["leading"])
    try TextStyleCommands.apply(in:&p,objectID:sheet,ids:[text],styleID:caption,mode:"reset")
    let filtered = art(p,sheet).elements[0].textRuns![1]
    XCTAssertEqual(filtered.fontSize,8)
    XCTAssertEqual(filtered.typography.leading,19)
    XCTAssertEqual(filtered.paragraphStyle?.overrides,["leading"])
    let native = TextStyleCommands.resetting(filtered,
      styles:Dictionary(uniqueKeysWithValues:p.textStyles!.map { ($0.id,$0) }),preservingParagraphs:true)
    try TextStyleCommands.apply(in:&p,objectID:sheet,ids:[text],mode:"reset")
    let reset = art(p,sheet).elements[0].textRuns![1]
    XCTAssertEqual(reset,native)
    XCTAssertEqual(reset.fontSize,8)
    XCTAssertEqual(reset.typography.leading,26)
    XCTAssertEqual(reset.paragraphStyle?.styleID,body)
    XCTAssertEqual(reset.paragraphStyle?.overrides,[])
    XCTAssertEqual(reset.textStyle?.characterOnly,true)
    var detached = TextStyleCommands.applying(filtered,style:nil,detach:true,preservingParagraphs:true)
    detached = TextStyleCommands.resetting(detached,styles:Dictionary(uniqueKeysWithValues:p.textStyles!.map { ($0.id,$0) }))
    XCTAssertNil(detached.textStyle)
    XCTAssertEqual(detached.typography.leading,26)
    XCTAssertEqual(detached.paragraphStyle?.overrides,[])
  }
  func testRedefinitionClearsOnlyItsSourceOverrideInTheSameUndo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let engine = OperationEngine(repository:try ProjectRepository(root:root))
    var (p,sheet,text,style) = try fixture()
    try TextStyleCommands.apply(in:&p,objectID:sheet,ids:[text],styleID:style)
    var a = art(p,sheet);a.elements[0].fontSize=24
    try p.setArtwork(a,for:sheet);engine.project=p
    try engine.call("form_text_style",arguments:["command":"update","style_id":style.uuidString,"font_size":24.0,
      "reset_selection":true,"object_id":sheet.uuidString,"element_ids":[text.uuidString]])
    XCTAssertEqual(art(engine.project!,sheet).elements[0].textStyle?.overrides,[])
    XCTAssertEqual(engine.undoStack.count,1)
    engine.undo();XCTAssertEqual(engine.project,p)
  }
  func testDeletingCharacterStyleKeepsTheSeparateParagraphRelationship() throws {
    var (p,sheet,text,body) = try fixture()
    try TextStyleCommands.apply(in:&p,objectID:sheet,ids:[text],styleID:body)
    var type=Typography();type.fontName="Menlo-Regular"
    let caption=try TextStyleCommands.save(in:&p,name:"Caption",typography:type,fontSize:8)
    try TextStyleCommands.apply(in:&p,objectID:sheet,ids:[text],styleID:caption,location:3,length:1)
    try TextStyleCommands.delete(in:&p,id:caption)
    var paragraph=p.textStyles![0].typography;paragraph.leading=31
    try TextStyleCommands.save(in:&p,id:body,name:"Body",typography:paragraph,fontSize:25)
    let value=art(p,sheet).elements[0].textRuns![1]
    XCTAssertNil(value.textStyle)
    XCTAssertEqual(value.paragraphStyle?.styleID,body)
    XCTAssertEqual(value.fontSize,8)
    XCTAssertEqual(value.typography.leading,31)
  }
  func testStyledComponentSourcesUpdateConsumersWithoutRewritingInstances() throws {
    var (p,sheet,text,body)=try fixture()
    try TextStyleCommands.apply(in:&p,objectID:sheet,ids:[text],styleID:body)
    let source=try ComponentCommands.create(in:&p,objectID:sheet,elements:[text],name:"Styled copy")
    let before=p.objects.first { $0.id==sheet }!
    let initial=try p.resolvingComponents(in:before.artwork!).elements.first { $0.kind=="text" }!
    XCTAssertEqual(initial.fontSize,20)
    let type=p.textStyles![0].typography
    try TextStyleCommands.save(in:&p,id:body,name:"Body",typography:type,fontSize:25)
    XCTAssertEqual(p.objects.first { $0.id==sheet },before)
    XCTAssertEqual(p.objects.first { $0.id==source.source }!.artwork!.elements[0].fontSize,25)
    let updated=try p.resolvingComponents(in:before.artwork!).elements.first { $0.kind=="text" }!
    XCTAssertEqual(updated.fontSize,25)
  }
}

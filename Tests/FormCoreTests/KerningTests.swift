import AppKit
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

final class KerningTests: XCTestCase {
  @MainActor private func positions(_ attributed: NSAttributedString) -> [CGPoint] {
    let line = CTLineCreateWithAttributedString(attributed)
    return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run in
      var p = [CGPoint](repeating: .zero, count: CTRunGetGlyphCount(run))
      CTRunGetPositions(run, CFRange(), &p)
      return p
    }
  }
  private func text(_ mode: String? = nil, tracking: Double = 0) -> ArtworkElement {
    var e = ArtworkElement(kind:"text",x:0,y:0,width:180,height:40,text:"AVATAR",color:"#222222",fontSize:60)
    var t = Typography(); t.fontName = "Baskerville"; t.kerningMode = mode; t.tracking = tracking
    e.typography = t
    return e
  }
  func testActualFontMetricsAndTrackingAreIndependentFromDisabledKerning() async throws {
    await MainActor.run {
      let natural = positions(TypographyEngine.attributed(text("metrics")))
      let none = positions(TypographyEngine.attributed(text("none")))
      let legacy = positions(TypographyEngine.attributed(text()))
      XCTAssertEqual(natural.count,6); XCTAssertEqual(none.count,6)
      XCTAssertLessThan(natural[1].x,none[1].x-3)
      XCTAssertEqual(legacy,none)
      for mode in ["metrics","none"] {
        let base = positions(TypographyEngine.attributed(text(mode)))
        let tracked = positions(TypographyEngine.attributed(text(mode,tracking:2)))
        for i in base.indices { XCTAssertEqual(tracked[i].x,base[i].x+Double(i)*2,accuracy:1e-7) }
      }
      let mm = positions(TypographyEngine.attributed(text("metrics",tracking:2),millimeters:true))
      let pt = positions(TypographyEngine.attributed(text("metrics",tracking:2)))
      for i in pt.indices { XCTAssertEqual(mm[i].x*TypographyEngine.pointsPerMM,pt[i].x,accuracy:1e-5) }
    }
  }
  func testManualPairZeroDoesNotDisableMetricsAndPairDeltasDoNotChangeTracking() async throws {
    await MainActor.run {
      let e = text("metrics",tracking:0.5)
      let original = TypographyEngine.attributed(e)
      let edited = NSMutableAttributedString(attributedString:original)
      TypographyEngine.setManualPair(-2,at:0,in:edited)
      let base = positions(original), changed = positions(edited)
      XCTAssertEqual(changed[0],base[0])
      for i in 1..<base.count { XCTAssertEqual(changed[i].x,base[i].x-2,accuracy:1e-7) }
      let span = TypographyEngine.spans(from:edited,fallback:e.typography!)[0]
      XCTAssertEqual(span.typography.tracking,0.5)
      XCTAssertEqual(span.typography.pairKerning,[0:-2])
      XCTAssertEqual(span.typography.kerningMode,"metrics")
      TypographyEngine.setManualPair(0,at:0,in:edited)
      XCTAssertEqual(positions(edited),base)
      XCTAssertNil(edited.attribute(.kern,at:0,effectiveRange:nil))
      let disabled = NSMutableAttributedString(attributedString:TypographyEngine.attributed(text("none")))
      TypographyEngine.setManualPair(-2,at:0,in:disabled)
      XCTAssertEqual(disabled.attribute(.kern,at:0,effectiveRange:nil) as? Double,0)
      var spaced=e;spaced.text="A V";spaced.typography!.wordSpacing=2
      spaced.typography!.pairKerning=[1:-0.5]
      let combined=NSMutableAttributedString(attributedString:TypographyEngine.attributed(spaced))
      XCTAssertEqual(combined.attribute(.tracking,at:1,effectiveRange:nil) as? Double,2)
      let restored=TypographyEngine.spans(from:combined,fallback:spaced.typography!)
      XCTAssertTrue(restored.allSatisfy { $0.typography.tracking==0.5 && $0.typography.wordSpacing==2 })
      TypographyEngine.setManualPair(0,at:1,in:combined)
      XCTAssertEqual(combined.attribute(.tracking,at:1,effectiveRange:nil) as? Double,2.5)
    }
  }
  func testMixedModesWordSpacingFeaturesAndOutlinesSurviveRepeatedNativeRoundTrips() async throws {
    try await MainActor.run {
      var e = text("metrics",tracking:0.5); e.text = "AV AV fi"
      e.typography!.wordSpacing = 2
      e.typography!.setIndependentFeature(1,selector:2,value:true)
      var plain = e.typography!; plain.kerningMode = "none"
      e.textRuns = [.init(location:3,length:2,typography:plain,fontSize:60,color:"#AA3300")]
      let original = TypographyEngine.attributed(e)
      let p = positions(original), ink = try TypographyEngine.outlines(e)
      for _ in 0..<4 {
        e.textRuns = TypographyEngine.spans(from:TypographyEngine.attributed(e),fallback:e.typography!)
        XCTAssertEqual(e.textRuns!.first { $0.location==3 }?.typography.kerningMode,"none")
        XCTAssertTrue(e.textRuns!.allSatisfy { $0.typography.tracking==0.5 && $0.typography.wordSpacing==2 })
        XCTAssertEqual(positions(TypographyEngine.attributed(e)),p)
        XCTAssertEqual(try TypographyEngine.outlines(e),ink)
      }
      let without = text("metrics")
      let raw = TypographyEngine.attributed(without).attributes(at:0,effectiveRange:nil)
      var foreign = raw
      foreign.removeValue(forKey:NSAttributedString.Key("studio.form.typography"))
      let detected = TypographyEngine.spans(from:NSAttributedString(string:"AV",attributes:foreign),fallback:.init())[0]
      XCTAssertEqual(detected.typography.kerningMode,"metrics")
    }
  }
  func testLegacyDecodingAndSpacingRemainExactAndInvalidModesReject() async throws {
    let old = try JSONDecoder.form.decode(Typography.self,from:Data("{\"tracking\":0.5,\"wordSpacing\":2,\"pairKerning\":{\"1\":-1}}".utf8))
    XCTAssertNil(old.kerningMode)
    XCTAssertNil((try jsonObject(old) as! [String:Any])["kerningMode"])
    await MainActor.run {
      var e = text();e.text="A V";e.typography=old
      let a=TypographyEngine.attributed(e)
      XCTAssertEqual(a.attribute(.kern,at:0,effectiveRange:nil) as? Double,0.5)
      XCTAssertEqual(a.attribute(.kern,at:1,effectiveRange:nil) as? Double,-0.5)
      XCTAssertNil(a.attribute(.tracking,at:0,effectiveRange:nil))
    }
    for mode in ["auto","optical","", "METRICS"] {
      var t = old;t.kerningMode=mode;XCTAssertThrowsError(try validateTypography(t))
    }
  }
  func testStyleInheritancePersistentOverrideResetAndAtomicRollback() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    var p=Project(name:"Spacing");var o=try p.makeObject(recipeID:"artboard")
    let e=text("metrics");o.artwork = .init(elements:[e]);p.objects=[o]
    let style=try TextStyleCommands.save(in:&p,name:"Wordmark",typography:e.typography!,fontSize:60)
    try TextStyleCommands.apply(in:&p,objectID:o.id,ids:[e.id],styleID:style)
    var a=p.objects[0].artwork!;a.elements[0].typography!.kerningMode="none"
    try p.setArtwork(a,for:o.id)
    XCTAssertEqual(p.objects[0].artwork!.elements[0].textStyle?.overrides,["kerningMode"])
    try TextStyleCommands.save(in:&p,id:style,name:"Wordmark",typography:Typography(),fontSize:60)
    XCTAssertEqual(p.objects[0].artwork!.elements[0].typography?.kerningMode,"none")
    try TextStyleCommands.apply(in:&p,objectID:o.id,ids:[e.id],mode:"reset")
    XCTAssertNil(p.objects[0].artwork!.elements[0].typography?.kerningMode)
    engine.project=p
    XCTAssertThrowsError(try engine.call("form_batch",arguments:["operations":[
      ["name":"form_text_style","arguments":["command":"update","style_id":style.uuidString,"typography":["kerningMode":"metrics"]]],
      ["name":"form_text_style","arguments":["command":"update","style_id":style.uuidString,"typography":["kerningMode":"optical"]]],
    ]]))
    XCTAssertEqual(engine.project,p);XCTAssertTrue(engine.undoStack.isEmpty)
  }
  func testSchemaThirteenIncludesRichSpansAndUnusedStyleDefinitions() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let repo=try ProjectRepository(root:root)
    var p=Project(name:"Kerning");var o=try p.makeObject(recipeID:"artboard");var e=text()
    o.artwork = .init(elements:[e]);p.objects=[o]
    try repo.save(p);XCTAssertEqual(try repo.load(p.id).schemaVersion,2)
    e.textRuns=[.init(location:0,length:2,typography:text("metrics").typography!,fontSize:60,color:e.color)]
    p.objects[0].artwork!.elements=[e];try repo.save(p)
    let loaded=try repo.load(p.id);XCTAssertEqual(loaded.schemaVersion,13)
    XCTAssertEqual(loaded.objects,p.objects)
    p.objects=[];p.textStyles=[.init(name:"Unused",typography:text("none").typography!)]
    XCTAssertEqual(p.minimumSchemaVersion,13)
    try repo.save(p);XCTAssertEqual(try repo.load(p.id).textStyles,p.textStyles)
  }
  func testSVGInheritsKerningModesAndExportsExplicitLiveText() async throws {
    try await MainActor.run {
      let svg=Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="160mm" height="100mm" viewBox="0 0 160 100">
        <g font-family="Baskerville" font-size="20" font-kerning="none">
        <text x="10" y="20">AV</text><text x="10" y="45" font-kerning="normal" letter-spacing="1">AV</text>
        <text x="10" y="70" font-kerning="auto">AV</text></g></svg>
        """.utf8)
      let result=try SVGImporter.read(svg)
      XCTAssertFalse(result.hasWarnings)
      let texts=result.artwork.elements.filter { $0.kind=="text" }
      XCTAssertEqual(texts.map { $0.typography?.kerningMode },["none","metrics","metrics"])
      let live=try SVGRenderer.document(result.artwork,width:160,height:100,assets:URL(fileURLWithPath:"/tmp"),outlineText:false)
      XCTAssertTrue(live.contains("font-kerning=\"none\""));XCTAssertTrue(live.contains("font-kerning=\"normal\""))
      let outlined=try SVGRenderer.document(result.artwork,width:160,height:100,assets:URL(fileURLWithPath:"/tmp"),outlineText:true)
      XCTAssertFalse(outlined.contains("<text "));XCTAssertTrue(outlined.contains("<path"))
    }
  }
  func testChangingModeRebuildsLayoutButPlacementReusesIt() async throws {
    await MainActor.run {
      var e=text("none")
      let before=TypographyEngine.diagnostics["layout_builds"] as! Int
      _=TypographyEngine.measured(e)
      XCTAssertEqual(TypographyEngine.diagnostics["layout_builds"] as! Int,before+1)
      e.typography!.kerningMode="metrics";_=TypographyEngine.measured(e)
      XCTAssertEqual(TypographyEngine.diagnostics["layout_builds"] as! Int,before+2)
      e.x=50;_=TypographyEngine.measured(e)
      XCTAssertEqual(TypographyEngine.diagnostics["layout_builds"] as! Int,before+2)
    }
  }
}

import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class NativeTextPaintTests: XCTestCase {
  private let assets = URL(fileURLWithPath: "/tmp")
  private func gradient() -> ArtworkPaintLayer {
    .init(.init(kind: "gradient", gradient: .init(kind: "linear", start: .init(0, 0), end: .init(1, 0),
      stops: [.init(0, "#FF0000"), .init(1, "#0000FF")])))
  }
  private func text(_ content: String = "MMMM") -> ArtworkElement {
    var e = ArtworkElement(kind: "text", x: 4, y: 3, width: 75, height: 30, text: content, color: "#000000", fontSize: 60)
    var type = Typography(); type.fontName = "Helvetica"; e.typography = type
    return e
  }
  private func bitmap(_ e: ArtworkElement) -> NSBitmapImageRep {
    var art = Artwork(elements: [e], bleed: 0); art.backgroundOpacity = 0
    return ArtworkRenderer.image(art, width: 84, height: 40, assets: assets, pixelsPerMM: 4).representations[0] as! NSBitmapImageRep
  }
  private func ink(_ bitmap: NSBitmapImageRep) -> [(Int, Int, NSColor)] {
    var pixels: [(Int, Int, NSColor)] = []
    for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
      if let c = bitmap.colorAt(x: x, y: y), c.alphaComponent > 0.25 { pixels.append((x, y, c)) }
    } }
    return pixels
  }
  func testGradientUsesActualGlyphCoverageAndRetainsEditableText() throws {
    var e = text(); e.paintStack = [gradient()]
    try validateArtwork(.init(elements: [e]))
    let pixels = ink(bitmap(e)); XCTAssertGreaterThan(pixels.count, 1000)
    let left = pixels.filter { $0.0 < 70 }, right = pixels.filter { $0.0 > 200 }
    XCTAssertFalse(left.isEmpty); XCTAssertFalse(right.isEmpty)
    XCTAssertGreaterThan(left.map { $0.2.redComponent }.reduce(0,+)/Double(max(1,left.count)), 0.65)
    XCTAssertGreaterThan(right.map { $0.2.blueComponent }.reduce(0,+)/Double(max(1,right.count)), 0.55)
    XCTAssertEqual(e.kind, "text"); XCTAssertNil(e.path); XCTAssertEqual(e.text, "MMMM")
    XCTAssertEqual(try JSONDecoder.form.decode(ArtworkElement.self, from: JSONEncoder.form.encode(e)), e)
    let layers = try TextPaintRenderer.vectorLayers(e)
    XCTAssertEqual(layers.count, 1); XCTAssertFalse(layers[0].0.isEmpty); XCTAssertEqual(layers[0].1.kind, "gradient")
  }
  func testOrderedOpacityStackAndStrokeOnlyCoverageHaveRealPixels() throws {
    var e = text("MM")
    e.paintStack = [.init(.init(color: "#FF0000", opacity: 0.5)), .init(.init(color: "#0000FF", opacity: 0.5))]
    let pixels = ink(bitmap(e)); let solid = try XCTUnwrap(pixels.max { $0.2.alphaComponent < $1.2.alphaComponent }?.2)
    XCTAssertEqual(solid.alphaComponent, 0.75, accuracy: 0.02)
    XCTAssertGreaterThan(solid.blueComponent, solid.redComponent)
    var stroke = ArtworkStroke(color: "#00FF00", width: 1); stroke.alignment = "outside"
    e.paintStack = [.init(.init(color: "#00FF00"), stroke: stroke)]; e.fillEnabled = false
    let outline = ink(bitmap(e)); XCTAssertGreaterThan(outline.count, 100)
    XCTAssertTrue(outline.allSatisfy { $0.2.greenComponent > 0.9 })
    let layers = try TextPaintRenderer.vectorLayers(e); XCTAssertEqual(layers.count, 1)
    XCTAssertGreaterThan(layers[0].0.boundingBoxOfPath.width, 0)
  }
  func testNativeAttributedEditsRetainPaintAndRecolorOnlyChangedRange() throws {
    var e = text("A😀אב"); e.paintStack = [gradient()]
    var span = TextSpan(location: 1, length: 2, typography: e.typography!, fontSize: 30, color: "#000000")
    span.paintStack = [.init(.init(color: "#00FF00", opacity: 0.4))]; e.textRuns = [span]
    let native = TypographyEngine.sourceAttributed(e)
    native.addAttribute(.font, value: NSFont(name: "Helvetica-Bold", size: 28)!, range: NSRange(location: 1, length: 2))
    let beforeColor = TypographyEngine.spans(from: native, fallback: e.typography!)
    XCTAssertEqual(beforeColor.first { $0.location == 1 }?.paintStack, span.paintStack)
    native.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 3, length: 2))
    let edited = TypographyEngine.spans(from: native, fallback: e.typography!)
    let rtl = try XCTUnwrap(edited.first { $0.location == 3 })
    XCTAssertEqual(rtl.length, 2); XCTAssertEqual(rtl.paintStack?.first?.paint.kind, "solid")
    XCTAssertEqual(rtl.paintStack?.first?.paint.color, "#FF0000")
    XCTAssertNil(edited.first { $0.location == 0 }?.paintStack, "Unedited inherited paint should stay inherited")
    XCTAssertEqual(native.string, e.text)
  }
  func testWholeTextRecolorRetainsStrokeOpacityAndGradientStopSwatchesResolve() throws {
    var e = text(); var stroke = ArtworkStroke(color: "#112233", width: 0.6)
    let id = UUID(); stroke.swatchID = id
    var fill = gradient(); fill.paint.gradient!.stops[0].swatchID = id
    e.paintStack = [fill, .init(.init(color: "#112233", opacity: 0.7), stroke: stroke)]
    var project = Project(name: "Paint swatches"); var swatch = ArtworkSwatch(name: "Ink", color: "#22AA44"); swatch.id = id; project.swatches = [swatch]
    let art = Artwork(elements: [e]); XCTAssertEqual(art.referencedSwatches, [id])
    let resolved = project.resolvingSwatches(in: art).elements[0]
    XCTAssertEqual(resolved.paintStack?[0].paint.gradient?.stops[0].color, "#22AA44")
    XCTAssertEqual(resolved.paintStack?[1].paint.color, "#22AA44")
    XCTAssertTrue(Artwork(elements: [resolved]).referencedSwatches.isEmpty)
    e.recolorTextFill("#FF00FF")
    XCTAssertEqual(e.paintStack?[0].paint.kind, "solid"); XCTAssertEqual(e.paintStack?[0].paint.color, "#FF00FF")
    XCTAssertEqual(e.paintStack?[1].paint.opacity, 0.7); XCTAssertEqual(e.paintStack?[1].stroke, stroke)
  }
  func testColorFontPaintUsesLiveCoverageAndVectorExportRejectsUnavailableOutlines() throws {
    var e = text("😀"); e.typography?.fontName = "AppleColorEmoji"
    let plain = ink(bitmap(e)); e.paintStack = [gradient()]
    let painted = ink(bitmap(e)); XCTAssertGreaterThan(painted.count, 100)
    XCTAssertEqual(Double(painted.map { $0.1 }.min() ?? -100), Double(plain.map { $0.1 }.min() ?? 100), accuracy: 2)
    XCTAssertEqual(Double(painted.map { $0.1 }.max() ?? -100), Double(plain.map { $0.1 }.max() ?? 100), accuracy: 2)
    XCTAssertThrowsError(try TextPaintRenderer.vectorLayers(e))
    XCTAssertEqual(e.text, "😀"); XCTAssertNil(e.path)
  }
  func testParagraphLayoutCanRenderRichPaintWithoutLosingText() throws {
    var e = text("Colorful paragraph words"); e.fontSize = 24; e.typography?.hyphenation = 1
    e.paintStack = [gradient()]
    XCTAssertGreaterThan(ink(bitmap(e)).count, 100)
    XCTAssertFalse(try TextPaintRenderer.vectorLayers(e).isEmpty)
  }
  func testNativeTextStrokeOpacityAffectsPixelsAndVectorPaintOnce()throws {
    var e=text("MM"),stroke=ArtworkStroke(color:"#00FF00",width:1)
    stroke.opacity=0.4;e.paintStack=[.init(.init(color:"#00FF00",opacity:0.5),stroke:stroke)]
    let layers=try TextPaintRenderer.vectorLayers(e)
    XCTAssertEqual(layers.first?.1.opacity ?? -1,0.2,accuracy:1e-9)
    let rep=bitmap(e);var maximum=0.0
    for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide {maximum=max(maximum,Double(rep.colorAt(x:x,y:y)?.alphaComponent ?? 0))}}
    XCTAssertEqual(maximum,0.2,accuracy:0.015)
    e.paintStack![0].stroke!.opacity=0
    XCTAssertTrue(try TextPaintRenderer.vectorLayers(e).isEmpty)
  }

}

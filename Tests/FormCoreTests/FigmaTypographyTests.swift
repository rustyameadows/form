import XCTest
import FormGraphics
@testable import FormCore

final class FigmaTypographyTests: XCTestCase {
  private func font(_ family: String = "Helvetica", _ style: String = "Regular", _ postscript: String = "Helvetica") -> FigmaValue {
    .object(["family": .string(family), "style": .string(style), "postscript": .string(postscript)])
  }
  private func spacing(_ value: Double, _ units: String) -> FigmaValue {
    .object(["value": .double(value), "units": .string(units)])
  }
  private func node(_ text: String, values: [String: FigmaValue] = [:], data: [String: FigmaValue] = [:]) -> FigmaValue {
    var textData = data; textData["characters"] = .string(text)
    var value: [String: FigmaValue] = ["fontName": font(), "fontSize": .double(16), "textData": .object(textData),
      "guid": .object(["sessionID": .uint(3), "localID": .uint(7)])]
    value.merge(values) { _, new in new }; return .object(value)
  }
  private func element() -> ArtworkElement {
    var e = ArtworkElement(kind: "text", x: 30, y: 40, width: 80, height: 30)
    e.affine = .init(a: 1, b: 0.2, c: 0.1, d: 1, tx: 5, ty: 6)
    return e
  }

  func testNativePixelMetricsConvertOnceAndKeepTopLeftFrameAndSourceCharacters() throws {
    var e = element(); let before = e
    let source = node("Mixed case", values: ["lineHeight": spacing(24, "PIXELS"),
      "letterSpacing": spacing(2, "PIXELS"), "paragraphSpacing": .double(8), "paragraphIndent": .double(4),
      "textAlignHorizontal": .string("JUSTIFIED"), "textAlignVertical": .string("CENTER"), "textCase": .string("UPPER")])
    _ = try FigmaTypography.apply(node: source, to: &e)
    XCTAssertEqual(e.fontSize, 12, accuracy: 1e-10)
    XCTAssertEqual(e.typography?.fontName, "Helvetica")
    XCTAssertEqual(e.typography?.leading, 18)
    XCTAssertEqual(e.typography?.tracking, 1.5)
    XCTAssertEqual(e.typography?.paragraphAfter, 6)
    XCTAssertEqual(e.typography?.firstLineIndent, 3)
    XCTAssertEqual(e.typography?.alignment, "justified")
    XCTAssertEqual(e.typography?.verticalAlignment, "middle")
    XCTAssertEqual(e.typography?.caseTreatment, "uppercase")
    XCTAssertEqual(e.text, "Mixed case", "Case treatment must not rewrite source characters or their offsets")
    XCTAssertEqual(e.x, before.x); XCTAssertEqual(e.y, before.y)
    XCTAssertEqual(e.width, before.width); XCTAssertEqual(e.height, before.height); XCTAssertEqual(e.affine, before.affine)
    try validateTypography(XCTUnwrap(e.typography))
  }

  func testAutoAndRelativeLeadingAreDistinctAndMixedFontSizesResolveRelativeMetrics() throws {
    var e = element()
    _ = try FigmaTypography.apply(node: node("auto", values: ["lineHeight": spacing(100, "PERCENT")]), to: &e)
    XCTAssertEqual(e.typography?.leading, 0, "Native 100 percent is the automatic-leading sentinel")
    let override: FigmaValue = .object(["styleID": .uint(5), "fontSize": .double(32), "textDecoration": .string("UNDERLINE")])
    let source = node("ab", values: ["lineHeight": spacing(1.5, "RAW"), "letterSpacing": spacing(10, "PERCENT")],
      data: ["characterStyleIDs": .array([.uint(0), .uint(5)]), "styleOverrideTable": .array([override])])
    _ = try FigmaTypography.apply(node: source, to: &e)
    let runs = try XCTUnwrap(e.textRuns)
    XCTAssertEqual(runs.map(\.fontSize), [12, 24])
    XCTAssertEqual(runs.map { $0.typography.leading }, [18, 36])
    XCTAssertEqual(runs[0].typography.tracking, 1.2, accuracy: 1e-10)
    XCTAssertEqual(runs[1].typography.tracking, 2.4, accuracy: 1e-10)
    XCTAssertTrue(runs[1].typography.underline)
  }

  func testEmojiAndRTLParagraphOverridesUseUTF16RangesWithoutShiftingText() throws {
    let text = "A😀\nאב"
    let emphasis: FigmaValue = .object(["styleID": .uint(2), "fontName": font("Helvetica", "Bold", "Helvetica-Bold"),
      "fillPaints": .array([.object(["type": .string("SOLID"), "color": .object(["r": .double(1), "g": .double(0), "b": .double(0)])])])])
    let paragraph: FigmaValue = .object(["styleID": .uint(9), "paragraphSpacing": .double(12), "textAlignHorizontal": .string("RIGHT")])
    var e = element()
    _ = try FigmaTypography.apply(node: node(text, data: ["characterStyleIDs": .array([.uint(0), .uint(2), .uint(2)]),
      "styleOverrideTable": .array([emphasis, paragraph]), "lines": .array([
        .object(["lineType": .string("PLAIN"), "sourceDirectionality": .string("AUTO")]),
        .object(["lineType": .string("PLAIN"), "sourceDirectionality": .string("RTL"), "styleId": .uint(9)])])]), to: &e)
    XCTAssertEqual(e.text, text)
    let runs = try XCTUnwrap(e.textRuns)
    let emoji = try XCTUnwrap(runs.first { $0.location == 1 })
    XCTAssertEqual(emoji.length, 2); XCTAssertEqual(emoji.typography.fontName, "Helvetica-Bold"); XCTAssertEqual(emoji.color, "#FF0000")
    let rtl = try XCTUnwrap(runs.first { $0.location == 4 })
    XCTAssertEqual(rtl.length, 2); XCTAssertEqual(rtl.typography.direction, "rtl")
    XCTAssertEqual(rtl.typography.alignment, "right"); XCTAssertEqual(rtl.typography.paragraphAfter, 9)
    XCTAssertEqual(runs.reduce(0) { $0 + $1.length }, text.utf16.count)
  }

  func testMissingFontAndUnsupportedLayoutRemainEditableAndProduceSpecificIssues() throws {
    var e = element()
    let source = node("אב\ntext", values: ["fontName": font("LABDefinitelyMissingFamily", "Semibold", "LABDefinitelyMissingFamily-Semibold"),
      "textAutoResize": .string("HEIGHT"), "textCase": .string("TITLE"), "maxLines": .int(2),
      "textTruncation": .string("ENDING"), "leadingTrim": .string("CAP_HEIGHT"),
      "textDecorationStyle": .string("WAVY")], data: ["glyphs": .array([.object(["firstCharacter": .uint(0)])]),
      "lines": .array([.object(["lineType": .string("ORDERED_LIST"), "indentationLevel": .int(1)])])])
    let issues = try FigmaTypography.apply(node: source, to: &e)
    XCTAssertEqual(e.kind, "text"); XCTAssertEqual(e.text, "אב\ntext")
    XCTAssertEqual(e.typography?.fontName, "LABDefinitelyMissingFamily-Semibold")
    XCTAssertEqual(e.typography?.frameMode, "area")
    XCTAssertNil(e.path)
    for feature in ["missingFont", "textAutoResize", "textCase", "maxLines", "textTruncation", "leadingTrim", "textDecorationStyle", "paragraphList", "textLayout"] {
      XCTAssertTrue(issues.contains { $0.feature == feature }, "Missing diagnostic for \(feature)")
    }
  }

  func testVariationAxesAndIndependentFeaturesRetainPerRangeOverrides() throws {
    let weight = Int(UInt32(0x77676874))
    let override: FigmaValue = .object(["styleID": .uint(1), "fontVariations": .array([
      .object(["axisTag": .uint(UInt64(weight)), "value": .double(650)])]), "toggledOffOTFeatures": .array([.string("LIGA")])])
    var e = element()
    let issues = try FigmaTypography.apply(node: node("ab", values: ["fontVariantNumericSpacing": .string("TABULAR"),
      "toggledOnOTFeatures": .array([.string("DLIG"), .string("HLIG"), .string("UNVERIFIED")])],
      data: ["styleOverrideTable": .array([override]), "characterStyleIDs": .array([.uint(0), .uint(1)])]), to: &e)
    let runs = try XCTUnwrap(e.textRuns)
    XCTAssertEqual(runs[1].typography.variations[weight], 650)
    XCTAssertEqual(runs[0].typography.features[6], 0)
    XCTAssertEqual(runs[1].typography.independentFeature(1, selector: 2), false)
    XCTAssertEqual(runs[1].typography.independentFeature(1, selector: 4), true)
    XCTAssertEqual(runs[1].typography.independentFeature(1, selector: 20), true)
    XCTAssertTrue(issues.contains { $0.feature == "fontFeature" && $0.message.contains("UNVERIFIED") })
  }

  func testSourceBaselinesAreNotMisinterpretedAsFrameOriginsAndSizingModesStayExplicit() throws {
    var e = element(); let original = e
    let issues = try FigmaTypography.apply(node: node("A", values: ["textAutoResize": .string("WIDTH_AND_HEIGHT")],
      data: ["baselines": .array([.object(["position": .object(["x": .double(0), "y": .double(15)]), "firstCharacter": .uint(0), "endCharacter": .uint(1)])]),
        "glyphs": .array([.object(["firstCharacter": .uint(0), "position": .object(["x": .double(0), "y": .double(15)])])])]), to: &e)
    XCTAssertEqual(e.typography?.frameMode, "point")
    XCTAssertEqual(e.typography?.baseline, 0)
    XCTAssertEqual(e.fontSize, 12, accuracy: 1e-10)
    XCTAssertEqual(e.x, original.x); XCTAssertEqual(e.y, original.y); XCTAssertEqual(e.affine, original.affine)
    XCTAssertTrue(issues.contains { $0.feature == "textLayout" })
  }

  func testInvalidStylesRejectAtomicallyIncludingSurrogateSplitsAndNonfiniteValues() throws {
    let bad: [FigmaValue] = [
      node("😀", data: ["characterStyleIDs": .array([.uint(0), .uint(1)]), "styleOverrideTable": .array([.object(["styleID": .uint(1), "fontSize": .double(24)])])]),
      node("a", data: ["characterStyleIDs": .array([.uint(99)])]),
      node("a", data: ["characterStyleIDs": .array([.uint(0), .uint(0)])]),
      node("a", values: ["fontSize": .double(.infinity)]),
      node("a", values: ["letterSpacing": spacing(.nan, "PIXELS")]),
      node("a", data: ["styleOverrideTable": .array([.object(["styleID": .uint(1)]), .object(["styleID": .uint(1)])])])]
    for source in bad {
      var e = element(); let before = e
      XCTAssertThrowsError(try FigmaTypography.apply(node: source, to: &e))
      XCTAssertEqual(e, before)
    }
  }

  func testUnknownEnumsDiagnoseAndOriginalCaseClearsInheritedSmallCaps() throws {
    var e = element()
    let source = node("ab", values: ["textCase": .string("SMALL_CAPS_FORCED"), "textAutoResize": .uint(999)],
      data: ["characterStyleIDs": .array([.uint(0), .uint(1)]), "styleOverrideTable": .array([
        .object(["styleID": .uint(1), "textCase": .string("ORIGINAL"), "textAlignVertical": .uint(999)])])])
    let issues = try FigmaTypography.apply(node: source, to: &e)
    XCTAssertTrue(issues.contains { $0.feature == "textAutoResize" })
    XCTAssertTrue(issues.contains { $0.feature == "textAlignVertical" })
    let runs = try XCTUnwrap(e.textRuns)
    XCTAssertEqual(runs[0].typography.features[37], 1); XCTAssertEqual(runs[0].typography.features[38], 1)
    XCTAssertNil(runs[1].typography.features[37]); XCTAssertNil(runs[1].typography.features[38])
  }
  func testIdenticalRichPaintsReuseOneNativeGradientDespiteStyleOverrides() throws {
    var e = element(); var conversions = 0
    let fill: FigmaValue = .array([.object(["type": .string("GRADIENT_LINEAR")])])
    let source = node("ab", values: ["fillPaints": fill], data: ["characterStyleIDs": .array([.uint(0), .uint(1)]),
      "styleOverrideTable": .array([.object(["styleID": .uint(1), "fontSize": .double(20), "fillPaints": fill])])])
    _ = try FigmaTypography.apply(node: source, to: &e, paints: { _ in
      conversions += 1
      return [.init(.init(kind: "gradient", gradient: .init(kind: "linear", start: .init(0,0), end: .init(1,0),
        stops: [.init(0,"#FF0000"),.init(1,"#0000FF")])))]
    })
    XCTAssertEqual(conversions, 1)
    XCTAssertEqual(e.paintStack?.first?.paint.kind, "gradient")
    XCTAssertTrue((e.textRuns ?? []).allSatisfy { $0.paintStack == nil })
  }

  func testConversionIsAvailableOffMainActorAndCancellationDoesNotPublishPartialText() async throws {
    let source = node("background text")
    let output = try await Task.detached { () -> ArtworkElement in
      var element = ArtworkElement(kind: "text", x: 0, y: 0, width: 50, height: 20)
      _ = try FigmaTypography.apply(node: source, to: &element)
      return element
    }.value
    XCTAssertEqual(output.text, "background text")
    let cancelledWithoutMutation = await Task.detached { () -> Bool in
      var element = ArtworkElement(kind: "text", x: 0, y: 0, width: 50, height: 20)
      let before = element
      withUnsafeCurrentTask { $0?.cancel() }
      do { _ = try FigmaTypography.apply(node: source, to: &element); return false }
      catch is CancellationError { return element == before }
      catch { return false }
    }.value
    XCTAssertTrue(cancelledWithoutMutation)
  }
}

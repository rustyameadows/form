import AppKit
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

final class TypographyFeatureTests: XCTestCase {
  func testIndependentSelectorsMigrateLegacyAndKeepOtherPairs() throws {
    var type = Typography()
    type.features = [1: 3, 21: 1]
    type.setIndependentFeature(1, selector: 4, value: true)
    XCTAssertNil(type.features[1])
    XCTAssertEqual(type.featureSelections?[1], [3, 4])
    XCTAssertEqual(type.features[21], 1)
    XCTAssertEqual(type.independentFeature(1, selector: 2), false)
    XCTAssertEqual(type.independentFeature(1, selector: 4), true)
    XCTAssertNil(type.independentFeature(1, selector: 20))
    type.setIndependentFeature(1, selector: 2, value: true)
    XCTAssertEqual(type.featureSelections?[1], [2, 4])
    type.setIndependentFeature(1, selector: 4, value: nil)
    XCTAssertEqual(type.featureSelections?[1], [2])
    type.resetFeature(1)
    XCTAssertNil(type.featureSelections)
    XCTAssertEqual(type.features, [21: 1])
    try validateTypography(type)
  }

  func testInvalidConflictingAndUnboundedSelectorsAreRejected() throws {
    for values in [[2, 3], [4, 4], [-1], [65536], []] {
      var type = Typography(); type.featureSelections = [1: values]
      XCTAssertThrowsError(try validateTypography(type))
    }
    var type = Typography(); type.features = [-1: 2]
    XCTAssertThrowsError(try validateTypography(type))
    type.features = [1: 65536]
    XCTAssertThrowsError(try validateTypography(type))
    type.features = [:]
    type.featureSelections = [1: Array(stride(from: 0, to: 514, by: 2))]
    XCTAssertThrowsError(try validateTypography(type))
  }

  func testDescriptorAndNativeSpansRetainSimultaneousOnOffAndExclusiveChoices() async throws {
    await MainActor.run {
      var type = Typography(); type.fontName = "Baskerville"
      type.features = [21: 0]
      type.setIndependentFeature(1, selector: 2, value: false)
      type.setIndependentFeature(1, selector: 4, value: true)
      type.setIndependentFeature(1, selector: 20, value: true)
      let font = TypographyEngine.font(type, size: 30)
      let settings = font.fontDescriptor.object(forKey: .featureSettings) as! [[NSFontDescriptor.FeatureKey: Int]]
      XCTAssertEqual(settings.filter { $0[.typeIdentifier] == 1 }.compactMap { $0[.selectorIdentifier] }.sorted(), [3, 4, 20])
      var e = ArtworkElement(kind: "text", x: 0, y: 0, text: "fi ct st 0123", color: "#234567", fontSize: 30)
      e.typography = type
      let spans = TypographyEngine.spans(from: TypographyEngine.attributed(e), fallback: type)
      XCTAssertEqual(spans.count, 1)
      XCTAssertEqual(spans[0].typography.featureSelections, type.featureSelections)
      XCTAssertEqual(spans[0].typography.features[21], 0)
      XCTAssertEqual(spans[0].color, e.color)
    }
  }

  @MainActor private func glyphs(_ text: String, _ style: Typography) -> [CGGlyph] {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
      attributes: TypographyEngine.attributes(style, size: 30, color: "#222222", millimeters: false)))
    return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run in
      var values = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
      CTRunGetGlyphs(run, CFRange(), &values)
      return values
    }
  }

  func testCoreTextActuallyShapesIndependentLigatureChoices() async throws {
    await MainActor.run {
      var type = Typography(); type.fontName = "Baskerville"
      type.setIndependentFeature(1, selector: 2, value: false)
      type.setIndependentFeature(1, selector: 4, value: false)
      type.setIndependentFeature(1, selector: 20, value: false)
      let plain = glyphs("fi ct st", type)
      XCTAssertEqual(glyphs("fi", type).count, 2)
      type.setIndependentFeature(1, selector: 4, value: true)
      type.setIndependentFeature(1, selector: 20, value: true)
      let historical = glyphs("fi ct st", type)
      type.setIndependentFeature(1, selector: 2, value: true)
      let all = glyphs("fi ct st", type)
      XCTAssertEqual(glyphs("fi", type).count, 1)
      XCTAssertNotEqual(plain, historical)
      XCTAssertNotEqual(historical, all)
      XCTAssertLessThan(all.count, plain.count)
      XCTAssertEqual(type.featureSelections?[1], [2, 4, 20])
    }
  }

  func testMixedCharacterFeaturesAndVariableAxesSurviveNativeRoundTrip() async throws {
    try await MainActor.run {
      var first = Typography(); first.fontName = "Skia"
      first.variations = [2003265652: 1.8, 2003072104: 1.1]
      first.setIndependentFeature(1, selector: 2, value: false)
      first.setIndependentFeature(1, selector: 4, value: true)
      var second = first
      second.setIndependentFeature(1, selector: 2, value: true)
      second.setIndependentFeature(1, selector: 10, value: false)
      var e = ArtworkElement(kind: "text", x: 0, y: 0, width: 100, height: 25,
        text: "fi ct ae", color: "#222222", fontSize: 24)
      e.typography = first
      e.textRuns = [.init(location: 0, length: 3, typography: first, fontSize: 24, color: "#222222"),
        .init(location: 3, length: 5, typography: second, fontSize: 30, color: "#AA3300")]
      let attributed = TypographyEngine.attributed(e)
      let spans = TypographyEngine.spans(from: attributed, fallback: first)
      XCTAssertEqual(spans.map(\.typography.featureSelections), [first.featureSelections, second.featureSelections])
      XCTAssertEqual(spans.map(\.fontSize), [24, 30])
      XCTAssertEqual(spans.map(\.color), ["#222222", "#AA3300"])
      for span in spans {
        XCTAssertEqual(span.typography.variations[2003265652]!, 1.8, accuracy: 0.001)
        XCTAssertEqual(span.typography.variations[2003072104]!, 1.1, accuracy: 0.001)
      }
      let before = try TypographyEngine.outlineRuns(e)
      e.textRuns = spans
      let after = try TypographyEngine.outlineRuns(e)
      XCTAssertEqual(before.count, after.count)
      for (a, b) in zip(before, after) {
        XCTAssertEqual(a.0, b.0)
        XCTAssertEqual(a.1, b.1)
      }
    }
  }

  func testNativeFontReplacementAndResetAreRespected() async throws {
    await MainActor.run {
      var original = Typography(); original.fontName = "Baskerville"
      original.setIndependentFeature(1, selector: 2, value: false)
      original.setIndependentFeature(1, selector: 4, value: true)
      var attributes = TypographyEngine.attributes(original, size: 30, color: "#222222", millimeters: false)
      var next = original
      next.setIndependentFeature(1, selector: 20, value: true)
      attributes[.font] = TypographyEngine.font(next, size: 30)
      let changed = TypographyEngine.spans(from: NSAttributedString(string: "fi ct st", attributes: attributes), fallback: original)[0]
      XCTAssertEqual(changed.typography.featureSelections?[1], [3, 4, 20])
      attributes[.font] = NSFont(name: "Baskerville", size: 30)!
      let reset = TypographyEngine.spans(from: NSAttributedString(string: "fi ct st", attributes: attributes), fallback: original)[0]
      XCTAssertTrue(reset.typography.features.isEmpty)
      XCTAssertNil(reset.typography.featureSelections)
    }
  }

  func testMissingFontRetainsEveryAssignedSelector() async throws {
    await MainActor.run {
      var type = Typography(); type.fontName = "FORM-Uninstalled-Face"
      type.features = [21: 0]
      type.featureSelections = [1: [2, 4, 20], 8: [8]]
      let attrs = TypographyEngine.attributes(type, size: 20, color: "#222222", millimeters: false)
      let restored = TypographyEngine.spans(from: NSAttributedString(string: "fi ct st", attributes: attrs), fallback: type)[0].typography
      XCTAssertEqual(restored.fontName, type.fontName)
      XCTAssertEqual(restored.features, type.features)
      XCTAssertEqual(restored.featureSelections, type.featureSelections)
    }
  }

  func testSchemaElevenIsRequiredForRichRunsAndOlderFilesRemainReadable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root: root)
    var project = Project(name: "Font features")
    var e = ArtworkElement(kind: "text", x: 0, y: 0, text: "ct")
    var type = Typography(); type.features = [1: 4]
    e.typography = type
    var frame = ProductObject(name: "Sheet", recipeID: "artboard", parameters: ["width": 100, "depth": 80])
    frame.artwork = .init(elements: [e]); project.objects = [frame]
    try repository.save(project)
    XCTAssertEqual(try repository.load(project.id).schemaVersion, 2)
    type.setIndependentFeature(1, selector: 20, value: true)
    project.objects[0].artwork?.elements[0].textRuns = [.init(location: 0, length: 2, typography: type, fontSize: 14, color: "#222222")]
    try repository.save(project)
    let reopened = try repository.load(project.id)
    XCTAssertEqual(reopened.schemaVersion, 11)
    XCTAssertEqual(reopened.objects, project.objects)
    XCTAssertEqual(reopened.minimumSchemaVersion, 11)
  }

  func testFeatureOnlyEditsInvalidateLayoutButPlacementReusesIt() async throws {
    await MainActor.run {
      var e = ArtworkElement(kind: "text", x: 0, y: 0, text: "fi ct st")
      var type = Typography(); type.fontName = "Baskerville"
      e.typography = type
      _ = TypographyEngine.measured(e)
      let builds = TypographyEngine.diagnostics["layout_builds"] as! Int
      e.typography?.setIndependentFeature(1, selector: 4, value: true)
      _ = TypographyEngine.measured(e)
      XCTAssertEqual(TypographyEngine.diagnostics["layout_builds"] as! Int, builds + 1)
      e.x = 42
      _ = TypographyEngine.measured(e)
      XCTAssertEqual(TypographyEngine.diagnostics["layout_builds"] as! Int, builds + 1)
    }
  }
}

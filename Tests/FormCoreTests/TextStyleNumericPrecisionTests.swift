import XCTest
@testable import FormCore

final class TextStyleNumericPrecisionTests: XCTestCase {
  private func shifted(_ value: Double, by steps: Int) -> Double {
    var result = value
    for _ in 0..<abs(steps) { result = steps < 0 ? result.nextDown : result.nextUp }
    return result
  }
  private func span(_ style: ArtworkTextStyle) -> TextSpan {
    var value = TextSpan(location: 0, length: 1, typography: style.typography,
      fontSize: style.fontSize, color: "#000000")
    value.textStyle = .init(styleID: style.id)
    return value
  }
  private func wire(_ arguments: [String: Any]) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: arguments)) as? [String: Any])
  }
  private func setArtwork(_ artwork: Artwork, objectID: UUID, engine: OperationEngine) throws {
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder.form.encode(artwork))
    _ = try engine.call("form_set_artwork", arguments: wire(["object_id": objectID.uuidString, "artwork": encoded]))
  }

  func testAllScalarStyleFieldsUseEightRepresentableStepsAndRetainRealDifferences() {
    let fields: [(String, WritableKeyPath<Typography, Double>)] = [
      ("tracking", \.tracking), ("leading", \.leading), ("baseline", \.baseline),
      ("wordSpacing", \.wordSpacing), ("horizontalScale", \.horizontalScale),
      ("paragraphBefore", \.paragraphBefore), ("paragraphAfter", \.paragraphAfter),
      ("leftIndent", \.leftIndent), ("rightIndent", \.rightIndent),
      ("firstLineIndent", \.firstLineIndent), ("hyphenation", \.hyphenation),
    ]
    for (name, path) in fields {
      var type = Typography(); type[keyPath: path] = name == "hyphenation" ? 0.5 : 16.8
      let style = ArtworkTextStyle(name: "Body", typography: type, fontSize: 14)
      let original = span(style)
      for direction in [-1, 1] {
        var near = original
        near.typography[keyPath: path] = shifted(type[keyPath: path], by: direction * 8)
        XCTAssertTrue(TextStyleCommands.inheritsCorrectly(near, style: style), name)
        XCTAssertEqual(TextStyleCommands.inheritedDifferences(near, style: style), [], name)
        XCTAssertEqual(TextStyleCommands.recording(near, from: original).textStyle?.overrides, [], name)
        XCTAssertFalse(TextStyleCommands.changesParagraphs(type, near.typography), name)
        var changed = original
        changed.typography[keyPath: path] = shifted(type[keyPath: path], by: direction * 9)
        XCTAssertFalse(TextStyleCommands.inheritsCorrectly(changed, style: style), name)
        XCTAssertEqual(TextStyleCommands.inheritedDifferences(changed, style: style), [name], name)
        XCTAssertEqual(TextStyleCommands.recording(changed, from: original).textStyle?.overrides, [name], name)
        if TextStyleCommands.paragraphProperties.contains(name) {
          XCTAssertTrue(TextStyleCommands.paragraphMatches(near.typography, style: type, overrides: []), name)
          XCTAssertFalse(TextStyleCommands.paragraphMatches(changed.typography, style: type, overrides: []), name)
          XCTAssertTrue(TextStyleCommands.changesParagraphs(type, changed.typography), name)
        }
      }
    }
    // Zero needs the same precision bound on both sides, without an absolute epsilon.
    let zeroStyle = ArtworkTextStyle(name: "Zero", typography: .init(), fontSize: 14)
    for direction in [-1, 1] {
      var value = span(zeroStyle)
      value.typography.baseline = shifted(0, by: direction * 8)
      XCTAssertTrue(TextStyleCommands.inheritsCorrectly(value, style: zeroStyle))
      value.typography.baseline = shifted(0, by: direction * 9)
      XCTAssertFalse(TextStyleCommands.inheritsCorrectly(value, style: zeroStyle))
    }
  }

  func testOptionalNumbersAndFontSizeKeepNilAndNonnumericSemantics() {
    var type = Typography(); type.defaultTabInterval = 16.8
    let style = ArtworkTextStyle(name: "Body", typography: type, fontSize: 16.8)
    let original = span(style)
    var near = original
    near.fontSize = shifted(style.fontSize, by: 8)
    near.typography.defaultTabInterval = shifted(16.8, by: -8)
    XCTAssertTrue(TextStyleCommands.inheritsCorrectly(near, style: style))
    XCTAssertEqual(TextStyleCommands.recording(near, from: original).textStyle?.overrides, [])
    var changed = original
    changed.fontSize = shifted(style.fontSize, by: 9)
    XCTAssertEqual(TextStyleCommands.inheritedDifferences(changed, style: style), ["fontSize"])
    XCTAssertEqual(TextStyleCommands.recording(changed, from: original).textStyle?.overrides, ["fontSize"])
    changed = original; changed.typography.defaultTabInterval = shifted(16.8, by: 9)
    XCTAssertEqual(TextStyleCommands.inheritedDifferences(changed, style: style), ["defaultTabInterval"])
    changed = original; changed.typography.defaultTabInterval = nil
    XCTAssertFalse(TextStyleCommands.inheritsCorrectly(changed, style: style))
    XCTAssertEqual(TextStyleCommands.recording(changed, from: original).textStyle?.overrides, ["defaultTabInterval"])
    let nilStyle = ArtworkTextStyle(name: "Default tabs", typography: .init(), fontSize: 14)
    changed = span(nilStyle); changed.typography.defaultTabInterval = 0
    XCTAssertFalse(TextStyleCommands.inheritsCorrectly(changed, style: nilStyle))
    XCTAssertEqual(TextStyleCommands.inheritedDifferences(changed, style: nilStyle), ["defaultTabInterval"])
    changed = original; changed.typography.fontName += "-other"
    XCTAssertEqual(TextStyleCommands.inheritedDifferences(changed, style: style), ["fontName"])
    changed = original; changed.typography.underline.toggle()
    XCTAssertEqual(TextStyleCommands.inheritedDifferences(changed, style: style), ["underline"])
    // Numeric payloads inside structured style values retain their existing exact semantics.
    var variationStyle = style; variationStyle.typography.variations = [1: 0.5]
    changed = span(variationStyle); changed.typography.variations[1] = 0.5.nextUp
    XCTAssertEqual(TextStyleCommands.inheritedDifferences(changed, style: variationStyle), ["variations"])
  }

  func testJSONArithmeticStyleAcceptsLiteralArtworkWithoutOverridesAndPreservesPropagationUndo() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = OperationEngine(repository: try ProjectRepository(root: folder))
    var project = Project(name: "Decimal style equivalence")
    var page = try project.makeObject(recipeID: "artboard", parameters: ["width": 150, "depth": 100])
    var text = ArtworkElement(kind: "text", x: 10, y: 10, width: 120, height: 40,
      text: "One canonical paragraph", color: "#000000", fontSize: 16.8)
    text.typography = .init()
    page.artwork = .init(background: "#FFFFFF", elements: [text], bleed: 0)
    project.objects = [page]; engine.project = project
    let arithmetic = 12.0 * 1.4
    XCTAssertNotEqual(arithmetic, 16.8, "The fixture must retain the reported arithmetic/literal difference.")
    let defaults = Typography()
    _ = try engine.call("form_text_style", arguments: wire([
      "command": "create", "name": "Body", "font_size": arithmetic,
      "typography": ["fontName": defaults.fontName, "leading": arithmetic, "defaultTabInterval": arithmetic],
    ]))
    let styleID = try XCTUnwrap(engine.project?.textStyles?.first?.id)
    var artwork = try XCTUnwrap(engine.project?.objects.first?.artwork)
    artwork.elements[0].typography?.leading = 16.8
    artwork.elements[0].typography?.defaultTabInterval = 16.8
    artwork.elements[0].textStyle = .init(styleID: styleID)
    try setArtwork(artwork, objectID: page.id, engine: engine)
    XCTAssertEqual(engine.project?.objects[0].artwork?.elements[0].textStyle?.overrides, [])
    var tinyEdit = try XCTUnwrap(engine.project?.objects[0].artwork)
    tinyEdit.elements[0].fontSize = 16.8.nextUp
    tinyEdit.elements[0].typography?.leading = 16.8.nextUp
    tinyEdit.elements[0].typography?.defaultTabInterval = 16.8.nextUp
    try setArtwork(tinyEdit, objectID: page.id, engine: engine)
    XCTAssertEqual(engine.project?.objects[0].artwork?.elements[0].textStyle?.overrides, [], "Recording edits must use the same equivalence as style validation.")
    let encoded = try JSONEncoder.form.encode(XCTUnwrap(engine.project))
    let reopened = try JSONDecoder.form.decode(Project.self, from: encoded)
    XCTAssertNoThrow(try reopened.validateArtworkLinks())
    XCTAssertEqual(reopened.objects, engine.project?.objects)

    let beforeRejected = try XCTUnwrap(engine.project), undoCount = engine.undoStack.count
    var explicit = try XCTUnwrap(beforeRejected.objects[0].artwork)
    var second = explicit.elements[0]
    second.id = UUID(); second.typography?.leading = 18
    explicit.elements.append(second)
    XCTAssertThrowsError(try setArtwork(explicit, objectID: page.id, engine: engine)) { error in
      XCTAssertTrue(error.localizedDescription.contains("leading"))
    }
    XCTAssertEqual(engine.project, beforeRejected)
    XCTAssertEqual(engine.undoStack.count, undoCount)
    explicit.elements[1].textStyle?.overrides = ["leading"]
    try setArtwork(explicit, objectID: page.id, engine: engine)
    let beforeUpdate = try XCTUnwrap(engine.project)
    _ = try engine.call("form_text_style", arguments: wire([
      "command": "update", "style_id": styleID.uuidString, "font_size": 19.0,
      "typography": ["leading": 21.0, "defaultTabInterval": 24.0],
    ]))
    let updated = try XCTUnwrap(engine.project)
    let values = try XCTUnwrap(updated.objects[0].artwork).elements
    XCTAssertEqual(values.map(\.fontSize), [19, 19])
    XCTAssertEqual(values.map { $0.typography?.leading }, [21, 18])
    XCTAssertEqual(values.map { $0.typography?.defaultTabInterval }, [24, 24])
    XCTAssertEqual(values[0].textStyle?.overrides, [])
    XCTAssertEqual(values[1].textStyle?.overrides, ["leading"])
    engine.undo(); XCTAssertEqual(engine.project, beforeUpdate)
    engine.redo(); XCTAssertEqual(engine.project, updated)
    engine.undo(); engine.undo(); XCTAssertEqual(engine.project, beforeRejected)
  }
}

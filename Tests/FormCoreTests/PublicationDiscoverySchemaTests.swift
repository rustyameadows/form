import XCTest
@testable import FormCore

final class PublicationDiscoverySchemaTests: XCTestCase {
  private func decode<T: Decodable>(_ type: T.Type, _ raw: [String: Any]) throws -> T {
    try JSONDecoder.form.decode(type, from: JSONSerialization.data(withJSONObject: raw))
  }
  private func properties(_ schema: [String: Any]) throws -> [String: Any] {
    try XCTUnwrap(schema["properties"] as? [String: Any])
  }
  private func fields(_ tool: String) throws -> [String: Any] {
    let tool = try XCTUnwrap(MCP.tools.first { $0["name"] as? String == tool })
    return try properties(XCTUnwrap(tool["inputSchema"] as? [String: Any]))
  }

  func testMasterSchemaHasExactlyRequiredSourceAndRealDecoderDefaults() throws {
    let schema = PublicationDiscoverySchema.master, props = try properties(schema), id = UUID()
    XCTAssertEqual(schema["required"] as? [String], ["sourceObjectID"])
    XCTAssertThrowsError(try decode(PublicationMaster.self, [:]))
    var supplied: [String: Any] = ["sourceObjectID": id.uuidString]
    for nullDefaults in [false, true] {
      if nullDefaults { for key in props.keys where key != "sourceObjectID" { supplied[key] = NSNull() } }
      let value = try decode(PublicationMaster.self, supplied)
      XCTAssertEqual(value.sourceObjectID, id)
      let raw = try XCTUnwrap(jsonObject(value) as? [String: Any])
      for (key, field) in props {
        if let expected = (field as? [String: Any])?["default"] {
          XCTAssertEqual(try JSONSerialization.data(withJSONObject: [raw[key]!], options: .sortedKeys),
            try JSONSerialization.data(withJSONObject: [expected], options: .sortedKeys), key)
        }
      }
    }
    let publication = try fields("form_publication")
    let masters = try XCTUnwrap(publication["masters"] as? [String: Any])
    let item = try XCTUnwrap(masters["items"] as? [String: Any])
    XCTAssertEqual(Set(try properties(item).keys), Set(props.keys))
    var project = Project(name: "Master schema")
    var source = try project.makeObject(recipeID: "artboard", name: "Furniture", parameters: ["width": 100, "depth": 100])
    source.artwork = .init(elements: [])
    project.objects.append(source)
    var master = PublicationMaster(sourceObjectID: source.id, x: 100_000, y: -100_000)
    XCTAssertNoThrow(try project.validatePublicationMasters(.init(masters: [master])))
    master.x = 100_001
    XCTAssertThrowsError(try project.validatePublicationMasters(.init(masters: [master])))
  }

  func testLayoutNumberingDefaultsAndRequiredCompleteObjectsMatchDecoding() throws {
    XCTAssertEqual(try decode(PublicationLayout.self, [:]), PublicationLayout())
    XCTAssertEqual(try decode(PublicationNumbering.self, [:]), PublicationNumbering())
    XCTAssertTrue(try decode(PublicationLayout.self, ["innerMargin": 1000, "outerMargin": 0]).valid)
    XCTAssertFalse(try decode(PublicationLayout.self, ["innerMargin": 1001]).valid)
    XCTAssertTrue(try decode(PublicationNumbering.self, ["start": 999_999]).valid)
    XCTAssertFalse(try decode(PublicationNumbering.self, ["start": 1_000_000]).valid)
    XCTAssertEqual((try properties(PublicationDiscoverySchema.layout)["facingPages"] as? [String: Any])?["default"] as? Bool, true)
    XCTAssertEqual((try properties(PublicationDiscoverySchema.numbering)["start"] as? [String: Any])?["default"] as? Int, 1)
    let margins: [String: Any] = ["top": 14, "right": 14, "bottom": 14, "left": 14]
    let grid: [String: Any] = ["spacing": 18, "origin": 0]
    for key in try XCTUnwrap(PublicationDiscoverySchema.margins["required"] as? [String]) {
      var partial = margins; partial.removeValue(forKey: key)
      XCTAssertThrowsError(try decode(PublicationMargins.self, partial))
    }
    for key in try XCTUnwrap(PublicationDiscoverySchema.baselineGrid["required"] as? [String]) {
      var partial = grid; partial.removeValue(forKey: key)
      XCTAssertThrowsError(try decode(BaselineGrid.self, partial))
    }
    XCTAssertTrue(try decode(PublicationMargins.self, margins).valid)
    XCTAssertTrue(try decode(BaselineGrid.self, grid).valid)
    XCTAssertFalse(try decode(BaselineGrid.self, ["spacing": 3.9, "origin": 0]).valid)
    XCTAssertFalse(try decode(BaselineGrid.self, ["spacing": 18, "origin": 10_001]).valid)
  }

  func testDiscoveryExposesRealNumericBoundsWithoutInventedConfigureDefaults() throws {
    let publication = try fields("form_publication"), output = try fields("form_export_publication")
    let expected: [(String, Double, Double)] = [("opening_degrees", 0, 180), ("bend_mm", 0, 20), ("active_spread", 0, 200), ("width", 20, 2000), ("height", 20, 2000), ("gutter", 0, 100)]
    for (key, minimum, maximum) in expected {
      let schema = try XCTUnwrap(publication[key] as? [String: Any])
      XCTAssertEqual((schema["minimum"] as? NSNumber)?.doubleValue, minimum, key)
      XCTAssertEqual((schema["maximum"] as? NSNumber)?.doubleValue, maximum, key)
    }
    for key in ["opening_degrees", "bend_mm", "active_spread"] {
      XCTAssertNil((publication[key] as? [String: Any])?["default"], "Omission preserves authored pose")
    }
    let dpi = try XCTUnwrap(output["dpi"] as? [String: Any])
    XCTAssertEqual(dpi["minimum"] as? Int, 36); XCTAssertEqual(dpi["maximum"] as? Int, 1200)
    XCTAssertEqual(dpi["default"] as? Int, 300)
    var project = Project(name: "Numeric boundary parity")
    let document = try PublicationCommands.createPublication(in: &project, name: "Boundary document", pages: [])
    _ = try PublicationCommands.addPage(in: &project, publicationID: document, width: 100, height: 100)
    let object = try SheetAssemblyCommands.create(in: &project, definition: .init(publicationID: document))
    var definition = project.objects.first { $0.id == object }!.sheetAssembly!
    for (opening, bend) in [(180.0, 20.0), (0.0, 0.0)] {
      definition.openingDegrees = opening; definition.bendMM = bend
      XCTAssertNoThrow(try SheetAssemblyCommands.configure(in: &project, objectID: object, definition: definition))
    }
    definition.openingDegrees = 180.01
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in: &project, objectID: object, definition: definition))
    definition.openingDegrees = 0; definition.bendMM = 20.01
    XCTAssertThrowsError(try SheetAssemblyCommands.configure(in: &project, objectID: object, definition: definition))
    XCTAssertThrowsError(try PublicationCommands.addPage(in: &project, publicationID: document, width: 2001))
    XCTAssertThrowsError(try PublicationCommands.addPage(in: &project, publicationID: document, gutter: 101))
  }
}

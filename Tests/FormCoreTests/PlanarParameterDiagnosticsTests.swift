import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class PlanarParameterDiagnosticsTests:XCTestCase {
  private func shipping()throws->PlanarConstructionDefinition {
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try JSONDecoder.form.decode(PlanarConstructionDefinition.self,from:Data(contentsOf:root.appendingPathComponent("examples/paper-packaging/01-rsc-shipping.json")))
  }
  func testNativeDefinitionDraftReportsTheActualDepthRangeInsteadOfMalformedStructure()throws {
    var definition=try shipping()
    let index=try XCTUnwrap(definition.parameters.firstIndex{$0.name=="depth"})
    definition.parameters[index].value=90
    XCTAssertThrowsError(try definition.net()) {error in
      let message=error.localizedDescription
      XCTAssertTrue(message.contains("'depth'"));XCTAssertTrue(message.contains("108"));XCTAssertTrue(message.contains("288"))
      XCTAssertFalse(message.contains("hinge"))
    }
    definition.parameters[index].value=108
    XCTAssertEqual(try definition.net().panels.count,13)
  }
  func testParameterUpdateRetainsTheAcceptedDefinitionOnOutOfRangeInput()throws {
    var definition=try shipping();let before=definition
    XCTAssertThrowsError(try definition.setParameters(["width":400,"depth":90])) {error in
      XCTAssertTrue(error.localizedDescription.contains("'depth'"));XCTAssertTrue(error.localizedDescription.contains("108"))
    }
    XCTAssertEqual(definition,before)
    definition.parameters[0].minimum = .nan
    XCTAssertThrowsError(try definition.net())
  }
}

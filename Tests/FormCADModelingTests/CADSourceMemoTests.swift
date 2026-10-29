import CryptoKit
import Foundation
import FormCADModel
import XCTest

final class CADSourceMemoTests: XCTestCase {
  private func fixture() -> CADModelDefinition {
    let body = CADFeatureNode(name: "Body", operation: .init(.box,
      values: ["width": "width", "height": 20, "depth": 30]))
    return .init(name: "Source proof", parameters: [.init("width", 40, 10...80)],
      features: [body], outputs: [body.id])
  }
  private func canonicalHash(_ model: CADModelDefinition) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SHA256.hash(data: try encoder.encode(model)).map { String(format: "%02x", $0) }.joined()
  }
  func testSourceWritesWithAnUnchangedRevisionCannotReuseValidation() throws {
    let original = fixture()
    let order = try original.validatedOrder(), fingerprint = try original.sourceFingerprint()
    let invalidEdits: [(inout CADModelDefinition) -> Void] = [
      { $0.parameters[0].value = 100 },
      { $0.features[0].operation.values["width"] = "unknown" },
      { $0.features[0].operation.inputs = [UUID()] },
      { $0.outputs = [UUID()] },
      { $0.name = "" },
      { $0.version = 999 },
      { $0.assumptions = [String(repeating: "x", count: 2049)] },
      { $0.unresolvedMeasurements = [String(repeating: "x", count: 2049)] },
      { $0.requirements = [.init(id: "impossible", lhs: 1, relation: .lessThan, rhs: 0, message: "Reject impossible source")] }
    ]
    for edit in invalidEdits {
      var changed = original; edit(&changed)
      XCTAssertEqual(changed.revision, original.revision)
      XCTAssertThrowsError(try changed.validatedOrder())
      XCTAssertEqual(try original.validatedOrder(), order, "Changing a copy must not poison the original proof")
      XCTAssertEqual(try original.sourceFingerprint(), fingerprint)
      XCTAssertEqual(try changed.sourceFingerprint(), try canonicalHash(changed))
    }
  }
  func testCanonicalFingerprintPreservesSignedZeroAndUnicodeBytes() throws {
    var model = fixture()
    model.name = "\u{00e9}"
    model.parameters.append(.init("unused", 0, -1...1))
    let initial = try model.sourceFingerprint()
    var changed = model
    changed.parameters[1].value = -0.0
    XCTAssertEqual(model, changed, "Double equality deliberately does not distinguish signed zero")
    XCTAssertNotEqual(initial, try changed.sourceFingerprint())
    XCTAssertEqual(try changed.sourceFingerprint(), try canonicalHash(changed))
    var unicode = model
    unicode.name = "e\u{0301}"
    XCTAssertEqual(model, unicode, "Swift strings compare canonically equivalent Unicode as equal")
    XCTAssertNotEqual(initial, try unicode.sourceFingerprint())
    XCTAssertEqual(try unicode.sourceFingerprint(), try canonicalHash(unicode))
    XCTAssertEqual(try model.sourceFingerprint(), initial)
  }
  func testRelaxedValidationDoesNotAcceptFailedRequirementsAndMetadataWritesInvalidateHashes() throws {
    var model = fixture(); model.version = 2
    model.requirements = [.init(id: "width-rule", lhs: "width", relation: .lessThan, rhs: 20, message: "Width must fit")]
    _ = try model.validatedOrder(checkRequirements: false)
    XCTAssertThrowsError(try model.validatedOrder())
    model.requirements![0].rhs = 60
    _ = try model.validatedOrder()
    let before = try model.sourceFingerprint()
    model.assumptions.append("Explicit assumption")
    XCTAssertNotEqual(try model.sourceFingerprint(), before)
    XCTAssertEqual(try model.sourceFingerprint(), try canonicalHash(model))
    let afterAssumption = try model.sourceFingerprint()
    model.importedAssemblies = []
    XCTAssertNotEqual(try model.sourceFingerprint(), afterAssumption)
    XCTAssertEqual(try model.sourceFingerprint(), try canonicalHash(model))
    model.surfaces = []; model.outputRequirements = []
    XCTAssertEqual(try model.sourceFingerprint(), try canonicalHash(model))
  }
  func testMemoPreservesCodingEqualityAndConcurrentImmutableReaders() async throws {
    let model = fixture(), expected = try model.validatedOrder(), fingerprint = try model.sourceFingerprint()
    let bytes = try JSONEncoder().encode(model)
    let decoded = try JSONDecoder().decode(CADModelDefinition.self, from: bytes)
    XCTAssertEqual(decoded, model)
    XCTAssertEqual(try decoded.sourceFingerprint(), fingerprint)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertNil(fields["sourceMemo"])
    let coldReaders = try JSONDecoder().decode(CADModelDefinition.self, from: bytes)
    try await withThrowingTaskGroup(of: ([CADFeatureNode], String).self) { group in
      for _ in 0..<32 { group.addTask { (try coldReaders.validatedOrder(), try coldReaders.sourceFingerprint()) } }
      for try await (order, hash) in group {
        XCTAssertEqual(order, expected); XCTAssertEqual(hash, fingerprint)
      }
    }
    var changed = decoded
    changed.features[0].operation.values["width"] = "missing"
    XCTAssertThrowsError(try changed.validatedOrder())
    XCTAssertEqual(try model.validatedOrder(), expected)
  }
}

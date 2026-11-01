import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class ObjectViewReferenceAspectTests: XCTestCase {
  func testViewChangeKeepsIntentionalNonuniformResize() throws {
    let triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = [
      (.init(-1,-1,0), .init(1,-1,0), .init(1,1,0)),
      (.init(-1,-1,0), .init(1,1,0), .init(-1,1,0)),
    ]
    let generated = try ObjectViewProjection.project(triangles, azimuth: 0, elevation: 0,
      style: "silhouette", name: "Square")
    var placed = generated
    var settings = ObjectViewSettings(sourceID: UUID())
    settings.referenceAspect = settings.framingAspect(for: placed)
    placed.width *= 2
    placed.path = try XCTUnwrap(ObjectViewProjection.fit(generated, into: settings.framingTarget(for: placed)))
    let bounds = VectorGeometry.path(placed).boundingBoxOfPath
    XCTAssertEqual(bounds.width / bounds.height, 2, accuracy: 0.001)
    XCTAssertEqual(placed.width, generated.width * 2)
    XCTAssertEqual(placed.height, generated.height)
    // Returning from an image retains the same reference frame and distortion.
    placed.kind = "image"; placed.path = nil
    XCTAssertEqual(settings.framingAspect(for: placed), 1, accuracy: 0.001)
    placed.kind = "path"
    placed.path = try XCTUnwrap(ObjectViewProjection.fit(generated, into: settings.framingTarget(for: placed)))
    let restored = VectorGeometry.path(placed).boundingBoxOfPath
    XCTAssertEqual(restored.width / restored.height, 2, accuracy: 0.001)
  }
}

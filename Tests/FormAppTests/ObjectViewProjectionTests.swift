import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class ObjectViewProjectionTests: XCTestCase {
  func testOverlappingTrianglesBecomeOneEditableSilhouette() throws {
    let triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = [
      (.init(0,0,0), .init(2,0,0), .init(2,1,0)),
      (.init(0,0,0), .init(2,1,0), .init(0,1,0)),
      // Reverse winding and overlap to ensure seams do not survive.
      (.init(1,0,1), .init(1,1,1), .init(3,1,1)),
      (.init(1,0,1), .init(3,1,1), .init(3,0,1)),
    ]
    let element = try ObjectViewProjection.project(triangles, azimuth: 0, elevation: 0, style: "silhouette", name: "Block")
    XCTAssertEqual(element.width, 60, accuracy: 0.001)
    XCTAssertEqual(element.height, 60, accuracy: 0.001)
    XCTAssertEqual(element.path?.contours.count, 1)
    XCTAssertEqual(element.fillEnabled, true)
    XCTAssertNil(element.stroke)
    XCTAssertTrue(VectorGeometry.path(element).contains(CGPoint(x: 30, y: 30)))
  }
  func testOutlineAndCameraAreIndependent() throws {
    let triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = [
      (.init(0,0,0), .init(2,0,0), .init(2,1,0)),
      (.init(0,0,0), .init(2,1,0), .init(0,1,0)),
      (.init(0,0,0), .init(0,1,0), .init(0,1,3)),
      (.init(0,0,0), .init(0,1,3), .init(0,0,3)),
    ]
    let front = try ObjectViewProjection.project(triangles, azimuth: 0, elevation: 0, style: "lines", name: "Model")
    let side = try ObjectViewProjection.project(triangles, azimuth: 90, elevation: 0, style: "silhouette", name: "Model")
    XCTAssertEqual(front.fillEnabled, false)
    XCTAssertEqual(front.stroke?.width, 0.5)
    XCTAssertEqual(front.height, 60, accuracy: 0.001)
    XCTAssertEqual(side.height, 60, accuracy: 0.001)
    let frontBounds = VectorGeometry.path(front).boundingBoxOfPath
    let sideBounds = VectorGeometry.path(side).boundingBoxOfPath
    XCTAssertEqual(frontBounds.height, sideBounds.height, accuracy: 0.001)
    XCTAssertEqual(sideBounds.width / frontBounds.width, 1.5, accuracy: 0.001)
    XCTAssertNotEqual(front.id, side.id)
  }
  func testLineViewHidesBackEdgesAndOmitsCoplanarSeams() throws {
    let triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = [
      (.init(0,0,0), .init(10,0,0), .init(10,4,0)),
      (.init(0,0,0), .init(10,4,0), .init(0,4,0)),
      (.init(4,-1,1), .init(6,-1,1), .init(6,1,1)),
      (.init(4,-1,1), .init(6,1,1), .init(4,1,1)),
    ]
    let view = try ObjectViewProjection.project(triangles, azimuth: 0, elevation: 0, style: "lines", name: "Overlap")
    let open = try XCTUnwrap(view.path).contours.filter { !$0.closed && $0.nodes.count == 2 }
    let scale = 60 / (1.2 * sqrt(126.0))
    func x(_ value: Double) -> Double { 30 + (value-5) * scale }
    let baseline = 30 + 1.5 * scale
    func hasEdge(_ x0: Double, _ x1: Double) -> Bool {
      open.contains { contour in
        let points = contour.nodes.map(\.anchor).sorted { $0.x < $1.x }
        return abs(points[0].x-x0)<0.001 && abs(points[1].x-x1)<0.001
          && abs(points[0].y-baseline)<0.001 && abs(points[1].y-baseline)<0.001
      }
    }
    XCTAssertTrue(hasEdge(x(0),x(4)))
    XCTAssertTrue(hasEdge(x(6),x(10)))
    XCTAssertFalse(hasEdge(x(0),x(10)))
    // The back rectangle diagonal is a tessellation seam, not an illustration line.
    XCTAssertFalse(open.contains { contour in
      let points = contour.nodes.map(\.anchor).sorted { $0.x < $1.x }
      return abs(points[0].x-x(0))<0.001 && abs(points[1].x-x(10))<0.001
        && abs(points[0].y-baseline)<0.001 && abs(points[1].y-(30-2.5*scale))<0.001
    })
  }
  func testFittingPreservesAspectAndPlacementFrame() throws {
    let triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = [
      (.init(0,0,0), .init(2,0,0), .init(2,1,0)),
      (.init(0,0,0), .init(2,1,0), .init(0,1,0)),
    ]
    let generated = try ObjectViewProjection.project(triangles, azimuth: 0, elevation: 0, style: "silhouette", name: "Block")
    let frame = ArtworkElement(kind: "path", x: 10, y: 20, width: 100, height: 100)
    var fitted = frame
    fitted.path = ObjectViewProjection.fit(generated, into: frame)
    XCTAssertEqual(fitted.path?.width, 100)
    XCTAssertEqual(fitted.path?.height, 100)
    let bounds = VectorGeometry.path(fitted).boundingBoxOfPath
    let expectedWidth = 100 * 2 / (1.2 * sqrt(5.0))
    XCTAssertEqual(bounds.width, expectedWidth, accuracy: 0.001)
    XCTAssertEqual(bounds.height, expectedWidth / 2, accuracy: 0.001)
    XCTAssertEqual(bounds.minY, (100-expectedWidth/2)/2, accuracy: 0.001)
  }
  func testEmptyGeometryAndInvalidAnglesFail() {
    XCTAssertThrowsError(try ObjectViewProjection.project([], azimuth: 0, elevation: 0, style: "silhouette", name: "Empty"))
    XCTAssertThrowsError(try ObjectViewProjection.project([], azimuth: .nan, elevation: 0, style: "lines", name: "Invalid"))
  }
}

import XCTest
import CoreGraphics
@testable import FormApp

final class CanvasEdgeScrollingTests: XCTestCase {
  private let viewport = CGRect(x: 0, y: 0, width: 900, height: 650)
  private let tick = 1.0 / 60

  func testInteriorAndMarginBoundaryStayStill() {
    for point in [CGPoint(x: 450, y: 325), .init(x: 32, y: 32), .init(x: 868, y: 618)] {
      XCTAssertEqual(CanvasEdgeScrolling.offset(pointer: point, viewport: viewport, elapsed: tick), .zero)
    }
  }

  func testApproachingEdgeAcceleratesSmoothlyToBoundedSpeed() {
    let nearMargin = CanvasEdgeScrolling.offset(pointer: .init(x: 31, y: 325), viewport: viewport, elapsed: tick)
    let midway = CanvasEdgeScrolling.offset(pointer: .init(x: 16, y: 325), viewport: viewport, elapsed: tick)
    let edge = CanvasEdgeScrolling.offset(pointer: .init(x: 0, y: 325), viewport: viewport, elapsed: tick)
    let outside = CanvasEdgeScrolling.offset(pointer: .init(x: -1000, y: 325), viewport: viewport, elapsed: tick)
    XCTAssertLessThan(nearMargin.x, 0); XCTAssertGreaterThan(nearMargin.x, -0.1)
    XCTAssertEqual(midway.x, -6, accuracy: 0.000001)
    XCTAssertEqual(edge.x, -12, accuracy: 0.000001)
    XCTAssertEqual(outside, edge)
    XCTAssertEqual(edge.y, 0)
    let opposite = CanvasEdgeScrolling.offset(pointer: .init(x: 900, y: 650), viewport: viewport, elapsed: tick)
    XCTAssertEqual(opposite.x, 12, accuracy: 0.000001)
    XCTAssertEqual(opposite.y, 12, accuracy: 0.000001)
  }

  func testNegativeCoordinatesAndTranslatedViewportsHaveIdenticalBehavior() {
    let point = CGPoint(x: 12, y: 642), translation = CGPoint(x: -1200, y: -800)
    let original = CanvasEdgeScrolling.offset(pointer: point, viewport: viewport, elapsed: tick)
    let translated = CanvasEdgeScrolling.offset(
      pointer: .init(x: point.x + translation.x, y: point.y + translation.y),
      viewport: viewport.offsetBy(dx: translation.x, dy: translation.y), elapsed: tick)
    XCTAssertEqual(original, translated)
    XCTAssertLessThan(translated.x, 0); XCTAssertGreaterThan(translated.y, 0)
  }

  func testElapsedTimeKeepsSpeedStableButAStallCannotJumpTheDocument() {
    let pointer = CGPoint(x: 900, y: 325)
    let sixtyHz = CanvasEdgeScrolling.offset(pointer: pointer, viewport: viewport, elapsed: tick)
    let thirtyHz = CanvasEdgeScrolling.offset(pointer: pointer, viewport: viewport, elapsed: tick * 2)
    let stalled = CanvasEdgeScrolling.offset(pointer: pointer, viewport: viewport, elapsed: 10)
    XCTAssertEqual(thirtyHz.x, sixtyHz.x * 2, accuracy: 0.000001)
    XCTAssertEqual(stalled.x, 36, accuracy: 0.000001)
  }

  func testNarrowViewportRetainsANeutralCenterAndCorrectDirections() {
    let narrow = CGRect(x: -25, y: -10, width: 40, height: 18)
    XCTAssertEqual(CanvasEdgeScrolling.offset(pointer: .init(x: -5, y: -1), viewport: narrow, elapsed: tick), .zero)
    let first = CanvasEdgeScrolling.offset(pointer: narrow.origin, viewport: narrow, elapsed: tick)
    let last = CanvasEdgeScrolling.offset(pointer: .init(x: narrow.maxX, y: narrow.maxY), viewport: narrow, elapsed: tick)
    XCTAssertEqual(first.x, -12, accuracy: 0.000001); XCTAssertEqual(first.y, -12, accuracy: 0.000001)
    XCTAssertEqual(last.x, 12, accuracy: 0.000001); XCTAssertEqual(last.y, 12, accuracy: 0.000001)
  }

  func testInvalidGeometryAndTimingDoNotMoveTheViewport() {
    for duration in [0, -1, Double.infinity, Double.nan] {
      XCTAssertEqual(CanvasEdgeScrolling.offset(pointer: .zero, viewport: viewport, elapsed: duration), .zero)
    }
    for rect in [CGRect.zero, .null, .infinite] {
      XCTAssertEqual(CanvasEdgeScrolling.offset(pointer: .zero, viewport: rect, elapsed: tick), .zero)
    }
    XCTAssertEqual(CanvasEdgeScrolling.offset(pointer: .init(x: CGFloat.nan, y: 0), viewport: viewport, elapsed: tick), .zero)
  }
}

import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasPreparedArtworkCacheTests: XCTestCase {
  func testMovingFramesReusesLocalGeometryAndOnlyEditedFrameOrExcludedContentInvalidates() throws {
    let cache = CanvasPreparedArtworkCache(), assets = FileManager.default.temporaryDirectory
    let a = UUID(), b = UUID(), shape = ArtworkElement(kind: "rectangle", x: 3, y: 5, width: 12, height: 9)
    var art = Artwork(elements: [shape])
    let first = try XCTUnwrap(cache.renderer(frameID: a, source: art, assets: assets, excluding: []))
    let other = try XCTUnwrap(cache.renderer(frameID: b, source: art, assets: assets, excluding: []))
    for n in 0..<30 {
      art.canvasPosition = .init(Double(n)*10,-Double(n)*20)
      XCTAssertTrue(cache.renderer(frameID: a, source: art, assets: assets, excluding: []) === first)
    }
    XCTAssertEqual(cache.builds, 2)
    art.elements[0].width = 20
    let edited = try XCTUnwrap(cache.renderer(frameID: a, source: art, assets: assets, excluding: []))
    XCTAssertFalse(edited === first)
    XCTAssertTrue(cache.renderer(frameID: b, source: Artwork(elements: [shape]), assets: assets, excluding: []) === other)
    XCTAssertFalse(cache.renderer(frameID: a, source: art, assets: assets, excluding: [shape.id]) === edited)
    let beforeAssetChange = cache.builds
    _ = cache.renderer(frameID: a, source: art, assets: assets.appendingPathComponent("other-project"), excluding: [shape.id])
    XCTAssertEqual(cache.builds, beforeAssetChange+1)
  }
  func testPreparedDisplayRetentionIsBoundedAndRemovedFramesAreReleased() throws {
    let cache = CanvasPreparedArtworkCache(byteLimit: 2500, entryLimit: 2)
    let art = Artwork(elements: [.init(kind: "rectangle", x: 0, y: 0, width: 20, height: 10)])
    let assets = FileManager.default.temporaryDirectory
    var latest = UUID()
    for _ in 0..<10 {
      latest = UUID()
      XCTAssertNotNil(cache.renderer(frameID: latest, source: art, assets: assets, excluding: []))
      XCTAssertLessThanOrEqual(cache.retainedBytes, 2500)
      XCTAssertLessThanOrEqual(cache.count, 2)
    }
    cache.retain([latest]); XCTAssertEqual(cache.count, 1)
    cache.clear(); XCTAssertEqual(cache.count, 0); XCTAssertEqual(cache.retainedBytes, 0)
  }
}

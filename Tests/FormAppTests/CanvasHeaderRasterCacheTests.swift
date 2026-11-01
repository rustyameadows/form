import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class CanvasHeaderRasterCacheTests: XCTestCase {
  private func draw(_ frame: CanvasFrame, appearance: InterfaceAppearance, density: Double = 2) throws -> Data {
    let scale = 1.0, rect = CanvasFrameChrome.headerRect(for: frame,scale: scale)
    let width = Int(ceil(rect.width*density)), height = Int(ceil(rect.height*density))
    let c = try XCTUnwrap(CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,
      bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    c.translateBy(x: 0,y: CGFloat(height)); c.scaleBy(x: density,y: -density)
    c.translateBy(x: -rect.minX,y: -rect.minY)
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c,flipped: true)
    CanvasFrameChrome.drawHeader(frame,context: c,scale: scale,appearance: appearance)
    return Data(bytes: try XCTUnwrap(c.data),count: c.bytesPerRow*height)
  }
  func testHeaderCacheReusesPlacementAndRefreshesTitleColorRoleFontAndBackingResolution() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("header-cache-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory); CanvasFrameChrome.clearHeaderCache() }
    let appearance = InterfaceAppearance(file: directory.appendingPathComponent("appearance.json"))
    let project = Project(name: "Native frame header")
    let object = try project.makeObject(recipeID: "artboard",name: "Desert collection")
    var frame = CanvasFrame(object: object,surfaceObject: object,rect: .init(x: 10,y: 40,width: 200,height: 100),artwork: .init())
    CanvasFrameChrome.clearHeaderCache()
    let before = CanvasFrameChrome.headerCacheBuilds, first = try draw(frame,appearance: appearance)
    XCTAssertTrue(first.contains { $0 > 0 }, "A native frame header must contain visible text/icon pixels.")
    frame.rect.origin = .init(x: 800,y: -500)
    XCTAssertEqual(try draw(frame,appearance: appearance),first)
    XCTAssertEqual(CanvasFrameChrome.headerCacheBuilds,before+1)
    frame.object.name = "Updated frame title"
    let renamed = try draw(frame,appearance: appearance)
    XCTAssertNotEqual(renamed,first); XCTAssertEqual(CanvasFrameChrome.headerCacheBuilds,before+2)
    try appearance.setFrameColor("#98381C",for: .artboard)
    XCTAssertNotEqual(try draw(frame,appearance: appearance),renamed)
    XCTAssertEqual(CanvasFrameChrome.headerCacheBuilds,before+3)
    frame.legacyDieline = true
    _ = try draw(frame,appearance: appearance)
    XCTAssertEqual(CanvasFrameChrome.headerCacheBuilds,before+4)
    TypographyEngine.invalidateFonts()
    _ = try draw(frame,appearance: appearance)
    XCTAssertEqual(CanvasFrameChrome.headerCacheBuilds,before+5)
    _ = try draw(frame,appearance: appearance,density: 1)
    XCTAssertEqual(CanvasFrameChrome.headerCacheBuilds,before+6)
  }
  func testHeaderPixelsRemainBoundedWhenBrowsingManyDifferentFrames() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("header-cache-budget-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory); CanvasFrameChrome.clearHeaderCache() }
    let appearance = InterfaceAppearance(file: directory.appendingPathComponent("appearance.json"))
    let project = Project(name: "Header retention")
    let object = try project.makeObject(recipeID: "artboard")
    var frame = CanvasFrame(object: object,surfaceObject: object,rect: .init(x: 0,y: 0,width: 300,height: 100),artwork: .init())
    CanvasFrameChrome.clearHeaderCache()
    for index in 0..<540 {
      frame.object.name = "Independent frame \(index)"
      _ = try draw(frame,appearance: appearance)
      XCTAssertLessThanOrEqual(CanvasFrameChrome.headerCacheBytes,8*1024*1024)
    }
    CanvasFrameChrome.clearHeaderCache(); XCTAssertEqual(CanvasFrameChrome.headerCacheBytes,0)
  }
}

import AppKit
import FormCore
import XCTest
@testable import FormApp

/// AppKit may supply damage rectangles larger than a view's bounds on macOS 14+.
/// Draw into a larger shared surface so overpainting adjacent chrome is visible;
/// caching only the canvas bounds would hide the regression.
@MainActor final class CanvasDrawingBoundaryTests: XCTestCase {
  private let extent = 128
  private let inset: CGFloat = 32

  private func bitmap() throws -> (NSBitmapImageRep, NSGraphicsContext) {
    _ = NSApplication.shared
    let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: extent, pixelsHigh: extent, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    return (image, try XCTUnwrap(NSGraphicsContext(bitmapImageRep: image)))
  }

  private func matches(_ color: NSColor, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
    abs(color.redComponent-r) < 0.025 && abs(color.greenComponent-g) < 0.025
      && abs(color.blueComponent-b) < 0.025 && color.alphaComponent > 0.99
  }

  func testOversizedCanvasDamageCannotEraseNeighboringHeaderOrFooterPixels() throws {
    let (image, graphics) = try bitmap()
    let canvas = VectorCanvasView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    // A nil session deliberately covers the early-return path after background painting.
    XCTAssertNil(canvas.session)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphics.cgContext
    context.setFillColor(NSColor(deviceRed: 1, green: 0, blue: 1, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(extent), height: CGFloat(extent)))
    context.translateBy(x: inset, y: inset)
    canvas.draw(canvas.bounds.insetBy(dx: -24, dy: -24))

    var changedOutside = 0, paintedInside = 0
    for y in 0..<extent { for x in 0..<extent {
      let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
      // The square is centered, so bitmap row direction does not affect the boundary.
      if (32..<96).contains(x) && (32..<96).contains(y) {
        if matches(color, 242/255, 242/255, 242/255) { paintedInside += 1 }
      } else if !matches(color, 1, 0, 1) { changedOutside += 1 }
    } }
    XCTAssertEqual(changedOutside, 0, "An oversized dirtyRect must not paint neighboring UI.")
    XCTAssertGreaterThan(paintedInside, 3600, "The canvas background must still paint normally.")
  }

  func testCanvasRenderingRestoresGraphicsTransformAndClipForNextSibling() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    defer { store.engine.project = nil; try? FileManager.default.removeItem(at: root) }
    store.engine.project = Project(name: "Drawing boundary")
    let canvas = VectorCanvasView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    canvas.session = store.artworkSession
    let (image, graphics) = try bitmap()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphics.cgContext
    context.setFillColor(NSColor(deviceRed: 1, green: 0, blue: 1, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(extent), height: CGFloat(extent)))
    context.translateBy(x: inset, y: inset)
    let transform = context.ctm, clip = context.boundingBoxOfClipPath
    canvas.draw(canvas.bounds.insetBy(dx: -24, dy: -24))
    XCTAssertEqual(context.ctm.a, transform.a); XCTAssertEqual(context.ctm.b, transform.b)
    XCTAssertEqual(context.ctm.c, transform.c); XCTAssertEqual(context.ctm.d, transform.d)
    XCTAssertEqual(context.ctm.tx, transform.tx); XCTAssertEqual(context.ctm.ty, transform.ty)
    XCTAssertEqual(context.boundingBoxOfClipPath, clip, "Canvas clipping must not leak into subsequent controls.")

    // A following sibling lies outside the canvas. A leaked clip would suppress it;
    // a leaked points/mm transform would move or resize it.
    context.setFillColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1).cgColor)
    context.fill(CGRect(x: -24, y: -24, width: 8, height: 8))
    var green = 0
    for y in 0..<extent { for x in 0..<extent {
      let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
      if matches(color, 0, 1, 0) { green += 1 }
    } }
    XCTAssertEqual(green, 64, "A sibling must retain its own coordinates and drawing area after canvas rendering.")
  }
}

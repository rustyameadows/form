import AppKit
import FormCore
import FormGraphics
import XCTest

@MainActor final class EmptyPaintCoverageTests: XCTestCase {
  private func image(_ elements: [ArtworkElement], background: String = "#FFFFFF", opacity: Double = 0) throws -> NSBitmapImageRep {
    var artwork = Artwork(background: background, elements: elements, bleed: 0)
    artwork.backgroundOpacity = opacity
    return try XCTUnwrap(ArtworkRenderer.image(artwork, width: 60, height: 40,
      assets: FileManager.default.temporaryDirectory, pixelsPerMM: 4).representations.first as? NSBitmapImageRep)
  }
  private func pixels(_ image: NSBitmapImageRep) -> [NSColor] {
    // ArtworkRenderer already writes sRGB bytes. NSBitmapImageRep.colorAt
    // exposes those stored channels; converting its calibrated NSColor again
    // would transform the fixture's sRGB values a second time.
    (0..<image.pixelsHigh).flatMap { y in
      (0..<image.pixelsWide).compactMap { x in image.colorAt(x: x, y: y) }
    }
  }
  private func text(_ content: String, height: Double = 20) -> ArtworkElement {
    var element = ArtworkElement(kind: "text", x: 5, y: 5, width: 45, height: height,
      text: content, color: "#0E1F33", fontSize: 28)
    var typography = Typography(); typography.fontName = "Helvetica-Bold"
    element.typography = typography
    element.paintStack = [.init(.init(color: "#0E1F33"))]
    return element
  }
  func testEmptyWhitespaceAndOversetTextNeverFillTheEnclosingClip() throws {
    for element in [text(""), text("   \n  "), text("Aa", height: 0.5)] {
      XCTAssertTrue(try TextPaintRenderer.vectorLayers(element).isEmpty)
      let bitmap = try image([element])
      XCTAssertTrue(pixels(bitmap).allSatisfy { $0.alphaComponent == 0 },
        "A paint with no shaped glyphs must leave the entire canvas transparent")
      var strokeOnly = element
      strokeOnly.paintStack = [.init(.init(color: "#FF0000"), stroke: .init(width: 1))]
      XCTAssertTrue(pixels(try image([strokeOnly])).allSatisfy { $0.alphaComponent == 0 })
    }
  }
  func testUnusedBasePaintDoesNotFloodAroundFullyOverriddenText() throws {
    var element = text("EDIT")
    element.paintStack = [.init(.init(color: "#0000FF"))]
    var span = TextSpan(location: 0, length: element.text.utf16.count, typography: element.typography!, fontSize: element.fontSize, color: "#FF0000")
    span.paintStack = [.init(.init(color: "#FF0000"))]; element.textRuns = [span]
    let layers = try TextPaintRenderer.vectorLayers(element)
    XCTAssertEqual(layers.count, 1); XCTAssertEqual(layers.first?.1.color, "#FF0000")
    let colors = pixels(try image([element]))
    XCTAssertGreaterThan(colors.filter { $0.alphaComponent > 0.8 && $0.redComponent > 0.9 }.count, 100)
    XCTAssertFalse(colors.contains { $0.alphaComponent > 0.1 && $0.blueComponent > 0.9 })
    XCTAssertGreaterThan(colors.filter { $0.alphaComponent == 0 }.count, colors.count / 2)
  }
  func testOversetPaintInsideRoundedPanelPreservesPanelAndVisibleSiblingText() throws {
    var group = ArtworkElement(kind: "group", x: 2, y: 2, width: 56, height: 36)
    group.contentSize = .init(56, 36)
    var background = ArtworkElement(kind: "rectangle", x: 0, y: 0, width: 56, height: 36, color: "#E5DECC")
    background.cornerRadius = 3; background.parentID = group.id
    var mask = background; mask.id = UUID(); mask.hidden = true
    var contents = ArtworkElement(kind: "group", x: 0, y: 0, width: 56, height: 36)
    contents.contentSize = .init(56, 36); contents.parentID = group.id; contents.clipID = mask.id
    var empty = text("Aa", height: 0.5); empty.parentID = contents.id
    var label = text("Visible"); label.fontSize = 15; label.parentID = contents.id; label.y = 15
    let bitmap = try image([group, background, mask, contents, label, empty])
    let untouched = try XCTUnwrap(bitmap.colorAt(x: 180, y: 32))
    XCTAssertEqual(untouched.redComponent, 229.0 / 255, accuracy: 0.01)
    XCTAssertEqual(untouched.greenComponent, 222.0 / 255, accuracy: 0.01)
    XCTAssertEqual(untouched.blueComponent, 204.0 / 255, accuracy: 0.01)
    XCTAssertGreaterThan(pixels(bitmap).filter { $0.alphaComponent > 0.9 && $0.redComponent < 0.15 }.count, 30)
  }
  func testEmptyVectorFillAndStrokePaintsLeaveCanvasTransparent() throws {
    var path = ArtworkElement(kind: "path", x: 5, y: 5, width: 30, height: 20)
    path.path = .init(width: 30, height: 20, contours: [])
    path.paintStack = [.init(.init(color: "#0000FF")),
      .init(.init(kind: "gradient", gradient: .init()), stroke: .init(width: 2))]
    XCTAssertTrue(pixels(try image([path])).allSatisfy { $0.alphaComponent == 0 })
  }
}

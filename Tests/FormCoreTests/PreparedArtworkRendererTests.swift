import AppKit
import XCTest
import FormCore
@testable import FormGraphics

@MainActor final class PreparedArtworkRendererTests: XCTestCase {
  private let assets = FileManager.default.temporaryDirectory
  private func pixels(_ art: Artwork, prepared: ArtworkRenderer.Prepared? = nil,
    excluding: Set<UUID> = [], viewport: CGRect = .init(x: 0, y: 0, width: 80, height: 60), scale: Double = 3) throws -> Data {
    let width = Int(ceil(viewport.width*scale)), height = Int(ceil(viewport.height*scale))
    let c = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    c.translateBy(x: -viewport.minX*scale, y: viewport.maxY*scale); c.scaleBy(x: scale, y: -scale)
    c.clip(to: viewport)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }
    if let prepared { prepared.draw(width: 400, height: 240, unbounded: true) }
    else { ArtworkRenderer.draw(art, width: 400, height: 240, assets: assets, production: false, excluding: excluding, unbounded: true) }
    return Data(bytes: try XCTUnwrap(c.data), count: height*c.bytesPerRow)
  }
  func testPreparedDenseVectorDrawingMatchesNativePixelsAndReusesGeometryAcrossPanAndZoom() throws {
    var elements: [ArtworkElement] = []
    for row in 0..<20 {
      let group = ArtworkElement(kind: "group", x: Double(row%5)*80, y: Double(row/5)*60, width: 75, height: 55)
      elements.append(group)
      for n in 0..<30 {
        var shape = ArtworkElement(kind: n%2 == 0 ? "ellipse":"rectangle", x: Double(n%6)*12, y: Double(n/6)*10, width: 9, height: 7, color: n%2 == 0 ? "#367354":"#D89443")
        shape.parentID = group.id; elements.append(shape)
      }
    }
    let art = Artwork(elements: elements), prepared = try ArtworkRenderer.Prepared(art, assets: assets)
    for rect in [CGRect(x: 0,y: 0,width: 80,height: 60),CGRect(x: 80,y: 0,width: 80,height: 60),CGRect(x: 160,y: 60,width: 80,height: 60)] {
      XCTAssertEqual(try pixels(art, prepared: prepared, viewport: rect), try pixels(art, viewport: rect))
      XCTAssertGreaterThan(prepared.diagnostics["culled_elements"] ?? 0, 0)
      XCTAssertLessThan(prepared.diagnostics["drawn_elements"] ?? Int.max, 100)
    }
    let builds = prepared.diagnostics["vector_paths"]
    for _ in 0..<10 { _ = try pixels(art, prepared: prepared) }
    XCTAssertEqual(prepared.diagnostics["vector_paths"], builds)
    XCTAssertEqual(prepared.preparations, 1)
    XCTAssertEqual(try pixels(art, prepared: prepared, scale: 5), try pixels(art, scale: 5))
    XCTAssertEqual(prepared.diagnostics["vector_paths"], builds)
  }
  func testCullingPreservesMasksBlendGroupsAndAnOffscreenSourceWhoseShadowEntersViewport() throws {
    var background = ArtworkElement(kind: "rectangle", x: 0, y: 0, width: 80, height: 60, color: "#33CCBB")
    background.name = "Backdrop"
    var mask = ArtworkElement(kind: "ellipse", x: 5, y: 5, width: 45, height: 40, color: "#FFFFFF")
    mask.hidden = true; mask.opacity = 0.5
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 60, height: 50)
    group.clipID = mask.id; group.clipMode = "alpha"; group.opacity = 0.75
    var fill = ArtworkElement(kind: "rectangle", x: 0, y: 0, width: 60, height: 50, color: "#F05533")
    fill.parentID = group.id; fill.blendMode = "multiply"
    var caster = ArtworkElement(kind: "rectangle", x: 130, y: 20, width: 15, height: 15, color: "#FFFFFF")
    caster.effectStack = .init(coverage: "paint-outline", effects: [.init(kind: "drop-shadow", offset: .init(-80,0), blur: 2, color: "#443399")])
    let art = Artwork(elements: [background,mask,group,fill,caster])
    for excluded in [Set<UUID>(),Set([group.id])] {
      let prepared = try ArtworkRenderer.Prepared(art, assets: assets, excluding: excluded)
      XCTAssertEqual(try pixels(art, prepared: prepared), try pixels(art, excluding: excluded))
    }
  }
  func testFontInvalidationRebuildsPreparedGeometryWithoutChangingItsImmutableSource() throws {
    let text = ArtworkElement(kind: "text", x: 4, y: 3, width: 65, height: 35, text: "Reusable vector text", fontSize: 13)
    let art = Artwork(elements: [text]), prepared = try ArtworkRenderer.Prepared(art, assets: assets)
    let first = try pixels(art, prepared: prepared)
    TypographyEngine.invalidateFonts()
    XCTAssertEqual(try pixels(art, prepared: prepared), first)
    XCTAssertEqual(prepared.preparations, 2)
    XCTAssertEqual(try pixels(art, prepared: prepared), try pixels(art))
  }
}

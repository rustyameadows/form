import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

final class AppearanceTests: XCTestCase {
  private let assets = URL(fileURLWithPath: "/tmp")
  private func box(_ x: Double = 20, _ y: Double = 20, color: String = "#FF0000") -> ArtworkElement {
    .init(kind: "rectangle", x: x, y: y, width: 20, height: 20, color: color)
  }
  @MainActor private func bitmap(_ elements: [ArtworkElement], background: String = "#FFFFFF",
    transparent: Bool = false) -> NSBitmapImageRep {
    var art = Artwork(background: background, elements: elements, bleed: 0)
    if transparent { art.backgroundOpacity = 0 }
    return ArtworkRenderer.image(art, width: 100, height: 100, assets: assets, pixelsPerMM: 2)
      .representations[0] as! NSBitmapImageRep
  }
  @MainActor private func pixel(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
    // colorAt returns calibrated RGB despite the bitmap's sRGB tag. Preserve
    // the stored sample values instead of converting those values a second time.
    let c = image.colorAt(x: x * 2, y: y * 2)!
    return NSColor(colorSpace: image.colorSpace,
      components: [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent], count: 4)
      .usingColorSpace(.sRGB)!
  }
  @MainActor private func bytes(_ image: NSBitmapImageRep) -> Data {
    image.representation(using: .png, properties: [:])!
  }
  private func fixture() throws -> (Project, UUID, UUID) {
    var p = Project(name: "Appearance")
    var sheet = try p.makeObject(recipeID: "artboard")
    let e = box()
    sheet.artwork = .init(background: "#FFFFFF", elements: [e], bleed: 0)
    p.objects = [sheet]
    return (p, sheet.id, e.id)
  }

  func testAppearancePatchesPreserveDisabledSettingsAndRejectInvalidEditsAtomically() throws {
    var (p, sheet, id) = try fixture()
    try AppearanceCommands.apply(in: &p, objectID: sheet, ids: [id], values: [
      "blend_mode": "multiply", "opacity": 0.5,
      "blur": ["radius": 2.0], "shadow": ["x": -5.0, "y": 3.0, "blur": 1.0],
    ])
    try AppearanceCommands.apply(in: &p, objectID: sheet, ids: [id], values: ["blur": ["enabled": false]])
    let e = p.objects[0].artwork!.elements[0]
    XCTAssertEqual(e.blur?.radius, 2)
    XCTAssertEqual(e.blur?.enabled, false)
    XCTAssertEqual(e.shadow?.offset, .init(-5, 3))
    let before = p
    for values: [String: Any] in [["blur": ["radius": -1]], ["shadow": ["x": 101]],
      ["shadow": ["opacity": 2]], ["shadow": ["color": "bad"]], ["blend_mode": "unsupported"],
      ["opacity": true], ["blur": ["enabled": 1]], ["blur": ["radius": Double.nan]],
      ["unexpected": 1]] {
      XCTAssertThrowsError(try AppearanceCommands.apply(in: &p, objectID: sheet, ids: [id], values: values))
      XCTAssertEqual(p, before)
    }
    try AppearanceCommands.apply(in: &p, objectID: sheet, ids: [id], values: [:], reset: true)
    XCTAssertNil(p.objects[0].artwork!.elements[0].blur)
    XCTAssertNil(p.objects[0].artwork!.elements[0].shadow)
    XCTAssertNil(p.objects[0].artwork!.elements[0].blendMode)
    XCTAssertNil(p.objects[0].artwork!.elements[0].opacity)
  }

  func testLockedRootsAndMasksRejectAppearance() throws {
    var (p, sheet, id) = try fixture()
    p.objects[0].artwork!.elements[0].locked = true
    var before = p
    XCTAssertThrowsError(try AppearanceCommands.apply(in: &p, objectID: sheet, ids: [id], values: ["opacity": 0.5]))
    XCTAssertEqual(p, before)
    p.objects[0].artwork!.elements[0].locked = nil
    let mask = box()
    p.objects[0].artwork!.elements[0].clipID = mask.id
    p.objects[0].artwork!.elements.append(mask)
    before = p
    XCTAssertThrowsError(try AppearanceCommands.apply(in: &p, objectID: sheet, ids: [mask.id], values: ["blur": [:]]))
    XCTAssertEqual(p, before)
  }

  func testShadowSwatchesResolveAndDeleteWithoutChangingAppearanceValues() throws {
    var (p, sheet, id) = try fixture()
    let swatch = try SwatchCommands.save(in: &p, name: "Shadow", color: "#263C64")
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [id], target: "shadow", swatchID: swatch)
    try SwatchCommands.save(in: &p, id: swatch, name: "Shadow", color: "#849381")
    let before = p.surfaceArtwork(p.objects[0])!
    XCTAssertEqual(before.elements[0].shadow?.color, "#849381")
    try SwatchCommands.delete(in: &p, id: swatch)
    XCTAssertEqual(p.surfaceArtwork(p.objects[0]), before)
    XCTAssertNil(p.objects[0].artwork!.elements[0].shadow?.swatchID)
  }

  func testDetachingMissingPaintDoesNotCreateAShadowOrStroke() throws {
    var (p, sheet, id) = try fixture()
    let before = p
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [id], target: "shadow", swatchID: nil)
    try SwatchCommands.assign(in: &p, objectID: sheet, ids: [id], target: "stroke", swatchID: nil)
    XCTAssertEqual(p, before)
  }

  @MainActor func testLayerOpacityIsAppliedOnceAcrossFillAndStroke() {
    var e = box()
    e.stroke = .init(color: "#FF0000", width: 8)
    e.opacity = 0.5
    let image = bitmap([e])
    XCTAssertEqual(pixel(image, 22, 30).greenComponent, 0.5, accuracy: 0.01)
    XCTAssertEqual(pixel(image, 30, 30).greenComponent, 0.5, accuracy: 0.01)
  }

  @MainActor func testGroupOpacityIsAppliedOnceAcrossOverlapsAndNestedOpacityMultiplies() {
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 100, height: 100)
    group.contentSize = .init(100, 100)
    group.opacity = 0.5
    var a = box(), b = box(30, 20)
    a.parentID = group.id; b.parentID = group.id
    let image = bitmap([group, a, b])
    XCTAssertEqual(pixel(image, 25, 30).greenComponent, 0.5, accuracy: 0.01)
    XCTAssertEqual(pixel(image, 35, 30).greenComponent, 0.5, accuracy: 0.01)
    a.opacity = 0.5
    let nested = bitmap([group, a])
    XCTAssertEqual(pixel(nested, 25, 30).greenComponent, 0.75, accuracy: 0.01)
  }

  @MainActor func testBlendModesCompositeAgainstTheActualBackdrop() {
    for (mode, expected): (String, [Double]) in [
      ("multiply", [0.4, 0.2, 0.1]), ("screen", [0.9, 0.7, 0.6]),
      ("difference", [0.3, 0.1, 0.3]), ("darken", [0.5, 0.4, 0.2]),
    ] {
      var e = box(color: "#CC6633")
      e.blendMode = mode
      let color = pixel(bitmap([e], background: "#808080"), 30, 30)
      XCTAssertEqual(color.redComponent, expected[0], accuracy: 0.015, mode)
      XCTAssertEqual(color.greenComponent, expected[1], accuracy: 0.015, mode)
      XCTAssertEqual(color.blueComponent, expected[2], accuracy: 0.015, mode)
    }
  }

  @MainActor func testGaussianBlurExtendsOutsideGeometryWithoutDarkFringes() {
    var e = box()
    e.blur = .init(); e.blur?.radius = 2
    let image = bitmap([e], transparent: true)
    let outside = pixel(image, 18, 30)
    XCTAssertGreaterThan(outside.alphaComponent, 0.05)
    XCTAssertLessThan(outside.alphaComponent, 0.5)
    XCTAssertGreaterThan(outside.redComponent, 0.95)
    XCTAssertGreaterThan(pixel(image, 30, 30).alphaComponent, 0.95)
    XCTAssertLessThan(pixel(image, 5, 30).alphaComponent, 0.01)
  }

  @MainActor func testDropShadowUsesDownwardArtworkCoordinatesAndLayerOpacity() {
    var e = box()
    e.shadow = .init(); e.shadow?.offset = .init(12, 8)
    e.shadow?.blur = 0; e.shadow?.color = "#0000FF"; e.shadow?.opacity = 0.5
    let image = bitmap([e], transparent: true)
    XCTAssertGreaterThan(pixel(image, 25, 25).redComponent, 0.95)
    XCTAssertGreaterThan(pixel(image, 45, 45).blueComponent, 0.95)
    XCTAssertEqual(pixel(image, 45, 45).alphaComponent, 0.5, accuracy: 0.01)
    XCTAssertLessThan(pixel(image, 45, 15).alphaComponent, 0.01)
    e.opacity = 0.5
    XCTAssertEqual(pixel(bitmap([e], transparent: true), 45, 45).alphaComponent, 0.25, accuracy: 0.01)
  }

  @MainActor func testShadowFilteringRetainsOpaqueSourceRGB() {
    var e = box(color: "#D45A37")
    let plain = pixel(bitmap([e]), 30, 30)
    e.shadow = .init(); e.shadow?.opacity = 0.23
    let filtered = pixel(bitmap([e]), 30, 30)
    XCTAssertEqual(filtered.redComponent, plain.redComponent, accuracy: 0.01)
    XCTAssertEqual(filtered.greenComponent, plain.greenComponent, accuracy: 0.01)
    XCTAssertEqual(filtered.blueComponent, plain.blueComponent, accuracy: 0.01)
  }

  @MainActor func testClipAppliesAfterBlurAndShadow() {
    var e = box()
    var mask = box(); mask.width = 15; mask.height = 40
    e.clipID = mask.id
    e.blur = .init(); e.blur?.radius = 1
    e.shadow = .init(); e.shadow?.offset = .init(20, 0)
    let image = bitmap([e, mask], transparent: true)
    XCTAssertGreaterThan(pixel(image, 25, 30).alphaComponent, 0.95)
    XCTAssertLessThan(pixel(image, 38, 30).alphaComponent, 0.01)
    XCTAssertLessThan(pixel(image, 55, 30).alphaComponent, 0.01)
  }

  @MainActor func testDisabledEffectsArePixelIdenticalToPlainArtwork() {
    var e = box()
    let plain = bytes(bitmap([e]))
    e.blur = .init(); e.blur?.radius = 4; e.blur?.enabled = false
    e.shadow = .init(); e.shadow?.enabled = false
    XCTAssertEqual(bytes(bitmap([e])), plain)
  }

  @MainActor func testEffectCacheReusesPlacementAndIndependentInstanceIdentity() {
    AppearanceRenderer.invalidateFonts()
    var e = box(color: "#9182AB")
    e.blur = .init(); e.blur?.radius = 1.25
    let start = AppearanceRenderer.diagnostics["builds"] as! Int
    _ = bitmap([e])
    XCTAssertEqual(AppearanceRenderer.diagnostics["builds"] as! Int, start + 1)
    e.x = 45; e.id = UUID(); e.name = "Another placement"
    _ = bitmap([e])
    XCTAssertEqual(AppearanceRenderer.diagnostics["builds"] as! Int, start + 1)
    e.blur?.radius = 2
    _ = bitmap([e])
    XCTAssertEqual(AppearanceRenderer.diagnostics["builds"] as! Int, start + 2)
  }

  func testSchemaEightPersistsDisabledEffectsAndLegacyDocumentsRemainReadable() throws {
    var (p, sheet, id) = try fixture()
    try AppearanceCommands.apply(in: &p, objectID: sheet, ids: [id], values: ["blur": ["enabled": false, "radius": 3]])
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try ProjectRepository(root: folder)
    try repo.save(p)
    var loaded = try repo.load(p.id)
    XCTAssertEqual(loaded.schemaVersion, 8)
    XCTAssertEqual(loaded.objects, p.objects)
    loaded.objects[0].artwork!.elements[0].blur = nil
    loaded.schemaVersion = 1
    try repo.save(loaded)
    XCTAssertLessThan(try repo.load(p.id).schemaVersion, 8)
  }

  @MainActor func testSVGUsesLiveFiltersExpandedRegionsAndExplicitGroupIsolation() throws {
    var e = box()
    e.blur = .init(); e.blur?.radius = 2
    e.shadow = .init(); e.shadow?.offset = .init(-6, 4)
    e.blendMode = "multiply"
    let art = Artwork(background: "#FFFFFF", elements: [e], bleed: 0)
    let svg = try SVGRenderer.document(art, width: 100, height: 100, assets: assets)
    XCTAssertTrue(svg.contains("feGaussianBlur"))
    XCTAssertTrue(svg.contains("stdDeviation=\"2.0\""))
    XCTAssertTrue(svg.contains("feDropShadow in=\"blurred\""))
    XCTAssertTrue(svg.contains("dx=\"-6.0\" dy=\"4.0\""))
    XCTAssertTrue(svg.contains("color-interpolation-filters=\"sRGB\""))
    XCTAssertTrue(svg.contains("mix-blend-mode:multiply"))
    XCTAssertTrue(svg.contains("filterUnits=\"userSpaceOnUse\""))
    XCTAssertTrue(svg.contains("isolation:isolate"))
    XCTAssertFalse(svg.contains("<image"))
  }

  @MainActor func testEffectOutputRefusesSilentResolutionReduction() throws {
    var e = box()
    e.blur = .init()
    let art = Artwork(elements: [e])
    XCTAssertNoThrow(try ArtworkRenderer.validateAppearanceOutput(art, assets: assets, pixelsPerMM: 12))
    e.width = 10000
    XCTAssertThrowsError(try ArtworkRenderer.validateAppearanceOutput(.init(elements: [e]), assets: assets, pixelsPerMM: 12))
  }

  func testSelectionExportsReserveAppearanceBoundsButKeepGeometricHandles() throws {
    var e = box()
    e.blur = .init(); e.blur?.radius = 2
    e.shadow = .init(); e.shadow?.offset = .init(12, 8); e.shadow?.blur = 1
    let art = Artwork(elements: [e])
    XCTAssertEqual(art.bounds(of: e), .init(20, 20, 20, 20))
    let exported = try art.exporting([e.id])
    XCTAssertLessThanOrEqual(exported.bounds.x, 12)
    XCTAssertGreaterThanOrEqual(exported.bounds.maxX, 64)
    XCTAssertGreaterThan(exported.bounds.height, 20)
  }

  func testUngroupDoesNotSilentlyDiscardCombinedAppearance() throws {
    var a = box(), b = box(30, 20)
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 100, height: 100)
    group.contentSize = .init(100, 100)
    group.shadow = .init()
    a.parentID = group.id; b.parentID = group.id
    var art = Artwork(elements: [group, a, b])
    let before = art
    XCTAssertThrowsError(try ArtworkCommands.apply("ungroup", to: &art, ids: [group.id]))
    XCTAssertEqual(art, before)
  }

  @MainActor func testGaussianBlurMatchesPhysicalStandardDeviation() {
    // NSImage's SVG decoder omits filters and blending, so it cannot serve as
    // an effects reference. Check Gaussian coverage against the analytic CDF.
    var e = box()
    e.blur = .init(); e.blur?.radius = 2
    let image = bitmap([e], transparent: true)
    func cdf(_ value: Double) -> Double { (1 + erf(value / sqrt(2))) / 2 }
    for x in 14...26 {
      let center = Double(x) + 0.25
      let horizontal = cdf((40 - center) / 2) - cdf((20 - center) / 2)
      let vertical = cdf((40 - 30.25) / 2) - cdf((20 - 30.25) / 2)
      XCTAssertEqual(pixel(image, x, 30).alphaComponent, horizontal * vertical, accuracy: 0.03)
    }
  }

  @MainActor func testGroupsPassBlendsThroughUnlessExplicitlyIsolated() {
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 100, height: 100)
    group.contentSize = .init(100, 100)
    var e = box(color: "#CC6633")
    e.blendMode = "multiply"; e.parentID = group.id
    var c = pixel(bitmap([group, e], background: "#808080"), 30, 30)
    XCTAssertEqual(c.redComponent, 0.4, accuracy: 0.015)
    XCTAssertEqual(c.greenComponent, 0.2, accuracy: 0.015)
    group.isolatedBlending = true
    c = pixel(bitmap([group, e], background: "#808080"), 30, 30)
    XCTAssertEqual(c.redComponent, 0.8, accuracy: 0.015)
    XCTAssertEqual(c.greenComponent, 0.4, accuracy: 0.015)
  }

  @MainActor func testComponentCreationPreservesBlendingAndShadowAppearance() throws {
    var (p, sheet, id) = try fixture()
    p.objects[0].artwork!.background = "#808080"
    p.objects[0].artwork!.elements[0].blendMode = "multiply"
    p.objects[0].artwork!.elements[0].shadow = .init()
    func png(_ project: Project) -> Data {
      let image = ArtworkRenderer.image(project.surfaceArtwork(project.objects[0])!,
        width: 100, height: 100, assets: assets, pixelsPerMM: 2)
      return bytes(image.representations[0] as! NSBitmapImageRep)
    }
    let before = png(p)
    _ = try ComponentCommands.create(in: &p, objectID: sheet, elements: [id], name: "Shadowed mark")
    XCTAssertEqual(png(p), before)
    let source = p.objects.last!
    XCTAssertGreaterThan(source.artworkSize.x, 20)
    XCTAssertGreaterThan(source.artworkSize.y, 20)
  }
}

import AppKit
import XCTest

@testable import FormCore
@testable import FormGraphics

final class PaintTests: XCTestCase {
  private let assets = URL(fileURLWithPath: "/tmp")
  private func shape(_ kind: String = "rectangle", x: Double = 20, y: Double = 20) -> ArtworkElement
  {
    .init(kind: kind, x: x, y: y, width: 30, height: 25, color: "#E45B34")
  }
  private func fixture(_ elements: [ArtworkElement]) throws -> (Project, UUID) {
    var p = Project(name: "Paint")
    var sheet = try p.makeObject(recipeID: "artboard")
    sheet.artwork = .init(background: "#FFFFFF", elements: elements, bleed: 0)
    p.objects = [sheet]
    return (p, sheet.id)
  }
  @MainActor private func image(_ art: Artwork) -> NSBitmapImageRep {
    ArtworkRenderer.image(art, width: 100, height: 100, assets: assets, pixelsPerMM: 2)
      .representations[0] as! NSBitmapImageRep
  }
  @MainActor private func difference(_ a: Artwork, _ b: Artwork) -> Double {
    let lhs = image(a)
    let rhs = image(b)
    var total = 0.0
    for y in 0..<lhs.pixelsHigh {
      for x in 0..<lhs.pixelsWide {
        let c = lhs.colorAt(x: x, y: y)!
        let d = rhs.colorAt(x: x, y: y)!
        total +=
          abs(c.redComponent - d.redComponent) + abs(c.greenComponent - d.greenComponent)
          + abs(c.blueComponent - d.blueComponent) + abs(c.alphaComponent - d.alphaComponent)
      }
    }
    return total / Double(lhs.pixelsHigh * lhs.pixelsWide * 4)
  }
  func testStrokePatchesRetainDisabledStylesAndRejectInvalidEditsAtomically() throws {
    let e = shape()
    var (p, sheet) = try fixture([e])
    try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [e.id],
      arguments: [
        "stroke": [
          "width": 4, "color": "#224B9B", "opacity": 0.5, "cap": "round", "join": "bevel",
          "miter": 3, "dash": [0, 2, 4], "dash_offset": -3, "alignment": "outside",
        ]
      ])
    try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [e.id], arguments: ["stroke": ["enabled": false]])
    let stored = p.objects[0].artwork!.elements[0].stroke!
    XCTAssertEqual(stored.width, 4)
    XCTAssertEqual(stored.dash, [0, 2, 4])
    XCTAssertNil(p.objects[0].artwork!.elements[0].visibleStroke)
    let before = p
    for values: [String: Any] in [
      ["width": true], ["enabled": 1], ["width": Double.nan], ["opacity": 2], ["dash": [0, 0]],
      ["dash": [-1, 2]], ["dash": Array(repeating: 1, count: 17)], ["alignment": "invalid"],
      ["miter": 0], ["unknown": 1],
    ] {
      XCTAssertThrowsError(
        try PaintCommands.apply(in: &p, objectID: sheet, ids: [e.id], arguments: ["stroke": values])
      )
      XCTAssertEqual(p, before)
    }
    try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [e.id], arguments: ["stroke": ["enabled": true]])
    XCTAssertEqual(p.objects[0].artwork!.elements[0].visibleStroke?.width, 4)
  }
  func testDashPatternUnitsZeroDotsOddPatternsAndInvalidSyntax() throws {
    XCTAssertEqual(try StrokePattern.parse("0, 2, 4", unit: .mm), [0, 2, 4])
    XCTAssertEqual(try StrokePattern.parse("1, .5 in", unit: .cm), [10, 12.7])
    XCTAssertNil(try StrokePattern.parse(" ", unit: .mm))
    for input in ["0,0", "1,,2", "-1,2", "1001", "NaN,2"] {
      XCTAssertThrowsError(try StrokePattern.parse(input, unit: .mm))
    }
  }
  func testStopUUIDSurvivesCrossingAndEqualOffsetsKeepHardEdgeOrder() throws {
    var e = shape()
    e.gradient = .init(stops: [.init(0, "#FF0000"), .init(0.5, "#00FF00"), .init(1, "#0000FF")])
    let middle = e.gradient!.stops[1].id
    let last = e.gradient!.stops[2].id
    var (p, sheet) = try fixture([e])
    try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [e.id], command: "update_stop",
      arguments: ["stop_id": middle.uuidString, "offset": 1.0, "opacity": 0.4])
    var g = p.objects[0].artwork!.elements[0].gradient!
    XCTAssertEqual(g.stops.suffix(2).map(\.id), [middle, last])
    XCTAssertEqual(g.sampledStop(at: 1).color, "#0000FF")
    try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [e.id], command: "update_stop",
      arguments: ["stop_id": last.uuidString, "offset": 0.2, "color": "#123456"])
    g = p.objects[0].artwork!.elements[0].gradient!
    XCTAssertEqual(g.stops[1].id, last)
    XCTAssertEqual(g.stops[2].id, middle)
    let before = p
    XCTAssertThrowsError(
      try PaintCommands.apply(
        in: &p, objectID: sheet, ids: [e.id], command: "update_stop",
        arguments: ["stop_id": middle.uuidString, "offset": 1.1]))
    XCTAssertEqual(p, before)
  }
  func testStopAddSamplesResolvedSwatchesAndRemoveKeepsTwoStops() throws {
    var e = shape()
    e.gradient = .init(stops: [.init(0, "#FF0000"), .init(1, "#0000FF")])
    var (p, sheet) = try fixture([e])
    let swatch = try SwatchCommands.save(in: &p, name: "Green", color: "#00FF00")
    try SwatchCommands.assign(
      in: &p, objectID: sheet, ids: [e.id], target: "gradient_stop", swatchID: swatch,
      stopID: e.gradient!.stops[0].id)
    let id = try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [e.id], command: "add_stop", arguments: [:])!
    let g = p.objects[0].artwork!.elements[0].gradient!
    XCTAssertEqual(g.stops[1].id, id)
    XCTAssertEqual(g.stops[1].color, "#008080")
    XCTAssertEqual(g.stops[1].offset, 0.5)
    XCTAssertNil(g.stops[1].swatchID)
    XCTAssertEqual(g.stops[0].swatchID, swatch)
    try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [e.id], command: "delete_stop",
      arguments: ["stop_id": id.uuidString])
    let before = p
    XCTAssertThrowsError(
      try PaintCommands.apply(
        in: &p, objectID: sheet, ids: [e.id], command: "delete_stop",
        arguments: ["stop_id": g.stops[0].id.uuidString]))
    XCTAssertEqual(p, before)
  }
  func testGradientTransformsReverseAndDuplicateStopValidation() throws {
    var e = shape()
    e.gradient = .init()
    var (p, sheet) = try fixture([e])
    try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [e.id],
      arguments: [
        "gradient": [
          "kind": "radial", "start": ["x": 0.2], "end": ["y": 0.7],
          "transform": ["a": 1.2, "b": 0.3, "tx": 5],
        ]
      ])
    let original = p
    try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [e.id], command: "reverse_stops", arguments: [:])
    try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [e.id], command: "reverse_stops", arguments: [:])
    XCTAssertEqual(p, original)
    var invalid = p.objects[0].artwork!
    invalid.elements[0].gradient!.stops[1].id = invalid.elements[0].gradient!.stops[0].id
    XCTAssertThrowsError(try validateArtwork(invalid))
  }
  @MainActor func testAddingInterpolatedAlphaStopPreservesNativePixels() throws {
    var e = shape()
    e.width = 75
    e.height = 70
    e.gradient = .init(
      start: .init(0, 0.2), end: .init(1, 0.8), stops: [.init(0, "#D45A37"), .init(1, "#224B9B")])
    e.gradient!.stops[0].opacity = 0.2
    e.gradient!.stops[1].opacity = 0.9
    var (p, sheet) = try fixture([e])
    let before = p.objects[0].artwork!
    try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [e.id], command: "add_stop", arguments: ["offset": 0.37])
    XCTAssertLessThan(difference(before, p.objects[0].artwork!), 0.001)
  }
  @MainActor func testDegenerateGradientUsesLastStopIncludingAlpha() {
    var e = shape()
    e.gradient = .init(
      start: .init(0.5, 0.5), end: .init(0.5, 0.5),
      stops: [.init(0, "#FF0000"), .init(1, "#0000FF")])
    var expected = e
    expected.gradient = nil
    expected.color = "#0000FF"
    expected.fillOpacity = 0.4
    e.gradient!.stops[1].opacity = 0.4
    XCTAssertLessThan(difference(.init(elements: [e]), .init(elements: [expected])), 0.0001)
  }
  @MainActor func testInsideCenterOutsideStrokeGeometryAndHoleDirection() throws {
    var e = shape()
    e.stroke = .init(width: 4)
    for (alignment, inset) in [("inside", 0.0), ("center", -2.0), ("outside", -4.0)] {
      e.stroke!.alignment = alignment
      let bounds = try StrokeGeometry.path(e).boundingBoxOfPath
      XCTAssertEqual(bounds.minX, inset, accuracy: 0.001)
      XCTAssertEqual(bounds.maxX, 30 - inset, accuracy: 0.001)
    }
    let path = CGMutablePath()
    path.addRect(.init(x: 0, y: 0, width: 30, height: 25))
    path.addRect(.init(x: 8, y: 8, width: 14, height: 9))
    var hole = try VectorGeometry.element(from: path, color: "#000000")
    hole.path!.evenOdd = true
    hole.stroke = .init(width: 2)
    hole.stroke!.alignment = "inside"
    let inside = try StrokeGeometry.path(hole)
    XCTAssertTrue(inside.contains(.init(x: 7, y: 12)))
    XCTAssertFalse(inside.contains(.init(x: 9, y: 12)))
    hole.stroke!.alignment = "outside"
    let outside = try StrokeGeometry.path(hole)
    XCTAssertFalse(outside.contains(.init(x: 7, y: 12)))
    XCTAssertTrue(outside.contains(.init(x: 9, y: 12)))
  }
  func testOpenPathsRejectAlignedStrokesAndMaskPaintIsNotEditable() throws {
    var line = shape("line")
    var mask = shape("ellipse")
    line.clipID = mask.id
    mask.hidden = true
    var (p, sheet) = try fixture([mask, line])
    let before = p
    XCTAssertThrowsError(
      try PaintCommands.apply(
        in: &p, objectID: sheet, ids: [line.id], arguments: ["stroke": ["alignment": "inside"]]))
    XCTAssertThrowsError(
      try PaintCommands.apply(in: &p, objectID: sheet, ids: [mask.id], arguments: ["gradient": [:]])
    )
    XCTAssertEqual(p, before)
  }
  @MainActor func testImplicitLineStrokeCanBeDisabledAndOutlined() throws {
    let line = shape("line")
    var (p, sheet) = try fixture([line])
    XCTAssertFalse(try StrokeGeometry.path(line).isEmpty)
    try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [line.id], arguments: ["stroke": ["enabled": false]])
    let disabled = p.objects[0].artwork!
    XCTAssertLessThan(
      difference(disabled, .init(background: "#FFFFFF", elements: [], bleed: 0)), 0.0001)
    XCTAssertThrowsError(try StrokeGeometry.path(disabled.elements[0]))
    try PaintCommands.apply(
      in: &p, objectID: sheet, ids: [line.id], arguments: ["stroke": NSNull()])
    XCTAssertNotNil(p.objects[0].artwork!.elements[0].visibleStroke)
  }
  @MainActor func testStrokeExpansionPreservesFillGradientAlphaEffectsClipAffineAndStack() throws {
    var e = shape()
    e.stroke = .init(color: "#224B9B", width: 3)
    e.stroke!.opacity = 0.6
    e.gradient = .init()
    e.opacity = 0.7
    e.fillOpacity = 0.6
    e.rotation = 13
    e.affine = .init(a: 1, b: 0.1, c: 0.2, d: 1, tx: 0, ty: 0)
    e.shadow = .init()
    e.shadow!.blur = 0.6
    var mask = shape("ellipse", x: 12, y: 12)
    mask.width = 55
    mask.height = 52
    e.clipID = mask.id
    let front = shape(x: 42, y: 32)
    for alignment in ["center", "inside", "outside"] {
      e.stroke!.alignment = alignment
      let art = Artwork(background: "#FFFFFF", elements: [mask, e, front], bleed: 0)
      let converted = try ArtworkOutlines.convert(art, ids: [e.id], mode: "stroke")
      XCTAssertLessThan(difference(art, converted.artwork), 0.002)
      XCTAssertEqual(converted.artwork.elements.last, front)
      XCTAssertEqual(converted.artwork.elements.first(where: { $0.id == e.id })?.hidden, true)
      XCTAssertEqual(converted.created.filter { $0.kind == "group" }.count, 1)
    }
  }
  @MainActor func testBooleanStrokeExpansionPreservesResultAndFill() throws {
    let a = shape()
    let b = shape("ellipse", x: 30, y: 25)
    var art = Artwork(elements: [a, b])
    let id = try BooleanCommands.create("subtract", artwork: &art, elements: [a.id, b.id])
    let ids: Set<UUID> = [id]
    let i = art.elements.firstIndex(where: { ids.contains($0.id) })!
    art.elements[i].stroke = .init(width: 2)
    art.elements[i].stroke!.alignment = "outside"
    art.elements[i].width *= 1.3
    art.elements[i].rotation = 11
    let result = try ArtworkOutlines.convert(art, ids: ids, mode: "stroke")
    XCTAssertLessThan(difference(art, result.artwork), 0.002)
  }
  @MainActor func testStrokeCacheIgnoresIdentityPlacementAndPaintButTracksGeometry() throws {
    var e = shape("star")
    e.stroke = .init(width: 1.37)
    e.sides = 7
    _ = try StrokeGeometry.path(e)
    let builds = StrokeGeometry.diagnostics["builds"] as! Int
    e.id = UUID()
    e.x = 77
    e.rotation = 13
    e.stroke!.color = "#224B9B"
    e.opacity = 0.2
    _ = try StrokeGeometry.path(e)
    XCTAssertEqual(StrokeGeometry.diagnostics["builds"] as! Int, builds)
    e.stroke!.width = 1.48
    _ = try StrokeGeometry.path(e)
    XCTAssertEqual(StrokeGeometry.diagnostics["builds"] as! Int, builds + 1)
  }
  @MainActor func testDenseDashExpansionRejectsBeforeAllocatingGeometry() throws {
    var e = shape()
    e.width = 1000
    e.stroke = .init(width: 1)
    e.stroke!.dash = [0.00001, 0.00001]
    XCTAssertThrowsError(try StrokeGeometry.path(e))
    XCTAssertTrue((StrokeGeometry.diagnostics["last_error"] as! String).contains("20,000"))
    XCTAssertThrowsError(
      try SVGRenderer.document(.init(elements: [e]), width: 1000, height: 100, assets: assets))
  }
  @MainActor func testPortableSVGExportsAlignedStrokeAsFilledGeometry() throws {
    var e = shape()
    e.stroke = .init(width: 2)
    e.stroke!.alignment = "outside"
    let svg = try SVGRenderer.document(
      .init(elements: [e]), width: 100, height: 100, assets: assets)
    XCTAssertFalse(svg.contains("stroke-alignment"))
    XCTAssertFalse(svg.contains("<image"))
    XCTAssertTrue(svg.contains("<path"))
    e.stroke!.alignment = nil
    e.stroke!.dash = [0, 3, 2]
    e.stroke!.dashOffset = -2
    let centered = try SVGRenderer.document(
      .init(elements: [e]), width: 100, height: 100, assets: assets)
    XCTAssertTrue(centered.contains("stroke-dasharray=\"0.0 3.0 2.0\""))
  }
  @MainActor func testDottedOddDashCapsJoinsAndPhaseMatchExpandedStroke() throws {
    for cap in ["butt", "round", "square"] {
      var e = shape("line")
      e.stroke = .init(color: "#224B9B", width: 2)
      e.stroke!.cap = cap
      e.stroke!.dash = cap == "round" ? [0, 3] : [2, 4, 1]
      e.stroke!.dashOffset = -2
      let art = Artwork(elements: [e])
      let outlined = try ArtworkOutlines.convert(art, ids: [e.id], mode: "stroke")
      XCTAssertLessThan(difference(art, outlined.artwork), 0.002, cap)
    }
    for join in ["miter", "round", "bevel"] {
      var e = shape("star")
      e.stroke = .init(width: 2)
      e.stroke!.join = join
      e.stroke!.miter = 2
      let art = Artwork(elements: [e])
      XCTAssertLessThan(
        difference(art, try ArtworkOutlines.convert(art, ids: [e.id], mode: "stroke").artwork),
        0.002, join)
    }
  }
  func testSelectionExportIncludesStrokeOverflow() throws {
    var e = shape()
    e.stroke = .init(width: 4)
    e.stroke!.alignment = "outside"
    let result = try Artwork(elements: [e]).exporting([e.id])
    XCTAssertLessThanOrEqual(result.bounds.x, 16)
    XCTAssertGreaterThanOrEqual(result.bounds.width, 38)
    e.stroke!.alignment = "inside"
    XCTAssertEqual(try Artwork(elements: [e]).exporting([e.id]).bounds.width, 30, accuracy: 0.001)
  }
  @MainActor func testMaskConversionRedirectsEveryConsumerAndKeepsNativePixels() throws {
    var mask = shape("ellipse")
    mask.hidden = true
    var a = shape(x: 10, y: 10)
    var b = shape(x: 35, y: 35)
    a.clipID = mask.id
    b.clipID = mask.id
    let art = Artwork(elements: [mask, a, b])
    let result = try ArtworkOutlines.convert(art, ids: [mask.id], mode: "shape")
    let replacement = result.created[0]
    XCTAssertEqual(result.artwork.elements.filter { $0.clipID == replacement.id }.count, 2)
    XCTAssertFalse(result.artwork.elements.contains { $0.clipID == mask.id })
    XCTAssertLessThan(difference(art, result.artwork), 0.0001)
  }
  func testNestedMaskCommandsReleaseWithoutDestroyingGeometry() throws {
    let outer = shape("ellipse")
    var group = ArtworkElement(kind: "group", x: 10, y: 10, width: 60, height: 60)
    group.contentSize = .init(60, 60)
    var inner = shape()
    var content = shape("star")
    inner.parentID = group.id
    content.parentID = group.id
    var art = Artwork(elements: [outer, group, inner, content])
    try ArtworkCommands.apply(
      "clip", to: &art, ids: [content.id], arguments: ["mask_id": inner.id.uuidString])
    try ArtworkCommands.apply(
      "clip", to: &art, ids: [group.id], arguments: ["mask_id": outer.id.uuidString])
    try validateArtwork(art)
    let before = art
    try ArtworkCommands.apply("release_clip", to: &art, ids: [content.id])
    XCTAssertNil(art.elements.first { $0.id == content.id }!.clipID)
    XCTAssertEqual(
      art.elements.first { $0.id == inner.id }, before.elements.first { $0.id == inner.id })
    XCTAssertEqual(art.elements.first { $0.id == group.id }!.clipID, outer.id)
    XCTAssertThrowsError(
      try ArtworkCommands.apply(
        "clip", to: &art, ids: [content.id], arguments: ["mask_id": outer.id.uuidString]))
  }
  func testLockedMaskTargetsAndOwnerRejectPaintEdits() throws {
    var e = shape()
    e.locked = true
    let mask = shape("ellipse")
    var art = Artwork(elements: [mask, e])
    let before = art
    XCTAssertThrowsError(try ArtworkCommands.apply("clip", to: &art, ids: [mask.id, e.id]))
    XCTAssertEqual(art, before)
    var (p, sheet) = try fixture([mask])
    p.objects[0].locked = true
    let snapshot = p
    XCTAssertThrowsError(
      try PaintCommands.apply(in: &p, objectID: sheet, ids: [mask.id], arguments: ["gradient": [:]])
    )
    XCTAssertEqual(p, snapshot)
  }
  func testSchemaTenRoundTripAndSharedUndoAtomicBatch() throws {
    let e = shape()
    var (p, sheet) = try fixture([e])
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try ProjectRepository(root: folder)
    let engine = OperationEngine(repository: repo)
    engine.project = p
    try engine.call(
      "form_edit_paint",
      arguments: [
        "object_id": sheet.uuidString, "element_ids": [e.id.uuidString],
        "stroke": ["alignment": "outside"],
      ])
    try engine.flush()
    let loaded = try repo.load(p.id)
    XCTAssertEqual(loaded.schemaVersion, 10)
    XCTAssertEqual(loaded.objects, engine.project!.objects)
    engine.undo()
    XCTAssertEqual(engine.project, p)
    engine.redo()
    let before = engine.project
    XCTAssertThrowsError(
      try engine.call(
        "form_batch",
        arguments: [
          "operations": [
            [
              "name": "form_edit_paint",
              "arguments": [
                "object_id": sheet.uuidString, "element_ids": [e.id.uuidString], "gradient": [:],
              ],
            ],
            [
              "name": "form_edit_paint",
              "arguments": [
                "object_id": sheet.uuidString, "element_ids": [e.id.uuidString],
                "stroke": ["width": -2],
              ],
            ],
          ]
        ]))
    XCTAssertEqual(engine.project, before)
    p.schemaVersion = 1
    try repo.save(p)
    XCTAssertLessThan(try repo.load(p.id).schemaVersion, 10)
  }
}

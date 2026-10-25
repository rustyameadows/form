import AppKit
import XCTest

@testable import FormCore
@testable import FormGraphics

final class CompoundPathTests: XCTestCase {
  private func curve(_ x: Double, _ y: Double) -> ArtworkElement {
    var e = ArtworkElement(kind: "path", x: x, y: y, width: 60, height: 40, color: "#263C64")
    e.path = .init(
      width: 100, height: 100,
      contours: [
        .init(
          [
            .init(.init(0, 20), outgoing: .init(20, -20)),
            .init(.init(100, 80), incoming: .init(80, 110)),
          ], closed: false)
      ])
    e.fillEnabled = false
    e.stroke = .init(color: e.color, width: 0.7)
    return e
  }
  private func map(_ e: ArtworkElement, _ art: Artwork) -> Affine2 {
    art.worldTransform(e).followed(by: .scale(e.width / e.path!.width, e.height / e.path!.height))
  }
  private func nodes(_ e: ArtworkElement, _ art: Artwork) -> [UUID: BezierNode] {
    Dictionary(
      uniqueKeysWithValues: e.path!.contours.flatMap(\.nodes).map {
        ($0.id, PathCommands.transformed($0, by: map(e, art)))
      })
  }
  private func equal(_ a: Point2, _ b: Point2, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: 1e-7, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: 1e-7, file: file, line: line)
  }
  private func equal(
    _ a: BezierNode, _ b: BezierNode, file: StaticString = #filePath, line: UInt = #line
  ) {
    equal(a.anchor, b.anchor, file: file, line: line)
    for (x, y) in [(a.incoming, b.incoming), (a.outgoing, b.outgoing)] {
      XCTAssertEqual(x == nil, y == nil, file: file, line: line)
      if let x, let y { equal(x, y, file: file, line: line) }
    }
  }
  private func paintPoint(_ e: ArtworkElement, _ art: Artwork, end: Bool) -> Point2 {
    let g = e.gradient!
    let p = end ? g.end : g.start
    return art.worldTransform(e).followed(by: g.transform ?? .init()).apply(
      .init(p.x * e.width, p.y * e.height))
  }
  func testCombinePreservesNestedAffineCurvesAndFrontPaintCoordinates() throws {
    var group = ArtworkElement(kind: "group", x: 45, y: 70, width: 180, height: 140)
    group.contentSize = .init(100, 100)
    group.affine = .init(a: -1, b: 0.2, c: 0.3, d: 1, tx: 300)
    var a = curve(15, 30)
    a.parentID = group.id
    a.rotation = 25
    var b = curve(90, 80)
    b.parentID = group.id
    b.flipX = true
    b.affine = .init(a: 1, b: 0.3, c: -0.2, d: 1, tx: 9, ty: 7)
    b.color = "#D45A37"
    b.opacity = 0.6
    b.gradient = .init()
    b.gradient?.transform = .rotation(15)
    var art = Artwork(elements: [group, a, b])
    let original = art
    let before = nodes(a, art).merging(nodes(b, art)) { $1 }
    let result = try PathCommands.edit("combine", artwork: &art, elements: [a.id, b.id])
    XCTAssertEqual(result.elements, [b.id])
    XCTAssertTrue(result.nodes.isEmpty)
    XCTAssertEqual(art.elements.count, 2)
    let compound = art.elements.last!
    XCTAssertEqual(compound.path?.contours.count, 2)
    XCTAssertEqual(compound.path?.evenOdd, true)
    XCTAssertEqual(compound.parentID, group.id)
    XCTAssertEqual(compound.color, b.color)
    XCTAssertEqual(compound.stroke, b.stroke)
    XCTAssertEqual(compound.opacity, b.opacity)
    let after = nodes(compound, art)
    for (id, node) in before { equal(node, after[id]!) }
    equal(paintPoint(b, original, end: false), paintPoint(compound, art, end: false))
    equal(paintPoint(b, original, end: true), paintPoint(compound, art, end: true))
    try validateArtwork(art)
  }
  func testReleaseRetainsContourCoordinatesAndAffineGradientField() throws {
    var a = curve(0, 0)
    var b = curve(80, 40)
    a.rotation = 30
    b.rotation = -20
    b.gradient = .init(kind: "radial")
    b.gradient?.transform = .init(a: 1, b: 0.3, c: 0.2, d: 0.6, tx: 12, ty: 5)
    var art = Artwork(elements: [a, b])
    let beforeNodes = nodes(a, art).merging(nodes(b, art)) { $1 }
    try PathCommands.edit("combine", artwork: &art, elements: [a.id, b.id])
    let compound = art.elements[0]
    let old = art
    let result = try PathCommands.edit("release", artwork: &art, elements: [compound.id])
    XCTAssertEqual(result.elements.count, 2)
    for part in art.elements {
      XCTAssertEqual(part.path?.contours.count, 1)
      for (id, node) in nodes(part, art) { equal(node, beforeNodes[id]!) }
      equal(paintPoint(compound, old, end: false), paintPoint(part, art, end: false))
      equal(paintPoint(compound, old, end: true), paintPoint(part, art, end: true))
    }
  }
  func testJoinAcrossSeparatePathsForEveryEndpointOrientation() throws {
    for first in 0...1 {
      for second in 0...1 {
        let a = curve(0, 0)
        var b = curve(60, 20)
        b.rotation = -25
        let art0 = Artwork(elements: [a, b])
        let na = a.path!.contours[0].nodes[first]
        let nb = b.path!.contours[0].nodes[second]
        let match = map(a, art0).apply(na.anchor)
        let point = map(b, art0).apply(nb.anchor)
        b.affine = .translation(match.x - point.x, match.y - point.y)
        var art = Artwork(elements: [a, b])
        let before = art
        let result = try PathCommands.edit(
          "join", artwork: &art, elements: [a.id, b.id], nodes: [na.id, nb.id])
        XCTAssertEqual(result.elements, [b.id])
        XCTAssertEqual(art.elements.count, 1)
        let e = art.elements[0]
        XCTAssertEqual(e.path?.contours.count, 1)
        XCTAssertEqual(e.path?.contours[0].nodes.count, 3)
        XCTAssertFalse(e.path!.contours[0].closed)
        let values = nodes(e, art)
        // Existing curve anchors stay fixed; coincident endpoints merge.
        for source in before.elements {
          for (id, node) in nodes(source, before) where id != na.id && id != nb.id {
            equal(node.anchor, values[id]!.anchor)
          }
        }
        let selected = e.path!.contours[0].nodes.first { result.nodes.contains($0.id) }!
        equal(map(e, art).apply(selected.anchor), match)
      }
    }
  }
  func testJoinSeparatedEndpointsKeepsBothAndCreatesOneUndoableDocumentEdit() async throws {
    try await MainActor.run {
      var project = Project(name: "Endpoint join")
      let a = curve(10, 20)
      let b = curve(90, 70)
      var source = try project.makeObject(recipeID: "artboard")
      source.artwork = Artwork(elements: [a, b])
      project.objects.append(source)
      var product = try project.makeObject(recipeID: "box")
      project.objects.append(product)
      try project.linkArtwork(product.id, sourceID: source.id)
      product = project.objects.first { $0.id == product.id }!
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: folder) }
      let repo = try ProjectRepository(root: folder)
      let engine = OperationEngine(repository: repo)
      engine.project = project
      let args: [String: Any] = [
        "object_id": product.id.uuidString, "element_ids": [a.id.uuidString, b.id.uuidString],
        "operation": "join",
        "node_ids": [
          a.path!.contours[0].nodes.last!.id.uuidString,
          b.path!.contours[0].nodes.first!.id.uuidString,
        ],
      ]
      _ = try engine.call("form_edit_path", arguments: args)
      let joined = engine.project!.editableArtwork(product)!.elements[0]
      XCTAssertEqual(joined.path?.contours[0].nodes.count, 4)
      XCTAssertEqual(engine.project!.objects.first { $0.id == product.id }, project.objects.last)
      engine.undo()
      XCTAssertEqual(engine.project?.objects, project.objects)
      engine.redo()
      try engine.flush()
      let loaded = try repo.load(project.id)
      XCTAssertEqual(loaded.editableArtwork(product)?.elements[0], joined)
      let before = engine.project
      var bad = args
      bad["node_ids"] = [UUID().uuidString]
      XCTAssertThrowsError(try engine.call("form_edit_path", arguments: bad))
      XCTAssertEqual(engine.project, before)
    }
  }
  func testMultiPathNodeTransformUsesArtworkCoordinatesUnderDifferentParents() throws {
    var group = ArtworkElement(kind: "group", x: 50, y: 30, width: 200, height: 100)
    group.contentSize = .init(100, 100)
    group.rotation = 21
    let a = curve(20, 15)
    var b = curve(10, 10)
    b.parentID = group.id
    b.flipY = true
    var art = Artwork(elements: [group, a, b])
    let before = art
    let selected: Set<UUID> = [a.path!.contours[0].nodes[0].id, b.path!.contours[0].nodes[1].id]
    let r = try PathCommands.edit(
      "transform", artwork: &art, elements: [a.id, b.id], nodes: selected,
      arguments: ["matrix": ["tx": 3.5, "ty": -7.25]])
    XCTAssertEqual(r.nodes, selected)
    for old in [a, b] {
      let new = art.elements.first { $0.id == old.id }!
      let values = nodes(new, art)
      for (id, node) in nodes(old, before) {
        let expected =
          selected.contains(id)
          ? PathCommands.transformed(node, by: .translation(3.5, -7.25)) : node
        equal(expected, values[id]!)
      }
    }
  }
  func testInvalidCombinesAndJoinsLeaveArtworkExactlyUnchanged() throws {
    let a = curve(0, 0)
    let b = curve(50, 0)
    func unchanged(_ art: Artwork, _ operation: String, _ ids: Set<UUID>, _ nodeIDs: Set<UUID> = [])
    {
      var candidate = art
      XCTAssertThrowsError(
        try PathCommands.edit(operation, artwork: &candidate, elements: ids, nodes: nodeIDs))
      XCTAssertEqual(candidate, art)
    }
    let art = Artwork(elements: [a, b])
    unchanged(art, "release", [a.id])
    unchanged(art, "combine", [a.id])
    unchanged(art, "combine", [UUID()])
    unchanged(art, "join", [a.id, b.id], [UUID(), b.path!.contours[0].nodes[0].id])
    var locked = b
    locked.locked = true
    unchanged(Artwork(elements: [a, locked]), "combine", [a.id, b.id])
    var closed = b
    closed.path?.contours[0].closed = true
    unchanged(
      Artwork(elements: [a, closed]), "join", [a.id, b.id],
      [a.path!.contours[0].nodes[0].id, b.path!.contours[0].nodes[0].id])
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 100, height: 100)
    group.contentSize = .init(100, 100)
    var child = b
    child.parentID = group.id
    unchanged(Artwork(elements: [a, group, child]), "combine", [a.id, b.id])
    var masked = b
    masked.clipID = a.id
    unchanged(Artwork(elements: [a, masked]), "combine", [a.id, b.id])
  }
  func testDuplicateRefreshesNodeIDsAndLegacyRepeatedIDsCanBeCombined() throws {
    let a = curve(0, 0)
    var art = Artwork(elements: [a])
    let selection = try ArtworkCommands.apply("duplicate", to: &art, ids: [a.id])
    let duplicate = art.elements.first { selection.contains($0.id) }!
    XCTAssertTrue(Set(nodes(a, art).keys).isDisjoint(with: nodes(duplicate, art).keys))
    var legacy = a
    legacy.id = UUID()
    legacy.x = 100
    art = Artwork(elements: [a, legacy])
    try PathCommands.edit("combine", artwork: &art, elements: [a.id, legacy.id])
    let all = art.elements[0].path!.contours.flatMap(\.nodes).map(\.id)
    XCTAssertEqual(Set(all).count, all.count)
  }
  func testDeletingAllNodesAcrossPathsRemovesBothAndReleasesMaskReferences() throws {
    let a = curve(0, 0)
    let b = curve(50, 10)
    var user = ArtworkElement(kind: "rectangle", x: 0, y: 0, width: 100, height: 100)
    user.clipID = a.id
    var art = Artwork(elements: [a, b, user])
    let ids = Set([a, b].flatMap { $0.path!.contours.flatMap(\.nodes).map(\.id) })
    let result = try PathCommands.edit("delete", artwork: &art, elements: [a.id, b.id], nodes: ids)
    XCTAssertTrue(result.elements.isEmpty)
    XCTAssertTrue(result.nodes.isEmpty)
    XCTAssertEqual(art.elements.map(\.id), [user.id])
    XCTAssertNil(art.elements[0].clipID)
  }
  @MainActor func testCompoundHoleAndReleaseProduceExpectedNativePixels() throws {
    let outer = try VectorGeometry.convertedShape(
      .init(kind: "ellipse", x: 10, y: 10, width: 80, height: 80, color: "#D45A37"))
    let inner = try VectorGeometry.convertedShape(
      .init(kind: "ellipse", x: 35, y: 35, width: 30, height: 30, color: "#D45A37"))
    var art = Artwork(background: "#FFFFFF", elements: [outer, inner])
    let result = try PathCommands.edit("combine", artwork: &art, elements: [outer.id, inner.id])
    func color(_ art: Artwork, _ x: Int, _ y: Int) -> NSColor {
      let image = ArtworkRenderer.image(
        art, width: 100, height: 100, assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 2)
      return (image.representations[0] as! NSBitmapImageRep).colorAt(x: x, y: y)!.usingColorSpace(
        .sRGB)!
    }
    let paint = color(Artwork(background: "#FFFFFF", elements: [outer]), 100, 100)
    XCTAssertGreaterThan(color(art, 100, 100).greenComponent, 0.99)
    XCTAssertEqual(color(art, 50, 100).greenComponent, paint.greenComponent, accuracy: 0.005)
    try PathCommands.edit("release", artwork: &art, elements: result.elements)
    XCTAssertEqual(color(art, 100, 100).greenComponent, paint.greenComponent, accuracy: 0.005)
  }
  @MainActor func testShapeConversionMatchesNativeAppearanceIncludingImplicitLineStroke() throws {
    for kind in ["rectangle", "ellipse", "polygon", "star", "line"] {
      var e = ArtworkElement(kind: kind, x: 30, y: 30, width: 45, height: 40, color: "#263C64")
      e.cornerRadius = 9
      e.rotation = 15
      e.flipX = true
      e.sides = 7
      if kind != "line" {
        e.gradient = .init()
        e.opacity = 0.65
        e.stroke = .init(color: "#D45A37", width: 1.2)
      }
      let converted = try VectorGeometry.convertedShape(e)
      let a = ArtworkRenderer.image(
        Artwork(background: "#FFFFFF", elements: [e]), width: 110, height: 110,
        assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 4)
      let b = ArtworkRenderer.image(
        Artwork(background: "#FFFFFF", elements: [converted]), width: 110, height: 110,
        assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 4)
      let ra = a.representations[0] as! NSBitmapImageRep
      let rb = b.representations[0] as! NSBitmapImageRep
      var error = 0.0
      for y in stride(from: 0, to: 440, by: 2) {
        for x in stride(from: 0, to: 440, by: 2) {
          let ca = ra.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
          let cb = rb.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
          error +=
            abs(ca.redComponent - cb.redComponent) + abs(ca.greenComponent - cb.greenComponent)
            + abs(ca.blueComponent - cb.blueComponent)
        }
      }
      XCTAssertLessThan(error / (220 * 220 * 3), 0.002, kind)
      if kind == "line" {
        XCTAssertNotNil(converted.stroke)
        XCTAssertEqual(converted.fillEnabled, false)
      }
    }
  }
}

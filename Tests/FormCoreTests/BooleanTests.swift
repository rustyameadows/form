import AppKit
import XCTest

@testable import FormCore
@testable import FormGraphics

final class BooleanTests: XCTestCase {
  private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: String = "#D45A37")
    -> ArtworkElement
  {
    .init(kind: "rectangle", x: x, y: y, width: w, height: h, color: color)
  }
  private func pair(_ operation: String) throws -> (Artwork, ArtworkElement, ArtworkElement, UUID) {
    let a = rect(0, 0, 60, 50)
    let b = rect(40, 0, 60, 50, "#263C64")
    var art = Artwork(background: "#FFFFFF", elements: [a, b])
    let id = try BooleanCommands.create(operation, artwork: &art, elements: [a.id, b.id])
    return (art, a, b, id)
  }
  @MainActor private func contains(_ point: Point2, group: ArtworkElement, art: Artwork) throws
    -> Bool
  {
    let local = art.worldTransform(group).inverse!.apply(point)
    return try BooleanGeometry.path(group, in: art).contains(.init(x: local.x, y: local.y))
  }
  private func equal(_ a: Point2, _ b: Point2, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: 1e-7, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: 1e-7, file: file, line: line)
  }
  @MainActor func testLiveOperationTruthTablesAndOperandOrder() throws {
    let expected = [
      "union": [true, true, true], "subtract": [true, false, false],
      "intersect": [false, true, false], "exclude": [true, false, true],
    ]
    for operation in BooleanCommands.operations {
      let (art, a, b, id) = try pair(operation)
      let group = art.elements.first { $0.id == id }!
      XCTAssertEqual(group.kind, "group")
      XCTAssertEqual(group.booleanOperation, operation)
      XCTAssertEqual(art.elements.filter { $0.parentID == id }.map(\.id), [a.id, b.id])
      XCTAssertFalse(art.elements.contains { $0.hidden == true })
      for (i, x) in [20.0, 50, 80].enumerated() {
        XCTAssertEqual(
          try contains(.init(x, 25), group: group, art: art), expected[operation]![i], operation)
      }
    }
    var (art, a, b, id) = try pair("subtract")
    try ArtworkCommands.apply("reorder", to: &art, ids: [a.id], arguments: ["mode": "front"])
    let group = art.elements.first { $0.id == id }!
    XCTAssertFalse(try contains(.init(20, 25), group: group, art: art))
    XCTAssertTrue(try contains(.init(80, 25), group: group, art: art))
    XCTAssertEqual(art.elements.first { $0.id == b.id }?.parentID, id)
  }
  @MainActor func testEmptyIntersectionRecoversWhenAnOperandMoves() throws {
    let a = rect(0, 0, 20, 20)
    let b = rect(80, 0, 20, 20)
    var art = Artwork(elements: [a, b])
    let id = try BooleanCommands.create("intersect", artwork: &art, elements: [a.id, b.id])
    let group = art.elements.last!
    XCTAssertTrue(try BooleanGeometry.path(group, in: art).isEmpty)
    XCTAssertTrue(try BooleanGeometry.proxy(group, in: art).path!.contours.isEmpty)
    let index = art.elements.firstIndex { $0.id == b.id }!
    ArtworkCommands.translate(&art.elements[index], dx: -80, dy: 0)
    XCTAssertTrue(try contains(.init(10, 10), group: art.elements.first { $0.id == id }!, art: art))
  }
  @MainActor func testNestedLiveGroupsUpdateAfterInnerOperandChanges() throws {
    var (art, a, _, inner) = try pair("subtract")
    let c = rect(80, 0, 40, 50)
    art.elements.append(c)
    let outer = try BooleanCommands.create("union", artwork: &art, elements: [inner, c.id])
    let group = art.elements.last!
    XCTAssertTrue(try contains(.init(20, 25), group: group, art: art))
    XCTAssertTrue(try contains(.init(100, 25), group: group, art: art))
    let i = art.elements.firstIndex { $0.id == inner }!
    art.elements[i].booleanOperation = "intersect"
    XCTAssertFalse(try contains(.init(20, 25), group: group, art: art))
    XCTAssertTrue(try contains(.init(50, 25), group: group, art: art))
    let render = try BooleanGeometry.materialized(art)
    XCTAssertEqual(render.elements.count, 1)
    XCTAssertEqual(render.elements[0].id, outer)
    XCTAssertNil(render.elements[0].booleanOperation)
    XCTAssertNotNil(art.elements.first { $0.id == a.id })
  }
  @MainActor func testCacheIgnoresPaintNamesAndRootPlacementButTracksGeometry() throws {
    BooleanGeometry.resetDiagnostics()
    var (art, a, _, id) = try pair("union")
    var group = art.elements.last!
    _ = try BooleanGeometry.path(group, in: art)
    XCTAssertEqual(BooleanGeometry.diagnostics["geometry_builds"] as? Int, 1)
    group.name = "New name"
    group.color = "#CC8822"
    group.opacity = 0.2
    group.affine = .translation(300, 200)
    _ = try BooleanGeometry.path(group, in: art)
    XCTAssertEqual(BooleanGeometry.diagnostics["geometry_builds"] as? Int, 1)
    let index = art.elements.firstIndex { $0.id == a.id }!
    art.elements[index].color = "#00FF00"
    _ = try BooleanGeometry.path(group, in: art)
    XCTAssertEqual(BooleanGeometry.diagnostics["geometry_builds"] as? Int, 1)
    art.elements[index].width = 75
    _ = try BooleanGeometry.path(group, in: art)
    XCTAssertEqual(BooleanGeometry.diagnostics["geometry_builds"] as? Int, 2)
    XCTAssertEqual(art.elements.first { $0.id == id }?.booleanOperation, "union")
  }
  @MainActor func testAffineOperandsAndGradientStrokeSurviveFlattening() throws {
    var parent = ArtworkElement(kind: "group", x: 40, y: 20, width: 140, height: 120)
    parent.contentSize = .init(100, 100)
    parent.rotation = 17
    var a = rect(0, 0, 60, 50)
    var b = rect(35, 10, 50, 60, "#263C64")
    a.parentID = parent.id
    b.parentID = parent.id
    b.affine = .init(a: 1, b: 0.2, c: 0.3, d: 1, tx: 4, ty: 2)
    b.flipX = true
    b.gradient = .init()
    b.gradient?.transform = .rotation(22)
    b.stroke = .init(color: "#263C64", width: 1.4)
    b.stroke?.dash = [2, 1]
    b.stroke?.dashOffset = 0.7
    b.opacity = 0.65
    var art = Artwork(background: "#FFFFFF", elements: [parent, a, b])
    let old = art
    let id = try BooleanCommands.create("union", artwork: &art, elements: [a.id, b.id])
    let group = art.elements.last!
    for source in [a, b] {
      let operand = art.elements.first { $0.id == source.id }!
      for p in [Point2(), .init(source.width, source.height)] {
        equal(old.worldTransform(source).apply(p), art.worldTransform(operand).apply(p))
      }
    }
    let proxy = try BooleanGeometry.proxy(group, in: art, normalize: true)
    var flat = art
    flat.elements.removeAll { art.descendants(of: [id]).contains($0.id) }
    flat.elements.append(proxy)
    let first = ArtworkRenderer.image(
      art, width: 260, height: 240, assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 2)
    let second = ArtworkRenderer.image(
      flat, width: 260, height: 240, assets: URL(fileURLWithPath: "/tmp"), pixelsPerMM: 2)
    let ra = first.representations[0] as! NSBitmapImageRep
    let rb = second.representations[0] as! NSBitmapImageRep
    var error = 0.0
    for y in stride(from: 0, to: 480, by: 3) {
      for x in stride(from: 0, to: 520, by: 3) {
        let a = ra.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        let b = rb.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        error +=
          abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
          + abs(a.blueComponent - b.blueComponent)
      }
    }
    XCTAssertLessThan(error / (160 * 174 * 3), 0.002)
  }
  @MainActor func testReleaseRestoresOperandPaintWorldTransformsAndCommonClip() throws {
    var mask = rect(-10, -10, 150, 80)
    mask.hidden = true
    var a = rect(0, 0, 60, 50)
    var b = rect(40, 0, 60, 50, "#263C64")
    a.clipID = mask.id
    b.clipID = mask.id
    a.rotation = 12
    b.opacity = 0.4
    var art = Artwork(elements: [mask, a, b])
    let before = art
    let id = try BooleanCommands.create("subtract", artwork: &art, elements: [a.id, b.id])
    let group = art.elements.last!
    XCTAssertEqual(group.clipID, mask.id)
    XCTAssertTrue(art.elements.filter { $0.parentID == id }.allSatisfy { $0.clipID == nil })
    let selected = try ArtworkCommands.apply("ungroup", to: &art, ids: [id])
    XCTAssertEqual(selected, [a.id, b.id])
    for old in [a, b] {
      let e = art.elements.first { $0.id == old.id }!
      XCTAssertEqual(e.color, old.color)
      XCTAssertEqual(e.opacity, old.opacity)
      XCTAssertEqual(e.clipID, mask.id)
      for p in [Point2(), .init(30, 20)] {
        equal(before.worldTransform(old).apply(p), art.worldTransform(e).apply(p))
      }
    }
    try validateArtwork(art)
  }
  @MainActor func testGenericGroupsUseFrontmostVisiblePaintAndRetainNestedClips() throws {
    var g = ArtworkElement(kind: "group", x: 20, y: 10, width: 100, height: 80)
    g.contentSize = .init(50, 40)
    g.opacity = 0.5
    var leaf = rect(0, 0, 40, 40, "#263C64")
    leaf.parentID = g.id
    leaf.opacity = 0.6
    var mask = rect(0, 0, 20, 40)
    mask.parentID = g.id
    mask.hidden = true
    leaf.clipID = mask.id
    let a = rect(0, 0, 20, 20)
    var art = Artwork(elements: [a, g, leaf, mask])
    let id = try BooleanCommands.create("union", artwork: &art, elements: [a.id, g.id])
    let group = art.elements.first { $0.id == id }!
    XCTAssertEqual(group.color, leaf.color)
    XCTAssertEqual(group.opacity!, 0.3, accuracy: 1e-10)
    XCTAssertTrue(try contains(.init(30, 30), group: group, art: art))
    XCTAssertFalse(try contains(.init(85, 30), group: group, art: art))
    XCTAssertNotNil(try BooleanGeometry.proxy(group, in: art).path)
    XCTAssertEqual(art.elements.first { $0.id == g.id }?.parentID, id)
  }
  @MainActor func testOperandSelectionExportKeepsCompleteOwningBoolean() throws {
    let (art, a, b, id) = try pair("subtract")
    let output = try art.exporting([a.id])
    XCTAssertTrue(Set(output.artwork.elements.map(\.id)).isSuperset(of: [a.id, b.id, id]))
    XCTAssertEqual(output.bounds.width, 100, accuracy: 1e-7)
    let svg = try SVGRenderer.document(
      output.artwork, width: output.bounds.width, height: output.bounds.height,
      assets: URL(fileURLWithPath: "/tmp"))
    XCTAssertFalse(svg.contains("booleanOperation"))
    XCTAssertTrue(svg.contains("<path"))
    let proxy = try BooleanGeometry.materialized(output.artwork).elements.first!
    XCTAssertFalse(
      VectorGeometry.worldPath(proxy, in: try BooleanGeometry.materialized(output.artwork))
        .contains(.init(x: 50, y: 25)))
  }
  @MainActor func testDividePartitionsOverlapAndUsesFrontmostRegionOwner() throws {
    let a = rect(0, 0, 60, 50)
    let b = rect(40, 0, 60, 50, "#263C64")
    let art = Artwork(elements: [a, b])
    let regions = try BooleanGeometry.divide([a, b], in: art)
    XCTAssertEqual(regions.count, 3)
    for x in stride(from: 0.37, to: 100, by: 1.5) {
      let matching = regions.filter { $0.path.contains(.init(x: x, y: 20)) }
      XCTAssertEqual(matching.count, 1)
      XCTAssertEqual(matching[0].owner.id, x < 40 ? a.id : b.id)
    }
    let pieces = try regions.enumerated().map {
      try BooleanGeometry.regionElement($0.element, in: art, name: "Region \($0.offset)")
    }
    try validateArtwork(Artwork(elements: pieces))
    XCTAssertEqual(pieces.count, 3)
  }
  @MainActor func testDividePreservesHoleTopologyAndNonoverlappingCoverage() throws {
    let path = CGMutablePath()
    path.addEllipse(in: .init(x: 10, y: 10, width: 80, height: 80))
    path.addEllipse(in: .init(x: 30, y: 30, width: 40, height: 40))
    var ring = try VectorGeometry.element(from: path, color: "#D45A37")
    ring.path?.evenOdd = true
    let cutter = rect(5, 30, 40, 40, "#263C64")
    let art = Artwork(elements: [ring, cutter])
    let regions = try BooleanGeometry.divide([ring, cutter], in: art)
    let original = VectorGeometry.worldPath(ring, in: art).normalized(using: .evenOdd).union(
      VectorGeometry.worldPath(cutter, in: art))
    for y in stride(from: 0.37, to: 100, by: 3) {
      for x in stride(from: 0.29, to: 100, by: 3) {
        let p = CGPoint(x: x, y: y)
        let count = regions.filter { $0.path.contains(p) }.count
        XCTAssertEqual(count, original.contains(p) ? 1 : 0)
      }
    }
    XCTAssertFalse(regions.contains { $0.path.contains(.init(x: 50, y: 50)) })
  }
  func testValidationRejectsIncompatibleLockedAndCyclicOperandsAtomically() throws {
    let a = rect(0, 0, 50, 50)
    var b = rect(30, 0, 50, 50)
    b.locked = true
    var art = Artwork(elements: [a, b])
    let before = art
    XCTAssertThrowsError(
      try BooleanCommands.create("union", artwork: &art, elements: [a.id, b.id]))
    XCTAssertEqual(art, before)
    var bad = a
    bad.booleanOperation = "union"
    XCTAssertThrowsError(try validateArtwork(Artwork(elements: [bad])))
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 50, height: 50)
    group.booleanOperation = "bogus"
    group.contentSize = .init(50, 50)
    XCTAssertThrowsError(try validateArtwork(Artwork(elements: [group])))
    group.booleanOperation = "union"
    var text = ArtworkElement(kind: "text", x: 0, y: 0, text: "No")
    text.parentID = group.id
    XCTAssertThrowsError(try validateArtwork(Artwork(elements: [group, text])))
    group.parentID = group.id
    XCTAssertThrowsError(try validateArtwork(Artwork(elements: [group])))
  }
  @MainActor func testReleaseRetainsClipsAddedInsideLiveGroup() throws {
    for external in [false, true] {
      var (art, a, _, id) = try pair("union")
      var inner = rect(0, 0, 30, 50)
      inner.parentID = id
      inner.hidden = true
      art.elements.append(inner)
      let i = art.elements.firstIndex { $0.id == a.id }!
      art.elements[i].clipID = inner.id
      if external {
        var outer = rect(-20, -20, 200, 200)
        outer.hidden = true
        art.elements.append(outer)
        let g = art.elements.firstIndex { $0.id == id }!
        art.elements[g].clipID = outer.id
      }
      try validateArtwork(art)
      try ArtworkCommands.apply("ungroup", to: &art, ids: [id])
      try validateArtwork(art)
      let operand = art.elements.first { $0.id == a.id }!
      XCTAssertEqual(operand.clipID, inner.id)
      XCTAssertEqual(operand.parentID, external ? id : nil)
      if external { XCTAssertNil(art.elements.first { $0.id == id }!.booleanOperation) }
    }
  }
  func testLiveBoundsIncludeMovedOperandsInsideOrdinaryGroups() throws {
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 30, height: 30)
    group.contentSize = .init(30, 30)
    var leaf = rect(0, 0, 20, 20)
    leaf.parentID = group.id
    let a = rect(40, 0, 20, 20)
    var art = Artwork(elements: [group, leaf, a])
    let id = try BooleanCommands.create("union", artwork: &art, elements: [group.id, a.id])
    let before = art.bounds(of: art.elements.last!)
    let index = art.elements.firstIndex { $0.id == leaf.id }!
    ArtworkCommands.translate(&art.elements[index], dx: 150, dy: 0)
    let after = art.bounds(of: art.elements.first { $0.id == id }!)
    XCTAssertGreaterThan(after.maxX, before.maxX + 100)
  }
  func testLiveCreationAndReleasePreserveStackPositionBelowUnrelatedArtwork() throws {
    let back = rect(0, 0, 100, 100)
    let a = rect(10, 10, 50, 50)
    let b = rect(30, 10, 50, 50)
    let overlay = rect(20, 20, 20, 20)
    var art = Artwork(elements: [back, a, b, overlay])
    let id = try BooleanCommands.create("union", artwork: &art, elements: [a.id, b.id])
    XCTAssertEqual(art.elements.filter { $0.parentID == nil }.map(\.id), [back.id, id, overlay.id])
    try ArtworkCommands.apply("ungroup", to: &art, ids: [id])
    XCTAssertEqual(art.elements.map(\.id), [back.id, a.id, b.id, overlay.id])
    let moved = try BooleanCommands.create("union", artwork: &art, elements: [a.id, b.id])
    try ArtworkCommands.apply("reorder", to: &art, ids: [moved], arguments: ["mode": "back"])
    try ArtworkCommands.apply("ungroup", to: &art, ids: [moved])
    XCTAssertEqual(art.elements.map(\.id), [a.id, b.id, back.id, overlay.id])
  }
  @MainActor func testSchemaFiveLinkedSourceUndoAndReopenRetainOperands() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let repository = try ProjectRepository(root: folder)
    let engine = OperationEngine(repository: repository)
    var project = Project(name: "Live boolean")
    var source = try project.makeObject(recipeID: "artboard")
    let a = rect(0, 0, 60, 50)
    let b = rect(40, 0, 60, 50)
    source.artwork = Artwork(elements: [a, b])
    project.objects.append(source)
    let box = try project.makeObject(recipeID: "box")
    project.objects.append(box)
    try project.linkArtwork(box.id, sourceID: source.id)
    engine.project = project
    try engine.edit("Live union") { p in
      var art = p.objects.first { $0.id == source.id }!.artwork!
      try BooleanCommands.create("union", artwork: &art, elements: [a.id, b.id])
      try p.setArtwork(art, for: box.id)
    }
    let after = engine.project!
    XCTAssertEqual(after.minimumSchemaVersion, 5)
    XCTAssertEqual(after.objects.first { $0.id == box.id }, project.objects.last)
    engine.undo()
    XCTAssertEqual(engine.project!.objects, project.objects)
    engine.redo()
    try engine.flush()
    let loaded = try repository.load(project.id)
    XCTAssertEqual(loaded.schemaVersion, 5)
    XCTAssertEqual(loaded.objects, after.objects)
    let owner = loaded.objects.first { $0.id == source.id }!
    XCTAssertTrue(try BooleanGeometry.materialized(owner.artwork!).elements[0].path != nil)
  }
}

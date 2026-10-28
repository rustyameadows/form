import XCTest

@testable import FormCore

final class SewingCurvedPatternTests: XCTestCase {
  private func polygon(_ points: [Point2], holes: [[Point2]] = []) -> ArtworkElement {
    var e = ArtworkElement(kind: "path", x: 0, y: 0, width: 120, height: 120)
    e.path = .init(
      width: 120, height: 120,
      contours: ([points] + holes).map { .init($0.map { BezierNode($0) }) }, evenOdd: true)
    e.sewingPiece = .init(name: "General panel")
    return e
  }
  private func circle(_ center: Point2, _ r: Double) -> VectorContour {
    let k = 0.5522847498307936 * r
    let c = center
    return .init([
      .init(
        .init(c.x + r, c.y), incoming: .init(c.x + r, c.y - k), outgoing: .init(c.x + r, c.y + k)),
      .init(
        .init(c.x, c.y + r), incoming: .init(c.x + k, c.y + r), outgoing: .init(c.x - k, c.y + r)),
      .init(
        .init(c.x - r, c.y), incoming: .init(c.x - r, c.y + k), outgoing: .init(c.x - r, c.y - k)),
      .init(
        .init(c.x, c.y - r), incoming: .init(c.x - k, c.y - r), outgoing: .init(c.x + k, c.y - r)),
    ])
  }
  private func holed() -> ArtworkElement {
    var e = polygon([.init(0, 0), .init(120, 0), .init(120, 120), .init(0, 120)])
    e.path!.contours.append(circle(.init(60, 60), 30))
    return e
  }
  private func geometry(_ e: ArtworkElement) throws -> SewingPieceGeometry {
    try SewingPatterns.geometry(e, in: Artwork(elements: [e]))
  }
  func testPinnedKernelAndConcaveOffsetRetainSourceShapeAndPhysicalScale() throws {
    XCTAssertEqual(SewingPolygonKernel.version, "2.0.1")
    let e = polygon([
      .init(0, 0), .init(100, 0), .init(100, 30), .init(30, 30), .init(30, 100), .init(0, 100),
    ])
    let before = e
    let g = try geometry(e)
    XCTAssertTrue(g.usesGeneralGeometry)
    XCTAssertEqual(g.edgeLengths, [100, 30, 70, 70, 30, 100])
    XCTAssertEqual(g.bounds, .init(-10, -10, 120, 120))
    XCTAssertFalse(SewingLayoutGeometry.containsMaterial(.init(70, 70), contours: g.allCutContours))
    XCTAssertTrue(SewingLayoutGeometry.containsMaterial(.init(35, 35), contours: g.allCutContours))
    XCTAssertEqual(e, before)
  }
  func testCurveLengthsUseIndependentNumericalIntegralAndWorldContourTolerance() throws {
    let template = try SewingPatternTemplates.roundedPouch()
    let e = template.artwork.elements[0]
    let g = try geometry(e)
    let curve = try XCTUnwrap(g.sourceEdges.first { $0.index == 2 })
    let nodes = e.path!.contours[0].nodes
    let a = nodes[2]
    let b = nodes[3]
    let p = [a.anchor, a.outgoing!, b.incoming!, b.anchor]
    func point(_ t: Double) -> Point2 {
      let u = 1 - t
      return .init(
        u * u * u * p[0].x + 3 * u * u * t * p[1].x + 3 * u * t * t * p[2].x + t * t * t * p[3].x
          + e.x,
        u * u * u * p[0].y + 3 * u * u * t * p[1].y + 3 * u * t * t * p[2].y + t * t * t * p[3].y
          + e.y)
    }
    func speed(_ t: Double) -> Double {
      let u = 1 - t
      return hypot(
        3 * u * u * (p[1].x - p[0].x) + 6 * u * t * (p[2].x - p[1].x) + 3 * t * t
          * (p[3].x - p[2].x),
        3 * u * u * (p[1].y - p[0].y) + 6 * u * t * (p[2].y - p[1].y) + 3 * t * t
          * (p[3].y - p[2].y))
    }
    let n = 10000
    let step = 1 / Double(n)
    let exact =
      (0...n).reduce(0.0) { sum, i in
        sum + speed(Double(i) * step) * (i == 0 || i == n ? 1 : i % 2 == 0 ? 2 : 4)
      } * step / 3
    XCTAssertEqual(curve.length, exact, accuracy: 0.005)
    XCTAssertLessThanOrEqual(abs(curve.length - exact), curve.lengthError + 1e-8)
    for i in 0...1000 {
      let p = point(Double(i) / 1000)
      let distance = zip(curve.points, curve.points.dropFirst()).map {
        SewingCurves.segmentDistance(p, $0, $1)
      }.min()!
      XCTAssertLessThanOrEqual(distance, 0.020001)
    }
    let half = curve.sample(fraction: 0.5)
    XCTAssertEqual(half.distanceMM, curve.length / 2, accuracy: 1e-8)
    XCTAssertEqual(half.edgeID, a.id)
  }
  func testHolesShrinkByPhysicalAllowanceAndCollapsedHolesAreExplicitErrors() throws {
    var e = holed()
    let g = try geometry(e)
    let hole = SewingLayoutGeometry.bounds(g.allCutContours[1])
    XCTAssertEqual(g.allCutContours.count, 2)
    XCTAssertEqual(hole.x, 40, accuracy: 0.03)
    XCTAssertEqual(hole.width, 40, accuracy: 0.04)
    XCTAssertFalse(SewingLayoutGeometry.containsMaterial(.init(60, 60), contours: g.allCutContours))
    e.sewingPiece!.seamAllowance = 31
    XCTAssertThrowsError(try geometry(e)) {
      XCTAssertTrue($0.localizedDescription.contains("hole"))
    }
  }
  func testMirrorRotationAndNonuniformTransformOffsetInMillimetersAfterTransform() throws {
    var e = holed()
    e.path!.contours = [circle(.init(60, 60), 30)]
    for transform in [
      Affine2.scale(2, 0.5), .scale(-1, 1), .rotation(37).followed(by: .scale(1.6, 0.7)),
    ] {
      e.affine = transform
      let g = try geometry(e)
      let outer = g.allStitchContours[0]
      for p in g.cut {
        let distance = zip(outer, Array(outer.dropFirst()) + [outer[0]]).map {
          SewingCurves.segmentDistance(p, $0, $1)
        }.min()!
        XCTAssertEqual(distance, 10, accuracy: 0.035)
      }
      XCTAssertEqual(hypot(g.grainDirection.x, g.grainDirection.y), 1, accuracy: 1e-8)
    }
  }
  func testStableEdgeUUIDAndArcFractionSurviveSourceOrderingButDeletedEdgesFail() throws {
    var art = try SewingPatternTemplates.roundedPouch().artwork
    let original = try SewingPatterns.geometry(art.elements[0], in: art)
    let notch = original.piece.notches[0]
    let edgeID = notch.edgeID!
    let point = original.sourceEdges.first { $0.id == edgeID }!.sample(fraction: notch.position)
      .point
    let identity = original.boundaries[0].id
    var nodes = art.elements[0].path!.contours[0].nodes
    nodes = Array(nodes.dropFirst(2)) + Array(nodes.prefix(2))
    art.elements[0].path!.contours[0].nodes = nodes
    let reordered = try SewingPatterns.geometry(art.elements[0], in: art)
    let edge = reordered.sourceEdges.first { $0.id == edgeID }!
    XCTAssertNotEqual(edge.index, notch.edge)
    XCTAssertEqual(edge.sample(fraction: notch.position).point, point)
    XCTAssertEqual(reordered.boundaries[0].id, identity)
    XCTAssertTrue(try SewingPatterns.diagnostics(art).allSatisfy(\.matches))
    art.elements[0].path!.contours[0].nodes.removeAll { $0.id == edgeID }
    XCTAssertThrowsError(try validateArtwork(art))
  }
  func testCurvedSeamZeroToleranceReportsUncertaintyRatherThanFalseExactMatch() throws {
    var art = try SewingPatternTemplates.roundedPouch().artwork
    let seamIndex = art.sewingSeams!.firstIndex { $0.first.edge == 2 }!
    art.sewingSeams![seamIndex].tolerance = 0
    let diagnostic = try SewingPatterns.diagnostics(art)[seamIndex]
    XCTAssertEqual(diagnostic.difference, 0)
    XCTAssertGreaterThan(diagnostic.measurementError, 0)
    XCTAssertFalse(diagnostic.matches)
    XCTAssertFalse(diagnostic.isConclusive)
  }
  func testGeneralFoldRemainsAnExactStraightBoundaryAndRejectsCurvedFoldOrVariableAllowance() throws
  {
    var e = polygon([
      .init(0, 0), .init(100, 0), .init(100, 30), .init(30, 30), .init(30, 100), .init(0, 100),
    ])
    e.sewingPiece!.onFoldEdge = 5
    let g = try geometry(e)
    XCTAssertEqual(g.bounds.x, 0, accuracy: 0.001)
    XCTAssertEqual(g.bounds.width, 110, accuracy: 0.001)
    for path in SewingPatternDrawing.cuttingContours(g) {
      for pair in zip(path.points, path.points.dropFirst()) {
        XCTAssertFalse(abs(pair.0.x) < 0.002 && abs(pair.1.x) < 0.002)
      }
    }
    var pouch = try SewingPatternTemplates.roundedPouch().artwork.elements[0]
    pouch.sewingPiece!.onFoldEdge = 2
    XCTAssertThrowsError(try geometry(pouch))
    e.sewingPiece!.edgeAllowances[0] = 20
    XCTAssertThrowsError(try geometry(e))
  }
  func testNotchesOnCurvesUseSourceArcLengthAndRemainOutsideStitchBoundary() throws {
    var e = try SewingPatternTemplates.roundedPouch().artwork.elements[0]
    e.sewingPiece!.notches = []
    let noNotch = try geometry(e)
    var notch = SewingNotch(edge: 2, position: 0.5)
    notch.edgeID = e.path!.contours[0].nodes[2].id
    e.sewingPiece!.notches = [notch]
    let g = try geometry(e)
    let record = try XCTUnwrap(g.cutNotches.first)
    XCTAssertEqual(record.openingLengthMM, notch.width, accuracy: 1e-9)
    XCTAssertEqual(record.sourceDistanceMM, g.edgeLengths[2] / 2, accuracy: 1e-8)
    // Opening arc length has the requested physical width; its chord is slightly shorter on a curve.
    XCTAssertLessThanOrEqual(
      SewingCurves.distance(record.firstMouth, record.secondMouth), notch.width + 0.001)
    XCTAssertGreaterThan(
      SewingCurves.distance(record.firstMouth, record.secondMouth), notch.width - 0.03)
    for mouth in [record.firstMouth, record.secondMouth] {
      XCTAssertLessThan(g.cut.map { SewingCurves.distance($0, mouth) }.min()!, 0.003)
    }
    XCTAssertLessThan(
      SewingLayoutGeometry.materialArea(g.allCutContours),
      SewingLayoutGeometry.materialArea(noNotch.allCutContours))
    for p in g.cut { XCTAssertFalse(SewingCurves.contains(p, ring: g.stitch)) }
    XCTAssertEqual(
      g.sourceEdges[2].sample(fraction: 0.5).distanceMM, g.edgeLengths[2] / 2, accuracy: 1e-8)
  }
  func testTopologyRejectsSelfCrossingTouchingNestedHolesAndWorkOverflow() throws {
    var e = polygon([.init(0, 0), .init(120, 120), .init(0, 120), .init(120, 0)])
    XCTAssertThrowsError(try geometry(e))
    e = holed()
    e.path!.contours.append(circle(.init(60, 60), 10))
    XCTAssertThrowsError(try geometry(e))
    e = holed()
    e.path!.contours[1] = circle(.init(10, 60), 20)
    XCTAssertThrowsError(try geometry(e))
    let p = (0..<513).map {
      let t = Double($0) * Double.pi * 2 / 513
      return Point2(60 + 50 * cos(t), 60 + 50 * sin(t))
    }
    e = polygon(p)
    e.path!.contours[0].nodes[0].outgoing = .init(110, 61)
    XCTAssertThrowsError(try geometry(e))
  }
  func testLayoutUsesHolesForExactCollisionClearanceAndAreaRatherThanBoundingBox() throws {
    var ring = holed()
    ring.sewingPiece!.seamAllowance = 0
    var inside = ArtworkElement(kind: "rectangle", x: 0, y: 0, width: 20, height: 20)
    inside.sewingPiece = .init(name: "Hole insert")
    inside.sewingPiece!.seamAllowance = 0
    let art = Artwork(elements: [ring, inside])
    var l = SewingCutLayout(materialID: "flight-nylon", stockWidth: 200)
    l.margin = 0
    l.spacing = 5
    l.grain = .unrestricted
    l.placements = [
      .init(elementID: ring.id, copies: [1], x: 10, y: 10),
      .init(elementID: inside.id, copies: [1], x: 60, y: 60),
    ]
    let report = try SewingLayouts.preflight(l, source: art)
    XCTAssertTrue(report.isValid)
    let g = try geometry(ring)
    let expected = 14400 - SewingLayoutGeometry.area(g.allCutContours[1]) + 400
    XCTAssertEqual(report.cutAreaMM2, expected, accuracy: 1e-7)
    l.placements[1].x = 78
    XCTAssertTrue(
      try SewingLayouts.preflight(l, source: art).issues.contains {
        $0.kind == .spacing || $0.kind == .collision
      })
    l.placements[1].x = 100
    XCTAssertTrue(
      try SewingLayouts.preflight(l, source: art).issues.contains { $0.kind == .collision })
  }
  func testTemplateCommandsRemainEditableAppendPreserveUndoAndRoundtripStableReferences() throws {
    var p = Project(name: "Curve32")
    var frame = try p.makeObject(
      recipeID: "artboard", name: "Curves", parameters: ["width": 800, "depth": 750])
    frame.artwork = Artwork(elements: [])
    p.objects = [frame]
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    engine.project = p
    let before = p
    _ = try engine.call(
      "form_edit_artwork",
      arguments: [
        "object_id": frame.id.uuidString, "command": "pattern_template", "template": "roundedPouch",
        "pattern_parameters": ["width": 280, "height": 190, "corner_radius": 40],
      ])
    let saved = engine.project!
    let art = saved.objects[0].artwork!
    XCTAssertEqual(saved.minimumSchemaVersion, 32)
    XCTAssertEqual(art.elements.count, 2)
    XCTAssertEqual(art.elements[0].width, 280)
    XCTAssertTrue(art.elements[0].path!.contours[0].nodes.contains { $0.outgoing != nil })
    XCTAssertEqual(art.sewingSeams!.count, 7)
    XCTAssertTrue(try SewingPatterns.diagnostics(art).allSatisfy(\.matches))
    let data = try JSONEncoder.form.encode(saved)
    let loaded = try JSONDecoder.form.decode(Project.self, from: data)
    XCTAssertEqual(try JSONEncoder.form.encode(loaded), data)
    XCTAssertEqual(loaded.objects, saved.objects)
    _ = try engine.call("form_undo")
    XCTAssertEqual(engine.project, before)
    _ = try engine.call("form_redo")
    XCTAssertEqual(engine.project, saved)
    let ids = art.elements.map(\.id)
    _ = try engine.call(
      "form_edit_artwork",
      arguments: [
        "object_id": frame.id.uuidString, "command": "pattern_template", "template": "roundedPouch",
      ])
    XCTAssertEqual(engine.project!.objects[0].artwork!.elements.prefix(2).map(\.id), ids)
  }
  func testReferencedSubdivisionAndReverseAreAtomicAndRequireExplicitReassignment() throws {
    var art = try SewingPatternTemplates.roundedPouch().artwork
    let before = art
    let element = art.elements[0]
    let node = element.path!.contours[0].nodes[2].id
    XCTAssertThrowsError(
      try PathCommands.edit("insert", artwork: &art, elements: [element.id], nodes: [node]))
    XCTAssertEqual(art, before)
    XCTAssertThrowsError(try PathCommands.edit("reverse", artwork: &art, elements: [element.id]))
    XCTAssertEqual(art, before)
    XCTAssertThrowsError(try PathCommands.edit("release", artwork: &art, elements: [element.id]))
    XCTAssertEqual(art, before)
  }
  func testDuplicateAndCollisionTransferRemapBothManufacturingEndpoints() throws {
    let original = try SewingPatternTemplates.roundedPouch().artwork
    var art = original
    let ids = Set(art.elements.map(\.id))
    let clones = try ArtworkCommands.apply("duplicate", to: &art, ids: ids)
    XCTAssertEqual(art.sewingSeams?.count, 14)
    XCTAssertTrue(try SewingPatterns.diagnostics(art).allSatisfy(\.matches))
    let clonedPanel = art.elements.first { clones.contains($0.id) && $0.kind == "path" }!
    let clonedIDs = Set(clonedPanel.path!.contours.flatMap(\.nodes).map(\.id))
    XCTAssertTrue(
      clonedPanel.sewingPiece!.notches.allSatisfy {
        clonedIDs.contains($0.edgeID!) && clonedIDs.contains($0.endID!)
      })
    _ = try ArtworkCommands.apply("delete", to: &art, ids: clones)
    XCTAssertEqual(art.sewingSeams?.count, 7)
    var project = Project(name: "Remapped curved source")
    let workspace = try project.ensureCanvasWorkspace()
    try project.setArtwork(original, for: workspace.id)
    var frame = try project.makeObject(
      recipeID: "artboard", name: "Collision destination", parameters: ["width": 800, "depth": 750])
    var other = original.elements[0]
    other.sewingPiece = nil
    frame.artwork = Artwork(elements: [other])
    project.objects.append(frame)
    let moved = try project.transferArtwork(
      from: workspace.id, to: frame.id, ids: ids, offset: .init(30, 20))
    let destination = project.objects.first { $0.id == frame.id }!.artwork!
    XCTAssertTrue(try SewingPatterns.diagnostics(destination).allSatisfy(\.matches))
    let panel = destination.elements.first { moved.contains($0.id) && $0.kind == "path" }!
    let newIDs = Set(panel.path!.contours.flatMap(\.nodes).map(\.id))
    for seam in destination.sewingSeams! {
      for end in [seam.first, seam.second] where end.elementID == panel.id {
        XCTAssertTrue(newIDs.contains(end.edgeID!))
        XCTAssertTrue(newIDs.contains(end.endID!))
      }
    }
  }
  func testCachedGeometryInvalidatesForSourceDimensionsAncestorTransformsAndAppearanceGuards()
    throws
  {
    let e = try SewingPatternTemplates.roundedPouch().artwork.elements[0]
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 400, height: 300)
    group.contentSize = .init(400, 300)
    var child = e
    child.parentID = group.id
    var art = Artwork(elements: [group, child])
    let first = try SewingPatterns.geometry(child, in: art)
    art.elements[0].affine = .scale(1.5, 0.7)
    let changed = try SewingPatterns.geometry(child, in: art)
    XCTAssertNotEqual(changed.edgeLengths, first.edgeLengths)
    XCTAssertEqual(changed.bounds.width, child.width * 1.5 + 20, accuracy: 0.025)
    art.elements[0].opacity = 0.5
    XCTAssertThrowsError(
      try SewingPatterns.geometry(child, in: art),
      "A cache hit must never bypass current ancestor manufacturing guards.")
  }

  func testGrainGuidesStayInsideMaterialAndDoNotCrossAHole() throws {
    let g = try geometry(holed())
    let line = SewingPatternDrawing.grainline(g)
    XCTAssertEqual(line.count, 2)
    for i in 0...100 {
      let t = Double(i) / 100
      let p = Point2(
        line[0].x + (line[1].x - line[0].x) * t, line[0].y + (line[1].y - line[0].y) * t)
      XCTAssertTrue(SewingLayoutGeometry.containsMaterial(p, contours: g.allStitchContours))
    }
    XCTAssertEqual(line[0].x, line[1].x, accuracy: 1e-8)
  }

}

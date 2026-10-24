import CoreGraphics
import XCTest

@testable import FormCore
@testable import FormGraphics

final class PathTests: XCTestCase {
  private func curve() -> ArtworkElement {
    var e = ArtworkElement(kind: "path", x: 20, y: 30, width: 200, height: 120)
    e.rotation = 32
    e.affine = .init(a: 1, b: 0.2, c: 0.4, d: 1, tx: 40, ty: 10)
    e.path = .init(
      width: 100, height: 100,
      contours: [
        .init(
          [
            .init(.init(0, 20), outgoing: .init(25, -40)),
            .init(.init(100, 60), incoming: .init(80, 90)),
          ], closed: false)
      ])
    return e
  }
  private func map(_ e: ArtworkElement, in art: Artwork) -> Affine2 {
    art.worldTransform(e).followed(by: .scale(e.width / e.path!.width, e.height / e.path!.height))
  }
  private func at(_ a: BezierNode, _ b: BezierNode, _ t: Double, _ map: Affine2) -> Point2 {
    let p = a.anchor
    let q = a.outgoing ?? p
    let r = b.incoming ?? b.anchor
    let s = b.anchor
    let u = 1 - t
    return map.apply(
      .init(
        u * u * u * p.x + 3 * u * u * t * q.x + 3 * u * t * t * r.x + t * t * t * s.x,
        u * u * u * p.y + 3 * u * u * t * q.y + 3 * u * t * t * r.y + t * t * t * s.y))
  }
  private func equal(_ a: Point2, _ b: Point2, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: 1e-7, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: 1e-7, file: file, line: line)
  }
  func testCubicSubdivisionPreservesWorldGeometryAndTightBounds() throws {
    var group = ArtworkElement(kind: "group", x: 100, y: 90, width: 140, height: 80)
    group.contentSize = .init(100, 100)
    group.rotation = -18
    var e = curve()
    e.parentID = group.id
    let art = Artwork(elements: [group, e])
    let original = e.path!.contours[0].nodes
    let oldMap = map(e, in: art)
    let selected = try PathCommands.apply(
      "insert", to: &e, nodes: [original[0].id], arguments: ["t": 0.37],
      world: art.worldTransform(e))
    let next = e.path!.contours[0].nodes
    let newMap = map(e, in: art)
    XCTAssertEqual(next.count, 3)
    XCTAssertEqual(selected, [next[1].id])
    for i in 0...200 {
      let t = Double(i) / 200
      let new =
        t <= 0.37
        ? at(next[0], next[1], t / 0.37, newMap) : at(next[1], next[2], (t - 0.37) / 0.63, newMap)
      equal(at(original[0], original[1], t, oldMap), new)
    }
    let bounds = VectorGeometry.path(e).boundingBoxOfPath
    XCTAssertEqual(bounds.minX, 0, accuracy: 1e-8)
    XCTAssertEqual(bounds.minY, 0, accuracy: 1e-8)
    XCTAssertEqual(bounds.width, e.width, accuracy: 1e-8)
    XCTAssertEqual(bounds.height, e.height, accuracy: 1e-8)
  }
  func testSplitAndJoinOpenContourPreserveCurveSegments() throws {
    var e = curve()
    let middle = BezierNode(.init(50, 60), incoming: .init(25, 80), outgoing: .init(75, 40))
    e.path!.contours[0].nodes.insert(middle, at: 1)
    let original = e
    let art = Artwork(elements: [e])
    let oldMap = map(e, in: art)
    let selected = try PathCommands.apply(
      "split", to: &e, nodes: [middle.id], world: art.worldTransform(e))
    XCTAssertEqual(e.path!.contours.count, 2)
    XCTAssertEqual(selected.count, 2)
    let next = e.path!.contours
    let newMap = map(e, in: art)
    equal(newMap.apply(next[0].nodes.last!.anchor), newMap.apply(next[1].nodes.first!.anchor))
    for i in 0...100 {
      let t = Double(i) / 100
      let old = original.path!.contours[0].nodes
      equal(at(old[0], old[1], t, oldMap), at(next[0].nodes[0], next[0].nodes[1], t, newMap))
      equal(at(old[1], old[2], t, oldMap), at(next[1].nodes[0], next[1].nodes[1], t, newMap))
    }
    try PathCommands.apply("join", to: &e, nodes: selected, world: art.worldTransform(e))
    XCTAssertEqual(e.path!.contours.count, 1)
    XCTAssertEqual(e.path!.contours[0].nodes.count, 3)
    XCTAssertFalse(e.path!.contours[0].closed)
  }
  func testSplitClosedContourAndJoinRestoresClosingCurve() throws {
    var e = curve()
    e.path!.contours[0].closed = true
    e.path!.contours[0].nodes[0].incoming = .init(-20, 80)
    e.path!.contours[0].nodes[1].outgoing = .init(70, -30)
    let before = e
    let art = Artwork(elements: [e])
    let original = before.path!.contours[0].nodes
    let ids = try PathCommands.apply(
      "split", to: &e, nodes: [original[0].id], world: art.worldTransform(e))
    let nodes = e.path!.contours[0].nodes
    XCTAssertEqual(nodes.count, 3)
    XCTAssertFalse(e.path!.contours[0].closed)
    for i in 0...100 {
      let t = Double(i) / 100
      equal(
        at(original[1], original[0], t, map(before, in: art)),
        at(nodes[1], nodes[2], t, map(e, in: art)))
    }
    try PathCommands.apply("join", to: &e, nodes: ids, world: art.worldTransform(e))
    XCTAssertTrue(e.path!.contours[0].closed)
    XCTAssertEqual(e.path!.contours[0].nodes.count, 2)
  }
  func testReverseKeepsCubicAppearanceAndSwapsHandles() throws {
    var e = curve()
    let original = e
    let art = Artwork(elements: [e])
    try PathCommands.apply("reverse", to: &e, nodes: [], world: art.worldTransform(e))
    for i in 0...100 {
      let t = Double(i) / 100
      let a = original.path!.contours[0].nodes
      let b = e.path!.contours[0].nodes
      equal(at(a[0], a[1], t, map(original, in: art)), at(b[0], b[1], 1 - t, map(e, in: art)))
    }
  }
  func testNumericNodeTransformRespectsParentAndDoesNotMoveUnselectedNodes() throws {
    var group = ArtworkElement(kind: "group", x: 300, y: 200, width: 140, height: 80)
    group.contentSize = .init(100, 100)
    group.rotation = 58
    var e = curve()
    e.parentID = group.id
    let original = e
    let art = Artwork(elements: [group, e])
    let old = original.path!.contours[0].nodes
    let delta = Affine2.translation(7, -13).followed(by: .rotation(12))
    try PathCommands.apply(
      "transform", to: &e, nodes: [old[0].id],
      arguments: [
        "matrix": [
          "a": delta.a, "b": delta.b, "c": delta.c, "d": delta.d, "tx": delta.tx, "ty": delta.ty,
        ]
      ], world: art.worldTransform(e))
    let new = e.path!.contours[0].nodes
    equal(
      delta.apply(map(original, in: art).apply(old[0].anchor)), map(e, in: art).apply(new[0].anchor)
    )
    equal(
      delta.apply(map(original, in: art).apply(old[0].outgoing!)),
      map(e, in: art).apply(new[0].outgoing!))
    equal(map(original, in: art).apply(old[1].anchor), map(e, in: art).apply(new[1].anchor))
    equal(map(original, in: art).apply(old[1].incoming!), map(e, in: art).apply(new[1].incoming!))
  }
  func testHandleModesPreserveIndependentAndUnequalSmoothLengths() {
    var n = BezierNode(.init(10, 10), incoming: .init(5, 10), outgoing: .init(20, 10))
    XCTAssertEqual(n.effectiveMode, "smooth")
    let moved = PathCommands.movingHandle(n, incoming: false, to: .init(10, 30), independent: false)
    equal(moved.incoming!, .init(10, 5))
    n.mode = "symmetric"
    equal(
      PathCommands.movingHandle(n, incoming: false, to: .init(10, 30), independent: false)
        .incoming!, .init(10, -10))
    let independent = PathCommands.movingHandle(
      n, incoming: false, to: .init(10, 30), independent: true)
    equal(independent.incoming!, n.incoming!)
    XCTAssertEqual(independent.effectiveMode, "corner")
  }
  func testJoinOrientsDifferentOpenContoursAtTheirSelectedEndpoints() throws {
    let a = BezierNode(.init(0, 0))
    let b = BezierNode(.init(10, 0))
    let c = BezierNode(.init(30, 0))
    let d = BezierNode(.init(20, 0))
    var e = ArtworkElement(kind: "path", x: 0, y: 0, width: 30, height: 1)
    e.path = .init(
      width: 30, height: 1,
      contours: [.init([a, b], closed: false), .init([c, d], closed: false)])
    try PathCommands.apply("join", to: &e, nodes: [a.id, d.id], world: e.localTransform)
    XCTAssertEqual(e.path!.contours.count, 1)
    XCTAssertEqual(e.path!.contours[0].nodes.map(\.id), [b.id, a.id, d.id, c.id])
    XCTAssertFalse(e.path!.contours[0].closed)
  }
  func testDeletingLastPathNodesReleasesMasksAndUndoRestoresThem() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    var p = Project(name: "Delete nodes")
    var object = try p.makeObject(recipeID: "artboard")
    let path = curve()
    var shape = ArtworkElement(kind: "rectangle", x: 10, y: 10)
    shape.clipID = path.id
    object.artwork = .init(elements: [path, shape])
    p.objects = [object]
    engine.project = p
    _ = try engine.call(
      "form_edit_path",
      arguments: [
        "object_id": object.id.uuidString, "element_id": path.id.uuidString, "operation": "delete",
        "node_ids": path.path!.contours.flatMap(\.nodes).map { $0.id.uuidString },
      ])
    XCTAssertEqual(engine.project!.objects[0].artwork!.elements.count, 1)
    XCTAssertNil(engine.project!.objects[0].artwork!.elements[0].clipID)
    engine.undo()
    XCTAssertEqual(engine.project, p)
  }
  func testNearestCubicSegmentFindsActualCurveUnderAffineTransform() throws {
    let e = curve()
    let path = e.path!
    let art = Artwork(elements: [e])
    let nodes = path.contours[0].nodes
    let t = map(e, in: art)
    let point = at(nodes[0], nodes[1], 0.371, t)
    let nearest = try XCTUnwrap(PathCommands.nearestSegment(path, to: point, map: t))
    XCTAssertEqual(nearest.nodeID, nodes[0].id)
    XCTAssertEqual(nearest.t, 0.371, accuracy: 1e-6)
    XCTAssertLessThan(nearest.distance, 1e-7)
  }
  func testPathMCPIsAtomicUndoablePersistentAndRespectsLocks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    var p = Project(name: "Curves")
    var object = try p.makeObject(recipeID: "artboard")
    let path = curve()
    object.artwork = .init(elements: [path])
    p.objects = [object]
    engine.project = p
    let base: [String: Any] = ["object_id": object.id.uuidString, "element_id": path.id.uuidString]
    let result =
      try engine.call(
        "form_edit_path",
        arguments: base.merging([
          "operation": "insert", "node_ids": [path.path!.contours[0].nodes[0].id.uuidString],
        ]) { $1 }) as! [String: Any]
    XCTAssertEqual((result["selected_nodes"] as? [String])?.count, 1)
    let after = engine.project!
    engine.undo()
    XCTAssertEqual(engine.project, p)
    engine.redo()
    XCTAssertEqual(engine.project, after)
    let undoCount = engine.undoStack.count
    XCTAssertThrowsError(
      try engine.call(
        "form_batch",
        arguments: [
          "operations": [
            [
              "name": "form_edit_path",
              "arguments": base.merging([
                "operation": "transform",
                "node_ids": [path.path!.contours[0].nodes[0].id.uuidString], "matrix": ["tx": 1.0],
              ]) { $1 },
            ],
            [
              "name": "form_edit_path",
              "arguments": base.merging(["operation": "delete", "node_ids": [UUID().uuidString]]) {
                $1
              },
            ],
          ]
        ]))
    XCTAssertEqual(engine.project, after)
    XCTAssertEqual(engine.undoStack.count, undoCount)
    XCTAssertThrowsError(
      try engine.call(
        "form_edit_path",
        arguments: base.merging(["operation": "delete", "node_ids": [UUID().uuidString]]) { $1 }))
    XCTAssertThrowsError(
      try engine.call(
        "form_edit_path",
        arguments: base.merging(["operation": "delete", "node_ids": "invalid"]) { $1 }))
    XCTAssertThrowsError(
      try engine.call(
        "form_edit_path",
        arguments: base.merging([
          "operation": "transform", "node_ids": [path.path!.contours[0].nodes[0].id.uuidString],
          "matrix": ["tx": true],
        ]) { $1 }))
    XCTAssertEqual(engine.project, after)
    try engine.flush()
    let reopened = try engine.repository.load(p.id)
    XCTAssertEqual(reopened.objects, after.objects)
    // The project format deliberately encodes dates at ISO-8601 precision.
    XCTAssertEqual(try JSONEncoder.form.encode(reopened), try JSONEncoder.form.encode(after))
    engine.project!.objects[0].artwork!.elements[0].locked = true
    XCTAssertThrowsError(
      try engine.call("form_edit_path", arguments: base.merging(["operation": "reverse"]) { $1 }))
  }
}

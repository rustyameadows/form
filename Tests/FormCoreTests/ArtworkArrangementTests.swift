import XCTest
@testable import FormCore

final class ArtworkArrangementTests: XCTestCase {
  private struct Fixture {
    var artwork: Artwork
    let selected: Set<UUID>
    let fixed: Set<UUID>
    let groupID: UUID
    let childID: UUID
    let nestedID: UUID
    let parentID: UUID
  }

  private func fixture() -> Fixture {
    var outer = ArtworkElement(kind: "group", x: -60, y: 45, width: 180, height: 100)
    outer.contentSize = .init(120, 100); outer.rotation = 27
    outer.affine = .init(a: 1, b: 0.1, c: 0.25, d: 1, tx: 3, ty: -5)
    var inner = ArtworkElement(kind: "group", x: 20, y: 10, width: 70, height: 90)
    inner.contentSize = .init(100, 100); inner.parentID = outer.id
    inner.rotation = -14
    var reflected = ArtworkElement(kind: "group", x: 180, y: -30, width: 100, height: 80)
    reflected.contentSize = .init(100, 100); reflected.flipX = true; reflected.rotation = -18
    reflected.affine = .init(a: 1, b: 0.2, c: 0.35, d: 1, tx: 0, ty: 0)
    var a = ArtworkElement(kind: "rectangle", x: 5, y: 15, width: 20, height: 12)
    a.parentID = inner.id; a.rotation = 11
    a.affine = .init(a: 1, b: 0.12, c: 0.07, d: 1, tx: 2, ty: -3)
    var b = ArtworkElement(kind: "ellipse", x: 25, y: 35, width: 45, height: 18)
    b.parentID = reflected.id; b.rotation = -8
    var c = ArtworkElement(kind: "rectangle", x: 80, y: 150, width: 30, height: 40)
    c.rotation = 35
    var group = ArtworkElement(kind: "group", x: 220, y: 160, width: 65, height: 50)
    group.contentSize = .init(65, 50); group.rotation = -12; group.affine = .scale(1.1, 0.8)
    var child = ArtworkElement(kind: "rectangle", x: 3, y: 4, width: 10, height: 9)
    child.parentID = group.id
    let art = Artwork(elements: [outer, inner, a, reflected, b, c, group, child])
    return .init(artwork: art, selected: [a.id, b.id, c.id, group.id],
      fixed: [outer.id, inner.id, reflected.id, child.id], groupID: group.id, childID: child.id,
      nestedID: a.id, parentID: inner.id)
  }

  private func assertUnchangedGeometry(_ before: Artwork, _ after: Artwork, ids: Set<UUID>,
    file: StaticString = #filePath, line: UInt = #line) {
    for id in ids {
      let old = before.elements.first { $0.id == id }!, new = after.elements.first { $0.id == id }!
      XCTAssertEqual(new.parentID, old.parentID, file: file, line: line)
      XCTAssertEqual(new.width, old.width, file: file, line: line)
      XCTAssertEqual(new.height, old.height, file: file, line: line)
      XCTAssertEqual(new.rotation, old.rotation, file: file, line: line)
      let a = before.worldTransform(old), b = after.worldTransform(new)
      XCTAssertEqual(a.a, b.a, accuracy: 1e-9, file: file, line: line)
      XCTAssertEqual(a.b, b.b, accuracy: 1e-9, file: file, line: line)
      XCTAssertEqual(a.c, b.c, accuracy: 1e-9, file: file, line: line)
      XCTAssertEqual(a.d, b.d, accuracy: 1e-9, file: file, line: line)
      let oldBox = before.bounds(of: old), newBox = after.bounds(of: new)
      XCTAssertEqual(oldBox.width, newBox.width, accuracy: 1e-8, file: file, line: line)
      XCTAssertEqual(oldBox.height, newBox.height, accuracy: 1e-8, file: file, line: line)
    }
  }

  func testAllSixAlignmentsUseCanvasAxesAcrossNestedReflectedAndShearedParents() throws {
    for mode in ["left", "right", "top", "bottom", "center_x", "center_y"] {
      let f = fixture(), before = f.artwork
      var art = before
      let roots = art.selectionRoots(f.selected), boxes = roots.map { art.bounds(of: $0) }
      let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
      try ArtworkCommands.apply("align", to: &art, ids: f.selected, arguments: ["mode": mode])
      for root in roots {
        let old = before.bounds(of: root), box = art.bounds(of: art.elements.first { $0.id == root.id }!)
        switch mode {
        case "left": XCTAssertEqual(box.x, union.x, accuracy: 1e-8)
        case "right": XCTAssertEqual(box.maxX, union.maxX, accuracy: 1e-8)
        case "center_x": XCTAssertEqual(box.center.x, union.center.x, accuracy: 1e-8)
        case "top": XCTAssertEqual(box.y, union.y, accuracy: 1e-8)
        case "bottom": XCTAssertEqual(box.maxY, union.maxY, accuracy: 1e-8)
        default: XCTAssertEqual(box.center.y, union.center.y, accuracy: 1e-8)
        }
        if ["left", "right", "center_x"].contains(mode) { XCTAssertEqual(box.y, old.y, accuracy: 1e-8) }
        else { XCTAssertEqual(box.x, old.x, accuracy: 1e-8) }
      }
      assertUnchangedGeometry(before, art, ids: f.selected)
      for id in f.fixed { XCTAssertEqual(art.elements.first { $0.id == id }, before.elements.first { $0.id == id }) }
      let group = before.elements.first { $0.id == f.groupID }!, child = before.elements.first { $0.id == f.childID }!
      let newGroup = art.elements.first { $0.id == f.groupID }!, newChild = art.elements.first { $0.id == f.childID }!
      let groupDelta = Point2(art.worldTransform(newGroup).tx - before.worldTransform(group).tx,
        art.worldTransform(newGroup).ty - before.worldTransform(group).ty)
      XCTAssertEqual(art.worldTransform(newChild).tx - before.worldTransform(child).tx, groupDelta.x, accuracy: 1e-8)
      XCTAssertEqual(art.worldTransform(newChild).ty - before.worldTransform(child).ty, groupDelta.y, accuracy: 1e-8)
    }
  }

  func testGapAndCenterDistributionPreserveWorldGeometryAcrossDifferentParents() throws {
    for mode in ["horizontal", "vertical", "horizontal_centers", "vertical_centers"] {
      let f = fixture(), before = f.artwork
      var art = before
      let horizontal = mode.hasPrefix("horizontal"), centers = mode.hasSuffix("_centers")
      func start(_ box: Rect2) -> Double { horizontal ? box.x : box.y }
      func end(_ box: Rect2) -> Double { horizontal ? box.maxX : box.maxY }
      func center(_ box: Rect2) -> Double { horizontal ? box.center.x : box.center.y }
      let ordered = before.selectionRoots(f.selected).sorted {
        let a = before.bounds(of: $0), b = before.bounds(of: $1)
        return centers ? center(a) < center(b) : start(a) < start(b)
      }
      let oldBoxes = ordered.map { before.bounds(of: $0) }
      try ArtworkCommands.apply("distribute", to: &art, ids: f.selected, arguments: ["mode": mode])
      let boxes = ordered.map { root in art.bounds(of: art.elements.first { $0.id == root.id }!) }
      let gaps = zip(boxes, boxes.dropFirst()).map { centers ? center($1) - center($0) : start($1) - end($0) }
      for gap in gaps { XCTAssertEqual(gap, gaps[0], accuracy: 1e-8) }
      if centers {
        XCTAssertEqual(center(boxes.first!), center(oldBoxes.first!), accuracy: 1e-8)
        XCTAssertEqual(center(boxes.last!), center(oldBoxes.last!), accuracy: 1e-8)
      } else {
        XCTAssertEqual(start(boxes.first!), oldBoxes.map(start).min()!, accuracy: 1e-8)
        XCTAssertEqual(end(boxes.last!), oldBoxes.map(end).max()!, accuracy: 1e-8)
      }
      for (old, box) in zip(oldBoxes, boxes) {
        XCTAssertEqual(horizontal ? box.y : box.x, horizontal ? old.y : old.x, accuracy: 1e-8)
      }
      assertUnchangedGeometry(before, art, ids: f.selected)
      for id in f.fixed { XCTAssertEqual(art.elements.first { $0.id == id }, before.elements.first { $0.id == id }) }
    }
  }

  func testDistributionTiesUseDocumentOrderForDifferentWidthsAndHeights() throws {
    for horizontal in [true, false] {
      for centers in [true, false] {
        let sizes = [30.0, 10.0, 5.0, 20.0]
        let positions = centers ? [35.0, 45, 47.5, 140] : [20.0, 20, 20, 200]
        let elements = sizes.enumerated().map { index, size -> ArtworkElement in
          .init(kind: "rectangle", x: horizontal ? positions[index] : 7,
            y: horizontal ? 7 : positions[index], width: horizontal ? size : 12, height: horizontal ? 12 : size)
        }
        var art = Artwork(elements: elements)
        let mode = (horizontal ? "horizontal" : "vertical") + (centers ? "_centers" : "")
        try ArtworkCommands.apply("distribute", to: &art, ids: Set(elements.map(\.id)), arguments: ["mode": mode])
        let expected: [Double] = centers ? [50.0, 250.0/3, 350.0/3, 150] : [20.0, 95, 150, 200]
        for (index, element) in elements.enumerated() {
          let box = art.bounds(of: art.elements.first { $0.id == element.id }!)
          let actual = centers ? (horizontal ? box.center.x : box.center.y) : (horizontal ? box.x : box.y)
          XCTAssertEqual(actual, expected[index], accuracy: 1e-8)
        }
      }
    }
  }

  func testSelectingAGroupAndItsDescendantMovesTheGroupOnlyOnce() throws {
    let f = fixture(), before = f.artwork
    var withoutChild = before, withChild = before
    try ArtworkCommands.apply("align", to: &withoutChild, ids: f.selected, arguments: ["mode": "left"])
    try ArtworkCommands.apply("align", to: &withChild, ids: f.selected.union([f.childID]), arguments: ["mode": "left"])
    XCTAssertEqual(withChild, withoutChild)
    XCTAssertEqual(withChild.elements.first { $0.id == f.childID }, before.elements.first { $0.id == f.childID })
  }

  func testLockedAncestorsTooFewRootsAndInvalidModesRejectAtomically() throws {
    let f = fixture()
    for command in ["align", "distribute"] {
      var locked = f.artwork
      locked.elements[locked.elements.firstIndex { $0.id == f.parentID }!].locked = true
      let before = locked
      XCTAssertThrowsError(try ArtworkCommands.apply(command, to: &locked, ids: f.selected,
        arguments: ["mode": command == "align" ? "left" : "horizontal"]))
      XCTAssertEqual(locked, before)
      var invalid = f.artwork
      XCTAssertThrowsError(try ArtworkCommands.apply(command, to: &invalid, ids: f.selected, arguments: ["mode": "diagonal"]))
      XCTAssertEqual(invalid, f.artwork)
    }
    var art = f.artwork
    XCTAssertThrowsError(try ArtworkCommands.apply("align", to: &art, ids: [f.nestedID], arguments: ["mode": "left"]))
    XCTAssertEqual(art, f.artwork)
    XCTAssertThrowsError(try ArtworkCommands.apply("distribute", to: &art, ids: [f.nestedID, f.groupID], arguments: ["mode": "horizontal"]))
    XCTAssertEqual(art, f.artwork)
    var singular = f.artwork
    singular.elements[singular.elements.firstIndex { $0.id == f.parentID }!].affine = .scale(0, 1)
    let before = singular
    XCTAssertThrowsError(try ArtworkCommands.apply("align", to: &singular, ids: f.selected, arguments: ["mode": "right"]))
    XCTAssertEqual(singular, before)
  }
}

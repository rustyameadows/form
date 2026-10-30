import CoreGraphics
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class ArtworkHitTestingTests: XCTestCase {
  private func rect(_ x: Double = 0, _ y: Double = 0, _ width: Double = 100, _ height: Double = 100) -> ArtworkElement {
    .init(kind: "rectangle", x: x, y: y, width: width, height: height)
  }
  private func hit(_ art: Artwork, _ x: Double, _ y: Double, tolerance: Double = 0, scope: UUID? = nil) -> UUID? {
    ArtworkHitTesting.hit(at: .init(x: x, y: y), in: art, scope: scope, tolerance: tolerance)?.id
  }

  func testUnpaintedAndDisabledStrokeLayersDoNotStealClicks() {
    let behind = rect()
    var front = rect()
    front.fillEnabled = false
    front.stroke = .init(width: 20)
    front.stroke?.enabled = false
    var art = Artwork(elements: [behind, front])
    XCTAssertEqual(hit(art, 1, 50, tolerance: 3.5), behind.id)
    front.stroke?.enabled = true
    front.stroke?.opacity = 0
    art.elements[1] = front
    XCTAssertEqual(hit(art, 1, 50, tolerance: 3.5), behind.id)
    front.stroke?.opacity = 1
    art.elements[1] = front
    XCTAssertEqual(hit(art, 1, 50), front.id)
    XCTAssertEqual(hit(art, 50, 50), behind.id)
  }

  func testExactPaintedHitWinsOverNearbyFrontOutline() {
    let behind = rect(1, 20, 30, 30)
    var front = rect(0, 0, 100, 100)
    front.fillEnabled = false
    front.stroke = .init(width: 0.5)
    let art = Artwork(elements: [behind, front])
    XCTAssertEqual(hit(art, 2, 30, tolerance: 3.5), behind.id)
    XCTAssertEqual(hit(art, -2, 30, tolerance: 3.5), front.id)
    XCTAssertNil(hit(art, -5, 30, tolerance: 3.5))
  }

  func testGroupsPickVisibleDescendantsInsteadOfEmptyBounds() {
    let behind = rect()
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 100, height: 100)
    group.contentSize = .init(100, 100)
    var left = rect(0, 0, 10, 10), right = rect(90, 90, 10, 10)
    left.parentID = group.id
    right.parentID = group.id
    let art = Artwork(elements: [behind, group, left, right])
    XCTAssertEqual(hit(art, 5, 5), group.id)
    XCTAssertEqual(hit(art, 95, 95), group.id)
    XCTAssertEqual(hit(art, 50, 50), behind.id)
    XCTAssertEqual(hit(art, 5, 5, scope: group.id), left.id)
  }

  func testScreenToleranceSurvivesNestedNonuniformScaleRotationAndShear() {
    var outer = ArtworkElement(kind: "group", x: 30, y: 20, width: 800, height: 25)
    outer.contentSize = .init(100, 100)
    outer.rotation = 31
    var inner = ArtworkElement(kind: "group", x: 10, y: 10, width: 50, height: 50)
    inner.parentID = outer.id
    inner.contentSize = .init(100, 100)
    inner.affine = .init(a: 1, b: 0.25, c: 0.4, d: 1, tx: 0, ty: 0)
    var line = ArtworkElement(kind: "line", x: 5, y: 5, width: 80, height: 0.001)
    line.parentID = inner.id
    line.stroke = .init(width: 0.00001)
    let art = Artwork(elements: [outer, inner, line])
    let transform = art.worldTransform(line)
    let a = transform.apply(.init(0, 0)), b = transform.apply(.init(80, 0.001))
    let middle = Point2((a.x + b.x) / 2, (a.y + b.y) / 2)
    let length = hypot(b.x - a.x, b.y - a.y)
    let normal = Point2(-(b.y - a.y) / length, (b.x - a.x) / length)
    for zoom in [0.08, 1, 24] {
      let tolerance = 3.5 / (TypographyEngine.pointsPerMM * zoom)
      XCTAssertEqual(hit(art, middle.x + normal.x * tolerance * 0.8,
        middle.y + normal.y * tolerance * 0.8, tolerance: tolerance, scope: inner.id), line.id)
      XCTAssertNil(hit(art, middle.x + normal.x * tolerance * 1.2,
        middle.y + normal.y * tolerance * 1.2, tolerance: tolerance, scope: inner.id))
    }
  }

  func testMasksClipRootAndScopedDescendantTargets() {
    var group = ArtworkElement(kind: "group", x: 20, y: 30, width: 100, height: 100)
    group.contentSize = .init(100, 100)
    group.rotation = 17
    var shape = rect()
    shape.parentID = group.id
    var mask = ArtworkElement(kind: "ellipse", x: 25, y: 25, width: 50, height: 50)
    mask.hidden = true
    mask.parentID = group.id
    shape.clipID = mask.id
    let art = Artwork(elements: [group, shape, mask])
    let inside = art.worldTransform(shape).apply(.init(50, 50))
    let outside = art.worldTransform(shape).apply(.init(27, 27))
    XCTAssertEqual(hit(art, inside.x, inside.y), group.id)
    XCTAssertNil(hit(art, outside.x, outside.y, tolerance: 2))
    XCTAssertNil(hit(art, outside.x, outside.y, tolerance: 2, scope: group.id))
    XCTAssertEqual(ArtworkHitTesting.hit(at: .init(x: inside.x, y: inside.y), in: art,
      scope: group.id, editingMask: mask.id)?.id, mask.id)

    var ancestorMask = rect(0, 0, 1, 1)
    ancestorMask.hidden = true
    var clipped = art
    clipped.elements[0].clipID = ancestorMask.id
    clipped.elements.append(ancestorMask)
    XCTAssertNil(hit(clipped, inside.x, inside.y, scope: group.id))
  }

  func testBooleanSubtractionHoleAllowsUnderlyingSelection() throws {
    let behind = rect()
    let outer = rect(), cutout = rect(25, 25, 50, 50)
    var art = Artwork(elements: [behind, outer, cutout])
    let groupID = try BooleanCommands.create("subtract", artwork: &art, elements: [outer.id, cutout.id])
    XCTAssertEqual(hit(art, 10, 10), groupID)
    XCTAssertEqual(hit(art, 50, 50), behind.id)
  }

  func testActualDashGapsAndOutsideStrokeAreRespected() {
    var shape = rect()
    shape.fillEnabled = false
    shape.stroke = .init(width: 8)
    shape.stroke?.alignment = "outside"
    var art = Artwork(elements: [shape])
    XCTAssertEqual(hit(art, -7, 50), shape.id)
    XCTAssertNil(hit(art, 3, 50))
    var line = ArtworkElement(kind: "line", x: 0, y: 0, width: 100, height: 0.001)
    line.stroke = .init(width: 2)
    line.stroke?.dash = [10, 20]
    line.stroke?.cap = "butt"
    art = Artwork(elements: [line])
    XCTAssertEqual(hit(art, 5, 0.00005), line.id)
    XCTAssertNil(hit(art, 20, 0.0002, tolerance: 3.5))
    XCTAssertEqual(hit(art, 11, 0.00011, tolerance: 3.5), line.id)
  }

  func testResolvedComponentPicksItsContentAndReturnsEditableInstance() {
    var instance = ArtworkElement(kind: "group", x: 0, y: 0, width: 100, height: 100)
    instance.contentSize = .init(100, 100)
    instance.component = .init(sourceObjectID: UUID())
    let raw = Artwork(elements: [instance])
    var child = rect(10, 10, 20, 20)
    child.parentID = instance.id
    var resolved = raw
    resolved.elements.append(child)
    XCTAssertEqual(ArtworkHitTesting.hit(at: .init(x: 20, y: 20), in: raw,
      renderedArtwork: resolved), instance)
    XCTAssertNil(ArtworkHitTesting.hit(at: .init(x: 80, y: 80), in: raw,
      renderedArtwork: resolved))
  }

  func testHiddenLockedTransparentAndExcludedTargetsAreSkipped() {
    let behind = rect()
    for mode in ["hidden", "locked", "opacity", "fillOpacity", "excluded"] {
      var front = rect()
      if mode == "hidden" { front.hidden = true }
      if mode == "locked" { front.locked = true }
      if mode == "opacity" { front.opacity = 0 }
      if mode == "fillOpacity" { front.fillOpacity = 0 }
      let art = Artwork(elements: [behind, front])
      XCTAssertEqual(ArtworkHitTesting.hit(at: .init(x: 50, y: 50), in: art,
        excluding: mode == "excluded" ? [front.id] : [])?.id, behind.id, mode)
    }
  }

  func testEvenOddCompoundHolesAndEllipseCornersAreNotFilledTargets() {
    let behind = rect()
    var ellipse = ArtworkElement(kind: "ellipse", x: 0, y: 0, width: 100, height: 100)
    XCTAssertEqual(hit(.init(elements: [behind, ellipse]), 1, 1), behind.id)
    let outer = VectorContour([.init(.init(0, 0)), .init(.init(100, 0)),
      .init(.init(100, 100)), .init(.init(0, 100))], closed: true)
    let hole = VectorContour([.init(.init(25, 25)), .init(.init(75, 25)),
      .init(.init(75, 75)), .init(.init(25, 75))], closed: true)
    ellipse.kind = "path"
    ellipse.path = .init(width: 100, height: 100, contours: [outer, hole], evenOdd: true)
    let art = Artwork(elements: [behind, ellipse])
    XCTAssertEqual(hit(art, 10, 10), ellipse.id)
    XCTAssertEqual(hit(art, 50, 50), behind.id)
  }

  func testProximityDoesNotResurrectCancelledCompoundContours() {
    let outer = VectorContour([.init(.init(0, 0)), .init(.init(100, 0)),
      .init(.init(100, 100)), .init(.init(0, 100))], closed: true)
    var path = ArtworkElement(kind: "path", x: 0, y: 0, width: 100, height: 100)
    path.path = .init(width: 100, height: 100, contours: [outer, outer], evenOdd: true)
    XCTAssertNil(hit(.init(elements: [path]), 1, 50, tolerance: 3.5))
    XCTAssertNil(hit(.init(elements: [path]), -1, 50, tolerance: 3.5))
  }

  func testProximityDoesNotResurrectGeometryHiddenBeyondItsMask() {
    var mask = rect(0, 0, 10, 10)
    mask.hidden = true
    var shape = rect(11, 0, 10, 10)
    shape.clipID = mask.id
    var art = Artwork(elements: [shape, mask])
    XCTAssertNil(hit(art, 9.5, 5, tolerance: 3.5))

    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 30, height: 30)
    group.contentSize = .init(30, 30); group.clipID = mask.id
    shape.clipID = nil; shape.parentID = group.id
    art = .init(elements: [group, shape, mask])
    XCTAssertNil(hit(art, 9.5, 5, tolerance: 3.5), "Ancestor clipping also constrains proximity")
    XCTAssertNil(hit(art, 9.5, 5, tolerance: 3.5, scope: group.id))

    shape.fillEnabled = false; shape.stroke = .init(width: 1)
    art.elements[1] = shape
    XCTAssertNil(hit(art, 9.5, 5, tolerance: 3.5), "The hidden stroke must not become a target either")
    shape.x = 10.2
    art.elements[1] = shape
    XCTAssertEqual(hit(art, 9.5, 5, tolerance: 3.5), group.id,
      "A stroke genuinely visible through the clip still gets a generous target")
  }

  func testDenseLayeredArtworkRetainsExactTargetingAcrossGroupsMasksAndTransforms() {
    var elements: [ArtworkElement] = [], targets: [(UUID, CGPoint)] = [], gaps: [CGPoint] = []
    for index in 0..<120 {
      let column = Double(index % 12), row = Double(index / 12)
      var group = ArtworkElement(kind: "group", x: column * 100, y: row * 80, width: 60, height: 45)
      group.contentSize = .init(60, 45)
      group.rotation = Double(index % 5) * 4
      var child = rect(5, 5, 20, 20)
      child.parentID = group.id
      var hollow = rect(0, 0, 60, 45)
      hollow.parentID = group.id; hollow.fillEnabled = false; hollow.stroke = .init(width: 0.5)
      var clip = rect(30, 0, 10, 10)
      clip.parentID = group.id; clip.hidden = true
      var invisible = rect(41, 0, 10, 10)
      invisible.parentID = group.id; invisible.clipID = clip.id
      elements.append(contentsOf: [group, child, hollow, clip, invisible])
      let center = group.localTransform.apply(.init(15, 15))
      let gap = group.localTransform.apply(.init(35, 25))
      targets.append((group.id, .init(x: center.x, y: center.y)))
      gaps.append(.init(x: gap.x, y: gap.y))
    }
    let art = Artwork(elements: elements)
    let picker = ArtworkHitTesting.Picker(in: art)
    XCTAssertEqual(art.elements.count, 600)
    let start = CFAbsoluteTimeGetCurrent()
    for (index, target) in targets.enumerated() {
      XCTAssertEqual(picker.hit(at: target.1, tolerance: 1.25)?.id, target.0)
      XCTAssertNil(picker.hit(at: gaps[index], tolerance: 1.25))
    }
    // A bounded interaction regression, not a benchmark tied to one Mac's frame rate.
    XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 5,
      "240 picks through 600 layers should not become multi-second individual interactions")
  }

  func testReusablePickerKeepsItsSnapshotAndAcceptsChangingZoomTolerance() {
    var shape = rect(10, 10, 20, 20)
    let original = Artwork(elements: [shape]), picker = ArtworkHitTesting.Picker(in: original)
    for _ in 0..<5 {
      XCTAssertEqual(picker.hit(at: .init(x: 20, y: 20))?.id, shape.id)
      XCTAssertEqual(picker.hit(at: .init(x: 8, y: 20), tolerance: 3.5)?.id, shape.id)
      XCTAssertNil(picker.hit(at: .init(x: 8, y: 20), tolerance: 0.5))
    }
    shape.x = 100
    let changed = Artwork(elements: [shape]), replacement = ArtworkHitTesting.Picker(in: changed)
    XCTAssertEqual(picker.hit(at: .init(x: 20, y: 20))?.id, shape.id)
    XCTAssertNil(replacement.hit(at: .init(x: 20, y: 20)))
    XCTAssertEqual(replacement.hit(at: .init(x: 110, y: 20))?.id, shape.id)
  }

  func testTextAndImagesKeepTheirEditableFrameTargets() {
    var text = ArtworkElement(kind: "text", x: 20, y: 30, width: 80, height: 50, text: "Short")
    text.rotation = 22
    // Text rendering uses its text color even if a retained vector gradient is transparent.
    var start = GradientStop(0, "#000000"), end = GradientStop(1, "#000000")
    start.opacity = 0; end.opacity = 0
    text.gradient = .init(stops: [start, end])
    var art = Artwork(elements: [text])
    let p = art.worldTransform(text).apply(.init(70, 40))
    XCTAssertEqual(hit(art, p.x, p.y), text.id)
    var image = ArtworkElement(kind: "image", x: 0, y: 0, width: 100, height: 100)
    image.fillEnabled = false
    image.fillOpacity = 0
    art = .init(elements: [image])
    XCTAssertEqual(hit(art, 50, 50), image.id)
    image.opacity = 0
    art.elements = [image]
    XCTAssertNil(hit(art, 50, 50))
  }
}

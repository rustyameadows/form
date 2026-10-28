import XCTest
@testable import FormCore

final class SewingPatternTests: XCTestCase {
  private func piece(_ name: String = "Panel", x: Double = 20, y: Double = 20, width: Double = 100, height: Double = 80) -> ArtworkElement {
    var e = ArtworkElement(kind: "rectangle", x: x, y: y, width: width, height: height)
    e.sewingPiece = .init(name: name); return e
  }
  func testPerEdgeAllowancesAreExactPhysicalOffsets() throws {
    var e = piece(); e.sewingPiece!.edgeAllowances = [0: 20, 1: 5, 2: 10, 3: 15]
    let g = try SewingPatterns.geometry(e, in: Artwork(elements: [e]))
    XCTAssertEqual(g.edgeLengths, [100, 80, 100, 80])
    XCTAssertEqual(g.cut, [.init(5, 0), .init(125, 0), .init(125, 110), .init(5, 110)])
    XCTAssertEqual(g.bounds, .init(5, 0, 120, 110))
    e.sewingPiece!.onFoldEdge = 3
    let folded = try SewingPatterns.geometry(e, in: Artwork(elements: [e]))
    XCTAssertEqual(folded.cut[0].x, 20); XCTAssertEqual(folded.cut[3].x, 20)
  }
  func testMirroredRotatedAndNonuniformTransformsDoNotScaleTheSeamAllowance() throws {
    for transform in [Affine2.rotation(37), .scale(-1, 1), .rotation(19).followed(by: .scale(2.5, 0.7)), .init(a: 1, b: 0.3, c: 0.4, d: 1)] {
      var e = piece(); e.affine = transform; e.sewingPiece!.seamAllowance = 12
      let g = try SewingPatterns.geometry(e, in: Artwork(elements: [e]))
      for i in g.stitch.indices {
        let n = g.normals[i], offset = Point2(g.cut[i].x - g.stitch[i].x, g.cut[i].y - g.stitch[i].y)
        XCTAssertEqual(n.x * offset.x + n.y * offset.y, 12, accuracy: 1e-8)
        let next = (i + 1) % g.stitch.count
        let end = Point2(g.cut[next].x - g.stitch[i].x, g.cut[next].y - g.stitch[i].y)
        XCTAssertEqual(n.x * end.x + n.y * end.y, 12, accuracy: 1e-8)
      }
      XCTAssertEqual(hypot(g.grainDirection.x, g.grainDirection.y), 1, accuracy: 1e-9)
    }
  }
  func testSeamMatchingUsesActualEdgesAndNumberedCutCopies() throws {
    var a = piece("Front"); let b = piece("Back", x: 200, height: 100)
    a.sewingPiece!.cutQuantity = 2
    var art = Artwork(elements: [a, b])
    art.sewingSeams = [.init(name: "Side", first: .init(elementID: a.id, edge: 1), second: .init(elementID: b.id, edge: 3))]
    let mismatch = try SewingPatterns.diagnostics(art)[0]
    XCTAssertEqual(mismatch.firstLength, 80); XCTAssertEqual(mismatch.secondLength, 100); XCTAssertFalse(mismatch.matches)
    art.elements[1].height = 80; XCTAssertTrue(try SewingPatterns.diagnostics(art)[0].matches)
    art.sewingSeams = [.init(name: "Cut copies", first: .init(elementID: a.id, edge: 1, copy: 1), second: .init(elementID: a.id, edge: 1, copy: 2))]
    XCTAssertNoThrow(try validateArtwork(art))
    art.elements[0].sewingPiece!.cutQuantity = 1; XCTAssertThrowsError(try validateArtwork(art))
  }
  func testUnsupportedContoursAndUnsafeNotchesFailExplicitly() throws {
    var e = piece(); e.cornerRadius = 8
    XCTAssertThrowsError(try SewingPatterns.geometry(e, in: Artwork(elements: [e])))
    e.cornerRadius = nil; e.kind = "path"
    e.path = .init(width: 100, height: 80, contours: [.init([.init(.init(0, 0)), .init(.init(100, 0)), .init(.init(50, 20)), .init(.init(100, 80)), .init(.init(0, 80))])])
    XCTAssertNoThrow(try SewingPatterns.geometry(e, in: Artwork(elements: [e])))
    e = piece(); e.sewingPiece!.notches = [.init(edge: 0, position: 0.01)]
    XCTAssertThrowsError(try SewingPatterns.geometry(e, in: Artwork(elements: [e])))
    e.sewingPiece!.notches[0].position = 0.5
    XCTAssertNoThrow(try SewingPatterns.geometry(e, in: Artwork(elements: [e])))
    e.sewingPiece!.notches[0].depth = 10
    XCTAssertThrowsError(try SewingPatterns.geometry(e, in: Artwork(elements: [e])))
    e.sewingPiece!.notches = []; e.opacity = 0.5
    XCTAssertThrowsError(try SewingPatterns.geometry(e, in: Artwork(elements: [e])))
  }
  func testGroupingDuplicationDeletionAndSelectionExportKeepSeamReferencesConsistent() throws {
    let a = piece("A"), b = piece("B", x: 200)
    var art = Artwork(elements: [a, b])
    art.sewingSeams = [.init(name: "Sides", first: .init(elementID: a.id, edge: 1), second: .init(elementID: b.id, edge: 3))]
    let lengths = try SewingPatterns.diagnostics(art)
    let group = try ArtworkCommands.apply("group", to: &art, ids: [a.id, b.id])
    XCTAssertEqual(try SewingPatterns.diagnostics(art), lengths)
    _ = try ArtworkCommands.apply("ungroup", to: &art, ids: group)
    XCTAssertEqual(try SewingPatterns.diagnostics(art), lengths)
    let clones = try ArtworkCommands.apply("duplicate", to: &art, ids: [a.id, b.id])
    XCTAssertEqual(art.sewingSeams?.count, 2)
    XCTAssertTrue(art.sewingSeams!.last!.first.elementID != a.id)
    XCTAssertTrue(clones.contains(art.sewingSeams!.last!.first.elementID)); XCTAssertNoThrow(try validateArtwork(art))
    _ = try ArtworkCommands.apply("delete", to: &art, ids: [a.id])
    XCTAssertEqual(art.sewingSeams?.count, 1)
    XCTAssertNil(try art.exporting([b.id]).artwork.sewingSeams)
  }
  func testToteTemplateHasRealCutQuantitiesGrainNotchesAndMatchedCopySeams() throws {
    let tote = try SewingPatternTemplates.tote()
    XCTAssertEqual(tote.artwork.elements.count, 2); XCTAssertEqual(tote.artwork.sewingSeams?.count, 3)
    let body = try SewingPatterns.geometry(tote.artwork.elements[0], in: tote.artwork)
    XCTAssertEqual(body.piece.cutQuantity, 2); XCTAssertEqual(body.piece.notches.count, 2)
    XCTAssertEqual(body.bounds.width, 360); XCTAssertEqual(body.bounds.height, 420)
    let handle = try SewingPatterns.geometry(tote.artwork.elements[1], in: tote.artwork)
    XCTAssertEqual(handle.piece.cutQuantity, 2); XCTAssertEqual(handle.bounds.width, 120); XCTAssertEqual(handle.bounds.height, 640)
    XCTAssertTrue(try SewingPatterns.diagnostics(tote.artwork).allSatisfy(\.matches))
    XCTAssertThrowsError(try SewingPatternTemplates.tote(["width": true]))
  }
  func testPairedPiecesTransferTogetherAcrossCanvasOwnersWithCollisionRemapping() throws {
    var project = Project(name: "Transferred sewing pieces")
    let workspace = try project.ensureCanvasWorkspace()
    let a = piece("A"), b = piece("B", x: 200)
    var art = Artwork(elements: [a, b])
    art.sewingSeams = [.init(name: "Sides", first: .init(elementID: a.id, edge: 1), second: .init(elementID: b.id, edge: 3))]
    try project.setArtwork(art, for: workspace.id)
    var frame = try project.makeObject(recipeID: "artboard", name: "Destination", parameters: ["width": 800, "depth": 750])
    var unrelated = ArtworkElement(kind: "rectangle", x: 500, y: 400, width: 30, height: 20)
    unrelated.id = a.id; frame.artwork = Artwork(elements: [unrelated]); project.objects.append(frame)
    let before = project
    XCTAssertThrowsError(try project.transferArtwork(from: workspace.id, to: frame.id, ids: [a.id]))
    XCTAssertEqual(project, before)
    let selected = try project.transferArtwork(from: workspace.id, to: frame.id, ids: [a.id, b.id], offset: .init(15, 25))
    let destination = project.objects.first { $0.id == frame.id }!.artwork!, seam = try XCTUnwrap(destination.sewingSeams?.first)
    XCTAssertNotEqual(seam.first.elementID, a.id); XCTAssertTrue(selected.contains(seam.first.elementID))
    XCTAssertEqual(seam.second.elementID, b.id)
    XCTAssertNil(project.canvasWorkspace!.artwork!.sewingSeams)
    let moved = destination.elements.first { $0.id == seam.first.elementID }!
    let geometry = try SewingPatterns.geometry(moved, in: destination)
    XCTAssertEqual(geometry.stitch[0], .init(35, 45)); XCTAssertEqual(geometry.edgeLengths, [100, 80, 100, 80])
    XCTAssertTrue(try SewingPatterns.diagnostics(destination)[0].matches)
  }
}

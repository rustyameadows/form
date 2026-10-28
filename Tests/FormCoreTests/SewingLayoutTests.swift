import XCTest
@testable import FormCore

final class SewingLayoutTests: XCTestCase {
  private func piece(_ name: String, width: Double = 20, height: Double = 30, quantity: Int = 1) -> ArtworkElement {
    var e = ArtworkElement(kind: "rectangle", x: 35, y: 50, width: width, height: height)
    e.sewingPiece = .init(name: name); e.sewingPiece!.seamAllowance = 0
    e.sewingPiece!.materialID = "flight-nylon"; e.sewingPiece!.cutQuantity = quantity
    return e
  }
  private func layout(width: Double? = 200) -> SewingCutLayout {
    var l = SewingCutLayout(materialID: "flight-nylon", stockWidth: width)
    l.margin = 5; l.spacing = 3; return l
  }
  func testPlannerIsDeterministicExpandsExactQuantitiesAndDoesNotChangeSources() throws {
    let a = piece("Body", width: 60, height: 80, quantity: 3), b = piece("Strap", width: 12, height: 110, quantity: 2)
    let source = Artwork(elements: [a, b]), original = source
    let options = layout()
    let first = try SewingLayouts.planned(options, source: source), second = try SewingLayouts.planned(options, source: source)
    XCTAssertEqual(first.layout, second.layout); XCTAssertTrue(first.preflight.isValid)
    XCTAssertEqual(first.layout.placements.count, 5)
    XCTAssertEqual(Set(first.layout.placements.filter { $0.elementID == a.id }.flatMap(\.copies)), [1, 2, 3])
    XCTAssertEqual(Set(first.layout.placements.filter { $0.elementID == b.id }.flatMap(\.copies)), [1, 2])
    XCTAssertEqual(source, original)
    XCTAssertGreaterThan(first.preflight.candidateChecks, 0)
    XCTAssertLessThanOrEqual(first.preflight.candidateChecks, SewingLayoutLimits.maximumCandidates)
  }
  func testDiagonalClearanceUsesActualRotatedContoursInsteadOfOverlappingBounds() throws {
    let e = piece("Diamond", width: 10, height: 10, quantity: 2), source = Artwork(elements: [e])
    var l = layout(width: 100); l.margin = 0; l.grain = .unrestricted; l.spacing = 4.1
    l.placements = [.init(elementID: e.id, copies: [1], x: 0, y: 0, rotation: 45), .init(elementID: e.id, copies: [2], x: 10, y: 10, rotation: 45)]
    let report = try SewingLayouts.preflight(l, source: source)
    XCTAssertTrue(report.isValid)
    let a = report.placements[0], b = report.placements[1]
    XCTAssertGreaterThan(a.bounds.maxX, b.bounds.x); XCTAssertGreaterThan(a.bounds.maxY, b.bounds.y)
    var comparisons = 0
    let distance = try SewingLayoutGeometry.separation(a, b, required: 4.2, comparisons: &comparisons)
    XCTAssertFalse(distance.overlaps); XCTAssertEqual(distance.distance, 10 * sqrt(2) - 10, accuracy: 1e-8)
    l.spacing = 4.2
    XCTAssertTrue(try SewingLayouts.preflight(l, source: source).issues.contains { $0.kind == .spacing })
  }
  func testRealVNotchCanContainASeparatedSmallPieceButMovingItIntoFabricCollides() throws {
    var body = piece("Notched body", width: 20, height: 20)
    body.sewingPiece!.seamAllowance = 10
    var notch = SewingNotch(edge: 0, position: 0.5); notch.width = 6; notch.depth = 6
    body.sewingPiece!.notches = [notch]
    var triangle = piece("Small triangle", width: 2, height: 2); triangle.kind = "path"
    triangle.path = .init(width: 2, height: 2, contours: [.init([.init(.init(0,0)),.init(.init(2,0)),.init(.init(1,2))])])
    let source = Artwork(elements: [body, triangle])
    var l = layout(width: 100); l.margin = 0; l.spacing = 0.1; l.grain = .unrestricted; l.surface = .sheet; l.sheetLength = 100
    l.placements = [.init(elementID: body.id, copies: [1], x: 0, y: 0), .init(elementID: triangle.id, copies: [1], x: 19, y: 1)]
    let valid = try SewingLayouts.preflight(l, source: source)
    XCTAssertTrue(valid.isValid); XCTAssertEqual(valid.cutAreaMM2, 1584, accuracy: 1e-8)
    l.placements[1].y = 5
    XCTAssertTrue(try SewingLayouts.preflight(l, source: source).issues.contains { $0.kind == .collision })
  }
  func testFoldedStockAccountsForTwoPlyOrdinaryCopiesAndFullOnFoldPieces() throws {
    let ordinary = piece("Ordinary", width: 10, height: 20, quantity: 2)
    var folded = piece("On fold", width: 30, height: 40, quantity: 2)
    folded.sewingPiece!.seamAllowance = 5; folded.sewingPiece!.onFoldEdge = 3
    let source = Artwork(elements: [ordinary, folded])
    var l = layout(); l.stock = .foldedPair
    let planned = try SewingLayouts.planned(l, source: source)
    XCTAssertTrue(planned.preflight.isValid); XCTAssertEqual(planned.preflight.workingWidth, 100)
    XCTAssertEqual(planned.layout.placements.count, 3)
    XCTAssertEqual(planned.layout.placements.first { $0.elementID == ordinary.id }?.copies, [1, 2])
    XCTAssertEqual(planned.layout.placements.filter { $0.elementID == folded.id }.map(\.copies), [[1], [2]])
    XCTAssertEqual(planned.preflight.cutAreaMM2, 7400, accuracy: 1e-8)
    for p in planned.preflight.placements where p.geometry.elementID == folded.id {
      XCTAssertEqual(p.transform.apply(p.geometry.stitch[3]).x, 0, accuracy: 1e-8)
      XCTAssertEqual(p.transform.apply(p.geometry.stitch[0]).x, 0, accuracy: 1e-8)
    }
    var moved = planned.layout
    let index = moved.placements.firstIndex { $0.elementID == folded.id }!; moved.placements[index].x += 10
    XCTAssertTrue(try SewingLayouts.preflight(moved, source: source).issues.contains { $0.kind == .fold })
  }
  func testFoldConflictsAndOddOrdinaryQuantitiesAreExplicit() throws {
    var ordinary = piece("Odd", quantity: 3), source = Artwork(elements: [ordinary])
    var l = layout(); l.stock = .foldedPair
    XCTAssertThrowsError(try SewingLayouts.planned(l, source: source))
    ordinary.sewingPiece!.cutQuantity = 1; ordinary.sewingPiece!.onFoldEdge = 0; ordinary.sewingPiece!.grainAngle = 90
    source.elements = [ordinary]
    XCTAssertThrowsError(try SewingLayouts.planned(l, source: source))
    l.stock = .singleLayer
    XCTAssertTrue(try SewingLayouts.preflight(l, source: source).issues.contains { $0.kind == .fold })
  }
  func testDirectionalGrainManualPosesAndMarginsArePreflighted() throws {
    let e = piece("Warp", width: 20, height: 30), source = Artwork(elements: [e])
    var l = layout(width: 100); l.grain = .directional
    l.placements = [.init(elementID: e.id, copies: [1], x: 5, y: 5, rotation: 180)]
    XCTAssertTrue(try SewingLayouts.preflight(l, source: source).issues.contains { $0.kind == .grain })
    l.grain = .bidirectional; XCTAssertTrue(try SewingLayouts.preflight(l, source: source).isValid)
    l.placements[0].x = 80
    XCTAssertTrue(try SewingLayouts.preflight(l, source: source).issues.contains { $0.kind == .bounds })
    l.placements[0].x = 5; l.placements[0].rotation = 37; l.grain = .unrestricted
    XCTAssertTrue(try SewingLayouts.preflight(l, source: source).issues.contains { $0.kind == .bounds } == false)
  }
  func testStockDimensionsAreRequiredAndNoLengthOrCostIsGuessed() throws {
    let source = Artwork(elements: [piece("Panel")])
    var l = layout(width: nil)
    XCTAssertNoThrow(try l.validateMetadata())
    XCTAssertThrowsError(try SewingLayouts.planned(l, source: source))
    let missing = try SewingLayouts.preflight(l, source: source)
    XCTAssertTrue(missing.issues.contains { $0.kind == .stock }); XCTAssertNil(missing.estimatedCost)
    l.stockWidth = 200; l.surface = .sheet; l.sheetLength = nil
    XCTAssertThrowsError(try SewingLayouts.planned(l, source: source))
    l.sheetLength = 300; l.costPerSquareMeter = 12.5
    let complete = try SewingLayouts.planned(l, source: source)
    XCTAssertEqual(complete.preflight.consumedLength, 300)
    XCTAssertEqual(complete.preflight.allocatedAreaMM2, 60000)
    XCTAssertEqual(complete.preflight.estimatedCost!, 0.75, accuracy: 1e-9)
  }
  func testTooWidePiecesRemainExplicitlyUnplacedRatherThanScaled() throws {
    let e = piece("Oversize", width: 150, height: 50), source = Artwork(elements: [e])
    var l = layout(width: 100); l.grain = .directional
    let result = try SewingLayouts.planned(l, source: source)
    XCTAssertTrue(result.layout.placements.isEmpty)
    XCTAssertTrue(result.preflight.issues.contains { $0.kind == .missingCopy })
    XCTAssertEqual(source.elements[0].width, 150)
  }
  func testMaterialScopeExcludesOtherStocksAndRetainsExplicitMissingSourceDiagnostics() throws {
    let a = piece("Nylon"), b = piece("Other fabric")
    var source = Artwork(elements: [a, b]); source.elements[1].sewingPiece!.materialID = "flight-sage"
    var l = layout()
    let result = try SewingLayouts.planned(l, source: source)
    XCTAssertEqual(result.layout.placements.count, 1); XCTAssertEqual(result.preflight.excludedPieceIDs, [b.id])
    l.elementIDs = [a.id, b.id]
    XCTAssertTrue(try SewingLayouts.preflight(l, source: source).issues.contains { $0.kind == .source })
    l.elementIDs = [UUID()]
    XCTAssertThrowsError(try SewingLayouts.planned(l, source: source))
  }
  func testManualPlacementsRoundTripAndLayoutEditingDoesNotChangeRenderOrPieceSources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
    let repo = try ProjectRepository(root: root)
    var project = Project(name: "Saved manual layout"), object = try Project(name: "Factory").makeObject(recipeID: "artboard", name: "Pieces", parameters: ["width": 800, "depth": 750])
    let source = Artwork(elements: [piece("Panel", quantity: 2)])
    var l = try SewingLayouts.planned(layout(), source: source).layout
    l.placements[0].x = 73; l.placements[0].y = 191; l.fabricOrigin = .init(13, -27)
    var art = source; art.sewingLayout = l; object.artwork = art; project.objects = [object]
    XCTAssertEqual(art.renderDefinition, source.renderDefinition)
    XCTAssertEqual(project.minimumSchemaVersion, 27)
    try repo.save(project); let loaded = try repo.load(project.id)
    XCTAssertEqual(loaded.objects[0].artwork?.sewingLayout, l)
    XCTAssertEqual(loaded.objects[0].artwork?.elements, source.elements)
  }
  func testSharedCommandSavePlanAndInvalidStockHaveAtomicUndo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
    let engine = OperationEngine(repository:try ProjectRepository(root:root))
    var project = Project(name:"MCP layout"), source = Artwork(elements:[piece("Panel",quantity:2)])
    let workspace = try project.ensureCanvasWorkspace(); try project.setArtwork(source,for:workspace.id); engine.project = project
    let original = project
    var options = layout(width:nil)
    _ = try engine.call("form_edit_artwork",arguments:["object_id":workspace.id.uuidString,"command":"cut_layout","cutting_layout":try jsonObject(options)])
    let unknown = engine.project!
    XCTAssertThrowsError(try engine.call("form_edit_artwork",arguments:["object_id":workspace.id.uuidString,"command":"cut_layout","layout_action":"plan"]))
    XCTAssertEqual(engine.project,unknown)
    options.stockWidth = 200
    _ = try engine.call("form_edit_artwork",arguments:["object_id":workspace.id.uuidString,"command":"cut_layout","layout_action":"plan","cutting_layout":try jsonObject(options)])
    let planned = engine.project!.canvasWorkspace!.artwork!
    XCTAssertEqual(planned.elements,source.elements); XCTAssertEqual(planned.sewingLayout?.placements.count,2)
    XCTAssertEqual(engine.project!.minimumSchemaVersion,27)
    engine.undo(); XCTAssertEqual(engine.project,unknown); engine.undo(); XCTAssertEqual(engine.project,original)
    source.elements[0].sewingPiece!.cutQuantity = 100
    let tooMany = Artwork(elements:[source.elements[0],piece("Second",quantity:100),piece("Third",quantity:100)])
    XCTAssertThrowsError(try SewingLayouts.planned(layout(),source:tooMany))
  }
  func testWholeLayoutTransferRetainsManualStockPosesAndRemapsCollidingSources() throws {
    var project = Project(name:"Transferred layout")
    let workspace = try project.ensureCanvasWorkspace(), a = piece("A"), b = piece("B",width:30)
    var source = Artwork(elements:[a,b]); source.sewingLayout = try SewingLayouts.planned(layout(),source:source).layout
    try project.setArtwork(source,for:workspace.id)
    var target = try project.makeObject(recipeID:"artboard",name:"Target",parameters:["width":800,"depth":750])
    var unrelated = ArtworkElement(kind:"rectangle",x:600,y:600,width:20,height:20); unrelated.id = a.id
    target.artwork = Artwork(elements:[unrelated]); project.objects.append(target)
    let before = project
    XCTAssertThrowsError(try project.transferArtwork(from:workspace.id,to:target.id,ids:[a.id]))
    XCTAssertEqual(project,before)
    _ = try project.transferArtwork(from:workspace.id,to:target.id,ids:[a.id,b.id],offset:.init(100,200))
    let moved = project.objects.first { $0.id == target.id }!.artwork!, saved = try XCTUnwrap(moved.sewingLayout)
    XCTAssertNil(project.canvasWorkspace!.artwork!.sewingLayout)
    XCTAssertEqual(saved.id,source.sewingLayout!.id)
    for old in source.sewingLayout!.placements {
      let new = try XCTUnwrap(saved.placements.first { $0.copies == old.copies && (old.elementID == b.id ? $0.elementID == b.id : $0.elementID != b.id) })
      XCTAssertEqual(new.x,old.x); XCTAssertEqual(new.y,old.y); XCTAssertEqual(new.rotation,old.rotation)
    }
    XCTAssertFalse(saved.placements.contains { $0.elementID == a.id })
    XCTAssertTrue(try SewingLayouts.preflight(saved,source:moved).isValid)
  }
}

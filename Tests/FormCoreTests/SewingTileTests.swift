import XCTest

@testable import FormCore

final class SewingTileTests: XCTestCase {
  func testA4LetterAndLandscapeHaveRealUnscaledContentDimensions() throws {
    let a = try SewingTilePlan(sourceSize: .init(320, 548))
    XCTAssertEqual(a.options.sheetSize, .init(210, 297))
    XCTAssertEqual(a.options.contentSize, .init(184, 259))
    XCTAssertEqual(a.columns, 2)
    XCTAssertEqual(a.rows, 3)
    XCTAssertEqual(a.pageCount, 7)
    let letter = try SewingTilePlan(
      sourceSize: .init(320, 548), options: .init(sheetSize: SewingTileOptions.letter))
    XCTAssertEqual(letter.options.sheetSize.x * 72 / 25.4, 612, accuracy: 1e-9)
    XCTAssertEqual(letter.options.sheetSize.y * 72 / 25.4, 792, accuracy: 1e-9)
    let landscape = try SewingTilePlan(
      sourceSize: .init(320, 548), options: .init(sheetSize: .init(297, 210)))
    XCTAssertEqual(landscape.options.contentSize, .init(271, 172))
    XCTAssertEqual(landscape.columns, 2)
    XCTAssertEqual(landscape.rows, 4)
  }
  func testFirstLastRowsColumnsAndOverlapCoverTheWholeAuthoritativePageWithoutGaps() throws {
    let p = try SewingTilePlan(
      sourceSize: .init(516.7, 881.3),
      options: .init(margins: .init(top: 12, right: 8, bottom: 9, left: 15), overlap: 13))
    XCTAssertEqual(p.tiles.first!.sourceRect.x, 0)
    XCTAssertEqual(p.tiles.first!.sourceRect.y, 0)
    XCTAssertEqual(p.tiles.last!.sourceRect.maxX, p.sourceSize.x, accuracy: 1e-9)
    XCTAssertEqual(p.tiles.last!.sourceRect.maxY, p.sourceSize.y, accuracy: 1e-9)
    var area = 0.0
    for tile in p.tiles {
      area += tile.trimSourceRect.width * tile.trimSourceRect.height
      XCTAssertEqual(tile.contentOnSheet.x, 18)
      XCTAssertEqual(tile.contentOnSheet.y, 15)
      XCTAssertGreaterThanOrEqual(tile.trimSourceRect.x, tile.sourceRect.x)
      XCTAssertLessThanOrEqual(tile.trimSourceRect.maxX, tile.sourceRect.maxX + 1e-9)
      if tile.column + 1 < p.columns {
        let next = p.tiles.first { $0.row == tile.row && $0.column == tile.column + 1 }!
        XCTAssertEqual(tile.sourceRect.maxX - next.sourceRect.x, 13, accuracy: 1e-9)
        XCTAssertEqual(tile.trimSourceRect.maxX, next.trimSourceRect.x, accuracy: 1e-9)
      }
      if tile.row + 1 < p.rows {
        let next = p.tiles.first { $0.row == tile.row + 1 && $0.column == tile.column }!
        XCTAssertEqual(tile.sourceRect.maxY - next.sourceRect.y, 13, accuracy: 1e-9)
        XCTAssertEqual(tile.trimSourceRect.maxY, next.trimSourceRect.y, accuracy: 1e-9)
      }
    }
    XCTAssertEqual(area, p.sourceSize.x * p.sourceSize.y, accuracy: 1e-7)
  }
  func testExactBoundariesSmallPagesAndZeroOverlapDoNotCropOrInventBlankTiles() throws {
    let size = SewingTileOptions().contentSize
    for (source, count) in [
      (Point2(40, 60), 1), (size, 1), (.init(size.x * 2 - 10, size.y * 2 - 10), 4), (.init(size.x * 2 - 9.999, size.y * 2 - 9.999), 9),
    ] {
      let p = try SewingTilePlan(sourceSize: source)
      XCTAssertEqual(p.tiles.count, count)
      XCTAssertEqual(p.tiles.last!.trimSourceRect.maxX, source.x, accuracy: 1e-9)
      XCTAssertEqual(p.tiles.last!.trimSourceRect.maxY, source.y, accuracy: 1e-9)
    }
    let zero = try SewingTilePlan(sourceSize: .init(size.x * 2, size.y * 2), options: .init(overlap: 0))
    XCTAssertEqual(zero.tiles.count, 4)
    XCTAssertEqual(zero.tiles[0].sourceRect.maxX, zero.tiles[1].sourceRect.x)
  }
  func testSheetMarginsFooterAndAllTileTrimRegionsStayInsidePhysicalPaper() throws {
    let o = SewingTileOptions(
      sheetSize: .init(180, 240), margins: .init(top: 5, right: 17, bottom: 8, left: 11), overlap: 7
    )
    let p = try SewingTilePlan(sourceSize: .init(500, 600), options: o)
    for tile in p.tiles {
      XCTAssertGreaterThanOrEqual(tile.trimOnSheet.x, o.margins.left)
      XCTAssertGreaterThanOrEqual(tile.trimOnSheet.y, o.margins.top)
      XCTAssertLessThanOrEqual(tile.trimOnSheet.maxX, o.sheetSize.x - o.margins.right + 1e-9)
      XCTAssertLessThanOrEqual(tile.trimOnSheet.maxY, o.sheetSize.y - o.margins.bottom - 12 + 1e-9)
    }
    XCTAssertEqual(
      p.tiles.map(\.id), (0..<p.rows).flatMap { r in (0..<p.columns).map { "R\(r+1)-C\($0+1)" } })
    XCTAssertEqual(p.tiles.map(\.pdfPage), Array(2...p.pageCount))
    XCTAssertEqual(try SewingTilePlan(sourceSize: p.sourceSize, options: o), p)
  }
  func testRegistrationCrossesAndTrimLocationsHavePhysicalBlankGuttersEvenWithNoMarginsOrOverlap() throws {
    for overlap in [0.0, 10, 40] {
      let options = SewingTileOptions(margins: .init(top: 0, right: 0, bottom: 0, left: 0), overlap: overlap)
      let plan = try SewingTilePlan(sourceSize: .init(410, 640), options: options)
      XCTAssertEqual(options.contentSize, .init(204, 279))
      for tile in plan.tiles {
        let ink = tile.contentOnSheet
        XCTAssertGreaterThanOrEqual(ink.x, 3)
        XCTAssertGreaterThanOrEqual(ink.y, 3)
        XCTAssertLessThanOrEqual(ink.maxX, options.sheetSize.x - 3)
        XCTAssertLessThanOrEqual(ink.maxY, options.sheetSize.y - 3 - 12)
        for join in plan.joins(for: tile) {
          for point in join.sourcePoints {
            let x = ink.x + point.x - tile.sourceRect.x, y = ink.y + point.y - tile.sourceRect.y
            let radius = 1.1 + 0.06
            XCTAssertTrue(x + radius < ink.x || x - radius > ink.maxX || y + radius < ink.y || y - radius > ink.maxY)
            XCTAssertGreaterThanOrEqual(x - radius, 0)
            XCTAssertGreaterThanOrEqual(y - radius, 0)
            XCTAssertLessThanOrEqual(x + radius, options.sheetSize.x)
            XCTAssertLessThanOrEqual(y + radius, options.sheetSize.y - 12)
          }
        }
      }
    }
  }
  func testInvalidNumbersIncompleteOverridesAndExcessPageCountsRejectBeforeAllocation() throws {
    for value in [Double.nan, .infinity, -1, 100001] {
      XCTAssertThrowsError(try SewingTilePlan(sourceSize: .init(value, 100)))
    }
    XCTAssertThrowsError(try SewingTilePlan(sourceSize: .init(100000, 100000)))
    XCTAssertThrowsError(
      try SewingTilePlan(sourceSize: .init(100, 100), options: .init(sheetSize: .init(100, 150))))
    XCTAssertThrowsError(
      try SewingTileOptions.decode([
        "sheetSize": ["x": 210, "y": 297],
        "margins": ["top": 10, "left": 10, "bottom": 10, "right": 10], "overlap": true,
      ]))
    XCTAssertThrowsError(try SewingTileOptions.decode(["overlap": 10]))
    XCTAssertThrowsError(try SewingTileOptions.exportOptions(1, saved: nil))
    XCTAssertEqual(try SewingTileOptions.exportOptions(true, saved: nil), .init())
    XCTAssertNil(try SewingTileOptions.exportOptions(false, saved: nil))
  }
  func testSavedOptionsAreOneAtomicUndoRoundTripAndNeverChangeRenderedGeometry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root: root)
    let engine = OperationEngine(repository: repository)
    var p = Project(name: "Tile options")
    var object = try p.makeObject(recipeID: "artboard", parameters: ["width": 400, "depth": 700])
    object.artwork = try SewingPatternTemplates.roundedPouch().artwork
    p.objects = [object]
    engine.project = p
    let art = object.artwork!
    let signature = try art.renderCacheData()
    let options = SewingTileOptions(sheetSize: SewingTileOptions.letter, overlap: 12)
    _ = try engine.call(
      "form_edit_artwork",
      arguments: [
        "object_id": object.id.uuidString, "command": "pattern_tiles",
        "tile_options": try jsonObject(options),
      ])
    XCTAssertEqual(engine.undoStack.count, 1)
    XCTAssertEqual(engine.project!.minimumSchemaVersion, 40)
    XCTAssertEqual(engine.project!.objects[0].artwork!.elements, art.elements)
    XCTAssertEqual(try engine.project!.objects[0].artwork!.renderCacheData(), signature)
    try engine.flush()
    XCTAssertEqual(try repository.load(p.id).objects, engine.project!.objects)
    let saved = engine.project!
    XCTAssertThrowsError(
      try engine.call(
        "form_edit_artwork",
        arguments: [
          "object_id": object.id.uuidString, "command": "pattern_tiles",
          "tile_options": ["sheetSize": ["x": 1, "y": 2]],
        ]))
    XCTAssertEqual(engine.project, saved)
    XCTAssertEqual(engine.undoStack.count, 1)
    engine.undo()
    XCTAssertEqual(engine.project, p)
    engine.redo()
    XCTAssertEqual(engine.project, saved)
    var cleared = saved
    cleared.objects[0].artwork!.sewingTiles = nil
    XCTAssertNotEqual(
      cleared, saved, "Saved tile options participate in persisted equality and Undo")
    _ = try engine.call(
      "form_edit_artwork",
      arguments: [
        "object_id": object.id.uuidString, "command": "pattern_tiles", "tile_options": NSNull(),
      ])
    XCTAssertNil(engine.project!.objects[0].artwork!.sewingTiles)
  }
}

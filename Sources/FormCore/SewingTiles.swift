import CoreFoundation
import Foundation

public struct SewingTileMargins: Codable, Equatable, Sendable {
  public var top: Double
  public var right: Double
  public var bottom: Double
  public var left: Double
  public init(top: Double = 10, right: Double = 10, bottom: Double = 10, left: Double = 10) {
    self.top = top
    self.right = right
    self.bottom = bottom
    self.left = left
  }
}

/// All dimensions are physical millimeters. No scale factor or printer capability is inferred.
public struct SewingTileOptions: Codable, Equatable, Sendable {
  public var sheetSize: Point2
  public var margins: SewingTileMargins
  public var overlap: Double
  public static let footerHeight = 12.0
  public static let markGutter = 3.0
  public static let maximumPages = 200
  public static let a4 = Point2(210, 297)
  public static let letter = Point2(215.9, 279.4)
  public init(sheetSize: Point2 = a4, margins: SewingTileMargins = .init(), overlap: Double = 10) {
    self.sheetSize = sheetSize
    self.margins = margins
    self.overlap = overlap
  }
  public var contentSize: Point2 {
    .init(
      sheetSize.x - margins.left - margins.right - 2 * Self.markGutter,
      sheetSize.y - margins.top - margins.bottom - Self.footerHeight - 2 * Self.markGutter)
  }
  public func validate() throws {
    guard [sheetSize.x, sheetSize.y].allSatisfy({ $0.isFinite && (100...1000).contains($0) }),
      [margins.top, margins.right, margins.bottom, margins.left].allSatisfy({
        $0.isFinite && (0...50).contains($0)
      }),
      overlap.isFinite, (0...40).contains(overlap)
    else {
      throw FormError.invalid(
        "Choose sheet dimensions of 100–1000 mm, margins of 0–50 mm, and overlap of 0–40 mm.")
    }
    guard contentSize.x >= 100, contentSize.y >= 140 else {
      throw FormError.invalid(
        "The sheet needs at least 100 × 140 mm of design area after margins, 3 mm blank mark gutters, and the 12 mm label footer. Enlarge the sheet or reduce its margins."
      )
    }
  }
  public static func decode(_ value: Any) throws -> Self {
    guard let object = value as? [String: Any],
      Set(object.keys).isSubset(of: ["sheetSize", "margins", "overlap"]),
      let size = object["sheetSize"] as? [String: Any], Set(size.keys) == ["x", "y"],
      let margins = object["margins"] as? [String: Any],
      Set(margins.keys) == ["top", "right", "bottom", "left"]
    else {
      throw FormError.invalid(
        "Provide complete tile options: sheetSize {x,y}, margins {top,right,bottom,left}, and overlap, all in millimeters."
      )
    }
    let result = try JSONDecoder.form.decode(
      Self.self, from: JSONSerialization.data(withJSONObject: object))
    try result.validate()
    return result
  }
  /// true selects saved options or defaults; an object is a one-shot complete override.
  public static func exportOptions(_ value: Any?, saved: Self?) throws -> Self? {
    guard let value else { return nil }
    if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
      return number.boolValue ? (saved ?? .init()) : nil
    }
    return try decode(value)
  }
}

public struct SewingTile: Equatable, Sendable, Identifiable {
  public var id: String { "R\(row + 1)-C\(column + 1)" }
  public let row: Int
  public let column: Int
  public let pdfPage: Int
  /// Top-left global source coordinates, including repeated overlap and the final partial tile.
  public let sourceRect: Rect2
  /// The nonoverlapping region kept when trimming paper and butting neighboring labeled edges.
  public let trimSourceRect: Rect2
  public let contentOnSheet: Rect2
  public let trimOnSheet: Rect2
}

public struct SewingTileJoin: Equatable, Sendable {
  public enum Edge: String, Sendable { case left, right, top, bottom }
  public let edge: Edge
  public let label: String
  /// The source coordinate system extended into blank gutters, not points on the printed source.
  public let sourcePoints: [Point2]
}

public struct SewingTilePlan: Equatable, Sendable {
  public let sourceSize: Point2
  public let options: SewingTileOptions
  public let rows: Int
  public let columns: Int
  public let tiles: [SewingTile]
  public var pageCount: Int { tiles.count + 1 }
  public init(sourceSize: Point2, options: SewingTileOptions = .init()) throws {
    try options.validate()
    guard [sourceSize.x, sourceSize.y].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 100000 }) else {
      throw FormError.invalid(
        "The authoritative pattern page needs finite positive dimensions up to 100 m.")
    }
    let size = options.contentSize
    let step = Point2(size.x - options.overlap, size.y - options.overlap)
    let columnCount = 1 + ceil(max(0, sourceSize.x - size.x) / step.x)
    let rowCount = 1 + ceil(max(0, sourceSize.y - size.y) / step.y)
    guard columnCount * rowCount + 1 <= Double(SewingTileOptions.maximumPages) else {
      throw FormError.invalid(
        "This tiling needs more than 200 pages including its calibration sheet. Choose a larger sheet or reduce margins/overlap; the pattern will never be shrunk."
      )
    }
    let columns = Int(columnCount)
    let rows = Int(rowCount)
    var tiles: [SewingTile] = []
    for row in 0..<rows {
      for column in 0..<columns {
        let x = Double(column) * step.x
        let y = Double(row) * step.y
        let covered = Rect2(x, y, min(size.x, sourceSize.x - x), min(size.y, sourceSize.y - y))
        let left = column == 0 ? 0 : x + options.overlap / 2
        let top = row == 0 ? 0 : y + options.overlap / 2
        let right = column == columns - 1 ? sourceSize.x : x + size.x - options.overlap / 2
        let bottom = row == rows - 1 ? sourceSize.y : y + size.y - options.overlap / 2
        let trim = Rect2(left, top, right - left, bottom - top)
        guard covered.width > 0, covered.height > 0, trim.width > 0, trim.height > 0 else {
          throw FormError.invalid("The requested tile grid contains an empty assembly region.")
        }
        tiles.append(
          .init(
            row: row, column: column, pdfPage: tiles.count + 2, sourceRect: covered,
            trimSourceRect: trim,
            contentOnSheet: .init(
              options.margins.left + SewingTileOptions.markGutter, options.margins.top + SewingTileOptions.markGutter, covered.width, covered.height),
            trimOnSheet: .init(
              options.margins.left + SewingTileOptions.markGutter + left - x, options.margins.top + SewingTileOptions.markGutter + top - y, trim.width,
              trim.height)))
      }
    }
    self.sourceSize = sourceSize
    self.options = options
    self.rows = rows
    self.columns = columns
    self.tiles = tiles
  }
  public func joins(for tile: SewingTile) -> [SewingTileJoin] {
    let r = tile.trimSourceRect
    // Extend the physical source coordinate system into the blank paper gutters.
    // Adjacent columns share these y positions; adjacent rows share these x positions.
    let half = SewingTileOptions.markGutter / 2
    let ys = [tile.sourceRect.y - half, tile.sourceRect.maxY + half]
    let xs = [tile.sourceRect.x - half, tile.sourceRect.maxX + half]
    var result: [SewingTileJoin] = []
    if tile.column > 0 {
      result.append(
        .init(
          edge: .left, label: "R\(tile.row+1):C\(tile.column)|C\(tile.column+1)",
          sourcePoints: ys.map { .init(r.x, $0) }))
    }
    if tile.column + 1 < columns {
      result.append(
        .init(
          edge: .right, label: "R\(tile.row+1):C\(tile.column+1)|C\(tile.column+2)",
          sourcePoints: ys.map { .init(r.maxX, $0) }))
    }
    if tile.row > 0 {
      result.append(
        .init(
          edge: .top, label: "C\(tile.column+1):R\(tile.row)|R\(tile.row+1)",
          sourcePoints: xs.map { .init($0, r.y) }))
    }
    if tile.row + 1 < rows {
      result.append(
        .init(
          edge: .bottom, label: "C\(tile.column+1):R\(tile.row+1)|R\(tile.row+2)",
          sourcePoints: xs.map { .init($0, r.maxY) }))
    }
    return result
  }
  public var metadata: [String: Any] {
    func rect(_ r: Rect2) -> [String: Double] {
      ["x": r.x, "y": r.y, "width": r.width, "height": r.height]
    }
    return [
      "units": "mm", "scale": 1, "source_width_mm": sourceSize.x, "source_height_mm": sourceSize.y,
      "sheet_width_mm": options.sheetSize.x, "sheet_height_mm": options.sheetSize.y,
      "overlap_mm": options.overlap,
      "margins_mm": ["top": options.margins.top, "right": options.margins.right,
        "bottom": options.margins.bottom, "left": options.margins.left],
      "design_width_mm": options.contentSize.x, "design_height_mm": options.contentSize.y,
      "footer_mm": SewingTileOptions.footerHeight, "mark_gutter_mm": SewingTileOptions.markGutter,
      "rows": rows, "columns": columns, "tile_count": tiles.count, "page_count": pageCount,
      "calibration_page": 1,
      "calibration_square_mm": 50, "calibration_rule_mm": 100,
      "assembly":
        "Match the row/column labels, cut straight between paired gray gutter ticks, then butt matching trimmed edges and tape. All ticks and crosshairs are outside the source drawing. The overlap is repeated alignment reference, not a scale change.",
      "tiles": tiles.map { tile in
        let marks = joins(for: tile).map { join in
          ["edge": join.edge.rawValue, "label": join.label,
            "points_on_sheet_mm": join.sourcePoints.map { point in
              ["x": tile.contentOnSheet.x + point.x - tile.sourceRect.x,
                "y": tile.contentOnSheet.y + point.y - tile.sourceRect.y]
            }] as [String: Any]
        }
        return [
          "id": tile.id, "row": tile.row + 1, "column": tile.column + 1, "pdf_page": tile.pdfPage,
          "source_mm": rect(tile.sourceRect), "trim_source_mm": rect(tile.trimSourceRect),
          "content_on_sheet_mm": rect(tile.contentOnSheet), "trim_on_sheet_mm": rect(tile.trimOnSheet),
          "registration_marks": marks,
        ] as [String: Any]
      },
    ]
  }
}

public enum SewingTileCommands {
  public static func edit(_ artwork: inout Artwork, arguments: [String: Any]) throws {
    guard let value = arguments["tile_options"] else {
      throw FormError.invalid("Provide tile_options or null to clear saved sheet options.")
    }
    let options = value is NSNull ? nil : try SewingTileOptions.decode(value)
    var candidate = artwork
    candidate.sewingTiles = options
    try validateArtwork(candidate)
    artwork = candidate
  }
}

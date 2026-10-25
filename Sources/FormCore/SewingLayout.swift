import CryptoKit
import Foundation

public struct SewingCutPlacement: Codable, Equatable, Identifiable, Sendable {
  public var elementID: UUID
  /// One physical cut in single-layer stock, two ordinary cuts in folded stock, or one on-fold cut.
  public var copies: [Int]
  public var x: Double
  public var y: Double
  public var rotation: Double
  public var id: UUID { SewingLayoutIdentity.placement(elementID, copies: copies) }
  public init(elementID: UUID, copies: [Int], x: Double, y: Double, rotation: Double = 0) {
    self.elementID = elementID; self.copies = copies; self.x = x; self.y = y; self.rotation = rotation
  }
}

/// A saved layout references editable sewing pieces in its own artwork document. Planning/export
/// never consumes inventory or mutates their contours, allowances, quantities, or material records.
public struct SewingCutLayout: Codable, Equatable, Identifiable, Sendable {
  public enum Surface: String, Codable, CaseIterable, Sendable { case roll, sheet }
  public enum Stock: String, Codable, CaseIterable, Sendable { case singleLayer, foldedPair }
  public enum Grain: String, Codable, CaseIterable, Sendable {
    case directional, bidirectional, unrestricted
    public var title: String {
      switch self {
      case .directional: return "Follow grain direction"
      case .bidirectional: return "Follow grain, either direction"
      case .unrestricted: return "Ignore grain; planner tries quarter turns"
      }
    }
  }
  public var id = UUID()
  public var name = "Cutting layout"
  public var materialID: String
  /// Open, unfolded usable material width. Nil is deliberately unknown, not a guessed preset.
  public var stockWidth: Double?
  public var surface: Surface = .roll
  public var stock: Stock = .singleLayer
  public var grain: Grain = .bidirectional
  public var sheetLength: Double?
  public var maximumLength = 5000.0
  public var margin = 10.0
  public var spacing = 5.0
  public var costPerSquareMeter: Double?
  public var costCurrency: String?
  /// A physical phase shift of the selected material's repeat in global roll/sheet coordinates.
  public var fabricOrigin = Point2()
  /// Nil includes all source pieces using this material; unassigned pieces use the selected stock.
  public var elementIDs: [UUID]?
  public var placements: [SewingCutPlacement] = []
  public init(materialID: String, stockWidth: Double?) { self.materialID = materialID; self.stockWidth = stockWidth }
  private enum CodingKeys: String, CodingKey {
    case id, name, materialID, stockWidth, surface, stock, grain, sheetLength, maximumLength, margin, spacing, costPerSquareMeter, costCurrency, fabricOrigin, elementIDs, placements
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Cutting layout"
    materialID = try c.decode(String.self, forKey: .materialID)
    stockWidth = try c.decodeIfPresent(Double.self, forKey: .stockWidth)
    surface = try c.decodeIfPresent(Surface.self, forKey: .surface) ?? .roll
    stock = try c.decodeIfPresent(Stock.self, forKey: .stock) ?? .singleLayer
    grain = try c.decodeIfPresent(Grain.self, forKey: .grain) ?? .bidirectional
    sheetLength = try c.decodeIfPresent(Double.self, forKey: .sheetLength)
    maximumLength = try c.decodeIfPresent(Double.self, forKey: .maximumLength) ?? 5000
    margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? 10
    spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? 5
    costPerSquareMeter = try c.decodeIfPresent(Double.self, forKey: .costPerSquareMeter)
    costCurrency = try c.decodeIfPresent(String.self, forKey: .costCurrency)
    fabricOrigin = try c.decodeIfPresent(Point2.self, forKey: .fabricOrigin) ?? .init()
    elementIDs = try c.decodeIfPresent([UUID].self, forKey: .elementIDs)
    placements = try c.decodeIfPresent([SewingCutPlacement].self, forKey: .placements) ?? []
  }
  public var workingWidth: Double? { stockWidth.map { stock == .foldedPair ? $0 / 2 : $0 } }
  public var availableLength: Double? { surface == .sheet ? sheetLength : maximumLength }
  public func validateMetadata() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 160,
      !materialID.isEmpty, materialID.count <= 160,
      stockWidth == nil || stockWidth!.isFinite && (50...3000).contains(stockWidth!),
      sheetLength == nil || sheetLength!.isFinite && (50...5000).contains(sheetLength!),
      maximumLength.isFinite, (50...5000).contains(maximumLength),
      margin.isFinite, (0...100).contains(margin), spacing.isFinite, (0.1...500).contains(spacing),
      costPerSquareMeter == nil || costPerSquareMeter!.isFinite && (0...1000000).contains(costPerSquareMeter!),
      costCurrency == nil || costCurrency!.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
      [fabricOrigin.x, fabricOrigin.y].allSatisfy({ $0.isFinite && abs($0) <= 100000 }),
      elementIDs == nil || !elementIDs!.isEmpty && Set(elementIDs!).count == elementIDs!.count,
      placements.count <= SewingLayoutLimits.maximumPlacements,
      Set(placements.map(\.id)).count == placements.count else {
      throw FormError.invalid("Cutting layouts need a named material, an explicit 50–3000 mm usable width, 0–100 mm margins, 0.1–500 mm separation, and at most 200 placements within a 5 m planning length. Unknown stock dimensions may be left empty until planning.")
    }
    for p in placements {
      guard (1...2).contains(p.copies.count), p.copies.allSatisfy({ (1...100).contains($0) }), Set(p.copies).count == p.copies.count,
        [p.x, p.y, p.rotation].allSatisfy(\.isFinite), abs(p.x) <= 100000, abs(p.y) <= 100000, abs(p.rotation) <= 36000 else {
        throw FormError.invalid("Use finite layout positions/rotations and one or two distinct positive cut-copy numbers per placement.")
      }
    }
  }
  public mutating func removeReferences(to ids: Set<UUID>) {
    placements.removeAll { ids.contains($0.elementID) }
    elementIDs?.removeAll { ids.contains($0) }
    if elementIDs?.isEmpty == true { elementIDs = nil }
  }
}

public enum SewingLayoutLimits {
  public static let maximumPlacements = 200
  public static let maximumCandidates = 20000
  public static let maximumSegmentComparisons = 4_000_000
}
public enum SewingLayoutIdentity {
  public static func placement(_ elementID: UUID, copies: [Int]) -> UUID {
    var bytes = Array(SHA256.hash(data: Data((elementID.uuidString + ":" + copies.sorted().map(String.init).joined(separator: ",")).utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
  }
}

public struct SewingLayoutIssue: Equatable, Sendable {
  public enum Kind: String, Sendable { case stock, source, missingCopy, extraCopy, bounds, collision, spacing, grain, fold, budget }
  public var kind: Kind
  public var message: String
  public var placements: [UUID]
  public init(_ kind: Kind, _ message: String, placements: [UUID] = []) { self.kind = kind; self.message = message; self.placements = placements }
}
public struct SewingLayoutResolvedPlacement: Equatable, Sendable {
  public var placement: SewingCutPlacement
  public var geometry: SewingPieceGeometry
  public var transform: Affine2
  public var contour: [Point2]
  public var bounds: Rect2
  public var grainDirection: Point2
}
public struct SewingLayoutPreflight: Sendable {
  public var issues: [SewingLayoutIssue]
  public var placements: [SewingLayoutResolvedPlacement]
  public var workingWidth: Double
  public var requiredLength: Double
  public var consumedLength: Double
  public var allocatedAreaMM2: Double
  public var cutAreaMM2: Double
  public var estimatedCost: Double?
  public var excludedPieceIDs: [UUID]
  public var candidateChecks = 0
  public var isValid: Bool { issues.isEmpty }
  public var wasteAreaMM2: Double { max(0, allocatedAreaMM2 - cutAreaMM2) }
  public var wasteFraction: Double { allocatedAreaMM2 > 0 ? wasteAreaMM2 / allocatedAreaMM2 : 0 }
}

extension SewingLayoutPreflight {
  public func metadata(layout: SewingCutLayout) -> [String: Any] {
    ["valid": isValid, "units": "mm", "working_width_mm": workingWidth,
      "open_stock_width_mm": layout.stockWidth.map { $0 as Any } ?? NSNull(),
      "required_length_mm": requiredLength, "consumed_length_mm": consumedLength,
      "allocated_area_mm2": allocatedAreaMM2, "cut_area_mm2": cutAreaMM2,
      "waste_area_mm2": wasteAreaMM2, "waste_fraction": wasteFraction,
      "estimated_cost": estimatedCost.map { $0 as Any } ?? NSNull(),
      "cost_rate_per_m2": layout.costPerSquareMeter.map { $0 as Any } ?? NSNull(),
      "cost_currency": layout.costCurrency.map { $0 as Any } ?? NSNull(),
      "cost_basis": "Declared rate times full open usable stock area; no inventory deduction.",
      "surface": layout.surface.rawValue, "stock_layers": layout.stock == .foldedPair ? 2 : 1,
      "fabric_origin_mm": ["x": layout.fabricOrigin.x, "y": layout.fabricOrigin.y],
      "fabric_preview_ply": layout.stock == .foldedPair ? "Upper/right half of the open stock" : "Single layer",
      "seam_pattern_continuity_verified": false, "inventory_deducted": false,
      "planner": "Deterministic bounded bottom-left candidate search; not optimal nesting",
      "candidate_checks": candidateChecks,
      "excluded_piece_ids": excludedPieceIDs.map(\.uuidString),
      "issues": issues.map { ["kind": $0.kind.rawValue, "message": $0.message, "placement_ids": $0.placements.map(\.uuidString)] as [String: Any] },
      "placements": placements.map { p in
        ["id": p.placement.id.uuidString, "element_id": p.placement.elementID.uuidString,
          "copies": p.placement.copies, "name": p.geometry.piece.name,
          "bounds_mm": ["x": p.bounds.x, "y": p.bounds.y, "width": p.bounds.width, "height": p.bounds.height],
          "grain_direction": [p.grainDirection.x, p.grainDirection.y]] as [String: Any]
      }] as [String: Any]
  }
}

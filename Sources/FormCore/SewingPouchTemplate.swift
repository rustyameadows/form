import CoreFoundation
import Foundation

extension SewingPatternTemplates {
  /// Original unlined rounded pouch study. Dimensions describe the stitch outline, not fitted capacity.
  /// Emits editable source Beziers and explicit construction notes; never replaces an existing source.
  public static func roundedPouch(_ parameters: [String: Any] = [:]) throws -> SewingPatternTemplate
  {
    func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) throws -> Double {
      guard let raw = parameters[key] else { return fallback }
      guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
        n.doubleValue.isFinite, range.contains(n.doubleValue)
      else { throw FormError.invalid("Use \(range.lowerBound)–\(range.upperBound) mm for \(key).") }
      return n.doubleValue
    }
    let w = try number("width", 260, 100...600)
    let h = try number("height", 180, 80...500)
    let r = try number("corner_radius", 35, 5...150)
    let a = try number("seam_allowance", 10, 2...25)
    let facing = try number("facing_height", 40, 25...80)
    let material = parameters["material_id"] as? String ?? "flight-nylon"
    guard r < min(w / 2, h - 20) else {
      throw FormError.invalid(
        "The corner radius must be smaller than half the width and leave at least20 mm of straight side."
      )
    }
    let k = 0.5522847498307936
    let nodes = [
      BezierNode(.init(0, 0)), BezierNode(.init(w, 0)),
      BezierNode(.init(w, h - r), outgoing: .init(w, h - r + k * r)),
      BezierNode(.init(w - r, h), incoming: .init(w - r + k * r, h)),
      BezierNode(.init(r, h), outgoing: .init(r - k * r, h)),
      BezierNode(.init(0, h - r), incoming: .init(0, h - r + k * r)),
    ]
    // Identical source edge UUIDs remain stable for the life of this editable template instance.
    var boundary = VectorContour(nodes)
    boundary.id = UUID()
    var panel = ArtworkElement(
      kind: "path", x: 35 + a, y: 60 + a, width: w, height: h, color: "#43718A")
    panel.name = "Rounded pouch / main panel"
    panel.path = .init(width: w, height: h, contours: [boundary])
    var piece = SewingPatternPiece(name: "Rounded pouch main panel")
    piece.materialID = material
    piece.cutQuantity = 2
    piece.seamAllowance = a
    piece.notes =
      "Original unlined pouch study: initial stitch outline \(w) × \(h) mm; initial lower radius \(r) mm. Cut2. Baste the zipper between each main-panel top and facing. Open zipper partway before sewing matching side/curve/bottom seams. Clip curved allowances carefully, turn through zipper, press. Sew a fabric test first; capacity, zipper fit, and construction are not calibrated."
    piece.notches = [1, 5].map { i in
      var n = SewingNotch(edge: i, position: 0.5)
      n.edgeID = nodes[i].id
      n.endID = nodes[(i + 1) % nodes.count].id
      n.depth = min(3, a / 2)
      return n
    }
    panel.sewingPiece = piece
    panel.fillEnabled = false
    panel.stroke = .init(color: "#43718A", width: 0.3)
    panel.productionRole = "stitch"
    var strip = ArtworkElement(
      kind: "rectangle", x: 35 + a, y: panel.y + h + 60, width: w, height: facing, color: "#43718A")
    strip.name = "Rounded pouch / zipper facing"
    var facingPiece = SewingPatternPiece(name: "Zipper facing")
    facingPiece.seamAllowance = a
    facingPiece.cutQuantity = 2
    facingPiece.materialID = material
    facingPiece.notes =
      "Cut2. Match the full-length top edge to the main-panel zipper edge, one facing per side. Finish the free long edge. Choose zipper/tape for the actual cut opening and confirm a fabric test; no zipper hardware or fit is inferred."
    strip.sewingPiece = facingPiece
    strip.fillEnabled = false
    strip.stroke = .init(color: "#43718A", width: 0.3)
    strip.productionRole = "stitch"
    var art = Artwork(background: "#FFFFFF", elements: [panel, strip], bleed: 0)
    art.sewingSeams = (1...5).map { edge in
      var first = SewingSeamEnd(elementID: panel.id, edge: edge, copy: 1)
      first.edgeID = nodes[edge].id
      first.endID = nodes[(edge + 1) % nodes.count].id
      var second = SewingSeamEnd(elementID: panel.id, edge: edge, copy: 2)
      second.edgeID = nodes[edge].id
      second.endID = nodes[(edge + 1) % nodes.count].id
      var seam = SewingSeam(
        name: edge == 2 || edge == 4 ? "Lower curved seam \(edge)" : "Panel perimeter \(edge)",
        first: first, second: second)
      seam.tolerance = 0.5
      return seam
    }
    for copy in 1...2 {
      var end = SewingSeamEnd(elementID: panel.id, edge: 0, copy: copy)
      end.edgeID = nodes[0].id
      end.endID = nodes[1].id
      art.sewingSeams!.append(
        .init(
          name: "Zipper facing \(copy)", first: end,
          second: .init(elementID: strip.id, edge: 0, copy: copy)))
    }
    try validateArtwork(art)
    return .init(artwork: art, frameSize: .init(w + 2 * a + 70, strip.y + facing + a + 60))
  }
}

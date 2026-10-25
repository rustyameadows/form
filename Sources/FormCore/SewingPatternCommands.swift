import CoreFoundation
import Foundation

public enum SewingPatternCommands {
  public static let names = ["pattern_piece", "seam_pair", "pattern_template"]
  public static func edit(_ command: String, artwork: inout Artwork, ids: Set<UUID>, arguments: [String: Any]) throws -> Set<UUID> {
    var next = artwork
    switch command {
    case "pattern_piece":
      guard !ids.isEmpty, let raw = arguments["piece"] else { throw FormError.invalid("Select a shape and provide piece metadata, or null to remove it.") }
      let roots = artwork.selectionRoots(ids)
      for root in roots {
        guard let index = next.elements.firstIndex(where: { $0.id == root.id }), !artwork.isLocked(root) else { throw FormError.invalid("Unlock the pattern piece first.") }
        if raw is NSNull {
          next.elements[index].sewingPiece = nil
          next.removeSewingLayoutReferences(to: [root.id])
          next.sewingSeams?.removeAll { $0.first.elementID == root.id || $0.second.elementID == root.id }
        } else {
          guard var value = raw as? [String: Any] else { throw FormError.invalid("piece must be an object or null.") }
          if value["name"] == nil { value["name"] = root.name ?? "Pattern piece" }
          if SewingPatterns.needsGeneralGeometry(next.elements[index]), var path=next.elements[index].path {
            for i in path.contours.indices where path.contours[i].id==nil {path.contours[i].id=UUID()}
            next.elements[index].path=path
          }
          let piece = try JSONDecoder.form.decode(SewingPatternPiece.self, from: JSONSerialization.data(withJSONObject: value))
          next.elements[index].sewingPiece = try SewingPatterns.bindingStableEdges(piece,to:next.elements[index])
          next.elements[index].fillEnabled = false
          next.elements[index].stroke = .init(color: "#43718A", width: 0.3)
          next.elements[index].productionRole = "stitch"
          _ = try SewingPatterns.geometry(next.elements[index], in: next)
        }
      }
    case "seam_pair":
      guard let raw = arguments["seam"] else { throw FormError.invalid("Provide seam metadata, or null with seam_id to remove a pair.") }
      if raw is NSNull {
        guard let key = arguments["seam_id"] as? String, let id = UUID(uuidString: key), next.sewingSeams?.contains(where: { $0.id == id }) == true else { throw FormError.invalid("Choose an existing seam_id.") }
        next.sewingSeams?.removeAll { $0.id == id }
      } else {
        guard let value = raw as? [String: Any] else { throw FormError.invalid("seam must be an object or null.") }
        var seam = try JSONDecoder.form.decode(SewingSeam.self, from: JSONSerialization.data(withJSONObject: value))
        for end in [seam.first, seam.second] {
          guard let e = artwork.elements.first(where: { $0.id == end.elementID }), !artwork.isLocked(e) else { throw FormError.invalid("Choose unlocked pattern pieces for this seam.") }
        }
        func bind(_ end:SewingSeamEnd)throws->SewingSeamEnd {
          var value=end
          if let e=next.elements.first(where:{$0.id==end.elementID}),SewingPatterns.needsGeneralGeometry(e),value.endID==nil {
            let g=try SewingPatterns.geometry(e,in:next)
            let index=try g.edgeIndex(value.edge,id:value.edgeID)
            value.edgeID=g.sourceEdges[index].id;value.endID=g.sourceEdges[index].endID
          };return value
        }
        seam.first=try bind(seam.first);seam.second=try bind(seam.second)
        var seams = next.sewingSeams ?? []
        if let index = seams.firstIndex(where: { $0.id == seam.id }) { seams[index] = seam } else { seams.append(seam) }
        next.sewingSeams = seams
      }
    case "pattern_template":
      let parameters=arguments["pattern_parameters"] as? [String:Any] ?? [:]
      let template:SewingPatternTemplate
      switch arguments["template"] as? String {
      case "tote":template=try SewingPatternTemplates.tote(parameters)
      case "roundedPouch":template=try SewingPatternTemplates.roundedPouch(parameters)
      default:throw FormError.invalid("Choose the tote or roundedPouch editable pattern template.")
      }
      next.elements += template.artwork.elements
      next.sewingSeams = (next.sewingSeams ?? []) + (template.artwork.sewingSeams ?? [])
      try validateArtwork(next); artwork = next; return Set(template.artwork.elements.map(\.id))
    default: throw FormError.invalid("Unknown sewing pattern command.")
    }
    if next.sewingSeams?.isEmpty == true { next.sewingSeams = nil }
    try validateArtwork(next); artwork = next; return ids
  }
}

public struct SewingPatternTemplate: Sendable {
  public var artwork: Artwork
  public var frameSize: Point2
}
public enum SewingPatternTemplates {
  /// An unlined flat tote: two body panels and two four-fold handle strips, with declared hems.
  public static func tote(_ parameters: [String: Any] = [:]) throws -> SewingPatternTemplate {
    func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) throws -> Double {
      guard let raw = parameters[key] else { return fallback }
      guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
        range.contains(value.doubleValue) else { throw FormError.invalid("Use \(range.lowerBound)–\(range.upperBound) mm for \(key).") }
      return value.doubleValue
    }
    let width = try number("width", 340, 100...1000), height = try number("height", 380, 100...1200)
    let handleLength = try number("handle_length", 600, 200...1500), handleWidth = try number("handle_width", 30, 15...80)
    let allowance = try number("seam_allowance", 10, 1...30), hem = try number("top_hem", 30, 10...80)
    let material = parameters["material_id"] as? String ?? "flight-nylon"
    var body = ArtworkElement(kind: "rectangle", x: 35 + allowance, y: 60 + hem, width: width, height: height, color: "#43718A")
    body.name = "Tote / body panel"
    var piece = SewingPatternPiece(name: "Body panel"); piece.seamAllowance = allowance
    piece.edgeAllowances[0] = hem; piece.materialID = material; piece.cutQuantity = 2
    piece.notes = "Unlined flat tote. Cut two. Turn the top hem in two equal folds. Match the side and bottom seams before attaching handles."
    piece.notches = [SewingNotch(edge: 1, position: 0.5), SewingNotch(edge: 3, position: 0.5)]
    if allowance <= 3 { piece.notches = [] }
    body.sewingPiece = piece; body.fillEnabled = false; body.productionRole = "stitch"; body.stroke = .init(color: "#43718A", width: 0.3)
    var handle = ArtworkElement(kind: "rectangle", x: width + allowance * 2 + 110, y: 80, width: handleWidth * 4, height: handleLength, color: "#43718A")
    handle.name = "Tote / four-fold handle"
    var strap = SewingPatternPiece(name: "Handle strip"); strap.seamAllowance = 0
    strap.edgeAllowances = [0: 20, 2: 20]; strap.materialID = material; strap.cutQuantity = 2
    strap.notes = "Cut two strips. Fold long edges to the center, then fold in half for a \(handleWidth) mm handle. The short ends include 20 mm attachment overlap."
    handle.sewingPiece = strap; handle.fillEnabled = false; handle.productionRole = "stitch"; handle.stroke = .init(color: "#43718A", width: 0.3)
    var art = Artwork(background: "#FFFFFF", elements: [body, handle], bleed: 0)
    art.sewingSeams = [1, 2, 3].map { edge in
      SewingSeam(name: edge == 2 ? "Body bottom" : "Body side \(edge == 1 ? "right" : "left")",
        first: .init(elementID: body.id, edge: edge, copy: 1), second: .init(elementID: body.id, edge: edge, copy: 2))
    }
    try validateArtwork(art)
    return .init(artwork: art, frameSize: .init(handle.x + handle.width + 40, max(body.y + body.height + allowance, handle.y + handle.height + 20) + 50))
  }
}

extension Artwork {
  public mutating func removeSewingSeams(involving ids: Set<UUID>) {
    sewingSeams?.removeAll { ids.contains($0.first.elementID) || ids.contains($0.second.elementID) }
    if sewingSeams?.isEmpty == true { sewingSeams = nil }
  }
  public mutating func duplicateSewingSeams(from original: Artwork, mapping: [UUID: UUID]) {
    for var seam in original.sewingSeams ?? [] {
      guard let first = mapping[seam.first.elementID], let second = mapping[seam.second.elementID] else { continue }
      seam.id = UUID()
      seam.first=remappingSewingEnd(seam.first,to:first,from:original)
      seam.second=remappingSewingEnd(seam.second,to:second,from:original)
      sewingSeams = (sewingSeams ?? []) + [seam]
    }
  }
  public func remappingSewingEnd(_ original:SewingSeamEnd,to target:UUID,from source:Artwork)->SewingSeamEnd {
    var result=original;result.elementID=target
    let old=source.elements.first{$0.id==original.elementID}?.path?.contours.flatMap(\.nodes) ?? []
    let new=elements.first{$0.id==target}?.path?.contours.flatMap(\.nodes) ?? []
    let mapping=Dictionary(uniqueKeysWithValues:zip(old,new).map{($0.id,$1.id)})
    result.edgeID=original.edgeID.flatMap{mapping[$0] ?? $0};result.endID=original.endID.flatMap{mapping[$0] ?? $0}
    return result
  }
  public mutating func retainRepresentedSewingSeams() {
    let pieces = Set(elements.filter { $0.sewingPiece != nil }.map(\.id))
    sewingSeams?.removeAll { !pieces.contains($0.first.elementID) || !pieces.contains($0.second.elementID) }
    if sewingSeams?.isEmpty == true { sewingSeams = nil }
  }
}

import CryptoKit
import Foundation

public struct SewingPatternPlan: Sendable {
  public var artwork: Artwork
  public var frameSize: Point2
  public var pieces: [SewingPieceGeometry]
  public var seams: [SewingSeamDiagnostic]
}

/// Derived technical geometry is rebuilt from the current editable contours; never persist it over
/// the source. Cut contours include real V notches, and a cut-on-fold edge is omitted from cutting.
public enum SewingPatternDrawing {
  public enum Coordinates: Sendable {
    case sheet, source
  }
  /// The complete physical material footprint. A fold boundary is included here for area and
  /// collision checks even though that boundary is omitted from the actual cutting pass.
  public static func cutContour(_ geometry: SewingPieceGeometry) -> [Point2] {
    if geometry.usesGeneralGeometry { return geometry.cut }
    return geometry.cut.indices.flatMap { Array(cutEdge(geometry, $0).dropLast()) }
  }
  public static func cutEdgePoints(_ geometry: SewingPieceGeometry, edge: Int) -> [Point2] { cutEdge(geometry, edge) }
  public static func grainline(_ geometry: SewingPieceGeometry) -> [Point2] { grain(geometry) }
  public static func technicalPath(_ points: [Point2], closed: Bool, source: UUID, name: String, role: String,
    color: String, dash: [Double]? = nil) -> ArtworkElement {
    line(points, closed: closed, source: source, tag: name, role: role, color: color, dash: dash)
  }
  public static func annotation(_ value: String, x: Double, y: Double, width: Double, height: Double,
    source: UUID, name: String, color: String = "#344D5D") -> ArtworkElement {
    text(value, x: x, y: y, width: width, height: height, source: source, tag: name, color: color)
  }
  private static func id(_ source: UUID, _ tag: String) -> UUID {
    var bytes = Array(SHA256.hash(data: Data((source.uuidString + tag).utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
  }
  private static func line(_ points: [Point2], closed: Bool, source: UUID, tag: String, role: String, color: String, dash: [Double]? = nil) -> ArtworkElement {
    let x = points.map(\.x).min()!, y = points.map(\.y).min()!
    let width = max(0.1, points.map(\.x).max()! - x), height = max(0.1, points.map(\.y).max()! - y)
    var e = ArtworkElement(kind: "path", x: x, y: y, width: width, height: height, color: color)
    e.id = id(source, tag); e.name = tag; e.fillEnabled = false; e.productionRole = role
    e.stroke = .init(color: color, width: 0.25); e.stroke?.dash = dash
    let nodes = points.enumerated().map { index, p -> BezierNode in
      var node = BezierNode(.init(p.x - x, p.y - y)); node.id = id(source, tag + "-node-\(index)"); return node
    }
    e.path = .init(width: width, height: height, contours: [.init(nodes, closed: closed)])
    return e
  }
  private static func text(_ value: String, x: Double, y: Double, width: Double, height: Double,
    source: UUID, tag: String, color: String = "#344D5D") -> ArtworkElement {
    var e = ArtworkElement(kind: "text", x: x, y: y, width: width, height: height, text: value, color: color, fontSize: 9)
    e.id = id(source, tag); e.name = tag; e.productionRole = "guide"; return e
  }
  private static func visible(_ e: ArtworkElement, in art: Artwork) -> Bool {
    var current: ArtworkElement? = e, seen = Set<UUID>()
    while let element = current, seen.insert(element.id).inserted {
      if element.hidden == true { return false }
      current = element.parentID.flatMap { id in art.elements.first { $0.id == id } }
    }
    return true
  }
  private static func cutEdge(_ g: SewingPieceGeometry, _ edge: Int) -> [Point2] {
    let start = g.cut[edge], end = g.cut[(edge + 1) % g.cut.count]
    let a = g.stitch[edge], b = g.stitch[(edge + 1) % g.stitch.count], length = g.edgeLengths[edge]
    let direction = Point2((b.x - a.x) / length, (b.y - a.y) / length), normal = g.normals[edge]
    let allowance = g.piece.allowance(for: edge)
    var result = [start]
    for notch in g.piece.notches.filter({ $0.edge == edge }).sorted(by: { $0.position < $1.position }) {
      let center = Point2(a.x + direction.x * length * notch.position + normal.x * allowance,
        a.y + direction.y * length * notch.position + normal.y * allowance)
      result += [.init(center.x - direction.x * notch.width / 2, center.y - direction.y * notch.width / 2),
        .init(center.x - normal.x * notch.depth, center.y - normal.y * notch.depth),
        .init(center.x + direction.x * notch.width / 2, center.y + direction.y * notch.width / 2)]
    }
    return result + [end]
  }
  private static func grain(_ g: SewingPieceGeometry) -> [Point2] { generalGrain(g) }
  public static func plan(_ source: Artwork, selection: Set<UUID> = [], coordinates: Coordinates = .sheet) throws -> SewingPatternPlan {
    try validateArtwork(source)
    let chosen = selection.isEmpty ? Set(source.elements.map(\.id)) : source.descendants(of: Set(source.selectionRoots(selection).map(\.id)))
    let pieces = try source.elements.filter { $0.sewingPiece != nil && chosen.contains($0.id) && visible($0, in: source) }.map { try SewingPatterns.geometry($0, in: source) }
    guard !pieces.isEmpty else { throw FormError.invalid("Select annotated sewing pattern pieces, or annotate a supported closed contour first.") }
    let diagnostics = try SewingPatterns.diagnostics(source), pieceIDs = Set(pieces.map(\.elementID))
    let seams = diagnostics.filter { pieceIDs.contains($0.seam.first.elementID) || pieceIDs.contains($0.seam.second.elementID) }
    var elements: [ArtworkElement] = []
    for g in pieces {
      if g.usesGeneralGeometry {
        for (i,path) in cuttingContours(g).enumerated() {
          elements.append(line(path.points,closed:path.closed,source:g.elementID,tag:"Cut contour \(i+1)",role:"cut",color:"#292D2C"))
        }
        for (i,contour) in g.allStitchContours.enumerated() {
          elements.append(line(contour,closed:true,source:g.elementID,tag:"Stitch contour \(i+1)",role:"stitch",color:"#43718A",dash:[3,2]))
        }
        if let fold=g.piece.onFoldEdge,let edge=g.sourceEdges.first(where:{$0.index==fold}) {
          elements.append(line(edge.points,closed:false,source:g.elementID,tag:"Place on fold",role:"guide",color:"#A67B41",dash:[6,2]))
        }
        for edge in g.sourceEdges {
          let sample=edge.sample(fraction:0.5),n=g.normals[edge.index]
          elements.append(text("E\(edge.index+1)",x:sample.point.x-n.x*7-4,y:sample.point.y-n.y*7-2,width:9,height:5,source:g.elementID,tag:"Source edge label \(edge.index+1)"))
        }
      } else {
      if let fold = g.piece.onFoldEdge {
        for edge in g.cut.indices where edge != fold {
          elements.append(line(cutEdge(g, edge), closed: false, source: g.elementID, tag: "Cut edge \(edge + 1)", role: "cut", color: "#292D2C"))
        }
        elements.append(line([g.stitch[fold], g.stitch[(fold + 1) % g.stitch.count]], closed: false,
          source: g.elementID, tag: "Place on fold", role: "guide", color: "#A67B41", dash: [6, 2]))
      } else {
        let outline = cutContour(g)
        elements.append(line(outline, closed: true, source: g.elementID, tag: "Cut contour", role: "cut", color: "#292D2C"))
      }
      if g.piece.unstitchedEdges?.isEmpty == false {
        for edge in g.stitch.indices {
          let ref = g.sourceEdges.first { $0.index == edge }
          if !g.piece.isUnstitched(edge:edge,edgeID:ref?.id,endID:ref?.endID) {
            elements.append(line([g.stitch[edge],g.stitch[(edge+1)%g.stitch.count]],closed:false,
              source:g.elementID,tag:"Stitch edge \(edge+1)",role:"stitch",color:"#43718A",dash:[3,2]))
          }
        }
      } else {
        elements.append(line(g.stitch, closed: true, source: g.elementID, tag: "Stitch outline", role: "stitch", color: "#43718A", dash: [3, 2]))
      }
      for edge in g.stitch.indices {
        let sourceEdge=g.sourceEdges.first{$0.index==edge}
        if g.piece.isUnstitched(edge:edge,edgeID:sourceEdge?.id,endID:sourceEdge?.endID) {continue}
        let a = g.stitch[edge], b = g.stitch[(edge + 1) % g.stitch.count], n = g.normals[edge]
        elements.append(text("E\(edge + 1)", x: (a.x + b.x) / 2 - n.x * 7 - 4, y: (a.y + b.y) / 2 - n.y * 7 - 2,
          width: 9, height: 5, source: g.elementID, tag: "Edge label \(edge + 1)"))
      }
      }
      for guide in try SewingConstructionGuides.resolve(g) {
        let guideSource=id(g.elementID,"construction-"+guide.guide.id.uuidString)
        let stitching = guide.guide.kind == .stitch
        for (index,points) in guide.segments.enumerated() {
          elements.append(line(points,closed:false,source:guideSource,tag:"Construction guide \(index+1)",
            role:stitching ? "stitch":"guide",color:stitching ? "#43718A":"#A67B41",dash:stitching ? [2,1]:[6,2]))
        }
        let middle=Point2((guide.first.x+guide.last.x)/2,(guide.first.y+guide.last.y)/2)
        let opening=guide.opening == nil ? "":String(format:" · leave %.1f mm opening",guide.guide.opening)
        elements.append(text(guide.guide.label+opening,x:middle.x-70,y:middle.y-6,width:140,height:6,
          source:guideSource,tag:"Construction guide label",color:stitching ? "#43718A":"#A67B41"))
      }
      let grain = grain(g), d = g.grainDirection, n = Point2(-d.y, d.x)
      elements.append(line(grain, closed: false, source: g.elementID, tag: "Grainline", role: "guide", color: "#A67B41"))
      for (index, tip) in grain.enumerated() {
        let sign = index == 0 ? 1.0 : -1.0
        let back = Point2(tip.x + sign * d.x * 4, tip.y + sign * d.y * 4)
        elements.append(line([.init(back.x + n.x * 2, back.y + n.y * 2), tip, .init(back.x - n.x * 2, back.y - n.y * 2)],
          closed: false, source: g.elementID, tag: "Grain arrow \(index + 1)", role: "guide", color: "#A67B41"))
      }
      elements.append(text("\(g.piece.name)  /  CUT \(g.piece.cutQuantity)\(g.piece.onFoldEdge == nil ? "" : " ON FOLD")",
        x: g.bounds.x, y: g.bounds.y - 10, width: max(100, g.bounds.width), height: 7, source: g.elementID, tag: "Piece label"))
      let material = g.piece.materialID.map { "Material: " + $0 + " · " } ?? ""
      elements.append(text(material + String(format: "Cut extent %.1f × %.1f mm", g.bounds.width, g.bounds.height),
        x: g.bounds.x, y: g.bounds.maxY + 3, width: max(130, g.bounds.width), height: 7, source: g.elementID, tag: "Physical piece dimensions"))
      if let notes = g.piece.notes, !notes.isEmpty {
        elements.append(text(notes, x: g.bounds.x, y: g.bounds.maxY + 12, width: max(130, g.bounds.width), height: 28, source: g.elementID, tag: "Construction notes"))
      }
    }
    var art = Artwork(background: "#FFFFFF", elements: elements, bleed: 0); art.unit = .mm
    let bounds = elements.dropFirst().reduce(art.bounds(of: elements[0])) { $0.union(art.bounds(of: $1)) }
    if case .source = coordinates {
      // Canvas uses the same technical paths in their original physical frame.
      // Calibration, seam schedules and page translation belong to sheet output.
      art.backgroundOpacity = 0
      try validateArtwork(art)
      return .init(artwork: art, frameSize: .init(bounds.width, bounds.height), pieces: pieces, seams: seams)
    }
    let calibrationID = pieces[0].elementID, x = bounds.x, y = bounds.maxY + 20
    art.elements.append(line([.init(x,y),.init(x+50,y),.init(x+50,y+50),.init(x,y+50)], closed: true,
      source: calibrationID, tag: "50 mm calibration square", role: "guide", color: "#344D5D"))
    art.elements.append(text("50 × 50 mm\nPrint at 100% / actual size", x: x + 60, y: y + 12, width: 130, height: 18, source: calibrationID, tag: "Print calibration instructions"))
    let mismatches = seams.filter { !$0.matches }
    if !mismatches.isEmpty {
      let message = mismatches.map { !$0.isConclusive ? String(format:"%@: measurement uncertain ±%.4f mm",$0.seam.name,$0.measurementError) : String(format: "%@: %.1f mm mismatch", $0.seam.name, $0.difference) }.joined(separator: " · ")
      art.elements.append(text("SEAM CHECK: " + message, x: x, y: y + 58, width: max(250, bounds.width), height: 20,
        source: calibrationID, tag: "Seam mismatch diagnostics", color: "#B64B32"))
    }
    var scheduleY = y + (mismatches.isEmpty ? 60 : 82)
    for check in seams {
      func endpoint(_ end: SewingSeamEnd) -> String {
        let name = source.elements.first { $0.id == end.elementID }?.sewingPiece?.name ?? "Piece"
        return "\(name) / copy \(end.copy) / E\(end.edge + 1)" + (pieceIDs.contains(end.elementID) ? "" : " [outside this sheet]")
      }
      let pair = "\(check.seam.name): \(endpoint(check.seam.first)) ↔ \(endpoint(check.seam.second))"
      let measurements = String(format: "%.1f / %.1f mm · %@ · %@", check.firstLength, check.secondLength,
        !check.isConclusive ? "MEASUREMENT UNCERTAIN" : check.matches ? "match" : "MISMATCH", check.seam.reversed ? "reverse edge direction" : "same edge direction")
      art.elements.append(text(pair + "\n" + measurements, x: x, y: scheduleY, width: max(250, bounds.width), height: 10,
        source: check.seam.id, tag: "Seam schedule", color: check.matches ? "#344D5D" : "#B64B32"))
      scheduleY += 13
    }
    let complete = art.elements.dropFirst().reduce(art.bounds(of: art.elements[0])) { $0.union(art.bounds(of: $1)) }
    for i in art.elements.indices { art.elements[i].x += 10 - complete.x; art.elements[i].y += 10 - complete.y }
    try validateArtwork(art)
    return .init(artwork: art, frameSize: .init(complete.width + 20, complete.height + 20), pieces: pieces, seams: seams)
  }
}

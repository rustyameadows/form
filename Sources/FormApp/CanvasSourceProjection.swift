import AppKit
import CryptoKit
import FormCore

/// A view of a construction's existing artwork source, never a second document.
struct CanvasSourceProjection: Equatable {
  let constructionID: UUID
  let sourceID: UUID
  let panelID: String?
  let inside: Bool
  let title: String
  let size: Point2
  let sourceToLocal: Affine2
  let boundary: [Point2]

  var key: String {
    "\(constructionID.uuidString):\(inside ? "inside" : "outside"):\(panelID ?? "net")"
  }
  var id: UUID {
    let b = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
    return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                       b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
  }
  var isProof: Bool { panelID == nil }

  static func views(of object: ProductObject, sourceID: UUID, inside: Bool,
                    net: PaperNet) -> [Self] {
    var result = [Self(constructionID: object.id, sourceID: sourceID, panelID: nil,
      inside: inside, title: object.name + (inside ? " · Inside dieline" : " · Dieline"),
      size: net.size, sourceToLocal: .init(), boundary: [])]
    for panel in net.panels {
      let angle = (panel.artworkRotationDegrees ?? 0) * .pi / 180
      let rotation = Affine2(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle), tx: 0, ty: 0)
      let rotated = panel.polygon.map(rotation.apply)
      guard let first = rotated.first else { continue }
      let bounds = rotated.dropFirst().reduce(Rect2(first.x, first.y, 0, 0)) {
        $0.union(.init($1.x, $1.y, 0, 0))
      }
      let transform = Affine2.translation(-bounds.x, -bounds.y).followed(by: rotation)
      result.append(Self(constructionID: object.id, sourceID: sourceID, panelID: panel.id,
        inside: inside, title: object.name + " · " + panel.name + (inside ? " · Inside" : ""),
        size: .init(bounds.width, bounds.height), sourceToLocal: transform,
        boundary: panel.polygon.map(transform.apply)))
    }
    return result
  }

  func display(_ source: Artwork) -> Artwork {
    guard !isProof, sourceToLocal != Affine2() else { return source }
    var value = source
    for i in value.elements.indices where value.elements[i].parentID == nil {
      value.elements[i].affine = sourceToLocal.followed(by: value.elements[i].affine ?? .init())
    }
    // Guides belong to the shared flat document, not to these derived local axes.
    value.guides = nil
    value.showGrid = false
    value.boundary = nil
    return value
  }

  func source(from displayed: Artwork, original: Artwork) -> Artwork {
    guard !isProof, sourceToLocal != Affine2(), let inverse = sourceToLocal.inverse else { return displayed }
    let baseline = display(original)
    let old = Dictionary(uniqueKeysWithValues: original.elements.map { ($0.id, $0) })
    let visible = Dictionary(uniqueKeysWithValues: baseline.elements.map { ($0.id, $0) })
    var value = displayed
    for i in value.elements.indices where value.elements[i].parentID == nil {
      let element = value.elements[i]
      if element == visible[element.id], let unchanged = old[element.id] {
        value.elements[i] = unchanged
      } else {
        value.elements[i].affine = inverse.followed(by: element.affine ?? .init())
      }
    }
    value.guides = original.guides
    value.showGrid = original.showGrid
    value.boundary = original.boundary
    value.canvasPosition = original.canvasPosition
    return value
  }

  @MainActor func contains(_ point: CGPoint) -> Bool {
    isProof || PaperOutput.path(boundary).contains(point)
  }

  /// Bulk selection uses the same physical region as pointer hit testing.
  /// Source layers outside this view remain in the shared artwork document.
  @MainActor func intersects(_ bounds: Rect2) -> Bool {
    guard !isProof, boundary.count >= 3 else { return true }
    let rect = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    if corners.contains(where: contains) || boundary.contains(where: {
      $0.x >= rect.minX && $0.x <= rect.maxX && $0.y >= rect.minY && $0.y <= rect.maxY
    }) { return true }
    func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
      (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
    }
    func onSegment(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> Bool {
      abs(cross(a,b,p)) < 1e-9 && p.x >= min(a.x,b.x)-1e-9 && p.x <= max(a.x,b.x)+1e-9
        && p.y >= min(a.y,b.y)-1e-9 && p.y <= max(a.y,b.y)+1e-9
    }
    func crosses(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
      let first = cross(a,b,c), second = cross(a,b,d), third = cross(c,d,a), fourth = cross(c,d,b)
      return (first*second < 0 && third*fourth < 0) || onSegment(a,b,c) || onSegment(a,b,d)
        || onSegment(c,d,a) || onSegment(c,d,b)
    }
    for i in boundary.indices {
      let next = boundary[(i+1)%boundary.count]
      let a = CGPoint(x: boundary[i].x, y: boundary[i].y), b = CGPoint(x: next.x, y: next.y)
      for j in corners.indices where crosses(a,b,corners[j],corners[(j+1)%corners.count]) { return true }
    }
    return false
  }
}

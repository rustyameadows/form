import CoreFoundation
import Foundation

/// Editing reference points never change the rendered geometry by themselves.
/// Normalized local coordinates follow a layer through nested affine transforms.
public enum ArtworkTransforms {
  public static let center = Point2(0.5,0.5)

  public static func validateOrigin(_ point: Point2) throws {
    guard point.x.isFinite,point.y.isFinite,(-10...10).contains(point.x),(-10...10).contains(point.y) else {
      throw FormError.invalid("Transform origin must be between −1000% and 1000% on each axis.")
    }
  }

  public static func localOrigin(_ element: ArtworkElement) -> Point2 {
    let origin = element.transformOrigin ?? center
    let size = element.kind == "group" ? element.contentSize ?? .init(element.width,element.height)
      : .init(element.width,element.height)
    return .init(origin.x*size.x,origin.y*size.y)
  }

  public static func worldOrigin(_ element: ArtworkElement,in artwork: Artwork) -> Point2 {
    artwork.worldTransform(element).apply(localOrigin(element))
  }

  public static func selectionOrigin(in artwork: Artwork,ids: Set<UUID>) -> Point2? {
    let roots = artwork.selectionRoots(ids)
    if roots.count == 1 { return worldOrigin(roots[0],in:artwork) }
    guard let first = roots.first else { return nil }
    return roots.dropFirst().reduce(artwork.bounds(of:first)) { $0.union(artwork.bounds(of:$1)) }.center
  }

  public static func applying(_ delta: Affine2,to element: ArtworkElement,in artwork: Artwork) throws -> ArtworkElement {
    let parent = element.parentID.flatMap { id in artwork.elements.first { $0.id == id } }
      .map { artwork.worldTransform($0) } ?? .init()
    guard let inverse = parent.inverse else { throw FormError.invalid("The parent transform is not invertible.") }
    var result = element
    result.affine = inverse.followed(by:delta).followed(by:parent).followed(by:element.affine ?? .init())
    return result
  }

  public static func editOrigin(_ artwork: inout Artwork,ids: Set<UUID>,arguments: [String:Any]) throws {
    let roots = artwork.selectionRoots(ids)
    guard roots.count == 1 else { throw FormError.invalid("Select one layer or group to set its transform origin.") }
    guard let raw = arguments["origin"] else { throw FormError.invalid("Provide origin {x,y}, or null to reset to center.") }
    let origin: Point2?
    if raw is NSNull { origin = nil }
    else {
      guard let values = raw as? [String:Any],Set(values.keys) == ["x","y"] else {
        throw FormError.invalid("Provide normalized transform origin coordinates {x,y}.")
      }
      origin = try .init(number(values["x"],name:"origin.x"),number(values["y"],name:"origin.y"))
      try validateOrigin(origin!)
    }
    let index = artwork.elements.firstIndex { $0.id == roots[0].id }!
    artwork.elements[index].transformOrigin = origin
  }

  public static func transform(_ artwork: inout Artwork,ids: Set<UUID>,arguments: [String:Any]) throws {
    guard let pivot = selectionOrigin(in:artwork,ids:ids) else { throw FormError.invalid("Select artwork to transform.") }
    let keys = ["rotation","scale_x","scale_y","translate_x","translate_y"]
    guard keys.contains(where:{arguments[$0] != nil}) else {
      throw FormError.invalid("Provide rotation, scale_x/scale_y, or translate_x/translate_y.")
    }
    let angle = try arguments["rotation"].map { try number($0,name:"rotation") } ?? 0
    let sx = try arguments["scale_x"].map { try number($0,name:"scale_x") } ?? 1
    let sy = try arguments["scale_y"].map { try number($0,name:"scale_y") } ?? 1
    let dx = try arguments["translate_x"].map { try number($0,name:"translate_x") } ?? 0
    let dy = try arguments["translate_y"].map { try number($0,name:"translate_y") } ?? 0
    guard abs(angle)<=36000,(0.001...1000).contains(sx),(0.001...1000).contains(sy),
      abs(dx)<=100000,abs(dy)<=100000 else { throw FormError.invalid("Check rotation, positive scales, and physical translation limits.") }
    if angle == 0 && sx == 1 && sy == 1 && dx == 0 && dy == 0 { return }
    let delta = Affine2.translation(dx+pivot.x,dy+pivot.y).followed(by:.rotation(angle))
      .followed(by:.scale(sx,sy)).followed(by:.translation(-pivot.x,-pivot.y))
    let snapshot = artwork
    for root in snapshot.selectionRoots(ids) {
      let index = artwork.elements.firstIndex { $0.id == root.id }!
      artwork.elements[index] = try applying(delta,to:root,in:snapshot)
    }
  }

  private static func number(_ value:Any?,name:String) throws -> Double {
    guard let value = value as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),value.doubleValue.isFinite else {
      throw FormError.invalid("\(name) must be a finite number.")
    }
    return value.doubleValue
  }
}

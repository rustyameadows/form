import Foundation

extension Project {
  public func merchandisePlacement(
    _ object: ProductObject, attachment: TextileAttachment, host: ProductObject
  ) -> TextilePlacement {
    guard let zone = MerchandiseBlanks.zones(host).first(where: { $0.id == attachment.zone }) else {
      return .init(position: object.position, rotation: object.rotation, underside: false)
    }
    let center = MerchandiseBlanks.sample(
      host, zone: zone, u: attachment.offset.x, v: attachment.offset.y,
      clearance: attachment.clearance)
    let a = host.rotation * Double.pi / 180
    let c = cos(a)
    let s = sin(a)
    func rotate(_ v: Vector3) -> Vector3 { .init(v.x * c + v.z * s, v.y, -v.x * s + v.z * c) }
    let p = rotate(MerchandiseBlanks.displayPoint(center.point, host: host))
    let normal = rotate(MerchandiseBlanks.displayVector(center.normal, host: host))
    if zone.curved {
      return .init(
        position: .init(host.position.x + p.x, host.position.y + p.y, host.position.z + p.z),
        rotation: host.rotation, underside: false, normal: .init(0, 1, 0),
        basisRight: rotate(.init(1, 0, 0)), basisDown: rotate(.init(0, 0, 1)))
    }
    let t = attachment.rotation * Double.pi / 180
    let cs = cos(t)
    let sn = sin(t)
    let r = Vector3(
      zone.right.x * cs - zone.down.x * sn, zone.right.y * cs - zone.down.y * sn,
      zone.right.z * cs - zone.down.z * sn)
    let d = Vector3(
      zone.right.x * sn + zone.down.x * cs, zone.right.y * sn + zone.down.y * cs,
      zone.right.z * sn + zone.down.z * cs)
    return .init(
      position: .init(host.position.x + p.x, host.position.y + p.y, host.position.z + p.z),
      rotation: host.rotation + attachment.rotation, underside: normal.y < 0, normal: normal,
      basisRight: rotate(MerchandiseBlanks.displayVector(r, host: host)),
      basisDown: rotate(MerchandiseBlanks.displayVector(d, host: host)))
  }
  public func conformedMerchandiseSignature(_ object: ProductObject) -> [String: Double]? {
    guard let a = object.textile?.attachment,
      let host = objects.first(where: { $0.id == a.garmentID }), host.recipeID == "curvedCap"
    else { return nil }
    var values = host.parameters
    values["offsetU"] = a.offset.x
    values["offsetV"] = a.offset.y
    values["attachmentRotation"] = a.rotation
    values["clearance"] = a.clearance
    values["zone"] = Double(TextileAttachment.Zone.allCases.firstIndex(of: a.zone) ?? 0)
    return values
  }
  public mutating func moveMerchandiseAttachment(
    _ objectID: UUID, to point: Vector3, host: ProductObject, attachment: TextileAttachment
  ) {
    guard let index = objects.firstIndex(where: { $0.id == objectID }),
      let zone = MerchandiseBlanks.zones(host).first(where: { $0.id == attachment.zone })
    else { return }
    let a = host.rotation * Double.pi / 180
    let dx = point.x - host.position.x
    let dz = point.z - host.position.z
    var local = Vector3(
      dx * cos(a) - dz * sin(a), point.y - host.position.y, dx * sin(a) + dz * cos(a))
    if host.textile?.laidFaceDown == true {
      local = .init(-local.x, MerchandiseBlanks.displayHeight(host) - local.y, local.z)
    }
    if zone.curved {
      var angle = atan2(local.x, -local.z) - zone.origin.x
      angle = atan2(sin(angle), cos(angle))
      objects[index].textile?.attachment?.offset = .init(
        -angle * host["width"] / 2, zone.origin.y - local.y)
    } else {
      let v = Vector3(local.x - zone.origin.x, local.y - zone.origin.y, local.z - zone.origin.z)
      objects[index].textile?.attachment?.offset = .init(
        v.x * zone.right.x + v.y * zone.right.y + v.z * zone.right.z,
        v.x * zone.down.x + v.y * zone.down.y + v.z * zone.down.z)
    }
  }
}

extension MerchandiseBlanks {
  public static func displayHeight(_ o: ProductObject) -> Double {
    o.recipeID == "crewTee" ? o["loft"] + 4 : o["gusset"] + 12
  }
  public static func displayPoint(_ p: Vector3, host: ProductObject) -> Vector3 {
    host.textile?.laidFaceDown == true ? .init(-p.x, displayHeight(host) - p.y, p.z) : p
  }
  public static func displayVector(_ p: Vector3, host: ProductObject) -> Vector3 {
    host.textile?.laidFaceDown == true ? .init(-p.x, -p.y, p.z) : p
  }
}
extension Project {
  public func merchandiseBlankPlacement(_ host: ProductObject) -> TextilePlacement {
    let flipped = host.textile?.laidFaceDown == true
    let a = host.rotation * Double.pi / 180
    let c = cos(a)
    let s = sin(a)
    let sign = flipped ? -1.0 : 1.0
    return .init(
      position: .init(
        host.position.x, host.position.y + (flipped ? MerchandiseBlanks.displayHeight(host) : 0),
        host.position.z), rotation: host.rotation, underside: flipped, normal: .init(0, sign, 0),
      basisRight: .init(sign * c, 0, -sign * s), basisDown: .init(s, 0, c))
  }
  public func merchandiseMaterialDependencies(_ o: ProductObject) -> [Material]? {
    guard MerchandiseBlanks.garmentIDs.contains(o.recipeID) else { return nil }
    return [
      material(
        o.textile?.trimMaterialID ?? MerchandiseBlanks.defaults(o.recipeID)?.trimMaterialID
          ?? o.materialID
      ).withoutFabricPattern
    ]
  }
}

extension Project {
  /// New merchandise regions become independent flat Table pieces when detached. Keep the existing
  /// bomber's world-pose behavior unchanged; extraction never leaves an unsupported curved plate.
  public func detachedTextilePlacement(_ object: ProductObject) -> TextilePlacement {
    let pose = textilePlacement(object)
    guard let a = object.textile?.attachment,
      let host = objects.first(where: { $0.id == a.garmentID }),
      MerchandiseBlanks.garmentIDs.contains(host.recipeID)
    else { return pose }
    return .init(
      position: .init(pose.position.x, 0, pose.position.z), rotation: host.rotation + a.rotation,
      underside: false)
  }
}

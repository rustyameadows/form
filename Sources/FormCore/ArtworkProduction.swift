import Foundation

public enum ArtworkProductionRole:String,Codable,CaseIterable,Hashable,Sendable {
  case print,cut,score,stitch,engrave,guide
  public var title:String {self == .print ? "Print artwork":rawValue.capitalized}
  public var isTechnical:Bool {self != .print && self != .guide}
  public static let manufacturing:[Self] = [.print,.cut,.score,.stitch,.engrave]
  public static func resolve(_ value:String?) -> Self? {
    value == "artwork" ? .print:value.flatMap(Self.init(rawValue:))
  }
}

public struct ArtworkProductionSelection:Sendable {
  public var artwork:Artwork
  /// Rendered leaves only; clipping dependencies and structural groups are excluded.
  public var contentIDs:Set<UUID>
  public var roles:[UUID:ArtworkProductionRole]
}

/// A non-print group is a manufacturing layer: its entire subtree inherits that
/// purpose. This preserves legacy construction-layer exclusion from print output.
public enum ArtworkProduction {
  public static func effectiveRoles(in art:Artwork) -> [UUID:ArtworkProductionRole] {
    let byID = Dictionary(uniqueKeysWithValues:art.elements.map {($0.id,$0)})
    var result:[UUID:ArtworkProductionRole] = [:]
    func role(_ element:ArtworkElement,_ visiting:Set<UUID>) -> ArtworkProductionRole {
      if let cached = result[element.id] {return cached}
      guard !visiting.contains(element.id) else {return .guide}
      var seen = visiting; seen.insert(element.id)
      let inherited = element.parentID.flatMap {byID[$0]}.map {role($0,seen)} ?? .print
      let value = inherited != .print ? inherited:ArtworkProductionRole.resolve(element.productionRole) ?? .print
      result[element.id] = value
      return value
    }
    for element in art.elements {_ = role(element,[])}
    return result
  }

  public static func controllingGroup(for element:ArtworkElement,in art:Artwork) -> ArtworkElement? {
    let byID = Dictionary(uniqueKeysWithValues:art.elements.map {($0.id,$0)})
    var ancestors:[ArtworkElement] = [],parent = element.parentID,seen:Set<UUID> = []
    while let id = parent,seen.insert(id).inserted,let value = byID[id] {
      ancestors.append(value); parent = value.parentID
    }
    return ancestors.reversed().first {ArtworkProductionRole.resolve($0.productionRole).map {$0 != .print} == true}
  }

  public static func assign(_ art:inout Artwork,ids:Set<UUID>,arguments:[String:Any]) throws {
    guard !ids.isEmpty,ids.isSubset(of:Set(art.elements.map(\.id))),let raw = arguments["role"] else {
      throw FormError.invalid("Select artwork layers and provide role print/cut/score/stitch/engrave/guide, or null to inherit.")
    }
    let role:ArtworkProductionRole?
    if raw is NSNull {role = nil}
    else if let name = raw as? String,let parsed = ArtworkProductionRole.resolve(name) {role = parsed}
    else {throw FormError.invalid("Unknown production role. Use print, cut, score, stitch, engrave, guide, or null.")}
    let roots = art.selectionRoots(ids),affected = art.descendants(of:Set(roots.map(\.id)))
    guard !art.elements.contains(where:{affected.contains($0.id) && art.isLocked($0)}) else {
      throw FormError.invalid("Unlock the selected manufacturing layer and its descendants first.")
    }
    for root in roots {
      if let role,let gate = controllingGroup(for:root,in:art),
        ArtworkProductionRole.resolve(gate.productionRole) != role {
        throw FormError.invalid("\(root.title) inherits its production role from \(gate.title). Change that group's role first.")
      }
    }
    let rootIDs = Set(roots.map(\.id))
    var result = art
    for index in result.elements.indices where affected.contains(result.elements[index].id) {
      result.elements[index].productionRole = rootIDs.contains(result.elements[index].id) ? role?.rawValue:nil
    }
    try validateArtwork(result)
    art = result
  }

  public static func parseRoles(_ raw:Any?) throws -> [ArtworkProductionRole] {
    guard let names = raw as? [String],!names.isEmpty,names.count <= ArtworkProductionRole.allCases.count else {
      throw FormError.invalid("roles must be a nonempty array of print/cut/score/stitch/engrave/guide.")
    }
    var selected:Set<ArtworkProductionRole> = []
    for name in names {
      guard let role = ArtworkProductionRole.resolve(name),selected.insert(role).inserted else {
        throw FormError.invalid("Choose known, distinct production roles.")
      }
    }
    return ArtworkProductionRole.allCases.filter {selected.contains($0)}
  }

  public static func filtered(_ source:Artwork,roles:Set<ArtworkProductionRole>) throws -> ArtworkProductionSelection {
    try validateArtwork(source)
    let byID = Dictionary(uniqueKeysWithValues:source.elements.map {($0.id,$0)})
    let effective = effectiveRoles(in:source),masks = Set(source.elements.compactMap(\.clipID))
    func visible(_ value:ArtworkElement) -> Bool {
      var current:ArtworkElement? = value,seen:Set<UUID> = []
      while let item = current,seen.insert(item.id).inserted {
        if item.hidden == true || (item.opacity ?? 1) == 0 {return false}
        current = item.parentID.flatMap {byID[$0]}
      }
      return true
    }
    let content = Set(source.elements.filter {
      $0.kind != "group" && !masks.contains($0.id) && roles.contains(effective[$0.id] ?? .print) && visible($0)
    }.map(\.id))
    var required = content
    // Structural ancestors, masks and mask ancestors retain exact transforms,
    // compound holes, clipping and appearance, even if their own role differs.
    var pending = Array(required)
    while let id = pending.popLast(),let element = byID[id] {
      for dependency in [element.parentID,element.clipID].compactMap({$0}) {
        if required.insert(dependency).inserted {pending.append(dependency)}
      }
    }
    var art = source.resolvingLists
    art.elements = art.elements.filter {required.contains($0.id)}.map(\.withBakedListNumbers)
    art.retainRepresentedSewingSeams()
    for index in art.elements.indices {art.elements[index].productionRole = nil}
    if !roles.contains(.print) {art.backgroundOpacity = 0; art.boundary = nil}
    return .init(artwork:art,contentIDs:content,roles:effective.filter {required.contains($0.key)})
  }

  public static func hiddenIDs(in art:Artwork,roles:Set<ArtworkProductionRole>) -> Set<UUID> {
    guard !roles.isEmpty else { return [] }
    return Set(effectiveRoles(in:art).filter {roles.contains($0.value)}.keys)
  }
}

extension Artwork {
  public var requiresSchemaTwentyTwo:Bool {elements.contains {$0.productionRole == "print"}}
}

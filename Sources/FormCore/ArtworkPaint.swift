import CoreFoundation
import Foundation

public enum StrokePattern {
  public static func parse(_ text: String, unit: PhysicalUnit) throws -> [Double]? {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count <= 16 else { throw FormError.invalid("Use at most 16 dash/gap lengths.") }
    let values = try parts.map { try unit.parse(String($0).trimmingCharacters(in: .whitespaces)) }
    guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1000 }), values.reduce(0, +) > 0
    else {
      throw FormError.invalid("Use nonnegative lengths up to 1000 mm, with a nonzero total.")
    }
    return values
  }
}

extension ArtworkElement {
  public var supportsAlignedStroke: Bool {
    if booleanOperation != nil { return true }
    if ["rectangle", "ellipse", "polygon", "star"].contains(kind) { return true }
    return kind == "path" && path?.contours.isEmpty == false && path!.contours.allSatisfy(\.closed)
  }
  public var visibleStroke: ArtworkStroke? {
    guard !["text", "image"].contains(kind), kind != "group" || booleanOperation != nil else { return nil }
    let value = stroke ?? (kind == "line" ? .init(color: color) : nil)
    return value?.enabled != false && (value?.width ?? 0) > 0 ? value : nil
  }
  public var hasVisualOverflow: Bool {
    hasActiveEffects || (visibleStroke != nil && visibleStroke?.alignment != "inside")
  }
}

extension ArtworkGradient {
  /// Keep equal-offset stops in their existing order: the later color defines
  /// the hard edge, and UUIDs remain stable as a stop crosses its neighbors.
  public mutating func sortStops() {
    stops = stops.enumerated().sorted {
      $0.element.offset == $1.element.offset
        ? $0.offset < $1.offset : $0.element.offset < $1.element.offset
    }.map(\.element)
  }
  public func sampledStop(at position: Double) -> GradientStop {
    let t = max(0, min(1, position))
    guard let first = stops.first else { return .init(t, "#000000") }
    let before = stops.last(where: { $0.offset <= t }) ?? first
    let after = stops.first(where: { $0.offset > t }) ?? stops.last!
    let fraction =
      after.offset > before.offset
      ? max(0, min(1, (t - before.offset) / (after.offset - before.offset))) : 0
    func rgb(_ color: String) -> [Double] {
      let value =
        UInt64(color.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
      return [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)]
    }
    let a = rgb(before.color)
    let b = rgb(after.color)
    let channels = zip(a, b).map { pair in Int((pair.0 + (pair.1 - pair.0) * fraction).rounded()) }
    var stop = GradientStop(
      t, String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2]))
    let opacity = (before.opacity ?? 1) + ((after.opacity ?? 1) - (before.opacity ?? 1)) * fraction
    stop.opacity = opacity == 1 ? nil : opacity
    return stop
  }
}

public enum PaintCommands {
  public static let names = ["update", "add_stop", "update_stop", "delete_stop", "reverse_stops"]
  @discardableResult public static func apply(
    in project: inout Project, objectID: UUID,
    ids: Set<UUID>, command: String = "update", arguments: [String: Any]
  ) throws -> UUID? {
    guard names.contains(command), let object = project.objects.first(where: { $0.id == objectID }),
      !project.artworkOwner(object).locked, var art = project.editableArtwork(object), !ids.isEmpty,
      ids.isSubset(of: Set(art.elements.map(\.id)))
    else { throw FormError.invalid("Choose editable vector artwork.") }
    let masks = Set(art.elements.compactMap(\.clipID))
    let roots = art.selectionRoots(ids)
    guard
      roots.allSatisfy({
        !art.isLocked($0) && !masks.contains($0.id)
          && (BooleanCommands.shapeKinds.contains($0.kind) || $0.kind == "line"
            || $0.booleanOperation != nil)
      })
    else {
      throw FormError.invalid(
        "Choose unlocked vector artwork. Clipping masks use geometry; convert text to outlines for vector paint."
      )
    }
    if command != "update" && roots.count != 1 {
      throw FormError.invalid("Choose one object to edit its gradient stops.")
    }
    func number(_ input: Any?, _ fallback: Double) throws -> Double {
      guard let input else { return fallback }
      guard let n = input as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
        n.doubleValue.isFinite
      else {
        throw FormError.invalid("Paint values must be finite numbers.")
      }
      return n.doubleValue
    }
    func boolean(_ input: Any) throws -> Bool {
      guard let n = input as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
        throw FormError.invalid("Stroke enabled must be a boolean.")
      }
      return n.boolValue
    }
    func string(_ input: Any) throws -> String {
      guard let value = input as? String else {
        throw FormError.invalid("Use a paint name or color string.")
      }
      return value
    }
    func point(_ input: Any, _ old: Point2) throws -> Point2 {
      guard let v = input as? [String: Any], Set(v.keys).isSubset(of: ["x", "y"]) else {
        throw FormError.invalid("Gradient positions accept x and y.")
      }
      return .init(try number(v["x"], old.x), try number(v["y"], old.y))
    }
    var selectedStop: UUID?
    for root in roots {
      let i = art.elements.firstIndex(where: { $0.id == root.id })!
      if command == "update" {
        if let value = arguments["stroke"] {
          if value is NSNull {
            art.elements[i].stroke = nil
          } else {
            guard let v = value as? [String: Any],
              Set(v.keys).isSubset(of: [
                "enabled", "width", "color", "opacity", "cap", "join", "miter", "dash",
                "dash_offset", "alignment",
              ])
            else {
              throw FormError.invalid("Unknown stroke property.")
            }
            var stroke = root.stroke ?? .init(color: root.kind == "line" ? root.color : "#292D2C")
            if root.stroke == nil && root.kind == "line" { stroke.swatchID = root.fillSwatchID }
            if let value = v["enabled"] { stroke.enabled = try boolean(value) ? nil : false }
            stroke.width = try number(v["width"], stroke.width)
            if let value = v["color"] {
              stroke.color = try string(value)
              stroke.swatchID = nil
            }
            if let value = v["opacity"] { stroke.opacity = try number(value, 1) }
            if let value = v["cap"] { stroke.cap = try string(value) }
            if let value = v["join"] { stroke.join = try string(value) }
            if let value = v["miter"] { stroke.miter = try number(value, 10) }
            if let value = v["alignment"] {
              let alignment = try string(value)
              stroke.alignment = alignment == "center" ? nil : alignment
            }
            if let value = v["dash_offset"] { stroke.dashOffset = try number(value, 0) }
            if let value = v["dash"] {
              if value is NSNull {
                stroke.dash = nil
              } else {
                guard let values = value as? [Any] else {
                  throw FormError.invalid(
                    "Dash pattern must be an array of lengths in millimeters.")
                }
                stroke.dash = try values.map { try number($0, 0) }
              }
            }
            art.elements[i].stroke = stroke
          }
        }
        if let value = arguments["gradient"] {
          guard root.kind != "line" else {
            throw FormError.invalid("Gradient fills need an area shape.")
          }
          if value is NSNull {
            art.elements[i].gradient = nil
          } else {
            guard let v = value as? [String: Any],
              Set(v.keys).isSubset(of: ["kind", "start", "end", "transform"])
            else { throw FormError.invalid("Unknown gradient property.") }
            var gradient = root.gradient ?? .init()
            if let value = v["kind"] { gradient.kind = try string(value) }
            if let value = v["start"] { gradient.start = try point(value, gradient.start) }
            if let value = v["end"] { gradient.end = try point(value, gradient.end) }
            if let value = v["transform"] {
              if value is NSNull {
                gradient.transform = nil
              } else {
                guard let v = value as? [String: Any],
                  Set(v.keys).isSubset(of: ["a", "b", "c", "d", "tx", "ty"])
                else { throw FormError.invalid("Use an affine gradient transform.") }
                let old = gradient.transform ?? .init()
                gradient.transform = .init(
                  a: try number(v["a"], old.a), b: try number(v["b"], old.b),
                  c: try number(v["c"], old.c), d: try number(v["d"], old.d),
                  tx: try number(v["tx"], old.tx), ty: try number(v["ty"], old.ty))
              }
            }
            if root.gradient == nil { art.elements[i].fillEnabled = true }
            art.elements[i].gradient = gradient
            art.elements[i].fillSwatchID = nil
          }
        }
      } else {
        guard var gradient = root.gradient else { throw FormError.invalid("Add a gradient first.") }
        if command == "reverse_stops" {
          gradient.stops.reverse()
          for i in gradient.stops.indices {
            gradient.stops[i].offset = 1 - gradient.stops[i].offset
          }
        } else if command == "add_stop" {
          guard gradient.stops.count < 32 else {
            throw FormError.invalid("A gradient supports up to 32 stops.")
          }
          let offset: Double
          if let value = arguments["offset"] {
            offset = try number(value, 0.5)
          } else {
            let positions = [0.0] + gradient.stops.map(\.offset) + [1.0]
            let gap = zip(positions, positions.dropFirst()).max { $0.1 - $0.0 < $1.1 - $1.0 }!
            offset = (gap.0 + gap.1) / 2
          }
          let resolved = project.resolvingSwatches(
            in: .init(elements: [root]), keepingReferences: true
          ).elements[0].gradient!
          var stop = resolved.sampledStop(at: offset)
          stop.offset = offset
          if let raw = arguments["stop_id"] {
            guard let value = raw as? String, let id = UUID(uuidString: value),
              !gradient.stops.contains(where: { $0.id == id })
            else { throw FormError.invalid("Choose a new gradient-stop UUID.") }
            stop.id = id
          }
          if let value = arguments["color"] { stop.color = try string(value) }
          if let value = arguments["opacity"] { stop.opacity = try number(value, 1) }
          gradient.stops.append(stop)
          selectedStop = stop.id
        } else {
          guard let value = arguments["stop_id"] as? String, let id = UUID(uuidString: value),
            let index = gradient.stops.firstIndex(where: { $0.id == id })
          else { throw FormError.invalid("Choose an existing gradient stop.") }
          if command == "delete_stop" {
            guard gradient.stops.count > 2 else {
              throw FormError.invalid("Keep at least two gradient stops.")
            }
            gradient.stops.remove(at: index)
            selectedStop = gradient.stops[min(index, gradient.stops.count - 1)].id
          } else {
            if let value = arguments["offset"] {
              gradient.stops[index].offset = try number(value, 0)
            }
            if let value = arguments["color"] {
              gradient.stops[index].color = try string(value)
              gradient.stops[index].swatchID = nil
            }
            if let value = arguments["opacity"] {
              gradient.stops[index].opacity = try number(value, 1)
            }
            selectedStop = id
          }
        }
        gradient.sortStops()
        art.elements[i].gradient = gradient
      }
    }
    var candidate = project
    try candidate.setArtwork(art, for: objectID)
    project = candidate
    return selectedStop
  }
}

extension Artwork {
  public var requiresSchemaTen: Bool {
    elements.contains { $0.stroke?.alignment != nil || $0.stroke?.enabled != nil }
  }
}

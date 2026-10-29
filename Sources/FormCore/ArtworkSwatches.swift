import Foundation

public struct ArtworkSwatch: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var name: String
  public var color: String
  public var colorSpace: String? = "sRGB"
  public var printInk:ProductionInk?
  public init(name: String, color: String,printInk:ProductionInk?=nil) { self.name = name; self.color = color;self.printInk=printInk }
}

extension Artwork {
  /// Paint leaves reached by a selection. Masks and hidden descendants do not
  /// take part; live boolean results and component instances are atomic paints.
  public func swatchPaintTargets(for ids: Set<UUID>) -> Set<UUID> {
    let masks = Set(elements.compactMap(\.clipID))
    var targets = Set<UUID>()
    func include(_ e: ArtworkElement) {
      if e.kind == "group" && e.booleanOperation == nil && e.component == nil {
        for child in elements where child.parentID == e.id && child.hidden != true && !masks.contains(child.id) {
          include(child)
        }
      } else { targets.insert(e.id) }
    }
    for root in selectionRoots(ids) { include(root) }
    return targets
  }

  public func fillSwatchReferences(for ids: Set<UUID>) -> Set<UUID?> {
    let targets = swatchPaintTargets(for: ids)
    var result = Set<UUID?>()
    for e in elements where targets.contains(e.id) {
      if e.kind == "text", let runs = e.textRuns, !runs.isEmpty {
        result.formUnion(runs.map(\.swatchID))
        if runs.reduce(0, { $0 + $1.length }) < e.text.utf16.count { result.insert(e.fillSwatchID) }
      } else if e.kind == "line" {
        result.insert(e.stroke?.swatchID)
      } else { result.insert(e.component?.colorSwatchID ?? e.fillSwatchID) }
    }
    return result
  }

  public var referencedSwatches: Set<UUID> {
    var ids = Set([backgroundSwatchID].compactMap { $0 })
    for e in elements {
      ids.formUnion([e.fillSwatchID, e.stroke?.swatchID, e.component?.colorSwatchID, e.shadow?.swatchID].compactMap { $0 })
      ids.formUnion(e.gradient?.stops.compactMap(\.swatchID) ?? [])
      ids.formUnion(e.textRuns?.compactMap(\.swatchID) ?? [])
      ids.formUnion(e.component?.overrides?.compactMap(\.colorSwatchID) ?? [])
    }
    return ids
  }
}

extension Project {
  public func validateSwatches() throws {
    try validateProductionInks()
    let values = swatches ?? []
    let ids = Set(values.map(\.id))
    guard values.count <= 256, ids.count == values.count,
      Set(values.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == values.count
    else { throw FormError.invalid("A project supports 256 swatches with unique IDs and names.") }
    for value in values {
      guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        value.name.count <= 100, value.colorSpace == nil || value.colorSpace == "sRGB"
      else { throw FormError.invalid("Use a swatch name of 1–100 characters and sRGB color.") }
      try validateColor(value.color)
    }
    for art in storedArtworks {
      guard art.referencedSwatches.isSubset(of: ids) else {
        throw FormError.invalid("Artwork references a missing project swatch.")
      }
    }
    for story in textStories ?? [] {
      guard Artwork(elements:[story.sourceElement]).referencedSwatches.isSubset(of:ids) else{throw FormError.invalid("A text story refers to a missing project swatch.")}
    }
  }

  public func resolvingSwatches(in artwork: Artwork, keepingReferences: Bool = false,
    only: Set<UUID>? = nil) -> Artwork {
    guard let swatches, !swatches.isEmpty else { return artwork }
    let colors = Dictionary(uniqueKeysWithValues: swatches.map { ($0.id, $0.color) })
    func resolve(_ id: inout UUID?, _ color: inout String) {
      guard let key = id, only == nil || only!.contains(key), let value = colors[key] else { return }
      color = value
      if !keepingReferences { id = nil }
    }
    func optional(_ id: inout UUID?, _ color: inout String?) {
      var value = color ?? "#292D2C"
      if id != nil { resolve(&id, &value); color = value }
    }
    var result = artwork
    resolve(&result.backgroundSwatchID, &result.background)
    for i in result.elements.indices {
      var e = result.elements[i]
      resolve(&e.fillSwatchID, &e.color)
      if var stroke = e.stroke { resolve(&stroke.swatchID, &stroke.color); e.stroke = stroke }
      if var shadow = e.shadow { resolve(&shadow.swatchID, &shadow.color); e.shadow = shadow }
      if var gradient = e.gradient {
        for index in gradient.stops.indices {
          var stop = gradient.stops[index]
          resolve(&stop.swatchID, &stop.color)
          gradient.stops[index] = stop
        }
        e.gradient = gradient
      }
      if var runs = e.textRuns {
        for index in runs.indices {
          var run = runs[index]
          resolve(&run.swatchID, &run.color)
          runs[index] = run
        }
        e.textRuns = runs
      }
      if var ref = e.component {
        optional(&ref.colorSwatchID, &ref.color)
        if var overrides = ref.overrides {
          for index in overrides.indices {
            var change = overrides[index]
            optional(&change.colorSwatchID, &change.color)
            overrides[index] = change
          }
          ref.overrides = overrides
        }
        e.component = ref
      }
      result.elements[i] = e
    }
    return result
  }
}

public enum SwatchCommands {
  @discardableResult public static func save(in project: inout Project, id: UUID? = nil,
    name: String, color: String,printInk:ProductionInk?=nil,replacingInk:Bool=false) throws -> UUID {
    var candidate = project
    var values = candidate.swatches ?? []
    if let id {
      guard let index = values.firstIndex(where: { $0.id == id }) else {
        throw FormError.missing("Swatch not found.")
      }
      if values[index].printInk != nil,!replacingInk,values[index].color.uppercased() != color.uppercased() {throw FormError.invalid("Edit the production ink components, or choose Convert to RGB preview before changing this swatch's HEX appearance.")}
      if replacingInk {values[index].printInk=printInk}
      values[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      values[index].color = color.uppercased()
    } else {
      values.append(.init(name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: color.uppercased(),printInk:printInk))
    }
    candidate.swatches = values
    try candidate.validateSwatches()
    project = candidate
    return id ?? values.last!.id
  }

  public static func delete(in project: inout Project, id: UUID) throws {
    guard project.swatches?.contains(where: { $0.id == id }) == true else { throw FormError.missing("Swatch not found.") }
    if project.productionInk(id) != nil,project.productionInkIsReferenced(id) {throw FormError.invalid("Convert this used production ink to RGB preview before deleting it.")}
    var candidate = project
    for i in candidate.objects.indices {
      candidate.objects[i].updateStoredArtworks{art in
        if art.referencedSwatches.contains(id){art=project.resolvingSwatches(in:art,only:[id])}
      }
    }
    candidate.swatches?.removeAll { $0.id == id }
    for i in candidate.textStories?.indices ?? 0..<0 {
      let artwork=Artwork(elements:[candidate.textStories![i].sourceElement])
      candidate.textStories![i].setSource(project.resolvingSwatches(in:artwork,only:[id]).elements[0])
    }
    try candidate.validateArtworkLinks()
    project = candidate
  }

  /// Preserve mixed typography while applying a color/link to a UTF-16 range.
  public static func textRange(_ element: inout ArtworkElement, location: Int, length: Int,
    color: String?, swatchID: UUID?) throws {
    let count = element.text.utf16.count
    let utf16 = element.text as NSString
    func scalarBoundary(_ offset: Int) -> Bool {
      if offset == 0 || offset == count { return true }
      return !(0xD800...0xDBFF).contains(utf16.character(at: offset - 1))
        || !(0xDC00...0xDFFF).contains(utf16.character(at: offset))
    }
    guard element.kind == "text", location >= 0, length > 0, location <= count,
      length <= count - location,
      scalarBoundary(location), scalarBoundary(location + length),
      Range(NSRange(location: location, length: length), in: element.text) != nil
    else { throw FormError.invalid("Choose a valid nonempty UTF-16 character range.") }
    let old = element.textRuns ?? []
    var points = Set([0, count, location, location + length])
    for run in old { points.insert(run.location); points.insert(run.location + run.length) }
    let sorted = points.sorted()
    var result: [TextSpan] = []
    for (start, end) in zip(sorted, sorted.dropFirst()) where end > start {
      var run = old.first { $0.location <= start && $0.location + $0.length >= end }
        ?? .init(location: start, length: end - start, typography: element.typography ?? .init(),
          fontSize: element.fontSize, color: element.color)
      if !old.contains(where: { $0.location <= start && $0.location + $0.length >= end }) {
        run.swatchID = element.fillSwatchID
        run.textStyle = element.textStyle
        run.paragraphStyle = element.paragraphStyle
      }
      run.location = start
      run.length = end - start
      if start >= location && end <= location + length {
        if let color { run.color = color }
        run.swatchID = swatchID
      }
      result.append(run)
    }
    element.textRuns = result
  }

  public static func assign(in project: inout Project, objectID: UUID, ids: Set<UUID>,
    target: String = "fill", swatchID: UUID?, stopID: UUID? = nil, partID: UUID? = nil,
    location: Int? = nil, length: Int? = nil) throws {
    guard let object = project.objects.first(where: { $0.id == objectID }),
      ["fill", "stroke", "shadow", "gradient_stop", "background", "component_part", "text_range"].contains(target)
    else { throw FormError.invalid("Choose artwork and a supported swatch target.") }
    guard target != "background" || object.supportsArtworkFace else {
      throw FormError.invalid("This object has no supported artwork background.")
    }
    var art = project.editableArtwork(object) ?? .init(background: "#FFFFFF", bleed: 0)
    if swatchID==nil {try ProductionInkCommands.validateDetach(project,artwork:art,ids:ids,target:target,stopID:stopID,partID:partID,location:location,length:length)}
    let color: String?
    if let swatchID {
      guard let swatch = project.swatches?.first(where: { $0.id == swatchID }) else { throw FormError.missing("Swatch not found.") }
      color = swatch.color
    } else { color = nil }
    if ["fill","text_range"].contains(target) {
      let targets=art.swatchPaintTargets(for:ids)
      let linked=art.elements.filter{targets.contains($0.id) && $0.storyFrame != nil}
      if !linked.isEmpty {
        var candidate=project,seen=Set<UUID>()
        for element in linked {
          let id=element.storyFrame!.storyID
          guard seen.insert(id).inserted,let story=project.textStories?.first(where:{$0.id==id}) else{continue}
          var source=story.sourceElement
          let current=project.resolvingSwatches(in:Artwork(elements:[source]),keepingReferences:true).elements[0]
          if target=="text_range" {
            guard let location,let length else{throw FormError.invalid("Provide a global story UTF-16 range.")}
            source=current;try textRange(&source,location:location,length:length,color:color,swatchID:swatchID)
          } else {
            source.color=color ?? current.color;source.fillSwatchID=swatchID
            for i in source.textRuns?.indices ?? 0..<0 {source.textRuns![i].color=color ?? current.textRuns?[i].color ?? current.color;source.textRuns![i].swatchID=swatchID}
          }
          try PublicationCommands.setSource(in:&candidate,storyID:id,source:source)
        }
        let ordinary=targets.subtracting(Set(linked.map(\.id)))
        if !ordinary.isEmpty {try assign(in:&candidate,objectID:objectID,ids:ordinary,target:target,swatchID:swatchID,stopID:stopID,partID:partID,location:location,length:length)}
        try candidate.validateArtworkLinks();project=candidate;return
      }
    }
    let resolved = project.resolvingSwatches(in: art, keepingReferences: true)
    if target == "background" {
      art.background = color ?? resolved.background
      art.backgroundSwatchID = swatchID
    } else {
      guard !ids.isEmpty, ids.isSubset(of: Set(art.elements.map(\.id))),
        art.selectionRoots(ids).allSatisfy({ !art.isLocked($0) }) else {
        throw FormError.invalid("Choose unlocked artwork to bind or detach a swatch.")
      }
      var targets = ids
      if target == "fill" || target == "stroke" {
        targets = art.swatchPaintTargets(for: ids)
      }
      guard !targets.isEmpty, art.elements.filter({ targets.contains($0.id) }).allSatisfy({ !art.isLocked($0) }) else {
        throw FormError.invalid("Choose unlocked paintable layers.")
      }
      for i in art.elements.indices where targets.contains(art.elements[i].id) {
        var e = art.elements[i]
        let current = resolved.elements[i]
        switch target {
        case "fill":
          guard e.kind != "image" else { throw FormError.invalid("Image pixels do not have a vector fill.") }
          if e.component != nil {
            e.component?.color = color ?? current.component?.color
            e.component?.colorSwatchID = swatchID
          } else if e.kind == "line" {
            var stroke = e.stroke ?? .init(color: e.color)
            stroke.color = color ?? current.stroke?.color ?? current.color
            stroke.swatchID = swatchID
            e.stroke = stroke
          } else {
            e.color = color ?? current.color
            e.fillSwatchID = swatchID
            if swatchID != nil { e.gradient = nil; e.fillEnabled = true }
            for r in e.textRuns?.indices ?? 0..<0 {
              e.textRuns?[r].color = color ?? current.textRuns?[r].color ?? current.color
              e.textRuns?[r].swatchID = swatchID
            }
          }
        case "stroke":
          guard !["text", "image"].contains(e.kind), e.component == nil else {
            throw FormError.invalid("Choose vector strokes; edit a component's source for its stroke.")
          }
          if swatchID == nil && e.stroke == nil { continue }
          var stroke = e.stroke ?? .init(color: e.color)
          stroke.color = color ?? current.stroke?.color ?? current.color
          stroke.swatchID = swatchID
          e.stroke = stroke
        case "shadow":
          if swatchID == nil && e.shadow == nil { continue }
          var shadow = e.shadow ?? .init()
          shadow.color = color ?? current.shadow?.color ?? shadow.color
          shadow.swatchID = swatchID
          e.shadow = shadow
        case "gradient_stop":
          guard let stopID, let index = e.gradient?.stops.firstIndex(where: { $0.id == stopID }) else {
            throw FormError.invalid("Choose an existing gradient stop.")
          }
          e.gradient?.stops[index].color = color ?? current.gradient!.stops[index].color
          e.gradient?.stops[index].swatchID = swatchID
        case "component_part":
          guard var ref = e.component, let partID,
            let source = project.objects.first(where: { $0.id == ref.sourceObjectID }),
            source.artwork?.componentOverrideParts.contains(where: { $0.id == partID }) == true
          else { throw FormError.invalid("Choose a visible component part.") }
          var changes = ref.overrides ?? []
          var change = changes.first { $0.elementID == partID } ?? .init(elementID: partID)
          change.color = color ?? current.component?.overrides?.first { $0.elementID == partID }?.color
          change.colorSwatchID = swatchID
          changes.removeAll { $0.elementID == partID }
          changes.append(change)
          ref.overrides = changes
          e.component = ref
        case "text_range":
          guard let location, let length else { throw FormError.invalid("Provide a UTF-16 location and length.") }
          e = current
          try textRange(&e, location: location, length: length,
            color: color, swatchID: swatchID)
        default: break
        }
        art.elements[i] = e
      }
    }
    var candidate = project
    try candidate.setArtwork(art, for: objectID)
    try candidate.validateArtworkLinks()
    project = candidate
  }
}

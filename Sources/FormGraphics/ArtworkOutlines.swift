import CoreGraphics
import FormCore
import Foundation

/// Editable replacements occupy the source's stack position. Hidden sources
/// remain recoverable; masks keep referring to the replacement geometry.
@MainActor public enum ArtworkOutlines {
  public static func convert(
    _ artwork: Artwork, ids: Set<UUID>, mode: String, resolvedPaint: Artwork? = nil
  ) throws
    -> (artwork: Artwork, created: [ArtworkElement])
  {
    guard ["text", "shape", "stroke"].contains(mode), !ids.isEmpty,
      ids.isSubset(of: Set(artwork.elements.map(\.id)))
    else {
      throw FormError.invalid("Choose artwork and a valid outline mode.")
    }
    var result = artwork
    var created: [ArtworkElement] = []
    let all = artwork.descendants(of: ids)
    let masks = Set(artwork.elements.compactMap(\.clipID))
    let booleanChildren = artwork.elements.filter {
      all.contains($0.id) && $0.booleanOperation != nil
    }
    .reduce(into: Set<UUID>()) {
      $0.formUnion(artwork.descendants(of: [$1.id]).subtracting([$1.id]))
    }
    let paintByID = Dictionary(
      uniqueKeysWithValues: (resolvedPaint ?? artwork).resolvingLists.elements.map { ($0.id, $0) })
    for record in artwork.elements
    where all.contains(record.id) && !booleanChildren.contains(record.id)
      && (record.hidden != true || masks.contains(record.id))
    {
      let source = (paintByID[record.id] ?? record).inheritingLanguage(artwork.language)
      let eligible =
        mode == "shape"
        ? ["rectangle", "ellipse", "line", "polygon", "star"].contains(source.kind)
        : mode == "stroke" ? source.visibleStroke != nil : source.kind == "text"
      guard eligible else { continue }
      guard !artwork.isLocked(source), mode != "stroke" || !masks.contains(source.id) else {
        throw FormError.invalid(
          "Unlock the selected layers first. Clipping masks use geometry rather than stroke paint.")
      }
      var replacements: [ArtworkElement]
      if mode == "shape" {
        let path = try VectorGeometry.convertedShape(source)
        replacements = [path]
        for i in result.elements.indices where result.elements[i].clipID == source.id {
          result.elements[i].clipID = path.id
        }
      } else if mode == "stroke" {
        let e =
          source.booleanOperation != nil ? try BooleanGeometry.proxy(source, in: artwork) : source
        let stroke = e.visibleStroke!
        var outline = try VectorGeometry.element(
          from: StrokeGeometry.path(e), color: stroke.color,
          name: "\(e.title.prefix(450)) · stroke", parentID: e.parentID)
        outline.fillSwatchID = stroke.swatchID
        outline.fillOpacity = stroke.opacity
        outline.productionRole = e.productionRole
        if e.kind != "line", e.fillEnabled != false, (e.fillOpacity ?? 1) > 0 {
          var group = wrapper(e, name: "\(e.title.prefix(450)) · expanded")
          // Boolean proxies already expose their result in paint coordinates.
          group.width = e.width
          group.height = e.height
          group.contentSize = .init(e.width, e.height)
          var fill = e
          fill.id = UUID()
          fill.name = "Fill"
          fill.parentID = group.id
          fill.x = 0
          fill.y = 0
          fill.affine = nil
          fill.rotation = nil
          fill.flipX = nil
          fill.flipY = nil
          fill.opacity = nil
          fill.blendMode = nil
          fill.blur = nil
          fill.shadow = nil
          fill.effectStack = nil
          fill.isolatedBlending = nil
          fill.clipID = nil
          fill.clipMode = nil
          fill.stroke = nil
          fill.hidden = nil
          fill.locked = nil
          outline.parentID = group.id
          replacements = [group, fill, outline]
        } else {
          outline.affine = e.localTransform
          outline.opacity = e.opacity
          outline.blendMode = e.blendMode
          outline.blur = e.blur
          outline.shadow = e.shadow
          outline.effectStack = e.effectStack
          outline.isolatedBlending = e.isolatedBlending
          outline.clipID = e.clipID
          outline.clipMode = e.clipMode
          replacements = [outline]
        }
      } else if TextPaintRenderer.usesPaints(source) {
        let group=wrapper(source,name:"\(source.title.prefix(450)) · outlines")
        replacements=[group]
        for (path,paint) in try TextPaintRenderer.vectorLayers(source) where !path.isEmpty {
          var vector=try VectorGeometry.element(from:path,color:paint.color,name:"\(source.title.prefix(450)) · outlines",parentID:group.id)
          // Keep source-frame paint coordinates after path conversion, which
          // otherwise normalizes each glyph group to its own tight bounds.
          let origin=Point2(vector.x,vector.y)
          if var shape=vector.path {
            for i in shape.contours.indices {shape.contours[i].nodes=shape.contours[i].nodes.map{PathCommands.transformed($0,by:.translation(origin.x,origin.y))}}
            shape.width=source.width;shape.height=source.height;vector.path=shape
          }
          vector.x=0;vector.y=0;vector.width=source.width;vector.height=source.height
          vector.paintStack=[.init(paint)];vector.productionRole=source.productionRole
          replacements.append(vector)
        }
        if replacements.count==1 {replacements=[]}
      } else {
        let paths = try TypographyEngine.outlinePaintRuns(source)
        let wrap =
          paths.count > 1
          && (source.hasActiveEffects || (source.blendMode ?? "normal") != "normal"
            || source.isolatedBlending == true || masks.contains(source.id)
            || (source.clipID != nil && ArtworkMasks.isCoverage(source.clipMode))
            || (source.opacity ?? 1) < 1 || (source.fillOpacity ?? 1) < 1)
        replacements = []
        var parentID = source.parentID
        if wrap {
          let group = wrapper(source, name: "\(source.title.prefix(450)) · outlines")
          replacements.append(group)
          parentID = group.id
          if (source.fillOpacity ?? 1) < 1 {
            var fills = ArtworkElement(
              kind: "group", x: 0, y: 0, width: source.width, height: source.height)
            fills.name = "Glyph fills"
            fills.contentSize = .init(source.width, source.height)
            fills.parentID = group.id
            fills.opacity = source.fillOpacity
            replacements.append(fills)
            parentID = fills.id
          }
        }
        for run in paths {
          var vector = try VectorGeometry.element(
            from: run.path, color: run.color,
            name: "\(source.title.prefix(450)) · outlines", parentID: parentID)
          vector.affine = wrap ? nil : source.localTransform
          vector.opacity = wrap ? nil : source.opacity
          vector.fillOpacity = wrap ? nil : source.fillOpacity
          vector.fillSwatchID = run.swatchID
          vector.blendMode = wrap ? nil : source.blendMode
          vector.blur = wrap ? nil : source.blur
          vector.shadow = wrap ? nil : source.shadow
          vector.effectStack = wrap ? nil : source.effectStack
          vector.isolatedBlending = wrap ? nil : source.isolatedBlending
          vector.productionRole = source.productionRole
          vector.clipID = wrap ? nil : source.clipID
          vector.clipMode = wrap ? nil : source.clipMode
          replacements.append(vector)
        }
      }
      guard !replacements.isEmpty else { continue }
      if masks.contains(source.id),mode != "shape" {
        guard let replacement=replacements.first else {continue}
        for i in result.elements.indices where result.elements[i].clipID==source.id {result.elements[i].clipID=replacement.id}
      }
      let index = result.elements.firstIndex { $0.id == source.id }!
      result.elements[index].hidden = true
      result.elements[index].name = "\(source.title.prefix(450)) · editable source"
      result.elements.insert(contentsOf: replacements, at: index + 1)
      created += replacements
    }
    guard !created.isEmpty else {
      throw FormError.invalid(
        mode == "shape"
          ? "Select geometric shapes to convert to paths."
          : mode == "stroke"
            ? "Select vector artwork with a visible stroke." : "Select text with visible glyphs.")
    }
    try validateArtwork(result)
    return (result, created)
  }
  private static func wrapper(_ e: ArtworkElement, name: String) -> ArtworkElement {
    var group = ArtworkElement(
      kind: "group", x: 0, y: 0, width: e.width, height: e.height, color: e.color)
    group.name = name
    group.parentID = e.parentID
    group.contentSize = .init(e.width, e.height)
    group.affine = e.localTransform
    group.opacity = e.opacity
    group.blendMode = e.blendMode
    group.blur = e.blur
    group.shadow = e.shadow
    group.effectStack = e.effectStack
    group.isolatedBlending = e.isolatedBlending
    group.clipID = e.clipID
    group.clipMode = e.clipMode
    group.productionRole = e.productionRole
    return group
  }
}

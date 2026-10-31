import AppKit
import CoreFoundation
import FormCore
import FormGraphics
import UniformTypeIdentifiers

extension StudioStore {
  func imageInfo(_ args: [String: Any]) throws -> Any {
    guard let p = project, let raw = args["object_id"] as? String, let id = UUID(uuidString: raw),
      let object = p.objects.first(where: { $0.id == id }), let art = p.surfaceArtwork(object) else {
      throw FormError.invalid("Choose an artwork frame or physical face.")
    }
    let requested = Set((args["element_ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
    let folder = repository.url(for: p.id).appendingPathComponent("Assets")
    let images: [[String: Any]] = art.elements.filter { $0.kind == "image" && (requested.isEmpty || requested.contains($0.id)) }.map { e in
      var result: [String: Any] = ["element_id": e.id.uuidString, "name": e.title,
        "crop": (try? jsonObject(e.imageCrop ?? .full)) ?? [:], "asset": e.asset ?? ""]
      if let asset = e.asset, let info = try? ImageRenderer.info(folder.appendingPathComponent(asset)) {
        let dpi = info.effectiveDPI(e, transform: art.worldTransform(e))
        result["original"] = try? jsonObject(info)
        result["effective_dpi"] = dpi
        result["below_300_dpi"] = dpi < 300
        result["below_150_dpi"] = dpi < 150
      } else { result["resolution"] = "Vector reference or unavailable pixel metadata" }
      return result
    }
    return ["images": images, "object_id": id.uuidString, "units": "physical millimeters; DPI includes crop and resolved surface transforms"]
  }

  func importImage(_ args: [String: Any], source: String = "Codex",
    placement: ((inout ArtworkElement) -> Void)? = nil,
    projection: CanvasSourceProjection? = nil) throws -> [String: Any] {
    guard let p = project, let raw = args["object_id"] as? String, let requestedID = UUID(uuidString: raw),
      let path = args["path"] as? String, path.hasPrefix("/") else {
      throw FormError.invalid("Choose an artwork target and an absolute local image path.")
    }
    var candidate = p
    var id = requestedID
    if let projection {
      guard requestedID == projection.sourceID,
        artworkSession.frames.first(where: { $0.id == projection.id })?.projection == projection,
        let physical = p.objects.first(where: { $0.id == projection.constructionID }) else {
        throw FormError.invalid("The image surface changed. Choose its destination again.")
      }
      guard !physical.locked else { throw FormError.invalid("Unlock the physical surface before importing an image.") }
      if projection.requiresInsideSource {
        guard projection.inside else { throw FormError.invalid("The blank image surface must be the inside face.") }
        id = try PaperCommands.ensureInside(in: &candidate, objectID: projection.constructionID)
      }
    }
    guard let object = candidate.objects.first(where: { $0.id == id }),
      object.supportsArtworkFace || object.isCanvasWorkspace else {
      throw FormError.invalid("Choose an artwork target or supported physical face.")
    }
    let owner = candidate.artworkOwner(object)
    guard !owner.locked else { throw FormError.invalid("Unlock the artwork source first.") }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.size] as? Int ?? Int.max) <= 50_000_000 else {
      throw FormError.invalid("Choose a regular image file under 50 MB.")
    }
    let existingFolder = repository.url(for:p.id).appendingPathComponent("Assets").resolvingSymlinksInPath()
    let existingAsset = url.deletingLastPathComponent().path == existingFolder.path
    if !existingAsset { ImageRenderer.invalidate(url) }
    let metadata = try? ImageRenderer.info(url)
    if metadata != nil { _ = try ImageRenderer.bitmap(url,requestedEdge:128) }
    let legacy = ["pdf","svg"].contains(url.pathExtension.lowercased()) ? NSImage(contentsOf: url) : nil
    guard metadata != nil || legacy != nil else { throw FormError.invalid("The image cannot be decoded, or exceeds 100 megapixels.") }
    let aspect = metadata?.aspect ?? Double(legacy!.size.width / max(1,legacy!.size.height))
    func number(_ key: String, _ fallback: Double) throws -> Double {
      guard let input = args[key] else { return fallback }
      guard let n = input as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
        throw FormError.invalid("Image placement values must be finite numbers.")
      }
      return n.doubleValue
    }
    var art = candidate.editableArtwork(object) ?? Artwork(background: "#FFFFFF")
    if candidate.editableArtwork(object) == nil { art.backgroundOpacity = 0; art.bleed = 0 }
    let placeholder = UUID().uuidString + "." + url.pathExtension.lowercased()
    let elementID: UUID
    if let raw = args["element_id"] {
      guard let raw = raw as? String, let replacement = UUID(uuidString: raw),
        let index = art.elements.firstIndex(where: { $0.id == replacement }),
        art.elements[index].kind == "image", !art.isLocked(art.elements[index]) else {
        throw FormError.invalid("Choose an unlocked image to replace.")
      }
      art.elements[index].asset = placeholder
      // A replacement has a different origin. Crop and transforms may retain
      // generation history, but swapping the source pixels must not mislabel it.
      art.elements[index].imageGeneration = nil
      if let info = metadata {
        let old = art.elements[index].imageCrop ?? .full
        let fitted = ImageCrop.filling(pixelWidth: Double(info.width),pixelHeight: Double(info.height),
          width: art.elements[index].width,height: art.elements[index].height)
        let w = fitted.width, h = fitted.height
        art.elements[index].imageCrop = .init(x: max(0,min(1-w,old.x+old.width/2-w/2)),
          y: max(0,min(1-h,old.y+old.height/2-h/2)),width:w,height:h)
      }
      elementID = replacement
    } else {
      let defaultWidth = owner.isCanvasWorkspace ? min(120,120*aspect)
        : min(owner.artworkSize.x*0.7,owner.artworkSize.y*0.7*aspect)
      let width = try number("width",defaultWidth), height = try number("height",width/aspect)
      var e = ArtworkElement(kind:"image",x:try number("x",owner.isCanvasWorkspace ? 0 : (owner.artworkSize.x-width)/2),
        y:try number("y",owner.isCanvasWorkspace ? 0 : (owner.artworkSize.y-height)/2),width:width,height:height,asset:placeholder)
      let originalName = existingAsset ? p.objects.compactMap(\.artwork).flatMap(\.elements)
        .first(where:{$0.asset == url.lastPathComponent && $0.name != nil})?.name.map{$0 + " copy"} : nil
      e.name = String((args["name"] as? String ?? originalName ?? url.lastPathComponent).prefix(500))
      if let raw = args["parent_id"] {
        guard let raw = raw as? String, let parent = UUID(uuidString: raw),
          let group = art.elements.first(where: { $0.id == parent }), group.kind == "group",
          group.component == nil, group.booleanOperation == nil, !art.isLocked(group) else {
          throw FormError.invalid("Choose an unlocked ordinary group for image placement.")
        }
        e.parentID = parent
        if args["x"] == nil { e.x = (group.paintSize.x - width) / 2 }
        if args["y"] == nil { e.y = (group.paintSize.y - height) / 2 }
      }
      let anchor = args["anchor"] as? String ?? "top-left"
      guard ["top-left","center"].contains(anchor) else { throw FormError.invalid("Choose top-left or center image placement.") }
      if anchor == "center" {
        if args["x"] != nil { e.x -= width/2 }
        if args["y"] != nil { e.y -= height/2 }
      }
      let fitted = ImageCrop.filling(pixelWidth: aspect,pixelHeight:1,width:width,height:height)
      if fitted != .full { e.imageCrop = fitted }
      placement?(&e)
      elementID = e.id; art.elements.append(e)
    }
    try candidate.setArtwork(art, for: id)
    try candidate.validateArtworkLinks()
    let asset = existingAsset ? url.lastPathComponent : try repository.importAsset(url, into: p.id)
    guard let index = art.elements.firstIndex(where: { $0.id == elementID }) else { throw FormError.missing("Image not found.") }
    art.elements[index].asset = asset
    do {
      try candidate.setArtwork(art, for: id)
      try engine.edit(args["element_id"] == nil ? "Place image" : "Replace image", source: source) { $0 = candidate }
    } catch {
      if !existingAsset { try? FileManager.default.removeItem(at: repository.url(for: p.id).appendingPathComponent("Assets").appendingPathComponent(asset)) }
      throw error
    }
    return ["selected_elements": [elementID.uuidString], "asset": asset, "object_id": owner.id.uuidString]
  }
}

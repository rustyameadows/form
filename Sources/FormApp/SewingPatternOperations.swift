import AppKit
import FormCore
import FormGraphics
import UniformTypeIdentifiers

extension StudioStore {
  func exportSewingPattern(object: ProductObject, arguments: [String: Any]) throws -> Any {
    guard arguments["roles"] == nil, arguments["fabric_pattern_material"] == nil,
      arguments["embroidery_format"] == nil, arguments["cut_layout"] as? Bool != true,
      arguments["ink_output"] == nil, arguments["layout_preflight"] == nil,
      arguments["include_fabric_preview"] == nil
    else {
      throw FormError.invalid(
        "Export sewing pattern pieces separately from fabric yardage, generic role layers, or embroidery programs."
      )
    }
    guard let project, let artwork = project.editableArtwork(object) else {
      throw FormError.missing("Choose a Canvas document containing sewing pattern pieces.")
    }
    var ids = Set<UUID>()
    if let raw = arguments["element_ids"] {
      guard let strings = raw as? [String] else {
        throw FormError.invalid("element_ids must be an array of UUIDs.")
      }
      ids = Set(strings.compactMap(UUID.init(uuidString:)))
      guard ids.count == strings.count, ids.isSubset(of: Set(artwork.elements.map(\.id))) else {
        throw FormError.invalid("Choose existing pattern piece IDs.")
      }
    }
    let output = try SewingPatternOutput(source: artwork, selection: ids)
    let assets = repository.url(for: project.id).appendingPathComponent("Assets")
    let format = arguments["format"] as? String ?? "pdf"
    let options = try SewingTileOptions.exportOptions(
      arguments["pattern_tiles"], saved: artwork.sewingTiles)
    let tiled = try options.map { try SewingTileOutput(source: output, options: $0) }
    if let tiled, format == "preflight" { return tiled.metadata }
    if tiled != nil, format != "pdf" {
      throw FormError.invalid(
        "Tiled sewing patterns export as PDF. Use the existing large-format route for SVG or raster output."
      )
    }
    let dpi: Double
    if let raw = arguments["dpi"] {
      guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw FormError.invalid("Pattern export DPI must be a number.")
      }
      dpi = number.doubleValue
    } else {
      dpi = 150
    }
    guard dpi.isFinite, (36...1200).contains(dpi) else {
      throw FormError.invalid("Choose 36–1200 DPI for pattern exports.")
    }
    let data: Data
    switch format {
    case "svg": data = Data(try output.svg(assets: assets).utf8)
    case "pdf":
      if let tiled {
        data = try tiled.pdf(assets: assets, dpi: dpi, name: object.name)
      } else {
        data = try output.pdf(assets: assets, dpi: dpi)
      }
    case "png", "jpeg":
      let image = try output.image(assets: assets, dpi: dpi)
      guard let rep = image.representations.first as? NSBitmapImageRep else {
        throw FormError.invalid("Could not render the sewing pattern.")
      }
      rep.size = .init(
        width: output.plan.frameSize.x * TypographyEngine.pointsPerMM,
        height: output.plan.frameSize.y * TypographyEngine.pointsPerMM)
      guard
        let encoded = rep.representation(
          using: format == "jpeg" ? .jpeg : .png, properties: [.compressionFactor: 0.94])
      else { throw FormError.invalid("Could not encode the pattern image.") }
      data = encoded
    default: throw FormError.invalid("Sewing patterns export as svg, pdf, png, or jpeg.")
    }
    let url: URL
    if let path = arguments["path"] as? String {
      guard path.hasPrefix("/") else { throw FormError.invalid("Export path must be absolute.") }
      url = URL(fileURLWithPath: path)
    } else {
      let folder = repository.url(for: project.id).appendingPathComponent("Exports")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      url = folder.appendingPathComponent(
        object.name.replacingOccurrences(of: "/", with: "-")
          + (tiled == nil ? "-sewing-pattern." : "-sewing-pattern-tiled.") + format)
    }
    try data.write(to: url, options: .atomic)
    var result = tiled?.metadata ?? output.metadata
    result["path"] = url.path
    result["format"] = format
    result["bytes"] = data.count
    return result
  }
  func createTotePattern() {
    do {
      let template = try SewingPatternTemplates.tote()
      var created: UUID?
      try engine.edit("Created tote cutting pattern", source: "Studio") { project in
        _ = try project.ensureCanvasWorkspace()
        var frame = try project.makeObject(
          recipeID: "artboard", name: "Everyday tote / cutting pattern",
          parameters: ["width": template.frameSize.x, "depth": template.frameSize.y])
        frame.artwork = template.artwork
        project.objects.append(frame)
        created = frame.id
      }
      changed()
      showSurface(.artwork)
      if let created {
        artworkSession.activate(created)
        DispatchQueue.main.async { self.artworkSession.canvas?.fit(all: false) }
      }
    } catch { self.error = error.localizedDescription }
  }
  func saveSewingSeam(_ seam: SewingSeam, objectID: UUID) throws {
    _ = try engine.call(
      "form_edit_artwork",
      arguments: [
        "object_id": objectID.uuidString, "command": "seam_pair", "seam": try jsonObject(seam),
      ])
    changed()
  }
}

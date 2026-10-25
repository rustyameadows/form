import AppKit
import FormCore
import FormGraphics

extension StudioStore {
  func exportSewingLayout(object: ProductObject, arguments: [String: Any]) throws -> Any {
    guard arguments["roles"] == nil, arguments["pattern_pieces"] as? Bool != true,
      arguments["fabric_pattern_material"] == nil, arguments["embroidery_format"] == nil else {
      throw FormError.invalid("Export cutting layouts separately from sewing templates, generic roles, fabric yardage, or embroidery programs.")
    }
    guard let project, let art = project.editableArtwork(object), let layout = art.sewingLayout else { throw FormError.missing("Save a cutting layout on this source document first.") }
    let report = try SewingLayouts.preflight(layout, source: art)
    if arguments["layout_preflight"] as? Bool == true { return report.metadata(layout: layout) }
    let material = project.material(layout.materialID)
    guard material.id == layout.materialID, material.fabric != nil else { throw FormError.invalid("Choose a known fabric material for this cutting layout.") }
    let includeFabric = arguments["include_fabric_preview"] as? Bool ?? false
    let fabric = try project.resolvedFabricPattern(materialID: layout.materialID)
    let output = try SewingLayoutOutput(layout: layout, source: art, fabric: fabric, fabricColor: material.color, includeFabricPreview: includeFabric)
    let assets = repository.url(for: project.id).appendingPathComponent("Assets")
    let format = arguments["format"] as? String ?? "pdf"
    let dpi: Double
    if let raw = arguments["dpi"] {
      guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw FormError.invalid("Cutting layout DPI must be a number.") }
      dpi = number.doubleValue
    } else { dpi = 150 }
    guard dpi.isFinite, (36...1200).contains(dpi) else { throw FormError.invalid("Choose 36–1200 DPI for cutting layout exports.") }
    let data: Data
    switch format {
    case "svg": data = Data(try output.svg(assets: assets).utf8)
    case "pdf": data = try output.pdf(assets: assets, dpi: dpi)
    case "png", "jpeg":
      let image = try output.image(assets: assets, dpi: dpi, fontRevision: GeometryFactory.fontRevision)
      guard let rep = image.representations.first as? NSBitmapImageRep,
        let encoded = rep.representation(using: format == "jpeg" ? .jpeg : .png, properties: [.compressionFactor: 0.94]) else { throw FormError.invalid("Could not encode the cutting layout.") }
      data = encoded
    default: throw FormError.invalid("Cutting layouts export as svg, pdf, png, or jpeg.")
    }
    let url: URL
    if let path = arguments["path"] as? String {
      guard path.hasPrefix("/") else { throw FormError.invalid("Export path must be absolute.") }; url = URL(fileURLWithPath: path)
    } else {
      let folder = repository.url(for: project.id).appendingPathComponent("Exports")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      url = folder.appendingPathComponent(layout.name.replacingOccurrences(of: "/", with: "-") + "." + format)
    }
    try data.write(to: url, options: .atomic)
    var result = output.metadata; result["path"] = url.path; result["format"] = format; result["bytes"] = data.count
    return result
  }
}

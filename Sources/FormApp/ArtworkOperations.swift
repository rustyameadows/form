import AppKit
import FormCore
import FormGraphics
import UniformTypeIdentifiers

extension StudioStore {
  func graphicsCall(_ name: String, _ args: [String: Any]) throws -> Any {
    if name == "form_import_svg" { return try importSVG(arguments: args) }
    if name == "form_list_fonts" {
      let query = (args["query"] as? String ?? "").lowercased()
      return [
        "families": FontCatalog.families.filter { query.isEmpty || $0.lowercased().contains(query) }
          .prefix(100).map {
            [
              "family": $0,
              "faces": FontCatalog.faces($0).map { ["name": $0.name, "style": $0.style] },
            ]
          }
      ]
    }
    if name == "form_font_features" {
      guard let font = args["font_name"] as? String else {
        throw FormError.invalid("font_name is required.")
      }
      return FontCatalog.details(font)
    }
    guard let raw = args["object_id"] as? String, let id = UUID(uuidString: raw), let project,
      let object = project.objects.first(where: { $0.id == id })
    else { throw FormError.missing("Choose an artwork object.") }
    if name == "form_export_artwork" { return try exportArtwork(object: object, arguments: args) }
    guard let rawIDs = args["element_ids"] as? [String], !rawIDs.isEmpty else {
      throw FormError.invalid("Select artwork element IDs.")
    }
    let ids = Set(rawIDs.compactMap(UUID.init(uuidString:)))
    let art = project.editableArtwork(object) ?? .init(background: "#FFFFFF")
    guard ids.count == rawIDs.count, ids.isSubset(of: Set(art.elements.map(\.id))) else {
      throw FormError.invalid("Unknown artwork element ID.")
    }
    var next = art
    var created: [ArtworkElement] = []
    if name == "form_convert_to_paths" {
      let stroke = args["mode"] as? String == "stroke"
      let all = art.descendants(of: ids)
      for e in art.elements
      where all.contains(e.id) && (stroke ? e.stroke != nil : e.kind == "text") && e.hidden != true
      {
        let paths: [(CGPath, String)] =
          stroke
          ? [(try VectorGeometry.expandedStroke(e), e.stroke!.color)]
          : try TypographyEngine.outlineRuns(e)
        for (path, color) in paths {
          var vector = try VectorGeometry.element(
            from: path, color: color, name: e.title + " · outlines", parentID: e.parentID)
          vector.affine = e.localTransform
          vector.opacity = e.opacity
          vector.fillOpacity = stroke ? e.stroke?.opacity : e.fillOpacity
          vector.productionRole = e.productionRole
          vector.clipID = e.clipID
          created.append(vector)
        }
        let index = next.elements.firstIndex { $0.id == e.id }!
        next.elements[index].hidden = true
        next.elements[index].name = e.title + " · editable source"
      }
      guard !created.isEmpty else {
        throw FormError.invalid(
          stroke
            ? "Select a vector object with a stroke." : "Select text with visible outline glyphs.")
      }
    } else if name == "form_boolean_artwork" {
      let selected = art.selectionRoots(ids)
      guard selected.count >= 2, Set(selected.map(\.parentID)).count == 1,
        selected.allSatisfy({
          ["rectangle", "ellipse", "polygon", "star", "path"].contains($0.kind)
        })
      else { throw FormError.invalid("Select two or more vector shapes in the same group.") }
      let operation = args["operation"] as? String ?? "union"
      func path(_ e: ArtworkElement) -> CGPath {
        var t = e.localTransform.cg
        return VectorGeometry.path(e).copy(using: &t)!.normalized(
          using: e.path?.evenOdd == true ? .evenOdd : .winding)
      }
      var result = path(selected[0])
      for e in selected.dropFirst() {
        switch operation {
        case "union": result = result.union(path(e), using: .winding)
        case "subtract": result = result.subtracting(path(e), using: .winding)
        case "intersect": result = result.intersection(path(e), using: .winding)
        case "exclude": result = result.symmetricDifference(path(e), using: .winding)
        default: throw FormError.invalid("Unknown boolean operation.")
        }
      }
      var vector = try VectorGeometry.element(
        from: result, color: selected.last!.color, name: operation.capitalized,
        parentID: selected[0].parentID)
      vector.path?.evenOdd = false
      created = [vector]
      for i in next.elements.indices where ids.contains(next.elements[i].id) {
        next.elements[i].hidden = true
      }
    } else {
      throw FormError.invalid("Unknown graphics operation.")
    }
    next.elements += created
    try validateArtwork(next)
    try engine.edit(
      "Artwork: \(name == "form_convert_to_paths" ? "convert to outlines":"combine paths")",
      source: "Graphics"
    ) { p in
      try p.setArtwork(next, for: object.id)
    }
    return [
      "selected_elements": created.map { $0.id.uuidString },
      "elements": try created.map { try jsonObject($0) },
    ]
  }
  func exportArtworkDialog(
    _ format: String, object: ProductObject, dpi: Double = 300, outlineText: Bool = true
  ) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = object.name + "." + format
    panel.allowedContentTypes = [
      format == "svg" ? .svg : format == "pdf" ? .pdf : format == "jpeg" ? .jpeg : .png
    ]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      _ = try exportArtwork(
        object: object,
        arguments: ["format": format, "path": url.path, "dpi": dpi, "outline_text": outlineText])
      toast("Artwork \(format.uppercased()) exported")
    } catch { self.error = error.localizedDescription }
  }
  func exportArtwork(object: ProductObject, arguments: [String: Any]) throws -> Any {
    guard let project else { throw FormError.missing("Open a project first.") }
    let format = arguments["format"] as? String ?? "svg"
    let dimensions = ArtworkDrawing.dimensions(object)
    let assets = repository.url(for: project.id).appendingPathComponent("Assets")
    var art = project.surfaceArtwork(object) ?? .init(background: "#FFFFFF")
    var width = dimensions.width
    var height = dimensions.height
    if let raw = arguments["element_ids"] as? [String], !raw.isEmpty {
      let ids = Set(raw.compactMap(UUID.init(uuidString:)))
      guard ids.count == raw.count else {
        throw FormError.invalid("Choose valid artwork elements.")
      }
      let exported = try art.exporting(ids)
      art = exported.artwork
      width = max(0.1, exported.bounds.width)
      height = max(0.1, exported.bounds.height)
    }
    let url: URL
    if let path = arguments["path"] as? String {
      guard path.hasPrefix("/") else { throw FormError.invalid("Export path must be absolute.") }
      url = URL(fileURLWithPath: path)
    } else {
      let folder = repository.url(for: project.id).appendingPathComponent("Exports")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      url = folder.appendingPathComponent(
        object.name.replacingOccurrences(of: "/", with: "-") + "-artwork." + format)
    }
    switch format {
    case "svg":
      try SVGRenderer.document(
        art, width: width, height: height, assets: assets,
        outlineText: arguments["outline_text"] as? Bool ?? true
      ).write(to: url, atomically: true, encoding: .utf8)
    case "pdf":
      var box = CGRect(
        x: 0, y: 0, width: width * TypographyEngine.pointsPerMM,
        height: height * TypographyEngine.pointsPerMM)
      let data = NSMutableData()
      guard let consumer = CGDataConsumer(data: data),
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)
      else { throw FormError.invalid("Could not create artwork PDF.") }
      context.beginPDFPage(
        [kCGPDFContextTrimBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
      context.translateBy(x: 0, y: box.height)
      context.scaleBy(x: TypographyEngine.pointsPerMM, y: -TypographyEngine.pointsPerMM)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
      ArtworkRenderer.draw(art, width: width, height: height, assets: assets)
      NSGraphicsContext.restoreGraphicsState()
      context.endPDFPage()
      context.closePDF()
      try (data as Data).write(to: url, options: .atomic)
    case "png", "jpeg":
      let dpi = arguments["dpi"] as? Double ?? 300
      guard dpi.isFinite, (36...1200).contains(dpi), width * dpi / 25.4 <= 16000,
        height * dpi / 25.4 <= 16000, width * height * pow(dpi / 25.4, 2) <= 100_000_000
      else {
        throw FormError.invalid(
          "Choose 36–1200 DPI with no more than 100 megapixels or 16000 pixels per edge.")
      }
      let image = ArtworkRenderer.image(
        art, width: width, height: height, assets: assets, pixelsPerMM: dpi / 25.4,
        opaqueBackground: format == "jpeg")
      guard let bitmap = image.representations.first as? NSBitmapImageRep else {
        throw FormError.invalid("Raster export failed.")
      }
      bitmap.size = .init(
        width: width * TypographyEngine.pointsPerMM, height: height * TypographyEngine.pointsPerMM)
      guard
        let data = bitmap.representation(
          using: format == "jpeg" ? .jpeg : .png, properties: [.compressionFactor: 0.94])
      else { throw FormError.invalid("Raster encoding failed.") }
      try data.write(to: url, options: .atomic)
    default: throw FormError.invalid("Artwork format must be svg, pdf, png, or jpeg.")
    }
    return [
      "path": url.path, "format": format, "width_mm": width, "height_mm": height,
      "bytes": (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0,
    ]
  }
}

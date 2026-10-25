import AppKit
import FormCore
import FormGraphics
import UniformTypeIdentifiers

extension StudioStore {
  func exportDialog(_ format: String, object: ProductObject? = nil) {
    guard let project else { return }
    let object = object ?? primary
    let panel = NSSavePanel()
    panel.nameFieldStringValue =
      (format == "png" || format == "json" ? project.name : object?.name ?? project.name) + "."
      + format
    panel.allowedContentTypes = [
      format == "png" ? .png : format == "pdf" ? .pdf : format == "svg" ? .svg : .json
    ]
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      do {
        var args: [String: Any] = ["path": url.path]
        if let object { args["object_id"] = object.id.uuidString }
        _ = try export(format: format, arguments: args)
        toast("\(format.uppercased()) exported")
      } catch { self.error = error.localizedDescription }
    }
  }
  func export(format: String, arguments: [String: Any]) throws -> Any {
    guard let project else { throw FormError.missing("Open a project before exporting.") }
    let object: ProductObject?
    if let raw = arguments["object_id"] as? String {
      guard
        let found = project.objects.first(where: {
          $0.id.uuidString.lowercased() == raw.lowercased()
        })
      else { throw FormError.missing("Object not found.") }
      object = found
    } else {
      object = primary
    }
    let output: URL
    if let path = arguments["path"] as? String {
      guard path.hasPrefix("/") else { throw FormError.invalid("Export path must be absolute.") }
      output = URL(fileURLWithPath: path)
    } else {
      let folder = repository.url(for: project.id).appendingPathComponent("Exports")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let title = (object?.name ?? project.name).replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
      output = folder.appendingPathComponent(title + "." + format)
    }
    switch format {
    case "png":
      let assets=repository.url(for:project.id).appendingPathComponent("Assets")
      for o in project.objects where isolated.isEmpty || isolated.contains(o.id) {
        if let art=project.surfaceArtwork(o) { try ArtworkRenderer.validateGlyphOutput(art,assets:assets) }
      }
      synchronizeScene()
      let image: NSImage
      if let scene {
        image = scene.snapshot(size: CGSize(width: 3000, height: 2000))
      } else {
        image = TableSceneController.preview(
          project: project, size: CGSize(width: 3000, height: 2000),
          assets: repository.url(for: project.id).appendingPathComponent("Assets"), studio: true,
          preset: studioPreset)
      }
      guard let data = image.pngData() else { throw FormError.invalid("Image rendering failed.") }
      try data.write(to: output, options: .atomic)
    case "svg":
      if let object, object.recipeID == "clock" {
        try ClockDesign.profileSVG(object).write(to: output, atomically: true, encoding: .utf8)
        break
      }
      guard let object, object.recipeID == "sleeve" else {
        throw FormError.invalid("Select a folding sleeve or clock to export its cut profile.")
      }
      var surface = object
      surface.artwork = project.surfaceArtwork(object)
      try Dieline.svg(
        surface, assets: repository.url(for: project.id).appendingPathComponent("Assets")
      ).write(to: output, atomically: true, encoding: .utf8)
    case "pdf":
      guard let object else { throw FormError.invalid("Select a printable object first.") }
      let art =
        project.surfaceArtwork(object)
        ?? Artwork(background: project.material(object.materialID).color)
      let size = ArtworkDrawing.dimensions(object)
      guard object.supportsArtworkFace else {
        throw FormError.invalid("This object has no printable face.")
      }
      try exportPDF(
        art, width: size.width, height: size.height,
        assets: repository.url(for: project.id).appendingPathComponent("Assets"), to: output)
    case "json":
      let components: [[String: Any]] = project.objects.map { object in
        [
          "id": object.id.uuidString, "name": object.name, "recipe": object.recipeID,
          "parameters": object.parameters, "material": project.material(object.materialID).name,
          "material_id": object.materialID,
          "color": object.color ?? project.material(object.materialID).color,
          "design_id": object.designID.uuidString, "relationship": object.relationship,
        ]
      }
      let summary: [String: Any] = [
        "project": project.name, "units": "mm", "components": components,
        "decisions": try jsonObject(project.notes), "equipment": try jsonObject(library.equipment),
        "notes":
          "Prototype output. Check physical material thickness, clearances, and printer scaling before fabrication.",
      ]
      try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        .write(to: output, options: .atomic)
    default: throw FormError.invalid("Export format must be png, pdf, svg, or json.")
    }
    return [
      "path": output.path, "format": format,
      "bytes": (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0,
    ]
  }
  private func exportPDF(_ art: Artwork, width: Double, height: Double, assets: URL, to url: URL)
    throws
  {
    try ArtworkRenderer.validateAppearanceOutput(art,assets:assets,pixelsPerMM:300/25.4)
    let pointsPerMM = 72.0 / 25.4
    let bleed = art.bleed
    var mediaBox = CGRect(
      x: 0, y: 0, width: (width + 2 * bleed) * pointsPerMM,
      height: (height + 2 * bleed) * pointsPerMM)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else { throw FormError.invalid("Could not create PDF.") }
    context.beginPDFPage(nil)
    context.translateBy(x: 0, y: mediaBox.height)
    context.scaleBy(x: pointsPerMM, y: -pointsPerMM)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    NSColor(hex: art.background).setFill()
    NSRect(x: 0, y: 0, width: width + 2 * bleed, height: height + 2 * bleed).fill()
    context.translateBy(x: bleed, y: bleed)
    ArtworkDrawing.draw(art, width: width, height: height, assets: assets)
    if bleed >= 2 {
      NSColor.black.setStroke()
      let marks = NSBezierPath()
      marks.lineWidth = 0.15
      for x in [0.0, width] {
        for y in [0.0, height] {
          let sx = x == 0 ? -1.0 : 1.0
          let sy = y == 0 ? -1.0 : 1.0
          marks.move(to: .init(x: x + sx * 0.7, y: y))
          marks.line(to: .init(x: x + sx * (bleed - 0.3), y: y))
          marks.move(to: .init(x: x, y: y + sy * 0.7))
          marks.line(to: .init(x: x, y: y + sy * (bleed - 0.3)))
        }
      }
      marks.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
    try profiledArtworkPDF(data as Data, artwork: art, assets: assets, title: "FORM artwork")
      .write(to: url, options: .atomic)
  }
}

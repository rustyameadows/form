import AppKit
import CoreFoundation
import FormCore
import FormGraphics
import UniformTypeIdentifiers

extension StudioStore {
  func graphicsCall(_ name: String, _ args: [String: Any]) throws -> Any {
    if name == "form_model_asset" {return try modelAssets.call(args)}
    if name == "form_cad" {return try cad.call(name,args)}
    if ArtworkTransferCommands.recognizes(name,args) {return try artworkTransferCall(args)}
    if name == "form_cloth" {return try clothCall(args)}
    if ["form_textile_stock","form_production_job"].contains(name) {return try productionCall(name,arguments:args)}
    if ["form_story","form_publication","form_export_publication"].contains(name) {return try publicationGraphicsCall(name,args)}
    if name == "form_color_profile" { return try colorProfileCall(args) }
    if name == "form_import_image" { return try importImage(args) }
    if name == "form_image_info" { return try imageInfo(args) }
    if name == "form_import_svg" { return try importSVG(arguments: args) }
    if name == "form_list_fonts" {return try fontLibraryCall(args)}
    if name == "form_replace_font" {return try replaceFontCall(args)}
    if name == "form_font_features" {
      guard let font = args["font_name"] as? String else {
        throw FormError.invalid("font_name is required.")
      }
      func integer(_ key: String, default fallback: Int) throws -> Int {
        guard let value = args[key] else { return fallback }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
          n.doubleValue.isFinite, n.doubleValue == n.doubleValue.rounded(),
          n.doubleValue >= 0, n.doubleValue <= 65536 else { throw FormError.invalid("Use a nonnegative integer for \(key).") }
        return n.intValue
      }
      switch args["command"] as? String ?? "features" {
      case "features": return FontCatalog.details(font)
      case "glyphs":
        return try GlyphCatalog.repertoire(fontName: font, query: args["query"] as? String ?? "",
          offset: integer("offset", default: 0), limit: integer("limit", default: 64))
      case "alternates":
        guard let text = args["text"] as? String else { throw FormError.invalid("Provide source text for alternate discovery.") }
        let style = try args["typography"].map { try JSONDecoder.form.decode(Typography.self,
          from: JSONSerialization.data(withJSONObject: $0)) } ?? Typography()
        let range = try NSRange(location: integer("location", default: 0), length: integer("length", default: text.utf16.count))
        let points:Double
        if let raw=args["font_size"] {
          guard let value=raw as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),value.doubleValue.isFinite,(0.1...10000).contains(value.doubleValue) else{throw FormError.invalid("Use finite 0.1–10000 nominal document points for alternate shaping.")}
          points=value.doubleValue
        }else{points=48}
        let options = try GlyphCatalog.alternates(fontName:font,text:text,range:range,typography:style,pointSize:points)
        return ["font_name": font, "location": range.location, "length": range.length, "glyphs": options.map(\.json)]
      default: throw FormError.invalid("Font discovery command must be features, glyphs, or alternates.")
      }
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
    let colored = project.resolvingSwatches(in:project.resolvingTextStories(in:art,objectID:project.artworkOwner(object).id), keepingReferences: true)
    var created: [ArtworkElement] = []
    if name == "form_convert_to_paths" {
      guard !project.artworkOwner(object).locked else { throw FormError.invalid("Unlock this artwork object first.") }
      let conversion = try ArtworkOutlines.convert(art, ids: ids, mode: args["mode"] as? String ?? "text", resolvedPaint: colored)
      next = conversion.artwork
      created = conversion.created
    } else if name == "form_boolean_artwork" {
      return try editBoolean(object: object, artwork: art, ids: ids, arguments: args)
    } else {
      throw FormError.invalid("Unknown graphics operation.")
    }
    try validateArtwork(next)
    try engine.edit(
      "Artwork: \(name == "form_convert_to_paths" ? "convert to outlines":"combine paths")",
      source: "Graphics"
    ) { p in
      try p.setArtwork(next, for: object.id)
    }
    return [
      "selected_elements": next.selectionRoots(Set(created.map(\.id))).map { $0.id.uuidString },
      "elements": try created.map { try jsonObject($0) },
    ]
  }
  func exportArtworkDialog(
    _ format: String, object: ProductObject, dpi: Double = 300, outlineText: Bool = true,
    elementIDs:Set<UUID> = [], roles:[String]? = nil
  ) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = object.name + "." + format
    panel.allowedContentTypes = [
      format == "svg" ? .svg : format == "pdf" ? .pdf : format == "jpeg" ? .jpeg : .png
    ]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      var arguments:[String:Any] = ["format":format,"path":url.path,"dpi":dpi,"outline_text":outlineText]
      if !elementIDs.isEmpty { arguments["element_ids"] = elementIDs.map(\.uuidString) }
      if let roles {arguments["roles"] = roles}
      _ = try exportArtwork(object:object,arguments:arguments)
      toast("Artwork \(format.uppercased()) exported")
    } catch { self.error = error.localizedDescription }
  }
  func exportArtwork(object suppliedObject: ProductObject, arguments: [String: Any]) throws -> Any {
    guard let object=self.project?.objects.first(where:{$0.id==suppliedObject.id}) else{throw FormError.missing("Choose an existing artwork object.")}
    guard object.meshAsset==nil else{throw FormError.invalid("UV placement has no verified physical scale. Export the original artwork frame for physical output, or use a scene PNG for the model preview.")}
    if arguments["page_output"] != nil {return try exportArtworkPage(objectID:object.id,arguments:arguments)}
    if arguments["pattern_tiles"] != nil, arguments["pattern_pieces"] as? Bool != true { throw FormError.invalid("Use pattern_tiles only with pattern_pieces:true for sewing template PDF output.") }
    if let value=arguments["ink_output"] {
      guard let mode=value as? String else{throw FormError.invalid("ink_output must be preview, composite, plates, or preflight.")}
      let conflict=arguments["embroidery_format"] != nil || arguments["fabric_pattern_material"] != nil || arguments["cut_layout"] as? Bool==true || arguments["pattern_pieces"] as? Bool==true
      guard !conflict,["pdf","svg","png","jpeg"].contains(arguments["format"] as? String ?? "") else{throw FormError.invalid("Choose production ink output separately from embroidery, pattern pieces and cutting layouts.")}
      if mode != "preview" {return try exportProductionInks(object,arguments:arguments)}
    }
    if arguments["cut_layout"] as? Bool == true { return try exportSewingLayout(object: object, arguments: arguments) }
    if arguments["pattern_pieces"] as? Bool == true { return try exportSewingPattern(object: object, arguments: arguments) }
    if arguments["embroidery_format"] != nil || ["dst","json","preflight"].contains(arguments["format"] as? String ?? "") {
      return try exportEmbroidery(object:object,arguments:arguments)
    }
    if let materialID = arguments["fabric_pattern_material"] as? String {
      return try exportFabricPattern(materialID: materialID, arguments: arguments)
    }
    if arguments["roles"] != nil {return try exportProductionArtwork(object:object,arguments:arguments)}
    guard !MerchandiseBlanks.garmentIDs.contains(object.recipeID) else {throw FormError.invalid("Choose an independent decoration region or its artwork source for physical artwork export. Use the scene export for a garment preview.")}
    guard let project else { throw FormError.missing("Open a project first.") }
    let format = arguments["format"] as? String ?? "svg"
    let dimensions = ArtworkDrawing.dimensions(object)
    let assets = repository.url(for: project.id).appendingPathComponent("Assets")
    if object.isCanvasWorkspace,(arguments["element_ids"] as? [String])?.isEmpty != false {
      throw FormError.invalid("Select Canvas artwork to export, or place it on a physical frame.")
    }
    var art = (object.isCanvasWorkspace ? project.editableArtwork(object) : project.surfaceArtwork(object,keepingSwatchReferences:format=="pdf")) ?? .init(background:"#FFFFFF")
    if object.isCanvasWorkspace {art=try project.resolvingComponents(in:art,keepingSwatchReferences:true)}
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
    let declaredInks=project.hasUsedProductionInks(in:art) || (format != "pdf" && art.requiresInkOutput)
    if format=="pdf" {art.requiresInkOutput=declaredInks}
    art=project.resolvingSwatches(in:art,keepingReferences:format=="pdf")
    if format=="pdf",declaredInks,arguments["ink_output"] as? String != "preview" {throw FormError.invalid("This artwork declares production inks. Choose ink_output preview, composite, plates, or preflight explicitly.")}
    if arguments["ink_output"] as? String=="preview" {art.outputColorProfile=nil;art.requiresInkOutput=false}
    // Resolve live geometry before opening/writing a production output.
    art = try BooleanGeometry.materialized(art)
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
      let dpi = try artworkExportDPI(arguments)
      guard dpi.isFinite, (36...1200).contains(dpi) else { throw FormError.invalid("Choose 36–1200 DPI for PDF effects.") }
      try ArtworkRenderer.validateAppearanceOutput(art, assets: assets, pixelsPerMM: dpi / 25.4)
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
      ArtworkRenderer.draw(art, width: width, height: height, assets: assets, effectScale: dpi / 25.4)
      NSGraphicsContext.restoreGraphicsState()
      context.endPDFPage()
      context.closePDF()
      try profiledArtworkPDF(data as Data, artwork: art, assets: assets, title: object.name)
        .write(to: url, options: .atomic)
    case "png", "jpeg":
      let dpi = try artworkExportDPI(arguments)
      guard dpi.isFinite, (36...1200).contains(dpi), width * dpi / 25.4 <= 16000,
        height * dpi / 25.4 <= 16000, width * height * pow(dpi / 25.4, 2) <= 100_000_000
      else {
        throw FormError.invalid(
          "Choose 36–1200 DPI with no more than 100 megapixels or 16000 pixels per edge.")
      }
      try ArtworkRenderer.validateAppearanceOutput(art, assets: assets, pixelsPerMM: dpi / 25.4)
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
    var result: [String: Any] = [
      "path": url.path, "format": format, "width_mm": width, "height_mm": height,
      "bytes": (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0,
      "composed_text_outlined": format == "svg" && arguments["outline_text"] as? Bool == false
        ? art.elements.filter { $0.kind == "text" && $0.hidden != true && TypographyEngine.requiresComposedOutlines($0) }.count : 0,
    ]
    let opticalFallback=format=="svg" && arguments["outline_text"] as? Bool==false ? art.elements.filter{$0.kind=="text" && $0.hidden != true && OpticalTypography.requiresOutlines($0)}.count:0
    let positionFallback=format=="svg" && arguments["outline_text"] as? Bool==false ? art.elements.filter{$0.kind=="text" && $0.hidden != true && CharacterTypography.requiresOutlines($0)}.count:0
    let capsFallback=format=="svg" && arguments["outline_text"] as? Bool==false ? art.elements.filter{$0.kind=="text" && $0.hidden != true && SmallCapsTypography.requiresOutlines($0)}.count:0
    result["character_position_text_outlined"]=positionFallback;result["character_position_warnings"]=CharacterTypography.warnings(art)
    result["small_caps_text_outlined"]=capsFallback;result["small_caps_warnings"]=SmallCapsTypography.warnings(art)
    if positionFallback>0 || capsFallback>0 {result["character_forms_fallback"]="Character position and small caps use shared native outlines for faithful font forms and geometric fallback; source words stay editable."}
    result["optical_text_outlined"]=opticalFallback
    result["optical_sizing_warnings"]=OpticalTypography.warnings(art)
    if opticalFallback>0 {result["optical_sizing_fallback"]="Optical-sizing text uses shared native outlines for precise SVG metrics; source text stays editable in LAB."}
    if declaredInks {result["ink_output"]="preview";result["ink_declarations_encoded"]=false;result["ink_notice"]="sRGB appearance preview; named/process ink declarations are not encoded in this output."}
    result["color_space"] = format == "pdf" ? art.outputColorProfile?.model ?? "sRGB" : "sRGB"
    if format == "pdf", let profile = art.outputColorProfile {
      result["pdf_output_profile"] = try jsonObject(profile)
    }
    return result
  }
}

private func artworkExportDPI(_ arguments: [String: Any]) throws -> Double {
  guard let raw = arguments["dpi"] else { return 300 }
  guard let number = raw as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
  else { throw FormError.invalid("Choose a finite numeric DPI value.") }
  return number.doubleValue
}

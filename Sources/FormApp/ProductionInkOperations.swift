import AppKit
import FormCore
import FormGraphics

extension StudioStore {
  func prepareProductionSwatch(_ project:Project,_ swatch:inout ArtworkSwatch) throws {
    guard let ink=swatch.printInk else{return}
    try ink.validate()
    let assets=repository.url(for:project.id).appendingPathComponent("Assets")
    swatch.color=try ICCOutputProfile(reference:ink.profile,assets:assets).inkPreview(ink)
  }
}

extension StudioStore {
  func inkPrintPage(_ suppliedObject:ProductObject,arguments:[String:Any]) throws -> InkPrintPage {
    guard let project else{throw FormError.missing("Open a project first.")}
    guard let object=project.objects.first(where:{$0.id==suppliedObject.id}) else{throw FormError.missing("Choose an existing artwork object.")}
    let owner=project.artworkOwner(object)
    let raw:Artwork
    if object.isCanvasWorkspace {
      guard let source=project.editableArtwork(object) else{throw FormError.missing("Canvas artwork is missing.")}
      raw=try project.resolvingComponents(in:project.resolvingTextStories(in:source,objectID:owner.id),keepingSwatchReferences:true)
    } else {guard let source=project.surfaceArtwork(object,keepingSwatchReferences:true) else{throw FormError.missing("Choose an object with a flat physical artwork surface.")};raw=source}
    var art=raw,width=object.artworkSize.x,height=object.artworkSize.y
    if let supplied=arguments["element_ids"] {
      guard let values=supplied as? [String] else{throw FormError.invalid("Choose artwork element UUIDs.")}
      let ids=Set(values.compactMap(UUID.init(uuidString:)))
      guard ids.count==values.count else{throw FormError.invalid("Choose distinct existing artwork elements.")}
      if !ids.isEmpty {let exported=try art.exporting(ids);art=exported.artwork;width=max(0.1,exported.bounds.width);height=max(0.1,exported.bounds.height)}
      else if object.isCanvasWorkspace {throw FormError.invalid("Select Canvas artwork or place it on a physical frame before ink output.")}
    } else if object.isCanvasWorkspace {throw FormError.invalid("Select Canvas artwork or place it on a physical frame before ink output.")}
    art.requiresInkOutput=project.hasUsedProductionInks(in:art)
    return .init(id:object.id,name:object.name,artwork:art,width:width,height:height)
  }
  func inkPublicationPages(_ id:UUID) throws -> [InkPrintPage] {
    guard let project,let document=project.publications?.first(where:{$0.id==id}) else{throw FormError.missing("Choose an existing publication.")}
    return try document.pages.map{page in
      guard let object=project.objects.first(where:{$0.id==page.objectID}) else{throw FormError.missing("A publication page is missing.")}
      return try inkPrintPage(object,arguments:[:])
    }
  }
  func exportProductionInks(_ object:ProductObject,arguments:[String:Any]) throws -> Any {
    guard let project,let name=arguments["ink_output"] as? String,let mode=InkOutputMode(rawValue:name),mode != .preview else{throw FormError.invalid("Choose an explicit production ink_output mode: composite, plates, or preflight.")}
    if let roles=arguments["roles"] {guard try ArtworkProduction.parseRoles(roles)==[.print] else{throw FormError.invalid("Export print ink colorants separately from technical production-role geometry.")}}
    let page=try inkPrintPage(object,arguments:arguments),assets=repository.url(for:project.id).appendingPathComponent("Assets")
    if mode == .preflight {return ProductionInkPDF.preflight(project:project,pages:[page],assets:assets)}
    guard arguments["format"] as? String=="pdf" else{throw FormError.invalid("Composite and digital ink maps require PDF output. Raster/SVG are preview only.")}
    let output=try ProductionInkPDF.export(project:project,pages:[page],assets:assets,mode:mode,title:object.name)
    return try writeProductionInkPDF(output.data,report:output.report,name:object.name,mode:mode,arguments:arguments)
  }
  func writeProductionInkPDF(_ data:Data,report:[String:Any],name:String,mode:InkOutputMode,arguments:[String:Any]) throws -> [String:Any] {
    guard let project else{throw FormError.missing("Open a project first.")}
    let url:URL
    if let path=arguments["path"] as? String {
      guard path.hasPrefix("/"),URL(fileURLWithPath:path).pathExtension.lowercased()=="pdf" else{throw FormError.invalid("Choose an absolute path ending in .pdf.")};url=URL(fileURLWithPath:path)
    } else {
      let folder=repository.url(for:project.id).appendingPathComponent("Exports");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      url=folder.appendingPathComponent(name.replacingOccurrences(of:"/",with:"-")+"-"+mode.rawValue+".pdf")
    }
    try data.write(to:url,options:.atomic)
    var value=report;value["path"]=url.path;value["format"]="pdf";value["bytes"]=data.count;return value
  }
  func preflightInkHandoff(_ name:String,_ arguments:[String:Any]) throws {
    let operations=arguments["operations"] as? [[String:Any]] ?? []
    let relevant=name=="form_swatch" || (name=="form_batch" && operations.contains{$0["name"] as? String=="form_swatch"})
    guard relevant,artworkSession.editingText else{return}
    guard artworkSession.canvas?.hasMarkedTextInput != true else{throw FormError.invalid("Finish the current text input before editing ink swatches.")}
    let mirror=OperationEngine(repository:repository);mirror.project=project;mirror.selection=engine.selection
    mirror.onPrepareSwatch=engine.onPrepareSwatch;mirror.onPrepareGlyph=engine.onPrepareGlyph;mirror.onPrepareParagraphs=engine.onPrepareParagraphs
    mirror.onGraphics={_,_ in throw FormError.invalid("Finish text editing before combining graphics and ink-palette operations in one batch.")}
    _ = try mirror.call(name,arguments:arguments,source:"Validation")
  }
}

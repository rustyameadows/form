import AppKit
import FormCore
import CoreFoundation
import FormGraphics

extension StudioStore {
  func artworkPageWarnings(_ art:Artwork)->[String:[String]] {
    ["font_warnings":FontCatalog.missing(in:art).map{"Missing assigned font \($0); source assignment is retained and the established preview fallback is used."},
     "optical_sizing_warnings":OpticalTypography.warnings(art),
     "character_position_warnings":CharacterTypography.warnings(art),
     "small_caps_warnings":SmallCapsTypography.warnings(art)]
  }
  func pageOutputSource(objectID:UUID,arguments:[String:Any])throws->(ProductObject,Artwork,ArtworkPageGeometry,URL,Bool,Double) {
    guard let project else{throw FormError.missing("Open a project first.")}
    guard Set(arguments.keys).isSubset(of:["object_id","format","path","page_output","dpi","outline_text","ink_output"]) else{throw FormError.invalid("Choose page output without unrelated or unsupported export selectors.")}
    if let value=arguments["format"],!(value is String) {throw FormError.invalid("Page output format must be pdf or preflight.")}
    if let value=arguments["outline_text"] {guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{throw FormError.invalid("outline_text must be Boolean.")}}
    let format=arguments["format"] as? String ?? "pdf"
    if format=="preflight",arguments["path"] != nil {throw FormError.invalid("Page preflight returns geometry without a destination file.")}
    guard ["pdf","preflight"].contains(format),let raw=arguments["page_output"] else{throw FormError.invalid("Explicit page_output supports PDF or source-only preflight.")}
    let conflicts=["element_ids","roles","pattern_tiles","pattern_pieces","cut_layout","embroidery_format","fabric_pattern_material"]
    guard !conflicts.contains(where:{arguments[$0] != nil}),arguments["ink_output"]==nil || arguments["ink_output"] as? String=="preview" else{throw FormError.invalid("Page output requires one complete rectangular frame, separate from selections, roles, sewing, pattern, embroidery and production-ink modes. Explicit ink_output preview is the only declared-ink option here.")}
    let options=try ArtworkPageSetup.options(raw),object=try ArtworkPageSetup.source(project,objectID:objectID)
    let geometry=try ArtworkPageGeometry(width:object.artworkSize.x,height:object.artworkSize.y,bleed:object.artwork!.bleed,safeInset:object.artwork!.safeInset,options:options)
    let dpi=try arguments["dpi"].map{try ArtworkPageSetup.number($0,"DPI")} ?? 300
    guard (36...1200).contains(dpi) else{throw FormError.invalid("Choose 36–1200 DPI for PDF appearance effects.")}
    // Metadata/box validation comes before source expansion and any asset read.
    let preview=arguments["ink_output"] as? String=="preview"
    var art=project.surfaceArtwork(object,keepingSwatchReferences:true) ?? object.artwork!
    _ = try ArtworkPageSetup.sourceWorkload(art)
    let inks=project.hasUsedProductionInks(in:art) || art.requiresInkOutput
    guard !inks || preview else{throw FormError.invalid("This frame uses declared production inks. Choose explicit ink_output preview or the established composite/plate workflow without page_output.")}
    art=project.resolvingSwatches(in:art,keepingReferences:false)
    if preview {art.outputColorProfile=nil};art.requiresInkOutput=false
    let assets=repository.url(for:project.id).appendingPathComponent("Assets")
    return(object,art,geometry,assets,inks,dpi)
  }
  func exportArtworkPage(objectID:UUID,arguments:[String:Any])throws->Any {
    let(object,art,g,assets,inks,dpi)=try pageOutputSource(objectID:objectID,arguments:arguments)
    var report=g.metadata
    report["source_workload"]=try ArtworkPageSetup.sourceWorkload(art)
    report["object_id"]=object.id.uuidString;report["safe_inset_mm"]=object.artwork!.safeInset as Any? ?? NSNull()
    report["source_only_preflight"]=arguments["format"] as? String=="preflight"
    report["validation_scope"]="Canonical source, selectors, declared ink intent and physical page geometry. Appearance/assets are validated when rendering a PDF; missing font assignments retain the established fallback and are reported."
    report["appearance_validated"]=false;report["assets_validated"]=false
    report["source_profile"]=try object.artwork!.outputColorProfile.map{try jsonObject($0)} as Any? ?? NSNull()
    report["pdf_output_profile"]=try art.outputColorProfile.map{try jsonObject($0)} as Any? ?? NSNull()
    report["ink_output"]=inks ? "preview":"none";report["ink_declarations_encoded"]=false
    if inks {report["ink_notice"]="Explicit sRGB appearance preview; declared spot/process originals remain in source and are not encoded by page_output."}
    if arguments["format"] as? String=="preflight" {return report}
    let path:URL
    if let value=arguments["path"] {
      guard let raw=value as? String,raw.hasPrefix("/"),raw.utf8.count<=4096 else{throw FormError.invalid("Use a bounded absolute PDF export path.")};path=URL(fileURLWithPath:raw)
    }else {
      let folder=assets.deletingLastPathComponent().appendingPathComponent("Exports");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      path=folder.appendingPathComponent(object.name.replacingOccurrences(of:"/",with:"-")+"-page.pdf")
    }
    let data=try ArtworkPagePDF.pdf(art,geometry:g,assets:assets,dpi:dpi,outlineText:arguments["outline_text"] as? Bool ?? false,title:object.name)
    try data.write(to:path,options:.atomic)
    report["path"]=path.path;report["format"]="pdf";report["bytes"]=data.count;report["appearance_validated"]=true;report["assets_validated"]=true
    for (key,values) in artworkPageWarnings(art) {report[key]=values}
    report["color_space"]=art.outputColorProfile?.model ?? "sRGB";return report
  }
  func preflightPageSetupHandoff(_ name:String,_ args:[String:Any])throws {
    func targeted(_ name:String,_ args:[String:Any])->Bool {
      (name=="form_edit_artwork" && args["command"] as? String=="page_setup") || (name=="form_set_artwork" && (args["artwork"] as? [String:Any])?.keys.contains("safeInset")==true) || (name=="form_export_artwork" && args["page_output"] != nil)
    }
    guard targeted(name,args) || (name=="form_batch" && (args["operations"] as? [[String:Any]] ?? []).contains{targeted($0["name"] as? String ?? "",$0["arguments"] as? [String:Any] ?? [:])}) else{return}
    guard artworkSession.canvas?.hasMarkedTextInput != true else{throw FormError.invalid("Finish marked text input before applying page setup.")}
    let mirror=OperationEngine(repository:repository);mirror.project=project;mirror.selection=engine.selection
    mirror.onPrepareParagraphs=engine.onPrepareParagraphs;mirror.onPrepareGlyph=engine.onPrepareGlyph;mirror.onPrepareOptical=engine.onPrepareOptical;mirror.onPrepareSwatch=engine.onPrepareSwatch;mirror.onValidatePaint=engine.onValidatePaint
    mirror.onGraphics={_,_ in throw FormError.invalid("Review page setup separately from graphics mutations in a batch while input is active.")}
    _ = try mirror.call(name,arguments:args,source:"Validation")
  }
}

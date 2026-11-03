import AppKit
import FormCore
import FormGraphics

extension StudioStore {
  /// Targeted saved-scene writes must reject stale revisions and malformed
  /// selectors before the general bridge handoff can finish a Canvas draft.
  func preflightStudioPoseHandoff(_ name:String,_ arguments:[String:Any]) throws {
    guard name=="form_studio_scene",["pose_update","pose_reset"].contains(arguments["command"] as? String ?? "") else{return}
    if let raw=arguments["scene_id"] as? String,let sceneID=UUID(uuidString:raw),
      studioComposition.contextProjectID==project?.id,studioComposition.draft?.id==sceneID,studioComposition.dirty {
      throw FormError.invalid("Save or discard this native Studio draft before editing its saved publication pose.")
    }
    let mirror=OperationEngine(repository:repository);mirror.project=project;mirror.selection=engine.selection
    _=try mirror.call(name,arguments:arguments,source:"Validation")
    guard artworkSession.canvas?.activeTextView?.hasMarkedText() != true,
      artworkSession.canvas?.storyEditor?.views.contains(where:{$0.hasMarkedText()}) != true else {
      throw FormError.invalid("Finish the current text input before changing a Studio publication pose.")
    }
  }
  /// Validate source/page edits against a detached in-memory engine before ending
  /// native editing. A rejected request leaves responder, selection and undo intact.
  func preflightPublicationHandoff(_ name:String,_ arguments:[String:Any]) throws {
    guard let canvas=artworkSession.canvas,canvas.storyEditor != nil || canvas.activeTextView != nil else{return}
    let operations=arguments["operations"] as? [[String:Any]] ?? []
    let relevant=["form_story","form_publication"].contains(name) || (name=="form_batch" && operations.contains{["form_story","form_publication"].contains($0["name"] as? String ?? "")})
    guard relevant else{return}
    guard canvas.activeTextView?.hasMarkedText() != true,
      canvas.storyEditor?.views.contains(where:{$0.hasMarkedText()}) != true else{throw FormError.invalid("Finish the current text input before changing a linked story or its pages.")}
    let mirror=OperationEngine(repository:repository);mirror.project=project;mirror.selection=engine.selection
    mirror.onPrepareGlyph=engine.onPrepareGlyph;mirror.onPrepareParagraphs=engine.onPrepareParagraphs
    mirror.onValidatePaint=engine.onValidatePaint
    mirror.onGraphics={_,_ in throw FormError.invalid("Finish text editing before combining publication edits and graphics operations in one batch.")}
    _ = try mirror.call(name,arguments:arguments,source:"Validation")
  }
  /// Native inspector and MCP preflight share the same physical-edition and
  /// ink-intent route as export; an ordinary arranged report omits those checks.
  func publicationPreflightReport(_ id:UUID,layout:PublicationPDFLayout,padToMultipleOfFour:Bool=false)throws->[String:Any] {
    guard let report=try publicationGraphicsCall("form_publication",["command":"preflight","publication_id":id.uuidString,
      "output_layout":layout.rawValue,"pad_to_multiple_of_four":padToMultipleOfFour]) as? [String:Any] else {
      throw FormError.invalid("The publication preflight report is unavailable.")
    }
    return report
  }
  func publicationGraphicsCall(_ name:String,_ arguments:[String:Any]) throws -> Any {
    guard let project else{throw FormError.missing("Open a project first.")}
    if name=="form_export_publication",artworkSession.canvas?.storyEditor?.views.contains(where:{$0.hasMarkedText()})==true {
      throw FormError.invalid("Finish the current text input before exporting the publication.")
    }
    let assets=repository.url(for:project.id).appendingPathComponent("Assets")
    func uuid(_ key:String) throws -> UUID {
      guard let value=arguments[key] as? String,let id=UUID(uuidString:value) else{throw FormError.invalid("Provide a valid \(key) UUID.")};return id
    }
    if name=="form_story" {return try PublicationOutput.storyLayout(project,storyID:uuid("story_id"))}
    let id=try uuid("publication_id")
    let physical=try PublicationOutput.physicalAssembly(project,documentID:id,
      objectID:arguments["physical_object_id"]==nil ? nil:uuid("physical_object_id"))
    if name=="form_publication" {
      let layout:PublicationPDFLayout
      if let raw=arguments["output_layout"] {
        guard let name=raw as? String,let parsed=PublicationPDFLayout(rawValue:name) else{throw FormError.invalid("Choose pages, spreads or booklet output.")}
        layout=parsed
      }else{layout = .pages}
      if let raw=arguments["pad_to_multiple_of_four"],!(raw is Bool) {throw FormError.invalid("Blank-page padding must be an explicit boolean.")}
      var inkMode:InkOutputMode?
      if let raw=arguments["ink_output"] {
        guard let value=raw as? String,let mode=InkOutputMode(rawValue:value),mode != .preflight else{throw FormError.invalid("Choose preview, composite or plates as the intended ink output.")}
        inkMode=mode
      }
      if let physical {return PublicationOutput.physicalPreflight(project,documentID:id,assembly:physical,assets:assets,layout:layout,previewOnly:inkMode == .preview)}
      return PublicationOutput.arrangedPreflight(project,documentID:id,assets:assets,layout:layout,
        padToMultipleOfFour:arguments["pad_to_multiple_of_four"] as? Bool ?? false,inkOutput:inkMode)
    }
    guard let document=project.publications?.first(where:{$0.id==id}) else{throw FormError.missing("Publication not found.")}
    let layout:PublicationPDFLayout
    if let raw=arguments["layout"] {
      guard let value=raw as? String,let parsed=PublicationPDFLayout(rawValue:value) else{throw FormError.invalid("Choose pages, spreads or booklet output.")}
      layout=parsed
    }else{layout = .pages}
    if let raw=arguments["pad_to_multiple_of_four"],!(raw is Bool) {throw FormError.invalid("Blank-page padding must be an explicit boolean.")}
    let padding=arguments["pad_to_multiple_of_four"] as? Bool ?? false
    if arguments["ink_output"] as? String != "preflight" {
      for page in document.pages {
        if let object = project.objects.first(where: { $0.id == page.objectID }) {
          try ObjectViewExportGuard.validate(project:project, object:object)
        }
      }
    }
    if let value=arguments["ink_output"] {
      guard let text=value as? String,let mode=InkOutputMode(rawValue:text) else{throw FormError.invalid("Choose a valid ink_output mode.")}
      if mode == .preflight {
        if let physical {return PublicationOutput.physicalPreflight(project,documentID:id,assembly:physical,assets:assets,layout:layout)}
        if layout == .pages {return ProductionInkPDF.preflight(project:project,pages:try inkPublicationPages(id),assets:assets)}
        var report=PublicationOutput.arrangedPreflight(project,documentID:id,assets:assets,layout:layout,padToMultipleOfFour:padding)
        report["ink_preflight"]=ProductionInkPDF.preflight(project:project,pages:try inkPublicationPages(id),assets:assets)
        return report
      }
      if mode == .composite || mode == .plates {
        if physical != nil,mode == .plates {throw FormError.invalid("Mixed photographic/black-only parent sheets export a physical composite. Full-color raster ink plates require a separate press separation workflow.")}
      }
      if (mode == .composite || mode == .plates),physical==nil {
        guard layout == .pages else{throw FormError.invalid("Production ink composites and plates use reader pages. Choose appearance preview for arranged output.")}
        try PublicationOutput.validateExportContent(project,documentID:id,assets:assets,allowOverset:arguments["allow_overset"] as? Bool ?? false)
        let output=try ProductionInkPDF.export(project:project,pages:inkPublicationPages(id),assets:assets,mode:mode,title:document.name)
        return try writeProductionInkPDF(output.data,report:output.report,name:document.name,mode:mode,arguments:arguments)
      }
    }
    let url:URL
    if let path=arguments["path"] as? String {
      guard path.hasPrefix("/"),URL(fileURLWithPath:path).pathExtension.lowercased()=="pdf" else{throw FormError.invalid("Use an absolute local path ending in .pdf.")}
      url=URL(fileURLWithPath:path)
    } else {
      let folder=repository.url(for:project.id).appendingPathComponent("Exports")
      try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      url=folder.appendingPathComponent(document.name.replacingOccurrences(of:"/",with:"-")+".pdf")
    }
    let preview=arguments["ink_output"] as? String=="preview"
    let plan:PublicationPDFPlan,data:Data
    if let physical {
      plan=try PublicationOutput.physicalArrangement(project,documentID:id,assembly:physical,layout:layout)
      data=try PublicationOutput.physicalPDF(project,documentID:id,assembly:physical,assets:assets,dpi:arguments["dpi"] as? Double ?? 300,
        outlineText:arguments["outline_text"] as? Bool ?? false,allowOverset:arguments["allow_overset"] as? Bool ?? false,layout:layout,previewOnly:preview)
    }else{
      plan=try PublicationOutput.arrangement(project,documentID:id,layout:layout,padToMultipleOfFour:padding)
      data=try PublicationOutput.arrangedPDF(project,documentID:id,assets:assets,dpi:arguments["dpi"] as? Double ?? 300,
        outlineText:arguments["outline_text"] as? Bool ?? false,allowOverset:arguments["allow_overset"] as? Bool ?? false,
        inkOutput:(arguments["ink_output"] as? String).flatMap(InkOutputMode.init(rawValue:)),layout:layout,padToMultipleOfFour:padding)
    }
    try data.write(to:url,options:.atomic)
    var result:[String:Any]=["path":url.path,"format":"pdf","publication_id":id.uuidString,"page_count":plan.sides.count,"source_page_count":document.pages.count,"layout":layout.rawValue,"arrangement":try jsonObject(plan),"bytes":data.count,
      "source_color_space":"sRGB","output_profile":preview ? NSNull():try PublicationOutput.outputProfile(project,document:document).map{try jsonObject($0)} ?? NSNull(),
      "preflight":PublicationOutput.preflight(project,documentID:id,assets:assets,previewOnly:preview)]
    if preview {result["ink_output"]="preview";result["ink_declarations_encoded"]=false;result["ink_notice"]="sRGB appearance preview; named/process ink declarations are not encoded in this output."}
    if let physical {
      result["physical_object_id"]=physical.id.uuidString;result["parent_sheet_count"]=physical.sheetAssembly?.parentSheets?.count ?? 0
      result["source_color_space"]=preview ? "sRGB substrate/ink appearance proof":"Profiled color pages and explicit K-only parent pages"
      result["substrate_is_printed"]=false
      result["stock_color_encoded_in_pdf"]=preview;result["for_print"] = !preview
      result["preflight"]=PublicationOutput.physicalPreflight(project,documentID:id,assembly:physical,assets:assets,layout:layout,previewOnly:preview)
    }
    return result
  }
}

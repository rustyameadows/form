import AppKit
import FormCore
import FormGraphics

extension StudioStore {
  /// Validate source/page edits against a detached in-memory engine before ending
  /// native editing. A rejected request leaves responder, selection and undo intact.
  func preflightPublicationHandoff(_ name:String,_ arguments:[String:Any]) throws {
    guard let editor=artworkSession.canvas?.storyEditor else{return}
    let operations=arguments["operations"] as? [[String:Any]] ?? []
    let relevant=["form_story","form_publication"].contains(name) || (name=="form_batch" && operations.contains{["form_story","form_publication"].contains($0["name"] as? String ?? "")})
    guard relevant else{return}
    guard !editor.views.contains(where:{$0.hasMarkedText()}) else{throw FormError.invalid("Finish the current text input before changing a linked story or its pages.")}
    let mirror=OperationEngine(repository:repository);mirror.project=project;mirror.selection=engine.selection
    mirror.onPrepareGlyph=engine.onPrepareGlyph;mirror.onPrepareParagraphs=engine.onPrepareParagraphs
    mirror.onValidatePaint=engine.onValidatePaint
    mirror.onGraphics={_,_ in throw FormError.invalid("Finish text editing before combining publication edits and graphics operations in one batch.")}
    _ = try mirror.call(name,arguments:arguments,source:"Validation")
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
    if name=="form_publication" {return PublicationOutput.preflight(project,documentID:id,assets:assets)}
    guard let document=project.publications?.first(where:{$0.id==id}) else{throw FormError.missing("Publication not found.")}
    let url:URL
    if let path=arguments["path"] as? String {
      guard path.hasPrefix("/"),URL(fileURLWithPath:path).pathExtension.lowercased()=="pdf" else{throw FormError.invalid("Use an absolute local path ending in .pdf.")}
      url=URL(fileURLWithPath:path)
    } else {
      let folder=repository.url(for:project.id).appendingPathComponent("Exports")
      try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      url=folder.appendingPathComponent(document.name.replacingOccurrences(of:"/",with:"-")+".pdf")
    }
    let data=try PublicationOutput.pdf(project,documentID:id,assets:assets,dpi:arguments["dpi"] as? Double ?? 300,
      outlineText:arguments["outline_text"] as? Bool ?? false,allowOverset:arguments["allow_overset"] as? Bool ?? false)
    try data.write(to:url,options:.atomic)
    return ["path":url.path,"format":"pdf","publication_id":id.uuidString,"page_count":document.pages.count,"bytes":data.count,
      "source_color_space":"sRGB","output_profile":try PublicationOutput.outputProfile(project,document:document).map{try jsonObject($0)} ?? NSNull(),
      "preflight":PublicationOutput.preflight(project,documentID:id,assets:assets)] as [String:Any]
  }
}

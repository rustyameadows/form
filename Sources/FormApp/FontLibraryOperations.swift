import AppKit
import FormCore
import FormGraphics

extension StudioStore {
  func preflightFontHandoff(_ name:String,_ arguments:[String:Any]) throws {
    if name=="form_replace_font" {var validation=arguments;validation["dry_run"]=true;_ = try replaceFontCall(validation);return}
    guard name=="form_edit_artwork",arguments["command"] as? String=="font" else{return}
    guard artworkSession.canvas?.hasMarkedTextInput != true else{throw FormError.invalid("Finish the current text input before assigning a font.")}
    let mirror=OperationEngine(repository:repository);mirror.project=project;mirror.selection=engine.selection
    mirror.onPrepareGlyph=engine.onPrepareGlyph;mirror.onPrepareParagraphs=engine.onPrepareParagraphs
    _ = try mirror.call(name,arguments:arguments,source:"Validation")
  }
  func fontLibraryCall(_ arguments:[String:Any]) throws -> Any {
    let command=arguments["command"] as? String ?? "families"
    if command=="usage" {
      guard let project else{throw FormError.missing("Open a project to inspect its font assignments.")}
      let values=FontLibraryCatalog.usage(project)
      return ["fonts":values,"missing_count":values.filter{$0["available"] as? Bool==false}.count,"renderer":FontLibraryCatalog.diagnostics]
    }
    func integer(_ key:String,_ fallback:Int,_ maximum:Int) throws -> Int {
      guard let raw=arguments[key] else{return fallback}
      guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue==n.doubleValue.rounded(),n.intValue>=0,n.intValue<=maximum else{throw FormError.invalid("Use a bounded nonnegative integer for \(key).")};return n.intValue
    }
    let offset=try integer("offset",0,100000),limit=try integer("limit",100,256)
    guard limit>0,["families","faces"].contains(command) else{throw FormError.invalid("Font list commands: families, faces, usage; limit 1–256.")}
    let faces=FontLibraryCatalog.search(arguments["query"] as? String ?? "")
    if command=="faces" {return ["faces":Array(faces.dropFirst(offset).prefix(limit)).map(\.json),"total":faces.count,"offset":offset,"limit":limit,"renderer":FontLibraryCatalog.diagnostics]}
    let grouped=Dictionary(grouping:faces,by:{$0.family}),families=grouped.keys.sorted()
    return ["families":Array(families.dropFirst(offset).prefix(limit)).map{family in
      ["id":family,"family":family,"faces":grouped[family]!.map(\.json)] as [String:Any]
    },"total":families.count,"offset":offset,"limit":limit,"renderer":FontLibraryCatalog.diagnostics]
  }
  func replaceFontCall(_ arguments:[String:Any]) throws -> Any {
    guard let project else{throw FormError.missing("Open a project first.")}
    guard let source=arguments["from_font"] as? String,let target=arguments["to_font"] as? String,
      FontLibraryCatalog.faces.contains(where:{$0.name==target}),FontLibraryCatalog.installed(target) else{
      throw FormError.invalid("Choose exact from_font and installed to_font face names from form_list_fonts.")
    }
    if let raw=arguments["dry_run"] {
      guard let number=raw as? NSNumber,CFGetTypeID(number)==CFBooleanGetTypeID() else{throw FormError.invalid("dry_run must be true or false.")}
    }
    guard artworkSession.canvas?.hasMarkedTextInput != true else{throw FormError.invalid("Finish the current text input before replacing document fonts.")}
    let changed=try FontUsage.replacing(in:project,from:source,to:target)
    let uses=FontUsage.uses(in:project).filter{$0.fontName==source},remaining=FontUsage.uses(in:changed).filter{$0.fontName==source}
    let dry=arguments["dry_run"] as? Bool ?? false
    if !dry,changed != project {
      try engine.edit("Replaced \(source) with \(target)",source:arguments["_source"] as? String ?? "Agent") {$0=changed}
      self.changed();fontLibraryPreferences.used(target)
    }
    return ["from_font":source,"to_font":target,"dry_run":dry,"assignment_count":uses.count,
      "replaced_assignments":uses.count-remaining.count,"retained_exact_glyphs":remaining.filter{$0.kind=="exact_glyph"}.count,
      "remaining_uses":remaining.map(\.json),"uses":uses.map(\.json),
      "warnings":(remaining.isEmpty ? []:["Exact glyph choices keep their original face, glyph name/ID and signature. Review, clear or reselect those choices explicitly before output."])+FontLibraryCatalog.settingsWarnings(changed,face:target),
      "font_usage":FontLibraryCatalog.usage(changed)] as [String:Any]
  }
}

extension ArtworkSession {
  func chooseFont(_ name:String) {
    guard FontLibraryCatalog.installed(name) else{store?.error="The selected face is no longer available. Refresh the font browser.";return}
    typography{$0.fontName=name}
    store?.fontLibraryPreferences.used(name)
  }
}

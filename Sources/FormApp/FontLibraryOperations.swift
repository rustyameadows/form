import AppKit
import FormCore
import FormGraphics

extension StudioStore {
  func replaceDocumentFont(from:String,to:String,context:FontDocumentContext,dryRun:Bool) throws -> Any {
    guard context.matches(self) else{throw FormError.invalid("The project changed. Reopen Document fonts for the current project.")}
    let arguments:[String:Any]=["from_font":from,"to_font":to,"dry_run":true]
    let report=try replaceFontCall(arguments)
    if dryRun {return report}
    artworkSession.canvas?.finishText()
    guard context.matches(self) else{throw FormError.invalid("The project changed. Reopen Document fonts for the current project.")}
    return try replaceFontCall(["from_font":from,"to_font":to,"dry_run":false,"_source":"Studio"])
  }
  func preflightFontHandoff(_ name:String,_ arguments:[String:Any],projection:CanvasSourceProjection?=nil) throws {
    if name=="form_replace_font" {var validation=arguments;validation["dry_run"]=true;_ = try replaceFontCall(validation);return}
    guard name=="form_edit_artwork",arguments["command"] as? String=="font" else{return}
    guard artworkSession.canvas?.hasMarkedTextInput != true else{throw FormError.invalid("Finish the current text input before assigning a font.")}
    var validationProject=project,validationArguments=arguments
    if let projection,projection.requiresInsideSource {
      guard var value=validationProject else{throw FormError.missing("Open a project first.")}
      // A legacy inline face has no canonical sheet yet. Resolve that sheet
      // only in the validation copy, so preflight inspects the chosen face
      // without changing the document or creating an Undo entry.
      let sourceID=try PaperCommands.ensureInside(in:&value,objectID:projection.constructionID)
      validationProject=value;validationArguments["object_id"]=sourceID.uuidString
    }
    let mirror=OperationEngine(repository:repository);mirror.project=validationProject;mirror.selection=engine.selection
    mirror.onPrepareGlyph=engine.onPrepareGlyph;mirror.onPrepareParagraphs=engine.onPrepareParagraphs
    _ = try mirror.call(name,arguments:validationArguments,source:"Validation")
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
  @discardableResult func chooseFont(_ name:String,context:FontSelectionContext?=nil)->Bool {
    let context=context ?? captureFontSelection()
    guard let store else{return false}
    if let reason=fontSelectionUnavailableReason(context:context) {store.error=reason;return false}
    // Existing inspector integrations may provide an installed family alias
    // (for example Skia). Resolve it to the actual installed face; the browser
    // itself already supplies exact catalog identities.
    let name=FontLibraryCatalog.faces.contains(where:{$0.name==name}) ? name:(NSFont(name:name,size:14)?.fontName ?? name)
    guard FontLibraryCatalog.faces.contains(where:{$0.name==name}),FontLibraryCatalog.installed(name) else{
      store.error="The selected face is no longer available. Refresh the font browser.";return false
    }
    guard let objectID else{return false}
    var arguments:[String:Any]=["object_id":objectID.uuidString,"element_ids":context.textElementIDs.map(\.uuidString),
      "command":"font","font_name":name]
    if let range=context.sourceRange,range.length>0 {arguments["location"]=range.location;arguments["length"]=range.length}
    do {
      // Validate locks, source ranges and shared-story ownership before moving
      // focus or altering native storage. Failed picks never enter Recents.
      try store.preflightFontHandoff("form_edit_artwork",arguments,projection:activeProjection)
      if context.wasEditing {
        guard let view=context.nativeView,let range=context.sourceRange,let canvas else{return false}
        let mapping=TextCase.source(view.attributedString())
        guard view.window?.makeFirstResponder(view)==true else{
          throw FormError.invalid("The text editor could not regain focus. Reopen the font picker.")
        }
        view.setSelectedRange(mapping.displayRange(range))
        guard canvas.applyTextStyle({$0.fontName=name}) else{return false}
        // NSTextView can veto an edit. A handled action is not by itself proof
        // that a font was assigned, so inspect its resulting source attributes.
        let assigned:Bool
        if range.length==0 {assigned=canvas.textInspection()?.typography.fontName==name}
        else {
          let source=TextCase.source(view.attributedString()).text
          let runs=TypographyEngine.spans(from:source.attributedSubstring(from:range),fallback:.init())
          assigned = !runs.isEmpty && runs.allSatisfy{$0.typography.fontName==name}
        }
        guard assigned else{throw FormError.invalid("The text editor could not assign the selected face.")}
      } else {
        store.engine.endInteraction()
        if let projection=activeProjection,projection.requiresInsideSource {
          let original=sourceArtwork
          var value=art
          _ = try ArtworkCommands.apply("font",to:&value,ids:context.textElementIDs,arguments:arguments)
          let expected=projection.source(from:value,original:original)
          // Use the same projection-aware first-write path as other Canvas
          // edits. Creating the inside sheet and assigning its font are one
          // transaction; the outside artwork never receives this command.
          save(value)
          guard sourceArtwork==expected else{throw FormError.invalid("The selected face could not assign the font.")}
        } else {
          _ = try store.engine.call("form_edit_artwork",arguments:arguments,source:"Studio")
          store.changed()
        }
      }
      context.didApply();store.fontLibraryPreferences.used(name)
      return true
    } catch {store.error=error.localizedDescription;return false}
  }
}

import AppKit
import FormCore
import FormGraphics

extension StudioStore {
  func preflightCharacterPositionHandoff(_ name:String,_ arguments:[String:Any])throws {
    func targeted(_ name:String,_ args:[String:Any])->Bool {
      if name=="form_edit_artwork",args["command"] as? String=="character_position" {return true}
      if name=="form_text_style",let type=args["typography"] as? [String:Any],type.keys.contains("characterPosition") || ["features","featureSelections"].contains(where:{(type[$0] as? [String:Any])?.keys.contains("10")==true}) {return true}
      let art=(name=="form_set_artwork" ? args["artwork"]:nil) as? [String:Any]
      let elements=art?["elements"] as? [[String:Any]] ?? (name=="form_edit_artwork" ? args["elements"] as? [[String:Any]]:nil) ?? []
      return elements.contains {element in
        (element["typography"] as? [String:Any])?.keys.contains("characterPosition")==true || (element["textRuns"] as? [[String:Any]] ?? []).contains{($0["typography"] as? [String:Any])?.keys.contains("characterPosition")==true}
      }
    }
    let operations=arguments["operations"] as? [[String:Any]] ?? []
    guard targeted(name,arguments) || (name=="form_batch" && operations.contains{targeted($0["name"] as? String ?? "",$0["arguments"] as? [String:Any] ?? [:])}) else{return}
    let graphics=Set(["form_convert_to_paths","form_boolean_artwork","form_color_profile"])
    if name=="form_batch",operations.contains(where:{graphics.contains($0["name"] as? String ?? "")}),!artworkSession.editingText,!(NSApp.keyWindow?.firstResponder is NSTextView) {return}
    guard artworkSession.canvas?.hasMarkedTextInput != true else{throw FormError.invalid("Finish marked text input before changing character position.")}
    let mirror=OperationEngine(repository:repository);mirror.project=project;mirror.selection=engine.selection
    mirror.onPrepareParagraphs=engine.onPrepareParagraphs;mirror.onPrepareGlyph=engine.onPrepareGlyph;mirror.onPrepareOptical=engine.onPrepareOptical
    mirror.onPrepareSwatch=engine.onPrepareSwatch;mirror.onValidatePaint=engine.onValidatePaint
    mirror.onGraphics={_,_ in throw FormError.invalid("Finish the current input before combining character-position and graphics operations in one batch.")}
    _ = try mirror.call(name,arguments:arguments,source:"Validation")
  }
}
extension ArtworkSession {
  func characterPosition(_ value:CharacterPosition?)throws {
    guard canvas?.hasMarkedTextInput != true else{throw FormError.invalid("Finish marked text input before changing character position.")}
    NotificationCenter.default.post(name:.formCommitArtworkFields,object:nil)
    canvas?.endNumericTextInteraction()
    if try canvas?.applyCharacterPosition(value)==true {objectWillChange.send();return}
    guard let store,let objectID else{throw FormError.missing("Choose editable text first.")}
    _ = try store.engine.call("form_edit_artwork",arguments:["object_id":objectID.uuidString,"element_ids":selection.map(\.uuidString),"command":"character_position","position":value?.rawValue as Any? ?? NSNull()],source:"Studio")
    store.changed();objectWillChange.send()
  }
  var smallCapWarnings:[String] {
    if let values=canvas?.smallCapInspection() {return Array(Set(values.filter{$0.status != "supported"}.map(\.message))).sorted()}
    return Array(Set(sourceTextElements.filter{$0.kind=="text"}.prefix(256).flatMap {source in SmallCapsTypography.reports(in:TypographyEngine.attributed(source,preservingSource:true)).filter{$0.status != "supported"}.map(\.message)})).sorted()
  }
  var characterPositionInspection:[CharacterTypography.Resolution] {
    if let values=canvas?.characterPositionInspection(){return values}
    return sourceTextElements.filter{$0.kind=="text"}.prefix(256).flatMap {source in CharacterTypography.records(in:TypographyEngine.attributed(source,preservingSource:true)).map(\.1)}
  }
}

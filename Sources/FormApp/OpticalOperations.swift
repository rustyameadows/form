import AppKit
import FormCore
import FormGraphics

extension StudioStore {
  func preflightOpticalHandoff(_ name:String,_ arguments:[String:Any])throws {
    let opticalCommand=name=="form_edit_artwork" && arguments["command"] as? String=="optical"
    let styleCommand=name=="form_text_style" && (arguments["typography"] as? [String:Any])?.keys.contains("opticalSizing")==true
    let operations=arguments["operations"] as? [[String:Any]] ?? []
    let batch=name=="form_batch" && operations.contains {op in
      let args=op["arguments"] as? [String:Any] ?? [:]
      return (op["name"] as? String=="form_edit_artwork" && args["command"] as? String=="optical") || (op["name"] as? String=="form_text_style" && (args["typography"] as? [String:Any])?.keys.contains("opticalSizing")==true)
    }
    guard opticalCommand || styleCommand || batch else{return}
    // Model-only batches can be mirrored before ending a native draft. Graphics
    // operations keep their existing transactional route once input is finished.
    let graphics=Set(["form_convert_to_paths","form_boolean_artwork","form_color_profile"])
    let hasGraphics=batch && operations.contains{graphics.contains($0["name"] as? String ?? "")}
    if hasGraphics,!artworkSession.editingText,!(NSApp.keyWindow?.firstResponder is NSTextView) {return}
    guard artworkSession.canvas?.hasMarkedTextInput != true else{throw FormError.invalid("Finish the current text input before changing optical sizing.")}
    let mirror=OperationEngine(repository:repository);mirror.project=project;mirror.selection=engine.selection
    mirror.onPrepareOptical=engine.onPrepareOptical;mirror.onPrepareParagraphs=engine.onPrepareParagraphs;mirror.onPrepareGlyph=engine.onPrepareGlyph
    mirror.onPrepareSwatch=engine.onPrepareSwatch;mirror.onValidatePaint=engine.onValidatePaint
    mirror.onGraphics={_,_ in throw FormError.invalid("Finish the current input before combining optical edits with graphics operations in one batch.")}
    _ = try mirror.call(name,arguments:arguments,source:"Validation")
    if styleCommand {
      let old=Dictionary(uniqueKeysWithValues:(project?.textStyles ?? []).map{($0.id,$0)})
      for style in mirror.project?.textStyles ?? [] where old[style.id]?.typography.opticalSizing != style.typography.opticalSizing {
        try OpticalTypography.validateEdit(style.typography.opticalSizing,fontName:style.typography.fontName)
      }
    }
  }
}

extension ArtworkSession {
  func opticalSizing(_ value:OpticalSizing?)throws {
    if try canvas?.applyOpticalSizing(value)==true {objectWillChange.send();return}
    guard let store,let objectID else{throw FormError.missing("Choose artwork text first.")}
    var arguments:[String:Any]=["command":"optical","object_id":objectID.uuidString,"element_ids":selection.map(\.uuidString)]
    arguments["optical_sizing"]=try value.map{try jsonObject($0)} ?? NSNull()
    _ = try store.engine.call("form_edit_artwork",arguments:arguments,source:"Studio");store.changed();objectWillChange.send()
  }
}

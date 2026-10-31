import AppKit
import Combine
import FormCore
import FormGraphics

/// A picker opening owns a particular source and native range. Moving focus to
/// search/preview fields must not turn a character assignment into a whole-layer
/// edit, or let a later selection inherit an earlier picker's Apply action.
@MainActor final class FontSelectionContext {
  let previewText:String
  let sourceRange:NSRange?
  let projectID:UUID?
  let projectEpoch:UUID?
  let objectID:UUID?
  let projectionID:UUID?
  let scopeID:UUID?
  let selection:Set<UUID>
  let textElementIDs:Set<UUID>
  let sourceElements:[ArtworkElement]
  let nativeSource:NSAttributedString?
  let wasEditing:Bool
  weak var nativeView:CanvasTextView?
  weak var canvas:VectorCanvasView?
  private(set) var applied=false
  private(set) var invalidated=false
  private var observations=Set<AnyCancellable>()

  init(session:ArtworkSession) {
    projectID=session.store?.project?.id;projectEpoch=session.store?.artworkTransferProjectEpoch
    objectID=session.objectID;projectionID=session.projectionFrameID;scopeID=session.scopeID
    selection=session.selection;textElementIDs=Set(session.elements.filter{$0.kind=="text"}.map(\.id))
    sourceElements=session.sourceTextElements.filter{$0.kind=="text"}
    canvas=session.canvas;wasEditing=session.editingText
    let view=session.canvas?.activeTextView
    nativeView=view
    if session.editingText,let view {
      let attributed=view.attributedString(),mapping=TextCase.source(attributed)
      let range=mapping.sourceRange(GlyphEngine.expandedDisplayRange(view.selectedRange(),in:attributed))
      nativeSource=NSAttributedString(attributedString:mapping.text);sourceRange=range
      let selected=Self.substring(mapping.text.string,range:range)
      previewText=Self.normalizedPreview(selected) ?? Self.normalizedPreview(mapping.text.string) ?? FontLibraryCatalog.defaultPreview
    } else {
      nativeSource=nil;sourceRange=nil
      previewText=sourceElements.lazy.filter{$0.kind=="text"}.compactMap{Self.normalizedPreview($0.text)}.first
        ?? FontLibraryCatalog.defaultPreview
    }
    // A selection that changes away and then back is still a new picker target.
    // These subscriptions affect only the ephemeral token, never the document.
    session.$selection.dropFirst().sink { [weak self] value in
      if let self,value != self.selection {self.invalidated=true}
    }.store(in:&observations)
    session.$objectID.dropFirst().sink { [weak self] value in
      if let self,value != self.objectID {self.invalidated=true}
    }.store(in:&observations)
    session.$projectionFrameID.dropFirst().sink { [weak self] value in
      if let self,value != self.projectionID {self.invalidated=true}
    }.store(in:&observations)
    session.$scopeID.dropFirst().sink { [weak self] value in
      if let self,value != self.scopeID {self.invalidated=true}
    }.store(in:&observations)
  }

  func didApply(){applied=true}

  static func substring(_ text:String,range:NSRange)->String {
    let value=text as NSString
    guard range.location != NSNotFound,range.location>=0,range.length>0,
      range.location<=value.length,range.length<=value.length-range.location else{return ""}
    return value.substring(with:range)
  }

  /// Cap by extended grapheme clusters so emoji and combining marks stay whole.
  /// Collapsed whitespace keeps multiline source useful in one-line specimens.
  static func normalizedPreview(_ text:String,limit:Int=128)->String? {
    guard limit>0 else{return nil}
    var result="",count=0,space=false
    for character in text {
      if character.isWhitespace {space = !result.isEmpty;continue}
      if space,count<limit {result.append(" ");count+=1};space=false
      guard count<limit else{break}
      result.append(character);count+=1
      if count==limit {break}
    }
    let value=result.trimmingCharacters(in:.whitespacesAndNewlines)
    return value.isEmpty ? nil:value
  }
}

extension ArtworkSession {
  func captureFontSelection()->FontSelectionContext {FontSelectionContext(session:self)}
  func canApplyFont(context:FontSelectionContext)->Bool {fontSelectionUnavailableReason(context:context)==nil}

  func fontSelectionUnavailableReason(context:FontSelectionContext)->String? {
    guard !context.applied,!context.invalidated,let project=store?.project,let object,
      project.id==context.projectID,store?.artworkTransferProjectEpoch==context.projectEpoch,
      objectID==context.objectID,projectionFrameID==context.projectionID,scopeID==context.scopeID,
      selection==context.selection,sourceTextElements.filter({$0.kind=="text"})==context.sourceElements else {
      return "The text selection changed. Reopen the font picker for the current text."
    }
    guard !object.locked,!project.artworkOwner(object).locked,activeCanvasFrame?.editable==true,
      !elements.filter({$0.kind=="text"}).contains(where:{art.isLocked($0)}),
      context.sourceElements.contains(where:{$0.kind=="text"}) else {
      return "Select unlocked text before choosing a font."
    }
    if canvas?.hasMarkedTextInput==true {return "Finish the current text input before assigning a font."}
    if context.wasEditing {
      guard editingText,canvas === context.canvas,let view=context.nativeView,
        canvas?.activeTextView === view,view.window != nil,let original=context.nativeSource,
        let range=context.sourceRange else {
        return "The text editor changed. Reopen the font picker for the current text."
      }
      let current=TextCase.source(view.attributedString())
      guard GlyphEngine.nativeEqual(current.text,original),
        current.sourceRange(GlyphEngine.expandedDisplayRange(view.selectedRange(),in:view.attributedString()))==range else {
        return "The text or character selection changed. Reopen the font picker."
      }
    } else if editingText {
      return "The text editor changed. Reopen the font picker for the current text."
    }
    return nil
  }
}

/// Document-wide replacement is tied to the opening, including reopenings of
/// the same project ID. A stale panel may never act on a later document.
@MainActor struct FontDocumentContext {
  let projectID:UUID?
  let projectEpoch:UUID?
  init(store:StudioStore?) {
    projectID=store?.project?.id;projectEpoch=store?.artworkTransferProjectEpoch
  }
  func matches(_ store:StudioStore?)->Bool {
    projectID != nil && store?.project?.id==projectID && store?.artworkTransferProjectEpoch==projectEpoch
  }
}

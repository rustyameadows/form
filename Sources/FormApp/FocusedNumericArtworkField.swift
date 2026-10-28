import AppKit
import SwiftUI

struct TypographyIncrement {
  var step:Double
  var range:ClosedRange<Double>
  var isCurrent:()->Bool
  var begin:()->NumericIncrementTransaction
}
struct NumericIncrementTransaction {
  var end:()->Void
  var undo:(Bool)->Void
}

/// One field owns one editor. No window delegate, event monitor or application
/// key binding is changed; events only arrive while this editor has focus.
struct NumericKeyActions {
  var step:(Int,Bool)->Bool
  var end:()->Void
  var undo:(Bool)->Void
}
@MainActor final class NumericArtworkFieldEditor:NSTextView {
  weak var numericField:NumericArtworkTextField?
  private var interaction:NumericKeyActions?
  func finishIncrement() {let prior=interaction;interaction=nil;prior?.end()}
  override func keyDown(with event:NSEvent) {
    let modifiers=event.modifierFlags.intersection([.command,.control,.option,.shift])
    if [UInt16(125),126].contains(event.keyCode),modifiers.isSubset(of:[.shift]),!hasMarkedText(),let field=numericField {
      if interaction==nil {interaction=field.startIncrement?()}
      let accepted=interaction?.step(event.keyCode==126 ? 1:-1,modifiers.contains(.shift)) ?? false
      if accepted {field.hasStepped=true;field.undoIncrement=interaction?.undo}
      field.synchronizeDraft?();return
    }
    if modifiers.contains(.command),!modifiers.contains(.control),!modifiers.contains(.option),event.charactersIgnoringModifiers?.lowercased()=="z",numericField?.hasStepped==true {
      finishIncrement();numericField?.undoIncrement?(modifiers.contains(.shift));return
    }
    finishIncrement();super.keyDown(with:event)
  }
  override func keyUp(with event:NSEvent) {
    if [UInt16(125),126].contains(event.keyCode),interaction != nil {finishIncrement();return}
    super.keyUp(with:event)
  }
  override func resignFirstResponder()->Bool {finishIncrement();return super.resignFirstResponder()}
}
@MainActor final class NumericArtworkFieldCell:NSTextFieldCell {
  private lazy var numericEditor:NumericArtworkFieldEditor = {let view=NumericArtworkFieldEditor();view.isFieldEditor=true;return view}()
  override func fieldEditor(for controlView:NSView)->NSTextView? {numericEditor.numericField=controlView as? NumericArtworkTextField;return numericEditor}
}
@MainActor final class NumericArtworkTextField:NSTextField {
  var startIncrement:(()->NumericKeyActions)?,synchronizeDraft:(()->Void)?
  var undoIncrement:((Bool)->Void)?
  var hasStepped=false
}

struct FocusedNumericArtworkField:NSViewRepresentable {
  @Binding var text:String
  var title:String
  var invalid:Bool
  var onFocus:(Bool)->Void
  var onSubmit:()->Void
  var onCancel:()->Void
  var onBegin:()->NumericIncrementTransaction
  var onStep:(Int,Bool)->Bool
  @MainActor final class Coordinator:NSObject,NSTextFieldDelegate {
    var parent:FocusedNumericArtworkField
    init(_ parent:FocusedNumericArtworkField) {self.parent=parent}
    func controlTextDidBeginEditing(_ notification:Notification) {parent.onFocus(true)}
    func controlTextDidChange(_ notification:Notification) {
      guard let field=notification.object as? NumericArtworkTextField else{return}
      field.hasStepped=false;parent.text=field.stringValue
    }
    func controlTextDidEndEditing(_ notification:Notification) {((notification.object as? NSTextField)?.currentEditor() as? NumericArtworkFieldEditor)?.finishIncrement();parent.onFocus(false)}
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
      if selector==#selector(NSResponder.insertNewline(_:)) {(textView as? NumericArtworkFieldEditor)?.finishIncrement();parent.onSubmit();return true}
      if selector==#selector(NSResponder.cancelOperation(_:)) {(textView as? NumericArtworkFieldEditor)?.finishIncrement();parent.onCancel();return true}
      return false
    }
    func sync(_ field:NumericArtworkTextField) {
      guard field.stringValue != parent.text else{return}
      field.stringValue=parent.text
      if let editor=field.currentEditor() as? NSTextView {let range=editor.selectedRange();editor.string=parent.text;editor.setSelectedRange(.init(location:min(range.location,editor.string.utf16.count),length:0))}
    }
  }
  func makeCoordinator()->Coordinator {Coordinator(self)}
  func makeNSView(context:Context)->NumericArtworkTextField {
    let field=NumericArtworkTextField();field.cell=NumericArtworkFieldCell(textCell:"");field.delegate=context.coordinator
    field.isEditable=true;field.isSelectable=true;field.isBezeled=true;field.bezelStyle = .roundedBezel;field.drawsBackground=true;field.alignment = .right
    field.font=NSFont.monospacedSystemFont(ofSize:10,weight:.regular);field.placeholderString=title;field.setAccessibilityLabel(title)
    field.lineBreakMode = .byClipping;field.cell?.usesSingleLineMode=true;field.cell?.isScrollable=true
    field.setContentHuggingPriority(.defaultLow,for:.horizontal)
    let coordinator=context.coordinator
    field.startIncrement = {[weak coordinator] in
      guard let coordinator else{return .init(step:{_,_ in false},end:{},undo:{_ in})}
      let snapshot=coordinator.parent,transaction=snapshot.onBegin()
      return .init(step:snapshot.onStep,end:transaction.end,undo:transaction.undo)
    }
    field.synchronizeDraft = {[weak field,weak coordinator] in if let field {coordinator?.sync(field)}}
    return field
  }
  func updateNSView(_ field:NumericArtworkTextField,context:Context) {
    context.coordinator.parent=self;field.textColor=invalid ? Palette.accentNS:.black;field.toolTip=invalid ? "Enter a valid value in this field's supported range.":"Up/Down steps this focused value. Shift uses ten times the step."
    context.coordinator.sync(field)
  }
  static func dismantleNSView(_ field:NumericArtworkTextField,coordinator:Coordinator) {(field.currentEditor() as? NumericArtworkFieldEditor)?.finishIncrement();field.delegate=nil}
}

extension ArtworkSession {
  func numericIncrement(step:Double,range:ClosedRange<Double> = -10000...10000)->TypographyIncrement {
    let projectID=store?.project?.id,objectID=self.objectID,selected=selection,characters=characterRange,mode=store?.mode,nativeEditing=editingText
    let owner:ArtworkSession?=self,originalCanvas=canvas
    let current:()->Bool = {owner?.store?.project?.id==projectID && owner?.objectID==objectID && owner?.selection==selected && owner?.characterRange==characters && owner?.store?.mode==mode && owner?.editingText==nativeEditing}
    return .init(step:step,range:range,isCurrent:current,begin:{
      guard current() else{return .init(end:{},undo:{_ in})}
      var engineToken:UUID?
      if !nativeEditing {owner?.store?.engine.endInteraction();engineToken=owner?.beginGesture()}
      let token=originalCanvas?.beginNumericTextInteraction()
      let finish:()->Void = {
        originalCanvas?.endNumericTextInteraction(ifToken:token)
        if let engineToken {owner?.store?.engine.endInteraction(ifGeneration:engineToken)}
      }
      return .init(end:finish,undo:{redo in
        guard current() else{return};finish();if redo {owner?.store?.redo()}else{owner?.store?.undo()};owner?.objectWillChange.send()
      })
    })
  }
}

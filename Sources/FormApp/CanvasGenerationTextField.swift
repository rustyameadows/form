import AppKit
import SwiftUI

/// A native single-line field alongside the native multiline prompt. Its mouse
/// target and Return command belong to this control rather than a SwiftUI focus
/// proxy, so typing a saved name cannot reach the generation prompt's shortcut.
struct CanvasGenerationTextField:NSViewRepresentable {
  @Binding var text:String
  let placeholder:String,identifier:String
  var onSubmit:()->Void = {}
  @Environment(\.isEnabled) private var enabled
  func makeCoordinator()->Coordinator {Coordinator(self)}
  func makeNSView(context:Context)->NSTextField {
    let field=CanvasGenerationNativeTextField(frame:.zero)
    field.isEditable=true;field.isSelectable=true
    field.isBezeled=true;field.bezelStyle = .roundedBezel
    field.drawsBackground=true;field.font = .systemFont(ofSize:12)
    field.cell?.usesSingleLineMode=true;field.cell?.isScrollable=true
    field.setContentHuggingPriority(.defaultLow,for:.horizontal)
    field.delegate=context.coordinator
    field.target=context.coordinator;field.action=#selector(Coordinator.submit(_:))
    updateNSView(field,context:context)
    return field
  }
  func updateNSView(_ field:NSTextField,context:Context) {
    context.coordinator.parent=self
    field.isEnabled=enabled;field.isEditable=enabled
    field.placeholderString=placeholder;field.setAccessibilityLabel(placeholder)
    field.setAccessibilityIdentifier(identifier)
    if field.stringValue != text {field.stringValue=text}
  }
  func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSTextField,context:Context)->CGSize? {
    .init(width:proposal.width ?? 240,height:24)
  }
  static func dismantleNSView(_ field:NSTextField,coordinator:Coordinator) {field.delegate=nil;field.target=nil;field.action=nil}
  final class Coordinator:NSObject,NSTextFieldDelegate {
    var parent:CanvasGenerationTextField
    init(_ parent:CanvasGenerationTextField){self.parent=parent}
    @objc func submit(_ field:NSTextField) {parent.text=field.stringValue;parent.onSubmit()}
    func controlTextDidChange(_ notification:Notification) {
      guard let field=notification.object as? NSTextField else{return}
      parent.text=field.stringValue
    }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
      guard selector==#selector(NSResponder.insertNewline(_:)),!textView.hasMarkedText() else{return false}
      parent.text=textView.string;parent.onSubmit();return true
    }
  }
}

/// A popover can have a focused multiline responder while its owning Canvas
/// window is still key. The first click must both activate this panel and enter
/// this field, rather than being consumed only as window activation.
final class CanvasGenerationNativeTextField:NSTextField {
  override var needsPanelToBecomeKey:Bool {true}
  override func acceptsFirstMouse(for event:NSEvent?)->Bool {isEnabled && isEditable}
  override func accessibilityPerformPress()->Bool {
    guard isEnabled,isEditable,!isHiddenOrHasHiddenAncestor,!bounds.isEmpty,
      let window,window.isVisible else{return false}
    // Assistive activation focuses this text field; it never invokes its
    // submit action or changes the draft's contents.
    window.makeKey()
    return window.makeFirstResponder(self)
  }
  override func mouseDown(with event:NSEvent) {
    guard isEnabled,isEditable else{super.mouseDown(with:event);return}
    window?.makeKey()
    window?.makeFirstResponder(self)
    super.mouseDown(with:event)
  }
}

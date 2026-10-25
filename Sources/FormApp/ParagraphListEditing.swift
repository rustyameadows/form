import AppKit
import FormCore
import FormGraphics

extension CanvasTextView {
  private func listTypingAttributes(_ base:[NSAttributedString.Key:Any],item:ParagraphListItem?,number:Int=1)->[NSAttributedString.Key:Any] {
    let sample=NSMutableAttributedString(string:"A",attributes:base);PublicationLists.clear(in:sample)
    if var item {item.location=0;item.resolvedNumber=number;PublicationLists.apply([item],to:sample)}
    return sample.attributes(at:0,effectiveRange:nil)
  }
  func restoreListTyping(_ item:ParagraphListItem,base:[NSAttributedString.Key:Any]?=nil) {
    typingAttributes=listTypingAttributes(base ?? typingAttributes,item:item,number:item.resolvedNumber ?? item.restart ?? 1)
  }
  /// List metadata has native Undo even when an empty paragraph has no characters.
  func installListState(_ text:NSAttributedString,typing:[NSAttributedString.Key:Any],selection:NSRange) {
    let previous=NSAttributedString(attributedString:attributedString()),oldTyping=typingAttributes,oldSelection=selectedRange()
    undoManager?.registerUndo(withTarget:self) {view in view.installListState(previous,typing:oldTyping,selection:oldSelection)}
    undoManager?.setActionName("Paragraph list")
    textStorage?.setAttributedString(text);typingAttributes=typing
    setSelectedRange(NSRange(location:min(selection.location,text.length),length:min(selection.length,max(0,text.length-selection.location))))
    didChangeText()
  }
  func applyParagraphList(_ arguments:[String:Any]) throws {
    let mapping=TextCase.source(attributedString()),source=NSMutableAttributedString(attributedString:mapping.text)
    let range=mapping.sourceRange(selectedRange())
    var items=PublicationLists.items(from:source,trailingAttributes:typingAttributes)
    let marker=ParagraphListItem.Marker(rawValue:arguments["marker"] as? String ?? "bullet") ?? .bullet
    let identity=(arguments["list_id"] as? String).flatMap(UUID.init(uuidString:))
    try ParagraphLists.edit(&items,text:source.string,range:range,action:arguments["list_action"] as? String ?? "set",marker:marker,
      listID:identity,level:arguments["level"] as? Int,restart:arguments["restart"] as? Int,fontName:arguments["marker_font"] as? String)
    PublicationLists.clear(in:source);PublicationLists.apply(items ?? [],to:source)
    let normalized=GlyphEngine.normalizedNative(source)
    let paragraph=ParagraphLists.selectedParagraphs(in:source.string,range:NSRange(location:range.location,length:0)).first
    let item=paragraph.flatMap{paragraph in items?.first{$0.location==paragraph.location}}
    let typing=listTypingAttributes(typingAttributes,item:item,number:item?.restart ?? 1)
    undoManager?.beginUndoGrouping();defer{undoManager?.endUndoGrouping()}
    installListState(normalized,typing:typing,selection:TextCase.source(normalized).displayRange(range))
  }
  func handleListReturn()->Bool {
    let mapping=TextCase.source(attributedString()),range=mapping.sourceRange(selectedRange())
    guard let paragraph=ParagraphLists.selectedParagraphs(in:mapping.text.string,range:NSRange(location:range.location,length:0)).first,
      PublicationLists.items(from:mapping.text,trailingAttributes:typingAttributes)?.contains(where:{$0.location==paragraph.location}) == true else{return false}
    let content=(mapping.text.string as NSString).substring(with:paragraph).trimmingCharacters(in:.whitespacesAndNewlines)
    guard content.isEmpty else{return false}
    try? applyParagraphList(["list_action":"remove"]);return true
  }
  func handleListIndent(outdent:Bool)->Bool {
    let mapping=TextCase.source(attributedString()),range=mapping.sourceRange(selectedRange())
    let starts=Set(ParagraphLists.selectedParagraphs(in:mapping.text.string,range:range).map(\.location))
    guard PublicationLists.items(from:mapping.text,trailingAttributes:typingAttributes)?.contains(where:{starts.contains($0.location)}) == true else{return false}
    try? applyParagraphList(["list_action":outdent ? "outdent":"indent"]);return true
  }
  func normalizeListTyping(_ source:NSAttributedString)->NSAttributedString {
    let normalized=PublicationLists.normalized(source)
    let values=PublicationLists.items(from:normalized,trailingAttributes:typingAttributes) ?? []
    if values.contains(where:{$0.location==source.length}),source.length==0 || source.string.last?.isNewline == true {
      if let item=values.last {
        let number=ParagraphLists.numbers(values)[item.id] ?? 1
        typingAttributes=listTypingAttributes(typingAttributes,item:item,number:number)
      }
    }
    return normalized
  }
}

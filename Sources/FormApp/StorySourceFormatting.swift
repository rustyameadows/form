import AppKit
import CoreText
import FormCore
import FormGraphics

enum StorySourceFormat:CaseIterable {case bold,italic,underline}
struct StorySourceFormatState:Equatable {
  let available:Bool
  let isOn:Bool
  let isMixed:Bool
  static let unavailable=Self(available:false,isOn:false,isMixed:false)
}

/// Formats the existing shared native storage; no page fragments or alternative
/// story representation are created. Authored faces, rather than glyph-coverage
/// fallback fonts, determine each run's available bold and italic variants.
@MainActor enum StorySourceFormatting {
  private struct Part {
    let range:NSRange
    let attributes:[NSAttributedString.Key:Any]
    let span:TextSpan
  }
  static func state(_ format:StorySourceFormat,editor:PublicationEditingController,text:CanvasTextView)->StorySourceFormatState {
    guard let parts=parts(editor:editor,text:text),!parts.isEmpty else{return .unavailable}
    let values=parts.map{isOn(format,in:$0.span)},on=values.allSatisfy{$0},mixed=Set(values).count>1
    let available=parts.allSatisfy{changed($0.span,format:format,enabled:!on) != nil}
    return .init(available:available,isOn:on,isMixed:mixed)
  }
  @discardableResult static func apply(_ format:StorySourceFormat,editor:PublicationEditingController,text:CanvasTextView)->Bool {
    guard let parts=parts(editor:editor,text:text),!parts.isEmpty else{return false}
    let enabled = !parts.allSatisfy{isOn(format,in:$0.span)}
    var replacements:[(NSRange,[NSAttributedString.Key:Any])]=[]
    // Preflight every face before touching storage: a missing trait in one run
    // must not leave a partially formatted multi-family selection.
    for part in parts {
      guard let span=changed(part.span,format:format,enabled:enabled) else{return false}
      var type=span.typography
      type.inheritedLanguage=part.attributes[LanguageHyphenation.inheritedLanguageKey] as? String
      let generated=TypographyEngine.attributes(type,size:span.fontSize,color:span.color,millimeters:false,
        swatchID:span.swatchID,textStyle:span.textStyle,paragraphStyle:span.paragraphStyle,paintStack:span.paintStack)
      var attributes=part.attributes
      attributes.merge(generated){_,new in new}
      replacements.append((part.range,attributes))
    }
    let originalSelection=text.selectedRange(),mapping=TextCase.source(text.attributedString())
    let sourceSelection=mapping.sourceRange(originalSelection)
    let undo=text.undoManager
    undo?.beginUndoGrouping();defer{undo?.endUndoGrouping()}
    if originalSelection.length==0 {
      setTyping(replacements[0].1,editor:editor,text:text)
    }else {
      let range=GlyphEngine.expandedDisplayRange(originalSelection,in:text.attributedString())
      guard text.shouldChangeText(in:range,replacementString:nil) else{return false}
      let typing=text.typingAttributes
      text.textStorage?.beginEditing()
      for (part,attributes) in replacements {text.textStorage?.setAttributes(attributes,range:part)}
      if let storage=text.textStorage {TypographyEngine.updateSpacing(storage,range:range)}
      text.textStorage?.endEditing()
      text.didChangeText()
      text.setSelectedRange(TextCase.source(text.attributedString()).displayRange(sourceSelection))
      text.typingAttributes=typing
    }
    undo?.setActionName(format == .bold ? "Bold":format == .italic ? "Italic":"Underline")
    editor.session?.objectWillChange.send()
    return true
  }
  private static func current(_ editor:PublicationEditingController,_ text:CanvasTextView)->Bool {
    guard let canvas=editor.canvas,canvas.storyEditor === editor,
      editor.views.contains(where:{$0 === text}),text.textStorage === editor.composition.storage,
      let project=editor.session?.store?.project,project.id==editor.projectID,
      let story=project.textStories?.first(where:{$0.id==editor.storyID}),
      story.frames==editor.composition.context.story.frames,
      story.publicationID==editor.composition.context.story.publicationID,
      story.text.utf16.elementsEqual(TextCase.source(text.attributedString()).text.string.utf16),
      !editor.views.contains(where:{$0.hasMarkedText()}) else{return false}
    return (try? PublicationCommands.ensureEditable(story,in:project)) != nil
  }
  private static func parts(editor:PublicationEditingController,text:CanvasTextView)->[Part]? {
    guard current(editor,text) else{return nil}
    let selection=text.selectedRange(),native=text.attributedString(),mapping=TextCase.source(native)
    guard selection.location != NSNotFound,selection.location>=0,selection.length>=0,
      selection.location<=native.length,selection.length<=native.length-selection.location else{return nil}
    let fallback=editor.composition.context.story.typography ?? .init()
    if selection.length==0 {
      let sample:String
      if native.length>0 {
        let string=native.string as NSString,index=min(native.length-1,max(0,selection.location-1))
        sample=string.substring(with:string.rangeOfComposedCharacterSequence(at:index))
      }else{sample="A"}
      guard let span=TypographyEngine.spans(from:NSAttributedString(string:sample,attributes:text.typingAttributes),fallback:fallback,
        utf16Offset:mapping.sourceRange(selection).location).first else{return nil}
      return [.init(range:selection,attributes:text.typingAttributes,span:span)]
    }
    var result:[Part]=[]
    native.enumerateAttributes(in:GlyphEngine.expandedDisplayRange(selection,in:native)){attributes,range,_ in
      if let span=TypographyEngine.spans(from:native.attributedSubstring(from:range),fallback:fallback,
        utf16Offset:mapping.sourceRange(.init(location:range.location,length:0)).location).first {
        result.append(.init(range:range,attributes:attributes,span:span))
      }
    }
    return result
  }
  private static func isOn(_ format:StorySourceFormat,in span:TextSpan)->Bool {
    if format == .underline {return span.typography.underline}
    guard NSFont(name:span.typography.fontName,size:span.fontSize) != nil else{return false}
    let font=TypographyEngine.font(span.typography,size:span.fontSize)
    return NSFontManager.shared.traits(of:font).contains(format == .bold ? .boldFontMask:.italicFontMask)
  }
  private static func changed(_ span:TextSpan,format:StorySourceFormat,enabled:Bool)->TextSpan? {
    var result=span
    if format == .underline {result.typography.underline=enabled}
    else {
      guard NSFont(name:span.typography.fontName,size:span.fontSize) != nil else{return nil}
      let font=TypographyEngine.font(span.typography,size:span.fontSize)
      let manager=NSFontManager.shared,trait:NSFontTraitMask=format == .bold ? .boldFontMask:.italicFontMask
      let other:NSFontTraitMask=format == .bold ? .italicFontMask:.boldFontMask
      let converted=enabled ? manager.convert(font,toHaveTrait:trait):manager.convert(font,toNotHaveTrait:trait)
      guard converted.familyName==font.familyName,
        manager.traits(of:converted).contains(trait)==enabled,
        manager.traits(of:converted).contains(other)==manager.traits(of:font).contains(other) else{return nil}
      result.typography.fontName=converted.fontName
      // A retained variable coordinate can override a newly converted named
      // face. Replace only the axes responsible for this trait; all unrelated
      // authored axes, features and optical-size policy remain source data.
      let traitAxes:Set<Int>=format == .bold ? [0x77676874]:[0x6974616c,0x736c6e74] // wght / ital, slnt
      let convertedAxes=CTFontCopyVariation(converted as CTFont) as? [NSNumber:NSNumber] ?? [:]
      for axis in traitAxes {
        if let value=convertedAxes[NSNumber(value:axis)] {result.typography.variations[axis]=value.doubleValue}
        else{result.typography.variations.removeValue(forKey:axis)}
      }
      let rebuilt=TypographyEngine.font(result.typography,size:span.fontSize)
      guard rebuilt.familyName==font.familyName,
        manager.traits(of:rebuilt).contains(trait)==enabled,
        manager.traits(of:rebuilt).contains(other)==manager.traits(of:font).contains(other) else{return nil}
    }
    return TextStyleCommands.recording(result,from:span)
  }
  private static func setTyping(_ attributes:[NSAttributedString.Key:Any],editor:PublicationEditingController,text:CanvasTextView) {
    let previous=text.typingAttributes
    text.undoManager?.registerUndo(withTarget:text){[weak editor] text in
      guard let editor,current(editor,text) else{return}
      setTyping(previous,editor:editor,text:text)
      editor.session?.objectWillChange.send()
    }
    text.typingAttributes=attributes
  }
}

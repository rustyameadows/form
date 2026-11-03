import AppKit
import FormCore
import FormGraphics
import SwiftUI

@MainActor final class PublicationEditingController:NSObject,ObservableObject,NSTextViewDelegate,NSWindowDelegate,@preconcurrency NSTextStorageDelegate {
  weak var canvas:VectorCanvasView?
  weak var session:ArtworkSession?
  let storyID:UUID
  let projectID:UUID?
  @Published private(set) var sourceRevision=0
  @Published private(set) var sourceError:String?
  @Published private(set) var selectedSourceAnnotationID:UUID?
  @Published private(set) var sourceZoom=1.0
  private(set) var sourceTextView:CanvasTextView?
  private(set) var sourceScrollView:NSScrollView?
  private var sourceFrame:StoryFrameID?
  private var sourceEditHint:(text:String,range:NSRange)?
  private let annotationHistory:StoryAnnotationHistory
  let composition:StoryComposition
  let nativeUndo=UndoManager()
  private(set) var views:[CanvasTextView]=[]
  private var hosts:[NSView]=[]
  private var hostFrames:[ObjectIdentifier:StoryFrameID]=[:]
  private var ids:[ObjectIdentifier:StoryFrameID]=[:]
  private var snapshot:NSAttributedString
  private var published:NSAttributedString
  private let originalInput:NSAttributedString
  private let originalSource:ArtworkElement
  private var overflowWindow:NSWindow?
  private var galleyLayout:PublicationLayoutManager?
  private var finishing=false
  private var finished=false
  private var publishing=false
  private var redirectingSelection=false
  init(canvas:VectorCanvasView,session:ArtworkSession,context:ResolvedTextStory) {
    self.canvas=canvas;self.session=session;storyID=context.story.id;projectID=session.store?.project?.id
    annotationHistory=StoryAnnotationHistory(text:context.story.text,annotations:session.store?.project?.textStories?.first{$0.id==context.story.id}?.annotations)
    let value=StoryComposition(context);composition=value
    snapshot=NSAttributedString(attributedString:value.storage);published=NSAttributedString(attributedString:value.storage)
    originalInput=NSAttributedString(attributedString:value.storage)
    originalSource=session.store?.project?.textStories?.first{$0.id==context.story.id}?.sourceElement ?? context.story.sourceElement
    sourceFrame=context.story.frames.first(where:{$0.objectID==session.objectID && (session.primary?.id==$0.elementID)}) ?? context.story.frames.first(where:{$0.objectID==session.objectID}) ?? context.story.frames.first
    super.init()
    if let project=session.store?.project,let story=project.textStories?.first(where:{$0.id==storyID}) {do{try PublicationCommands.ensureEditable(story,in:project)}catch{sourceError=error.localizedDescription}}
    session.store?.engine.beginInteraction("story-\(storyID)")
    for (index,geometry) in context.frames.enumerated() {
      guard let frame=session.frames.first(where:{$0.object.id==geometry.frame.objectID}),let element=frame.artwork.elements.first(where:{$0.id==geometry.frame.elementID}) else{continue}
      let text=makeView(container:composition.containers[index],frame:geometry.frame)
      text.verticalOffset=composition.offset(index,verticalAlignment:element.typography?.verticalAlignment ?? "top")
      let host=canvas.attachStoryText(text,frame:frame,element:element)
      hosts.append(host);hostFrames[ObjectIdentifier(host)]=geometry.frame;views.append(text)
    }
    composition.storage.delegate=self
  }
  private func makeView(container:NSTextContainer,frame:StoryFrameID?)->CanvasTextView {
    let text=CanvasTextView(frame:NSRect(x:0,y:0,width:container.size.width,height:container.size.height),textContainer:container)
    text.isEditable=canEditSource;text.isRichText=true;text.allowsUndo=true;text.drawsBackground=false;text.clipsToBounds=true
    text.usesRuler=false;text.usesInspectorBar=false;text.importsGraphics=false;text.textContainerInset = .zero
    text.isHorizontallyResizable=false;text.isVerticallyResizable=false
    container.widthTracksTextView=false;container.heightTracksTextView=false
    text.sharedUndoManager=nativeUndo;text.sharedSourceDelegate=self;text.delegate=self
    text.prepareSource={ [weak self] source in self?.composition.preparing(source) ?? source }
    if composition.storage.length==0 {
      var type=composition.context.story.typography ?? .init();type.inheritedLanguage=composition.context.language
      text.typingAttributes=TypographyEngine.attributes(type,size:composition.context.story.fontSize,color:composition.context.story.color,millimeters:false,
        swatchID:composition.context.story.fillSwatchID,textStyle:composition.context.story.textStyle,paragraphStyle:composition.context.story.paragraphStyle)
      if let item=composition.context.story.listItems?.first(where:{$0.location==0}) {text.restoreListTyping(item)}
    }
    text.onBecomeActive={ [weak self,weak text] in
      guard let self,let text else{return};if let frame {self.sourceFrame=frame};self.canvas?.activateStoryText(text,frame:frame ?? self.sourceFrame)
    }
    if let frame {ids[ObjectIdentifier(text)]=frame}
    text.resetSourceTracking();return text
  }
  func focus(_ frame:StoryFrameID,range:NSRange?=nil) {
    guard let index=composition.index(frame),let view=views.first(where:{ids[ObjectIdentifier($0)]==frame}) else{return}
    sourceFrame=frame
    canvas?.window?.makeFirstResponder(view)
    let source=TextCase.source(view.attributedString())
    view.setSelectedRange(source.displayRange(range ?? composition.sourceRange(index)))
  }
  func showOverflow() {showSource(revealOverflow:true)}
  func showSource(revealOverflow:Bool=false) {
    guard isCurrent else{return}
    if let window=overflowWindow {
      let active=canvas?.activeStoryView
      let range=active.flatMap{$0 === sourceTextView ? nil:TextCase.source($0.attributedString()).sourceRange($0.selectedRange())}
      window.makeKeyAndOrderFront(nil);window.makeFirstResponder(sourceTextView)
      if revealOverflow {goToSourceOverflow()}else if let range {selectSourceRange(range)}
      return
    }
    let openingSelection=canvas?.activeStoryView.map{TextCase.source($0.attributedString()).sourceRange($0.selectedRange())}
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:880,height:640),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.title="\(sourceStory?.name ?? composition.context.story.name) — Story source"
    window.appearance=NSAppearance(named:.aqua);window.backgroundColor = .windowBackgroundColor
    window.contentMinSize = .init(width:700,height:400);window.delegate=self
    let galley=PublicationLayoutManager(),container=StoryTextContainer(size:.init(width:700,height:100_000_000_000))
    galley.displayInkColor = .labelColor
    composition.storage.addLayoutManager(galley);galley.addTextContainer(container);container.lineFragmentPadding=0;galleyLayout=galley
    let text=makeView(container:container,frame:nil)
    text.drawsBackground=true;text.backgroundColor = .textBackgroundColor;text.insertionPointColor = .controlAccentColor
    text.textContainerInset = .init(width:28,height:24)
    text.isVerticallyResizable=true;text.minSize = .zero;text.maxSize = .init(width:1_000_000,height:100_000_000_000)
    text.sourceFormattingAction={ [weak self] format in self?.toggleSourceFormat(format) }
    text.sourceFindAction={ [weak self] in self?.findInSource() };text.usesFindBar=true;text.isIncrementalSearchingEnabled=true
    let scroll=StorySourceScrollView(frame:.init(x:0,y:0,width:880,height:560))
    scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=false;scroll.drawsBackground=true;scroll.backgroundColor = .textBackgroundColor
    scroll.allowsMagnification=true;scroll.minMagnification=0.75;scroll.maxMagnification=2
    scroll.onZoomChange={ [weak self] value in self?.sourceZoom=value }
    scroll.documentView=text;sourceTextView=text;sourceScrollView=scroll;overflowWindow=window;views.append(text)
    sourceZoom=max(1,min(2,15/max(8,composition.context.story.fontSize)))
    composition.storage.delegate=self
    window.contentView=NSHostingView(rootView:StorySourceWorkspace(editor:self).labInterface())
    window.center();window.makeKeyAndOrderFront(nil);window.contentView?.layoutSubtreeIfNeeded()
    scroll.magnification=sourceZoom;scroll.resizeDocument()
    let range:NSRange
    if revealOverflow {sourceFrame=composition.context.frames.last?.frame;range = .init(location:composition.oversetRange.location,length:0)}
    else if let openingSelection {range=openingSelection}
    else if let sourceFrame,let index=composition.index(sourceFrame) {range = .init(location:composition.sourceRange(index).location,length:0)}
    else {range = .init(location:0,length:0)}
    window.makeFirstResponder(text);selectSourceRange(range);refreshSourcePresentation()
  }
  func windowWillClose(_ notification:Notification) {
    guard !finishing,notification.object as? NSWindow === overflowWindow else{return}
    canvas?.finishText()
  }
  func excluded(in objectID:UUID)->Set<UUID> {Set(composition.context.frames.filter{$0.frame.objectID==objectID}.map{$0.frame.elementID})}
  func reposition() {
    guard let canvas,let session else{return}
    for host in hosts {
      guard let id=hostFrames[ObjectIdentifier(host)],let frame=session.frames.first(where:{$0.id==id.objectID}),let element=frame.artwork.elements.first(where:{$0.id==id.elementID}),let view=views.first(where:{ids[ObjectIdentifier($0)]==id}) else{continue}
      if let index=composition.index(id) {view.verticalOffset=composition.offset(index,verticalAlignment:element.typography?.verticalAlignment ?? "top")}
      canvas.positionStoryText(view,host:host,frame:frame,element:element)
    }
  }
  func textStorage(_ storage:NSTextStorage,didProcessEditing mask:NSTextStorageEditActions,range:NSRange,changeInLength delta:Int) {
    if mask.contains(.editedCharacters),!storage.string.utf16.elementsEqual(snapshot.string.utf16) {
      let old=NSRange(location:range.location,length:max(0,range.length-delta))
      for text in views {text.captureSharedSourceEdit(snapshot,range:old)}
    }
    snapshot=NSAttributedString(attributedString:storage)
    // TextKit has not invalidated the old glyph map yet. Temporary paint here
    // can query stale glyph ranges while Undo shortens the string. Refresh
    // after textDidChange instead, once storage processing has completed.
  }
  func textDidChange(_ notification:Notification) {
    guard !publishing,let text=notification.object as? CanvasTextView,!text.hasMarkedText() else{return}
    publish(text)
    refreshSourcePresentation()
    for other in views where other !== text {other.resetSourceTracking()}
  }
  func textView(_ textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
    guard commandSelector == #selector(NSResponder.cancelOperation(_:)),let canvas else{return false}
    canvas.finishText()
    canvas.window?.makeFirstResponder(canvas)
    return true
  }
  func textViewDidChangeSelection(_ notification:Notification) {
    guard let text=notification.object as? CanvasTextView else{return}
    let range=text.selectedRange()
    if text === sourceTextView {sourceRevision &+= 1;refreshSourceHighlight()}
    session?.characterRange=TextCase.source(text.attributedString()).sourceRange(range)
    session?.objectWillChange.send()
    // TextKit moves the shared insertion range but does not move the key view
    // across separately transformed page hosts. Keep the native caret visible.
    guard !redirectingSelection,range.length==0,text.window?.firstResponder === text,
      ids[ObjectIdentifier(text)] != nil,!text.hasMarkedText() else{return}
    composition.layout.ensureLayout(for:composition.overflow)
    guard let index=composition.containers.indices.first(where:{
      let coverage=composition.displayRange($0)
      return range.location>=coverage.location && range.location<NSMaxRange(coverage)
    }) else{return}
    let frame=composition.context.frames[index].frame
    guard let target=views.first(where:{ids[ObjectIdentifier($0)]==frame}),target !== text else{return}
    redirectingSelection=true;defer{redirectingSelection=false}
    text.window?.makeFirstResponder(target);target.setSelectedRange(range,affinity:text.selectionAffinity,stillSelecting:false)
    canvas?.revealStoryPage(frame.objectID)
  }
  private func merged(_ input:[TextSpan])->[TextSpan] {
    var result:[TextSpan]=[]
    for run in input {
      if var last=result.last,NSMaxRange(NSRange(location:last.location,length:last.length))==run.location {
        last.location=run.location;last.length=run.length
        if last==run {result[result.count-1].length += run.length;continue}
      }
      result.append(run)
    }
    return result
  }
  private func publish(_ text:CanvasTextView) {
    guard isCurrent,let session,let store=session.store,let index=store.project?.textStories?.firstIndex(where:{$0.id==storyID}) else{return}
    let native=text.attributedString()
    let previous=store.project!.textStories![index]
    let source=TextCase.source(native).text
    let edit=preciseSourceEdit(previous:previous.text,replacement:source.string)
    defer{sourceEditHint=nil}
    let items=PublicationLists.items(from:source,trailingAttributes:text.typingAttributes)
    if source.string.utf16.elementsEqual(previous.text.utf16),GlyphEngine.nativeEqual(native,published),items==previous.listItems {return}
    published=NSAttributedString(attributedString:native)
    // TextCase may rearchive identical source attributes during native Undo.
    // Compare the recovered source, not the derived archive's byte identity.
    let restoringOriginal=source.string.utf16.elementsEqual(originalSource.text.utf16) && GlyphEngine.nativeEqual(source,TextCase.source(originalInput).text) && items==originalSource.listItems
    var element=previous.sourceElement
    if restoringOriginal {
      // Native Undo can return exactly to the opening source. Preserve its
      // sparse inherited ranges and style references instead of materializing
      // every default run as a new source assignment.
      element=originalSource
      var restored=previous;restored.setSource(element)
      if restored==previous {return}
    } else {
      element.text=source.string
      element.glyphOverrides=GlyphEngine.overrides(from:source);if element.glyphOverrides?.isEmpty==true {element.glyphOverrides=nil}
      element.listItems=items
      let runs=merged(TypographyEngine.spans(from:source,fallback:previous.typography ?? .init()))
      let oldRuns=merged(TypographyEngine.spans(from:TypographyEngine.sourceAttributed(previous.sourceElement.inheritingLanguage(composition.context.language)),fallback:previous.typography ?? .init()))
      if previous.text.utf16.elementsEqual(element.text.utf16),previous.glyphOverrides==element.glyphOverrides,previous.listItems==items,runs==oldRuns {return}
      if runs.count==1,let run=runs.first,run.fontSize==element.fontSize,run.color==element.color,run.typography==(element.typography ?? .init()),run.swatchID==element.fillSwatchID,run.textStyle==element.textStyle,run.paragraphStyle==element.paragraphStyle {element.textRuns=nil}
      else {element.textRuns=runs}
    }
    publishing=true;defer{publishing=false}
    do {
      try store.engine.edit("Edited text story",source:"Studio",coalescing:"story-\(storyID)") {project in
        if restoringOriginal,let index=project.textStories?.firstIndex(where:{$0.id==self.storyID}) {
          try PublicationCommands.ensureEditable(project.textStories![index],in:project)
          project.textStories![index].setSource(element,textEdit:edit)
          try project.validatePublications()
        } else {try PublicationCommands.setSource(in:&project,storyID:self.storyID,source:element,textEdit:edit)}
        if let i=project.textStories?.firstIndex(where:{$0.id==self.storyID}) {
          project.textStories![i].annotations=self.annotationHistory.transition(from:previous.text,annotations:previous.annotations,to:element.text,proposed:project.textStories![i].annotations,undoing:self.nativeUndo.isUndoing,redoing:self.nativeUndo.isRedoing)
          try project.validatePublications()
        }
      }
      store.changed();session.characterRange=TextCase.source(text.attributedString()).sourceRange(text.selectedRange())
      canvas?.needsDisplay=true
    } catch {store.error=error.localizedDescription;sourceError=error.localizedDescription}
  }
  private var isCurrent:Bool {
    guard !finished,let project=session?.store?.project,project.id==projectID,
      project.textStories?.contains(where:{$0.id==storyID})==true else{return false}
    return true
  }
  private var canEditSource:Bool {guard let project=session?.store?.project,let story=sourceStory else{return false};return (try? PublicationCommands.ensureEditable(story,in:project)) != nil}
  var sourceStory:TextStory? {guard isCurrent else{return nil};return session?.store?.project?.textStories?.first{$0.id==storyID}}
  var sourceNotes:[StoryAnnotation] {sourceStory?.annotations ?? []}
  var sourceWordCount:Int {StorySourceStatistics.words(sourceStory?.text ?? "")}
  var sourceCharacterCount:Int {(sourceStory?.text ?? "").count}
  var sourceOverflowCount:Int {
    let text=sourceStory?.text ?? "",range=composition.oversetRange
    guard StoryAnnotations.validRange(range,in:text) else{return 0}
    return (text as NSString).substring(with:range).count
  }
  var sourceFrameOptions:[StorySourceFrameOption] {
    guard let project=session?.store?.project else{return []}
    let document=sourceStory?.publicationID.flatMap{id in project.publications?.first{$0.id==id}}
    return composition.context.frames.enumerated().map {index,geometry in
      let name=project.objects.first{$0.id==geometry.frame.objectID}?.name ?? "Page"
      let label=document?.pageLabel(for:geometry.frame.objectID).map{"Page \($0)"} ?? name
      let onPage=composition.context.frames.filter{$0.frame.objectID==geometry.frame.objectID}
      let column=onPage.firstIndex{$0.frame==geometry.frame}.map{$0+1} ?? 1
      return .init(id:geometry.frame,label:label+(onPage.count>1 ? " · Frame \(column)":""))
    }
  }
  var sourceSelectedFrame:StoryFrameID? {
    guard let text=sourceTextView else{return sourceFrame}
    let source=TextCase.source(text.attributedString()).sourceRange(text.selectedRange())
    return composition.context.frames.enumerated().first(where:{index,_ in
      let range=composition.sourceRange(index);return source.location>=range.location && source.location<NSMaxRange(range)
    })?.element.frame ?? sourceFrame
  }
  func formatState(_ format:StorySourceFormat)->StorySourceFormatState {
    guard let text=sourceTextView else{return .unavailable}
    return StorySourceFormatting.state(format,editor:self,text:text)
  }
  func toggleSourceFormat(_ format:StorySourceFormat) {
    guard isCurrent,let text=sourceTextView else{return}
    let range=text.selectedRange();text.window?.makeFirstResponder(text);text.setSelectedRange(range)
    if !StorySourceFormatting.apply(format,editor:self,text:text) {NSSound.beep()}
    refreshSourcePresentation()
  }
  private func selectSourceRange(_ range:NSRange) {
    guard let text=sourceTextView,StoryAnnotations.validRange(range,in:TextCase.source(text.attributedString()).text.string) else{return}
    text.setSelectedRange(TextCase.source(text.attributedString()).displayRange(range));text.scrollRangeToVisible(text.selectedRange())
  }
  func navigateSourceFrame(_ frame:StoryFrameID) {
    guard isCurrent,!views.contains(where:{$0.hasMarkedText()}),let index=composition.index(frame) else{return}
    sourceFrame=frame;sourceTextView?.window?.makeFirstResponder(sourceTextView)
    selectSourceRange(.init(location:composition.sourceRange(index).location,length:0));sourceRevision &+= 1
  }
  func showSourceOnCanvas() {
    guard isCurrent,!views.contains(where:{$0.hasMarkedText()}),let frame=sourceSelectedFrame else{return}
    sourceFrame=frame;session?.objectID=frame.objectID;session?.selection=[frame.elementID]
    let range=sourceTextView.map{TextCase.source($0.attributedString()).sourceRange($0.selectedRange())}
    canvas?.revealStoryPage(frame.objectID);canvas?.window?.makeKeyAndOrderFront(nil);focus(frame,range:range)
    // This is explicit navigation from another window. Fit the chosen page in
    // the usable Canvas viewport, including its floating-panel occlusion.
    canvas?.window?.contentView?.layoutSubtreeIfNeeded()
    _=canvas?.fit(frameIDs:[frame.objectID])
  }
  func goToSourceOverflow() {
    guard isCurrent,!views.contains(where:{$0.hasMarkedText()}) else{return}
    sourceFrame=composition.context.frames.last?.frame;sourceTextView?.window?.makeFirstResponder(sourceTextView)
    selectSourceRange(.init(location:composition.oversetRange.location,length:0));sourceRevision &+= 1
  }
  func findInSource() {
    guard isCurrent,let text=sourceTextView else{return}
    text.window?.makeFirstResponder(text)
    let item=NSMenuItem(title:"Find",action:nil,keyEquivalent:"")
    item.tag=NSTextFinder.Action.showFindInterface.rawValue;text.performTextFinderAction(item)
  }
  func setSourceZoom(_ value:Double) {
    guard value.isFinite else{return};sourceZoom=max(0.75,min(2,value));sourceScrollView?.magnification=sourceZoom
    (sourceScrollView as? StorySourceScrollView)?.resizeDocument()
  }
  func textView(_ textView:NSTextView,shouldChangeTextIn affectedCharRange:NSRange,replacementString:String?)->Bool {
    if replacementString != nil,sourceEditHint==nil {
      let mapping=TextCase.source(textView.attributedString())
      sourceEditHint=(mapping.text.string,mapping.sourceRange(affectedCharRange))
    }
    return true
  }
  private func preciseSourceEdit(previous:String,replacement:String)->StoryTextEdit? {
    guard let hint=sourceEditHint,hint.text.utf16.elementsEqual(previous.utf16),StoryAnnotations.validRange(hint.range,in:previous) else{return nil}
    let length=replacement.utf16.count-(previous.utf16.count-hint.range.length)
    let added=NSRange(location:hint.range.location,length:max(0,length))
    guard length>=0,StoryAnnotations.validRange(added,in:replacement) else{return nil}
    let text=(replacement as NSString).substring(with:added)
    guard (previous as NSString).replacingCharacters(in:hint.range,with:text).utf16.elementsEqual(replacement.utf16) else{return nil}
    return .init(range:hint.range,text:text)
  }
  @discardableResult func saveSourceAnnotation(id:UUID?,kind:StoryAnnotation.Kind,body:String)->Bool {
    guard let story=sourceStory,let text=sourceTextView,!views.contains(where:{$0.hasMarkedText()}) else{return false}
    let selection=TextCase.source(text.attributedString()).sourceRange(text.selectedRange())
    let previous=id.flatMap{id in sourceNotes.first{$0.id==id}}
    guard id==nil || previous != nil else{return false}
    let note=StoryAnnotation(id:previous?.id ?? UUID(),location:previous?.location ?? selection.location,length:previous?.length ?? selection.length,kind:kind,body:body)
    var values=story.annotations ?? []
    if let i=values.firstIndex(where:{$0.id==note.id}) {values[i]=note}else{values.append(note)}
    guard changeSourceAnnotations(values,action:previous==nil ? "Added story annotation":"Edited story annotation") else{return false}
    selectedSourceAnnotationID=note.id;refreshSourceHighlight();return true
  }
  func selectSourceAnnotation(_ id:UUID) {
    guard let note=sourceNotes.first(where:{$0.id==id}),!views.contains(where:{$0.hasMarkedText()}) else{return}
    selectedSourceAnnotationID=id;sourceTextView?.window?.makeFirstResponder(sourceTextView)
    selectSourceRange(.init(location:note.location,length:note.length));refreshSourceHighlight()
  }
  func removeSourceAnnotation(_ id:UUID) {
    guard sourceNotes.contains(where:{$0.id==id}) else{return}
    if changeSourceAnnotations(sourceNotes.filter{$0.id != id},action:"Removed story annotation") {selectedSourceAnnotationID=nil;refreshSourceHighlight()}
  }
  @discardableResult private func changeSourceAnnotations(_ values:[StoryAnnotation]?,action:String)->Bool {
    guard isCurrent,!views.contains(where:{$0.hasMarkedText()}),let store=session?.store,let old=sourceStory else{return false}
    let values=values?.isEmpty==true ? nil:values
    guard values != old.annotations else{return true}
    do {
      try StoryAnnotations.validate(values,in:old.text)
      nativeUndo.beginUndoGrouping();defer{nativeUndo.endUndoGrouping()}
      try store.engine.edit(action,source:"Studio",coalescing:"story-\(storyID)") {project in
        guard let i=project.textStories?.firstIndex(where:{$0.id==self.storyID}) else{throw FormError.missing("Text story not found.")}
        try PublicationCommands.ensureEditable(project.textStories![i],in:project)
        project.textStories![i].annotations=values;try project.validatePublications()
      }
      nativeUndo.registerUndo(withTarget:self){editor in _ = editor.changeSourceAnnotations(old.annotations,action:action)}
      nativeUndo.setActionName(action);annotationHistory.recordCurrent(text:old.text,annotations:values)
      sourceError=nil;store.changed();refreshSourcePresentation();return true
    }catch{sourceError=error.localizedDescription;return false}
  }
  private func refreshSourceHighlight() {
    guard let layout=galleyLayout else{return}
    let full=NSRange(location:0,length:composition.storage.length)
    layout.removeTemporaryAttribute(.backgroundColor,forCharacterRange:full)
    if let id=selectedSourceAnnotationID,let note=sourceNotes.first(where:{$0.id==id}) {
      let range=TextCase.source(composition.storage).displayRange(.init(location:note.location,length:note.length))
      layout.addTemporaryAttribute(.backgroundColor,value:NSColor.controlAccentColor.withAlphaComponent(0.12),forCharacterRange:range)
    }
    sourceTextView?.needsDisplay=true
  }
  private func refreshSourcePresentation() {
    sourceRevision &+= 1;galleyLayout?.refreshDisplayInk();(sourceScrollView as? StorySourceScrollView)?.resizeDocument();refreshSourceHighlight()
  }
  func finish() {
    guard !finishing else{return};finishing=true
    for text in views where text.hasMarkedText() {text.unmarkText();text.didChangeText()}
    if let active=canvas?.activeStoryView ?? views.first {publish(active)}
    composition.storage.delegate=nil
    overflowWindow?.delegate=nil
    for text in views {text.sourceFormattingAction=nil;text.sourceFindAction=nil;text.delegate=nil;text.sharedSourceDelegate=nil;text.onBecomeActive=nil;text.prepareSource=nil}
    for host in hosts {host.removeFromSuperview()};hosts=[]
    overflowWindow?.contentView=nil;overflowWindow?.close();overflowWindow=nil;sourceTextView=nil;sourceScrollView=nil;nativeUndo.removeAllActions()
    if let galleyLayout {composition.storage.removeLayoutManager(galleyLayout)};galleyLayout=nil
    session?.editingText=false;session?.store?.engine.endInteraction();finished=true
  }
}

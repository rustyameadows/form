import AppKit
import FormCore
import FormGraphics

@MainActor final class PublicationEditingController:NSObject,NSTextViewDelegate,@preconcurrency NSTextStorageDelegate {
  weak var canvas:VectorCanvasView?
  weak var session:ArtworkSession?
  let storyID:UUID
  let composition:StoryComposition
  let nativeUndo=UndoManager()
  private(set) var views:[CanvasTextView]=[]
  private var hosts:[NSView]=[]
  private var hostFrames:[ObjectIdentifier:StoryFrameID]=[:]
  private var ids:[ObjectIdentifier:StoryFrameID]=[:]
  private var snapshot:NSAttributedString
  private var published:NSAttributedString
  private var overflowWindow:NSWindow?
  private var galleyLayout:PublicationLayoutManager?
  private var finishing=false
  private var publishing=false
  private var redirectingSelection=false
  init(canvas:VectorCanvasView,session:ArtworkSession,context:ResolvedTextStory) {
    self.canvas=canvas;self.session=session;storyID=context.story.id
    let value=StoryComposition(context);composition=value
    snapshot=NSAttributedString(attributedString:value.storage);published=NSAttributedString(attributedString:value.storage)
    super.init()
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
    text.isRichText=true;text.allowsUndo=true;text.drawsBackground=false;text.clipsToBounds=true
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
      guard let self,let text else{return};self.canvas?.activateStoryText(text,frame:frame ?? self.composition.context.frames.last?.frame)
    }
    if let frame {ids[ObjectIdentifier(text)]=frame}
    text.resetSourceTracking();return text
  }
  func focus(_ frame:StoryFrameID,range:NSRange?=nil) {
    guard let index=composition.index(frame),let view=views.first(where:{ids[ObjectIdentifier($0)]==frame}) else{return}
    canvas?.window?.makeFirstResponder(view)
    let source=TextCase.source(view.attributedString())
    view.setSelectedRange(source.displayRange(range ?? composition.sourceRange(index)))
  }
  func showOverflow() {
    if let window=overflowWindow {window.makeKeyAndOrderFront(nil);return}
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:500),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.title="\(composition.context.story.name) — Story source"
    let scroll=NSScrollView(frame:window.contentView!.bounds);scroll.hasVerticalScroller=true;scroll.autoresizingMask=[.width,.height]
    let galley=PublicationLayoutManager(),container=StoryTextContainer(size:.init(width:560,height:100_000_000_000))
    composition.storage.addLayoutManager(galley);galley.addTextContainer(container);container.lineFragmentPadding=0;galleyLayout=galley
    let text=makeView(container:container,frame:nil);text.drawsBackground=true;text.backgroundColor=NSColor.textBackgroundColor
    text.isVerticallyResizable=true;text.minSize = .zero;text.maxSize = .init(width:1_000_000,height:100_000_000_000)
    galley.ensureLayout(for:container)
    text.setFrameSize(.init(width:container.size.width,height:max(500,galley.usedRect(for:container).height)))
    scroll.documentView=text;window.contentView=scroll;overflowWindow=window;views.append(text)
    composition.storage.delegate=self
    window.center();window.makeKeyAndOrderFront(nil);window.makeFirstResponder(text)
    text.setSelectedRange(TextCase.source(text.attributedString()).displayRange(NSRange(location:composition.oversetRange.location,length:0)))
    text.scrollRangeToVisible(text.selectedRange())
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
    if mask.contains(.editedCharacters),storage.string != snapshot.string {
      let old=NSRange(location:range.location,length:max(0,range.length-delta))
      for text in views {text.captureSharedSourceEdit(snapshot,range:old)}
    }
    snapshot=NSAttributedString(attributedString:storage)
  }
  func textDidChange(_ notification:Notification) {
    guard !publishing,let text=notification.object as? CanvasTextView,!text.hasMarkedText() else{return}
    publish(text)
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
    guard let session,let store=session.store,let index=store.project?.textStories?.firstIndex(where:{$0.id==storyID}) else{return}
    let native=text.attributedString()
    let previous=store.project!.textStories![index]
    let source=TextCase.source(native).text
    let items=PublicationLists.items(from:source,trailingAttributes:text.typingAttributes)
    if GlyphEngine.nativeEqual(native,published),items==previous.listItems {return}
    published=NSAttributedString(attributedString:native)
    var element=previous.sourceElement;element.text=source.string
    element.glyphOverrides=GlyphEngine.overrides(from:source);if element.glyphOverrides?.isEmpty==true {element.glyphOverrides=nil}
    element.listItems=items
    let runs=merged(TypographyEngine.spans(from:source,fallback:previous.typography ?? .init()))
    let oldRuns=merged(TypographyEngine.spans(from:TypographyEngine.sourceAttributed(previous.sourceElement.inheritingLanguage(composition.context.language)),fallback:previous.typography ?? .init()))
    if previous.text==element.text,previous.glyphOverrides==element.glyphOverrides,previous.listItems==items,runs==oldRuns {return}
    if runs.count==1,let run=runs.first,run.fontSize==element.fontSize,run.color==element.color,run.typography==(element.typography ?? .init()),run.swatchID==element.fillSwatchID,run.textStyle==element.textStyle,run.paragraphStyle==element.paragraphStyle {element.textRuns=nil}
    else {element.textRuns=runs}
    publishing=true;defer{publishing=false}
    do {
      try store.engine.edit("Edited text story",source:"Studio",coalescing:"story-\(storyID)") {project in
        try PublicationCommands.setSource(in:&project,storyID:self.storyID,source:element)
      }
      store.changed();session.characterRange=TextCase.source(text.attributedString()).sourceRange(text.selectedRange())
      canvas?.needsDisplay=true
    } catch {store.error=error.localizedDescription}
  }
  func finish() {
    guard !finishing else{return};finishing=true
    for text in views where text.hasMarkedText() {text.unmarkText();text.didChangeText()}
    if let active=canvas?.activeStoryView ?? views.first {publish(active)}
    composition.storage.delegate=nil
    for text in views {text.delegate=nil;text.sharedSourceDelegate=nil;text.onBecomeActive=nil;text.prepareSource=nil}
    for host in hosts {host.removeFromSuperview()};hosts=[]
    overflowWindow?.close();overflowWindow=nil;nativeUndo.removeAllActions()
    if let galleyLayout {composition.storage.removeLayoutManager(galleyLayout)};galleyLayout=nil
    session?.editingText=false;session?.store?.engine.endInteraction()
  }
}

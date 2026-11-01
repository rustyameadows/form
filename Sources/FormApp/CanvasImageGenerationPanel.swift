import AppKit
import FormCore
import SwiftUI

extension VectorCanvasView {
  func showCanvasImagePrompt() {
    guard let store=session?.store,let draft=store.canvasImages.draft,window != nil else{return}
    closeCanvasImagePrompt()
    synchronize()
    guard session?.frames.contains(where:{$0.object.id==draft.destinationID}) == true else{return}
    let size=CanvasImageGenerationPanel.presentationSize(available:window?.screen?.visibleFrame.size ?? .init(width:1440,height:900))
    let popover=NSPopover()
    popover.behavior = .transient
    popover.animates=false
    popover.contentViewController=NSHostingController(rootView:
      CanvasImageGenerationPanel(controller:store.canvasImages,store:store,size:size) { [weak self] in
        self?.synchronize()
        self?.closeCanvasImagePrompt()
      })
    popover.contentSize=size
    imagePromptPopover=popover
    // Anchor to the visible viewport, so reopening never moves or zooms the
    // user's artboard and the full composer has room above the anchor.
    let visible=visibleRect
    let anchor=CGPoint(x:visible.midX,y:visible.maxY-16/max(zoom,0.01))
    popover.show(relativeTo:NSRect(x:anchor.x,y:anchor.y,width:1,height:1),of:self,preferredEdge:.maxY)
    store.objectWillChange.send()
  }
  func closeCanvasImagePrompt() {
    imagePromptPopover?.close();imagePromptPopover=nil
    session?.store?.objectWillChange.send()
  }
  func applyCanvasImageTextHistory(redo:Bool)->Bool {
    guard let popover=imagePromptPopover,popover.isShown,
      let panelWindow=popover.contentViewController?.view.window,
      let text=panelWindow.firstResponder as? NSTextView,text.isEditable,
      text.window === panelWindow else{return false}
    // AppKit may report the owning window as key for a focused transient
    // popover, or no key window while the app is inactive. Use its actual text
    // responder, but never intercept another active window's Undo. Clicking
    // back on Canvas dismisses this transient popover and removes this route.
    let key=NSApp.keyWindow
    guard key === panelWindow || key === window || key == nil || !NSApp.isActive else{return false}
    if redo {text.undoManager?.redo()} else {text.undoManager?.undo()}
    return true
  }
}

struct CanvasImageGenerationPanel:View {
  @ObservedObject var controller:CanvasImageGenerationController
  @ObservedObject var store:StudioStore
  var size=CGSize(width:820,height:640)
  let close:()->Void
  @State private var choosingReference=false
  @State private var referenceSearch=""
  @State private var savingPrompt=false
  @State private var promptName=""
  @State private var localError:String?
  static func presentationSize(available:CGSize)->CGSize {
    .init(width:min(820,max(640,available.width-80)),height:min(640,max(600,available.height-90)))
  }
  private var prompt:Binding<String> {Binding(get:{controller.presentationPrompt},set:{controller.updatePrompt($0)})}
  private var options:StudioImageGenerationOptions {controller.presentationOptions}
  private var completed:Bool {controller.draft?.status == .succeeded}
  private var editingDisabled:Bool {controller.busy || completed}
  private var choices:[CanvasGenerationReference] {
    guard let project=store.project else{return []}
    let selected=Set(controller.presentationReferences.map(\.id))
    return CanvasGenerationReferenceCapture.choices(in:project).filter {
      $0.objectID != controller.draft?.destinationID && !selected.contains($0.id)
        && (referenceSearch.isEmpty || $0.title.localizedStandardContains(referenceSearch))
    }
  }
  var body:some View {
    VStack(spacing:0) {
      header
      Divider()
      HStack(alignment:.top,spacing:0) {
        composer.padding(22).frame(maxWidth:.infinity,maxHeight:.infinity)
        Divider()
        settings.padding(20).frame(width:266).frame(maxHeight:.infinity,alignment:.top)
      }
      Divider()
      footer
    }.frame(width:size.width,height:size.height).background(Palette.paper).labInterface()
      .onChange(of:controller.draft?.status) {_,status in if status == .succeeded {close()} }
  }
  private var header:some View {
    HStack(spacing:12) {
      Image(systemName:"sparkles").font(.system(size:20)).foregroundStyle(Palette.accent)
      VStack(alignment:.leading,spacing:4) {
        Text(completed ? "Image added" : "Generate image").font(.system(size:19,weight:.semibold))
        Text("CANVAS · "+(store.project?.objects.first{$0.id==controller.draft?.destinationID}?.name ?? "Image artboard"))
          .font(.system(size:10,weight:.medium)).tracking(0.6).foregroundStyle(Palette.secondary).lineLimit(1)
      }
      Spacer()
      WorkspaceToolbarButton("Close image prompt",symbol:"xmark",identifier:"canvas-generation-close",action:close)
    }.padding(.horizontal,22).padding(.vertical,18)
  }
  private var composer:some View {
    VStack(alignment:.leading,spacing:12) {
      if let library=controller.promptLibrary {
        CanvasPromptPresets(library:library,compact:savingPrompt || size.height<640,choose:{controller.updatePrompt($0)},reportError:{localError=$0})
          .disabled(editingDisabled)
      }
      HStack {
        InspectorSectionHeader("PROMPT")
        Spacer()
        CanvasGenerationActionButton(title:"Save prompt…",enabled:!editingDisabled && !prompt.wrappedValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
          action:{savingPrompt.toggle()},identifier:"canvas-generation-save-prompt",prominent:false)
          .disabled(editingDisabled || prompt.wrappedValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
      }
      if savingPrompt {
        HStack(spacing:8) {
          CanvasGenerationTextField(text:$promptName,placeholder:"Prompt name",
            identifier:"canvas-generation-prompt-name",onSubmit:savePrompt)
          Button("Save",action:savePrompt).disabled(promptName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
          WorkspaceToolbarButton("Cancel saving prompt",symbol:"xmark",identifier:"canvas-generation-cancel-save"){savingPrompt=false}
        }.disabled(editingDisabled)
      }
      CanvasGenerationPromptEditor(text:prompt,enabled:!editingDisabled,onSubmit:generate)
        .frame(minHeight:120,maxHeight:.infinity)
        .background(Palette.surface,in:RoundedRectangle(cornerRadius:9))
        .overlay(RoundedRectangle(cornerRadius:9).stroke(Palette.line,lineWidth:0.75).allowsHitTesting(false))
      references
    }
  }
  private var references:some View {
    VStack(alignment:.leading,spacing:8) {
      HStack {
        InspectorSectionHeader("REFERENCES")
        Text("\(controller.presentationReferences.count) / 8").font(.system(size:10)).foregroundStyle(Palette.secondary)
        Spacer()
        Button("Add from Canvas…"){choosingReference.toggle()}
          .font(.system(size:11)).disabled(editingDisabled || (controller.presentationReferences.count)>=8)
          .accessibilityIdentifier("canvas-generation-add-reference")
          .popover(isPresented:$choosingReference,arrowEdge:.bottom){referencePicker}
      }
      if controller.presentationReferences.isEmpty {
        Text("Add an artboard or image for inspiration.")
          .font(.system(size:11)).foregroundStyle(Palette.secondary).padding(.vertical,8)
      } else {
        LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:6) {
          ForEach(controller.presentationReferences) {reference in
            HStack(spacing:6) {
              Image(systemName:reference.elementIDs.isEmpty ? "rectangle" : "photo.on.rectangle").foregroundStyle(Palette.secondary)
              Text(reference.title).font(.system(size:11)).lineLimit(1).help(reference.title)
              Spacer(minLength:0)
              WorkspaceToolbarButton("Remove reference \(reference.title)",symbol:"xmark",identifier:"canvas-generation-remove-reference") {
                controller.removeReference(id:reference.id)
              }.disabled(editingDisabled)
            }.padding(.leading,8).padding(.trailing,3).frame(height:30)
              .background(Palette.surface,in:RoundedRectangle(cornerRadius:6))
          }
        }
      }
    }
  }
  private var referencePicker:some View {
    VStack(alignment:.leading,spacing:12) {
      HStack {InspectorSectionHeader("CANVAS REFERENCES");Spacer();Button("Done"){choosingReference=false}}
      CanvasGenerationTextField(text:$referenceSearch,placeholder:"Find an artboard or image",
        identifier:"canvas-generation-reference-search")
      ScrollView {
        LazyVStack(alignment:.leading,spacing:3) {
          if choices.isEmpty {Text("No matching Canvas artwork.").font(.system(size:12)).foregroundStyle(Palette.secondary).padding(.vertical,12)}
          ForEach(choices) {reference in
            Button {
              if controller.addReference(reference) {choosingReference=false;referenceSearch=""}
            } label: {
              Label(reference.title,systemImage:reference.elementIDs.isEmpty ? "rectangle" : "photo")
                .font(.system(size:12)).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                .padding(8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Add reference \(reference.title)")
          }
        }
      }
    }.padding(16).frame(width:360,height:340).background(Palette.paper).labInterface()
  }
  private var settings:some View {
    VStack(alignment:.leading,spacing:18) {
      InspectorSectionHeader("IMAGE SETTINGS")
      setting("Model") {
        Picker("Model",selection:option(\.model)) {ForEach(StudioGenerationModel.allCases,id:\.self){Text($0.title).tag($0)}}
          .labelsHidden().inspectorPicker().accessibilityIdentifier("canvas-generation-model")
      }
      setting("Quality") {
        Picker("Quality",selection:option(\.quality)){ForEach(StudioGenerationQuality.allCases,id:\.self){Text($0.title).tag($0)}}
          .labelsHidden().inspectorPicker().accessibilityIdentifier("canvas-generation-quality")
      }
      setting("Resolution") {
        Picker("Resolution",selection:option(\.size)){ForEach(StudioGenerationSize.allCases,id:\.self){Text("\($0.title) · \($0.longEdge) px").tag($0)}}
          .labelsHidden().inspectorPicker().accessibilityIdentifier("canvas-generation-resolution")
      }
      setting("Artboard shape") {
        Picker("Artboard shape",selection:Binding<StudioGenerationAspect?>(get:{controller.shapePreset},set:{if let value=$0 {_ = controller.updateShape(value)}})) {
          Text("Custom").tag(Optional<StudioGenerationAspect>.none).disabled(true)
          ForEach(StudioGenerationAspect.allCases,id:\.self){Text($0.title).tag(Optional($0))}
        }.labelsHidden().inspectorPicker().accessibilityIdentifier("canvas-generation-aspect")
      }
      VStack(alignment:.leading,spacing:8) {
        if let pixels=controller.outputPixels {
          Text("\(pixels.width) × \(pixels.height) px").font(.system(size:20,weight:.medium,design:.rounded))
            .accessibilityIdentifier("canvas-generation-output-pixels")
        }
        if let dimensions=controller.destinationSizeMM {
          Text(String(format:"%.1f × %.1f mm on Canvas",dimensions.x,dimensions.y))
            .font(.system(size:11)).foregroundStyle(Palette.secondary)
        }
        Text("Drag the artboard’s edges or corners to choose any shape. Resolution changes image detail, not its size on Canvas.")
          .font(.system(size:11)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      }.padding(.vertical,3)
      Spacer(minLength:0)
      setting("Demo outcome") {
        Picker("Demo outcome",selection:option(\.failureFixture)){ForEach(StudioGenerationFailureFixture.allCases,id:\.self){Text($0.title).tag($0)}}
          .labelsHidden().inspectorPicker().accessibilityIdentifier("canvas-generation-demo-outcome")
      }
    }.disabled(editingDisabled)
  }
  private func setting<V:View>(_ title:String,@ViewBuilder content:()->V)->some View {
    VStack(alignment:.leading,spacing:6) {
      Text(title).font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)
      content().frame(maxWidth:.infinity,alignment:.leading)
    }
  }
  private var footer:some View {
    VStack(alignment:.leading,spacing:10) {
      if let error=localError ?? controller.error ?? controller.outputSizeError {
        Label(error,systemImage:"exclamationmark.circle").font(.system(size:11)).foregroundStyle(Palette.accent)
          .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("canvas-generation-error")
      }
      if controller.busy {ProgressView(value:controller.progress).accessibilityLabel("Image generation progress")}
      HStack(spacing:20) {
        VStack(alignment:.leading,spacing:4) {
          Text(controller.busy ? controller.phase.title : "Local demo · no AI request or charge")
            .font(.system(size:11,weight:.medium)).foregroundStyle(Palette.secondary)
          Text("Return to generate · Shift-Return for a new line").font(.system(size:10)).foregroundStyle(Palette.secondary)
        }
        Spacer(minLength:0)
        if controller.busy {
          CanvasGenerationActionButton(title:"Cancel generation",enabled:true,action:{controller.cancel()},identifier:"canvas-generation-cancel")
            .frame(width:180)
        } else {
          CanvasGenerationActionButton(title:completed ? "Done" : "Generate demo",enabled:completed || controller.canGenerate,action:completed ? close : generate)
            .disabled(!completed && !controller.canGenerate).frame(width:180)
        }
      }
    }.padding(.horizontal,22).padding(.vertical,16)
  }
  private func option<T>(_ key:WritableKeyPath<StudioImageGenerationOptions,T>)->Binding<T> {
    Binding(get:{options[keyPath:key]},set:{var value=options;value[keyPath:key]=$0;controller.updateOptions(value)})
  }
  private func generate() {
    guard controller.canGenerate else{return}
    localError=nil;choosingReference=false
    store.studioImageConnection.useDemoConnection()
    Task {await controller.generate()}
  }
  private func savePrompt() {
    guard let library=controller.promptLibrary else{return}
    do {_ = try library.save(name:promptName,prompt:prompt.wrappedValue);savingPrompt=false;promptName="";localError=nil}
    catch {localError=error.localizedDescription}
  }
}

private struct CanvasPromptPresets:View {
  @ObservedObject var library:ImageGenerationPromptLibrary
  var compact=false
  let choose:(String)->Void
  let reportError:(String)->Void
  var body:some View {
    VStack(alignment:.leading,spacing:8) {
      HStack {
        InspectorSectionHeader("SAVED PROMPTS")
        Spacer()
        CanvasSavedPromptMenu(library:library,choose:choose,reportError:reportError).font(.system(size:11))
      }
      if !compact && library.savedPresets.isEmpty {
        Text("Save a starting point to reuse here and in Studio.")
          .font(.system(size:11)).foregroundStyle(Palette.secondary).padding(.vertical,9)
      } else if !compact {
        HStack(spacing:8) {
          ForEach(Array(library.savedPresets.suffix(3).reversed())) {preset in
            Button {choose(preset.prompt)} label: {
              VStack(alignment:.leading,spacing:5) {
                HStack(spacing:4) {
                  Text(preset.name).font(.system(size:11,weight:.medium)).lineLimit(1)
                  Spacer(minLength:0)
                  Image(systemName:"arrow.down").font(.system(size:10)).foregroundStyle(Palette.secondary)
                }
                Text(preset.prompt).font(.system(size:10)).foregroundStyle(Palette.secondary).lineLimit(2)
                  .frame(maxWidth:.infinity,alignment:.leading)
              }.padding(10).frame(maxWidth:.infinity,minHeight:64,alignment:.topLeading)
                .background(Palette.surface,in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(Palette.line,lineWidth:0.75).allowsHitTesting(false))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).help(preset.prompt).accessibilityLabel("Use prompt "+preset.name)
          }
        }
      }
    }
  }
}

private struct CanvasSavedPromptMenu:View {
  @ObservedObject var library:ImageGenerationPromptLibrary
  let choose:(String)->Void
  let reportError:(String)->Void
  var body:some View {
    Menu("Saved prompts") {
      if library.savedPresets.isEmpty {Text("Save a prompt to reuse it here and in Studio.")}
      ForEach(library.savedPresets) {preset in
        Button(preset.name){choose(preset.prompt)}
      }
      if !library.savedPresets.isEmpty {
        Divider()
        Menu("Remove saved prompt") {
          ForEach(library.savedPresets) {preset in Button(preset.name) {
            do {try library.remove(id:preset.id)} catch {reportError(error.localizedDescription)}
          }}
        }
      }
    }.accessibilityIdentifier("canvas-generation-saved-prompts")
      .onAppear {if let error=library.error {reportError(error)}}
      .onChange(of:library.error) {_,error in if let error {reportError(error)}}
  }
}

struct CanvasGenerationActionButton:NSViewRepresentable {
  let title:String,enabled:Bool,action:()->Void
  var identifier="canvas-generation-submit"
  var prominent=true
  func makeCoordinator()->Coordinator {Coordinator(action)}
  func makeNSView(context:Context)->NSButton {
    let button=NSButton(title:title,target:context.coordinator,action:#selector(Coordinator.press))
    button.bezelStyle = .rounded;button.controlSize = prominent ? .large : .small
    if prominent {button.bezelColor = NSColor(Palette.accent)}
    button.setAccessibilityIdentifier(identifier)
    return button
  }
  func updateNSView(_ view:NSButton,context:Context) {
    context.coordinator.action=action;view.title=title;view.isEnabled=enabled;view.setAccessibilityLabel(title)
  }
  func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSButton,context:Context)->CGSize? {
    .init(width:prominent ? proposal.width ?? 300 : nsView.intrinsicContentSize.width,height:prominent ? 34:20)
  }
  final class Coordinator:NSObject {
    var action:()->Void
    init(_ action:@escaping()->Void){self.action=action}
    @objc func press(){action()}
  }
}

struct CanvasGenerationPromptEditor:NSViewRepresentable {
  @Binding var text:String
  var enabled:Bool
  var onSubmit:()->Void
  func makeCoordinator()->Coordinator {Coordinator(self)}
  func makeNSView(context:Context)->NSScrollView {
    let scroll=NSScrollView(frame:.init(x:0,y:0,width:356,height:112));scroll.hasVerticalScroller=true;scroll.drawsBackground=false
    let editor=CanvasGenerationTextView(frame:scroll.contentView.bounds)
    editor.isRichText=false;editor.isAutomaticQuoteSubstitutionEnabled=false;editor.isAutomaticDashSubstitutionEnabled=false
    editor.allowsUndo=true;editor.drawsBackground=false
    editor.font = .systemFont(ofSize:15);editor.textColor=NSColor(Palette.ink)
    editor.textContainerInset = .init(width:10,height:12)
    editor.autoresizingMask = [.width];editor.isVerticallyResizable=true;editor.isHorizontallyResizable=false
    editor.minSize = .init(width:0,height:112)
    editor.maxSize = .init(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
    editor.textContainer?.containerSize = .init(width:scroll.contentSize.width,height:CGFloat.greatestFiniteMagnitude)
    editor.textContainer?.widthTracksTextView=true
    editor.delegate=context.coordinator;editor.submit=onSubmit
    editor.setAccessibilityLabel("Image prompt");editor.setAccessibilityIdentifier("canvas-generation-prompt")
    scroll.documentView=editor
    return scroll
  }
  func updateNSView(_ view:NSScrollView,context:Context) {
    context.coordinator.parent=self
    guard let editor=view.documentView as? CanvasGenerationTextView else{return}
    if editor.string != text {editor.string=text;editor.undoManager?.removeAllActions()}
    editor.isEditable=enabled;editor.submit=onSubmit
    editor.needsDisplay=true
  }
  final class Coordinator:NSObject,NSTextViewDelegate {
    var parent:CanvasGenerationPromptEditor
    init(_ parent:CanvasGenerationPromptEditor){self.parent=parent}
    func textDidChange(_ notification:Notification) {
      guard let editor=notification.object as? NSTextView else{return};parent.text=editor.string
    }
  }
}

final class CanvasGenerationTextView:NSTextView {
  var submit:(()->Void)?
  private var requestedInitialFocus=false
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard !requestedInitialFocus,let targetWindow=window else{return}
    requestedInitialFocus=true
    DispatchQueue.main.async { [weak self,weak targetWindow] in
      guard let self,let targetWindow,self.window === targetWindow,self.isEditable else{return}
      // An initial presentation may already have given another field focus.
      // Never take it back, including after SwiftUI reparents this scroll view.
      if let other=targetWindow.firstResponder as? NSView,other !== self,
        (other as? NSTextView)?.isEditable == true || (other as? NSTextField)?.isEditable == true {return}
      targetWindow.makeKey()
      targetWindow.contentView?.layoutSubtreeIfNeeded()
      targetWindow.makeFirstResponder(self)
    }
  }
  override func keyDown(with event:NSEvent) {
    if event.keyCode==36 || event.keyCode==76 {
      if !hasMarkedText() {
        if event.modifierFlags.contains(.shift) {insertText("\n",replacementRange:selectedRange())}
        else {submit?()}
        return
      }
    }
    super.keyDown(with:event)
  }
  override func draw(_ dirtyRect:NSRect) {
    super.draw(dirtyRect)
    if string.isEmpty {
      ("Describe the image you want to make…" as NSString).draw(in:bounds.insetBy(dx:15,dy:12),
        withAttributes:[.font:NSFont.systemFont(ofSize:15),.foregroundColor:NSColor.placeholderTextColor])
    }
  }
}

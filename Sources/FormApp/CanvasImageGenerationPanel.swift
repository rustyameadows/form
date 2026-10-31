import AppKit
import FormCore
import SwiftUI

extension VectorCanvasView {
  func showCanvasImagePrompt() {
    guard let store=session?.store,let draft=store.canvasImages.draft,window != nil else{return}
    closeCanvasImagePrompt()
    synchronize()
    _ = fit(frameIDs:[draft.destinationID])
    guard let frame=session?.frames.first(where:{$0.object.id==draft.destinationID}) else{return}
    let popover=NSPopover()
    popover.behavior = .transient
    popover.animates=false
    popover.contentViewController=NSHostingController(rootView:
      CanvasImageGenerationPanel(controller:store.canvasImages,store:store) { [weak self,weak store] in
        guard let self else{return}
        if store?.canvasImages.draft?.status == .succeeded {
          self.synchronize();_ = self.fit(frameIDs:[draft.destinationID])
        }
        self.closeCanvasImagePrompt()
      })
    popover.contentSize=NSSize(width:392,height:530)
    imagePromptPopover=popover
    let anchor=documentPoint(CGPoint(x:frame.rect.midX,y:frame.rect.maxY))
    popover.show(relativeTo:NSRect(x:anchor.x-1,y:anchor.y-1,width:2,height:2),of:self,preferredEdge:.maxY)
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
  let close:()->Void
  @State private var choosingReference=false
  @State private var referenceSearch=""
  @State private var savingPrompt=false
  @State private var promptName=""
  @State private var localError:String?
  private var prompt:Binding<String> {Binding(get:{controller.draft?.prompt ?? ""},set:{controller.updatePrompt($0)})}
  private var options:StudioImageGenerationOptions {controller.draft?.options ?? .init()}
  private var completed:Bool {controller.draft?.status == .succeeded}
  private var choices:[CanvasGenerationReference] {
    guard let project=store.project else{return []}
    let selected=Set(controller.draft?.references.map(\.id) ?? [])
    return CanvasGenerationReferenceCapture.choices(in:project).filter {
      $0.objectID != controller.draft?.destinationID && !selected.contains($0.id)
        && (referenceSearch.isEmpty || $0.title.localizedStandardContains(referenceSearch))
    }
  }
  var body:some View {
    let availableReferences=choosingReference ? choices : []
    VStack(spacing:0) {
      HStack(spacing:10) {
        Image(systemName:"sparkles").font(.system(size:18)).foregroundStyle(Palette.accent)
        VStack(alignment:.leading,spacing:3) {
          Text(completed ? "Image added" : "Generate image").font(.system(size:17,weight:.semibold))
          Text("Local demo · nothing is sent").font(.system(size:10)).foregroundStyle(Palette.secondary)
        }
        Spacer()
        WorkspaceToolbarButton("Close image prompt",symbol:"xmark",identifier:"canvas-generation-close",action:close)
      }.padding(18)
      Divider()
      ScrollView {
        VStack(alignment:.leading,spacing:16) {
          if completed {
            Label("Your image is on the Canvas.",systemImage:"checkmark.circle.fill")
              .font(.system(size:13,weight:.medium)).foregroundStyle(Palette.ink)
            Text("Move, resize, crop or group it like any other image. Right-click it to start another image using this one as a reference.")
              .font(.system(size:12)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
          }
          CanvasGenerationPromptEditor(text:prompt,enabled:!controller.busy && !completed,onSubmit:generate)
            .frame(height:112).background(Palette.surface,in:RoundedRectangle(cornerRadius:9))
            .overlay(RoundedRectangle(cornerRadius:9).stroke(Palette.line,lineWidth:1).allowsHitTesting(false))
          if !completed {
            HStack {
              if let library=controller.promptLibrary {
                CanvasSavedPromptMenu(library:library,choose:{controller.updatePrompt($0)},reportError:{localError=$0})
              }
              Spacer()
              CanvasGenerationActionButton(title:"Save prompt…",enabled:!prompt.wrappedValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                action:{savingPrompt.toggle()},identifier:"canvas-generation-save-prompt",prominent:false)
                .disabled(prompt.wrappedValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }.font(.system(size:11)).disabled(controller.busy)
            if savingPrompt {
              HStack {
                CanvasGenerationTextField(text:$promptName,placeholder:"Prompt name",
                  identifier:"canvas-generation-prompt-name",onSubmit:savePrompt)
                Button("Save",action:savePrompt).disabled(promptName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
              }.disabled(controller.busy)
            }
          }
          VStack(alignment:.leading,spacing:10) {
            HStack {
              Text("REFERENCES").font(.system(size:10,weight:.semibold)).tracking(0.8).foregroundStyle(Palette.secondary)
              Spacer()
              if !completed {Button(choosingReference ? "Done" : "Add from Canvas…") {choosingReference.toggle()}.font(.system(size:11)).disabled(controller.busy)}
            }
            ForEach(controller.draft?.references ?? []) {reference in
              HStack(spacing:8) {
                Image(systemName:reference.elementIDs.isEmpty ? "rectangle" : "photo.on.rectangle").foregroundStyle(Palette.secondary)
                Text(reference.title).font(.system(size:12)).lineLimit(2)
                Spacer()
                if !completed {
                  WorkspaceToolbarButton("Remove reference \(reference.title)",symbol:"xmark",identifier:"canvas-generation-remove-reference") {
                    controller.removeReference(id:reference.id)
                  }.disabled(controller.busy)
                }
              }.padding(7).background(Palette.surface,in:RoundedRectangle(cornerRadius:7))
            }
            if controller.draft?.references.isEmpty == true && !choosingReference {
              Text(completed ? "No reference images used." : "Start with words, or add artwork for inspiration.")
                .font(.system(size:11)).foregroundStyle(Palette.secondary)
            }
            if choosingReference && !completed {
              CanvasGenerationTextField(text:$referenceSearch,placeholder:"Find an artboard or image",
                identifier:"canvas-generation-reference-search")
              if availableReferences.isEmpty {Text("No matching Canvas artwork.").font(.system(size:11)).foregroundStyle(Palette.secondary)}
              ForEach(Array(availableReferences.prefix(40))) {reference in
                Button {
                  if controller.addReference(reference) {choosingReference=false;referenceSearch=""}
                } label: {
                  Label(reference.title,systemImage:reference.elementIDs.isEmpty ? "rectangle" : "photo")
                    .font(.system(size:12)).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,5).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Add reference \(reference.title)")
              }
              if availableReferences.count>40 {Text("Search to narrow \(availableReferences.count) items.").font(.system(size:10)).foregroundStyle(Palette.secondary)}
            }
          }.disabled(controller.busy)
          Divider()
          VStack(spacing:10) {
            Picker("Model",selection:option(\.model)) {
              ForEach(StudioGenerationModel.allCases,id:\.self) {Text($0.title).tag($0)}
            }.accessibilityIdentifier("canvas-generation-model")
            Picker("Shape",selection:option(\.aspect)) {
              ForEach(StudioGenerationAspect.allCases,id:\.self) {Text($0.title).tag($0)}
            }.accessibilityIdentifier("canvas-generation-aspect")
            DisclosureGroup("Output settings") {
              VStack(spacing:10) {
                Picker("Size",selection:option(\.size)) {ForEach(StudioGenerationSize.allCases,id:\.self){Text($0.title).tag($0)}}
                Picker("Quality",selection:option(\.quality)) {ForEach(StudioGenerationQuality.allCases,id:\.self){Text($0.title).tag($0)}}
                Picker("Demo outcome",selection:option(\.failureFixture)) {ForEach(StudioGenerationFailureFixture.allCases,id:\.self){Text($0.title).tag($0)}}
                Text("Shared with Studio. Live generation will use your connected provider; this build makes labeled demo images locally.")
                  .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
              }.padding(.top,10)
            }
          }.font(.system(size:12)).disabled(controller.busy || completed)
          if let error=localError ?? controller.error {
            Text(error).font(.system(size:11)).foregroundStyle(Palette.accent).fixedSize(horizontal:false,vertical:true)
              .accessibilityIdentifier("canvas-generation-error")
          }
        }.padding(18)
      }
      Divider()
      VStack(spacing:8) {
        if controller.busy {
          ProgressView(value:controller.progress).accessibilityLabel("Image generation progress")
          HStack {
            Text(controller.phase.title).font(.system(size:11)).foregroundStyle(Palette.secondary)
            Spacer()
            Button("Cancel generation"){controller.cancel()}.font(.system(size:11))
          }
        } else if completed {
          CanvasGenerationActionButton(title:"Done",enabled:true,action:close)
        } else {
          CanvasGenerationActionButton(title:"Generate demo",enabled:controller.canGenerate,action:generate)
            .disabled(!controller.canGenerate)
          Text("Return to generate · Shift-Return for a new line").font(.system(size:10)).foregroundStyle(Palette.secondary)
        }
      }.padding(16)
    }.frame(width:392,height:530).background(Palette.paper).labInterface()
      .onChange(of:controller.draft?.status) {_,status in
        if status == .succeeded {close()}
      }
  }
  private func option<T>(_ key:WritableKeyPath<StudioImageGenerationOptions,T>)->Binding<T> {
    Binding(get:{options[keyPath:key]},set:{var value=options;value[keyPath:key]=$0;controller.updateOptions(value)})
  }
  private func generate() {
    guard controller.canGenerate else{return}
    localError=nil
    choosingReference=false
    store.studioImageConnection.useDemoConnection()
    Task {await controller.generate()}
  }
  private func savePrompt() {
    guard let library=controller.promptLibrary else{return}
    do {_ = try library.save(name:promptName,prompt:prompt.wrappedValue);savingPrompt=false;promptName="";localError=nil}
    catch {localError=error.localizedDescription}
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

import SwiftUI
import UniformTypeIdentifiers

@MainActor struct StudioImageWorkspace:View {
  @ObservedObject var controller:StudioImageGenerationController
  @ObservedObject var library:StudioAssetLibrary
  @ObservedObject private var connection:OpenAIConnectionPreviewController
  var onBack:()->Void
  var onConnection:(()->Void)?
  var onUseInCanvas:((UUID)->Void)?
  @StateObject private var reviewer=StudioImageReviewPresenter()
  @State private var showingSettings=false
  @State private var showingPromptPresetName=false
  @State private var promptPresetName=""
  @State private var promptPresetIssue:String?
  @State private var showingConnection=false
  @State private var showingImporter=false
  @State private var showingReferencePicker=false
  @State private var chosenReference:UUID?
  @State private var referenceProjectID:UUID?
  @State private var selectedAssetID:UUID?
  @State private var showingPresetName=false
  @State private var presetName=""
  @State private var presetIssue:String?
  @State private var importing=false
  @State private var issue:String?

  init(controller:StudioImageGenerationController,library:StudioAssetLibrary,onBack:@escaping()->Void={},onConnection:(()->Void)?=nil,onUseInCanvas:((UUID)->Void)?=nil) {
    self.controller=controller;self.library=library;self.onBack=onBack;self.onConnection=onConnection
    self.onUseInCanvas=onUseInCanvas
    _connection=ObservedObject(wrappedValue:controller.connection)
  }
  private var editingDisabled:Bool {controller.busy || controller.isCapturing || importing}
  var body:some View {
    VStack(spacing:0) {
      header
      Divider()
      GeometryReader {geometry in
        let layout=StudioImageAuthoringLayout(width:geometry.size.width,height:geometry.size.height,
          hasReferences:!controller.references.isEmpty,hasMessage:issue != nil || controller.error != nil,isBusy:controller.busy || controller.isCapturing)
        HStack(spacing:0) {
          StudioImageInputPanel(controller:controller,library:library).frame(width:layout.inputWidth)
          Divider()
          composer(layout).frame(maxWidth:.infinity,maxHeight:.infinity)
          Divider()
          StudioImageOutputRail(controller:controller,library:library,selectedAssetID:selectedAssetID,onPreview:review)
            .frame(width:layout.outputWidth)
        }
      }
    }.background(Palette.paper)
      .sheet(isPresented:$showingConnection) {
        OpenAIConnectionPreviewView(controller:connection){showingConnection=false}
      }
      .sheet(isPresented:$showingReferencePicker) {
        referencePicker
      }
      .sheet(isPresented:$showingPresetName){presetSheet}
      .sheet(isPresented:$showingPromptPresetName){promptPresetSheet}
      .onDisappear{reviewer.close()}
      .onChange(of:library.projectID){_,_ in reviewer.close()}
      .onChange(of:controller.store?.project?.id){_,id in if id != controller.projectID {reviewer.close()}}
      .fileImporter(isPresented:$showingImporter,allowedContentTypes:[.png,.jpeg,.heic,.tiff,.webP],allowsMultipleSelection:true) {result in
        switch result {case .success(let urls):importReferences(urls);case .failure(let error):issue=error.localizedDescription}
      }
      .onChange(of:chosenReference){_,id in
        guard let id else{return}
        if controller.store?.project?.id==referenceProjectID {controller.addReference(assetID:id,role:.style)}
        showingReferencePicker=false
      }

  }
  private var header:some View {
    HStack(spacing:12) {
      WorkspaceToolbarButton("Back to composition",symbol:"chevron.left",showsTitle:true,identifier:"studio-image-back") {
        onBack()
      }
      Text("Create still").font(.system(size:17,weight:.semibold))
      StudioDemoBadge()
      Spacer(minLength:4)
      WorkspaceToolbarButton(connection.state == .demoReady ? "Demo connection":"Connection settings",
        symbol:connection.state == .demoReady ? "checkmark.shield":"key",showsTitle:true,identifier:"studio-image-connection"){openConnection()}
      WorkspaceToolbarButton("Create another image",symbol:"plus",identifier:"studio-image-new") {
        controller.newRun();selectedAssetID=nil
      }.disabled(editingDisabled)
    }.padding(.horizontal,16).padding(.vertical,9)
  }
  private func composer(_ layout:StudioImageAuthoringLayout)->some View {
    VStack(alignment:.leading,spacing:layout.spacing) {
      promptPresets(height:layout.presetHeight)
      HStack {
        InspectorSectionHeader("PROMPT")
        Spacer()
        WorkspaceToolbarButton("Save prompt preset",symbol:"square.and.arrow.down",identifier:"studio-image-save-prompt") {
          promptPresetName="";promptPresetIssue=nil;showingPromptPresetName=true
        }.disabled(editingDisabled || controller.prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
      }
      TextEditor(text:$controller.prompt).font(.system(size:13)).scrollContentBackground(.hidden)
        .padding(10).frame(minHeight:180,maxHeight:.infinity)
        .background(Palette.surface,in:RoundedRectangle(cornerRadius:9))
        .overlay(RoundedRectangle(cornerRadius:9).stroke(Palette.line,lineWidth:0.75).allowsHitTesting(false))
        .overlay(alignment:.topLeading) {
          if controller.prompt.isEmpty {Text("Describe the image you want to make…").font(.system(size:13)).foregroundStyle(Palette.secondary).padding(15).allowsHitTesting(false).accessibilityHidden(true)}
        }
        .accessibilityLabel("Image prompt").accessibilityIdentifier("studio-image-prompt")
        .disabled(editingDisabled)
      if !controller.references.isEmpty {
        ScrollView {
          LazyVStack(spacing:8){ForEach(controller.references){reference in referenceRow(reference)}}
        }.frame(height:layout.referenceHeight).disabled(editingDisabled)
      }
      composerFooter
    }.padding(16)
  }
  private func promptPresets(height:CGFloat)->some View {
    VStack(alignment:.leading,spacing:9) {
      InspectorSectionHeader("PROMPT PRESETS",subtitle:"Choose a starting point, then make it yours.")
      ScrollView {
        LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:8),count:3),spacing:8) {
          ForEach(controller.promptPresets){preset in
            VStack(alignment:.leading,spacing:4) {
              HStack(spacing:2) {
                Text(preset.name).font(.system(size:11,weight:.medium)).lineLimit(1)
                Spacer(minLength:0)
                WorkspaceToolbarButton("Use prompt "+preset.name,symbol:"arrow.down",identifier:"studio-image-preset-"+preset.id.uuidString) {
                  controller.applyPromptPreset(preset)
                }
              }
              Text(preset.prompt).font(.system(size:10)).foregroundStyle(Palette.secondary).lineLimit(2)
                .frame(maxWidth:.infinity,alignment:.leading)
            }.padding(.horizontal,9).padding(.bottom,8)
              .frame(maxWidth:.infinity,minHeight:76,alignment:.topLeading)
              .background(Palette.surface,in:RoundedRectangle(cornerRadius:8))
              .overlay(RoundedRectangle(cornerRadius:8).stroke(Palette.line,lineWidth:0.75).allowsHitTesting(false))
              .contentShape(Rectangle()).onTapGesture{if !editingDisabled {controller.applyPromptPreset(preset)}}
              .help(preset.prompt)
          }
        }
      }.frame(height:height).disabled(editingDisabled)
    }
  }
  private var composerFooter:some View {
    VStack(alignment:.leading,spacing:10) {
      if controller.busy || controller.isCapturing {progress}
      if let message=issue ?? controller.error {errorBanner(message)}
      HStack(spacing:5) {
        WorkspaceToolbarButton("Upload reference",symbol:"square.and.arrow.up",identifier:"studio-image-upload") {
          referenceProjectID=controller.store?.project?.id;showingImporter=true
        }.disabled(editingDisabled)
        WorkspaceToolbarButton("Choose reference from Library",symbol:"photo.on.rectangle",identifier:"studio-image-library") {
          referenceProjectID=controller.store?.project?.id;chosenReference=nil;showingReferencePicker=true
        }.disabled(editingDisabled)
        Picker("Model",selection:$controller.options.model){ForEach(StudioGenerationModel.allCases,id:\.self){Text($0.title).tag($0)}}
          .labelsHidden().inspectorPicker().frame(maxWidth:170).disabled(editingDisabled)
        WorkspaceToolbarButton("Image settings",symbol:"slider.horizontal.3",identifier:"studio-image-settings"){showingSettings.toggle()}
          .disabled(editingDisabled)
          .popover(isPresented:$showingSettings){settingsPanel}
        Spacer(minLength:0)
        if controller.busy {
          WorkspaceToolbarButton("Cancel demo generation",symbol:"xmark",showsTitle:true,identifier:"studio-image-cancel"){controller.cancel()}
        }else {
          WorkspaceToolbarButton(primaryTitle,symbol:controller.capture==nil ? "camera":"sparkles",isSelected:true,showsTitle:true,identifier:"studio-image-generate"){performPrimary()}
            .disabled(controller.isCapturing || importing)
        }
      }
      Text("Local demo · no AI request or charge. \(controller.options.pixels.width) × \(controller.options.pixels.height) px · \(controller.options.count) image(s)")
        .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
    }
  }
  private var settingsPanel:some View {
    VStack(spacing:0) {
      HStack {Text("Image settings").font(.system(size:14,weight:.semibold));Spacer();AppCloseButton("Close image settings"){showingSettings=false}}.padding(16)
      Divider()
      ScrollView {
        VStack(alignment:.leading,spacing:18) {
          imageSettings
          InspectorDivider()
          styleSettings
          InspectorDivider()
          Menu {
            ForEach(StudioGenerationFailureFixture.allCases,id:\.self){fixture in
              Button{controller.options.failureFixture=fixture}label:{Label(fixture.title,systemImage:controller.options.failureFixture==fixture ? "checkmark":"circle")}
            }
          }label:{Label("Demo scenario",systemImage:"slider.horizontal.3")}
            .accessibilityIdentifier("studio-image-scenario")
          Text(controller.options.failureFixture.title).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
        }.padding(16)
      }
    }.frame(width:350,height:540).background(Palette.paper)
  }
  private func review(_ runID:UUID,_ assetID:UUID?) {
    selectedAssetID=assetID
    reviewer.show(controller:controller,library:library,runID:runID,assetID:assetID,onUseInCanvas:onUseInCanvas)
  }
  private var styleSettings:some View {
    VStack(alignment:.leading,spacing:9) {
      HStack {
        InspectorSectionHeader("STYLE")
        Menu("Presets") {
          ForEach(controller.stylePresets){preset in Button(preset.name){controller.applyStylePreset(preset)}}
        }.menuStyle(.borderlessButton).fixedSize()
      }
      TextEditor(text:$controller.style).font(InspectorStyle.labelFont).scrollContentBackground(.hidden)
        .padding(7).frame(height:65).background(Palette.surface,in:RoundedRectangle(cornerRadius:8))
        .accessibilityLabel("Image style instructions").accessibilityIdentifier("studio-image-style")
      Button("Save as style preset…"){presetName="";presetIssue=nil;showingPresetName=true}.font(InspectorStyle.captionFont)
    }
  }
  private func referenceRow(_ reference:StudioGenerationReference)->some View {
    HStack(spacing:8) {
      StudioAssetImageView(library:library,assetID:reference.assetID,maximumPixelSize:160,label:"Reference image").frame(width:44,height:44).clipShape(RoundedRectangle(cornerRadius:5))
      VStack(alignment:.leading,spacing:4) {
        Text(library.asset(id:reference.assetID)?.name ?? "Unavailable reference").font(InspectorStyle.labelFont).lineLimit(1)
        Picker("Reference role",selection:Binding(get:{controller.references.first{$0.assetID==reference.assetID}?.role ?? reference.role},set:{role in
          if let index=controller.references.firstIndex(where:{$0.assetID==reference.assetID}) {controller.references[index].role=role}
        })) {ForEach(StudioGenerationReference.Role.allCases,id:\.self){role in Text(role.title).tag(role)}}.inspectorPicker().labelsHidden()
      }.frame(maxWidth:.infinity,alignment:.leading)
      AppCloseButton("Remove reference image"){controller.removeReference(assetID:reference.assetID)}
    }
  }
  private var imageSettings:some View {
    VStack(spacing:9) {
      InspectorSectionHeader("OPENAI · GPT IMAGE")
      InspectorRow("Model") {Picker("Model",selection:$controller.options.model){ForEach(StudioGenerationModel.allCases,id:\.self){Text($0.title).tag($0)}}.labelsHidden().inspectorPicker()}
      InspectorRow("Quality") {Picker("Quality",selection:$controller.options.quality){ForEach(StudioGenerationQuality.allCases,id:\.self){Text($0.title).tag($0)}}.labelsHidden().inspectorPicker()}
      InspectorRow("Aspect") {Picker("Aspect",selection:$controller.options.aspect){ForEach(StudioGenerationAspect.allCases,id:\.self){Text($0.title).tag($0)}}.labelsHidden().inspectorPicker()}
      InspectorRow("Size") {Picker("Size",selection:$controller.options.size){ForEach(StudioGenerationSize.allCases,id:\.self){Text($0.title).tag($0)}}.labelsHidden().inspectorPicker()}
      InspectorRow("Images") {Picker("Image count",selection:$controller.options.count){ForEach([1,2,4],id:\.self){Text(String($0)).tag($0)}}.labelsHidden().inspectorSegmented().frame(width:155)}
      Text("\(controller.options.pixels.width) × \(controller.options.pixels.height) pixels per image")
        .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary).frame(maxWidth:.infinity,alignment:.trailing)
    }
  }
  private var progress:some View {
    HStack(spacing:10) {
      ProgressView(value:controller.progress).frame(maxWidth:.infinity)
      Text(controller.phase.title).font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)
      Text("\(Int(controller.progress*100))%").font(InspectorStyle.valueFont).frame(width:35,alignment:.trailing)
    }.accessibilityElement(children:.combine).accessibilityIdentifier("studio-image-progress")
  }
  private func errorBanner(_ message:String)->some View {
    HStack(spacing:8) {
      Image(systemName:"exclamationmark.circle")
      Text(message).font(InspectorStyle.labelFont).lineLimit(2).help(message)
      Spacer(minLength:4)
      WorkspaceToolbarButton("Retry",symbol:"arrow.clockwise",showsTitle:true,identifier:"studio-image-retry"){issue=nil;Task{await controller.retry()}}.disabled(editingDisabled || controller.currentRun == nil)
      AppCloseButton("Dismiss image message"){issue=nil;controller.dismissError()}
    }.foregroundStyle(Palette.accent).padding(10).background(Palette.accent.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
  }
  private var primaryTitle:String {
    if controller.capture == nil {return "Capture scene"}
    if connection.state != .demoReady {return "Connect with demo"}
    return controller.options.count == 1 ? "Generate":"Generate \(controller.options.count)"
  }
  private func performPrimary() {
    issue=nil
    if controller.capture == nil {Task{await controller.captureScene()}}
    else if connection.state != .demoReady {openConnection()}
    else {selectedAssetID=nil;Task{await controller.generate()}}
  }
  private func openConnection(){if let onConnection {onConnection()}else{showingConnection=true}}
  private var referencePicker:some View {
    VStack(spacing:0) {
      HStack {
        Text("Choose reference").font(.system(size:16,weight:.semibold));Spacer()
        AppCloseButton("Close reference picker",keyEquivalent:"\u{1b}"){showingReferencePicker=false}
      }.padding(.horizontal,14).padding(.top,12)
      StudioAssetPicker(library:library,selection:$chosenReference)
    }.frame(minWidth:580,minHeight:450).background(Palette.paper)
  }
  private var promptPresetSheet:some View {
    VStack(alignment:.leading,spacing:16) {
      HStack {Text("Save prompt preset").font(.system(size:16,weight:.semibold));Spacer();AppCloseButton("Close prompt preset"){showingPromptPresetName=false}}
      TextField("Preset name",text:$promptPresetName).textFieldStyle(InspectorTextFieldStyle())
      Text("Saves this prompt in the current project. Applying it changes only the prompt.").font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)
      if let promptPresetIssue {Text(promptPresetIssue).font(InspectorStyle.captionFont).foregroundStyle(Palette.accent)}
      HStack {Spacer();Button("Save preset"){
        do{try controller.savePromptPreset(name:promptPresetName);showingPromptPresetName=false;promptPresetIssue=nil}catch{promptPresetIssue=error.localizedDescription}
      }.buttonStyle(.borderedProminent).tint(Palette.ink).disabled(promptPresetName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
    }.padding(24).frame(width:400).background(Palette.paper)
  }
  private var presetSheet:some View {
    VStack(alignment:.leading,spacing:16) {
      HStack {Text("Save style preset").font(.system(size:16,weight:.semibold));Spacer();AppCloseButton("Close style preset"){showingPresetName=false}}
      TextField("Preset name",text:$presetName).textFieldStyle(InspectorTextFieldStyle())
      Text("Saves these style instructions and reference choices for another image.").font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)
      if let presetIssue {Text(presetIssue).font(InspectorStyle.captionFont).foregroundStyle(Palette.accent)}
      HStack {Spacer();Button("Save preset"){
        do{try controller.saveStylePreset(name:presetName);showingPresetName=false;presetIssue=nil}catch{presetIssue=error.localizedDescription}
      }.buttonStyle(.borderedProminent).tint(Palette.ink).disabled(presetName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
    }.padding(24).frame(width:400).background(Palette.paper)
  }
  private func importReferences(_ urls:[URL]) {
    guard controller.store?.project?.id==referenceProjectID else{return}
    let projectID=referenceProjectID
    importing=true
    Task {
      defer{importing=false}
      do {
        for url in urls {
          let access=url.startAccessingSecurityScopedResource();defer{if access {url.stopAccessingSecurityScopedResource()}}
          let asset=try await library.importFile(url)
          guard !Task.isCancelled,controller.store?.project?.id==projectID else{return}
          controller.addReference(assetID:asset.id,role:.style)
        }
        issue=nil
      }catch{issue=error.localizedDescription}
    }
  }
}

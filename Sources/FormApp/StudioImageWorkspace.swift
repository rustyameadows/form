import SwiftUI
import UniformTypeIdentifiers

struct StudioImageWorkspace:View {
  @ObservedObject var controller:StudioImageGenerationController
  @ObservedObject var library:StudioAssetLibrary
  @ObservedObject private var connection:OpenAIConnectionPreviewController
  var onBack:()->Void
  var onConnection:(()->Void)?
  var onUseInCanvas:((UUID)->Void)?
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
  private var outputs:[UUID] {controller.currentRun?.outputAssetIDs ?? []}
  private var selectedOutput:UUID? {selectedAssetID.flatMap{outputs.contains($0) ? $0:nil} ?? outputs.first}
  private var editingDisabled:Bool {controller.busy || controller.isCapturing || importing}
  var body:some View {
    VStack(spacing:0) {
      header
      Divider()
      HStack(spacing:0) {
        VStack(spacing:14) {
          if controller.capture != nil && controller.isCaptureStale {staleBanner}
          StudioImageResultReview(controller:controller,library:library,selectedAssetID:$selectedAssetID,
            onIterate:{id in controller.iterate(resultAssetID:id)},onRegenerate:{Task{await controller.retry()}},onUseInCanvas:onUseInCanvas)
            .frame(minHeight:220,maxHeight:.infinity)
          if controller.busy || controller.isCapturing {progress}
          if !outputs.isEmpty {outputGrid}
          if !controller.history.isEmpty {history}
          if let message=issue ?? controller.error {errorBanner(message)}
        }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity)
        Divider()
        sidebar.frame(width:320)
      }
    }.background(Palette.paper)
      .sheet(isPresented:$showingConnection) {
        OpenAIConnectionPreviewView(controller:connection){showingConnection=false}
      }
      .sheet(isPresented:$showingReferencePicker) {
        referencePicker
      }
      .sheet(isPresented:$showingPresetName){presetSheet}
      .fileImporter(isPresented:$showingImporter,allowedContentTypes:[.png,.jpeg,.heic,.tiff,.webP],allowsMultipleSelection:true) {result in
        switch result {case .success(let urls):importReferences(urls);case .failure(let error):issue=error.localizedDescription}
      }
      .onChange(of:chosenReference){_,id in
        guard let id else{return}
        if controller.store?.project?.id==referenceProjectID {controller.addReference(assetID:id,role:.style)}
        showingReferencePicker=false
      }
      .onChange(of:controller.selectedRunID){_,_ in selectedAssetID=controller.currentRun?.outputAssetIDs.first}
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
  private var staleBanner:some View {
    HStack(spacing:8) {
      Image(systemName:"camera.badge.ellipsis")
      Text("Scene changed. The next image still uses your frozen input.").font(InspectorStyle.labelFont)
      Spacer(minLength:4)
      Button("Recapture"){Task{await controller.captureScene()}}.disabled(editingDisabled)
    }.padding(10).background(Palette.accent.opacity(0.08),in:RoundedRectangle(cornerRadius:8))
  }
  private var sidebar:some View {
    VStack(spacing:0) {
      ScrollView {
        VStack(alignment:.leading,spacing:18) {
          InspectorSectionHeader("NEXT IMAGE")
          if let capture=controller.capture {
            HStack(spacing:9) {
              StudioAssetImageView(library:library,assetID:capture.inputAssetID,maximumPixelSize:180,label:"Next image scene input")
                .frame(width:58,height:43).clipShape(RoundedRectangle(cornerRadius:5))
              VStack(alignment:.leading,spacing:3) {
                Text("Scene input").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
                Text(capture.scene.name).font(InspectorStyle.labelFont).lineLimit(1)
                Text(capture.createdAt.formatted(date:.omitted,time:.shortened)).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
              }
            }
          }
          TextEditor(text:$controller.prompt).font(.system(size:12)).scrollContentBackground(.hidden)
            .padding(7).frame(height:118).background(Palette.surface,in:RoundedRectangle(cornerRadius:8))
            .overlay(RoundedRectangle(cornerRadius:8).stroke(Palette.line,lineWidth:0.75))
            .overlay(alignment:.topLeading) {
              if controller.prompt.isEmpty {Text("Describe the image you want to make…").font(.system(size:12)).foregroundStyle(Palette.secondary).padding(12).allowsHitTesting(false).accessibilityHidden(true)}
            }
            .accessibilityLabel("Image prompt").accessibilityIdentifier("studio-image-prompt")
          styleSettings
          InspectorDivider()
          referenceSettings
          InspectorDivider()
          imageSettings
          InspectorDivider()
          Menu {
            ForEach(StudioGenerationFailureFixture.allCases,id:\.self){fixture in
              Button{controller.options.failureFixture=fixture}label:{Label(fixture.title,systemImage:controller.options.failureFixture==fixture ? "checkmark":"circle")}
            }
          }label:{Label("Demo scenario",systemImage:"slider.horizontal.3")}
            .help("Try success, authentication, rate-limit, offline or refusal states without contacting a service")
            .accessibilityIdentifier("studio-image-scenario")
          if controller.options.failureFixture != .none {Text(controller.options.failureFixture.title).font(InspectorStyle.captionFont).foregroundStyle(Palette.accent)}
        }.padding(16).disabled(editingDisabled)
      }
      Divider()
      VStack(alignment:.leading,spacing:9) {
        if controller.busy {
          Button("Cancel demo generation"){controller.cancel()}.frame(maxWidth:.infinity).accessibilityIdentifier("studio-image-cancel")
        }else {
          Button(primaryTitle){performPrimary()}.buttonStyle(.borderedProminent).tint(Palette.ink).controlSize(.large)
            .frame(maxWidth:.infinity).disabled(controller.isCapturing || importing).accessibilityIdentifier("studio-image-generate")
        }
        Text("Local demo PNGs from your captured scene. No AI request or charge.").font(InspectorStyle.captionFont)
          .foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      }.padding(16)
    }
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
  private var referenceSettings:some View {
    VStack(alignment:.leading,spacing:10) {
      InspectorSectionHeader("REFERENCES",subtitle:"Optional images for style, subject or composition.")
      HStack {
        Button{referenceProjectID=controller.store?.project?.id;showingImporter=true}label:{Label("Upload",systemImage:"square.and.arrow.up")}.accessibilityIdentifier("studio-image-upload")
        Button{referenceProjectID=controller.store?.project?.id;chosenReference=nil;showingReferencePicker=true}label:{Label("Library",systemImage:"photo.on.rectangle")}.accessibilityIdentifier("studio-image-library")
      }
      ForEach(controller.references){reference in referenceRow(reference)}
      if controller.references.isEmpty {Text("No reference images").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
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
  private var outputGrid:some View {
    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:8),count:min(4,max(1,outputs.count))),spacing:8) {
      ForEach(outputs,id:\.self){id in
        Button{selectedAssetID=id}label:{
          StudioAssetImageView(library:library,assetID:id,maximumPixelSize:320,label:library.asset(id:id)?.name ?? "Demo image")
            .frame(height:84).overlay(alignment:.topLeading){Text("Demo").font(.system(size:9,weight:.semibold)).padding(4).background(Palette.paper.opacity(0.9),in:RoundedRectangle(cornerRadius:4)).padding(5)}
            .clipShape(RoundedRectangle(cornerRadius:6)).overlay(RoundedRectangle(cornerRadius:6).stroke(selectedOutput==id ? Palette.accent:Palette.line,lineWidth:selectedOutput==id ? 2:0.75))
        }.buttonStyle(.plain).accessibilityLabel("Review demo image "+(library.asset(id:id)?.name ?? "result"))
      }
    }
  }
  private var history:some View {
    VStack(alignment:.leading,spacing:5) {
      InspectorSectionHeader("RECENT RUNS")
      ScrollView(.horizontal,showsIndicators:true) {
        HStack(spacing:6) {
          ForEach(controller.history.sorted{$0.createdAt>$1.createdAt}) {run in
            WorkspaceNavigationRow(title:run.prompt.isEmpty ? run.capture.scene.name:String(run.prompt.prefix(48)),
              subtitle:run.createdAt.formatted(date:.omitted,time:.shortened)+" · "+run.status.title,
              symbol:"photo",selected:controller.selectedRunID==run.id,accessibilityLabel:"Review image run "+run.createdAt.formatted(),identifier:"studio-image-run-"+run.id.uuidString) {
                controller.selectRun(run.id)
              }.frame(width:210)
          }
        }
      }.frame(height:46)
    }
  }
  private func errorBanner(_ message:String)->some View {
    HStack(spacing:8) {
      Image(systemName:"exclamationmark.circle")
      Text(message).font(InspectorStyle.labelFont).fixedSize(horizontal:false,vertical:true)
      Spacer(minLength:4)
      Button("Retry"){issue=nil;Task{await controller.retry()}}.disabled(editingDisabled || controller.currentRun == nil)
      AppCloseButton("Dismiss image message"){issue=nil;controller.dismissError()}
    }.foregroundStyle(Palette.accent).padding(10).background(Palette.accent.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
  }
  private var primaryTitle:String {
    if controller.capture == nil {return "Capture scene"}
    if connection.state != .demoReady {return "Connect with demo"}
    return controller.options.count == 1 ? "Generate demo image":"Generate \(controller.options.count) demo images"
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

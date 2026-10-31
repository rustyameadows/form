import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StudioAssetImageView:View {
  @ObservedObject var library:StudioAssetLibrary
  var assetID:UUID?
  var maximumPixelSize=1200
  var label="Image preview"
  @State private var image:NSImage?
  @State private var loading=false
  var body:some View {
    ZStack {
      Palette.surface
      if let image {Image(nsImage:image).resizable().scaledToFit()}
      else if loading {ProgressView().controlSize(.small)}
      else {Image(systemName:"photo").font(.system(size:28)).foregroundStyle(Palette.secondary.opacity(0.5))}
    }.clipped().accessibilityLabel(label)
      .task(id:assetID) {
        image=nil
        guard let assetID,let asset=library.asset(id:assetID) else{loading=false;return}
        loading=true
        let loaded=await library.thumbnail(for:asset,maxPixelSize:maximumPixelSize)
        guard !Task.isCancelled else{return}
        image=loaded;loading=false
      }
  }
}

struct StudioImageResultReview:View {
  @ObservedObject var controller:StudioImageGenerationController
  @ObservedObject var library:StudioAssetLibrary
  @Binding var selectedAssetID:UUID?
  var onIterate:(UUID)->Void
  var onRegenerate:()->Void
  var onUseInCanvas:((UUID)->Void)?=nil
  @State private var comparison="Result"
  @State private var renameTarget:UUID?
  @State private var renameDraft=""
  @State private var issue:String?
  @State private var inspectingRun:StudioGenerationRun?

  private var capture:StudioGenerationCapture? {controller.currentRun?.capture ?? controller.capture}
  private var outputID:UUID? {
    guard let run=controller.currentRun else{return nil}
    if let selectedAssetID,run.outputAssetIDs.contains(selectedAssetID){return selectedAssetID}
    return run.outputAssetIDs.first
  }
  var body:some View {
    VStack(spacing:12) {
      HStack(spacing:10) {
        Text(outputID == nil ? "Scene input":"Demo result").font(.system(size:13,weight:.semibold))
        Spacer()
        if outputID != nil {
          Picker("Compare image",selection:$comparison) {
            Text("Result").tag("Result");Text("Scene input").tag("Scene");Text("Compare").tag("Compare")
          }.labelsHidden().inspectorSegmented().frame(width:230).accessibilityIdentifier("studio-image-compare")
        }
        if let run=controller.currentRun {
          Text(run.status.title).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
          WorkspaceToolbarButton("Run details",symbol:"info.circle",identifier:"studio-run-details"){inspectingRun=run}
        }
      }
      ZStack {
        RoundedRectangle(cornerRadius:10).fill(Palette.surface)
        if capture == nil {
          VStack(spacing:10) {
            Image(systemName:"camera.viewfinder").font(.system(size:34)).foregroundStyle(Palette.secondary)
            Text("Capture a Studio scene to begin.").font(.system(size:14,weight:.medium))
            Text("The captured image and its scene stay attached to every run.").font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)
          }.padding(28)
        }else if outputID == nil || comparison == "Scene" {
          preview(capture?.inputAssetID,title:"Frozen scene input")
        }else if comparison == "Compare" {
          HStack(spacing:1) {
            preview(capture?.inputAssetID,title:"Scene input")
            preview(outputID,title:"Demo result")
          }
        }else {preview(outputID,title:"Demo result")}
      }.frame(maxWidth:.infinity,maxHeight:.infinity).clipShape(RoundedRectangle(cornerRadius:10))
      if let id=outputID,let asset=library.asset(id:id) {resultActions(asset)}
      else if let capture {
        HStack {
          Text(capture.scene.name).font(InspectorStyle.labelFont).lineLimit(1)
          Spacer()
          Text("\(capture.width) × \(capture.height) · frozen input").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
        }
      }
      if let issue {Text(issue).font(InspectorStyle.captionFont).foregroundStyle(Palette.accent).frame(maxWidth:.infinity,alignment:.leading)}
    }
    .alert("Rename image",isPresented:Binding(get:{renameTarget != nil},set:{if !$0 {renameTarget=nil}})) {
      TextField("Image name",text:$renameDraft)
      Button("Rename") {
        guard let id=renameTarget else{return}
        do {try library.rename(id,to:renameDraft);issue=nil}catch{issue=error.localizedDescription}
        renameTarget=nil
      }
      Button("Cancel",role:.cancel){renameTarget=nil}
    }
    .sheet(item:$inspectingRun){run in StudioImageRunDetails(run:run,library:library){inspectingRun=nil}}
  }
  private func preview(_ id:UUID?,title:String)->some View {
    StudioAssetImageView(library:library,assetID:id,label:title)
      .overlay(alignment:.bottomLeading) {
        Text(title).font(.system(size:10,weight:.medium)).padding(.horizontal,8).padding(.vertical,5)
          .background(Palette.paper.opacity(0.92),in:RoundedRectangle(cornerRadius:5)).padding(10)
      }
  }
  private func resultActions(_ asset:StudioAsset)->some View {
    HStack(spacing:3) {
      Text(asset.name).font(InspectorStyle.labelFont).lineLimit(1)
      Spacer(minLength:2)
      WorkspaceToolbarButton("Favorite image",symbol:asset.favorite ? "star.fill":"star",isSelected:asset.favorite,
        identifier:"studio-result-favorite") {
          do{try library.setFavorite(asset.id,!asset.favorite);issue=nil}catch{issue=error.localizedDescription}
        }
      WorkspaceToolbarButton("Rename image",symbol:"pencil",identifier:"studio-result-rename"){renameDraft=asset.name;renameTarget=asset.id}
      WorkspaceToolbarButton("Save image copy",symbol:"square.and.arrow.down",identifier:"studio-result-save"){saveCopy(asset)}
      WorkspaceToolbarButton("Reveal image in Finder",symbol:"folder",identifier:"studio-result-reveal") {
        do{NSWorkspace.shared.activateFileViewerSelecting([try library.fileURL(for:asset)])}catch{issue=error.localizedDescription}
      }
      WorkspaceToolbarButton("Use image as reference",symbol:"photo.badge.plus",identifier:"studio-result-reference"){onIterate(asset.id)}
      if let onUseInCanvas {
        WorkspaceToolbarButton("Use image on Canvas",symbol:"square.and.arrow.down.on.square",identifier:"studio-result-canvas"){onUseInCanvas(asset.id)}
      }
      WorkspaceToolbarButton("Regenerate this run",symbol:"arrow.clockwise",identifier:"studio-result-regenerate"){onRegenerate()}
        .disabled(controller.busy)
    }
  }
  private func saveCopy(_ asset:StudioAsset) {
    let panel=NSSavePanel();panel.allowedContentTypes=[.png];panel.nameFieldStringValue=asset.filename
    panel.begin {response in
      guard response == .OK,let destination=panel.url else{return}
      do {
        try library.saveCopy(asset.id,to:destination,replaceExisting:true)
        issue=nil
      }catch{issue=error.localizedDescription}
    }
  }
}

struct StudioImageRunDetails:View {
  let run:StudioGenerationRun
  @ObservedObject var library:StudioAssetLibrary
  var onClose:()->Void = {}
  var body:some View {
    VStack(alignment:.leading,spacing:18) {
      HStack {Text("Run details").font(.system(size:17,weight:.semibold));Spacer();AppCloseButton("Close run details",action:onClose)}
      StudioDemoBadge()
      ScrollView {
        VStack(alignment:.leading,spacing:18) {
          Text(run.createdAt.formatted(date:.abbreviated,time:.shortened)).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
          Text(run.status.title).font(.system(size:11,weight:.semibold))
          if let error=run.error {Text(error).foregroundStyle(Palette.accent)}
          InspectorSectionHeader("FROZEN PROMPT")
          Text(run.prompt.isEmpty ? "No additional prompt":run.prompt).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
          if !run.style.isEmpty {InspectorSectionHeader("STYLE");Text(run.style).textSelection(.enabled)}
          InspectorSectionHeader("REQUEST")
          Text("\(run.options.model.title) · \(run.options.quality.title) · \(run.options.aspect.title) · \(run.options.size.title) · \(run.options.count) image(s)")
          Text("\(run.capture.scene.name) · \(run.capture.width) × \(run.capture.height) input").foregroundStyle(Palette.secondary)
          if !run.references.isEmpty {
            InspectorSectionHeader("REFERENCES")
            ForEach(run.references){reference in Text((library.asset(id:reference.assetID)?.name ?? "Unavailable image")+" · "+reference.role.title)}
          }
          InspectorSectionHeader("PROVENANCE")
          Text(run.provider).foregroundStyle(Palette.secondary)
          Text("Source: "+run.capture.designSHA256).font(.system(size:9,design:.monospaced)).textSelection(.enabled)
          Text("The input, prompt, style, reference IDs and settings above are snapshots of this run. Results are local demo images, not AI-generated output.").foregroundStyle(Palette.secondary)
        }.font(InspectorStyle.labelFont).frame(maxWidth:.infinity,alignment:.leading)
      }
    }.padding(24).frame(width:560,height:610).background(Palette.paper)
  }
}

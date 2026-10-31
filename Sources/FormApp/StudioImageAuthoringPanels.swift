import AppKit
import FormCore
import SwiftUI

struct StudioImageAuthoringLayout {
  let inputWidth:CGFloat,outputWidth:CGFloat,presetHeight:CGFloat,referenceHeight:CGFloat,spacing:CGFloat
  init(width:CGFloat,height:CGFloat=900,hasReferences:Bool=false,hasMessage:Bool=false,isBusy:Bool=false) {
    let expansion=max(0,min(1,(width-1020)/420))
    inputWidth=240+40*expansion;outputWidth=216+32*expansion
    spacing=height<650 ? 12:14
    // Keep the native editor and actions intact at the production 700pt
    // window minimum; the same preset/reference inventories remain scrollable.
    presetHeight=max(80,min(168,height-540))
    let footer:CGFloat=54+(hasMessage ? 62:0)+(isBusy ? 24:0)
    let reserved:CGFloat=28+9+32+180+footer+32+spacing*(hasReferences ? 4:3)
    referenceHeight=hasReferences ? max(44,min(110,height-reserved-presetHeight)):0
  }
}

@MainActor struct StudioImageInputPanel:View {
  @ObservedObject var controller:StudioImageGenerationController
  @ObservedObject var library:StudioAssetLibrary
  private var capture:StudioGenerationCapture? {
    guard controller.store?.project?.id==controller.projectID,controller.store?.showingHome==false else{return nil}
    return controller.capture
  }
  var body:some View {
    ScrollView {
      VStack(alignment:.leading,spacing:18) {
        InspectorSectionHeader("SCENE INPUT",subtitle:"The frozen scene used for your next image.")
        StudioAssetImageView(library:library,assetID:capture?.inputAssetID,maximumPixelSize:640,label:"Next image scene input")
          .frame(height:174).clipShape(RoundedRectangle(cornerRadius:9))
        if let capture {
          VStack(alignment:.leading,spacing:5) {
            Text(capture.scene.name).font(.system(size:13,weight:.medium)).fixedSize(horizontal:false,vertical:true)
            Text(capture.projectName).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
            Text("\(capture.width) × \(capture.height) px"+(capture.hasExactStudioPixels ? " · From Studio":" · Older input"))
              .font(InspectorStyle.valueFont).foregroundStyle(Palette.secondary)
              .accessibilityIdentifier("studio-image-input-dimensions")
          }
          if !capture.hasExactStudioPixels {
            Label("Recapture for \(capture.scene.pixels.width) × \(capture.scene.pixels.height) px from Studio.",systemImage:"camera.badge.ellipsis")
              .font(InspectorStyle.labelFont).foregroundStyle(Palette.accent).fixedSize(horizontal:false,vertical:true)
          }
          if controller.isCaptureStale {
            Label("Scene changed since capture",systemImage:"camera.badge.ellipsis")
              .font(InspectorStyle.labelFont).foregroundStyle(Palette.accent)
          }
          WorkspaceToolbarButton("Recapture scene",symbol:"camera.rotate",showsTitle:true,identifier:"studio-image-recapture") {
            Task{await controller.captureScene()}
          }.disabled(controller.busy)
          ForEach(Array(capture.warnings.enumerated()),id:\.offset) {_,warning in
            Label(warning,systemImage:"exclamationmark.triangle").font(InspectorStyle.captionFont).foregroundStyle(Palette.accent)
          }
          if let context=capture.context {contextDetails(context)}
          else {
            InspectorDivider()
            Text("Object and material details were not recorded with this earlier capture.")
              .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
          }
          Text("Captured "+capture.createdAt.formatted(date:.abbreviated,time:.shortened))
            .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
        }else {
          Text("Capture a Studio scene to include its objects, materials and camera.")
            .font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)
        }
      }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
    }.accessibilityLabel("Scene input and captured context")
  }
  @ViewBuilder private func contextDetails(_ context:StudioGenerationInputContext)->some View {
    InspectorDivider()
    InspectorSectionHeader("OBJECTS",subtitle:"\(context.instanceCount) in scene · \(context.materialCount) materials")
    ForEach(context.objects){object in StudioImageInputObjectRow(object:object)}
    InspectorDivider()
    VStack(alignment:.leading,spacing:9) {
      InspectorSectionHeader("CAMERA & VIEWPORT")
      StudioImageMetadataRow("Projection",context.camera.projection.capitalized)
      StudioImageMetadataRow("Distance",number(context.camera.distanceMM)+" mm")
      StudioImageMetadataRow("Azimuth",number(context.camera.azimuthDegrees)+"°")
      StudioImageMetadataRow("Elevation",number(context.camera.elevationDegrees)+"°")
      if let angle=context.camera.verticalFieldOfViewDegrees {StudioImageMetadataRow("Field of view",number(angle)+"°")}
      if let span=context.camera.orthographicSpanMM {StudioImageMetadataRow("View span",number(span)+" mm")}
      StudioImageMetadataRow("Input pixels","\(context.viewport.width) × \(context.viewport.height)")
      StudioImageMetadataRow("Aspect",String(format:"%.2f:1",context.viewport.aspect))
      StudioImageMetadataRow("Lighting",context.lighting.capitalized)
      StudioImageMetadataRow("Surface",context.surface.capitalized)
    }
  }
  private func number(_ value:Double)->String {String(format:"%.1f",value)}
}

private struct StudioImageInputObjectRow:View {
  let object:StudioGenerationInputContext.Object
  @State private var expanded=false
  var body:some View {
    VStack(alignment:.leading,spacing:7) {
      DisclosureGroup(isExpanded:$expanded) {
        VStack(alignment:.leading,spacing:8) {
          if let size=object.declaredDimensionsMM {
            StudioImageMetadataRow("Declared size",vector(size)+" mm")
          }
          StudioImageMetadataRow("Position",String(format:"%.1f, %.1f, %.1f mm",object.positionMM.x,object.positionMM.y,object.positionMM.z))
          StudioImageMetadataRow("Rotation",String(format:"%.1f°",object.rotationDegrees))
          if let roughness=object.roughness {StudioImageMetadataRow("Roughness",String(format:"%.2f",roughness))}
          if let metallic=object.metallic {StudioImageMetadataRow("Metallic",String(format:"%.2f",metallic))}
          if let stock=object.paper {
            StudioImageMetadataRow("Stock",stock.name)
            StudioImageMetadataRow("Caliper",String(format:"%.2f mm",stock.thicknessMM))
            substrate("Front substrate",stock.front)
            substrate("Back substrate",stock.back)
            if !stock.plies.isEmpty {StudioImageMetadataRow("Plies",stock.plies.map(\.name).joined(separator:", "))}
            if !stock.finishes.isEmpty {StudioImageMetadataRow("Finishes",stock.finishes.map(\.name).joined(separator:", "))}
          }
          ForEach(Array(object.materialSlots.prefix(8))){slot in
            VStack(alignment:.leading,spacing:5) {
              Text(slot.name).font(.system(size:10,weight:.medium))
              StudioImageMetadataRow("Roughness factor",String(format:"%.2f",slot.roughness))
              StudioImageMetadataRow("Metallic factor",String(format:"%.2f",slot.metallic))
              if !slot.textureChannels.isEmpty {StudioImageMetadataRow("Texture maps",slot.textureChannels.joined(separator:", "))}
              if let override=slot.overrideColorHex {StudioImageMetadataRow("Color override",override)}
            }.padding(.vertical,4)
          }
          if object.materialSlots.count>8 {Text("\(object.materialSlots.count) material slots · first 8 shown").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
        }.padding(.top,7)
      }label:{Text(object.name).font(InspectorStyle.labelFont).lineLimit(2)}
      HStack(spacing:6) {
        if let color=object.color {Circle().fill(Color(nsColor:NSColor(hex:color))).frame(width:9,height:9)}
        Text(object.materialName).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary).lineLimit(2)
      }.padding(.leading,16)
    }
  }
  private func substrate(_ title:String,_ face:StudioGenerationInputContext.Face)->some View {
    HStack(spacing:5) {
      Circle().fill(Color(nsColor:NSColor(hex:face.color))).frame(width:9,height:9)
      StudioImageMetadataRow(title,face.color)
    }
  }
  private func vector(_ value:Vector3)->String {String(format:"%.1f × %.1f × %.1f",value.x,value.y,value.z)}
}

struct StudioImageMetadataRow:View {
  let title:String,value:String
  init(_ title:String,_ value:String){self.title=title;self.value=value}
  var body:some View {
    HStack(alignment:.firstTextBaseline,spacing:8) {
      Text(title).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      Spacer(minLength:2)
      Text(value).font(InspectorStyle.valueFont).multilineTextAlignment(.trailing).fixedSize(horizontal:false,vertical:true)
    }
  }
}

@MainActor struct StudioImageOutputRail:View {
  @ObservedObject var controller:StudioImageGenerationController
  @ObservedObject var library:StudioAssetLibrary
  var selectedAssetID:UUID?
  var onPreview:(UUID,UUID?)->Void
  private var runs:[StudioGenerationRun] {
    guard controller.store?.project?.id==controller.projectID,controller.store?.showingHome==false else{return []}
    return controller.history.filter{$0.capture.projectID==controller.projectID && (library.projectID==nil || $0.capture.projectID==library.projectID)}
      .sorted{$0.createdAt>$1.createdAt}
  }
  var body:some View {
    VStack(alignment:.leading,spacing:0) {
      InspectorSectionHeader("PROJECT IMAGES",subtitle:runs.isEmpty ? "Your results appear here.":"\(runs.reduce(0){$0+$1.outputAssetIDs.count}) images · \(runs.count) runs")
        .padding(16)
      Divider()
      ScrollView {
        LazyVStack(alignment:.leading,spacing:18) {
          if runs.isEmpty {
            VStack(alignment:.leading,spacing:10) {
              Image(systemName:"photo.stack").font(.system(size:26,weight:.light)).foregroundStyle(Palette.secondary)
              Text("No images yet").font(.system(size:12,weight:.medium))
              Text("Images made in this project stay here while you work on the next prompt.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
            }.padding(.vertical,14)
          }
          ForEach(runs){run in
            VStack(alignment:.leading,spacing:8) {
              HStack(spacing:4) {
                VStack(alignment:.leading,spacing:3) {
                  Text(run.createdAt.formatted(date:.abbreviated,time:.shortened)).font(InspectorStyle.captionFont)
                  Text(run.status.title).font(InspectorStyle.captionFont).foregroundStyle(run.status == .failed ? Palette.accent:Palette.secondary)
                }
                Spacer(minLength:0)
                WorkspaceToolbarButton("Review run",symbol:"info.circle",identifier:"studio-image-run-"+run.id.uuidString){onPreview(run.id,run.outputAssetIDs.first)}
              }
              ForEach(run.outputAssetIDs,id:\.self){id in output(id,run:run)}
              if run.outputAssetIDs.isEmpty {
                Text(run.error ?? (run.status == .running ? "Making local demo images…":"No images from this run."))
                  .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
              }
            }
          }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(14)
      }
    }.accessibilityLabel("Current project image history")
  }
  private func output(_ id:UUID,run:StudioGenerationRun)->some View {
    let asset=library.asset(id:id)
    return VStack(alignment:.leading,spacing:6) {
      StudioAssetImageView(library:library,assetID:id,maximumPixelSize:360,label:asset?.name ?? "Unavailable project image")
        .frame(height:124).clipShape(RoundedRectangle(cornerRadius:7)).contentShape(Rectangle())
        .onTapGesture{onPreview(run.id,id)}
      HStack(spacing:3) {
        VStack(alignment:.leading,spacing:3) {
          Text(asset?.name ?? "Unavailable image").font(InspectorStyle.labelFont).lineLimit(2)
          Text(asset?.isMissing==true ? "Original file missing":"Demo · local preview").font(.system(size:9)).foregroundStyle(Palette.secondary)
        }
        Spacer(minLength:0)
        WorkspaceToolbarButton("Preview image",symbol:"arrow.up.forward",identifier:"studio-image-preview-"+id.uuidString){onPreview(run.id,id)}
      }
    }.padding(7).background(selectedAssetID==id ? Palette.accent.opacity(0.07):Palette.surface,in:RoundedRectangle(cornerRadius:9))
      .overlay(RoundedRectangle(cornerRadius:9).strokeBorder(selectedAssetID==id ? Palette.accent:Palette.line,lineWidth:selectedAssetID==id ? 1.5:0.75))
  }
}

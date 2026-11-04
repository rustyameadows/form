import AppKit
import FormCore
import SwiftUI

struct CyclesRenderModeControl:View {
  @ObservedObject var preview:CyclesViewportController
  var settings:CyclesRenderSettings
  var change:(CyclesRenderSettings)->Void
  @State private var showingSettings=false
  var body:some View {
    HStack(spacing:5) {
      Picker("Rendering",selection:Binding(get:{settings.renderer},set:{value in var copy=settings;copy.renderer=value;change(copy)})) {
        Text("Fast").tag(CyclesRenderSettings.Renderer.realtime)
        Text("Rendered").tag(CyclesRenderSettings.Renderer.cycles)
      }.pickerStyle(.segmented).labelsHidden().frame(width:132).accessibilityIdentifier("cycles-render-mode")
      Button{showingSettings=true}label:{Image(systemName:"slider.horizontal.3")}.buttonStyle(.plain).help("Rendering settings")
      if settings.renderer == .cycles {
        VStack(alignment:.leading,spacing:1) {
          Text(preview.error == nil ? preview.statusText:"Render unavailable")
          if !preview.device.isEmpty {Text(preview.device).foregroundStyle(.secondary)}
        }.font(.system(size:10,design:.monospaced)).lineLimit(1).frame(maxWidth:150)
          .help(preview.error ?? preview.fallbackReason ?? preview.phase)
        Button {if preview.isPaused {preview.resume()}else{preview.pause()}}label:{Image(systemName:preview.isPaused ? "play.fill":"pause.fill")}
          .buttonStyle(.plain).help(preview.isPaused ? "Resume rendering":"Pause rendering")
      }
    }.sheet(isPresented:$showingSettings) {
      CyclesSettingsEditor(settings:settings,preset:{
        guard let source=preview.source else {throw FormError.invalid("The lighting scene is no longer available. Reopen rendering settings.")}
        return source.cyclesLightingPreset()
      },apply:change)
    }
  }
}

private struct CyclesSettingsEditor:View {
  @EnvironmentObject var store:StudioStore
  @Environment(\.dismiss) var dismiss
  @State var settings:CyclesRenderSettings
  var preset:()throws->CyclesLightingPreset
  var apply:(CyclesRenderSettings)->Void
  @State private var error:String?
  @State private var lightingConversion=CyclesLightingConversionDraft()
  var body:some View {
    VStack(alignment:.leading,spacing:14) {
      Text("Rendering").font(.title2)
      ScrollView {
        Form {
          Section("Quality") {
            Picker("Device",selection:$settings.device) {Text("Automatic").tag(CyclesRenderSettings.Device.automatic);Text("Apple GPU · Metal").tag(CyclesRenderSettings.Device.metal);Text("CPU").tag(CyclesRenderSettings.Device.cpu)}
            TextField("Final samples",value:$settings.samples,format:.number)
            TextField("Preview samples",value:$settings.previewSamples,format:.number)
            TextField("Final noise threshold",value:$settings.noiseThreshold,format:.number)
            TextField("Maximum bounces",value:$settings.maxBounces,format:.number)
            Toggle("Denoise",isOn:$settings.denoise)
            TextField("Displacement detail · pixels",value:$settings.displacementDicingRate,format:.number)
            TextField("Displacement triangle limit",value:$settings.displacementMaxTriangles,format:.number)
            TextField("Displacement subdivision limit",value:$settings.displacementMaxSubdivisions,format:.number)
          }
          Section("Camera") {
            TextField("Exposure · stops",value:$settings.exposure,format:.number)
            Toggle("Depth of field",isOn:$settings.depthOfField)
            if settings.depthOfField {
              TextField("Aperture · f-stop",value:$settings.fStop,format:.number)
              TextField("Focus distance · mm",value:$settings.focusDistanceMM,format:.number)
            }
          }
          Section("Environment") {
            TextField("Color · #RRGGBB",text:$settings.environmentColor)
            TextField("Strength",value:$settings.environmentStrength,format:.number)
            TextField("Rotation · degrees",value:$settings.environmentRotationDegrees,format:.number)
            HStack {
              Text(settings.environmentTexture?.asset ?? "Solid environment").lineLimit(1)
              Spacer();Button("Choose image…"){importEnvironment()}
              if settings.environmentTexture != nil {Button("Remove"){settings.environmentTexture=nil}}
            }
          }
          Section("Area lights") {
            if settings.areaLights==nil {
              Text("Current scene preset").foregroundStyle(.secondary)
              Button("Make current lights editable"){makeEditable()}
                .accessibilityIdentifier("cycles-make-lights-editable")
              Text("Copies the current lights and ambient response. Apply saves your editable lighting.")
                .font(.caption).foregroundStyle(.secondary)
            } else {
              Text("Editable lights · \(settings.areaLights?.count ?? 0)").foregroundStyle(.secondary)
            }
            ForEach(Array((settings.areaLights ?? []).enumerated()),id:\.element.id) {index,_ in
              VStack(alignment:.leading) {
                HStack{Text("Light \(index+1)").font(.headline);Spacer();Button("Remove"){settings.areaLights?.remove(at:index)}}
                vector("Position · mm",light:index,key:\.positionMM)
                vector("Target · mm",light:index,key:\.targetMM)
                HStack {
                  TextField("Width · mm",value:lightValue(index,\.sizeMM.x),format:.number)
                  TextField("Height · mm",value:lightValue(index,\.sizeMM.y),format:.number)
                }
                TextField("Power · W",value:lightValue(index,\.powerWatts),format:.number)
                TextField("Color · #RRGGBB",text:lightValue(index,\.color))
                Picker("Shape",selection:lightValue(index,\.shape)) {Text("Rectangle").tag(PhysicalAreaLight.Shape.rectangle);Text("Disk").tag(PhysicalAreaLight.Shape.disk)}
              }.padding(.vertical,5)
            }
            HStack {
              Button("Add area light"){makeEditable(addLight:true)}.accessibilityIdentifier("cycles-add-area-light")
              Button("Use scene preset"){settings=lightingConversion.usePreset(settings);error=nil}
                .help("Return to the scene preset. Within this draft, restore the environment from before conversion.")
            }
          }
        }.formStyle(.grouped)
      }
      if let error {Text(error).font(.caption).foregroundStyle(.red)}
      HStack{Spacer();Button("Cancel"){dismiss()};Button("Apply"){NSApp.keyWindow?.makeFirstResponder(nil);do{try settings.validate();apply(settings);dismiss()}catch{self.error=error.localizedDescription}}.keyboardShortcut(.defaultAction)}
    }.padding(20).frame(width:540,height:690)
  }
  private func makeEditable(addLight:Bool=false) {
    do {
      settings=try lightingConversion.makeEditable(settings,using:preset(),addingLight:addLight);error=nil
    } catch {self.error=error.localizedDescription}
  }
  private func lightValue<T>(_ index:Int,_ key:WritableKeyPath<PhysicalAreaLight,T>)->Binding<T> {
    Binding(get:{let lights=settings.areaLights ?? [];return (lights.indices.contains(index) ? lights[index]:PhysicalAreaLight())[keyPath:key]},set:{value in guard settings.areaLights?.indices.contains(index)==true else{return};settings.areaLights?[index][keyPath:key]=value})
  }
  private func vector(_ title:String,light:Int,key:WritableKeyPath<PhysicalAreaLight,Vector3>)->some View {
    VStack(alignment:.leading) {Text(title).font(.caption);HStack{
      TextField("X",value:lightValue(light,key.appending(path:\.x)),format:.number)
      TextField("Y",value:lightValue(light,key.appending(path:\.y)),format:.number)
      TextField("Z",value:lightValue(light,key.appending(path:\.z)),format:.number)
    }}
  }
  private func importEnvironment() {
    let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
    guard panel.runModal() == .OK,let url=panel.url else{return}
    do {
      let encoding=["exr","hdr"].contains(url.pathExtension.lowercased()) ? "linearSRGB":"srgb"
      let result=try store.engine.call("form_material",arguments:["command":"import_texture","path":url.path,"color_space":encoding],source:"Studio")
      guard let result=result as? [String:Any],let raw=result["texture"] else{throw FormError.invalid("Texture import did not return an image reference.")}
      settings.environmentTexture=try JSONDecoder.form.decode(PhysicalTextureReference.self,from:JSONSerialization.data(withJSONObject:raw))
    }catch{self.error=error.localizedDescription}
  }
}

extension StudioStore {
  func setTableRenderSettings(_ settings:CyclesRenderSettings) {
    do {
      try settings.validate()
      if mode == .studio && studioShowingShots {studioShots.renderSettings=settings;scene?.cyclesSettingsOverride=settings;scene?.cyclesPreview.refresh();objectWillChange.send()}
      else {try engine.edit("Changed Table rendering",source:"Studio"){$0.renderSettings=settings};changed()}
    }
    catch{self.error=error.localizedDescription}
  }
}

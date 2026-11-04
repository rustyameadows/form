import AppKit
import FormCore
import SwiftUI
import UniformTypeIdentifiers

/// Shared local-draft controls for material, stock, finish and thread appearance.
/// Import stages portable Assets; applying the owning editor commits one command.
struct PhysicalAppearanceDraftControls:View {
  @EnvironmentObject var store:StudioStore
  @Binding var appearance:PhysicalAppearance
  @Binding var error:String
  var supportsDisplacement=true
  var supportsSecondUV=true
  @State private var channel:PhysicalTextureChannel = .baseColor
  @State private var importMaximumEdge=0
  var body:some View {
    VStack(alignment:.leading,spacing:18) {
      VStack(alignment:.leading,spacing:10) {
        SectionLabel("OPTICAL RESPONSE")
      number("Index of refraction",appearanceBinding(\.ior))
      slider("Diffuse transmission",appearanceBinding(\.diffuseTransmission))
      slider("Refraction",appearanceBinding(\.transmission))
      slider("Subsurface",appearanceBinding(\.subsurface))
      HStack {number("Red radius (mm)",appearanceBinding(\.subsurfaceRadiusMM.x));number("Green radius (mm)",appearanceBinding(\.subsurfaceRadiusMM.y));number("Blue radius (mm)",appearanceBinding(\.subsurfaceRadiusMM.z))}
      slider("Sheen",appearanceBinding(\.sheen));slider("Sheen roughness",appearanceBinding(\.sheenRoughness))
      InspectorColorPicker("Sheen tint",selection:Binding(get:{Color(nsColor:NSColor(hex:appearance.sheenTint))},set:{appearance.sheenTint=NSColor($0).hexString}),supportsOpacity:false)
      slider("Anisotropy",appearanceBinding(\.anisotropy));slider("Tangent rotation (turns)",appearanceBinding(\.anisotropyRotation))
      slider("Coat",appearanceBinding(\.coat));slider("Coat roughness",appearanceBinding(\.coatRoughness))
      number("Bump strength",appearanceBinding(\.bumpStrength))
      number("Normal map strength",appearanceBinding(\.normalStrength))
      if supportsDisplacement {
        number("Displacement (mm)",appearanceBinding(\.displacementScaleMM))
        slider("Displacement midpoint",appearanceBinding(\.displacementMidlevel))
      }

      }
      textureControls
    }
  }
  private func appearanceBinding<T>(_ key:WritableKeyPath<PhysicalAppearance,T>)->Binding<T> {
    Binding(get:{appearance[keyPath:key]},set:{appearance[keyPath:key]=$0})
  }
  private var textureControls:some View {
    VStack(alignment:.leading,spacing:10) {
      SectionLabel("TEXTURE MAPS")
      HStack {
        Picker("Channel",selection:$channel) {ForEach(PhysicalTextureChannel.allCases.filter{supportsDisplacement || $0 != .displacement},id:\.self){Text(label($0)).tag($0)}}
        Button("Import image…"){importTexture()}
      }
      Picker("Import size",selection:$importMaximumEdge) {
        Text("Original").tag(0)
        Text("Fit within 4096 px").tag(4096)
        Text("Fit within 2048 px").tag(2048)
        Text("Fit within 1024 px").tag(1024)
      }
      ForEach(appearance.textures.keys.filter{PhysicalTextureChannel(rawValue:$0) != nil}.sorted(),id:\.self) {key in
        HStack {Button(label(PhysicalTextureChannel(rawValue:key)!)){channel=PhysicalTextureChannel(rawValue:key)!};Text(appearance.textures[key]!.asset).font(.caption).lineLimit(1).truncationMode(.middle);Spacer();Button("Remove"){appearance.textures.removeValue(forKey:key)}}
      }
      if let texture=appearance.textures[channel.rawValue],let project=store.project {
        PhysicalTexturePreview(texture:texture,channelName:label(channel),
          assets:store.repository.url(for:project.id).appendingPathComponent("Assets"))
        mappingControls
      }
      Text("Color maps retain their color space. Roughness, normals and height maps use data values. Repeat size is physical millimeters.").font(.caption).foregroundStyle(Palette.secondary)
    }
  }
  private var mappingControls:some View {
    VStack(alignment:.leading,spacing:10) {
      Picker("Color space",selection:textureBinding(\.colorSpace,fallback:.data)) {
        Text("sRGB").tag(PhysicalTextureReference.ColorSpace.srgb)
        Text("Linear sRGB").tag(PhysicalTextureReference.ColorSpace.linearSRGB)
        Text("Data").tag(PhysicalTextureReference.ColorSpace.data)
      }
      Picker("UV coordinates",selection:textureBinding(\.uvIndex,fallback:0)) {Text("UV 0").tag(0);if supportsSecondUV {Text("UV 1").tag(1)}}
      HStack {wrap("Horizontal wrap",textureBinding(\.wrapS,fallback:.repeat));wrap("Vertical wrap",textureBinding(\.wrapT,fallback:.repeat))}
      HStack {number("U scale",textureBinding(\.scale.x,fallback:1));number("V scale",textureBinding(\.scale.y,fallback:1))}
      HStack {number("U offset",textureBinding(\.offset.x,fallback:0));number("V offset",textureBinding(\.offset.y,fallback:0))}
      number("Texture rotation (°)",textureBinding(\.rotationDegrees,fallback:0))
      Toggle("Physical repeat size",isOn:Binding(get:{appearance.textures[channel.rawValue]?.scaleMM != nil},set:{appearance.textures[channel.rawValue]?.scaleMM=$0 ? .init(100,100):nil}))
      if appearance.textures[channel.rawValue]?.scaleMM != nil {
        HStack {
          number("Width (mm)",Binding(get:{appearance.textures[channel.rawValue]?.scaleMM?.x ?? 100},set:{appearance.textures[channel.rawValue]?.scaleMM?.x=$0}))
          number("Height (mm)",Binding(get:{appearance.textures[channel.rawValue]?.scaleMM?.y ?? 100},set:{appearance.textures[channel.rawValue]?.scaleMM?.y=$0}))
        }
      }
    }.padding(12).background(Palette.surface,in:RoundedRectangle(cornerRadius:8))
  }
  private func slider(_ title:String,_ binding:Binding<Double>)->some View {
    HStack {Text(title).frame(width:180,alignment:.leading);InspectorSlider(value:binding,in:0...1,label:title);Text(binding.wrappedValue,format:.number.precision(.fractionLength(2))).monospacedDigit().frame(width:40,alignment:.trailing)}
  }
  private func number(_ title:String,_ binding:Binding<Double>)->some View {
    VStack(alignment:.leading,spacing:3) {Text(title).font(.caption);TextField(title,value:binding,format:.number).textFieldStyle(.roundedBorder).accessibilityLabel(title)}
  }
  private func wrap(_ title:String,_ binding:Binding<PhysicalTextureReference.Wrap>)->some View {
    Picker(title,selection:binding) {Text("Repeat").tag(PhysicalTextureReference.Wrap.repeat);Text("Clamp").tag(PhysicalTextureReference.Wrap.clamp);Text("Mirror").tag(PhysicalTextureReference.Wrap.mirror)}
  }
  private func textureBinding<T>(_ key:WritableKeyPath<PhysicalTextureReference,T>,fallback:T)->Binding<T> {
    Binding(get:{appearance.textures[channel.rawValue]?[keyPath:key] ?? fallback},set:{appearance.textures[channel.rawValue]?[keyPath:key]=$0})
  }
  private func importTexture() {
    let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
    panel.allowedContentTypes=[.png,.jpeg,.tiff]+[UTType(filenameExtension:"exr"),UTType(filenameExtension:"hdr")].compactMap{$0}
    guard panel.runModal() == .OK,let url=panel.url else{return}
    attempt {
      let color=[PhysicalTextureChannel.baseColor,.emission,.sheenTint].contains(channel)
      var arguments:[String:Any]=["command":"import_texture","path":url.path,"color_space":color ? "srgb":"data"]
      if importMaximumEdge>0 {arguments["max_dimension"]=importMaximumEdge}
      let result=try store.engine.call("form_material",arguments:arguments,source:"Studio") as! [String:Any]
      let imported=try JSONDecoder.form.decode(PhysicalTextureReference.self,from:JSONSerialization.data(withJSONObject:result["texture"]!))
      replaceTextureSource(imported,for:channel)
    }
  }
  /// Replacing an image changes its source, not the surface's authored mapping.
  /// A previously empty channel keeps the imported reference's defaults.
  func replaceTextureSource(_ imported:PhysicalTextureReference,for channel:PhysicalTextureChannel) {
    var replacement=appearance.textures[channel.rawValue] ?? imported
    replacement.asset=imported.asset;replacement.sha256=imported.sha256;replacement.colorSpace=imported.colorSpace
    appearance.textures[channel.rawValue]=replacement
  }
  private func attempt(_ body:()throws->Void) {do {try body();error=""}catch {self.error=error.localizedDescription}}
  private func label(_ value:PhysicalTextureChannel)->String {
    switch value {case .baseColor:return "Base color";case .diffuseTransmission:return "Diffuse transmission";case .sheenTint:return "Sheen tint";default:return value.rawValue.capitalized}
  }
}

/// A reusable single-surface sheet. Its owner chooses the existing domain command
/// (or a parent editing draft); this view never changes manufacturing parameters.
struct PhysicalAppearanceDraftEditor:View {
  @Environment(\.dismiss) private var dismiss
  let title:String
  let subtitle:String
  let usesInheritedAppearance:Bool
  let initialRoughness:Double?
  let showsRoughness:Bool
  let supportsDisplacement:Bool
  let onApply:(PhysicalAppearance?,Double?)throws->Void
  @State private var appearance:PhysicalAppearance
  @State private var roughness:Double
  @State private var error=""
  init(title:String,subtitle:String,appearance:PhysicalAppearance?,fallback:PhysicalAppearance = .init(),
       roughness:Double? = nil,showsRoughness:Bool = false,supportsDisplacement:Bool = true,
       onApply:@escaping(PhysicalAppearance?,Double?)throws->Void) {
    self.title=title;self.subtitle=subtitle;usesInheritedAppearance=appearance == nil;initialRoughness=roughness;self.showsRoughness=showsRoughness
    self.supportsDisplacement=supportsDisplacement;self.onApply=onApply
    _appearance=State(initialValue:appearance ?? fallback);_roughness=State(initialValue:roughness ?? 0.5)
  }
  var body:some View {
    VStack(alignment:.leading,spacing:14) {
      Text(title).font(.title2)
      Text(subtitle).foregroundStyle(Palette.secondary)
      Text(usesInheritedAppearance ? "Editing inherited appearance. Apply creates an override for this surface.":"This surface has its own appearance. Use inherited appearance to clear this override.")
        .font(.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      ScrollView {
        VStack(alignment:.leading,spacing:16) {
          if showsRoughness {
            HStack {
              Text("Roughness").frame(width:180,alignment:.leading)
              InspectorSlider(value:$roughness,in:0...1,label:"Thread roughness")
              Text(roughness,format:.number.precision(.fractionLength(2))).monospacedDigit().frame(width:40,alignment:.trailing)
            }
          }
          PhysicalAppearanceDraftControls(appearance:$appearance,error:$error,supportsDisplacement:supportsDisplacement,supportsSecondUV:false)
          if !supportsDisplacement {
            Text("Thread maps repeat along and around the strand in millimeters. Use normal or bump maps for thread surface detail.")
              .font(.caption).foregroundStyle(Palette.secondary)
          }
        }.padding(.trailing,8)
      }
      if !error.isEmpty {Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
      HStack {
        Button("Cancel"){dismiss()}.keyboardShortcut(.cancelAction).accessibilityIdentifier("physical-appearance-cancel")
        Button("Use inherited appearance"){apply(clear:true)}.accessibilityIdentifier("physical-appearance-clear")
        Spacer()
        CanvasGenerationActionButton(title:"Apply",enabled:true,action:{apply(clear:false)},
          identifier:"physical-appearance-apply",prominent:false,keyEquivalent:"\r")
      }
    }.padding(24).frame(width:600,height:740).background(Palette.paper)
  }
  private func apply(clear:Bool) {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {
      if !clear {
        try appearance.validate()
        guard appearance.textures.values.allSatisfy({$0.uvIndex==0}) else {throw FormError.invalid("This surface supplies UV 0. Choose UV 0 for its texture maps.")}
        if !supportsDisplacement,appearance.displacementScaleMM != 0,appearance.textures[PhysicalTextureChannel.displacement.rawValue] != nil {
          throw FormError.invalid("Threads support normal and bump maps. Remove the displacement map before applying this appearance.")
        }
      }
      guard roughness.isFinite,(0...1).contains(roughness) else {throw FormError.invalid("Use a roughness from zero to one.")}
      let response:Double? = showsRoughness && (initialRoughness != nil || roughness != 0.5) ? roughness:nil
      try onApply(clear ? nil:appearance,clear ? nil:response);dismiss()
    }catch {self.error=error.localizedDescription}
  }
}

/// Captures only the optical field being edited. Apply resolves the live paper
/// again so unrelated caliper, construction, process or artwork edits survive.
@MainActor struct PaperPhysicalAppearanceDraft:Identifiable {
  enum Scope:Equatable {case stock,ply(UUID),stockEdge,plyEdge(UUID),finish(UUID)}
  let id=UUID()
  let projectID:UUID,objectID:UUID
  let scope:Scope
  let appearance:PhysicalAppearance?
  let fallback:PhysicalAppearance
  private let inheritedProfile:PaperSurfaceProfile
  let name:String
  init(project:Project,object:ProductObject,scope:Scope)throws {
    let paper=try PaperConstruction.definition(for:object)
    projectID=project.id;objectID=object.id;self.scope=scope
    var unlayered=paper.stock;unlayered.plies=nil
    var untinted=object;untinted.color=nil
    inheritedProfile=PaperGeometry.faceAppearance(for:untinted,stock:unlayered,project:project,inside:false).profile
    switch scope {
    case .stock:appearance=paper.stock.profile?.appearance;name="Stock · "+paper.stock.name;fallback=inheritedProfile.appearance ?? .init()
    case .stockEdge:appearance=paper.stock.profile?.edgeAppearance;name="Cut edge · "+paper.stock.name;fallback = .init()
    case .ply(let id):
      guard let ply=paper.stock.plies?.first(where:{$0.id==id}) else {throw FormError.missing("Paper ply missing.")}
      appearance=ply.profile?.appearance;name="Ply · "+ply.name
      fallback=inheritedProfile.appearance ?? .init()
    case .plyEdge(let id):
      guard let ply=paper.stock.plies?.first(where:{$0.id==id}) else {throw FormError.missing("Paper ply missing.")}
      appearance=ply.profile?.edgeAppearance;name="Ply cut edge · "+ply.name
      fallback=paper.stock.profile?.edgeAppearance ?? .init()
    case .finish(let id):
      guard let finish=paper.finishes?.first(where:{$0.id==id}) else {throw FormError.missing("Paper finish missing.")}
      appearance=finish.appearance;name="Finish · "+finish.name
      fallback=PaperGeometry.faceAppearance(for:untinted,stock:paper.stock,project:project,inside:finish.side == .inside).profile.appearance ?? .init()
    }
  }
  func apply(_ value:PhysicalAppearance?,to store:StudioStore)throws {
    guard let project=store.project,project.id==projectID,let object=project.objects.first(where:{$0.id==objectID}),!object.locked else {
      throw FormError.invalid("This paper target is no longer editable in the current project.")
    }
    let current=try PaperPhysicalAppearanceDraft(project:project,object:object,scope:scope)
    guard current.appearance==appearance,appearance != nil || current.fallback==fallback else {throw FormError.invalid("This appearance changed while the editor was open. Cancel and reopen to retain the newer edit.")}
    try value?.validate()
    if value==appearance {return}
    var stock=try PaperConstruction.definition(for:object).stock
    var arguments:[String:Any]=["object_id":objectID.uuidString]
    switch scope {
    case .stock,.stockEdge:
      let edge=scope == .stockEdge,key=edge ? "edgeAppearance":"appearance"
      var profile=stock.profile ?? current.inheritedProfile
      if edge,stock.profile==nil {profile.appearance=nil}
      if edge {profile.edgeAppearance=value}else{profile.appearance=value};stock.profile=profile
      var encoded=try jsonObject(stock) as! [String:Any],profileJSON=try jsonObject(profile) as! [String:Any]
      // configure merges stock profiles; an omitted optional field would retain
      // the previous appearance instead of clearing the local override.
      profileJSON[key]=try value.map{try jsonObject($0)} ?? NSNull();encoded["profile"]=profileJSON
      arguments["command"]="configure";arguments["stock"]=encoded
    case .ply(let id),.plyEdge(let id):
      guard let index=stock.plies?.firstIndex(where:{$0.id==id}) else {throw FormError.missing("Paper ply missing.")}
      var profile=stock.plies![index].profile ?? current.inheritedProfile
      if stock.plies![index].profile==nil {profile.color=nil;profile.edgeAppearance=nil;if case .plyEdge=scope {profile.appearance=nil}}
      if case .plyEdge=scope {profile.edgeAppearance=value}else{profile.appearance=value};stock.plies![index].profile=profile
      arguments["command"]="configure";arguments["stock"]=try jsonObject(stock)
    case .finish(let id):
      arguments["command"]="set_finish"
      arguments["finish"]=["id":id.uuidString,"appearance":try value.map{try jsonObject($0)} ?? NSNull()]
    }
    store.engine.endInteraction()
    _ = try store.engine.call("form_paper",arguments:arguments,source:"Studio")
    store.engine.endInteraction();store.changed()
  }
}

import AppKit
import FormCore
import SwiftUI
import UniformTypeIdentifiers

/// Editing drafts remain local until Apply, which uses the public domain command
/// and creates one project Undo entry for the complete material change.
struct MaterialAppearanceControls:View {
  @EnvironmentObject var store:StudioStore
  let materialID:String
  @State private var editing:FormCore.Material?
  var body:some View {
    if store.project != nil,let material=store.materials.first(where:{$0.id==materialID}) {
      Button("Physical appearance…") {editing=material}
        .accessibilityLabel("Edit physical material appearance")
        .sheet(item:$editing) {material in MaterialAppearanceEditor(material:material).environmentObject(store)}
    }
  }
}

private struct MaterialAppearanceEditor:View {
  @EnvironmentObject var store:StudioStore
  @Environment(\.dismiss) private var dismiss
  let material:FormCore.Material
  @State private var frontAppearance:PhysicalAppearance
  @State private var backAppearance:PhysicalAppearance
  @State private var editingBack=false
  @State private var hasBack:Bool
  @State private var backColor:String
  @State private var backRoughness:Double
  @State private var backMetallic:Double
  @State private var thickness:Double
  @State private var roughness:Double
  @State private var metallic:Double
  @State private var references:[MaterialReference]
  @State private var error=""
  @State private var referenceTitle=""
  @State private var referenceURL=""
  init(material:FormCore.Material) {
    self.material=material;_frontAppearance=State(initialValue:material.appearance ?? .init())
    _backAppearance=State(initialValue:material.backSurface?.appearance ?? .init())
    _hasBack=State(initialValue:material.backSurface != nil)
    _backColor=State(initialValue:material.backSurface?.color ?? material.color)
    _backRoughness=State(initialValue:material.backSurface?.roughness ?? material.roughness)
    _backMetallic=State(initialValue:material.backSurface?.metallic ?? material.metallic)
    _thickness=State(initialValue:material.thickness)
    _roughness=State(initialValue:material.roughness);_metallic=State(initialValue:material.metallic)
    _references=State(initialValue:material.references ?? [])
  }
  var body:some View {
    VStack(alignment:.leading,spacing:14) {
      HStack {VStack(alignment:.leading,spacing:3){Text("Physical appearance").font(.title2);Text(material.name).foregroundStyle(Palette.secondary)};Spacer()}
      ScrollView {
        VStack(alignment:.leading,spacing:18) {
          number("Material caliper (mm)",$thickness)
          Toggle("Independent reverse surface",isOn:$hasBack).onChange(of:hasBack) {_,value in if !value {editingBack=false}}
          if hasBack {
            Picker("Surface",selection:$editingBack) {Text("Front").tag(false);Text("Reverse").tag(true)}.pickerStyle(.segmented)
          }
          surfaceControls
          PhysicalAppearanceDraftControls(appearance:Binding(get:{appearance},set:{appearance=$0}),error:$error)
          referenceControls
        }.padding(.trailing,8)
      }
      if !error.isEmpty {Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
      HStack {
        Button("Cancel"){dismiss()}.keyboardShortcut(.cancelAction)
        Button("Use basic appearance") {attempt {try save(clear:true)}}
        Spacer();Button("Apply") {NSApp.keyWindow?.makeFirstResponder(nil);attempt {try save(clear:false)}}.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
      }
    }.padding(24).frame(width:600,height:740).background(Palette.paper)
  }
  private var surfaceControls:some View {
    VStack(alignment:.leading,spacing:10) {
      SectionLabel("SURFACE")
      if editingBack {InspectorColorPicker("Reverse color",selection:Binding(get:{Color(nsColor:NSColor(hex:backColor))},set:{backColor=NSColor($0).hexString}),supportsOpacity:false)}
      slider("Roughness",Binding(get:{editingBack ? backRoughness:roughness},set:{if editingBack {backRoughness=$0}else {roughness=$0}}))
      slider("Metallic",Binding(get:{editingBack ? backMetallic:metallic},set:{if editingBack {backMetallic=$0}else {metallic=$0}}))
    }
  }
  private var referenceControls:some View {
    VStack(alignment:.leading,spacing:9) {
      SectionLabel("MATERIAL REFERENCES")
      ForEach(Array(references.enumerated()),id:\.offset) {index,reference in
        HStack {if let raw=reference.url,let url=URL(string:raw) {Link(reference.title,destination:url)}else {Text(reference.title)};Spacer();Text(reference.evidence.rawValue).font(.caption).foregroundStyle(Palette.secondary);Button("Remove"){references.remove(at:index)}}
      }
      TextField("Reference title",text:$referenceTitle)
      TextField("Source URL",text:$referenceURL)
      Button("Add reference link") {attempt {
        let value=MaterialReference(title:referenceTitle,url:referenceURL,evidence:.photograph)
        try value.validate();references.append(value);referenceTitle="";referenceURL=""
      }}.disabled(referenceTitle.isEmpty || referenceURL.isEmpty || references.count>=64)
    }
  }
  private var appearance:PhysicalAppearance {
    get {editingBack ? backAppearance:frontAppearance}
    nonmutating set {if editingBack {backAppearance=newValue}else {frontAppearance=newValue}}
  }
  private func slider(_ title:String,_ binding:Binding<Double>)->some View {
    HStack {Text(title).frame(width:180,alignment:.leading);Slider(value:binding,in:0...1);Text(binding.wrappedValue,format:.number.precision(.fractionLength(2))).monospacedDigit().frame(width:40,alignment:.trailing)}
  }
  private func number(_ title:String,_ binding:Binding<Double>)->some View {
    VStack(alignment:.leading,spacing:3) {Text(title).font(.caption);TextField(title,value:binding,format:.number).textFieldStyle(.roundedBorder).accessibilityLabel(title)}
  }
  private func save(clear:Bool)throws {
    guard store.materials.first(where:{$0.id==material.id})==material else {throw FormError.invalid("This material changed while the editor was open. Cancel and reopen to retain the newer edit.")}
    try frontAppearance.validate()
    let back=MaterialSurfaceResponse(color:backColor,roughness:backRoughness,metallic:backMetallic,appearance:backAppearance)
    if hasBack {try back.validate()}
    _ = try store.engine.call("form_material",arguments:["command":"update","material_id":material.id,"patch":["appearance":clear ? NSNull():try jsonObject(frontAppearance),"backSurface":hasBack && !clear ? try jsonObject(back):NSNull(),"roughness":roughness,"metallic":metallic,"thickness":thickness,"references":try jsonObject(references)]],source:"Studio")
    store.changed();dismiss()
  }
  private func attempt(_ body:()throws->Void) {do {try body();error=""}catch {self.error=error.localizedDescription}}
}

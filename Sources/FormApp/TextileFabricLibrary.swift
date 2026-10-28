import AppKit
import FormCore
import SwiftUI

struct TextileFabricLibrary: View {
  @EnvironmentObject var store:StudioStore
  @Environment(\.dismiss) var dismiss
  @State private var editing:FormCore.Material?
  @State private var patternEditing:FormCore.Material?
  var body:some View {
    VStack(alignment:.leading,spacing:20) {
      HStack {
        VStack(alignment:.leading,spacing:6) {
          Text("Fabrics & textile materials").font(.system(size:25,design:.serif))
          Text("Physical specifications and studio inventory, shared across projects.").font(.system(size:11)).foregroundStyle(Palette.secondary)
        }
        Spacer();Button("Done"){dismiss()}.keyboardShortcut(.cancelAction)
      }
      ScrollView {
        LazyVStack(spacing:10) {
          ForEach(store.library.materials.filter{$0.fabric != nil}) {material in
            HStack(spacing: 8) {
            Button {editing=material} label: {
              HStack(spacing:14) {
                RoundedRectangle(cornerRadius:7).fill(Color(nsColor:NSColor(hex:material.color))).frame(width:48,height:55)
                VStack(alignment:.leading,spacing:4) {
                  Text(material.name).font(.system(size:13,weight:.medium))
                  Text(material.fabric!.composition).font(.system(size:11)).foregroundStyle(Palette.secondary)
                  Text([material.fabric!.weightGSM.map{String(format:"%.0f GSM",$0)},material.fabric!.inventoryMeters.map{String(format:"%.1f m in studio",$0)},material.fabric!.specificationsVerified ? "Verified specification":"Generic / unverified specification"].compactMap{$0}.joined(separator:" · "))
                    .font(.system(size:10)).foregroundStyle(Palette.secondary)
                }
                Spacer();Image(systemName:"slider.horizontal.3").foregroundStyle(Palette.secondary)
              }.padding(12).background(.white,in:RoundedRectangle(cornerRadius:10)).contentShape(Rectangle())
            }.buttonStyle(.plain)
              Button {
                patternEditing = store.project?.material(material.id) ?? material
              } label: {
                VStack(spacing: 5) {
                  Image(systemName: "square.grid.3x3").font(.system(size: 16))
                  Text(store.project?.material(material.id).fabric?.pattern == nil ? "Pattern" : "Edit pattern").font(.system(size: 9))
                }.frame(width: 70, height: 74).background(.white, in: RoundedRectangle(cornerRadius: 10))
              }.buttonStyle(.plain).disabled(store.project == nil).help("Edit this project's fabric repeat design")
            }
          }
        }
      }
      Button("Add fabric") {
        var material=FormCore.Material("fabric_"+UUID().uuidString,"New fabric","Fabric","#D4CDBB",roughness:0.9,thickness:0.6)
        material.fabric=FabricProfile(composition:"Unspecified composition",structure:.woven);editing=material
      }.buttonStyle(.borderless)
    }.padding(28).frame(width:700,height:610).background(Palette.paper)
      .sheet(item:$editing) {material in FabricMaterialEditor(material:material) {changed in
        var changed = changed; changed.fabric?.pattern = nil
        if let i=store.library.materials.firstIndex(where:{$0.id==changed.id}) {store.library.materials[i]=changed}
        else {store.library.materials.append(changed)}
        store.saveLibrary();editing=nil
      }}
      .sheet(item:$patternEditing) {material in
        FabricPatternEditor(material: material, project: store.project) { sourceID in
          patternEditing = nil; dismiss()
          store.showingLibrary = false
          DispatchQueue.main.async {
            store.showSurface(.artwork); store.artworkSession.activate(sourceID)
            DispatchQueue.main.async { store.artworkSession.canvas?.fit(all: false) }
          }
        }.environmentObject(store)
      }
  }
}

private struct FabricMaterialEditor:View {
  @Environment(\.dismiss) var dismiss
  let material:FormCore.Material
  let save:(FormCore.Material)->Void
  @State private var draft:FormCore.Material
  @State private var error=""
  @State private var gsm:String
  @State private var usableWidth:String
  @State private var inventory:String
  init(material:FormCore.Material,save:@escaping(FormCore.Material)->Void) {
    self.material=material;self.save=save;_draft=State(initialValue:material)
    _gsm=State(initialValue:material.fabric?.weightGSM.map{String(format:"%g",$0)} ?? "")
    _usableWidth=State(initialValue:material.fabric?.usableWidth.map{String(format:"%g",$0)} ?? "")
    _inventory=State(initialValue:material.fabric?.inventoryMeters.map{String(format:"%g",$0)} ?? "")
  }
  private func number(_ text:String,_ label:String) throws -> Double? {
    if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {return nil}
    guard let value=Double(text),value.isFinite else {throw FormError.invalid("Enter a valid number for \(label), or leave it unknown.")}
    return value
  }
  var body:some View {
    VStack(alignment:.leading,spacing:18) {
      Text("Fabric specification").font(.system(size:24,design:.serif))
      Form {
        TextField("Material name",text:$draft.name)
        ColorPicker("Color",selection:Binding(get:{Color(nsColor:NSColor(hex:draft.color))},set:{draft.color=NSColor($0).hexString}),supportsOpacity:false)
        TextField("Composition",text:Binding(get:{draft.fabric?.composition ?? ""},set:{draft.fabric?.composition=$0}))
        Picker("Structure",selection:Binding(get:{draft.fabric?.structure ?? .woven},set:{draft.fabric?.structure=$0})) {
          ForEach(FabricProfile.Structure.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}
        }
        TextField("Weight (GSM)",text:$gsm)
        TextField("Usable width (mm)",text:$usableWidth)
        TextField("Inventory (meters)",text:$inventory)
        TextField("Supplier",text:Binding(get:{draft.fabric?.supplier ?? ""},set:{draft.fabric?.supplier=$0}))
        TextField("SKU",text:Binding(get:{draft.fabric?.sku ?? ""},set:{draft.fabric?.sku=$0}))
        TextField("Care / production notes",text:Binding(get:{draft.fabric?.care ?? ""},set:{draft.fabric?.care=$0}))
        Toggle("Specifications verified against the material",isOn:Binding(get:{draft.fabric?.specificationsVerified ?? false},set:{draft.fabric?.specificationsVerified=$0}))
      }.textFieldStyle(.roundedBorder)
      if !error.isEmpty {Text(error).foregroundStyle(.red).font(.system(size:11))}
      HStack {Button("Cancel"){dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button("Save fabric") {
        NSApp.keyWindow?.makeFirstResponder(nil)
        do {guard !draft.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw FormError.invalid("Name the fabric.")};draft.fabric?.weightGSM=try number(gsm,"weight");draft.fabric?.usableWidth=try number(usableWidth,"usable width");draft.fabric?.inventoryMeters=try number(inventory,"inventory");try draft.fabric?.validate();save(draft)} catch {self.error=error.localizedDescription}
      }.keyboardShortcut(.defaultAction)}
    }.padding(28).frame(width:530).background(Palette.paper)
  }
}

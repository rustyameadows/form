import AppKit
import FormCore
import SwiftUI

struct CollectionSupplyLibrary:View {
  @ObservedObject var store:StudioStore
  @State private var editing:StudioSupply?
  @State private var error=""
  var body:some View {
    LazyVStack(alignment:.leading,spacing:10) {
      Text("Blank, trim and consumable declarations. Thread and fabric inventory retain their existing identities. No record is created automatically and nothing is deducted.").font(.system(size:11)).foregroundStyle(Palette.secondary)
      ForEach(store.library.textileProduction?.supplies ?? []) {s in HStack {
        Button{editing=s}label:{VStack(alignment:.leading,spacing:4) {Text(s.name).fontWeight(.medium);Text(s.category+" / "+(s.available ?? "Unknown")+" "+s.unit.rawValue+" available");Text([s.manufacturer,s.sku,s.supplier].compactMap{$0}.joined(separator:" · ")).foregroundStyle(Palette.secondary)}.frame(maxWidth:.infinity,alignment:.leading)}.buttonStyle(.plain)
        Button{do{_ = try store.productionCall("form_textile_stock",arguments:["command":"remove_supply","stock_id":s.id.uuidString],source:"Studio")}catch{self.error=error.localizedDescription}}label:{Image(systemName:"trash")}.buttonStyle(.borderless)
      }.padding(12).background(.white,in:RoundedRectangle(cornerRadius:8))}
      Button("Add supply declaration"){editing = .init(name:"New supply")}
      if !error.isEmpty {Text(error).foregroundStyle(Palette.ink)}
    }.font(.system(size:11)).sheet(item:$editing){s in CollectionSupplyEditor(item:s){v in _ = try store.productionCall("form_textile_stock",arguments:["command":"save_supply","supply":try jsonObject(v)],source:"Studio");editing=nil}}
  }
}
struct CollectionSupplyEditor:View {
  @Environment(\.dismiss) var dismiss
  let save:(StudioSupply)throws->Void
  @State var item:StudioSupply
  @State private var error=""
  init(item:StudioSupply,save:@escaping(StudioSupply)throws->Void) {_item=State(initialValue:item);self.save=save}
  private func optional(_ key:WritableKeyPath<StudioSupply,String?>)->Binding<String> {Binding(get:{item[keyPath:key] ?? ""},set:{item[keyPath:key]=$0.isEmpty ? nil:$0})}
  var body:some View {
    VStack(alignment:.leading,spacing:16) {
      Text("Supply declaration").font(.system(size: 24, weight: .semibold))
      Form {
        TextField("Supply name",text:$item.name)
        Picker("Category",selection:$item.category){Text("Blank").tag("blank");Text("Trim").tag("trim");Text("Consumable").tag("consumable")}
        Picker("Unit",selection:$item.unit){ForEach([CollectionUnit.piece,.m,.m2],id:\.self){Text($0.rawValue).tag($0)}}
        TextField("Available quantity · unknown if blank",text:optional(\.available))
        TextField("Declared price per unit",text:optional(\.unitPrice));TextField("Currency",text:optional(\.currency))
        TextField("Manufacturer",text:optional(\.manufacturer));TextField("SKU",text:optional(\.sku));TextField("Supplier",text:optional(\.supplier));TextField("Studio location",text:optional(\.location));HStack {TextField("Declared width (mm)",text:optional(\.widthMM));TextField("Declared sheet length (mm)",text:optional(\.sheetLengthMM))};TextField("Notes",text:optional(\.notes),axis:.vertical).lineLimit(2...4)
      }.textFieldStyle(.roundedBorder)
      Text("Exact nonnegative decimals; unknown values stay blank. Assignments are portable snapshots and refresh only when chosen explicitly.").font(.system(size:10)).foregroundStyle(Palette.secondary)
      if !error.isEmpty {Text(error).font(.system(size:11)).foregroundStyle(Palette.ink)}
      HStack {Button("Cancel"){dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button("Save supply"){do{try item.validate();try save(item)}catch{self.error=error.localizedDescription}}.keyboardShortcut(.defaultAction).accessibilityIdentifier("collection-supply-save")}
    }.padding(26).frame(width:570).background(Palette.paper)
  }
}

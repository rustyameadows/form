import AppKit
import FormCore
import SwiftUI

struct TextileProductionLibraryButton:View {
  @EnvironmentObject var store:StudioStore
  @State private var stocks=false
  @State private var jobs=false
  var body:some View {
    HStack {
      Button {stocks=true} label:{Label("Textile stock & equipment",systemImage:"circle.circle")}
      Spacer();Button {jobs=true} label:{Label("Production jobs",systemImage:"list.clipboard")}.disabled(store.project==nil)
    }.font(.system(size:11)).buttonStyle(.borderless)
      .sheet(isPresented:$stocks) {TextileProductionLibraryView().environmentObject(store)}
      .sheet(isPresented:$jobs) {ProductionJobsView().environmentObject(store)}
  }
}
struct TextileProductionLibraryView:View {
  @EnvironmentObject var store:StudioStore
  @Environment(\.dismiss) var dismiss
  @State private var section=0
  @State private var thread:StudioThread?
  @State private var equipment:EmbroideryEquipment?
  @State private var error=""
  private var stock:TextileProductionLibrary {store.library.textileProduction ?? .init()}
  var body:some View {
    VStack(alignment:.leading,spacing:18) {
      HStack {VStack(alignment:.leading,spacing:5) {Text("Textile stock & equipment").font(.system(size:24,design:.serif));Text("Studio records · portable snapshots on assignment · no automatic stock deduction").font(.system(size:10)).foregroundStyle(Palette.secondary)};Spacer();Button("Done") {dismiss()}.keyboardShortcut(.cancelAction)}
      Picker("Library",selection:$section) {Text("Thread stock").tag(0);Text("Equipment declarations").tag(1);Text("Blanks, trims & supplies").tag(2)}.pickerStyle(.segmented)
      ScrollView {
        LazyVStack(spacing:9) {
          if section==0 {
            ForEach(stock.threads) {item in
              HStack {
                Button {thread=item} label:{
                  HStack(spacing:12) {RoundedRectangle(cornerRadius:6).fill(Color(nsColor:NSColor(hex:item.color))).frame(width:35,height:45)
                    VStack(alignment:.leading,spacing:4) {Text(item.name).font(.system(size:12,weight:.semibold));Text([item.brand,item.sku,item.supplier].compactMap {$0}.joined(separator:" · ")).font(.system(size:10)).foregroundStyle(Palette.secondary)
                      Text(item.availableMeters.map {String(format:"%.3g m recorded",$0)} ?? "Inventory unknown").font(.system(size:10)).foregroundStyle(Palette.secondary)};Spacer()}
                }.buttonStyle(.plain)
                Button {remove("remove_thread",id:item.id)} label:{Image(systemName:"trash")}.buttonStyle(.borderless).help("Remove Studio record; assigned snapshots remain portable")
              }.padding(12).background(.white,in:RoundedRectangle(cornerRadius:8))
            }
            if stock.threads.isEmpty {ContentUnavailableView("No thread stock recorded",systemImage:"circle.circle",description:Text("Add the threads you own, with supplier and stock information when known."))}
          } else if section==2 {CollectionSupplyLibrary(store:store)} else {
            ForEach(stock.equipment) {item in
              HStack {Button {equipment=item} label:{VStack(alignment:.leading,spacing:5) {Text(item.name).font(.system(size:12,weight:.semibold));Text("\(item.hoops.count) declared hoops · \(item.formats.isEmpty ? "Formats unknown":item.formats.joined(separator:", ").uppercased())").font(.system(size:10)).foregroundStyle(Palette.secondary)}.frame(maxWidth:.infinity,alignment:.leading)}.buttonStyle(.plain)
                Button {remove("remove_equipment",id:item.id)} label:{Image(systemName:"trash")}.buttonStyle(.borderless)
              }.padding(14).background(.white,in:RoundedRectangle(cornerRadius:8))
            }
            if stock.equipment.isEmpty {ContentUnavailableView("No embroidery equipment declared",systemImage:"square.dashed",description:Text("Record supported hoop sizes and file formats. These profiles do not connect to or control machines."))}
          }
        }
      }
      if !error.isEmpty {Text(error).font(.system(size:11)).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
      HStack {if section != 2 {Button(section==0 ? "Add thread stock":"Add equipment declaration") {if section==0 {thread = .init(name:"New thread",color:"#D7CAB0")} else {equipment = .init(name:"New embroidery equipment")}}};Spacer();Text("Unknown prices and capacities remain unknown.").font(.system(size:10)).foregroundStyle(Palette.secondary)}
    }.padding(26).frame(width:760,height:640).background(Palette.paper)
      .sheet(item:$thread) {item in StudioThreadEditor(item:item) {changed in try save("save_thread",key:"thread",value:changed);thread=nil}}
      .sheet(item:$equipment) {item in EmbroideryEquipmentEditor(item:item) {changed in try save("save_equipment",key:"equipment",value:changed);equipment=nil}}
  }
  private func save<T:Encodable>(_ command:String,key:String,value:T)throws {_ = try store.productionCall("form_textile_stock",arguments:["command":command,key:try jsonObject(value)],source:"Studio");error=""}
  private func remove(_ command:String,id:UUID) {do {_ = try store.productionCall("form_textile_stock",arguments:["command":command,(command=="remove_thread" ? "stock_id":"equipment_id"):id.uuidString],source:"Studio");error=""} catch {self.error=error.localizedDescription}}
}
private struct StudioThreadEditor:View {
  @Environment(\.dismiss) var dismiss
  let save:(StudioThread)throws->Void
  @State private var item:StudioThread
  @State private var available:String
  @State private var spool:String
  @State private var price:String
  @State private var currency:String
  @State private var error=""
  init(item:StudioThread,save:@escaping(StudioThread)throws->Void) {self.save=save;_item=State(initialValue:item);_available=State(initialValue:item.availableMeters.map {String($0)} ?? "");_spool=State(initialValue:item.spoolMeters.map {String($0)} ?? "");_price=State(initialValue:item.spoolPrice.map {String($0)} ?? "");_currency=State(initialValue:item.currency ?? "")}
  private func text(_ key:WritableKeyPath<StudioThread,String?>)->Binding<String> {Binding(get:{item[keyPath:key] ?? ""},set:{item[keyPath:key]=ProductionNumberInput.text($0)})}
  var body:some View {
    VStack(alignment:.leading,spacing:16) {
      Text("Thread stock").font(.system(size:24,design:.serif))
      Form {
        TextField("Name",text:$item.name)
        ColorPicker("Color",selection:Binding(get:{Color(nsColor:NSColor(hex:item.color))},set:{item.color=NSColor($0).hexString}),supportsOpacity:false)
        TextField("Brand",text:text(\.brand));TextField("SKU / catalog",text:text(\.sku));TextField("Supplier",text:text(\.supplier));TextField("Fiber / specification",text:text(\.fiber));TextField("Studio location",text:text(\.location))
        TextField("Available meters · unknown if blank",text:$available)
        TextField("Spool length (m)",text:$spool);TextField("Price per spool",text:$price);TextField("Currency · three-letter code",text:$currency)
        TextField("Notes",text:text(\.notes),axis:.vertical).lineLimit(2...4)
      }.textFieldStyle(.roundedBorder)
      Text("Unit cost needs both a known spool price and length. Assignments capture this record; editing library stock does not rewrite projects or jobs.").font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      if !error.isEmpty {Text(error).font(.system(size:11)).foregroundStyle(.red)}
      HStack {Button("Cancel") {dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button("Save thread") {commit()}.keyboardShortcut(.defaultAction)}
    }.padding(26).frame(width:570).background(Palette.paper)
  }
  private func commit() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {var value=item;value.availableMeters=try ProductionNumberInput.number(available,"available stock");value.spoolMeters=try ProductionNumberInput.number(spool,"spool length");value.spoolPrice=try ProductionNumberInput.number(price,"spool price");value.currency=ProductionNumberInput.text(currency)?.uppercased();try value.validate();try save(value)} catch {self.error=error.localizedDescription}
  }
}
private struct HoopDraft:Identifiable {var id=UUID();var name:String;var width:String;var height:String}
private struct EmbroideryEquipmentEditor:View {
  @Environment(\.dismiss) var dismiss
  let save:(EmbroideryEquipment)throws->Void
  @State private var item:EmbroideryEquipment
  @State private var hoops:[HoopDraft]
  @State private var formats:String
  @State private var needles:String
  @State private var error=""
  init(item:EmbroideryEquipment,save:@escaping(EmbroideryEquipment)throws->Void) {self.save=save;_item=State(initialValue:item);_hoops=State(initialValue:item.hoops.map {.init(name:$0.name,width:String($0.width),height:String($0.height))});_formats=State(initialValue:item.formats.joined(separator:", "));_needles=State(initialValue:item.needleCount.map {String($0)} ?? "")}
  var body:some View {
    VStack(alignment:.leading,spacing:15) {
      Text("Embroidery equipment declaration").font(.system(size:23,design:.serif))
      Form {
        TextField("Name",text:$item.name)
        TextField("Manufacturer",text:Binding(get:{item.manufacturer ?? ""},set:{item.manufacturer=ProductionNumberInput.text($0)}))
        TextField("Model",text:Binding(get:{item.model ?? ""},set:{item.model=ProductionNumberInput.text($0)}))
        TextField("Formats · comma separated, e.g. dst",text:$formats)
        TextField("Needle count · unknown if blank",text:$needles)
        Toggle("Declarations checked against the equipment specification",isOn:$item.declarationsVerified)
      }.textFieldStyle(.roundedBorder)
      HStack {Text("SUPPORTED HOOPS · MM").font(.system(size:9,weight:.semibold));Spacer();Button("Add hoop") {hoops.append(.init(name:"Hoop \(hoops.count+1)",width:"",height:""))}}
      ScrollView {VStack {ForEach($hoops) {$hoop in HStack {TextField("Name",text:$hoop.name);TextField("Width",text:$hoop.width).frame(width:85);Text("×");TextField("Height",text:$hoop.height).frame(width:85);Button {hoops.removeAll {$0.id==hoop.id}} label:{Image(systemName:"minus.circle")}}.textFieldStyle(.roundedBorder)}}}.frame(height:150)
      Text("Checks compare declared hoop axes and DST support only. No automatic rotation, device connection, scheduling, or physical sewing capability is implied.").font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      if !error.isEmpty {Text(error).font(.system(size:11)).foregroundStyle(.red)}
      HStack {Button("Cancel") {dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button("Save declaration") {commit()}.keyboardShortcut(.defaultAction)}
    }.padding(26).frame(width:660).background(Palette.paper)
  }
  private func commit() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {
      var value=item
      value.hoops=try hoops.map {row in guard let w=try ProductionNumberInput.number(row.width,"hoop width"),let h=try ProductionNumberInput.number(row.height,"hoop height") else {throw FormError.invalid("Enter both dimensions for each hoop, or remove its row.")};return .init(name:row.name,width:w,height:h)}
      value.formats=formats.split(separator:",").map {$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}.filter {!$0.isEmpty}
      let text=needles.trimmingCharacters(in:.whitespacesAndNewlines)
      if text.isEmpty {value.needleCount=nil} else {guard let count=Int(text) else {throw FormError.invalid("Needle count must be an integer or unknown.")};value.needleCount=count}
      try value.validate();try save(value)
    } catch {self.error=error.localizedDescription}
  }
}

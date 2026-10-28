import AppKit
import FormCore
import FormGraphics
import UniformTypeIdentifiers

@MainActor final class DecorationPreparationDraft:ObservableObject {
  weak var store:StudioStore?
  let projectID:UUID
  let objectID:UUID
  @Published var process=DecorationProcess.dtf
  @Published var mirror=false
  @Published var includeBackground=false
  @Published var weedMargin="0"
  @Published var dpi="300"
  @Published var whitePolicy=DecorationWhitePolicy.printOpaqueWhite
  @Published var colorDelivery=DecorationColorDelivery.sRGBRaster
  @Published var convertSpotAlternates=false
  @Published var underbaseReference=true
  @Published var name="Decoration preparation"
  @Published var quantity="1"
  @Published var notes=""
  @Published var materialNotes=""
  @Published var equipmentNotes=""
  @Published var materials:[String:String]=[:]
  @Published private(set) var plan:DecorationGeometry?
  @Published private(set) var error=""
  @Published private(set) var capturedID:UUID?
  private(set) var geometryBuilds=0
  init(store:StudioStore,objectID:UUID) {
    self.store=store;self.objectID=objectID;projectID=store.project?.id ?? UUID()
    if let object=store.project?.objects.first(where:{$0.id==objectID}) {name=object.name+" / DTF"}
    refresh()
  }
  func chooseProcess(_ value:DecorationProcess) {
    if let object=store?.project?.objects.first(where:{$0.id==objectID}),name==object.name+" / "+process.rawValue.uppercased() {name=object.name+" / "+value.rawValue.uppercased()}
    process=value;mirror=value == .htv;underbaseReference=value == .dtf;weedMargin="0";colorDelivery = .sRGBRaster;convertSpotAlternates=false
    refresh()
  }
  private func number(_ text:String,_ title:String,range:ClosedRange<Double>) throws -> Double {
    guard let value=Double(text.trimmingCharacters(in:.whitespacesAndNewlines)),value.isFinite,range.contains(value) else{throw FormError.invalid("\(title) must be a finite number from \(range.lowerBound) to \(range.upperBound).")};return value
  }
  func options()throws->DecorationPreparationOptions {
    var value=DecorationPreparationOptions(process:process);value.mirror=mirror;value.includeBackground=includeBackground
    value.weedMargin=process == .htv ? try number(weedMargin,"Weed padding",range:0...50):0
    value.dpi=process == .dtf ? try number(dpi,"DPI",range:72...600):300
    value.whitePolicy=whitePolicy;value.colorDelivery=process == .dtf ? colorDelivery:.sRGBRaster;value.convertSpotAlternates=process == .dtf && convertSpotAlternates
    value.includeUnderbaseReference=process == .dtf && underbaseReference
    value.layerMaterials=process == .htv ? materials.keys.sorted().compactMap {key in
      guard let name=materials[key]?.trimmingCharacters(in:.whitespacesAndNewlines),!name.isEmpty else{return nil}
      return DecorationLayerMaterial(paintKey:key,name:name)
    }:[]
    value.materialNotes=ProductionNumberInput.text(materialNotes);value.equipmentNotes=ProductionNumberInput.text(equipmentNotes);try value.validate();return value
  }
  func arguments()throws->[String:Any] {
    guard let count=Int(quantity.trimmingCharacters(in:.whitespacesAndNewlines)),(1...100000).contains(count) else{throw FormError.invalid("Quantity must be an integer from 1 to 100,000.")}
    return ["kind":"decoration","command":"create","object_id":objectID.uuidString,"preparation":try jsonObject(options()),"name":name,"quantity":count,"notes":notes]
  }
  func refresh() {
    guard let store,let project=store.project,project.id==projectID else{plan=nil;error="This preparation belongs to a different project.";return}
    do {
      let value=try options(),assets=store.repository.url(for:projectID).appendingPathComponent("Assets")
      plan=try DecorationGeometry(project:project,objectID:objectID,options:value,assets:assets);geometryBuilds+=1;error=""
    }catch{plan=nil;self.error=error.localizedDescription}
  }
  @discardableResult func capture()->Bool {
    guard let store,store.project?.id==projectID else{error="This preparation belongs to a different project.";return false}
    do {
      let args=try arguments(),input=try store.decorationPlanning(args)
      _ = try store.captureDecoration(input.plan,name:input.name,quantity:input.quantity,notes:input.notes)
      plan=input.plan;capturedID=store.project?.decorationPreparations?.last?.id;error="";return true
    }catch{self.error=error.localizedDescription;return false}
  }
  func assignProfile(_ path:String) {
    guard let store,store.project?.id==projectID else{return}
    do {_ = try store.colorProfileCall(["command":"set","object_id":objectID.uuidString,"profile_path":path]);store.changed();refresh()}
    catch{self.error=error.localizedDescription}
  }
  func chooseProfileFile() {
    let panel=NSOpenPanel();panel.allowedContentTypes=[UTType("com.apple.colorsync-profile") ?? .data];panel.allowsMultipleSelection=false;panel.canChooseDirectories=false
    guard panel.runModal() == .OK,let url=panel.url else{return};assignProfile(url.path)
  }
}

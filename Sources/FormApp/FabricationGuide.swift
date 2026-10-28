import AppKit
import Combine
import FormCore

enum FabricationStep:Int,CaseIterable,Identifiable {
  case object,process,material,prepare,review
  var id:Int{rawValue}
  var title:String{["What to make","Process","Material","Prepare","Review & export"][rawValue]}
  var detail:String{["Choose the source","Choose how to make it","Confirm actual stock","Arrange and check","Files and next steps"][rawValue]}
}
enum GuidedProcess:String,CaseIterable,Identifiable {
  case paper,print3D,page,pattern,layout,embroidery,decoration
  var id:String{rawValue}
  var destination:FabricationDestination? {
    switch self {case .paper:return nil;case .print3D:return .print3D;case .page:return .page;case .pattern:return .pattern;case .layout:return .layout;case .embroidery:return .embroidery;case .decoration:return .decoration}
  }
  var title:String {self == .paper ? "Print, cut & fold":destination!.title}
  var symbol:String {self == .paper ? "shippingbox":destination!.symbol}
  var explanation:String {
    switch self {
    case .paper:return "Uses the object's identified paper panels, cut outline and crease lines."
    case .print3D:return "Uses the selected rigid model. Choose the printer, filament and slicing settings in bed preparation."
    case .page:return "Uses the object's physical artwork dimensions and existing page setup."
    case .pattern:return "Uses the original sewing pattern, allowances, notches and grain."
    case .layout:return "Arranges the original cutting pieces on declared material stock."
    case .embroidery:return "Uses the component's editable thread and stitch specification."
    case .decoration:return "Prepares the selected artwork for its declared application process."
    }
  }
  static func available(object:ProductObject,project:Project)->[Self] {
    if PaperConstruction.isPaper(object){return [.paper]}
    if let context=FabricEnvironmentContext(object:object,project:project){return allCases.filter{process in process.destination.map{context.fabricationRoutes.contains($0) && $0.available(in:project,object:object)} ?? false}}
    return allCases.filter{process in
      guard let destination=process.destination else{return false}
      return (process != .decoration || object.recipeID=="artboard") && destination.available(in:project,object:object)
    }
  }
}

/// A source-scoped session draft. No inferred material is confirmed by opening a view.
@MainActor final class FabricationGuide:ObservableObject {
  weak var store:StudioStore?
  @Published var step:FabricationStep = .object
  @Published var process:GuidedProcess?
  @Published var quantity=3
  @Published var stockName=""
  @Published var caliper=""
  @Published var gsm=""
  @Published var grain:PaperStock.Grain = .unknown
  @Published var sheetWidth="700"
  @Published var sheetHeight="1000"
  @Published var margin="10"
  @Published var gap="6"
  @Published var measured=false
  @Published var materialID=""
  @Published var filamentID:UUID?
  @Published var printerID:UUID?
  @Published var issue:String?
  @Published private(set) var confirmedMaterial:String?
  private var context:String?
  private var loadedStock:PaperStock?
  var object:ProductObject?{store?.primary}
  var processes:[GuidedProcess] {guard let object,let project=store?.project else{return []};return GuidedProcess.available(object:object,project:project)}
  var paper:PaperConstruction? {object.flatMap{try? PaperConstruction.definition(for:$0)}}
  var materialFingerprint:String? {
    guard let object,let project=store?.project else{return nil}
    if process == .print3D {
      guard let filament=store?.library.filaments.first(where:{$0.id==filamentID}),let printer=store?.library.printers.first(where:{$0.id==printerID}) else{return nil}
      return (try? JSONSerialization.data(withJSONObject:["filament":jsonObject(filament),"printer":jsonObject(printer)],options:.sortedKeys)).map{String(decoding:$0,as:UTF8.self)}
    }
    if let panels=object.patternAssembly?.panels {return (try? JSONEncoder.form.encode(panels)).map{String(decoding:$0,as:UTF8.self)}}
    if let paper {return (try? JSONEncoder.form.encode(paper.stock)).map{String(decoding:$0,as:UTF8.self)}}
    return (try? JSONEncoder.form.encode(project.material(object.materialID))).map{String(decoding:$0,as:UTF8.self)}
  }
  var materialConfirmed:Bool {
    guard confirmedMaterial != nil,confirmedMaterial==materialFingerprint else{return false}
    if process == .print3D {let setup=store?.project?.printSetups?[object?.id.uuidString ?? ""];return setup?.filamentID==filamentID && setup?.printerID==printerID}
    if let paper {return stockName==paper.stock.name && Double(caliper)==paper.stock.thicknessMM && (gsm.isEmpty ? nil:Double(gsm))==paper.stock.gsm && grain==paper.stock.grain && measured==paper.stock.verified && (step != .material || (Double(sheetWidth)==paper.stock.sheetSizeMM?.x && Double(sheetHeight)==paper.stock.sheetSizeMM?.y))}
    return materialID==object?.materialID
  }
  init(store:StudioStore){self.store=store}
  func reconcile() {
    let next=store?.project.map{$0.id.uuidString+"/"+(object?.id.uuidString ?? "none")}
    if context != next {context=next;step = .object;process=nil;confirmedMaterial=nil;quantity=3;sheetWidth="700";sheetHeight="1000";margin="10";gap="6";reloadMaterial();issue=nil}
    if let process,!processes.contains(process){self.process=nil;confirmedMaterial=nil}
    if let confirmedMaterial,confirmedMaterial != materialFingerprint {self.confirmedMaterial=nil}
  }
  func choose(_ process:GuidedProcess) {guard processes.contains(process) else{return};if self.process != process {confirmedMaterial=nil};self.process=process;issue=nil}
  func reloadMaterial() {
    if let paper {loadedStock=paper.stock;stockName=paper.stock.name;caliper=String(paper.stock.thicknessMM);gsm=paper.stock.gsm.map{String($0)} ?? "";grain=paper.stock.grain;measured=paper.stock.verified
      if let size=paper.stock.sheetSizeMM {sheetWidth=String(size.x);sheetHeight=String(size.y)}
    }
    materialID=object?.materialID ?? ""
    let setup=store?.project?.printSetups?[object?.id.uuidString ?? ""]
    filamentID=setup?.filamentID;printerID=setup?.printerID
  }
  func confirmMaterial() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {
      guard let store,let object,process != nil else{throw FormError.invalid("Choose an object and process first.")}
      if process == .print3D {
        guard !store.printing.busy,let filament=store.library.filaments.first(where:{$0.id==filamentID}),let printer=store.library.printers.first(where:{$0.id==printerID}) else{throw FormError.invalid("Choose a saved filament and printer; finish or cancel any active slice before changing settings.")}
        try filament.validate(for:printer)
        var setup=store.project?.printSetups?[object.id.uuidString] ?? .init();setup.filamentID=filament.id;setup.printerID=printer.id;try setup.validate(nozzle:printer.nozzleDiameter)
        try store.engine.edit("Confirmed production filament and printer"){project in if project.printSetups==nil{project.printSetups=[:]};project.printSetups?[object.id.uuidString]=setup}
        store.metadataRecordsChanged();store.printing.reconcile()
      }else if var d=paper {
        guard loadedStock==d.stock else{throw FormError.invalid("The project's stock changed while you were editing. Reload it before applying.")}
        guard let thickness=Double(caliper),thickness.isFinite,let w=Double(sheetWidth),let h=Double(sheetHeight),w.isFinite,h.isFinite,w>0,h>0 else{throw FormError.invalid("Enter finite caliper and positive sheet dimensions in millimeters.")}
        let weight=gsm.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil:Double(gsm)
        guard gsm.isEmpty || (weight?.isFinite==true && weight!>0) else{throw FormError.invalid("Enter a positive GSM or leave it unknown.")}
        d.stock.name=stockName;d.stock.thicknessMM=thickness;d.stock.gsm=weight;d.stock.grain=grain;d.stock.verified=measured;d.stock.sheetSizeMM = .init(w,h)
        if d != paper {guard store.configurePaper(object,definition:d) else{return}}
        loadedStock=d.stock
      }else if materialID != object.materialID {store.update(object,["material_id":materialID]);guard store.primary?.materialID==materialID else{throw FormError.invalid("Material assignment did not apply.")}}
      confirmedMaterial=materialFingerprint;issue=nil
    }catch{issue=error.localizedDescription}
  }
  func applyLayout()throws {
    guard let store,let d=paper else{return}
    guard let w=Double(sheetWidth),let h=Double(sheetHeight),let m=Double(margin),let g=Double(gap),[w,h,m,g].allSatisfy(\.isFinite),(1...64).contains(quantity) else{throw FormError.invalid("Enter finite sheet dimensions/margins and 1–64 prototypes.")}
    if let stock=d.stock.sheetSizeMM, w>stock.x+1e-6 || h>stock.y+1e-6 {throw FormError.invalid("The preparation sheet exceeds the declared stock sheet. Review and confirm larger stock in Material first.")}
    let layout=try d.net().layout(sheetSize:.init(w,h),marginMM:m,gapMM:g,count:quantity,allowRotation:false)
    guard !layout.hasErrors else{throw FormError.invalid(layout.issues.map(\.message).joined(separator:"\n"))}
    store.paperSheetWidth=w;store.paperSheetHeight=h;store.paperSheetMargin=m;store.paperSheetGap=g;store.paperQuantity=quantity
  }
  var canContinue:Bool {
    switch step {case .object:return object != nil;case .process:return process != nil;case .material:return materialConfirmed;case .prepare:return materialConfirmed && process != nil;case .review:return false}
  }
  func next() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    guard canContinue else{return}
    do {if step == .prepare {try applyLayout()};if let next=FabricationStep(rawValue:step.rawValue+1){step=next};issue=nil}catch{issue=error.localizedDescription}
  }
  func openPreparation() {
    guard let process,let store else{return}
    if let destination=process.destination {store.presentFabrication(destination)}
  }
}

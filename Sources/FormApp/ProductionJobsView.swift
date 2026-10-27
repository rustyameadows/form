import AppKit
import FormCore
import SwiftUI
import UniformTypeIdentifiers

struct ProductionNumberInput {
  static func number(_ value:String,_ label:String)throws -> Double? {
    let text=value.trimmingCharacters(in:.whitespacesAndNewlines);if text.isEmpty {return nil}
    guard let number=Double(text),number.isFinite else {throw FormError.invalid("Enter a finite number for \(label), or leave it unknown.")};return number
  }
  static func text(_ value:String)->String? {let value=value.trimmingCharacters(in:.whitespacesAndNewlines);return value.isEmpty ? nil:value}
}
private struct JobBOMDraft:Identifiable {
  var id=UUID();var name="Additional material";var quantity="1";var unit="item";var price="";var currency="";var supplier="";var sku=""
}
struct ProductionJobsView:View {
  @EnvironmentObject var store:StudioStore
  @Environment(\.dismiss) var dismiss
  @State private var productionKind=0
  @State private var objectID:UUID?
  @State private var selectedJobID:UUID?
  @State private var captured:ProductionJobRevision?
  @State private var currentSource="Not compared"
  @State private var name="Production job"
  @State private var quantity="1"
  @State private var equipmentID:UUID?
  @State private var supersedesID:UUID?
  @State private var outputs:Set<String>=["dst","svg","json"]
  @State private var factor=""
  @State private var allowance=""
  @State private var baseCost=""
  @State private var baseCurrency=""
  @State private var minutes=""
  @State private var hourlyRate=""
  @State private var laborCurrency=""
  @State private var assumptionNotes=""
  @State private var extras:[JobBOMDraft]=[]
  @State private var recordKind=ProductionRecord.Kind.note
  @State private var recordOutcome:ProductionRecord.Outcome?
  @State private var recordStatus=ProductionRecord.Status.planned
  @State private var recordAuthor=""
  @State private var recordNotes=""
  @State private var reportedMeters=""
  @State private var error=""
  init(objectID:UUID? = nil) {_objectID=State(initialValue:objectID)}
  private var objects:[ProductObject] {store.project?.objects.filter {$0.textile?.embroidery != nil} ?? []}
  private var object:ProductObject? {objects.first {$0.id==objectID}}
  private var jobs:[ProductionJob] {Array((store.project?.productionJobs ?? []).reversed())}
  private var selected:ProductionJob? {jobs.first {$0.id==selectedJobID}}
  private var equipment:[EmbroideryEquipment] {store.library.textileProduction?.equipment ?? []}
  var body:some View {
    VStack(alignment:.leading,spacing:16) {
      HStack {VStack(alignment:.leading,spacing:4) {Text("Production jobs").font(.system(size: 25, weight: .semibold));Text(store.project?.name ?? "Open a project").font(.system(size:11)).foregroundStyle(Palette.secondary)};Spacer();Button("Done") {dismiss()}.keyboardShortcut(.cancelAction)}
      Picker("Production kind",selection:$productionKind) {Text("Embroidery").tag(0);Text("HTV / DTF preparations").tag(1);Text("Collection BOM").tag(2)}.pickerStyle(.segmented).frame(width:520)
      if productionKind==2 {CollectionProductionView(store:store)} else if productionKind==1 {DecorationArchiveBrowser(store:store)} else {
      HSplitView {
        VStack(alignment:.leading,spacing:8) {
          Text("CAPTURED JOBS").font(.system(size:9,weight:.semibold)).tracking(1)
          ScrollView {LazyVStack(spacing:7) {
            ForEach(jobs) {job in Button {load(job)} label:{VStack(alignment:.leading,spacing:4) {Text(job.name).font(.system(size:12,weight:.medium));Text("\(job.quantity) items · user status \(job.status.rawValue)").font(.system(size:10));Text(String(job.sourceDigest.prefix(16))).font(.system(size:9,design:.monospaced))}.foregroundStyle(selectedJobID==job.id ? Palette.ink:Palette.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(11).background(selectedJobID==job.id ? Color.white:Color.clear,in:RoundedRectangle(cornerRadius:7))}.buttonStyle(.plain)}
            if jobs.isEmpty {Text("Capture a source revision to prepare its specifications, thread schedule, and review packet.").font(.system(size:11)).foregroundStyle(Palette.secondary).padding(.vertical,16)}
          }}
          Button("New job") {selectedJobID=nil;captured=nil;currentSource="Not compared"}
        }.frame(minWidth:200,idealWidth:225,maxWidth:280).padding(.trailing,16)
        ScrollView {Group {if let selected,let captured {history(selected,captured)} else {creation}}.padding(.horizontal,16)}.frame(minWidth:520)
      }
      if !error.isEmpty {Text(error).font(.system(size:11)).foregroundStyle(Palette.ink).fixedSize(horizontal:false,vertical:true)}
      Text("No machine connection, stock reservation, or deduction. A user-reported approval or completion is recorded against its source digest; it does not automatically verify physical sewing.")
        .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      }
    }.padding(26).frame(width:1080,height:770).background(Palette.paper)
      .onAppear {if objectID==nil {objectID=objects.first?.id}}
      .onChange(of:store.project?.id) {_,_ in dismiss()}
  }
  private var creation:some View {
    VStack(alignment:.leading,spacing:13) {
      Text("Capture a production revision").font(.system(size: 19, weight: .semibold))
      Text("The needle program, editable source, physical specification, assigned thread stock, equipment declaration, and assumptions become a portable immutable snapshot.").font(.system(size:11)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      Picker("Decoration",selection:$objectID) {Text("Choose decoration").tag(UUID?.none);ForEach(objects) {Text($0.name).tag(Optional($0.id))}}
      HStack {TextField("Job name",text:$name);TextField("Quantity",text:$quantity).frame(width:100)}.textFieldStyle(.roundedBorder)
      Picker("Equipment declaration",selection:$equipmentID) {Text("Unknown / no profile").tag(UUID?.none);ForEach(equipment) {Text($0.name).tag(Optional($0.id))}}
      if let design=object?.textile?.embroidery {
        let check=EmbroideryCompatibility.check(design:design,equipment:equipment.first {$0.id==equipmentID},outputs:Array(outputs))
        Text(check.status == .incompatible ? "Declared incompatibility: "+check.messages.joined(separator:" "):check.messages.joined(separator:" ")).font(.system(size:10)).foregroundStyle(check.status == .incompatible ? Palette.ink:Palette.secondary).fixedSize(horizontal:false,vertical:true)
      }
      Picker("Revision lineage",selection:$supersedesID) {Text("Independent job").tag(UUID?.none);ForEach(jobs.filter {$0.objectID==objectID}) {Text("Supersedes "+$0.name).tag(Optional($0.id))}}
      HStack {ForEach(["dst","svg","json"],id:\.self) {format in Toggle(format.uppercased(),isOn:Binding(get:{outputs.contains(format)},set:{if $0 {outputs.insert(format)} else {outputs.remove(format)}})).toggleStyle(.checkbox)}}
      Divider();Text("EXPLICIT ESTIMATE ASSUMPTIONS").font(.system(size:9,weight:.semibold)).tracking(1)
      HStack {field("Upper-thread multiplier",$factor);field("Extra m / color / item",$allowance)}
      Text("Blank fields stay unknown. Both consumption assumptions are needed. Needle-path length includes underlay/locks and excludes travel; it is not machine thread consumption.").font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      HStack {field("Blank / component unit cost",$baseCost);field("Currency",$baseCurrency)}
      HStack {field("Labor minutes / item",$minutes);field("Hourly rate",$hourlyRate);field("Currency",$laborCurrency)}
      HStack {Text("ADDITIONAL BOM").font(.system(size:9,weight:.semibold)).tracking(1);Spacer();Button("Add material") {extras.append(.init())}}
      ForEach($extras) {$extra in VStack(spacing:5) {
        HStack {TextField("Material",text:$extra.name);Button {extras.removeAll {$0.id==extra.id}} label:{Image(systemName:"minus.circle")}}
        HStack {TextField("Qty / item",text:$extra.quantity);TextField("Unit",text:$extra.unit);TextField("Unit cost",text:$extra.price);TextField("Currency",text:$extra.currency)}
        HStack {TextField("Supplier",text:$extra.supplier);TextField("SKU",text:$extra.sku)}
      }.textFieldStyle(.roundedBorder).padding(9).background(.white,in:RoundedRectangle(cornerRadius:6))}
      TextField("Assumption notes / excluded materials",text:$assumptionNotes,axis:.vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
      Button("Capture revision") {create()}.buttonStyle(.borderedProminent).disabled(object==nil || outputs.isEmpty)
    }.font(.system(size:11))
  }
  private func field(_ title:String,_ value:Binding<String>)->some View {VStack(alignment:.leading,spacing:4) {Text(title).font(.system(size:10)).foregroundStyle(Palette.secondary);TextField("Unknown",text:value).textFieldStyle(.roundedBorder)}}
  private func history(_ job:ProductionJob,_ revision:ProductionJobRevision)->some View {
    let estimate=ProductionCostEstimate.estimate(revision)
    return VStack(alignment:.leading,spacing:13) {
      HStack {VStack(alignment:.leading,spacing:3) {Text(job.name).font(.system(size: 20, weight: .semibold));Text("\(job.quantity) items · \(revision.object.name)").font(.system(size:11)).foregroundStyle(Palette.secondary)};Spacer();Button("Export packet…") {export(job)}}
      Text("Source "+job.sourceDigest).font(.system(size:9,design:.monospaced)).textSelection(.enabled)
      Text("Revision "+job.revisionDigest).font(.system(size:9,design:.monospaced)).textSelection(.enabled)
      HStack {Text("Current source: "+currentSource).foregroundStyle(Palette.secondary);Spacer();Button("Compare current") {compare(job)}}.font(.system(size:10))
      Text("Equipment: \(revision.equipment?.name ?? "Unknown") · \(revision.compatibility.status.displayName)").font(.system(size:11))
      Text(revision.compatibility.messages.joined(separator:" ")).font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      Text("THREAD SCHEDULE").font(.system(size:9,weight:.semibold)).tracking(1)
      ForEach(estimate.threads,id:\.threadIndex) {line in
        let thread=revision.object.textile!.embroidery!.threads[line.threadIndex]
        HStack {Circle().fill(Color(nsColor:NSColor(hex:thread.color))).frame(width:12,height:12);VStack(alignment:.leading,spacing:3) {Text("\(line.threadIndex+1) · \(thread.name)");Text("Needle path \(String(format:"%.4g",line.measuredNeedleMeters)) m / job · planned use \(line.estimatedMeters.map {String(format:"%.4g m",$0)} ?? "Unknown")").font(.system(size:10)).foregroundStyle(Palette.secondary)};Spacer();Text(line.estimatedCost.flatMap {cost in line.currency.map {$0+" "+String(format:"%.4g",cost)}} ?? "Cost unknown").font(.system(size:10))}
      }
      Text(estimate.total.flatMap {total in estimate.currency.map {"Complete estimated total: "+$0+" "+String(format:"%.5g",total)}} ?? "Complete cost remains unknown.").font(.system(size:11,weight:.medium))
      ForEach(estimate.unknowns,id:\.self) {Text($0).font(.system(size:10)).foregroundStyle(Palette.secondary)}
      ForEach(estimate.inventoryNotes,id:\.self) {Text($0).font(.system(size:10)).foregroundStyle(Palette.secondary)}
      Divider();Text("USER-RECORDED SAMPLE / QUALITY HISTORY").font(.system(size:9,weight:.semibold)).tracking(1)
      ForEach(job.records) {record in VStack(alignment:.leading,spacing:4) {Text("\(record.kind.rawValue.capitalized) · \(record.date.formatted(date:.abbreviated,time:.shortened)) · \(record.recordedBy ?? "Author unspecified")").font(.system(size:10,weight:.medium));Text(record.notes).font(.system(size:11));if let outcome=record.outcome {Text("User result: "+outcome.rawValue).font(.system(size:10)).foregroundStyle(Palette.secondary)};if let status=record.status {Text("User status: "+status.rawValue).font(.system(size:10)).foregroundStyle(Palette.secondary)}}.frame(maxWidth:.infinity,alignment:.leading).padding(9).background(.white,in:RoundedRectangle(cornerRadius:6))}
      Picker("Record",selection:$recordKind) {ForEach(ProductionRecord.Kind.allCases,id:\.self) {Text($0.rawValue.capitalized).tag($0)}}
      if recordKind == .status {Picker("User-declared status",selection:$recordStatus) {ForEach(ProductionRecord.Status.allCases,id:\.self) {Text($0.rawValue.capitalized).tag($0)}}}
      if recordKind == .sample || recordKind == .quality {Picker("User-reported result",selection:$recordOutcome) {Text("No result stated").tag(ProductionRecord.Outcome?.none);ForEach(ProductionRecord.Outcome.allCases,id:\.self) {Text($0.rawValue).tag(Optional($0))}};TextField("User-reported meters · unknown if blank",text:$reportedMeters).textFieldStyle(.roundedBorder)}
      TextField("Recorded by · optional",text:$recordAuthor).textFieldStyle(.roundedBorder)
      TextField("Notes / sample observations",text:$recordNotes,axis:.vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
      Button("Record against this revision") {record(job)}.disabled(recordNotes.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
    }
  }
  private func create() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {
      guard let objectID,let count=Int(quantity.trimmingCharacters(in:.whitespacesAndNewlines)) else {throw FormError.invalid("Choose a decoration and an integer quantity.")}
      var assumptions=ProductionAssumptions();assumptions.upperThreadFactor=try ProductionNumberInput.number(factor,"thread multiplier");assumptions.allowanceMetersPerThreadPerItem=try ProductionNumberInput.number(allowance,"thread allowance")
      assumptions.baseUnitCost=try ProductionNumberInput.number(baseCost,"component cost");assumptions.baseCurrency=ProductionNumberInput.text(baseCurrency)?.uppercased()
      assumptions.laborMinutesPerItem=try ProductionNumberInput.number(minutes,"labor minutes");assumptions.hourlyLaborRate=try ProductionNumberInput.number(hourlyRate,"hourly rate");assumptions.laborCurrency=ProductionNumberInput.text(laborCurrency)?.uppercased();assumptions.notes=ProductionNumberInput.text(assumptionNotes)
      assumptions.extraBOM=try extras.map {draft in guard let quantity=try ProductionNumberInput.number(draft.quantity,"BOM quantity") else {throw FormError.invalid("State each extra BOM quantity, or remove its row.")};var item=ProductionBOMItem(name:draft.name,quantityPerItem:quantity,unit:draft.unit);item.id=draft.id;item.unitCost=try ProductionNumberInput.number(draft.price,"BOM unit cost");item.currency=ProductionNumberInput.text(draft.currency)?.uppercased();item.supplier=ProductionNumberInput.text(draft.supplier);item.sku=ProductionNumberInput.text(draft.sku);return item}
      var args:[String:Any]=["command":"create","object_id":objectID.uuidString,"name":name,"quantity":count,"outputs":outputs.sorted(),"assumptions":try jsonObject(assumptions)]
      if let equipmentID {args["equipment_id"]=equipmentID.uuidString};if let supersedesID {args["supersedes_job_id"]=supersedesID.uuidString}
      let result=try store.productionCall("form_production_job",arguments:args,source:"Studio") as! [String:Any]
      let job=try JSONDecoder.form.decode(ProductionJob.self,from:JSONSerialization.data(withJSONObject:result["job"]!));load(job);store.toast("Production revision captured")
    } catch {self.error=error.localizedDescription}
  }
  private func load(_ job:ProductionJob) {do {captured=try store.productionRevision(job:job);selectedJobID=job.id;currentSource="Not compared";error=""} catch {self.error=error.localizedDescription}}
  private func compare(_ job:ProductionJob) {
    do {let value=try store.productionCall("form_production_job",arguments:["command":"get","job_id":job.id.uuidString]) as! [String:Any];currentSource=value["current_source"] as? String ?? "Unknown";error=""} catch {self.error=error.localizedDescription}
  }
  private func record(_ job:ProductionJob) {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {
      var record=ProductionRecord(kind:recordKind,sourceDigest:job.sourceDigest,notes:recordNotes);record.recordedBy=ProductionNumberInput.text(recordAuthor)
      if recordKind == .status {record.status=recordStatus}
      if recordKind == .sample || recordKind == .quality {record.outcome=recordOutcome;record.reportedMeters=try ProductionNumberInput.number(reportedMeters,"reported consumption")}
      _ = try store.productionCall("form_production_job",arguments:["command":"event","job_id":job.id.uuidString,"record":try jsonObject(record)],source:"Studio");recordNotes="";reportedMeters="";error="";store.toast("Production record added")
    } catch {self.error=error.localizedDescription}
  }
  private func export(_ job:ProductionJob) {
    let panel=NSSavePanel();panel.allowedContentTypes=[.zip];panel.nameFieldStringValue=job.name.replacingOccurrences(of:"/",with:"-")+"-production.zip"
    guard panel.runModal() == .OK,let url=panel.url else {return}
    do {_ = try store.productionCall("form_production_job",arguments:["command":"export","job_id":job.id.uuidString,"format":"zip","path":url.path],source:"Studio");error="";store.toast("Production packet exported")} catch {self.error=error.localizedDescription}
  }
}

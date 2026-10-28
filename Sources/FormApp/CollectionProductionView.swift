import AppKit
import FormCore
import SwiftUI
import UniformTypeIdentifiers

struct CollectionRunDraft:Identifiable,Equatable {
  var id:UUID,objectID:UUID?,blockID:UUID?,sizeID:UUID?,quantity:String,includeAttachments:Bool
  init(_ run:CollectionRun) {id=run.id;objectID=run.objectID;blockID=run.garmentBlockID;sizeID=run.sizeID;quantity=String(run.quantity);includeAttachments=run.includeAttachments}
  func value()throws->CollectionRun {
    guard quantity.range(of:"^[1-9][0-9]{0,5}$",options:.regularExpression) != nil,let n=Int(quantity),(1...100000).contains(n) else{throw FormError.invalid("Run quantity must be a complete integer from 1 to 100,000.")}
    var r:CollectionRun
    if let objectID {r = .init(objectID:objectID,quantity:n,includeAttachments:includeAttachments)}else{guard let blockID,let sizeID else{throw FormError.invalid("Choose a managed size.")};r = .init(blockID:blockID,sizeID:sizeID,quantity:n)};r.id=id;return r
  }
}
struct CollectionRuleDraft:Equatable {
  var source:CollectionLineRule
  var quantity:String,price:String,currency:String,notes:String
  var unit:CollectionUnit
  var mayDeclare:Bool
  init(_ row:CollectionLine,rule:CollectionLineRule?) {source=rule ?? .init(rowID:row.id);quantity=source.quantity ?? "";price=source.unitPrice ?? "";currency=source.currency ?? "";notes=source.notes ?? "";unit=source.unit ?? row.unit;mayDeclare=row.quantity==nil || source.quantity != nil}
  func value()throws->CollectionLineRule {
    var r=source;r.quantity=quantity.isEmpty ? nil:quantity;r.unit=r.quantity==nil ? nil:unit;r.unitPrice=price.isEmpty ? nil:price;r.currency=currency.isEmpty ? nil:currency;r.notes=notes.isEmpty ? nil:notes;try r.validate();return r
  }
}
@MainActor final class CollectionDraft:ObservableObject {
  let projectID:UUID
  @Published var plan:CollectionProductionPlan
  @Published var name:String
  @Published var runs:[CollectionRunDraft]
  @Published var rules:[String:CollectionRuleDraft]=[:]
  @Published var report:CollectionPreflight?
  @Published var error=""
  @Published var capturedID:UUID?
  @Published var cancelled=false
  private struct Display:Equatable {
    var plan:CollectionProductionPlan,name:String,runs:[CollectionRunDraft],rules:[String:CollectionRuleDraft]
  }
  private var loadedDefinition:CollectionProductionPlan?
  private var loadedDisplay:Display?
  private var display:Display {.init(plan:plan,name:name,runs:runs,rules:rules)}
  init(project:Project,plan:CollectionProductionPlan?=nil) {
    projectID=project.id
    let value=plan ?? .init(name:"Collection production",runs:[]);self.plan=value;name=value.name;runs=value.runs.map(CollectionRunDraft.init)
  }
  func definition(_ store:StudioStore)throws->CollectionProductionPlan {
    guard store.project?.id==projectID else{throw FormError.invalid("This collection draft belongs to another project.")}
    var value=plan;value.name=name;value.runs=try runs.map{try $0.value()}
    var edited:[CollectionLineRule]=[]
    for draft in rules.values {
      let r=try draft.value()
      let meaningful:[Bool]=[r.costBasis != nil,r.costSourceRowID != nil,r.quantity != nil,r.unitPrice != nil,r.currency != nil,r.stock != nil,r.excludedReason != nil,r.notes != nil]
      if meaningful.contains(true) {edited.append(r)}
    }
    let keys=Set(rules.keys);value.rules=plan.rules.filter{!keys.contains($0.rowID)}+edited.sorted{$0.rowID<$1.rowID};try value.validate();return value
  }
  func review(_ store:StudioStore) {
    do {let value=try definition(store),input=try store.collectionPlanning(["definition":try jsonObject(value)]);report=input.report
      for row in input.report.rows where rules[row.id]==nil {rules[row.id] = .init(row,rule:value.rules.first{$0.rowID==row.id})};error=""
    }catch{self.error=error.localizedDescription}
  }
  func load(_ value:CollectionProductionPlan,_ store:StudioStore) {
    plan=value;name=value.name;runs=value.runs.map(CollectionRunDraft.init);rules=[:];report=nil
    review(store);loadedDefinition=value;loadedDisplay=display
  }
  func reconcile(_ store:StudioStore) {
    guard store.project?.id==projectID,let old=loadedDefinition,plan.id==old.id,
      let saved=store.project?.collectionProduction?.plans.first(where:{$0.id==old.id}),saved != old else{return}
    // The editor can contain newer input than its SwiftUI binding. Never replace
    // or commit that input during document Undo; retry after editing ends.
    guard !NSApp.windows.contains(where:{$0.isVisible && ($0.firstResponder as? NSTextView)?.isFieldEditor == true}),
      display==loadedDisplay else{return}
    load(saved,store)
  }
  func save(_ store:StudioStore)throws {
    let value=try definition(store)
    _ = try store.collectionNativeMutation(["kind":"collection","command":"save_plan","definition":try jsonObject(value)])
    plan=value;name=value.name;review(store);loadedDefinition=value;loadedDisplay=display
  }
  func capture(_ store:StudioStore)throws {
    let value=try definition(store)
    guard store.project?.collectionProduction?.plans.contains(where:{$0==value})==true else{throw FormError.invalid("Save the complete reviewed plan before capture.")}
    let raw=try store.collectionNativeMutation(["kind":"collection","command":"create","plan_id":value.id.uuidString])
    if let value=raw as? [String:Any],let job=value["job"] as? [String:Any],let id=job["id"] as? String {capturedID=UUID(uuidString:id)}
  }
  func orbital(_ store:StudioStore) {
    guard let p=store.project,p.id==projectID else{return}
    let roots=p.objects.filter{$0.recipeID=="bomberJacket"},spares=p.objects.filter{$0.textile?.attachment==nil && [.patch,.label].contains($0.textile?.kind ?? .garment)}
    guard roots.count==2,let patch=spares.first(where:{$0.textile?.kind == .patch}),let label=spares.first(where:{$0.textile?.kind == .label}) else{error="Open the original ORBITAL flight-bomber study to use this declared run.";return}
    plan = .init(name:"ORBITAL / Collection production",runs:[.init(objectID:roots[0].id,quantity:12),.init(objectID:roots[1].id,quantity:8),.init(objectID:patch.id,quantity:6),.init(objectID:label.id,quantity:4)])
    name=plan.name;runs=plan.runs.map(CollectionRunDraft.init);rules=[:];report=nil;review(store)
  }
  func removeRun(_ id:UUID) {runs.removeAll{$0.id==id};plan.layouts.removeAll{$0.runID==id};plan.extras.removeAll{$0.runID==id};rules=rules.filter{!$0.key.hasPrefix(id.uuidString+"/")};plan.rules.removeAll{$0.rowID.hasPrefix(id.uuidString+"/")};report=nil}
}
struct CollectionProductionView:View {
  @ObservedObject var store:StudioStore
  @Environment(\.dismiss) private var dismiss
  @StateObject var draft:CollectionDraft
  @State private var selectedPlan:UUID?
  @State private var selectedCapture:UUID?
  @State private var archive:CollectionRevision?
  @State private var currentSource="Not compared"
  @State private var currentPlan="Not compared"
  @State private var proof:Data?
  @State private var showingProof=false
  @StateObject private var document=PhysicalDocumentController()
  init(store:StudioStore,draft:CollectionDraft?=nil) {self.store=store;_draft=StateObject(wrappedValue:draft ?? CollectionDraft(project:store.project ?? Project(name:"No project")))}
  private var source:Project {store.project ?? .init(name:"No project")}
  private var stocks:[CollectionStockSnapshot] {(store.library.textileProduction?.supplies ?? []).map{.init(supply:$0)}+(store.library.textileProduction?.threads ?? []).map{.init(thread:$0)}+store.library.materials.filter{$0.fabric != nil}.map{.init(fabric:$0)}}
  var body:some View {
    HSplitView {
      VStack(alignment:.leading,spacing:10) {
        Text("COLLECTION PLANS").font(.system(size:9,weight:.semibold)).tracking(1)
        ScrollView {LazyVStack(alignment:.leading,spacing:8) {
          ForEach(source.collectionProduction?.plans ?? []) {p in Button(p.name){load(p)}.buttonStyle(.plain)}
          Divider();Text("CAPTURED PACKETS").font(.system(size:9,weight:.semibold)).tracking(1)
          ForEach(Array((source.collectionProduction?.captures ?? []).reversed())) {c in Button(c.name+" / "+String(c.sourceDigest.prefix(8))){open(c)}.buttonStyle(.plain)}
        }.frame(maxWidth:.infinity,alignment:.leading)}
        Button("New plan"){selectedCapture=nil;archive=nil;selectedPlan=nil;draft.plan = .init(name:"Collection production",runs:[]);draft.name=draft.plan.name;draft.runs=[];draft.rules=[:];draft.report=nil}
      }.font(.system(size:11)).padding(.trailing,14).frame(minWidth:180,idealWidth:210,maxWidth:260)
      VStack(alignment:.leading,spacing:10) {
        if let archive,let id=selectedCapture {
          HStack {Text(archive.plan.name).font(.system(size:20,design:.serif));Spacer();Button("Review PDF"){showingProof=true};Button("Export packet…"){export(id)}}
          HStack {Text("Current source: "+currentSource+" / plan: "+currentPlan);Spacer();Button("Compare current"){compare(archive)}}.font(.system(size:10)).foregroundStyle(Palette.secondary)
          Text("Immutable captured source / "+archive.sourceDigest).font(.system(size:9,design:.monospaced)).textSelection(.enabled)
          ScrollView {summary(archive.report)}
        } else {
          HStack {TextField("Collection plan name",text:$draft.name).font(.system(size:18,design:.serif));Spacer();Button("Use ORBITAL quantities"){draft.orbital(store)}}
          ScrollView {LazyVStack(alignment:.leading,spacing:14) {
            runs
            Text("BOM / SOURCE AND DECLARED QUANTITIES").font(.system(size:10,weight:.semibold)).tracking(1)
            HStack {Button("Review BOM"){draft.review(store)};Button("Clear row overrides"){draft.rules=[:];draft.plan.rules=[];draft.review(store)};Text("Review declared quantities and availability before capture.").font(.system(size:10)).foregroundStyle(Palette.secondary)}
            if let report=draft.report {summary(report)
              ForEach(report.rows) {row in CollectionBOMRow(row:row,draft:Binding(get:{draft.rules[row.id] ?? .init(row,rule:nil)},set:{draft.rules[row.id]=$0}),stocks:stocks,legacyRows:report.rows.filter{$0.role=="unmapped"})}
            }
            extras
            processes
            TextField("Collection notes",text:Binding(get:{draft.plan.notes ?? ""},set:{draft.plan.notes=$0}),axis:.vertical).lineLimit(2...5)
          }.padding(.trailing,8)}
          HStack {Button("Cancel"){draft.cancelled=true;dismiss()}.accessibilityIdentifier("collection-cancel");Button("Save plan"){perform{try draft.save(store)}}.accessibilityIdentifier("collection-save");Spacer();Button("Capture technical packet"){perform{try draft.capture(store);if let id=draft.capturedID,let c=source.collectionProduction?.captures.first(where:{$0.id==id}) {open(c)}}}.buttonStyle(.borderedProminent).accessibilityIdentifier("collection-capture")}
        }
        if !draft.error.isEmpty {Text(draft.error).font(.system(size:11)).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
        Text("Quantities/rates are declarations or source calculations. Unknowns remain visible. No purchasing, inventory transaction, physical verification or machine action.").font(.system(size:10)).foregroundStyle(Palette.secondary)
      }.padding(.leading,14).frame(minWidth:600)
    }.textFieldStyle(.roundedBorder)
      .onChange(of:store.revision){_,_ in reconcileRecords()}
      .onReceive(NotificationCenter.default.publisher(for:NSControl.textDidEndEditingNotification)){_ in
        DispatchQueue.main.async {reconcileRecords()}
      }
      .sheet(isPresented:$showingProof) {VStack {PhysicalDocumentNavigation(controller:document);PhysicalDocumentCanvas(controller:document,data:proof ?? Data(),identifier:PhysicalDocumentController.key(project:source.id,object:selectedCapture,kind:"collection-immutable-review"));Button("Done"){showingProof=false}}.padding(20).frame(width:900,height:760)}
  }
  private var runs:some View {
    VStack(alignment:.leading,spacing:8) {
      Text("RUN QUANTITIES").font(.system(size:10,weight:.semibold)).tracking(1)
      ForEach($draft.runs) {$r in HStack {
        Text(r.objectID.flatMap{id in source.objects.first{$0.id==id}?.name} ?? source.garmentBlocks?.first{$0.id==r.blockID}?.sizes.first{$0.id==r.sizeID}?.label ?? "Missing source").frame(maxWidth:.infinity,alignment:.leading)
        TextField("Run quantity",text:$r.quantity).frame(width:90)
        if r.objectID != nil {Toggle("Attachments",isOn:$r.includeAttachments).toggleStyle(.checkbox)}
        Button{draft.removeRun(r.id)}label:{Image(systemName:"minus.circle")}
      }}
      Menu("Add product or managed size") {
        ForEach(source.objects.filter{$0.textile != nil || $0.patternAssembly != nil || $0.cloth != nil}) {o in Button(o.name){draft.runs.append(.init(.init(objectID:o.id)));draft.report=nil}}
        ForEach(source.garmentBlocks ?? []) {block in ForEach(block.sizes) {size in Button(block.name+" / "+size.label){draft.runs.append(.init(.init(blockID:block.id,sizeID:size.id)));draft.report=nil}}}
      }
      ForEach(draft.runs.filter{r in r.blockID != nil || source.objects.first(where:{$0.id==r.objectID})?.patternAssembly != nil}) {run in
        ForEach(source.objects.filter{$0.artwork?.sewingLayout != nil}) {o in Toggle("Repeat one-unit layout: "+o.name,isOn:Binding(get:{draft.plan.layouts.contains{$0.runID==run.id && $0.objectID==o.id}},set:{on in draft.plan.layouts.removeAll{$0.runID==run.id && $0.objectID==o.id};if on {draft.plan.layouts.append(.init(runID:run.id,objectID:o.id))}})).toggleStyle(.checkbox)}
      }
    }.font(.system(size:11))
  }
  private func summary(_ r:CollectionPreflight)->some View {
    VStack(alignment:.leading,spacing:5) {
      Text("\(r.occurrences.reduce(0){$0+$1.quantity}) physical component occurrences · \(r.rows.count) rows").font(.system(size:12,weight:.medium))
      ForEach(r.knownSubtotals.keys.sorted(),id:\.self){c in Text(c+" "+r.knownSubtotals[c]!+" known priced subtotal")}
      Text(r.completeTotal.map{"Complete declared estimate: "+(r.currency ?? "")+" "+$0} ?? "Complete estimate unknown").fontWeight(.medium)
      ForEach(Array(r.unknowns.prefix(8)),id:\.self){Text($0).foregroundStyle(Palette.secondary)}
      if r.unknowns.count>8 {Text("\(r.unknowns.count-8) more unknown rows are retained in the full packet.").foregroundStyle(Palette.secondary)}
      ForEach(r.stock,id:\.key){s in Text(s.name+" / demand ≥"+s.knownDemand+" "+s.unit.rawValue+" / "+s.status)}
      ForEach(r.findings,id:\.message){f in Text(f.message).foregroundStyle(Palette.secondary)}
      Text("Calculated rates use up to 12 decimal places with half-even rounding. The full calculations are included in the packet.").foregroundStyle(Palette.secondary)
    }.font(.system(size:10)).fixedSize(horizontal:false,vertical:true)
  }
  private var extras:some View {
    VStack(alignment:.leading,spacing:8) {
      HStack {Text("DECLARED MATERIALS / LABOR / SETUP").font(.system(size:10,weight:.semibold));Spacer();Button("Add declaration"){draft.plan.extras.append(.init(name:"Additional material"))}}
      ForEach($draft.plan.extras) {$e in VStack {
        HStack {TextField("Material / operation",text:$e.name);Button{let id=e.id;draft.plan.extras.removeAll{$0.id==id};draft.rules.removeValue(forKey:"extra/"+id.uuidString);draft.plan.rules.removeAll{$0.rowID=="extra/"+id.uuidString};draft.report=nil}label:{Image(systemName:"minus.circle")}}
        HStack {TextField("Quantity · unknown if blank",text:optional($e.quantity));Picker("Unit",selection:$e.unit){ForEach(CollectionUnit.allCases,id:\.self){Text($0.rawValue).tag($0)}};TextField("Price / unit",text:optional($e.unitPrice));TextField("Currency",text:optional($e.currency))}
        Picker("Declaration scope",selection:$e.runID){Text("Once per collection").tag(UUID?.none);ForEach(draft.runs){r in Text("Per item / "+String(r.id.uuidString.prefix(8))).tag(Optional(r.id))}}
        HStack {TextField("Supplier",text:optional($e.supplier));TextField("SKU",text:optional($e.sku))}
      }.padding(9).background(.white,in:RoundedRectangle(cornerRadius:6))}
    }.font(.system(size:11))
  }
  private var processes:some View {
    VStack(alignment:.leading,spacing:6) {
      Text("EXACT ARCHIVED PROCESS REVISIONS").font(.system(size:10,weight:.semibold))
      ForEach(source.productionJobs ?? []) {j in processToggle(j.id,"embroidery",j.name+" / \(j.quantity) captured items")}
      ForEach(source.decorationPreparations ?? []) {j in processToggle(j.id,"decoration",j.name+" / \(j.quantity) captured transfers")}
      Text("Archived quantity must match its exact physical occurrences. Captured base/extra costs need one explicit BOM owner; referenced files do not add garments twice.").font(.system(size:10)).foregroundStyle(Palette.secondary)
    }
  }
  private func processToggle(_ id:UUID,_ kind:String,_ name:String)->some View {
    Toggle(name,isOn:Binding(get:{draft.plan.processes.contains{$0.jobID==id}},set:{on in
      draft.plan.processes.removeAll{$0.jobID==id}
      if !on {
        draft.rules=draft.rules.filter{!$0.key.hasPrefix("process/"+id.uuidString+"/")}
        draft.plan.rules.removeAll{$0.rowID.hasPrefix("process/"+id.uuidString+"/")}
      }
      draft.report=nil
      if on {draft.plan.processes.append(.init(jobID:id,kind:kind))}
    })).toggleStyle(.checkbox)
  }
  private func optional(_ value:Binding<String?>)->Binding<String>{Binding(get:{value.wrappedValue ?? ""},set:{value.wrappedValue=$0.isEmpty ? nil:$0})}
  private func perform(_ action:()throws->Void){do{try action();draft.error=""}catch{draft.error=error.localizedDescription}}
  private func load(_ p:CollectionProductionPlan) {selectedPlan=p.id;selectedCapture=nil;archive=nil;draft.load(p,store)}
  private func reconcileRecords() {
    draft.reconcile(store)
    if let id=selectedCapture,source.collectionProduction?.captures.contains(where:{$0.id==id}) != true {
      selectedCapture=nil;archive=nil;proof=nil;showingProof=false
    }
  }
  private func open(_ c:CollectionCapture) {perform{let value=try store.collectionArchive(c);archive=value.revision;selectedCapture=c.id;proof=value.files["Review.pdf"];compare(value.revision)}}
  private func compare(_ revision:CollectionRevision) {guard let id=selectedCapture,let job=source.collectionProduction?.captures.first(where:{$0.id==id}) else{return};let value=store.collectionCurrentState(revision,sourceDigest:job.sourceDigest);currentSource=value.source;currentPlan=value.plan}
  private func export(_ id:UUID) {perform{guard let c=source.collectionProduction?.captures.first(where:{$0.id==id}) else{throw FormError.missing("Capture unavailable.")};let panel=NSSavePanel();panel.allowedContentTypes=[.zip];panel.nameFieldStringValue="Collection-"+String(id.uuidString.prefix(8))+".zip";guard panel.runModal() == .OK,let url=panel.url else{return};_ = try store.collectionCall(["kind":"collection","command":"export","job_id":c.id.uuidString,"path":url.path])}}
}
private struct CollectionBOMRow:View {
  let row:CollectionLine
  @Binding var draft:CollectionRuleDraft
  let stocks:[CollectionStockSnapshot],legacyRows:[CollectionLine]
  var body:some View {
    VStack(alignment:.leading,spacing:6) {
      Text(row.name).font(.system(size:12,weight:.medium));Text((row.quantity ?? "Unknown")+" "+row.unit.rawValue+" / "+row.evidence.rawValue).foregroundStyle(Palette.secondary)
      Text(row.formula).foregroundStyle(Palette.secondary)
      let descriptive=row.role=="specification" && !row.requiredCost
      let componentInactive=row.role=="component" && (draft.source.costBasis ?? row.costBasis ?? .unresolved) != .purchased
      if draft.mayDeclare && !descriptive {HStack {TextField("Declared total quantity",text:$draft.quantity);Picker("Unit",selection:$draft.unit){ForEach(CollectionUnit.allCases,id:\.self){Text($0.rawValue).tag($0)}}}}
      if row.role=="component" {Picker("Cost basis",selection:Binding(get:{draft.source.costBasis ?? row.costBasis ?? .unresolved},set:{draft.source.costBasis=$0})){ForEach(CollectionCostBasis.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}}}
      if !["geometry","finishedProduct","unmapped"].contains(row.role) && !descriptive && !componentInactive {
        HStack {TextField("Declared price / unit",text:$draft.price);TextField("Currency",text:$draft.currency).frame(width:85)}
        Picker("Portable stock",selection:Binding(get:{draft.source.stock?.key ?? ""},set:{key in draft.source.stock=stocks.first{$0.key==key}})){Text("Unassigned / unknown").tag("");if let old=draft.source.stock,!stocks.contains(where:{$0.key==old.key}) {Text(old.name+" / captured").tag(old.key)};ForEach(stocks.filter{$0.unit==draft.unit},id:\.key){s in Text(s.name).tag(s.key)}}
        if let assigned=draft.source.stock {Button("Refresh assigned stock snapshot"){draft.source.stock=stocks.first{$0.key==assigned.key}}}
        Picker("Captured component cost",selection:Binding(get:{draft.source.costSourceRowID ?? ""},set:{draft.source.costSourceRowID=$0.isEmpty ? nil:$0})){Text("Use own declared/source rate").tag("");ForEach(legacyRows.filter{$0.quantity==row.quantity && $0.unit==row.unit}){e in Text(e.name).tag(e.id)}}
      }
      if descriptive {Text("Covered by the complete component; raw material consumption remains descriptive/unknown.").foregroundStyle(Palette.secondary)}
      if componentInactive {Text("Choose Purchased to price the whole component, or Made to cost its raw materials/processes separately.").foregroundStyle(Palette.secondary)}
      if let c=row.calculation {Text("\(c.numerator)/\(c.denominator) = \(c.result) · half-even12 · rounding \(c.rounded ? "occurred":"not needed")").foregroundStyle(Palette.secondary)}
      if let reason=row.excludedReason {Text(reason).foregroundStyle(Palette.secondary)}
      TextField("Exclude from cost/stock · reason",text:Binding(get:{draft.source.excludedReason ?? ""},set:{draft.source.excludedReason=$0.isEmpty ? nil:$0}))
      TextField("Row notes",text:$draft.notes)
    }.font(.system(size:10)).padding(12).background(.white,in:RoundedRectangle(cornerRadius:8))
  }
}

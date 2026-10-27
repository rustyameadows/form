import AppKit
import FormCore
import SwiftUI
import UniformTypeIdentifiers

struct DecorationArchiveBrowser:View {
  @ObservedObject var store:StudioStore
  var objectID:UUID?
  @State private var selectedID:UUID?
  @State private var revision:DecorationPreparationRevision?
  @State private var proof:Data?
  @State private var comparison="Not compared"
  @State private var error=""
  @StateObject private var review=PhysicalDocumentController()
  init(store:StudioStore,objectID:UUID?=nil,initialSelection:UUID?=nil) {self.store=store;self.objectID=objectID;_selectedID=State(initialValue:initialSelection)}
  private var jobs:[DecorationPreparation] {Array((store.project?.decorationPreparations ?? []).filter{objectID==nil || $0.objectID==objectID}.reversed())}
  private var selected:DecorationPreparation? {jobs.first{$0.id==selectedID}}
  var body:some View {
    HSplitView {
      ScrollView {LazyVStack(alignment:.leading,spacing:8) {
        Text("CAPTURED PREPARATIONS").font(.system(size:9,weight:.semibold)).tracking(1).foregroundStyle(Palette.secondary)
        ForEach(jobs) {job in
          Button{load(job)} label:{VStack(alignment:.leading,spacing:4) {
            Text(job.name).font(.system(size:12,weight:.medium))
            Text("\(job.process.rawValue.uppercased()) · \(job.quantity) items · \(job.createdAt.formatted(date:.abbreviated,time:.shortened))").font(.system(size:10)).foregroundStyle(Palette.secondary)
            Text(String(format:"%.1f × %.1f mm",job.width,job.height)).font(.system(size:10,design:.monospaced)).foregroundStyle(Palette.secondary)
          }.frame(maxWidth:.infinity,alignment:.leading).padding(11).background(job.id==selectedID ? Color.white:Color.clear,in:RoundedRectangle(cornerRadius:7))}.buttonStyle(.plain)
        }
        if jobs.isEmpty {Text("Capture a preparation from a physical artwork frame or decoration. Its exact delivery, reference and source files remain available after live source changes or deletion.").font(.system(size:11)).foregroundStyle(Palette.secondary).padding(.vertical,14)}
      }.padding(.trailing,14)}.frame(minWidth:225,idealWidth:250,maxWidth:290)
      VStack(alignment:.leading,spacing:10) {
        if let job=selected,let revision,let proof {
          HStack {VStack(alignment:.leading,spacing:4) {Text(job.name).font(.system(size: 20, weight: .semibold));Text("Captured \(job.quantity) items · \(job.process.rawValue.uppercased()) · source unchanged by export").font(.system(size:11)).foregroundStyle(Palette.secondary)};Spacer();Button("Export packet…"){export(job)}}
          PhysicalDocumentNavigation(controller:review)
          PhysicalDocumentCanvas(controller:review,data:proof,identifier:PhysicalDocumentController.key(project:store.project?.id,object:job.id,kind:"decoration-archive-review"))
            .frame(maxWidth:.infinity,maxHeight:.infinity).clipShape(RoundedRectangle(cornerRadius:7))
          HStack {Text(comparison).font(.system(size:10)).foregroundStyle(Palette.secondary);Spacer();Button("Compare current records"){compare(job)}.font(.system(size:10))}
          DisclosureGroup("Captured settings and files") {
            ScrollView {VStack(alignment:.leading,spacing:6) {
              Text("Mirror \(revision.options.mirror ? "on":"off") · background \(revision.options.includeBackground ? "included":"excluded") · \(revision.options.whitePolicy == .printOpaqueWhite ? "opaque white prints":"opaque white shows through")").font(.system(size:10))
              if let notes=revision.notes,!notes.isEmpty {Text(notes).font(.system(size:10))}
              ForEach(revision.files,id:\.name) {file in HStack {Text(file.name).font(.system(size:10,design:.monospaced));Spacer();Text(file.role.capitalized+" · "+ByteCountFormatter.string(fromByteCount:Int64(file.bytes),countStyle:.file)).font(.system(size:9)).foregroundStyle(Palette.secondary)}}
              Text("Source "+job.sourceDigest).font(.system(size:9,design:.monospaced)).textSelection(.enabled)
            }}.frame(maxHeight:150)
          }.font(.system(size:11))
        }else {ContentUnavailableView("No preparation selected",systemImage:"shippingbox",description:Text(error.isEmpty ? "Choose a captured revision to review its immutable files.":error)).frame(maxWidth:.infinity,maxHeight:.infinity)}
        if !error.isEmpty {Text(error).font(.system(size:10)).foregroundStyle(Palette.ink).fixedSize(horizontal:false,vertical:true)}
        Text("Delivery files are distinct from reference/source files. Vendor/RIP white handling and physical material/application compatibility remain explicit, unverified decisions.").font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      }.padding(.leading,16).frame(minWidth:500)
    }
    .onAppear{if let job=selected ?? jobs.first {load(job)}}
    .onChange(of:store.project?.id){_,_ in selectedID=nil;revision=nil;proof=nil}
    .onChange(of:jobs.map(\.id)){_,ids in if let selectedID,!ids.contains(selectedID) {self.selectedID=nil;revision=nil;proof=nil}}
  }
  private func load(_ job:DecorationPreparation) {
    do {
      guard let project=store.project else{return}
      let value=try store.decorationRevision(job)
      guard let file=value.files.first(where:{$0.name=="Review.pdf"}) else{throw FormError.invalid("The captured review PDF is missing.")}
      let data=try DecorationPacketAssets.read(file.digest,repository:store.repository,projectID:project.id,expectedBytes:file.bytes)
      selectedID=job.id;revision=value;proof=data;error="";compare(job)
    }catch{self.error=error.localizedDescription;revision=nil;proof=nil}
  }
  private func compare(_ job:DecorationPreparation) {
    do {
      let value=try store.decorationCall(["kind":"decoration","command":"get","job_id":job.id.uuidString]) as! [String:Any]
      switch value["current_source"] as? String {
      case "matches":comparison="Original editable records match"
      case "changed":comparison="Live records changed; this archive stays unchanged"
      case "missing":comparison="Live object deleted; archived source/files remain available"
      default:comparison="Live records unavailable; review uses archived files"
      }
    }catch{self.error=error.localizedDescription}
  }
  private func export(_ job:DecorationPreparation) {
    let panel=NSSavePanel();panel.allowedContentTypes=[.zip];panel.nameFieldStringValue=job.process.rawValue.uppercased()+"-"+job.name.replacingOccurrences(of:"/",with:"-")+".zip"
    guard panel.runModal() == .OK,let url=panel.url else{return}
    do {_ = try store.decorationCall(["kind":"decoration","command":"export","job_id":job.id.uuidString,"format":"zip","path":url.path]);error="";store.toast("Decoration packet exported")}
    catch{self.error=error.localizedDescription}
  }
}

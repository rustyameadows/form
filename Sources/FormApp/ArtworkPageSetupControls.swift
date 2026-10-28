import AppKit
import FormCore
import SwiftUI
import UniformTypeIdentifiers

struct ArtworkPageSetupControls:View {
  @ObservedObject var store:StudioStore
  @StateObject private var draft:ArtworkPageSetupDraft
  @FocusState private var focus:String?
  @State private var review=false
  init(store:StudioStore,objectID:UUID,draft:ArtworkPageSetupDraft?=nil){self.store=store;_draft=StateObject(wrappedValue:draft ?? ArtworkPageSetupDraft(store:store,objectID:objectID))}
  var body:some View {
    VStack(alignment:.leading,spacing:8) {
      SectionLabel("PAGE SETUP")
      field("Bleed",$draft.bleed,key:"bleed",prompt:"Outward extension")
      field("Safe inset",$draft.safe,key:"safe",prompt:"None if blank")
      Text("Bleed extends beyond trim. Safe inset is an inward rectangular guide; it is not printed.").font(.system(size:9)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      HStack {Button("Apply page setup"){draft.apply()}.accessibilityIdentifier("apply-page-setup");Button("Review physical page…"){review=true}}
        .font(.system(size:10))
      if !draft.error.isEmpty {Text(draft.error).font(.system(size:10)).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
    }.onChange(of:focus){_,value in draft.focused=Set([value].compactMap{$0});draft.synchronize()}
      .onChange(of:store.revision){_,_ in draft.synchronize()}
      .sheet(isPresented:$review){ArtworkPageReview(store:store,objectID:draft.objectID)}
  }
  private func field(_ label:String,_ text:Binding<String>,key:String,prompt:String)->some View {
    HStack {Text(label).font(.system(size:10)).foregroundStyle(Palette.secondary);Spacer();TextField(prompt,text:text).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width:110).focused($focus,equals:key).accessibilityLabel(label+" page setup");Text(draft.unit.rawValue).font(.system(size:9)).foregroundStyle(Palette.secondary)}
  }
}
struct ArtworkPageReview:View {
  @ObservedObject var store:StudioStore
  @Environment(\.dismiss) private var dismiss
  @StateObject private var model:ArtworkPageReviewModel
  @StateObject private var review=PhysicalDocumentController()
  init(store:StudioStore,objectID:UUID,model:ArtworkPageReviewModel?=nil){self.store=store;_model=StateObject(wrappedValue:model ?? ArtworkPageReviewModel(store:store,objectID:objectID))}
  var body:some View {
    VStack(alignment:.leading,spacing:14) {
      HStack {Text("Physical page").font(.system(size:25,design:.serif));Spacer();Button("Done"){dismiss()}.keyboardShortcut(.cancelAction)}
      HStack {
        Picker("Output area",selection:$model.area){Text("Trim only").tag(ArtworkPageArea.trim);Text("Include bleed").tag(ArtworkPageArea.bleed)}.frame(width:240)
        Toggle("Crop marks",isOn:$model.cropMarks).toggleStyle(.checkbox)
        Text("Gap mm");TextField("Mark gap",text:$model.gap).textFieldStyle(.roundedBorder).frame(width:65)
        Text("Length mm");TextField("Mark length",text:$model.length).textFieldStyle(.roundedBorder).frame(width:65)
        Button("Refresh review"){model.refresh()}
      }.font(.system(size:10))
      HStack {Toggle("Reference guides",isOn:$model.referenceGuides).toggleStyle(.checkbox);Text("Blue · trim   Red · bleed   Green · safe inset").foregroundStyle(Palette.secondary);Spacer();Toggle("Explicit sRGB ink preview",isOn:$model.previewInks).toggleStyle(.checkbox)}.font(.system(size:10))
      if let data=model.proof {
        PhysicalDocumentNavigation(controller:review)
        PhysicalDocumentCanvas(controller:review,data:data,identifier:model.identity).frame(maxWidth:.infinity,maxHeight:.infinity).clipShape(RoundedRectangle(cornerRadius:6))
      }else{ContentUnavailableView("Page review unavailable",systemImage:"doc.viewfinder",description:Text(model.error.isEmpty ? "Review the page setup and output choices.":model.error)).frame(maxWidth:.infinity,maxHeight:.infinity)}
      if model.proof != nil && !model.matchesReview {Text("Options changed. Refresh review before exporting.").font(.system(size:10)).foregroundStyle(Palette.accent)}
      if !model.warnings.isEmpty {
        Text("Output notices (\(model.warnings.count))").font(.system(size:10,weight:.medium))
        ScrollView {VStack(alignment:.leading,spacing:4) {
          ForEach(Array(model.warnings.prefix(64)),id:\.self){Text($0).font(.system(size:10)).foregroundStyle(Palette.secondary).frame(maxWidth:.infinity,alignment:.leading)}
          if model.warnings.count>64 {Text("Showing the first 64 output notices.").font(.system(size:10)).foregroundStyle(Palette.secondary)}
        }}.frame(maxHeight:76)
      }
      if let g=model.geometry {Text(String(format:"Trim %.3f × %.3f mm · Sheet %.3f × %.3f mm · Included bleed %.3f mm · %d crop segments",g.trimMm.width,g.trimMm.height,g.mediaMm.width,g.mediaMm.height,g.includedBleedMm,g.marks.count)).font(.system(size:10,design:.monospaced))}
      Text("Review uses applied source/setup; pending editor drafts are not committed. Reference guides use sRGB overlays. Export uses the assigned ICC profile unless explicit ink preview is selected, and prepares a separate production PDF with no guides, scaling or registration marks.").font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      HStack {if !model.error.isEmpty {Text(model.error).foregroundStyle(.red).font(.system(size:10))};Spacer();Button("Export production PDF…"){export()} .disabled(!model.matchesReview)}
    }.padding(24).frame(width:1120,height:820).background(Palette.paper)
      .onAppear{model.refresh()}.onChange(of:store.revision){_,_ in model.refresh()}
      .onChange(of:model.area){_,_ in model.refresh()}.onChange(of:model.cropMarks){_,_ in model.refresh()}.onChange(of:model.previewInks){_,_ in model.refresh()}.onChange(of:model.referenceGuides){_,_ in model.refresh()}
      .onChange(of:store.project?.id){_,id in if id != model.projectID {dismiss()}}
  }
  private func export() {
    let panel=NSSavePanel();panel.allowedContentTypes=[.pdf];panel.nameFieldStringValue=(store.project?.objects.first{$0.id==model.objectID}?.name ?? "Artwork")+"-page.pdf"
    guard panel.runModal() == .OK,let url=panel.url else{return}
    if model.export(path:url){store.toast("Physical page PDF exported")}
  }
}

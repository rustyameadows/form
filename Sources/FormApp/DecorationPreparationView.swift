import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct DecorationPreparationAction:View {
  @ObservedObject var store:StudioStore
  let objectID:UUID
  @State private var open=false
  var body:some View {
    Button("Prepare HTV / DTF…",systemImage:"tshirt") {
      guard store.artworkSession.canvas?.hasMarkedTextInput != true else{store.error="Finish the current text input before opening decoration preparation.";return}
      store.artworkSession.canvas?.finishText();open=true
    }.sheet(isPresented:$open) {DecorationPreparationView(store:store,objectID:objectID)}
  }
}
struct DecorationCaptureButton:View {
  @ObservedObject var draft:DecorationPreparationDraft
  var onCapture:()->Void
  var body:some View {Button("Capture immutable preparation") {if draft.capture(){onCapture()}}.buttonStyle(.borderedProminent)}
}
struct DecorationPreparationView:View {
  @ObservedObject var store:StudioStore
  @Environment(\.dismiss) private var dismiss
  @StateObject private var draft:DecorationPreparationDraft
  @State private var mode=DecorationPreviewMode.delivery
  @State private var layer:String?
  @State private var saved=false
  @State private var profiles:[InstalledOutputProfile]=[]
  init(store:StudioStore,objectID:UUID,draft:DecorationPreparationDraft?=nil) {self.store=store;_draft=StateObject(wrappedValue:draft ?? DecorationPreparationDraft(store:store,objectID:objectID))}
  var body:some View {
    VStack(alignment:.leading,spacing:14) {
      HStack {
        VStack(alignment:.leading,spacing:4) {Text("Decoration preparation").font(.system(size: 25, weight: .semibold));Text(store.project?.objects.first{$0.id==draft.objectID}?.name ?? "Source unavailable").font(.system(size:11)).foregroundStyle(Palette.secondary)}
        Spacer();Picker("View",selection:$saved) {Text("Prepare").tag(false);Text("Saved preparations").tag(true)}.pickerStyle(.segmented).labelsHidden().frame(width:290)
        AppCloseButton("Close", keyEquivalent: "\u{1b}"){dismiss()}.keyboardShortcut(.cancelAction)
      }.fixedSize(horizontal:false,vertical:true).layoutPriority(1)
      if saved {DecorationArchiveBrowser(store:store,objectID:draft.objectID,initialSelection:draft.capturedID)}
      else {
        HSplitView {preview.frame(minWidth:560);ScrollView {controls.padding(.leading,16)}.frame(minWidth:325,idealWidth:355,maxWidth:395)}.frame(maxHeight:.infinity).clipped()
        VStack(alignment:.leading,spacing:7) {
          if !draft.error.isEmpty {Text(draft.error).font(.system(size:10)).foregroundStyle(Palette.ink).fixedSize(horizontal:false,vertical:true)}
          HStack {Text("Capture records current source and exact files as one undoable revision.").font(.system(size:10)).foregroundStyle(Palette.secondary);Spacer();DecorationCaptureButton(draft:draft){saved=true}}
        }.fixedSize(horizontal:false,vertical:true).layoutPriority(1)
      }
    }.padding(24).frame(width:1080,height:760).background(Palette.paper)
      .onAppear{profiles=ICCOutputProfile.installed().filter{$0.model=="CMYK"}}
      .onChange(of:store.project?.id){_,id in if id != draft.projectID {dismiss()}}
  }
  private var preview:some View {
    VStack(alignment:.leading,spacing:10) {
      Picker("Preview orientation",selection:$mode) {
        Text("Application").tag(DecorationPreviewMode.application);Text("Delivery").tag(DecorationPreviewMode.delivery)
        if draft.process == .dtf {Text("Underbase reference").tag(DecorationPreviewMode.underbase)}
      }.pickerStyle(.segmented).labelsHidden()
      if let plan=draft.plan {
        DecorationPreparationPreview(plan:plan,mirror:draft.mirror,mode:mode,layer:layer).frame(minHeight:180,maxHeight:.infinity).clipShape(RoundedRectangle(cornerRadius:8))
        HStack {
          Text(String(format:"%.1f × %.1f mm",plan.width,plan.height)).font(.system(size:11,design:.monospaced))
          Spacer();Text(mode == .application ? "Application-facing":draft.mirror ? "Mirrored delivery":"Unmirrored delivery").font(.system(size:11)).foregroundStyle(Palette.secondary)
        }
        if draft.process == .htv {
          Picker("Material region",selection:$layer) {
            Text("All material regions").tag(String?.none)
            ForEach(plan.regions,id:\.paintKey) {region in Text(draft.materials[region.paintKey].flatMap{$0.isEmpty ? nil:$0} ?? region.name).tag(Optional(region.paintKey))}
          }
        }
        if let target=plan.source.target {
          Text(target.garment.name+" · "+target.zoneName).font(.system(size:11,weight:.medium))
          Text(target.surface == .cylindricalBand ? "Curved concept zone; flat file uses its recorded arc-length dimensions. Application compensation is unverified.":target.surface == .unverified ? "Host envelope is unverified; the flat artwork dimensions are explicit.":"Placement uses the current bounded garment zone and rotation.").font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
        }
      }else {ContentUnavailableView("Preview unavailable",systemImage:"tshirt",description:Text(draft.error.isEmpty ? "Review the preparation inputs.":draft.error)).frame(maxWidth:.infinity,maxHeight:.infinity)}
      if mode == .underbase {Text("Reference silhouette for vendor/RIP review. This file is not a generated white channel, choke or screening instruction.").font(.system(size:10)).foregroundStyle(Palette.secondary)}
    }.padding(.trailing,16)
  }
  private var controls:some View {
    VStack(alignment:.leading,spacing:13) {
      Picker("Process",selection:Binding(get:{draft.process},set:{draft.chooseProcess($0);layer=nil;if $0 == .htv && mode == .underbase {mode = .delivery}})) {
        Text("HTV cut material").tag(DecorationProcess.htv);Text("DTF handoff").tag(DecorationProcess.dtf)
      }
      Toggle("Mirror delivery",isOn:$draft.mirror).toggleStyle(.checkbox)
      Text(draft.process == .htv ? "Conventional carrier-side HTV cuts mirrored. Confirm your selected material's orientation.":"Keep vendor handoff orientation explicit; a provider may mirror in its RIP.").font(.system(size:10)).foregroundStyle(Palette.secondary)
      Toggle("Include source frame background",isOn:$draft.includeBackground).toggleStyle(.checkbox).onChange(of:draft.includeBackground){_,_ in draft.refresh()}
      if draft.process == .htv {field("Weed padding (mm)",$draft.weedMargin);Text("Zero omits the weed frame. Padding expands each physical cut page without scaling the artwork.").font(.system(size:10)).foregroundStyle(Palette.secondary)}
      else {
        field("Requested DPI",$draft.dpi)
        Picker("Opaque white artwork",selection:$draft.whitePolicy) {Text("Print white").tag(DecorationWhitePolicy.printOpaqueWhite);Text("Garment show-through").tag(DecorationWhitePolicy.showThrough)}.onChange(of:draft.whitePolicy){_,_ in draft.refresh()}
        Picker("Color delivery",selection:$draft.colorDelivery) {Text("sRGB RGBA PNG").tag(DecorationColorDelivery.sRGBRaster);Text("Profiled process-CMYK PDF").tag(DecorationColorDelivery.profiledProcess)}.onChange(of:draft.colorDelivery){_,_ in draft.refresh()}
        Toggle("Convert named spots to process alternates",isOn:$draft.convertSpotAlternates).toggleStyle(.checkbox).onChange(of:draft.convertSpotAlternates){_,_ in draft.refresh()}
        Toggle("Include underbase references",isOn:$draft.underbaseReference).toggleStyle(.checkbox)
        Menu {
          ForEach(profiles) {profile in Button(profile.name){draft.assignProfile(profile.path)}}
          Divider();Button("Choose ICC file…"){draft.chooseProfileFile()}
        } label:{Text(draft.plan?.source.artwork.outputColorProfile.map{"Profile · "+$0.name} ?? "Choose CMYK profile…")}
        Text("RGBA is an appearance handoff for a vendor/RIP. Original ink declarations stay in the source archive; process conversion is explicit.").font(.system(size:10)).foregroundStyle(Palette.secondary)
      }
      Button("Refresh preview"){draft.refresh()}
      if let plan=draft.plan,draft.process == .htv {
        Divider();Text("MATERIAL DECLARATIONS").font(.system(size:9,weight:.semibold)).tracking(1)
        ForEach(plan.regions,id:\.paintKey) {region in
          VStack(alignment:.leading,spacing:4) {
            Text(region.name).font(.system(size:10)).foregroundStyle(Palette.secondary)
            TextField("Material / supplier / SKU · unknown if blank",text:Binding(get:{draft.materials[region.paintKey] ?? ""},set:{draft.materials[region.paintKey]=$0})).textFieldStyle(.roundedBorder)
          }
        }
        Text("Paint previews do not identify a matching vinyl. Cut regions use visible knockout geometry; no overlap or tacking recipe is inferred.").font(.system(size:10)).foregroundStyle(Palette.secondary)
      }
      if let plan=draft.plan {ForEach(Array(plan.issues.enumerated()),id:\.offset) {_,issue in Text(issue.message).font(.system(size:10)).foregroundStyle(issue.severity=="error" ? Palette.ink:Palette.secondary).fixedSize(horizontal:false,vertical:true)}}
      Divider();field("Preparation name",$draft.name);field("Quantity",$draft.quantity)
      TextField("Material / film declarations · optional",text:$draft.materialNotes,axis:.vertical).lineLimit(2...3).textFieldStyle(.roundedBorder)
      TextField("Equipment / application notes · unknown if blank",text:$draft.equipmentNotes,axis:.vertical).lineLimit(2...3).textFieldStyle(.roundedBorder)
      TextField("Review notes · optional",text:$draft.notes,axis:.vertical).lineLimit(2...3).textFieldStyle(.roundedBorder)
      Text("Delivery and reference files are identified separately in the packet. No cutting, printing or stock deduction occurs.").font(.system(size:10)).foregroundStyle(Palette.secondary)
    }.font(.system(size:11))
  }
  private func field(_ label:String,_ value:Binding<String>)->some View {
    VStack(alignment:.leading,spacing:4) {Text(label).font(.system(size:10)).foregroundStyle(Palette.secondary);TextField(label,text:value).textFieldStyle(.roundedBorder).onSubmit{draft.refresh()}}
  }
}

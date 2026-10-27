import AppKit
import FormCore
import FormGraphics
import SwiftUI
import UniformTypeIdentifiers

struct ProductionInkSwatchControls:View {
  @ObservedObject var session:ArtworkSession
  let swatch:ArtworkSwatch
  @State private var editing=false
  var body:some View {
    HStack(spacing:8) {
      if let ink=swatch.printInk {
        Text(ink.kind == .spot ? "Spot · \(ink.spotName!) · \(Int((ink.tint*100).rounded()))%":"Process CMYK").foregroundStyle(Palette.accent)
        Spacer()
        Button("Edit ink…") {editing=true}
        Button("Convert to RGB preview") {session.swatch("update",["swatch_id":swatch.id.uuidString,"print_ink":NSNull()])}
      } else {
        Text("RGB preview").foregroundStyle(Palette.secondary)
        Spacer()
        Button("Set production ink…") {editing=true}
      }
    }.font(.system(size:9)).sheet(isPresented:$editing) {ProductionInkEditor(session:session,swatch:swatch)}
  }
}

@MainActor final class ProductionInkDraft:ObservableObject {
  weak var session:ArtworkSession?
  let swatch:ArtworkSwatch
  @Published var kind=ProductionInk.Kind.processCMYK
  @Published var cyanText="0"
  @Published var magentaText="0"
  @Published var yellowText="0"
  @Published var blackText="0"
  @Published var tintText="100"
  @Published var profile:ArtworkOutputProfile?
  @Published var spotName=""
  @Published var error:String?
  private var originalComponents=CMYKComponents(0,0,0,0)
  private var originalTint=1.0
  private var originalTexts:[String]=[]
  private var originalTintText="100"
  init(session:ArtworkSession,swatch:ArtworkSwatch) {
    self.session=session;self.swatch=swatch;spotName=swatch.name
    var components=CMYKComponents(0,0,0,0),tint=1.0
    if let ink=swatch.printInk {kind=ink.kind;components=ink.components;profile=ink.profile;spotName=ink.spotName ?? swatch.name;tint=ink.tint}
    else {
      currentProfile()
      if let profile {
        do {let values=try ICCOutputProfile(reference:profile,assets:session.assets).processComponents(swatch.color);components = .init(values[0],values[1],values[2],values[3])}
        catch {self.error=error.localizedDescription}
      }
    }
    func text(_ value:Double)->String {let percent=value*100;return percent==percent.rounded() ? String(Int(percent)):String(percent)}
    originalComponents=components;originalTint=tint;originalTexts=components.values.map(text);originalTintText=text(tint)
    cyanText=originalTexts[0];magentaText=originalTexts[1];yellowText=originalTexts[2];blackText=originalTexts[3];tintText=originalTintText
  }
  func currentProfile() {
    guard let value=session?.art.outputColorProfile,value.model=="CMYK" else{error="Assign the intended CMYK profile in Color output first.";return}
    profile=value;error=nil
  }
  private func percentage(_ text:String,label:String,original:Double,initialText:String)throws->Double {
    guard let value=Double(text.trimmingCharacters(in:.whitespacesAndNewlines)),value.isFinite,(0...100).contains(value) else{throw FormError.invalid("\(label) must be a finite percentage from 0 to 100.")}
    // Preserve the exact original component when the field is untouched; formatting
    // a percentage must not round another component while editing this one.
    return text==initialText ? original:value/100
  }
  func save()->Bool {
    guard let session,let profile else{error="Choose the intended CMYK output profile first.";return false}
    do {
      let texts=[cyanText,magentaText,yellowText,blackText],labels=["Cyan","Magenta","Yellow","Black"],original=originalComponents.values
      let values=try texts.indices.map{try percentage(texts[$0],label:labels[$0],original:original[$0],initialText:originalTexts[$0])}
      let tint=kind == .spot ? try percentage(tintText,label:"Ink tint",original:originalTint,initialText:originalTintText):1
      let ink=ProductionInk(kind:kind,components:.init(values[0],values[1],values[2],values[3]),profile:profile,spotName:kind == .spot ? spotName.trimmingCharacters(in:.whitespacesAndNewlines):nil,tint:tint)
      try ink.validate()
      guard session.swatch("update",["swatch_id":swatch.id.uuidString,"print_ink":try jsonObject(ink)]) else{error=session.store?.error ?? "The ink could not be saved.";return false}
      error=nil;return true
    }catch {self.error=error.localizedDescription;return false}
  }
}

struct ProductionInkEditor:View {
  @ObservedObject var session:ArtworkSession
  let swatch:ArtworkSwatch
  @Environment(\.dismiss) private var dismiss
  @StateObject private var draft:ProductionInkDraft
  init(session:ArtworkSession,swatch:ArtworkSwatch,draft:ProductionInkDraft?=nil) {
    self.session=session;self.swatch=swatch
    _draft=StateObject(wrappedValue:draft ?? ProductionInkDraft(session:session,swatch:swatch))
  }
  func save() {if draft.save() {dismiss()}}
  private func percentageField(_ title:String,text:Binding<String>)->some View {
    HStack(spacing:5) {
      Text(title).foregroundStyle(Palette.secondary)
      Spacer(minLength:2)
      TextField(title,text:text).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(minWidth:40,maxWidth:77)
      Text("%").foregroundStyle(Palette.secondary).fixedSize()
    }.font(.system(size:10))
  }
  var body:some View {
    VStack(alignment:.leading,spacing:15) {
      Text("Production ink").font(.system(size: 22, weight: .semibold))
      Text(swatch.name).font(.system(size:12)).foregroundStyle(Palette.secondary)
      Picker("Kind",selection:$draft.kind) {Text("Process CMYK").tag(ProductionInk.Kind.processCMYK);Text("Named spot ink").tag(ProductionInk.Kind.spot)}.pickerStyle(.segmented)
      if draft.kind == .spot {
        TextField("Exact colorant name",text:$draft.spotName).textFieldStyle(.roundedBorder)
        percentageField("Ink tint",text:$draft.tintText)
        Text("CMYK below is the spot's alternate appearance. It does not define a physical match for that ink.").font(.system(size:10)).foregroundStyle(Palette.secondary)
      }
      percentageField("Cyan",text:$draft.cyanText)
      percentageField("Magenta",text:$draft.magentaText)
      percentageField("Yellow",text:$draft.yellowText)
      percentageField("Black",text:$draft.blackText)
      Text(draft.profile.map{"Profile · "+$0.name} ?? "No CMYK profile chosen").font(.system(size:10)).foregroundStyle(Palette.secondary)
      Button("Use current frame's CMYK profile") {draft.currentProfile()}.buttonStyle(.borderless).font(.system(size:10))
      Text(swatch.printInk==nil ? "Initial values convert the RGB preview through this profile. Review the actual components before saving.":"Source components and profile identity stay separate from the approximate sRGB preview.").font(.system(size:10)).foregroundStyle(Palette.secondary)
      if let error=draft.error {Text(error).font(.system(size:10)).foregroundStyle(Palette.accent)}
      HStack {Button("Cancel"){dismiss()};Spacer();Button("Save ink"){save()}.buttonStyle(.borderedProminent).disabled(draft.profile==nil)}
    }.padding(24).frame(width:390).background(Palette.paper)
  }
}

struct ProductionInkExportControls:View {
  @ObservedObject var session:ArtworkSession
  var publicationID:UUID?
  @State private var mode=InkOutputMode.composite
  @State private var report:[String:Any]?
  private func preflight()->Bool {
    if mode == .preview {report=["preview_only":true,"issues":[["message":"RGB appearance output omits process/spot declarations. Normal font and image output checks apply when exporting."]]];return true}
    guard let store=session.store,let object=session.object else{return false}
    do {
      if let publicationID {report=try store.publicationGraphicsCall("form_export_publication",["publication_id":publicationID.uuidString,"ink_output":"preflight"]) as? [String:Any]}
      else {report=try store.exportProductionInks(object,arguments:["format":"pdf","ink_output":"preflight"]) as? [String:Any]}
      return report?[mode == .plates ? "can_export_plates":"can_export_composite"] as? Bool==true
    }catch {store.error=error.localizedDescription;return false}
  }
  private func export() {
    session.canvas?.finishText();guard let store=session.store,let object=session.object else{return}
    if mode != .preview,!preflight() {return}
    let panel=NSSavePanel();panel.allowedContentTypes=[.pdf];panel.nameFieldStringValue=object.name.replacingOccurrences(of:"/",with:"-")+"-"+mode.rawValue+".pdf"
    guard panel.runModal() == .OK,let url=panel.url else{return}
    do {
      if let publicationID {_ = try store.publicationGraphicsCall("form_export_publication",["publication_id":publicationID.uuidString,"ink_output":mode.rawValue,"path":url.path])}
      else {_ = try store.exportArtwork(object:object,arguments:["format":"pdf","ink_output":mode.rawValue,"path":url.path])}
      store.toast("PDF exported")
    }
    catch {store.error=error.localizedDescription}
  }
  var body:some View {
    VStack(alignment:.leading,spacing:9) {
      Divider()
      Text(publicationID==nil ? "Frame production ink PDF":"Publication production ink PDF").font(.system(size:11,weight:.medium))
      Picker("Output",selection:$mode) {
        Text("RGB appearance preview").tag(InkOutputMode.preview)
        Text("CMYK + named-spot composite").tag(InkOutputMode.composite)
        Text("Positive digital ink maps").tag(InkOutputMode.plates)
      }.labelsHidden()
      HStack {Button("Preflight"){_ = preflight()};Spacer();Button("Export PDF…"){export()}}
      Text("Opaque flat vectors and shared text outlines. Ink maps preserve normal knockout, not overprint, trapping, screening or a physical ink-coverage promise.").font(.system(size:9)).foregroundStyle(Palette.secondary)
      if let report {
        Text(report["preview_only"] as? Bool==true ? "RGB appearance preview":report["can_export"] as? Bool==true ? "Production geometry ready":"Review production issues").font(.system(size:10)).foregroundStyle(Palette.secondary)
        ForEach(Array((report["issues"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) {_,issue in Text(issue["message"] as? String ?? "").font(.system(size:9)).foregroundStyle(Palette.accent)}
      }
    }.onChange(of:mode) {_,_ in report=nil}
  }
}

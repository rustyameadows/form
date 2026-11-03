import AppKit
import FormCore
import FormGraphics
import SwiftUI
import UniformTypeIdentifiers

/// Native controls send the same explicit intent as the public export command.
struct PublicationOutputSettings {
  var layout:PublicationPDFLayout = .pages
  var padBooklet=false
  var physicalObjectID:UUID?
  var inkOutput="automatic"
  var dpi=300
  var outlineText=false
  var allowOverset=false
  func arguments(publicationID:UUID,preflight:Bool)->[String:Any] {
    var value:[String:Any]=["publication_id":publicationID.uuidString,
      (preflight ? "output_layout":"layout"):layout.rawValue,"pad_to_multiple_of_four":padBooklet]
    if let physicalObjectID {value["physical_object_id"]=physicalObjectID.uuidString}
    if inkOutput != "automatic" {value["ink_output"]=inkOutput}
    if preflight {value["command"]="preflight"}
    else {value["dpi"]=Double(dpi);value["outline_text"]=outlineText;value["allow_overset"]=allowOverset}
    return value
  }
}

struct PublicationOutputControls:View {
  @ObservedObject var session:ArtworkSession
  @ObservedObject var controller:PublicationWorkspaceController
  let project:Project
  let document:PublicationDocument
  @State private var settings=PublicationOutputSettings()
  @State private var preflightOpen=false
  @State private var report:[String:Any]=[:]
  @State private var reportProjectID:UUID?
  @State private var reportPublicationID:UUID?
  private var editions:[ProductObject] {
    project.objects.filter{$0.sheetAssembly?.publicationID==document.id && $0.sheetAssembly?.parentSheets != nil}
  }
  var body:some View {
    VStack(alignment:.leading,spacing:10) {
      InspectorSectionHeader("OUTPUT")
      Picker("PDF layout",selection:$settings.layout) {
        Text("Reader pages").tag(PublicationPDFLayout.pages)
        Text("Reader spreads").tag(PublicationPDFLayout.spreads)
        Text("Booklet sheets").tag(PublicationPDFLayout.booklet)
      }.pickerStyle(.menu)
      if !editions.isEmpty {
        Picker("Physical edition",selection:$settings.physicalObjectID) {
          Text("Automatic edition").tag(Optional<UUID>.none)
          ForEach(editions){edition in Text(edition.name).tag(Optional(edition.id))}
        }.pickerStyle(.menu).accessibilityIdentifier("publication-output-edition")
      }
      Picker("Output intent",selection:$settings.inkOutput) {
        Text("Document intent").tag("automatic")
        Text("Appearance proof · sRGB").tag("preview")
        Text("Production composite").tag("composite")
        Text("Ink plates").tag("plates")
      }.pickerStyle(.menu).accessibilityIdentifier("publication-output-intent")
      if settings.inkOutput=="preview" {
        Text("Appearance proof. Named and process ink declarations are not encoded.")
          .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      }
      if settings.layout == .booklet,document.layout?.firstPageSide == .verso || document.pages.count%4 != 0 {
        Toggle("Pad with explicit blank pages",isOn:$settings.padBooklet).inspectorToggle()
        Text("Padding completes folded output sheets. Source pages stay exact.")
          .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      }
      Picker("Effects resolution",selection:$settings.dpi) {
        ForEach([72,150,300,600,1200],id:\.self){dpi in Text("\(dpi) DPI").tag(dpi)}
      }.pickerStyle(.menu)
      Toggle("Outline text in PDF",isOn:$settings.outlineText).inspectorToggle()
      Toggle("Allow reviewed text overflow",isOn:$settings.allowOverset).inspectorToggle()
        .help("Explicitly allow clipped text in the exported PDF. Preflight continues to report every affected frame.")
      HStack {
        Button("Preflight",action:preflight).buttonStyle(InspectorActionStyle()).accessibilityIdentifier("publication-preflight")
        Spacer()
        Button("Export PDF…",action:export).buttonStyle(InspectorActionStyle()).accessibilityIdentifier("publication-export-pdf")
      }
    }.font(InspectorStyle.labelFont)
      .popover(isPresented:$preflightOpen){preflightView}
  }
  private var preflightView:some View {
    VStack(alignment:.leading,spacing:12) {
      HStack {
        Text("Publication preflight").font(.system(size:15,weight:.semibold))
        Spacer();AppCloseButton("Close preflight"){preflightOpen=false}
      }
      Text(report["can_export"] as? Bool==true ? "Ready to export":"Review before export")
        .font(InspectorStyle.labelFont)
      if report["uncommitted_text_may_differ"] as? Bool==true {
        Text("This report checks saved artwork. Finish the current text edit and run preflight again to check the draft.")
          .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      }
      if let count=(report["text_frames"] as? [[String:Any]])?.count {
        Text("\(count) text frames checked").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      }
      ScrollView {
        LazyVStack(alignment:.leading,spacing:14) {
          ForEach(Array((report["issues"] as? [[String:Any]] ?? []).enumerated()),id:\.offset){index,item in
            VStack(alignment:.leading,spacing:6) {
              Label(item["message"] as? String ?? "",systemImage:item["severity"] as? String=="error" ? "exclamationmark.triangle":"info.circle")
                .font(InspectorStyle.labelFont).foregroundStyle(item["severity"] as? String=="error" ? Palette.accent:Palette.secondary)
                .fixedSize(horizontal:false,vertical:true)
              if let projectID=reportProjectID,let publicationID=reportPublicationID,
                let target=PublicationPreflightTarget(issue:item,projectID:projectID,publicationID:publicationID) {
                Button(target.elementID==nil ? "Go to page":target.instanceElementID != nil ? "Go to source frame":"Go to frame") {
                  if controller.focusPreflightIssue(target) {preflightOpen=false}
                  else {session.store?.error="The reported source is no longer available, or text composition is still active. Finish the edit and run preflight again."}
                }.buttonStyle(.link).accessibilityIdentifier("publication-preflight-locate-\(index)")
                if target.instanceElementID != nil {
                  Text("Component occurrence. Its text may be overridden; frame geometry belongs to the shared source.")
                    .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
                }
              }
            }
          }
        }.padding(.vertical,4)
      }.frame(maxHeight:420)
    }.padding(18).frame(width:440).labInterface()
  }
  private func preflight() {
    guard let store=session.store,store.project?.id==project.id else{return}
    reportProjectID=project.id;reportPublicationID=document.id
    do {
      report=try store.publicationGraphicsCall("form_publication",settings.arguments(publicationID:document.id,preflight:true)) as? [String:Any] ?? [:]
      report["uncommitted_text_may_differ"]=session.editingText
    }catch{report=["can_export":false,"issues":[["severity":"error","message":error.localizedDescription]]]}
    preflightOpen=true
  }
  private func export() {
    guard let store=session.store,store.project?.id==project.id else{return}
    // Capture intent before the save panel. Changing projects invalidates it.
    var arguments=settings.arguments(publicationID:document.id,preflight:false)
    let panel=NSSavePanel();panel.allowedContentTypes=[.pdf]
    panel.nameFieldStringValue=document.name.replacingOccurrences(of:"/",with:"-")+(settings.inkOutput=="preview" ? " - proof":"")+".pdf"
    guard panel.runModal() == .OK,let url=panel.url,store.project?.id==project.id else{return}
    do {
      guard session.canvas?.storyEditor?.views.contains(where:{$0.hasMarkedText()}) != true,
        session.canvas?.activeTextView?.hasMarkedText() != true else {
        throw FormError.invalid("Finish the current text input before exporting the publication.")
      }
      session.canvas?.finishText();arguments["path"]=url.path
      _=try store.publicationGraphicsCall("form_export_publication",arguments)
      store.toast(settings.inkOutput=="preview" ? "Appearance proof exported":"Publication PDF exported")
    }catch{store.error=error.localizedDescription}
  }
}

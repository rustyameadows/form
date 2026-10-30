import AppKit
import FormCore
import FormGraphics
import SwiftUI

enum PaperRepresentation: String, CaseIterable, Identifiable {
  case panels, dieline, sheet
  var id: String { rawValue }
  var title: String { self == .sheet ? "Sheet layout" : rawValue.capitalized }
}

extension StudioStore {
  func selectPaperPanel(objectID: UUID, panelID: String) {
    guard let object = project?.objects.first(where: { $0.id == objectID }),
      let net = try? PaperConstruction.definition(for: object).net(), net.panels.contains(where: { $0.id == panelID }) else { return }
    if primary?.id != objectID { select(objectID) }
    paperSelectedPanelID = panelID
    if let foldID=paperSelectedFoldID,net.folds.first(where:{$0.id==foldID})?.childPanelID != panelID {paperSelectedFoldID=nil}
    changed(save: false)
  }
  func focusConstructionCanvas(objectID: UUID, panelID: String?) {
    guard let frame = artworkSession.frames.first(where: {
      $0.projection?.constructionID == objectID && $0.projection?.panelID == panelID
    }) else { return }
    artworkSession.activate(frame.id)
    artworkSession.canvas?.synchronize()
    artworkSession.canvas?.fit(all: false)
  }
  func showPaper(_ representation: PaperRepresentation, object: ProductObject, split: Bool = false) {
    finishArtworkEditing()
    paperRepresentation = representation
    functionRepresentation=representation.title
    if split {
      closeDetachedCanvas(); surfaceLayout = .split; showingHome = false; mode = .artwork
    } else if surfaceLayout == .single { mode = .artwork }
    activatePaperArtwork(object)
    if environment == .form {
      focusConstructionCanvas(objectID: object.id,
        panelID: representation == .panels ? paperSelectedPanelID ?? (try? PaperConstruction.definition(for: object).net().rootPanelID) : nil)
    }
    changed(save: false)
  }
  func activatePaperArtwork(_ object: ProductObject) {
    let source = paperInside ? object.paperConstruction?.insideArtworkSourceID : project?.artworkOwner(object).id
    guard let source, project?.objects.contains(where: { $0.id == source }) == true else { return }
    artworkSession.activate(source)
    // Only the Canvas context changes; Table keeps its own physical selection.
    artworkSession.linkedTargetID = object.id
    if let proof=artworkSession.frames.first(where: {
      $0.projection?.constructionID == object.id && $0.projection?.sourceID == source && $0.projection?.isProof == true
    }) { artworkSession.activate(proof.id) }
    artworkSession.dieline = false
  }
  func setPaperInside(_ inside: Bool, object: ProductObject) {
    guard inside != paperInside else { return }
    let panel = artworkSession.activeProjection?.panelID
    finishArtworkEditing()
    paperInside = inside
    activatePaperArtwork(object)
    focusConstructionCanvas(objectID: object.id, panelID: panel)
    changed(save: false)
  }
  func createPaperInside(_ object: ProductObject) {
    do {
      finishArtworkEditing()
      _ = try engine.call("form_paper", arguments: ["command":"ensure_inside", "object_id":object.id.uuidString], source:"Studio")
      paperInside = true
      if let current = project?.objects.first(where: { $0.id == object.id }) { activatePaperArtwork(current) }
      changed()
    } catch { self.error = error.localizedDescription }
  }
  @discardableResult func configurePaper(_ object: ProductObject, definition: PaperConstruction) -> Bool {
    do {
      finishArtworkEditing()
      _ = try engine.call("form_paper", arguments:["command":"configure","object_id":object.id.uuidString,"definition":try jsonObject(definition)],source:"Studio")
      changed()
      return true
    } catch { self.error = error.localizedDescription; return false }
  }
}

struct PaperWorkspaceView: View {
  @EnvironmentObject var store: StudioStore
  let object: ProductObject
  private var definition: PaperConstruction? { try? .definition(for: object) }
  var body: some View {
    GeometryReader { proxy in
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment:.leading, spacing:4) {
            Text(store.environment == .form ? "COMPOSE THE SURFACES" : store.environment == .function ? "DEVELOP THE CONSTRUCTION" : "PREPARE THE PAPER GOODS")
              .font(.system(size:9,weight:.semibold)).tracking(1.5).foregroundStyle(Palette.secondary)
            Text(object.name).font(.system(size:18,weight:.medium,design: .default)).lineLimit(1)
          }.frame(minWidth:0,maxWidth:.infinity,alignment:.leading)
          Spacer()
          if let net = try? definition?.net() {
            Text(String(format:"%.1f × %.1f mm flat",net.size.x,net.size.y)).font(.system(size:10,design:.monospaced)).foregroundStyle(Palette.secondary).fixedSize()
          }
        }
        VStack(alignment:.leading,spacing:10) {
          representationPicker.frame(width:min(330,max(1,proxy.size.width-36)))
          HStack(spacing:10) {
            sidePicker
            Spacer(minLength:0)
            visibilityControls
          }
        }
      }.padding(18).frame(width:proxy.size.width,alignment:.leading).background(Palette.paper)
      Divider()
      if store.environment == .form && store.paperRepresentation == .dieline && store.paperShowingArtwork {
        if store.paperInside && definition?.insideArtworkSourceID == nil {
          VStack(spacing:14) {
            Image(systemName:"square.on.square").font(.system(size:32)).foregroundStyle(Palette.secondary)
            Text("An independent inside artwork source").font(.system(size: 18, weight: .semibold))
            Text("Registered to the same flat construction. Creating it leaves the outside artwork intact.").font(.system(size:12)).foregroundStyle(Palette.secondary)
            Button("Create inside artwork") { store.createPaperInside(object) }
          }.frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
          ArtworkStudio(session:store.artworkSession)
            .onAppear { store.activatePaperArtwork(object) }
        }
      } else {
        PaperConstructionPreview(object:object, representation:store.paperRepresentation)
      }
      HStack(spacing:12) {
        Label(store.paperInside ? "Inside · registered layout" : "Outside artwork",systemImage:"square.on.square")
        Spacer()
        if store.paperRepresentation == .panels {
          Button("Edit panel") { store.showPaper(.dieline,object:object); store.environment = .form }
            .help("Edit selected panel in dieline").accessibilityLabel("Edit selected panel in dieline")
        }
        Text(store.environment == .form ? "One artwork source · physical scale" : store.environment == .function ? "Select a panel · review its folds & joins" : "Actual-size output · local files only")
      }.font(.system(size:10)).lineLimit(1).foregroundStyle(Palette.secondary).padding(.horizontal,18).frame(height:36).background(Palette.paper)
    }.frame(width:proxy.size.width,height:proxy.size.height)
    }
    .onChange(of:object.id) { _,_ in store.paperSelectedPanelID = nil; store.paperSelectedFoldID = nil; store.activatePaperArtwork(object) }
    .focusedValue(\.designSurface,.artwork)
  }
  private var representationPicker:some View {
    HStack(spacing:2) {
      ForEach(PaperRepresentation.allCases) { value in
        Button {store.paperRepresentation=value} label: {
          Text(value.title).frame(maxWidth:.infinity).padding(.vertical,4)
            .background(store.paperRepresentation == value ? Color.white:.clear,in:RoundedRectangle(cornerRadius:4))
        }.buttonStyle(.plain).accessibilityValue(store.paperRepresentation == value ? "Selected":"")
      }
    }.font(.system(size:11)).padding(2).background(.black.opacity(0.05),in:RoundedRectangle(cornerRadius:6))
      .accessibilityElement(children:.contain).accessibilityLabel("Paper view")
  }
  private var sidePicker:some View {
    HStack(spacing:2) {
      ForEach([false,true],id:\.self) { inside in
        Button {store.setPaperInside(inside,object:object)} label: {
          Text(inside ? "Inside":"Outside").frame(maxWidth:.infinity).padding(.vertical,4)
            .background(store.paperInside == inside ? Color.white:.clear,in:RoundedRectangle(cornerRadius:4))
        }.buttonStyle(.plain).accessibilityValue(store.paperInside == inside ? "Selected":"")
      }
    }.font(.system(size:11)).padding(2).background(.black.opacity(0.05),in:RoundedRectangle(cornerRadius:6)).frame(width:150)
      .accessibilityElement(children:.contain).accessibilityLabel("Artwork side")
  }
  private var visibilityControls:some View {
    HStack(spacing:10) {
      Toggle("Artwork",isOn:$store.paperShowingArtwork)
      Toggle("Guides",isOn:$store.paperShowingGuides)
    }.toggleStyle(.checkbox).font(.system(size:10)).fixedSize()
  }
}

struct PaperEnvironmentControls: View {
  @EnvironmentObject var store: StudioStore
  let object: ProductObject
  @State private var draft: PaperConstruction?
  @State private var draftBase: PaperConstruction?
  @State private var draftIssue: String?
  @State private var note = ""
  private var definition: PaperConstruction? { try? .definition(for:object) }
  var body: some View {
    ScrollView {
      VStack(alignment:.leading,spacing:InspectorStyle.sectionSpacing) {
        LinkedObjectInspectorModule(object: object, session: store.artworkSession)
        if let definition {
          if store.environment == .form { appearance(definition) }
          else if store.environment == .function { construction(definition) }
          else { fabrication(definition) }
        }
      }.padding(16)
    }.inspectorSurface().onAppear { reloadDraft() }
      .onChange(of:object.paperConstruction) { _,_ in reconcileDraft() }
      .onChange(of:object.id) { _,_ in reloadDraft(); note = "" }
      .accessibilityElement(children:.contain).accessibilityLabel("Paper " + store.environment.title + " controls")
  }
  private func appearance(_ d:PaperConstruction) -> some View {
    VStack(alignment:.leading,spacing:12) {
      SectionLabel("PAPER & EXPRESSION")
      Text(d.stock.name).font(.system(size:13,weight:.medium))
      Text("White uncoated · subtle tooth · matte").font(.system(size:11)).foregroundStyle(Palette.secondary)
      HStack {
        Button("White") { store.update(object,["color":"#F7F5EF"]) }
        Button("Natural") { store.update(object,["color":"#D9C6A2"]) }
        Button("Blue") { store.update(object,["color":"#254F91"]) }
      }.font(.system(size:11))
      InspectorColorPicker("Paper color", selection: Binding(
        get: { Color(nsColor: NSColor(hex: object.color ?? "#F7F5EF")) },
        set: { store.update(object, ["color": NSColor($0).hexString]) }), supportsOpacity: false,
        targetID: "paper-\(store.project?.id.uuidString ?? "")-\(object.id)",
        onEditingChanged: store.inspectorInteraction("paper-color-\(object.id)"))
      InspectorDivider()
      SectionLabel("ARTWORK")
      if d.insideArtworkSourceID == nil { Button("Create inside artwork…") { store.createPaperInside(object); store.showPaper(.dieline,object:object,split:true) } }
      InspectorDivider()
      Button("Develop construction in Function") { store.showEnvironment(.function) }
    }
  }
  private func construction(_ d:PaperConstruction) -> some View {
    VStack(alignment:.leading,spacing:12) {
      SectionLabel(d.authored?.name.uppercased() ?? (d.kind == .envelope ? "GLUED ENVELOPE" : "STRAIGHT TUCK CARTON"))
      if d.authored == nil {
        Text(d.kind == .envelope ? "Flat back · side seam · top opening" : "Four body panels · glue seam · tuck & dust flaps").font(.system(size:11)).foregroundStyle(Palette.secondary)
      }
      if draft != nil {
        if let authored = d.authored {
          ForEach(authored.parameters, id: \.name) { parameter in
            let value = draft?.authored?.parameters.first(where: { $0.name == parameter.name })?.value ?? parameter.value
            if parameter.unit == "mm" {
              ArtworkUnitField(parameter.name, value: value, unit: store.project?.unit == "in" ? .inches : .mm) { updateDraft(parameter.name, $0) }
            } else {
              ScalarArtworkField(parameter.name, value: value, unit: parameter.unit) { updateDraft(parameter.name, $0) }
            }
          }
        } else {
        field("Internal width",get:{draft!.dimensions.width},set:{draft!.dimensions.width=$0})
        field("Internal height",get:{draft!.dimensions.height},set:{draft!.dimensions.height=$0})
        field("Internal depth",get:{draft!.dimensions.depth},set:{draft!.dimensions.depth=$0})
        field("Paper thickness",get:{draft!.stock.thicknessMM},set:{draft!.stock.thicknessMM=$0})
        field("Contents clearance",get:{draft!.clearanceMM},set:{draft!.clearanceMM=$0})
        field("Glue tab",get:{draft!.glueTabMM},set:{draft!.glueTabMM=$0})
        field("Top flap",get:{draft!.topFlapMM},set:{draft!.topFlapMM=$0})
        field("Bottom flap",get:{draft!.bottomFlapMM},set:{draft!.bottomFlapMM=$0})
        }
        Button("Apply construction") { applyDraft() }.buttonStyle(.borderedProminent).disabled(draftIssue != nil)
        if let draftIssue { Text(draftIssue).font(.system(size:10)).foregroundStyle(Palette.accent); Button("Reload current construction") {reloadDraft()} }
      }
      InspectorDivider()
      SectionLabel("FOLD REVIEW")
      HStack {Text("Flat");InspectorSlider(value:Binding(get:{object["fold"]},set:{store.update(object,["parameters":["fold":$0]])}),in:0...100);Text("Folded")}.font(.system(size:10))
      HStack {ForEach([0.0,45.0,100.0],id:\.self) {v in Button(v == 0 ? "Flat" : v == 100 ? "Assembled" : "Part folded") {store.update(object,["parameters":["fold":v]])}}}.font(.system(size:10))
      HStack {Text("Closed");InspectorSlider(value:Binding(get:{object["opening"]},set:{store.update(object,["parameters":["opening":$0]])}),in:0...100);Text("Top open")}.font(.system(size:10))
      Text("Opening leaves the glued body and bottom assembled.").font(.system(size:10)).foregroundStyle(Palette.secondary)
      if let net = try? d.net() {
        Picker("Selected panel",selection:Binding(get:{store.paperSelectedPanelID ?? net.rootPanelID},set:{store.selectPaperPanel(objectID:object.id,panelID:$0)})) {
          ForEach(net.panels) { Text($0.name).tag($0.id) }
        }.font(.system(size:11))
        Picker("Selected fold",selection:Binding<String?>(get:{store.paperSelectedFoldID},set:{id in
          if let id,let fold=net.folds.first(where:{$0.id==id}) {store.selectPaperPanel(objectID:object.id,panelID:fold.childPanelID)}
          store.paperSelectedFoldID=id;store.changed(save:false)
        })) {
          Text("Choose a fold").tag(String?.none)
          ForEach(net.folds) {fold in Text(fold.parentPanelID+" → "+fold.childPanelID).tag(Optional(fold.id))}
        }.font(.system(size:11))
        ForEach(net.joins) {join in
          VStack(alignment:.leading,spacing:3) {Text(join.name).font(.system(size:11,weight:.medium));Text(join.firstPanelID + " ↔ " + join.secondPanelID + " · " + String(format:"%.1f mm overlap",join.overlapMM)).font(.system(size:10)).foregroundStyle(Palette.secondary)}
        }
      }
      TextField("Construction note for selected panel",text:$note,axis:.vertical).textFieldStyle(.roundedBorder).font(.system(size:11))
      Button("Attach note") { addNote(d) }.disabled(note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
      ForEach(d.annotations) {annotation in Text((annotation.panelID.map{$0 + " · "} ?? "") + annotation.text).font(.system(size:11)).foregroundStyle(Palette.secondary)}
      preflight(d)
    }
  }
  private func fabrication(_ d:PaperConstruction) -> some View {
    VStack(alignment:.leading,spacing:12) {
      SectionLabel("STOCK & PROTOTYPES")
      Text(d.stock.name).font(.system(size:13,weight:.medium))
      Text(String(format:"%.2f mm · %@",d.stock.thicknessMM,d.stock.verified ? "measured stock" : "unverified prototype stock")).font(.system(size:11)).foregroundStyle(Palette.secondary)
      TextField("Sheet width · mm",value:$store.paperSheetWidth,format:.number).font(Palette.numericFont).textFieldStyle(.roundedBorder)
      TextField("Sheet height · mm",value:$store.paperSheetHeight,format:.number).font(Palette.numericFont).textFieldStyle(.roundedBorder)
      Stepper("Prototype quantity: \(store.paperQuantity)",value:$store.paperQuantity,in:1...64)
      TextField("Margin · mm",value:$store.paperSheetMargin,format:.number).font(Palette.numericFont).textFieldStyle(.roundedBorder)
      TextField("Gap · mm",value:$store.paperSheetGap,format:.number).font(Palette.numericFont).textFieldStyle(.roundedBorder)
      if let layout = try? PaperOutput.layout(store:store,definition:d) {
        Text("\(layout.sheetCount) sheets · \(layout.placements.count) blanks").font(.system(size:12,weight:.medium))
        ForEach(layout.issues) {issue in Text(issue.message).font(.system(size:11)).foregroundStyle(issue.severity == .error ? Palette.ink : Palette.secondary)}
      }
      Button("Review sheet layout") { store.showPaper(.sheet,object:object) }
      InspectorDivider()
      SectionLabel("CUT, CREASE & PRINT")
      Text("Print artwork, cut the outline, crease the folds, then glue and assemble. Grain is retained; automatic rotation is off.").font(.system(size:11)).foregroundStyle(Palette.secondary)
      Button("Export cut & crease SVG…") { store.exportPaperDialog(object:object,format:"svg") }
      Button("Export sheet proof PDF…") { store.exportPaperDialog(object:object,format:"pdf") }
      Button("Export production packet…") { store.exportPaperDialog(object:object,format:"packet") }.buttonStyle(.borderedProminent)
      Text("Inside files use registered flat coordinates. Prove duplex feed, creases, glue and fit with the actual paper.").font(.system(size:10)).foregroundStyle(Palette.secondary)
      preflight(d)
    }.font(.system(size:11))
  }
  private func updateDraft(_ name: String, _ value: Double) {
    if let index = draft?.authored?.parameters.firstIndex(where: { $0.name == name }) {
      draft?.authored?.parameters[index].value = value
    }
  }
  private func field(_ title:String,get:@escaping()->Double,set:@escaping(Double)->Void)->some View {
    ArtworkUnitField(title, value: get(), unit: store.project?.unit == "in" ? .inches : .mm) { set($0) }
  }
  private func addNote(_ d:PaperConstruction) {
    var value=d;value.annotations.append(.init(text:note,panelID:store.paperSelectedPanelID,edgeID:store.paperSelectedFoldID,view:store.mode == .table ? "assembled":store.paperRepresentation == .panels ? "panels":"dieline"));if store.configurePaper(object,definition:value) {note=""}
  }
  private func reloadDraft() {draft=definition;draftBase=definition;draftIssue=nil}
  private func reconcileDraft() {
    guard let current=definition else{reloadDraft();return}
    if draft==draftBase || draft==current {reloadDraft();return}
    var base=draftBase;base?.foldPercent=current.foldPercent;base?.openingPercent=current.openingPercent
    if base==current {draft?.foldPercent=current.foldPercent;draft?.openingPercent=current.openingPercent;draftBase=current}
    else {draftIssue="The construction changed while these fields were being edited. Reload it before applying."}
  }
  private func applyDraft() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    guard let draft,definition==draftBase else{draftIssue="The source changed. Reload the current construction before applying.";return}
    if store.configurePaper(object,definition:draft) {reloadDraft()}
  }
  private func preflight(_ d:PaperConstruction)->some View {
    VStack(alignment:.leading,spacing:7) {
      InspectorDivider();SectionLabel("CONSTRUCTION REVIEW")
      if let report=try? d.preflight() {
        ForEach(report.issues) {issue in Text(issue.message).font(.system(size:10)).foregroundStyle(issue.severity == .error ? Palette.ink : Palette.secondary)}
      }
    }
  }
}

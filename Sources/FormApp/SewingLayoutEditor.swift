import AppKit
import FormCore
import SwiftUI
import UniformTypeIdentifiers

struct SewingLayoutEditor: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) var dismiss
  @StateObject private var model: SewingLayoutController
  @State private var dpi = 150.0
  @State private var includeFabricExport = false
  @State private var exportError = ""
  @State private var reviewingPDF = false
  init(session: ArtworkSession) { _model = StateObject(wrappedValue: SewingLayoutController(session: session)) }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Material cutting layout").font(.system(size: 25, design: .serif))
          Text(model.sourceName + " · source pieces remain editable").font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
        Spacer()
        Button("Undo") { store.undo(); _ = model.refreshContext() }.disabled(store.engine.undoStack.isEmpty)
        Button("Redo") { store.redo(); _ = model.refreshContext() }.disabled(store.engine.redoStack.isEmpty)
        Button("Done") { if !model.sourceAvailable || model.commitFields() { model.finish(); dismiss() } }.keyboardShortcut(.cancelAction)
      }
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Button("Auto layout") { model.plan() }.disabled(!model.canPlan)
            Button("Fit stock") { model.fitRequest += 1 }
            Button("Review PDF…") { if model.commitFields() { reviewingPDF = true } }.disabled(!model.canExport).accessibilityLabel("Review cutting layout PDF")
            Toggle("Fabric reference", isOn: $model.showFabric).toggleStyle(.checkbox).font(.system(size: 10))
            Spacer()
            if model.planning || model.checking { ProgressView().controlSize(.small); Text(model.planning ? "Planning…" : "Checking…").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
          }
          SewingLayoutCanvas(controller: model).background(.white, in: RoundedRectangle(cornerRadius: 8)).clipShape(RoundedRectangle(cornerRadius: 8))
          summary
          Text("Drag a cut copy to position it. Scroll or pinch to inspect. Escape restores the current drag. Only Auto layout rearranges the saved poses.")
            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            stockControls
            selectedControls
            diagnostics
            exportControls
          }.padding(.trailing, 7)
        }.frame(width: 305)
      }
      if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
      if !exportError.isEmpty { Text(exportError).foregroundStyle(.red).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
      if !model.notice.isEmpty { Text(model.notice).font(.system(size: 10)).foregroundStyle(Palette.secondary) }
    }.padding(24).frame(width: 1160, height: 790).background(Palette.paper)
      .onChange(of: store.revision) { _, _ in _ = model.refreshContext() }
      .onChange(of: store.project?.id) { _, id in if id != model.projectID { model.finish(); dismiss() } }
      .onDisappear { model.finish() }
      .sheet(isPresented: $reviewingPDF) { SewingLayoutPDFReview(model: model).environmentObject(store) }
  }
  @ViewBuilder private var stockControls: some View {
    SectionLabel("MATERIAL & STOCK")
    Picker("Fabric", selection: Binding(get: { model.layout.materialID }, set: { id in if let material = store.materials.first(where: { $0.id == id }) { model.chooseMaterial(material) } })) {
      if model.layout.materialID.isEmpty { Text("Choose fabric").tag("") }
      ForEach(store.materials.filter { $0.fabric != nil }) { Text($0.name).tag($0.id) }
    }.font(.system(size: 11)).disabled(!model.canEdit)
    Picker("Surface", selection: option(\.surface)) { Text("Roll").tag(SewingCutLayout.Surface.roll); Text("Sheet").tag(SewingCutLayout.Surface.sheet) }.pickerStyle(.segmented).disabled(!model.canEdit)
    number("Open usable width", key: "width", value: model.layout.stockWidth, optional: true, unit: "mm") { value in model.edit { $0.stockWidth = value } }
    if model.layout.surface == .sheet {
      number("Sheet length", key: "sheet", value: model.layout.sheetLength, optional: true, unit: "mm") { value in model.edit { $0.sheetLength = value } }
    } else {
      number("Planner length limit", key: "limit", value: model.layout.maximumLength, unit: "mm") { value in if let value { model.edit { $0.maximumLength = value } } }
    }
    Picker("Layers", selection: option(\.stock)) { Text("Single layer").tag(SewingCutLayout.Stock.singleLayer); Text("Folded, two plies").tag(SewingCutLayout.Stock.foldedPair) }.font(.system(size: 10)).disabled(!model.canEdit)
    if model.layout.stock == .foldedPair {
      Text("The left edge is the material fold. Working width is half the open width. Ordinary placements cut two copies; on-fold placements produce one full piece. Ordinary quantities must be even.")
        .font(.system(size: 9)).foregroundStyle(Palette.secondary)
    }
    Picker("Grain", selection: option(\.grain)) { ForEach(SewingCutLayout.Grain.allCases, id: \.self) { Text($0.title).tag($0) } }.font(.system(size: 10)).disabled(!model.canEdit)
    number("Margin", key: "margin", value: model.layout.margin, unit: "mm") { value in if let value { model.edit { $0.margin = value } } }
    number("Piece separation", key: "spacing", value: model.layout.spacing, unit: "mm") { value in if let value { model.edit { $0.spacing = value } } }
    Text("Unassigned pieces use the selected stock; other material assignments stay outside this layout. Width comes from a declared specification or your entry. Empty measurements remain unknown. The bounded planner supports up to 200 placements and a 5 m length, without claiming optimal nesting.")
      .font(.system(size: 9)).foregroundStyle(Palette.secondary)
    Divider(); SectionLabel("FABRIC PHASE")
    number("Origin X", key: "phaseX", value: model.layout.fabricOrigin.x, unit: "mm") { value in if let value { model.edit { $0.fabricOrigin.x = value } } }
    number("Origin Y", key: "phaseY", value: model.layout.fabricOrigin.y, unit: "mm") { value in if let value { model.edit { $0.fabricOrigin.y = value } } }
    Text("Repeats stay anchored in physical roll coordinates. Moving a piece changes which motifs it captures. Folded stock previews the upper/right ply. Alignment across seams and the hidden ply is not verified.")
      .font(.system(size: 9)).foregroundStyle(Palette.secondary)
    Divider(); SectionLabel("DECLARED MATERIAL COST")
    number("Rate per usable m²", key: "cost", value: model.layout.costPerSquareMeter, optional: true, unit: "") { value in model.edit { $0.costPerSquareMeter = value } }
    currency
    Text("Estimate uses the full open usable stock area at your declared rate. Planning and export never deduct inventory.")
      .font(.system(size: 9)).foregroundStyle(Palette.secondary)
  }
  @ViewBuilder private var selectedControls: some View {
    Divider(); SectionLabel("CUT COPIES")
    if let p = model.selected {
      Text(model.source.elements.first { $0.id == p.elementID }?.sewingPiece?.name ?? "Missing source piece").font(.system(size: 13, design: .serif))
      Text("Copy " + p.copies.map(String.init).joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(Palette.secondary)
      number("X", key: "poseX", value: p.x, unit: "mm") { value in if let value { model.editPlacement(p.id) { $0.x = value } } }
      number("Y", key: "poseY", value: p.y, unit: "mm") { value in if let value { model.editPlacement(p.id) { $0.y = value } } }
      number("Rotation", key: "poseR", value: p.rotation, unit: "°") { value in if let value { model.editPlacement(p.id) { $0.rotation = value } } }
      Button("Remove this placement") { model.removePlacement(p.id) }.font(.system(size: 10)).disabled(!model.canEdit)
    }
    ForEach(model.layout.placements) { p in
      Button { model.selectedID = p.id } label: {
        HStack {
          Text(model.source.elements.first { $0.id == p.elementID }?.sewingPiece?.name ?? "Missing piece")
          Spacer(); Text(p.copies.map(String.init).joined(separator: ",")).foregroundStyle(Palette.secondary)
        }.font(.system(size: 10)).padding(7).background(model.selectedID == p.id ? Palette.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
      }.buttonStyle(.plain)
    }
    if model.layout.placements.isEmpty { Text("Configure stock, then choose Auto layout. Source geometry and cut quantities stay unchanged.").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
  }
  @ViewBuilder private var diagnostics: some View {
    Divider(); SectionLabel("EXACT PREFLIGHT")
    if let report = model.report {
      Label(report.isValid ? "All copies clear" : "Layout needs attention", systemImage: report.isValid ? "checkmark.circle" : "exclamationmark.circle")
        .font(.system(size: 11, weight: .medium)).foregroundStyle(report.isValid ? Palette.ink : Palette.accent)
      ForEach(Array(report.issues.prefix(12).enumerated()), id: \.offset) { _, issue in
        Button { model.selectedID = issue.placements.first } label: { Text(issue.message).font(.system(size: 10)).multilineTextAlignment(.leading).foregroundStyle(Palette.accent) }.buttonStyle(.plain)
      }
      if report.issues.count > 12 { Text("\(report.issues.count - 12) additional issues; replan or inspect the selected placements.").font(.system(size: 9)).foregroundStyle(Palette.secondary) }
      if !report.excludedPieceIDs.isEmpty { Text("\(report.excludedPieceIDs.count) source pieces use another stock or lie outside this layout's scope.").font(.system(size: 9)).foregroundStyle(Palette.secondary) }
    } else { Text("Enter valid stock settings to check the layout.").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
    Button("Remove saved layout") { model.removeLayout() }.font(.system(size: 10)).disabled(!model.canEdit)
  }
  @ViewBuilder private var summary: some View {
    if let report = model.report {
      HStack(spacing: 20) {
        metric("Required length", String(format: "%.1f mm", report.requiredLength))
        metric(model.layout.surface == .sheet ? "Sheet allocation" : "Roll allocation", String(format: "%.3f m²", report.allocatedAreaMM2/1_000_000))
        metric("Cut material", String(format: "%.3f m²", report.cutAreaMM2/1_000_000))
        metric("Waste / unused", String(format: "%.1f%%", report.wasteFraction*100))
        if let cost = report.estimatedCost { metric("Declared-rate estimate", String(format: "%.2f %@", cost, model.layout.costCurrency ?? "units")) }
        Spacer()
      }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 7))
    }
  }
  private func metric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 9)).foregroundStyle(Palette.secondary); Text(value).font(.system(size: 12, design: .monospaced)) }
  }
  @ViewBuilder private var exportControls: some View {
    Divider(); SectionLabel("PHYSICAL OUTPUT")
    Toggle("Include fabric reference layer", isOn: $includeFabricExport).font(.system(size: 10))
    Text("SVG and PDF use the exact working-stock width and consumed length, with origin 0,0. Colored fabric is a reference layer; this export does not verify seam registration or operate a machine.")
      .font(.system(size: 9)).foregroundStyle(Palette.secondary)
    HStack { Text("Raster / effect DPI").font(.system(size: 10)); Spacer(); TextField("DPI", value: $dpi, format: .number).textFieldStyle(.roundedBorder).frame(width: 70) }
    HStack { ForEach(["svg","pdf","png"], id: \.self) { format in Button(format.uppercased()) { export(format) }.disabled(!model.canExport) } }
  }
  private func option<T: Equatable>(_ path: WritableKeyPath<SewingCutLayout, T>) -> Binding<T> {
    Binding(get: { model.layout[keyPath: path] }, set: { value in model.edit { $0[keyPath: path] = value } })
  }
  private func number(_ title: String, key: String, value: Double?, optional: Bool = false, unit: String,
    commit: @escaping (Double?) -> Void) -> some View {
    let epoch = model.externalEpoch
    return SewingLayoutNumberField(title: title, value: value, optional: optional, unit: unit, reset: epoch,
      invalid: { model.setInputError(key, invalid: $0) }, commit: { if model.externalEpoch == epoch { commit($0) } })
      .disabled(!model.canEdit)
  }
  private var currency: some View {
    let epoch = model.externalEpoch
    return SewingLayoutCurrencyField(value: model.layout.costCurrency, reset: epoch,
      invalid: { model.setInputError("currency", invalid: $0) }, commit: { value in if model.externalEpoch == epoch { model.edit { $0.costCurrency = value } } }).disabled(!model.canEdit)
  }
  private func export(_ format: String) {
    guard model.commitFields(), model.canExport, let objectID = model.objectID,
      let object = store.project?.objects.first(where: { $0.id == objectID }) else { return }
    let panel = NSSavePanel(); panel.nameFieldStringValue = model.layout.name + "." + format
    panel.allowedContentTypes = [format == "svg" ? .svg : format == "pdf" ? .pdf : .png]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      _ = try store.exportSewingLayout(object: object, arguments: ["format": format, "path": url.path, "dpi": dpi, "include_fabric_preview": includeFabricExport])
      exportError = ""; store.toast("Cutting layout exported")
    } catch { exportError = error.localizedDescription }
  }
}

private struct SewingLayoutNumberField: View {
  let title: String
  let value: Double?
  let optional: Bool
  let unit: String
  let reset: Int
  let invalid: (Bool) -> Void
  let commit: (Double?) -> Void
  @State private var draft = ""
  @State private var lastCommitted = ""
  @State private var error = false
  @FocusState private var focused: Bool
  private func text() -> String {
    guard let value else { return "" }
    var result = String(format: "%.6f", value)
    while result.hasSuffix("0") { result.removeLast() }
    if result.hasSuffix(".") { result.removeLast() }
    return result == "-0" ? "0" : result
  }
  private func apply() {
    if draft == lastCommitted { error = false; invalid(false); return }
    let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if optional && raw.isEmpty { error = false; invalid(false); lastCommitted = draft; commit(nil); return }
    let number = Double(raw) ?? (unit == "mm" ? try? PhysicalUnit.mm.parse(raw) : nil)
    guard let number, number.isFinite else { error = true; invalid(true); return }
    error = false; invalid(false); lastCommitted = draft; commit(number)
  }
  var body: some View {
    HStack {
      Text(title).font(.system(size: 10)); Spacer()
      TextField(optional ? "Unknown" : title, text: $draft).focused($focused).multilineTextAlignment(.trailing)
        .textFieldStyle(.roundedBorder).font(.system(size: 10,design: .monospaced)).foregroundStyle(error ? Palette.accent : Palette.ink).frame(width: 90)
        .onSubmit(apply).onChange(of: focused) { _, focus in if !focus { apply() } }
      if !unit.isEmpty { Text(unit).font(.system(size: 9)).foregroundStyle(Palette.secondary).frame(width: 22, alignment: .leading) }
    }.onAppear { draft = text(); lastCommitted = draft }.onChange(of: value) { _, _ in if !focused { draft = text(); lastCommitted = draft } }
      .onChange(of: reset) { _, _ in draft = text(); lastCommitted = draft; error = false; invalid(false) }
      .onReceive(NotificationCenter.default.publisher(for: .formCommitArtworkFields)) { _ in apply() }
      .onDisappear { invalid(false) }
  }
}
private struct SewingLayoutCurrencyField: View {
  let value: String?
  let reset: Int
  let invalid: (Bool) -> Void
  let commit: (String?) -> Void
  @State private var draft = ""
  @State private var error = false
  @FocusState private var focused: Bool
  private func apply() {
    let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard raw.isEmpty || raw.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { error = true; invalid(true); return }
    error = false; invalid(false); commit(raw.isEmpty ? nil : raw)
  }
  var body: some View {
    HStack { Text("Currency (optional)").font(.system(size: 10)); Spacer(); TextField("e.g. USD", text: $draft).focused($focused).textFieldStyle(.roundedBorder).foregroundStyle(error ? Palette.accent : Palette.ink).frame(width: 90).onSubmit(apply).onChange(of: focused) { _, focus in if !focus { apply() } } }
      .onAppear { draft = value ?? "" }.onChange(of: value) { _, _ in if !focused { draft = value ?? "" } }
      .onChange(of: reset) { _, _ in draft = value ?? ""; error = false; invalid(false) }
      .onReceive(NotificationCenter.default.publisher(for: .formCommitArtworkFields)) { _ in apply() }.onDisappear { invalid(false) }
  }
}

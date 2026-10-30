import AppKit
import FormCore
import SwiftUI

/// Native editing is a thin adapter to the same commands exposed to agents.
struct PaperAppearanceControls: View {
  @EnvironmentObject var store: StudioStore
  let object: ProductObject
  @State private var side: PaperFinishAssignment.Side = .outside
  @State private var kind: PaperFinishAssignment.Kind = .letterpress
  @State private var targets = Set<UUID>()
  private var current: ProductObject? { store.project?.objects.first { $0.id == object.id } }
  private var paper: PaperConstruction? { current.flatMap { try? PaperConstruction.definition(for: $0) } }
  private var unit: PhysicalUnit { PhysicalUnit(rawValue: store.project?.unit ?? "mm") ?? .mm }
  private var stockKey: String { "paper-stock-\(object.id)" }
  private var finishKey: String { "paper-finish-\(object.id)" }
  private var savedStocks: [FormCore.Material] { store.library.materials.filter { $0.paperStock != nil } }

  var body: some View {
    VStack(alignment: .leading, spacing: InspectorStyle.sectionSpacing) {
      if let paper, let current {
        stockControls(paper.stock)
        InspectorDivider()
        finishControls(paper, current: current)
        Text("Visual profiles and finish intent. Relief uses surface shading; press tooling, registration, bonding and physical prototypes remain unverified.")
          .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        if let project = store.project, let report = try? PaperAppearance.inspect(project: project, object: current) {
          ForEach(Array(report.issues.filter { ["missingFinishTargets", "missingFinishSide", "deepImpression"].contains($0.code) }.enumerated()), id: \.offset) { _, issue in
            Text(issue.message).font(InspectorStyle.captionFont).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }.disabled(current?.locked != false)
      .onChange(of: object.id) { _, _ in targets = [] }
      .accessibilityElement(children: .contain).accessibilityLabel("Paper stock and finishes")
  }
  private func stockControls(_ stock: PaperStock) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionLabel("STOCK & BONDED PLIES")
      Menu("Visual stock examples") {
        ForEach(Array(PaperAppearanceCommands.presets.enumerated()), id: \.offset) { _, preset in
          Button(preset.name) { attempt { try updateStock { $0 = preset } } }
        }
      }.menuStyle(.borderlessButton)
      if !savedStocks.isEmpty {
        Menu("Apply saved Lab stock") { ForEach(savedStocks) { material in
          Button(material.name) { attempt { try command("apply_stock", ["material_id": material.id]) } }
        }}.menuStyle(.borderlessButton)
      }
      Button("Save stock to Lab") { attempt { try command("save_stock") } }
        .accessibilityLabel("Save paper stock to Lab")
      ArtworkUnitField("Total caliper", value: stock.resolvedThicknessMM, unit: unit) { value in
        try updateStock { valueStock in
          guard valueStock.plies == nil else { throw FormError.invalid("Edit each bonded ply's caliper; the total is their sum.") }
          valueStock.thicknessMM = value
        }
      }.disabled(stock.plies != nil)
      let profile = stock.profile ?? PaperSurfaceProfile()
      Picker("Texture", selection: Binding(get: { profile.texture }, set: { texture in attempt { try updateProfile { $0.texture = texture } } })) {
        ForEach(PaperSurfaceProfile.Texture.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }.inspectorPicker().accessibilityLabel("Paper texture")
      InspectorColorPicker("Stock color", selection: Binding(get: { Color(nsColor: NSColor(hex: profile.color ?? "#F7F5EF")) }, set: { color in
        attempt { try updateProfile { $0.color = NSColor(color).hexString } }
      }), supportsOpacity: false, targetID: "paper-stock-color-\(object.id)", onEditingChanged: store.inspectorInteraction(stockKey))
      if current?.color != nil {
        Text("An instance tint overrides the paper face color.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
        Button("Clear tint · use stock colors") { attempt {
          _ = try store.engine.call("form_update_object", arguments: ["object_id": object.id.uuidString, "color": NSNull()], source: "Studio")
          store.changed()
        }}.accessibilityLabel("Clear paper color override")
      }
      slider("Roughness", value: profile.roughness, key: stockKey) { value in attempt { try updateProfile { $0.roughness = value } } }
      ArtworkUnitField("Texture scale", value: profile.textureScaleMM, unit: unit) { value in try updateProfile { $0.textureScaleMM = value } }
      ArtworkUnitField("Texture depth", value: profile.textureDepthMM, unit: unit) { value in try updateProfile { $0.textureDepthMM = value } }
      slider("Opacity", value: profile.opacity, key: stockKey) { value in attempt { try updateProfile { $0.opacity = value } } }
      ForEach(stock.plies ?? []) { ply in
        VStack(alignment: .leading, spacing: 8) {
          HStack { Text(ply.name).font(InspectorStyle.labelFont); Spacer(); Button("Remove", role: .destructive) { attempt { try updateStock { value in
            value.plies?.removeAll { $0.id == ply.id }; if value.plies?.isEmpty == true { value.plies = nil }
          } } } }
          ArtworkUnitField("Ply caliper", value: ply.thicknessMM, unit: unit) { amount in try updateStock { value in
            if let index = value.plies?.firstIndex(where: { $0.id == ply.id }) { value.plies![index].thicknessMM = amount }
          } }
          InspectorColorPicker("Ply color", selection: Binding(get: { Color(nsColor: NSColor(hex: ply.color)) }, set: { color in attempt { try updateStock { value in
            if let index = value.plies?.firstIndex(where: { $0.id == ply.id }) { value.plies![index].color = NSColor(color).hexString }
          } } }), supportsOpacity: false, targetID: "paper-ply-\(object.id)-\(ply.id)", onEditingChanged: store.inspectorInteraction(stockKey))
        }.padding(10).background(Palette.surface, in: RoundedRectangle(cornerRadius: InspectorStyle.moduleRadius))
      }
      Button("Add bonded ply") { attempt { try updateStock { value in
        if value.plies == nil { value.plies = [.init(name: "Back ply", color: value.profile?.color ?? "#F7F5EF", thicknessMM: value.thicknessMM)] }
        value.plies!.append(.init(name: "Front ply", color: "#F7F5EF", thicknessMM: 0.15))
      } } }.disabled((stock.plies?.count ?? 0) >= 16)
      Text("Plies are ordered back to front. Front/back artwork is a separate registration.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
    }
  }
  private func finishControls(_ paper: PaperConstruction, current: ProductObject) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionLabel("ARTWORK FINISHES")
      ForEach(paper.finishes ?? []) { finish in finishEditor(finish) }
      Picker("New finish", selection: $kind) { ForEach(PaperFinishAssignment.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.inspectorPicker()
      Picker("Artwork side", selection: $side) { Text("Outside / front").tag(PaperFinishAssignment.Side.outside); Text("Inside / back").tag(PaperFinishAssignment.Side.inside) }
        .inspectorPicker().onChange(of: side) { _, _ in targets = [] }
      targetMenu(side: side, selected: targets) { targets = $0 }
      Button("Use selected Canvas artwork") { targets = selectedTargets(side) }.disabled(selectedTargets(side).isEmpty)
      if side == .inside, let project = store.project, PaperAppearance.source(project: project, object: current, side: .inside).artwork == nil {
        Button("Create inside artwork") { attempt { try command("ensure_inside") } }
      }
      Button("Add artwork finish") { attempt { try addFinish() } }.disabled(targets.isEmpty)
        .accessibilityLabel("Add paper artwork finish")
    }
  }
  private func finishEditor(_ finish: PaperFinishAssignment) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack { Text(finish.name).font(.system(size: 11, weight: .medium)); Spacer(); Button("Remove", role: .destructive) { attempt { try command("remove_finish", ["finish_id": finish.id.uuidString]) } } }
      Toggle("Enabled", isOn: Binding(get: { finish.enabled }, set: { value in finishChange(finish, ["enabled": value]) })).inspectorToggle()
      Picker("Process", selection: Binding(get: { finish.kind }, set: { value in
        var patch: [String: Any] = ["kind": value.rawValue]
        if [.flatInk, .emboss, .screenPrint].contains(value) { patch["depthMM"] = 0.0 }
        if [.flatInk, .letterpress, .deboss].contains(value) { patch["heightMM"] = 0.0 }
        finishChange(finish, patch)
      })) { ForEach(PaperFinishAssignment.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.inspectorPicker()
      targetMenu(side: finish.side, selected: Set(finish.elementIDs)) { finishChange(finish, ["elementIDs": $0.map(\.uuidString).sorted()]) }
      if [.letterpress, .deboss, .foil].contains(finish.kind) {
        ArtworkUnitField("Impression depth", value: finish.depthMM, unit: unit) { try changeFinish(finish, ["depthMM": $0]) }
      }
      if [.emboss, .screenPrint, .foil].contains(finish.kind) {
        ArtworkUnitField("Raised height", value: finish.heightMM, unit: unit) { try changeFinish(finish, ["heightMM": $0]) }
      }
      InspectorColorPicker("Finish color", selection: Binding(get: { Color(nsColor: NSColor(hex: finish.color ?? "#B68C45")) }, set: { finishChange(finish, ["color": NSColor($0).hexString]) }), supportsOpacity: false,
        targetID: "paper-finish-color-\(object.id)-\(finish.id)", onEditingChanged: store.inspectorInteraction(finishKey))
      slider("Finish roughness", value: finish.roughness ?? (finish.kind == .foil ? 0.2 : 0.8), key: finishKey) { finishChange(finish, ["roughness": $0]) }
      slider("Metallic", value: finish.metallic ?? (finish.kind == .foil ? 1 : 0), key: finishKey) { finishChange(finish, ["metallic": $0]) }
      slider("Finish opacity", value: finish.opacity, key: finishKey) { finishChange(finish, ["opacity": $0]) }
    }.padding(10).background(Palette.surface, in: RoundedRectangle(cornerRadius: InspectorStyle.moduleRadius))
  }
  private func targetMenu(side: PaperFinishAssignment.Side, selected: Set<UUID>, set: @escaping (Set<UUID>) -> Void) -> some View {
    Menu("Artwork targets · \(selected.count)") {
      if let project = store.project, let current, let artwork = PaperAppearance.source(project: project, object: current, side: side).artwork {
        ForEach(Array(artwork.elements.prefix(200))) { element in
          Toggle(element.title.isEmpty ? element.kind : element.title, isOn: Binding(get: { selected.contains(element.id) }, set: { enabled in
            var value = selected; if enabled { value.insert(element.id) } else { value.remove(element.id) }; set(value)
          }))
        }
        if artwork.elements.count > 200 { Text("Select additional artwork directly on Canvas.") }
      } else { Text("Create artwork on this side first.") }
    }.menuStyle(.borderlessButton)
  }
  private func slider(_ title: String, value: Double, key: String, set: @escaping (Double) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)
      InspectorSlider(value: Binding(get: { value }, set: set), label: title, onEditingChanged: store.inspectorInteraction(key))
    }
  }
  private func selectedTargets(_ side: PaperFinishAssignment.Side) -> Set<UUID> {
    guard let project = store.project, let current else { return [] }
    let source = PaperAppearance.source(project: project, object: current, side: side)
    guard source.id == store.artworkSession.objectID else { return [] }
    return store.artworkSession.selection.intersection(Set(source.artwork?.elements.map(\.id) ?? []))
  }
  private func updateProfile(_ edit: (inout PaperSurfaceProfile) -> Void) throws {
    try updateStock { stock in var profile = stock.profile ?? .init(); edit(&profile); stock.profile = profile }
  }
  private func updateStock(_ edit: (inout PaperStock) throws -> Void) throws {
    guard let paper else { throw FormError.missing("Paper construction missing.") }
    var stock = paper.stock; try edit(&stock)
    if stock.plies != nil { stock.thicknessMM = stock.resolvedThicknessMM }
    var args: [String: Any] = ["stock": try jsonObject(stock)]
    if let authored = paper.authored, abs(try authored.number(authored.stockThickness) - stock.resolvedThicknessMM) > 1e-9 {
      let name = authored.stockThickness.expression.trimmingCharacters(in: .whitespacesAndNewlines)
      guard authored.parameters.contains(where: { $0.name == name }) else { throw FormError.invalid("Change this composed caliper expression's parameters in Function before applying the new stock.") }
      args["parameters"] = [name: stock.resolvedThicknessMM]
    }
    try command("configure", args)
  }
  private func addFinish() throws {
    var finish: [String: Any] = ["name": kind.rawValue, "kind": kind.rawValue, "side": side.rawValue, "elementIDs": targets.map(\.uuidString).sorted()]
    if [.letterpress, .deboss].contains(kind) { finish["depthMM"] = 0.05 }
    if kind == .emboss { finish["heightMM"] = 0.05 }
    if kind == .screenPrint { finish["heightMM"] = 0.015 }
    try command("set_finish", ["finish": finish])
  }
  private func finishChange(_ finish: PaperFinishAssignment, _ patch: [String: Any]) { attempt { try changeFinish(finish, patch) } }
  private func changeFinish(_ finish: PaperFinishAssignment, _ patch: [String: Any]) throws {
    try command("set_finish", ["finish": patch.merging(["id": finish.id.uuidString]) { _, new in new }])
  }
  private func command(_ name: String, _ args: [String: Any] = [:]) throws {
    _ = try store.engine.call("form_paper", arguments: args.merging(["command": name, "object_id": object.id.uuidString]) { _, new in new }, source: "Studio")
    if name == "save_stock" { store.library = StudioLibrary.load(from: store.repository.root) }
    else { store.changed() }
  }
  private func attempt(_ body: () throws -> Void) { do { try body() } catch { store.error = error.localizedDescription } }
}

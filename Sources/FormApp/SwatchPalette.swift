import AppKit
import FormCore
import FormGraphics
import SwiftUI

extension ArtworkSession {
  var backgroundColor: String {
    store?.project?.swatches?.first { $0.id == art.backgroundSwatchID }?.color ?? art.background
  }
  var fillSwatchReferences: Set<UUID?> {
    if let native = canvas?.textSwatchReferences() { return native }
    if elements.contains(where:{$0.storyFrame != nil}) {
      var seen=Set<UUID>()
      let sources=sourceTextElements.filter{seen.insert($0.id).inserted}
      return Artwork(elements:sources).fillSwatchReferences(for:Set(sources.map(\.id)))
    }
    return art.fillSwatchReferences(for: selection)
  }
  var inspectedFillSwatchID: UUID? {
    let refs = fillSwatchReferences
    return refs.count == 1 ? refs.first! : nil
  }
  @discardableResult func swatch(_ command: String, _ arguments: [String: Any] = [:]) -> Bool {
    guard let store else { return false }
    let target = arguments["target"] as? String ?? "fill"
    if ["assign", "detach"].contains(command), target == "fill", editingText {
      if command=="detach",fillSwatchReferences.contains(where:{store.project?.productionInk($0) != nil}) {
        store.error="Convert this production ink to RGB preview before detaching its paint link.";return false
      }
      let id = (arguments["swatch_id"] as? String).flatMap(UUID.init(uuidString:))
      let color = store.project?.swatches?.first { $0.id == id }?.color
      if canvas?.applyTextSwatch(command == "assign" ? id : nil, color: color) == true { return true }
    }
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
    canvas?.finishText()
    var args = arguments
    args["command"] = command
    if let objectID { args["object_id"] = objectID.uuidString }
    if args["element_ids"] == nil { args["element_ids"] = selection.map(\.uuidString) }
    do {
      try store.engine.call("form_swatch", arguments: args, source: "Studio")
      store.changed()
      return true
    } catch { store.error = error.localizedDescription; return false }
  }
  func studioPalette() {
    let values = [("Ink", "#263C64"), ("Vermilion", "#D45A37"), ("Warm white", "#EDE8DA"),
      ("Sage", "#849381"), ("Clay", "#B57860"), ("Butter", "#DCCB83")]
    canvas?.finishText()
    do {
      try store?.engine.call("form_batch", arguments: ["operations": values.map {
        ["name": "form_swatch", "arguments": ["command": "create", "name": $0.0, "color": $0.1]]
      }], source: "Studio")
      store?.changed()
    } catch { store?.error = error.localizedDescription }
  }
}

struct SwatchPicker: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  let target: String
  let swatchID: UUID?
  var stopID: UUID?
  var partID: UUID?
  var mixed = false
  var args: [String: Any] {
    var values: [String: Any] = ["target": target]
    if let stopID { values["stop_id"] = stopID.uuidString }
    if let partID { values["part_id"] = partID.uuidString }
    // A stop/part is an explicit property of the inspected object.
    if stopID != nil || partID != nil, let id = session.primary?.id { values["element_ids"] = [id.uuidString] }
    return values
  }
  var body: some View {
    Menu {
      Button("Local color · detach") { session.swatch("detach", args) }.disabled(swatchID == nil && !mixed)
      ForEach(store.project?.swatches ?? []) { value in
        Button(value.name + (value.id == swatchID ? " ✓" : "")) {
          var input = args
          input["swatch_id"] = value.id.uuidString
          session.swatch("assign", input)
        }
      }
      Divider()
      Button("Manage palette…") { session.showingPalette = true }
    } label: {
      Label(mixed ? "Mixed color sources" : store.project?.swatches?.first { $0.id == swatchID }?.name ?? "Local color", systemImage: "swatchpalette")
        .font(.system(size: 9)).foregroundStyle(Palette.secondary)
    }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
  }
}

struct SwatchPalette: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  @State private var name = ""
  @State private var color = "#D45A37"
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        SectionLabel("PROJECT PALETTE")
        Spacer()
        Text("sRGB preview / print inks").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary)
        AppCloseButton("Close project palette", keyEquivalent: "\u{1b}") { dismiss() }
      }
      InspectorDivider()
      if store.project?.swatches?.isEmpty != false {
        Text("Keep a collection's colors linked across artwork and products.")
          .font(.system(size: 12)).foregroundStyle(Palette.secondary)
        Button("Start with studio colors") { session.studioPalette() }
      }
      ScrollView {
        VStack(spacing: 12) {
          ForEach(store.project?.swatches ?? []) { value in
            VStack(alignment: .leading, spacing: 7) {
              HStack {
                InspectorColorPicker("Swatch color", selection: Binding(
                  get: { Color(nsColor: FormColor.color(value.color)) },
                  set: { session.swatch("update", ["swatch_id": value.id.uuidString,
                    "color": FormColor.hex(NSColor($0))]) }), supportsOpacity: false,
                  targetID: "swatch-\(store.project?.id.uuidString ?? "")-\(value.id)",
                  onEditingChanged: store.inspectorInteraction("swatch-\(value.id)")).labelsHidden().disabled(value.printInk != nil)
                SwatchTextField(title: "Swatch name", value: value.name) {
                  session.swatch("update", ["swatch_id": value.id.uuidString, "name": $0])
                }
                SwatchTextField(title: "HEX", value: value.color) {
                  session.swatch("update", ["swatch_id": value.id.uuidString, "color": $0])
                }.frame(width: 85).disabled(value.printInk != nil)
              }
              ProductionInkSwatchControls(session:session,swatch:value)
              HStack(spacing: 12) {
                Button("Apply fill") { session.swatch("assign", ["swatch_id": value.id.uuidString]) }
                  .disabled(session.selection.isEmpty)
                Button("Frame background") {
                  session.swatch("assign", ["swatch_id": value.id.uuidString, "target": "background"])
                }.disabled(session.object == nil)
                Spacer()
                Button("Delete") { session.swatch("delete", ["swatch_id": value.id.uuidString]) }
              }.font(.system(size: 9))
            }.padding(10).background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }.frame(maxHeight: 390)
      Divider()
      HStack {
        TextField("New color name", text: $name).textFieldStyle(.roundedBorder)
        TextField("HEX", text: $color).textFieldStyle(.roundedBorder).frame(width: 85)
        Button("Add") {
          if session.swatch("create", ["name": name, "color": color]) { name = "" }
        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      Text("RGB swatches preserve appearance when deleted. Used production inks require explicit conversion to RGB preview before detaching or deleting; Undo restores their intent.")
        .font(.system(size: 9)).foregroundStyle(Palette.secondary)
    }.padding(20).frame(width: 410).background(Palette.paper)
  }
}

private struct SwatchTextField: View {
  let title: String
  let value: String
  let onCommit: (String) -> Void
  @State private var draft = ""
  @State private var committed = ""
  @FocusState private var focused: Bool
  func commit() {
    guard draft != committed else { return }
    committed = draft
    onCommit(draft)
  }
  var body: some View {
    TextField(title, text: $draft).textFieldStyle(.roundedBorder).font(.system(size: 11)).focused($focused)
      .onAppear { draft = value; committed = value }
      .onSubmit { commit() }
      .onChange(of: focused) { _, active in if !active { commit() } }
      .onChange(of: value) { _, new in
        if !focused || draft == committed { draft = new; committed = new }
      }
      .onReceive(NotificationCenter.default.publisher(for: .formCommitArtworkFields)) { _ in commit() }
  }
}

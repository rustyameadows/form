import AppKit
import FormCore
import FormGraphics
import SwiftUI

extension ArtworkSession {
  var inspectedTextStyle: TextStyleReference? {
    canvas?.textInspection()?.textStyle ?? sourceTextElement?.textStyle
  }
  var textStyleReferences: Set<TextStyleReference?> {
    if let native = canvas?.textStyleReferences() { return native }
    var result = Set<TextStyleReference?>()
    for e in sourceTextElements where e.kind == "text" {
      result.formUnion((e.textRuns ?? []).map(\.textStyle))
      if (e.textRuns ?? []).reduce(0, { $0 + $1.length }) < e.text.utf16.count || e.text.isEmpty {
        result.insert(e.textStyle)
      }
    }
    return result
  }
  @discardableResult func textStyle(_ command: String, _ arguments: [String: Any] = [:]) -> Bool {
    guard let store else { return false }
    if ["assign", "reset", "detach"].contains(command), editingText {
      let id = (arguments["style_id"] as? String).flatMap(UUID.init(uuidString:))
      if canvas?.applyTextReference(command, styleID: id) == true { return true }
    }
    var args = arguments
    args["command"] = command
    if ["assign", "reset", "detach"].contains(command) {
      args["object_id"] = objectID?.uuidString
      args["element_ids"] = selection.map(\.uuidString)
    }
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
    canvas?.finishText()
    do {
      try store.engine.call("form_text_style", arguments: args, source: "Studio")
      store.changed()
      return true
    } catch { store.error = error.localizedDescription; return false }
  }
  @discardableResult func captureTextStyle(name: String, updating id: UUID? = nil) -> Bool {
    do {
      var args: [String: Any] = ["name": name, "font_size": inspectedSize,
        "typography": try jsonObject(inspectedTypography)]
      // Frame behavior and manual pair positions stay with their text object.
      var typography = args["typography"] as! [String: Any]
      for key in ["frameMode", "verticalAlignment", "pairKerning"] { typography.removeValue(forKey: key) }
      args["typography"] = typography
      if let id { args["style_id"] = id.uuidString; args["reset_selection"] = true }
      if let objectID, !selection.isEmpty {
        args["object_id"] = objectID.uuidString
        args["element_ids"] = selection.map(\.uuidString)
        if editingText, characterRange.length > 0 {
          args["location"] = characterRange.location; args["length"] = characterRange.length
        }
      }
      return textStyle(id == nil ? "create" : "update", args)
    } catch { store?.error = error.localizedDescription; return false }
  }
}

struct TextStylePicker: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  var label: String {
    let refs = session.textStyleReferences
    if refs.count > 1 { return "Mixed text styles" }
    guard let ref = refs.first ?? nil,
      let style = store.project?.textStyles?.first(where: { $0.id == ref.styleID }) else { return "No text style" }
    return style.name + (ref.overrides.isEmpty ? "" : " + overrides")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
    Menu {
      ForEach(store.project?.textStyles ?? []) { style in
        Button(style.name) { session.textStyle("assign", ["style_id": style.id.uuidString]) }
      }
      Divider()
      Button("Reset local overrides") { session.textStyle("reset") }
      Button("Detach text style") { session.textStyle("detach") }
      if let ref = session.inspectedTextStyle,
        let style = store.project?.textStyles?.first(where: { $0.id == ref.styleID }) {
        Button("Redefine \(style.name) from selection") { session.captureTextStyle(name: style.name, updating: style.id) }
      }
      Divider()
      Button("Manage text styles…") { session.showingTextStyles = true }
    } label: { Label(label, systemImage: "textformat.size").font(.system(size: 10)) }
      .menuStyle(.borderlessButton)
    if let ref = session.canvas?.textInspection()?.paragraphStyle ?? session.sourceTextElement?.paragraphStyle,
      let style = store.project?.textStyles?.first(where: { $0.id == ref.styleID }) {
      Text("Paragraph · \(style.name)").font(.system(size: 9)).foregroundStyle(Palette.secondary)
    }
    }
  }
}

struct TextStylesPanel: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var session: ArtworkSession
  @State private var name = ""
  var canCapture: Bool { session.primary?.kind == "text" }
  var canApply: Bool {
    let ids = session.art.swatchPaintTargets(for: session.selection)
    return session.art.elements.contains { ids.contains($0.id) && $0.kind == "text" }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack {
        SectionLabel("PROJECT TEXT STYLES")
        Spacer()
        Button("Done") {
          NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
          dismiss()
        }.keyboardShortcut(.cancelAction)
      }
      Text("One typographic language. Across every page and surface.")
        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
      ScrollView {
        VStack(spacing: 12) {
          ForEach(store.project?.textStyles ?? []) { style in
            VStack(alignment: .leading, spacing: 9) {
              TextStyleNameField(value: style.name) {
                session.textStyle("update", ["style_id": style.id.uuidString, "name": $0])
              }
              Text("Aa  Form  0123").font(Font(TypographyEngine.font(style.typography, size: 20)))
                .foregroundStyle(Palette.ink).lineLimit(1)
              if NSFont(name: style.typography.fontName, size: 12) == nil {
                Label("Missing font · \(style.typography.fontName)", systemImage: "exclamationmark.triangle")
                  .font(.system(size: 9)).foregroundStyle(Palette.accent)
              } else { Text(style.typography.fontName).font(.system(size: 9)).foregroundStyle(Palette.secondary) }
              HStack(spacing: 10) {
                ScalarArtworkField("Style size", value: style.fontSize, unit: "pt") {
                  session.textStyle("update", ["style_id": style.id.uuidString, "font_size": $0])
                }
                ScalarArtworkField("Style leading", value: style.typography.leading, unit: "pt") {
                  session.textStyle("update", ["style_id": style.id.uuidString, "typography": ["leading": $0]])
                }
              }
              HStack(spacing: 12) {
                Button("Apply") { session.textStyle("assign", ["style_id": style.id.uuidString]) }.disabled(!canApply)
                Button("Redefine from selection") { session.captureTextStyle(name: style.name, updating: style.id) }.disabled(!canCapture)
                Spacer()
                Button("Delete") { session.textStyle("delete", ["style_id": style.id.uuidString]) }
              }.font(.system(size: 9))
            }.padding(12).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }.frame(maxHeight: 410)
      Divider()
      HStack {
        TextField("New text style name", text: $name).textFieldStyle(.roundedBorder)
        Button("Create from selection") {
          if session.captureTextStyle(name: name) { name = "" }
        }.disabled(!canCapture || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      Text("Styles retain local overrides and color links. Reset follows the style again; detach or delete keeps the current appearance.")
        .font(.system(size: 9)).foregroundStyle(Palette.secondary)
    }.padding(20).frame(width: 430).background(Palette.paper)
  }
}

private struct TextStyleNameField: View {
  let value: String
  let commit: (String) -> Void
  @State private var draft = ""
  @State private var committed = ""
  @FocusState private var focused: Bool
  private func save() {
    guard draft != committed else { return }
    committed = draft; commit(draft)
  }
  var body: some View {
    TextField("Text style name", text: $draft).textFieldStyle(.roundedBorder).focused($focused)
      .onAppear { draft = value; committed = value }
      .onSubmit { save() }
      .onChange(of: focused) { _, active in if !active { save() } }
      .onChange(of: value) { _, new in if !focused || draft == committed { draft = new; committed = new } }
      .onReceive(NotificationCenter.default.publisher(for: .formCommitArtworkFields)) { _ in save() }
  }
}

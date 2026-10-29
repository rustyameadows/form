import AppKit
import FormCore
import SwiftUI

struct ComponentEditingContext {
  var objectID: UUID
  var linkedTargetID: UUID?
  var instanceID: UUID
}

extension ArtworkSession {
  func component(_ command: String, _ arguments: [String: Any] = [:]) {
    canvas?.finishText()
    guard let store, let object else { return }
    var args = arguments
    args["command"] = command
    args["object_id"] = object.id.uuidString
    args["element_ids"] = selection.map(\.uuidString)
    do {
      let result = try store.engine.call("form_component", arguments: args, source: "Studio") as? [String: Any]
      if let ids = result?["selected_elements"] as? [String] {
        choose(Set(ids.compactMap(UUID.init(uuidString:))))
      }
      store.changed()
    } catch { store.error = error.localizedDescription }
  }
  func editComponentSource(_ instance: ArtworkElement) {
    guard let sourceID = instance.component?.sourceObjectID, let objectID else { return }
    let context = ComponentEditingContext(objectID: objectID, linkedTargetID: linkedTargetID, instanceID: instance.id)
    let target = previewObject?.id
    activate(sourceID)
    componentReturn = context
    linkedTargetID = target == sourceID ? nil : target
    canvas?.fit(all: false)
  }
  func returnToComponent() {
    guard let context = componentReturn else { return }
    activate(context.objectID)
    linkedTargetID = context.linkedTargetID
    store?.select(context.linkedTargetID ?? context.objectID)
    choose([context.instanceID])
    componentReturn = nil
    canvas?.fit(all: false)
  }
  func overridePart(_ id: UUID, _ update: (inout ArtworkComponentOverride) -> Void) {
    guard let reference = primary?.component else { return }
    var values = reference.overrides ?? []
    var change = values.first { $0.elementID == id } ?? .init(elementID: id)
    update(&change)
    values.removeAll { $0.elementID == id }
    if change.color != nil || change.text != nil || change.opacity != nil { values.append(change) }
    do { component("override", ["overrides": try values.map { try jsonObject($0) }]) }
    catch { store?.error = error.localizedDescription }
  }
}

struct ComponentInspector: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  let element: ArtworkElement
  @State private var selectedPart: UUID?
  var reference: ArtworkComponentReference { element.component! }
  var source: ProductObject? { store.project?.objects.first { $0.id == reference.sourceObjectID } }
  var parts: [ArtworkElement] {
    guard let art = source?.artwork else { return [] }
    return store.project?.resolvingSwatches(in: art, keepingReferences: true).componentOverrideParts ?? []
  }
  var part: ArtworkElement? { parts.first { $0.id == selectedPart } ?? parts.first }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionLabel("LINKED COMPONENT")
      Text(source?.name ?? "Missing source").font(.system(size: 12, weight: .medium))
      HStack {
        Button("Edit source") { session.editComponentSource(element) }
        Button("Detach instance") { session.component("detach") }
      }.font(.system(size: 10))
      Text("Source edits update linked placements. Size, position, and overrides belong to this instance.")
        .font(.system(size: 9)).foregroundStyle(Palette.secondary)
      Toggle("Override all fills", isOn: Binding(
        get: { reference.color != nil },
        set: { session.component("override", ["color": $0 ? "#263C64" : NSNull()]) }))
      if let color = reference.color {
        InspectorColorPicker("Instance fill", selection: Binding(
          get: { Color(nsColor: NSColor(hex: color)) },
          set: { session.component("override", ["color": NSColor($0).hexString]) }), supportsOpacity: false,
          targetID: session.inspectorColorTarget("component-fill"), onEditingChanged: session.inspectorEditing)
        SwatchPicker(session: session, target: "fill", swatchID: reference.colorSwatchID)
      }
      if let part {
        Divider()
        Picker("Part", selection: Binding(get: { part.id }, set: { selectedPart = $0 })) {
          ForEach(parts) { Text($0.title).tag($0.id) }
        }
        let change = reference.overrides?.first { $0.elementID == part.id }
        Toggle("Override part fill", isOn: Binding(
          get: { change?.color != nil },
          set: { enabled in session.overridePart(part.id) {
            $0.color = enabled ? part.color : nil; $0.colorSwatchID = nil
          } }))
        if let color = change?.color {
          InspectorColorPicker("Part fill", selection: Binding(
            get: { Color(nsColor: NSColor(hex: color)) },
            set: { value in session.overridePart(part.id) {
              $0.color = NSColor(value).hexString; $0.colorSwatchID = nil
            } }), supportsOpacity: false, targetID: session.inspectorColorTarget("part-\(part.id)"), onEditingChanged: session.inspectorEditing)
          SwatchPicker(session: session, target: "component_part", swatchID: change?.colorSwatchID, partID: part.id)
        }
        if part.kind == "text" {
          Toggle("Override text", isOn: Binding(
            get: { change?.text != nil },
            set: { enabled in session.overridePart(part.id) { $0.text = enabled ? part.text : nil } }))
          if let text = change?.text {
            ComponentTextField(value: text) { value in session.overridePart(part.id) { $0.text = value } }
              .id(part.id)
          }
        }
        Toggle("Override part opacity", isOn: Binding(
          get: { change?.opacity != nil },
          set: { enabled in session.overridePart(part.id) { $0.opacity = enabled ? part.opacity ?? 1 : nil } }))
        if let opacity = change?.opacity {
          ScalarArtworkField("Part opacity", value: opacity * 100, unit: "%") { value in
            session.overridePart(part.id) { $0.opacity = min(1, max(0, value / 100)) }
          }
        }
      }
      if reference.color != nil || reference.overrides?.isEmpty == false {
        Button("Reset appearance and text overrides") { session.component("reset") }
      }
    }.font(.system(size: 10))
  }
}

private struct ComponentTextField: View {
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
    TextField("Text override", text: $draft).textFieldStyle(InspectorTextFieldStyle()).focused($focused)
      .onSubmit { commit() }
      .onAppear { draft = value; committed = value }
      .onChange(of: focused) { _, active in if !active { commit() } }
      .onChange(of: value) { _, new in
        if !focused || draft == committed { draft = new; committed = new }
      }
      .onReceive(NotificationCenter.default.publisher(for: .formCommitArtworkFields)) { _ in commit() }
  }
}

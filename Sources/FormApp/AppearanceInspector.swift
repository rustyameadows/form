import AppKit
import FormCore
import SwiftUI

extension ArtworkSession {
  func appearance(_ values: [String: Any] = [:], reset: Bool = false) {
    guard let store, let objectID, !selection.isEmpty else { return }
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
    canvas?.finishText()
    do {
      try store.engine.call("form_appearance", arguments: [
        "command": reset ? "reset" : "update", "object_id": objectID.uuidString,
        "element_ids": selection.map(\.uuidString), "values": values,
      ], source: "Studio")
      store.changed()
    } catch { store.error = error.localizedDescription }
  }
}

struct AppearanceInspector: View {
  @ObservedObject var session: ArtworkSession
  let element: ArtworkElement
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Blend", selection: Binding(get: { element.blendMode ?? "normal" },
        set: { session.appearance(["blend_mode": $0]) })) {
        ForEach(AppearanceCommands.blendModes, id: \.self) { mode in
          Text(mode.replacingOccurrences(of: "-", with: " ").capitalized).tag(mode)
        }
      }.font(.system(size: 10))
      if element.kind == "group" {
        Toggle("Isolate blending", isOn: Binding(get: { element.isolatedBlending == true },
          set: { session.appearance(["isolate": $0]) }))
          .inspectorToggle().font(.system(size: 10))
          .help("Blend children with each other before compositing this group. Opacity and layer blur also isolate a group.")
      }
      DisclosureGroup("Effects") {
        VStack(alignment: .leading, spacing: 12) {
          if let stack=element.effectStack {
            ArtworkEffectStackInspector(session:session,element:element,stack:stack)
          } else {
          Toggle("Blur", isOn: Binding(get: { element.blur?.enabled == true },
            set: { session.appearance(["blur": ["enabled": $0]]) }))
            .inspectorToggle()
          if let blur = element.blur {
            ArtworkUnitField("Blur radius", value: blur.radius, unit: session.unit) {
              session.appearance(["blur": ["radius": $0]])
            }.disabled(!blur.enabled)
          }
          Divider()
          Toggle("Drop shadow", isOn: Binding(get: { element.shadow?.enabled == true },
            set: { session.appearance(["shadow": ["enabled": $0]]) }))
            .inspectorToggle()
          if let shadow = element.shadow {
            VStack(alignment: .leading, spacing: 10) {
              HStack {
                ArtworkUnitField("Offset X", value: shadow.offset.x, unit: session.unit) {
                  session.appearance(["shadow": ["x": $0]])
                }
                ArtworkUnitField("Offset Y", value: shadow.offset.y, unit: session.unit) {
                  session.appearance(["shadow": ["y": $0]])
                }
              }
              ArtworkUnitField("Shadow blur", value: shadow.blur, unit: session.unit) {
                session.appearance(["shadow": ["blur": $0]])
              }
              InspectorColorPicker("Shadow color", selection: Binding(
                get: { Color(nsColor: NSColor(hex: shadow.color)) },
                set: { session.appearance(["shadow": ["color": NSColor($0).hexString]]) }),
                supportsOpacity: false, targetID: session.inspectorColorTarget("shadow"), onEditingChanged: session.inspectorEditing)
              SwatchPicker(session: session, target: "shadow", swatchID: shadow.swatchID)
              ScalarArtworkField("Shadow opacity", value: shadow.opacity * 100, unit: "%") {
                session.appearance(["shadow": ["opacity": $0 / 100]])
              }
            }.disabled(!shadow.enabled)
          }
          }
          Text("Effects remain editable. A group's opacity and effects apply to the whole group.")
            .font(.system(size: 9)).foregroundStyle(Palette.secondary)
          Button("Reset appearance") { session.appearance(reset: true) }
            .help("Restore full opacity, normal blending, and no effects.")
        }.font(.system(size: 10)).padding(.top, 8)
      }.font(.system(size: 10))
    }
  }
}

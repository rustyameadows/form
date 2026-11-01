import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct MaskEditingContext {
  var maskID: UUID
  var targets: Set<UUID>
  var scope: UUID?
  var tool:ArtworkTool = .select
}

extension ArtworkSession {
  func paint(_ command: String = "update", _ values: [String: Any] = [:]) {
    guard let store, let objectID, !selection.isEmpty else { return }
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
    canvas?.finishText()
    var args = values
    args["object_id"] = objectID.uuidString
    args["element_ids"] = selection.map(\.uuidString)
    args["command"] = command
    do {
      let result =
        try store.engine.call("form_edit_paint", arguments: args, source: "Studio")
        as? [String: Any]
      if let stop = result?["selected_stop"] as? String {
        selectedGradientStopID = UUID(uuidString: stop)
      }
      store.changed()
    } catch { store.error = error.localizedDescription }
  }
  func editMask(_ id: UUID) {
    guard let mask = art.elements.first(where: { $0.id == id }),!art.isLocked(mask),
      art.elements.contains(where:{$0.clipID==id}) else { return }
    canvas?.prepareForGroupNavigation()
    canvas?.finishText()
    let targets = Set(art.elements.filter { $0.clipID == id }.map(\.id))
    let priorScope = mask.parentID
    let priorTool=tool
    choose([id])
    scopeID = mask.parentID
    tool = mask.kind == "group" ? .select:.direct
    maskEditing = .init(maskID: id, targets: targets, scope: priorScope,tool:priorTool)
    canvas?.synchronize()
    canvas?.window?.makeFirstResponder(canvas)
  }
  func returnFromMask() {
    guard let context = maskEditing else { return }
    canvas?.prepareForGroupNavigation();canvas?.finishText();endGesture()
    maskEditing = nil
    scopeID = context.scope
    choose(context.targets.intersection(Set(art.elements.map(\.id))))
    tool=context.tool;canvas?.synchronize()
    canvas?.window?.makeFirstResponder(canvas)
  }
  func convertMaskToPath() {
    guard var context = maskEditing else { return }
    convert("shape")
    if let id = selection.first, id != context.maskID {
      context.maskID = id
      maskEditing = context
    }
    canvas?.window?.makeFirstResponder(canvas)
  }
}

struct StrokeInspector: View {
  @ObservedObject var session: ArtworkSession
  let element: ArtworkElement
  var stroke: ArtworkStroke {
    element.stroke ?? .init(color: element.kind == "line" ? element.color : "#292D2C")
  }
  func patch(_ values: [String: Any]) { session.paint("update", ["stroke": values]) }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(
        "Stroke",
        isOn: Binding(
          get: { element.visibleStroke != nil },
          set: { patch(["enabled": $0, "width": $0 && stroke.width == 0 ? 0.5 : stroke.width]) })
      )
      .inspectorToggle()
      if element.stroke != nil || element.kind == "line" {
        HStack {
          ArtworkUnitField("Stroke width", value: stroke.width, unit: session.unit) {
            patch(["width": $0])
          }
          InspectorColorPicker(
            "Stroke color",
            selection: Binding(
              get: { Color(nsColor: NSColor(hex: stroke.color)) },
              set: { patch(["color": NSColor($0).hexString]) }), supportsOpacity: false,
            targetID: session.inspectorColorTarget("stroke"), onEditingChanged: session.inspectorEditing
          ).labelsHidden()
        }
        SwatchPicker(session: session, target: "stroke", swatchID: stroke.swatchID)
        ScalarArtworkField("Stroke opacity", value: (stroke.opacity ?? 1) * 100, unit: "%") {
          patch(["opacity": $0 / 100])
        }
        Picker(
          "Alignment",
          selection: Binding(
            get: { stroke.alignment ?? "center" }, set: { patch(["alignment": $0]) })
        ) {
          Text("Center").tag("center")
          Text("Inside").tag("inside").disabled(!element.supportsAlignedStroke)
          Text("Outside").tag("outside").disabled(!element.supportsAlignedStroke)
        }.help("Inside and outside require closed vector geometry.")
        HStack {
          Picker(
            "Cap", selection: Binding(get: { stroke.cap ?? "butt" }, set: { patch(["cap": $0]) })
          ) {
            Text("Butt").tag("butt")
            Text("Round").tag("round")
            Text("Square").tag("square")
          }
          Picker(
            "Join",
            selection: Binding(get: { stroke.join ?? "miter" }, set: { patch(["join": $0]) })
          ) {
            Text("Miter").tag("miter")
            Text("Round").tag("round")
            Text("Bevel").tag("bevel")
          }
        }
        if (stroke.join ?? "miter") == "miter" {
          ScalarArtworkField("Miter limit", value: stroke.miter ?? 10) { patch(["miter": $0]) }
        }
        StrokePatternField(session: session, stroke: stroke)
        HStack {
          Button("Solid") { patch(["dash": NSNull()]) }
          Button("Dashed") { patch(["dash": [3, 2]]) }
          Button("Dotted") { patch(["dash": [0, 2], "cap": "round"]) }
        }.buttonStyle(.borderless)
        if stroke.dash?.isEmpty == false {
          ArtworkUnitField("Dash phase", value: stroke.dashOffset ?? 0, unit: session.unit) {
            patch(["dash_offset": $0])
          }
        }
        Button("Outline stroke") { session.convert("stroke") }.disabled(
          element.visibleStroke == nil
        )
        .help(
          "Preserve the fill and convert the stroke into editable paths. The original stays as a hidden layer."
        )
      }
    }.font(.system(size: 10))
  }
}

private struct StrokePatternField: View {
  @ObservedObject var session: ArtworkSession
  let stroke: ArtworkStroke
  @State private var draft = ""
  @State private var error: String?
  @State private var committed = ""
  @FocusState private var focused: Bool
  var formatted: String {
    (stroke.dash ?? []).map {
      ($0 / session.unit.millimeters).formatted(
        .number.precision(.fractionLength(0...4)).grouping(.never))
    }.joined(separator: ", ")
  }
  func commit() {
    guard draft != committed else { return }
    do {
      let pattern = try StrokePattern.parse(draft, unit: session.unit)
      committed = draft
      error = nil
      session.paint("update", ["stroke": ["dash": pattern as Any? ?? NSNull()]])
    } catch { self.error = error.localizedDescription }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      TextField("Dash / gap lengths (\(session.unit.rawValue))", text: $draft)
        .textFieldStyle(InspectorTextFieldStyle()).focused($focused)
        .onSubmit { commit() }.onChange(of: focused) { _, value in if !value { commit() } }
        .onAppear {
          draft = formatted
          committed = draft
        }
        .onChange(of: formatted) { _, value in
          if !focused || draft == committed {
            draft = value
            committed = value
          }
        }.onReceive(NotificationCenter.default.publisher(for: .formCommitArtworkFields)) { _ in
          commit()
        }
      if let error {
        Text(error).foregroundStyle(Palette.accent)
      } else {
        Text("Comma-separated dash / gap lengths. Blank is solid.").foregroundStyle(
          Palette.secondary)
      }
    }.font(.system(size: 9))
  }
}

struct GradientInspector: View {
  @ObservedObject var session: ArtworkSession
  let element: ArtworkElement
  @State private var expanded = true
  func patch(_ values: [String: Any]) { session.paint("update", ["gradient": values]) }
  var body: some View {
    DisclosureGroup("Gradient", isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 10) {
        Toggle(
          "Use gradient",
          isOn: Binding(
            get: { element.gradient != nil },
            set: {
              session.paint("update", ["gradient": $0 ? [String: Any]() : NSNull()])
            })
        ).inspectorToggle()
        if let gradient = element.gradient {
          Picker("Type", selection: Binding(get: { gradient.kind }, set: { patch(["kind": $0]) })) {
            Text("Linear").tag("linear")
            Text("Radial").tag("radial")
            Text("Angular").tag("angular")
            Text("Diamond").tag("diamond")
          }
          HStack {
            ScalarArtworkField("Start X", value: gradient.start.x * 100, unit: "%") {
              patch(["start": ["x": $0 / 100]])
            }
            ScalarArtworkField("Y", value: gradient.start.y * 100, unit: "%") {
              patch(["start": ["y": $0 / 100]])
            }
          }
          HStack {
            ScalarArtworkField("End X", value: gradient.end.x * 100, unit: "%") {
              patch(["end": ["x": $0 / 100]])
            }
            ScalarArtworkField("Y", value: gradient.end.y * 100, unit: "%") {
              patch(["end": ["y": $0 / 100]])
            }
          }
          if gradient.transform != nil {
            Button("Reset gradient transform") { patch(["transform": NSNull()]) }
          }
          if session.selection.count == 1 {
            ForEach(Array(gradient.stops.enumerated()), id: \.element.id) { index, stop in
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Button("Stop \(index+1)") {
                    session.selectedGradientStopID = stop.id
                    session.canvas?.window?.makeFirstResponder(session.canvas)
                  }.foregroundStyle(
                    session.selectedGradientStopID == stop.id ? Palette.accent : Palette.ink)
                  Spacer()
                  InspectorColorPicker(
                    "Stop \(index+1) color",
                    selection: Binding(
                      get: { Color(nsColor: NSColor(hex: stop.color)) },
                      set: {
                        session.paint(
                          "update_stop",
                          ["stop_id": stop.id.uuidString, "color": NSColor($0).hexString])
                      }), supportsOpacity: false,
                    targetID: session.inspectorColorTarget("gradient-\(stop.id)"), onEditingChanged: session.inspectorEditing
                  ).labelsHidden()
                  Button {
                    session.paint("delete_stop", ["stop_id": stop.id.uuidString])
                  } label: {
                    Image(systemName: "minus.circle")
                  }.help("Remove stop \(index+1)").accessibilityLabel("Remove stop \(index+1)")
                    .disabled(gradient.stops.count <= 2)
                }
                ScalarArtworkField("Stop \(index+1) position", value: stop.offset * 100, unit: "%")
                {
                  session.paint("update_stop", ["stop_id": stop.id.uuidString, "offset": $0 / 100])
                }
                ScalarArtworkField(
                  "Stop \(index+1) opacity", value: (stop.opacity ?? 1) * 100, unit: "%"
                ) {
                  session.paint(
                    "update_stop", ["stop_id": stop.id.uuidString, "opacity": $0 / 100])
                }
                SwatchPicker(
                  session: session, target: "gradient_stop", swatchID: stop.swatchID,
                  stopID: stop.id)
              }.padding(7).background(
                session.selectedGradientStopID == stop.id
                  ? Palette.accent.opacity(0.06) : Color.clear
              )
              .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            HStack {
              Button("Add color stop") { session.paint("add_stop") }.disabled(
                gradient.stops.count >= 32)
              Button("Reverse") { session.paint("reverse_stops") }
            }
          } else {
            Text("Select one object to edit individual stops.").foregroundStyle(Palette.secondary)
          }
          Text(
            "Drag the gradient axis and color stops on the canvas. Double-click the axis to add a stop."
          )
          .font(.system(size: 9)).foregroundStyle(Palette.secondary)
        }
      }.padding(.top, 8)
    }.font(.system(size: 10))
  }
}

struct MaskInspector: View {
  @ObservedObject var session: ArtworkSession
  let element: ArtworkElement
  var body: some View {
    if let mask = element.clipID {
      VStack(alignment: .leading, spacing: 8) {
        SectionLabel("CLIPPING MASK")
        HStack {
          Button("Edit mask") { session.editMask(mask) }
          Button("Release mask") { session.execute("release_clip") }
        }
      }.font(.system(size: 10))
    }
    if session.art.elements.contains(where: { $0.clipID == element.id }) {
      VStack(alignment: .leading, spacing: 8) {
        SectionLabel(session.art.isCoverageMask(element.id) ? "MASK CONTENT":"MASK GEOMETRY")
        Text(session.art.isCoverageMask(element.id)
          ? "Edit shapes, paint, opacity and effects to change the mask. Enter a group to edit its children."
          : "Edit the shape or its nodes. Its paint does not affect the clipped artwork.")
          .foregroundStyle(Palette.secondary)
        if session.maskEditing == nil {
          Button(session.art.isCoverageMask(element.id) ? "Edit mask contents":"Edit mask geometry") { session.editMask(element.id) }
        } else {
          if ["rectangle", "ellipse", "polygon", "star"].contains(element.kind) {
            Button("Convert mask to path") { session.convertMaskToPath() }
          }
          Button("Back to contents") { session.returnFromMask() }
        }
      }.font(.system(size: 10))
    }
  }
}

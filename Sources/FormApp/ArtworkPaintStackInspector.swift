import AppKit
import FormCore
import FormGraphics
import SwiftUI

extension ArtworkSession {
  /// Read the current source after committing fields, so editing one paint never
  /// restores a stale snapshot of a different paint or another selected layer.
  func editPaintStack(elementID: UUID, structural: Bool = false,
    _ edit: (inout [ArtworkPaintLayer]) throws -> Void) {
    guard let store, let objectID, selection == [elementID] else { return }
    if structural {
      InspectorColorPanelController.shared.close()
      NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
    }
    canvas?.finishText()
    guard selection == [elementID],
      let current = sourceArtwork.elements.first(where: { $0.id == elementID }),
      current.storyFrame == nil else { return }
    var stack = ArtworkPaintEditing.stack(for: colored(current))
    if structural { store.engine.endInteraction() }
    defer { if structural { store.engine.endInteraction() } }
    do {
      try edit(&stack)
      var candidate = current; candidate.paintStack = stack
      try ArtworkPaintValidation.validate(candidate)
      let value = try JSONSerialization.jsonObject(with: JSONEncoder.form.encode(stack))
      try store.engine.call("form_edit_paint", arguments: ["object_id": objectID.uuidString,
        "element_ids": [elementID.uuidString], "command": "update", "paint_stack": value], source: "Studio")
      store.changed()
    } catch { store.error = error.localizedDescription }
  }
}

enum ArtworkPaintEditing {
  static func stack(for element: ArtworkElement) -> [ArtworkPaintLayer] {
    if let stack = element.paintStack { return stack }
    var stack: [ArtworkPaintLayer] = []
    if element.kind != "line", element.fillEnabled != false {
      stack.append(.init(.init(kind: element.gradient == nil ? "solid" : "gradient",
        color: element.color, opacity: element.fillOpacity ?? 1, gradient: element.gradient)))
    }
    if let stroke = element.visibleStroke { stack.append(.init(.init(color: stroke.color), stroke: stroke)) }
    return stack
  }
}

enum ArtworkPaintPlacement {
  enum Parameter { case offsetX, offsetY, scaleX, scaleY, rotation, skew }
  struct Components {
    var scaleX: Double, scaleY: Double, rotation: Double, skew: Double
  }
  /// QR decomposition in physical frame coordinates. Conjugating by the frame
  /// dimensions makes a 45° rotation remain 45° on a non-square layer.
  static func components(of transform: Affine2, frame: Point2) -> Components {
    let ratio = frame.x > 0 && frame.y > 0 ? frame.y / frame.x : 1
    let a = transform.a, b = transform.b * ratio, c = transform.c / ratio, d = transform.d
    let x = hypot(a, b), y = (a * d - b * c) / x
    return .init(scaleX: x, scaleY: y, rotation: atan2(b, a) * 180 / .pi,
      skew: atan((a * c + b * d) / (x * y)) * 180 / .pi)
  }
  static func setting(_ transform: Affine2, frame: Point2, parameter: Parameter, value: Double) -> Affine2 {
    if parameter == .offsetX { var result = transform; result.tx = value; return result }
    if parameter == .offsetY { var result = transform; result.ty = value; return result }
    var components = components(of: transform, frame: frame)
    switch parameter {
    case .scaleX: components.scaleX = value
    case .scaleY: components.scaleY = value
    case .rotation: components.rotation = value
    case .skew: components.skew = value
    case .offsetX, .offsetY: break
    }
    let angle = components.rotation * .pi / 180, shear = tan(components.skew * .pi / 180)
    let cosine = cos(angle), sine = sin(angle)
    let ratio = frame.x > 0 && frame.y > 0 ? frame.y / frame.x : 1
    return .init(a: cosine * components.scaleX, b: sine * components.scaleX / ratio,
      c: (cosine * shear - sine) * components.scaleY * ratio,
      d: (sine * shear + cosine) * components.scaleY, tx: transform.tx, ty: transform.ty)
  }
  static func transform(filling: Bool, width: Double, height: Double, sourceAspect: Double) -> Affine2 {
    guard width > 0, height > 0, sourceAspect > 0 else { return .init() }
    let ratio = sourceAspect / (width / height)
    let x = filling ? max(1, ratio) : min(1, ratio)
    let y = filling ? max(1, 1 / ratio) : min(1, 1 / ratio)
    return .init(a: x, d: y, tx: (1 - x) / 2, ty: (1 - y) / 2)
  }
}

struct ArtworkPaintStackInspector: View {
  @ObservedObject var session: ArtworkSession
  let element: ArtworkElement
  private var stack: [ArtworkPaintLayer] { ArtworkPaintEditing.stack(for: element) }
  private var imageAssets: [String] {
    var names = session.art.renderedAssetNames
    if let asset = stack.first(where: { $0.paint.kind == "image" })?.paint.asset { names.insert(asset) }
    return names.filter { ["png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "webp", "heic", "heif"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }.sorted()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(element.kind == "text" ? "Base text paints" : "Paints").font(InspectorStyle.labelFont)
      if element.textRuns?.contains(where: { $0.paintStack != nil }) == true {
        Text("Styled character ranges keep their own paints. Select characters on the canvas to change their color.")
          .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      }
      if element.storyFrame != nil {
        Text("Edit paints on the shared text story source.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      }
      ForEach(Array(stack.indices.reversed()), id: \.self) { index in
        ArtworkPaintRow(session: session, element: element, index: index,
          layer: stack[index], count: stack.count, imageAssets: imageAssets)
        InspectorDivider()
      }
      HStack {
        Menu("Add fill") {
          Button("Solid color") { add(.init()) }
          Button("Gradient") { add(.init(kind: "gradient", gradient: .init())) }
          Menu("Image") {
            ForEach(imageAssets, id: \.self) { asset in
              Button(asset) { add(.init(kind: "image", asset: asset)) }
            }
          }.disabled(imageAssets.isEmpty)
        }.accessibilityIdentifier("paint-stack-add-fill")
        Button("Add stroke") { add(.init(), stroke: .init()) }
          .accessibilityIdentifier("paint-stack-add-stroke")
      }.disabled(stack.count >= 16)
      if stack.isEmpty { Text("No paints").foregroundStyle(Palette.secondary) }
      Text("Top paints appear in front.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
    }.font(InspectorStyle.labelFont).disabled(element.storyFrame != nil)
  }
  private func add(_ paint: ArtworkPaint, stroke: ArtworkStroke? = nil) {
    session.editPaintStack(elementID: element.id, structural: true) {
      guard $0.count < 16 else { return }; $0.append(.init(paint, stroke: stroke))
    }
  }
}

private struct ArtworkPaintRow: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  let element: ArtworkElement
  let index: Int
  let layer: ArtworkPaintLayer
  let count: Int
  let imageAssets: [String]
  @State private var expanded = true
  private var title: String { "\(layer.stroke == nil ? "Fill" : "Stroke") \(index + 1)" }
  private var enabled: Bool { layer.enabled && layer.stroke?.enabled != false }
  private var colorEditing: (Bool) -> Void {
    store.inspectorInteraction("paint-\(session.objectID?.uuidString ?? "")-\(element.id)")
  }
  private func update(_ edit: (inout ArtworkPaintLayer) -> Void) {
    session.editPaintStack(elementID: element.id) {
      guard $0.indices.contains(index) else { return }; edit(&$0[index])
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Toggle(title, isOn: .init(get: { enabled }, set: { value in
          update { $0.enabled = value; if value { $0.stroke?.enabled = true } }
        })).inspectorToggle().accessibilityIdentifier("paint-\(index)-enabled")
        Spacer(minLength: 0)
        Button { move(1) } label: { Image(systemName: "arrow.up") }
          .disabled(index == count - 1).help("Move \(title.lowercased()) forward")
          .accessibilityLabel("Move \(title.lowercased()) forward").accessibilityIdentifier("paint-\(index)-forward")
        Button { move(-1) } label: { Image(systemName: "arrow.down") }
          .disabled(index == 0).help("Move \(title.lowercased()) backward")
          .accessibilityLabel("Move \(title.lowercased()) backward").accessibilityIdentifier("paint-\(index)-backward")
        Button {
          session.editPaintStack(elementID: element.id, structural: true) {
            if $0.indices.contains(index) { $0.remove(at: index) }
          }
        } label: { Image(systemName: "minus.circle") }
          .help("Remove \(title.lowercased())").accessibilityLabel("Remove \(title.lowercased())")
          .accessibilityIdentifier("paint-\(index)-remove")
      }.buttonStyle(.borderless)
      DisclosureGroup("\(layer.paint.kind.capitalized) settings", isExpanded: $expanded) {
        VStack(alignment: .leading, spacing: 9) {
          Picker("Paint", selection: .init(get: { layer.paint.kind }, set: changeKind)) {
            Text("Solid").tag("solid"); Text("Gradient").tag("gradient")
            Text("Image").tag("image").disabled(imageAssets.isEmpty)
          }
          if layer.paint.kind == "solid" { solidControls }
          if layer.paint.kind == "gradient", let gradient = layer.paint.gradient {
            ArtworkStackGradientControls(session: session, elementID: element.id, index: index,
              gradient: gradient, frameSize: .init(element.width, element.height))
          }
          if layer.paint.kind == "image" { imageControls }
          ScalarArtworkField("Paint opacity", value: layer.paint.opacity * 100, unit: "%") {
            value in update { $0.paint.opacity = value / 100 }
          }
          Picker("Paint blend", selection: .init(get: { layer.paint.blendMode ?? "normal" }, set: { value in
            update { $0.paint.blendMode = value == "normal" ? nil : value }
          })) {
            ForEach(AppearanceCommands.blendModes, id: \.self) {
              Text($0.replacingOccurrences(of: "-", with: " ").capitalized).tag($0)
            }
          }
          if let stroke = layer.stroke {
            ArtworkStackStrokeControls(session: session, element: element, index: index, stroke: stroke)
          }
        }.padding(.top, 7).disabled(!enabled)
      }
    }
  }
  private var solidControls: some View {
    VStack(alignment: .leading, spacing: 7) {
      InspectorColorPicker("\(title) color", selection: .init(get: { Color(nsColor: NSColor(hex: layer.paint.color)) },
        set: { value in update { $0.paint.color = NSColor(value).hexString } }), supportsOpacity: false,
        targetID: session.inspectorColorTarget("paint-\(index)"), onEditingChanged: colorEditing)
      Menu("Use palette color…") {
        ForEach(store.project?.swatches ?? []) { swatch in
          Button(swatch.name) { update { $0.paint.color = swatch.color } }.disabled(swatch.printInk != nil)
        }
        Divider(); Button("Manage palette…") { session.showingPalette = true }
      }.help("Copies an RGB palette color into this paint.").menuStyle(.borderlessButton)
    }
  }
  private var imageControls: some View {
    VStack(alignment: .leading, spacing: 9) {
      Picker("Image asset", selection: .init(get: { layer.paint.asset ?? "" }, set: { value in update { $0.paint.asset = value } })) {
        ForEach(imageAssets, id: \.self) { Text($0).tag($0) }
      }
      HStack {
        Button("Fill") { placeImage(filling: true) }
        Button("Fit") { placeImage(filling: false) }
        Button("Reset placement") { update { $0.paint.imageTransform = nil } }
      }.buttonStyle(.borderless)
      Toggle("Repeat image", isOn: .init(get: { layer.paint.imageRepeat == true }, set: { value in update { $0.paint.imageRepeat = value } })).inspectorToggle()
      ArtworkPaintTransformControls(title: "Image placement", transform: layer.paint.imageTransform ?? .init(),
        frameSize: .init(element.width, element.height), update: { parameter, value in
          update { $0.paint.imageTransform = ArtworkPaintPlacement.setting($0.paint.imageTransform ?? .init(),
            frame: .init(element.width, element.height), parameter: parameter, value: value) }
        })
      DisclosureGroup("Image adjustments") {
        VStack(spacing: 8) {
          ScalarArtworkField("Brightness", value: (layer.paint.imageAdjustments?.brightness ?? 0) * 100, unit: "%") { value in
            update { var a = $0.paint.imageAdjustments ?? .init(); a.brightness = value / 100; $0.paint.imageAdjustments = a }
          }
          ScalarArtworkField("Contrast", value: (layer.paint.imageAdjustments?.contrast ?? 1) * 100, unit: "%") { value in
            update { var a = $0.paint.imageAdjustments ?? .init(); a.contrast = value / 100; $0.paint.imageAdjustments = a }
          }
          ScalarArtworkField("Saturation", value: (layer.paint.imageAdjustments?.saturation ?? 1) * 100, unit: "%") { value in
            update { var a = $0.paint.imageAdjustments ?? .init(); a.saturation = value / 100; $0.paint.imageAdjustments = a }
          }
          Button("Reset adjustments") { update { $0.paint.imageAdjustments = nil } }
        }
      }
    }
  }
  private func placeImage(filling: Bool) {
    guard let asset = layer.paint.asset,
      let info = try? ImageRenderer.info(session.assets.appendingPathComponent(asset)) else { return }
    update { $0.paint.imageTransform = ArtworkPaintPlacement.transform(filling: filling,
      width: element.width, height: element.height, sourceAspect: info.aspect); $0.paint.imageRepeat = false }
  }
  private func changeKind(_ kind: String) {
    update { layer in
      let old = layer.paint
      layer.paint = .init(kind: kind, color: old.color, opacity: old.opacity, blendMode: old.blendMode,
        gradient: kind == "gradient" ? old.gradient ?? .init() : nil,
        asset: kind == "image" ? old.asset ?? imageAssets.first : nil,
        imageTransform: kind == "image" ? old.imageTransform : nil,
        imageAdjustments: kind == "image" ? old.imageAdjustments : nil,
        imageRepeat: kind == "image" ? old.imageRepeat : nil)
    }
  }
  private func move(_ delta: Int) {
    session.editPaintStack(elementID: element.id, structural: true) {
      guard $0.indices.contains(index), $0.indices.contains(index + delta) else { return }
      $0.swapAt(index, index + delta)
    }
  }
}

private struct ArtworkPaintTransformControls: View {
  let title: String
  let transform: Affine2
  let frameSize: Point2
  let update: (ArtworkPaintPlacement.Parameter, Double) -> Void
  private var components: ArtworkPaintPlacement.Components { ArtworkPaintPlacement.components(of: transform, frame: frameSize) }
  var body: some View {
    DisclosureGroup(title) {
      VStack(spacing: 8) {
        HStack {
          ScalarArtworkField("Offset X", value: transform.tx * 100, unit: "%") { update(.offsetX, $0 / 100) }
          ScalarArtworkField("Offset Y", value: transform.ty * 100, unit: "%") { update(.offsetY, $0 / 100) }
        }
        HStack {
          ScalarArtworkField("Scale X", value: components.scaleX * 100, unit: "%") { update(.scaleX, $0 / 100) }
          ScalarArtworkField("Scale Y", value: components.scaleY * 100, unit: "%") { update(.scaleY, $0 / 100) }
        }
        HStack {
          ScalarArtworkField("Rotation", value: components.rotation, unit: "°") { update(.rotation, $0) }
          ScalarArtworkField("Skew", value: components.skew, unit: "°") { value in
            guard abs(value) < 89.9 else { throw FormError.invalid("Use a skew angle between −89.9° and 89.9°.") }
            update(.skew, value)
          }
        }
      }.padding(.top, 7)
    }
  }
}

private struct ArtworkStackGradientControls: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  let elementID: UUID
  let index: Int
  let gradient: ArtworkGradient
  let frameSize: Point2
  private func edit(_ action: (inout ArtworkGradient) -> Void) {
    session.editPaintStack(elementID: elementID) { stack in
      guard stack.indices.contains(index), var value = stack[index].paint.gradient else { return }
      action(&value); value.sortStops(); stack[index].paint.gradient = value
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Picker("Gradient type", selection: .init(get: { gradient.kind }, set: { kind in edit { $0.kind = kind } })) {
        ForEach(["linear", "radial", "angular", "diamond"], id: \.self) { Text($0.capitalized).tag($0) }
      }
      HStack {
        ScalarArtworkField("Start X", value: gradient.start.x * 100, unit: "%") { value in edit { $0.start.x = value / 100 } }
        ScalarArtworkField("Start Y", value: gradient.start.y * 100, unit: "%") { value in edit { $0.start.y = value / 100 } }
      }
      HStack {
        ScalarArtworkField("End X", value: gradient.end.x * 100, unit: "%") { value in edit { $0.end.x = value / 100 } }
        ScalarArtworkField("End Y", value: gradient.end.y * 100, unit: "%") { value in edit { $0.end.y = value / 100 } }
      }
      if let transform = gradient.transform {
        ArtworkPaintTransformControls(title: "Gradient transform", transform: transform, frameSize: frameSize,
          update: { parameter, value in edit { $0.transform = ArtworkPaintPlacement.setting($0.transform ?? .init(),
            frame: frameSize, parameter: parameter, value: value) } })
        Button("Reset gradient transform") { edit { $0.transform = nil } }
      }
      ForEach(gradient.stops) { stop in
        VStack(spacing: 7) {
          HStack {
            InspectorColorPicker("Gradient stop color", selection: .init(get: { Color(nsColor: NSColor(hex: stop.color)) },
              set: { color in stopEdit(stop.id) { $0.color = NSColor(color).hexString; $0.swatchID = nil } }),
              supportsOpacity: false, targetID: session.inspectorColorTarget("paint-\(index)-stop-\(stop.id)"),
              onEditingChanged: store.inspectorInteraction("paint-\(session.objectID?.uuidString ?? "")-\(elementID)"))
            Button { edit { $0.stops.removeAll { $0.id == stop.id } } } label: { Image(systemName: "minus.circle") }
              .disabled(gradient.stops.count <= 2).help("Remove gradient stop").accessibilityLabel("Remove gradient stop")
          }
          HStack {
            ScalarArtworkField("Position", value: stop.offset * 100, unit: "%") { value in stopEdit(stop.id) { $0.offset = value / 100 } }
            ScalarArtworkField("Stop opacity", value: (stop.opacity ?? 1) * 100, unit: "%") { value in stopEdit(stop.id) { $0.opacity = value / 100 } }
          }
        }
      }
      HStack {
        Button("Add stop") {
          edit { value in
            let positions = [0.0] + value.stops.map(\.offset) + [1.0]
            let interval = zip(positions, positions.dropFirst()).max { $0.1 - $0.0 < $1.1 - $1.0 }
            value.stops.append(value.sampledStop(at: interval.map { ($0.0 + $0.1) / 2 } ?? 0.5))
          }
        }.disabled(gradient.stops.count >= 256)
        Button("Reverse") { edit { $0.stops.reverse(); for i in $0.stops.indices { $0.stops[i].offset = 1 - $0.stops[i].offset } } }
      }.buttonStyle(.borderless)
    }
  }
  private func stopEdit(_ id: UUID, _ action: (inout GradientStop) -> Void) {
    edit { value in if let i = value.stops.firstIndex(where: { $0.id == id }) { action(&value.stops[i]) } }
  }
}

private struct ArtworkStackStrokeControls: View {
  @ObservedObject var session: ArtworkSession
  let element: ArtworkElement
  let index: Int
  let stroke: ArtworkStroke
  private func edit(_ action: (inout ArtworkStroke) -> Void) {
    session.editPaintStack(elementID: element.id) { stack in
      guard stack.indices.contains(index), var value = stack[index].stroke else { return }
      action(&value); stack[index].stroke = value
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ArtworkUnitField("Stroke width", value: stroke.width, unit: session.unit) { value in edit { $0.width = value } }
      Picker("Stroke alignment", selection: .init(get: { stroke.alignment ?? "center" }, set: { value in edit { $0.alignment = value } })) {
        Text("Center").tag("center")
        Text("Inside").tag("inside").disabled(element.kind != "text" && !element.supportsAlignedStroke)
        Text("Outside").tag("outside").disabled(element.kind != "text" && !element.supportsAlignedStroke)
      }
      HStack {
        Picker("Cap", selection: .init(get: { stroke.cap ?? "butt" }, set: { value in edit { $0.cap = value } })) {
          Text("Butt").tag("butt"); Text("Round").tag("round"); Text("Square").tag("square")
        }
        Picker("Join", selection: .init(get: { stroke.join ?? "miter" }, set: { value in edit { $0.join = value } })) {
          Text("Miter").tag("miter"); Text("Round").tag("round"); Text("Bevel").tag("bevel")
        }
      }
      if (stroke.join ?? "miter") == "miter" {
        ScalarArtworkField("Miter limit", value: stroke.miter ?? 10) { value in edit { $0.miter = value } }
      }
      ArtworkPaintDashField(stroke: stroke, unit: session.unit, update: { dash in edit { $0.dash = dash } })
      HStack {
        Button("Solid") { edit { $0.dash = nil } }
        Button("Dashed") { edit { $0.dash = [3, 2] } }
        Button("Dotted") { edit { $0.dash = [0, 2]; $0.cap = "round" } }
      }.buttonStyle(.borderless)
      if stroke.dash?.isEmpty == false {
        ArtworkUnitField("Dash phase", value: stroke.dashOffset ?? 0, unit: session.unit) { value in edit { $0.dashOffset = value } }
      }
      if let opacity = stroke.opacity, opacity != 1 {
        ScalarArtworkField("Stroke opacity", value: opacity * 100, unit: "%") { value in edit { $0.opacity = value / 100 } }
      }
    }
  }
}

private struct ArtworkPaintDashField: View {
  let stroke: ArtworkStroke
  let unit: PhysicalUnit
  let update: ([Double]?) -> Void
  @State private var draft = ""
  @State private var committed = ""
  @State private var error: String?
  @FocusState private var focused: Bool
  private var formatted: String {
    (stroke.dash ?? []).map { ($0 / unit.millimeters).formatted(.number.precision(.fractionLength(0...4)).grouping(.never)) }.joined(separator: ", ")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      TextField("Dash / gap lengths (\(unit.rawValue))", text: $draft).textFieldStyle(InspectorTextFieldStyle())
        .focused($focused).onSubmit(commit).onChange(of: focused) { _, value in if !value { commit() } }
        .onAppear { draft = formatted; committed = draft }
        .onChange(of: formatted) { _, value in if !focused || draft == committed { draft = value; committed = value } }
        .onReceive(NotificationCenter.default.publisher(for: .formCommitArtworkFields)) { _ in commit() }
      if let error { Text(error).foregroundStyle(Palette.accent) }
    }
  }
  private func commit() {
    guard draft != committed else { return }
    do { let dash = try StrokePattern.parse(draft, unit: unit); committed = draft; error = nil; update(dash) }
    catch { self.error = error.localizedDescription }
  }
}

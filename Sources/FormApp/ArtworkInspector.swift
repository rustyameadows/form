import AppKit
import FormCore
import FormGraphics
import SwiftUI

extension Notification.Name {
  static let formCommitArtworkFields = Notification.Name("studio.form.commitArtworkFields")
}

struct ArtworkUnitField: View {
  let title: String, value: Double, unit: PhysicalUnit, onCommit: (Double) -> Void
  init(_ title: String, value: Double, unit: PhysicalUnit, _ onCommit: @escaping (Double) -> Void) {
    self.title = title
    self.value = value
    self.unit = unit
    self.onCommit = onCommit
  }
  var body: some View {
    ArtworkInput(
      title: title, value: value / unit.millimeters, suffix: unit.rawValue,
      parser: { try unit.parse($0) / unit.millimeters }
    ) { onCommit($0 * unit.millimeters) }
  }
}
struct ScalarArtworkField: View {
  let title: String, value: Double, unit: String, onCommit: (Double) -> Void
  init(_ title: String, value: Double, unit: String = "", _ onCommit: @escaping (Double) -> Void) {
    self.title = title
    self.value = value
    self.unit = unit
    self.onCommit = onCommit
  }
  var body: some View {
    ArtworkInput(
      title: title, value: value, suffix: unit,
      parser: {
        guard let value = Double($0), value.isFinite else {
          throw FormError.invalid("Enter a finite number.")
        }
        return value
      }, onCommit: onCommit)
  }
}
private struct ArtworkInput: View {
  let title: String, value: Double, suffix: String, parser: (String) throws -> Double,
    onCommit: (Double) -> Void
  @State private var draft = ""
  @State private var error = false
  @State private var lastCommitted = ""
  @FocusState private var focused: Bool
  func formatted() -> String {
    value.formatted(.number.precision(.fractionLength(0...4)).grouping(.never))
  }
  func commit() {
    guard draft != lastCommitted else { return }
    do {
      onCommit(try parser(draft))
      error = false
      lastCommitted = draft
    } catch { self.error = true }
  }
  var body: some View {
    HStack(spacing: 5) {
      Text(title).foregroundStyle(Palette.secondary)
      Spacer(minLength: 2)
      TextField(title, text: $draft).multilineTextAlignment(.trailing).textFieldStyle(
        .roundedBorder
      ).frame(minWidth: 40, maxWidth: 77).focused($focused).foregroundStyle(
        error ? Palette.accent : Palette.ink
      ).onSubmit { commit() }.onChange(of: focused) { _, focus in
        if !focus {
          commit()
          if !error {
            draft = formatted()
            lastCommitted = draft
          }
        }
      }.onAppear {
        draft = formatted()
        lastCommitted = draft
      }.onChange(of: value) { _, _ in
        if !focused || draft == lastCommitted {
          draft = formatted()
          lastCommitted = draft
          error = false
        }
      }
      .onChange(of: suffix) { _, _ in
        if !focused {
          draft = formatted()
          lastCommitted = draft
          error = false
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .formCommitArtworkFields)) { _ in
        commit()
      }
      if !suffix.isEmpty { Text(suffix).foregroundStyle(Palette.secondary).fixedSize() }
    }.font(.system(size: 10))
  }
}

struct ArtworkInspector: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  var e: ArtworkElement? { session.primary }
  var type: Typography { session.inspectedTypography }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 17) {
        if let object = session.object {
          if session.preview, let project = store.project {
            HStack {
              SectionLabel("LIVE OBJECT")
              Spacer()
              Image(systemName: "link").foregroundStyle(Palette.accent)
            }
            ObjectPreview(
              object: session.previewObject ?? object, project: project, assets: session.assets
            ).frame(
              height: 155
            ).clipped()
            if let target = session.previewObject, session.linkedTargetID != nil {
              Text("Editing \(object.name) · linked to \(target.name)")
                .font(.system(size: 9)).foregroundStyle(Palette.secondary)
            }
          }
          if let e {
            HStack {
              SectionLabel(
                session.elements.count > 1
                  ? "\(session.elements.count) OBJECTS" : e.kind.uppercased())
              Spacer()
              if session.editingText {
                Text("CHARACTERS").font(.system(size: 7, weight: .semibold)).foregroundStyle(
                  Palette.accent)
              }
            }
            if session.elements.count == 1 {
              TextField(
                "Layer name",
                text: Binding(get: { e.title }, set: { name in session.update { $0.name = name } })
              ).font(.system(size: 15, design: .serif)).textFieldStyle(.plain)
            }
            transformControls
            Divider()
            if e.kind == "text" || session.elements.allSatisfy({ $0.kind == "text" }) {
              if session.elements.count == 1 {
                Button(session.editingText ? "Finish text editing" : "Edit text on canvas") {
                  if session.editingText {
                    session.canvas?.finishText()
                    session.canvas?.window?.makeFirstResponder(session.canvas)
                  } else {
                    session.canvas?.beginText(e)
                  }
                }.font(.system(size: 10))
              }
              typographyControls
              Divider()
            }
            appearanceControls
            if e.kind == "rectangle" {
              ArtworkUnitField("Corner radius", value: e.cornerRadius ?? 0, unit: session.unit) {
                v in session.update { $0.cornerRadius = max(0, v) }
              }
            }
            if ["polygon", "star"].contains(e.kind) {
              Stepper(
                "\(e.kind=="star" ? "Points":"Sides"): \(e.sides ?? 5)",
                value: Binding(
                  get: { e.sides ?? 5 }, set: { v in session.update { $0.sides = v } }), in: 3...100
              ).font(.system(size: 10))
              if e.kind == "star" {
                ScalarArtworkField("Inner radius", value: (e.starInset ?? 0.45) * 100, unit: "%") {
                  v in session.update { $0.starInset = min(1, max(0.01, v / 100)) }
                }
              }
            }
            if e.kind == "path" { pathControls.disabled(session.selection.count != 1) }
            if e.kind == "image" { imageControls(e) }
            Divider()
            HStack {
              IconButton("Bring forward", symbol: "square.3.layers.3d.top.filled") {
                session.execute("reorder", ["mode": "forward"])
              }
              IconButton("Send backward", symbol: "square.3.layers.3d.bottom.filled") {
                session.execute("reorder", ["mode": "backward"])
              }
              Spacer()
              Button("Duplicate") { session.execute("duplicate") }
              Button("Delete") { session.execute("delete") }
            }.font(.system(size: 9))
            DisclosureGroup("Production role") {
              Picker(
                "Role",
                selection: Binding(
                  get: { e.productionRole ?? "artwork" },
                  set: { role in session.update { $0.productionRole = role } })
              ) {
                ForEach(["artwork", "cut", "score", "stitch", "engrave", "guide"], id: \.self) {
                  Text($0.capitalized).tag($0)
                }
              }.labelsHidden()
              Text("Construction roles stay separate from printable artwork.").font(
                .system(size: 9)
              ).foregroundStyle(Palette.secondary)
            }.font(.system(size: 10))
          } else {
            frameControls(object)
          }
        } else {
          Text("Create an artwork frame to begin.").font(.system(size: 12)).foregroundStyle(
            Palette.secondary)
        }
      }.padding(18)
    }.background(Palette.paper).disabled(session.elements.contains { session.art.isLocked($0) })
  }
  @ViewBuilder var transformControls: some View {
    if let b = session.selectionBounds {
      HStack(spacing: 12) {
        ArtworkUnitField("X", value: b.x, unit: session.unit) { session.transformBounds(x: $0) }
        ArtworkUnitField("Y", value: b.y, unit: session.unit) { session.transformBounds(y: $0) }
      }
      HStack(spacing: 12) {
        ArtworkUnitField("W", value: b.width, unit: session.unit) {
          if $0 > 0 { session.transformBounds(width: $0) }
        }
        ArtworkUnitField("H", value: b.height, unit: session.unit) {
          if $0 > 0 { session.transformBounds(height: $0) }
        }
      }
      HStack {
        ScalarArtworkField(
          "Rotation",
          value: e.map {
            let t = session.art.worldTransform($0)
            return atan2(t.b, t.a) * 180 / .pi
          } ?? 0, unit: "°"
        ) { value in
          let t = session.art.worldTransform(e!)
          session.rotate(value - atan2(t.b, t.a) * 180 / .pi)
        }
        IconButton(
          "Flip horizontally", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        ) { session.execute("flip", ["axis": "x"]) }
        IconButton(
          "Flip vertically", symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down"
        ) { session.execute("flip", ["axis": "y"]) }
      }
      if session.elements.count > 1 {
        HStack(spacing: 0) {
          ForEach(
            [
              ("left", "align.horizontal.left"), ("center_x", "align.horizontal.center"),
              ("right", "align.horizontal.right"), ("top", "align.vertical.top"),
              ("center_y", "align.vertical.center"), ("bottom", "align.vertical.bottom"),
            ], id: \.0
          ) { item in
            IconButton("Align \(item.0)", symbol: item.1) {
              session.execute("align", ["mode": item.0])
            }
          }
        }
        HStack {
          Button("Space ↔") { session.execute("distribute", ["mode": "horizontal"]) }
          Button("Space ↕") { session.execute("distribute", ["mode": "vertical"]) }
          Spacer()
          Button("Group") { session.execute("group") }
        }.font(.system(size: 9))
        Menu("Combine paths") {
          Button("Union") { session.boolean("union") }
          Button("Subtract") { session.boolean("subtract") }
          Button("Intersect") { session.boolean("intersect") }
          Button("Exclude") { session.boolean("exclude") }
        }
        Button("Use bottom shape as clipping mask") { session.makeMask() }.buttonStyle(.plain).font(
          .system(size: 10)
        ).foregroundStyle(Palette.accent)
      }
      if e?.kind == "group" {
        HStack {
          Button("Edit group") {
            session.scopeID = e?.id
            session.choose([])
          }
          Button("Ungroup") { session.execute("ungroup") }
        }.font(.system(size: 10))
      }
    }
  }
  var typographyControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionLabel("TYPOGRAPHY")
      FontBrowserButton(session: session)
      if let font = NSFont(name: type.fontName, size: 12), let family = font.familyName {
        Picker(
          "Style",
          selection: Binding(
            get: { type.fontName }, set: { name in session.typography { $0.fontName = name } })
        ) {
          ForEach(FontCatalog.faces(family), id: \.name) { face in Text(face.style).tag(face.name) }
        }.labelsHidden().font(.system(size: 11))
      } else {
        Label(
          "Missing: \(type.fontName). Choose a replacement above.",
          systemImage: "exclamationmark.triangle"
        ).font(.system(size: 10)).foregroundStyle(Palette.accent)
      }
      HStack(spacing: 10) {
        ScalarArtworkField("Size", value: session.inspectedSize, unit: "pt") {
          session.typeSize(max(0.1, $0))
        }
        ScalarArtworkField("Leading", value: type.leading, unit: "pt") { v in
          session.typography { $0.leading = max(0, v) }
        }
      }
      HStack(spacing: 10) {
        ScalarArtworkField("Tracking", value: type.tracking, unit: "pt") { v in
          session.typography { $0.tracking = v }
        }
        ScalarArtworkField("Baseline", value: type.baseline, unit: "pt") { v in
          session.typography { $0.baseline = v }
        }
      }
      Picker(
        "Alignment",
        selection: Binding(
          get: { type.alignment }, set: { v in session.typography { $0.alignment = v } })
      ) {
        Text("Left").tag("left")
        Text("Center").tag("center")
        Text("Right").tag("right")
        Text("Justify").tag("justified")
      }.labelsHidden().pickerStyle(.segmented).font(.system(size: 9))
      HStack {
        Toggle(
          "Underline",
          isOn: Binding(
            get: { type.underline }, set: { v in session.typography { $0.underline = v } }))
        Toggle(
          "Strike",
          isOn: Binding(
            get: { type.strikethrough }, set: { v in session.typography { $0.strikethrough = v } }))
      }.toggleStyle(.checkbox).font(.system(size: 10))
      Picker(
        "Text frame",
        selection: Binding(
          get: { type.frameMode }, set: { v in session.typography { $0.frameMode = v } })
      ) {
        Text("Area text · wraps").tag("area")
        Text("Point text · grows").tag("point")
      }.font(.system(size: 10))
      if session.editingText {
        Text("Selected characters keep their own fonts, sizes, colors, and spacing.").font(
          .system(size: 9)
        ).foregroundStyle(Palette.secondary)
        ScalarArtworkField("Pair kerning", value: type.tracking, unit: "pt") {
          session.manualKerning($0)
        }
      }
      if let e, TypographyEngine.overflows(e) {
        Label("Text overflows this frame.", systemImage: "plus.app").font(.system(size: 10))
          .foregroundStyle(Palette.accent)
      }
      DisclosureGroup("Paragraph & character settings") {
        VStack(spacing: 10) {
          ScalarArtworkField("Word spacing", value: type.wordSpacing, unit: "pt") { v in
            session.typography { $0.wordSpacing = v }
          }
          ScalarArtworkField("Character width", value: type.horizontalScale, unit: "%") { v in
            session.typography { $0.horizontalScale = min(1000, max(1, v)) }
          }
          ScalarArtworkField("Space before", value: type.paragraphBefore, unit: "pt") { v in
            session.typography { $0.paragraphBefore = v }
          }
          ScalarArtworkField("Space after", value: type.paragraphAfter, unit: "pt") { v in
            session.typography { $0.paragraphAfter = v }
          }
          ScalarArtworkField("Left indent", value: type.leftIndent, unit: "pt") { v in
            session.typography { $0.leftIndent = v }
          }
          ScalarArtworkField("Right indent", value: type.rightIndent, unit: "pt") { v in
            session.typography { $0.rightIndent = v }
          }
          ScalarArtworkField("First line", value: type.firstLineIndent, unit: "pt") { v in
            session.typography { $0.firstLineIndent = v }
          }
          Picker(
            "Vertical",
            selection: Binding(
              get: { session.primary?.typography?.verticalAlignment ?? "top" },
              set: { v in
                session.canvas?.finishText()
                session.typography { $0.verticalAlignment = v }
              })
          ) {
            Text("Top").tag("top")
            Text("Middle").tag("middle")
            Text("Bottom").tag("bottom")
          }
          Picker(
            "Direction",
            selection: Binding(
              get: { type.direction }, set: { v in session.typography { $0.direction = v } })
          ) {
            Text("Automatic").tag("natural")
            Text("Left to right").tag("ltr")
            Text("Right to left").tag("rtl")
          }
        }
      }.font(.system(size: 10))
      FontFeaturesInspector(session: session)
      Button("Convert to editable outlines") {
        session.canvas?.finishText()
        session.convert()
      }.font(.system(size: 10)).help("The original editable text is retained as a hidden layer.")
    }
  }
  var appearanceControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionLabel("APPEARANCE")
      if let e {
        if e.kind != "image", e.kind != "group" {
          HStack {
            Toggle(
              "Fill",
              isOn: Binding(
                get: { e.fillEnabled != false }, set: { v in session.update { $0.fillEnabled = v } }
              )
            ).toggleStyle(.checkbox)
            Spacer()
            ColorPicker(
              "Fill color",
              selection: Binding(
                get: { Color(nsColor: FormColor.color(session.inspectedColor)) },
                set: { session.textColor(FormColor.hex(NSColor($0))) }), supportsOpacity: false
            ).labelsHidden()
          }.font(.system(size: 10))
        }
        ScalarArtworkField("Opacity", value: (e.opacity ?? 1) * 100, unit: "%") { v in
          session.update { $0.opacity = min(1, max(0, v / 100)) }
        }
        if !["text", "image", "group"].contains(e.kind) {
          Toggle(
            "Stroke",
            isOn: Binding(
              get: { e.stroke != nil },
              set: { v in session.update { $0.stroke = v ? .init() : nil } })
          ).font(.system(size: 10)).toggleStyle(.checkbox)
          if let stroke = e.stroke {
            HStack {
              ArtworkUnitField("Width", value: stroke.width, unit: session.unit) { v in
                session.update { $0.stroke?.width = max(0, v) }
              }
              ColorPicker(
                "Stroke color",
                selection: Binding(
                  get: { Color(nsColor: FormColor.color(stroke.color)) },
                  set: { color in
                    session.update { $0.stroke?.color = FormColor.hex(NSColor(color)) }
                  }), supportsOpacity: false
              ).labelsHidden()
            }
            HStack {
              Picker(
                "Cap",
                selection: Binding(
                  get: { stroke.cap ?? "butt" }, set: { v in session.update { $0.stroke?.cap = v } }
                )
              ) {
                Text("Butt").tag("butt")
                Text("Round").tag("round")
                Text("Square").tag("square")
              }
              Picker(
                "Join",
                selection: Binding(
                  get: { stroke.join ?? "miter" },
                  set: { v in session.update { $0.stroke?.join = v } })
              ) {
                Text("Miter").tag("miter")
                Text("Round").tag("round")
                Text("Bevel").tag("bevel")
              }
            }.labelsHidden().font(.system(size: 9))
            Toggle(
              "Dashed",
              isOn: Binding(
                get: { !(stroke.dash ?? []).isEmpty },
                set: { v in session.update { $0.stroke?.dash = v ? [3, 2] : nil } })
            ).font(.system(size: 10)).toggleStyle(.checkbox)
            if let dash = stroke.dash, !dash.isEmpty {
              HStack {
                ArtworkUnitField("Dash", value: dash[0], unit: session.unit) { v in
                  session.update {
                    $0.stroke?.dash = [max(0.01, v), dash.count > 1 ? dash[1] : dash[0]]
                  }
                }
                ArtworkUnitField(
                  "Gap", value: dash.count > 1 ? dash[1] : dash[0], unit: session.unit
                ) { v in session.update { $0.stroke?.dash = [dash[0], max(0.01, v)] } }
              }
            }
            Button("Outline stroke") { session.convert("stroke") }.font(.system(size: 10))
          }
          DisclosureGroup("Gradient") {
            Toggle(
              "Use gradient",
              isOn: Binding(
                get: { e.gradient != nil },
                set: { v in session.update { $0.gradient = v ? .init() : nil } })
            ).font(.system(size: 10)).toggleStyle(.checkbox)
            if let g = e.gradient {
              Picker(
                "Type",
                selection: Binding(
                  get: { g.kind }, set: { v in session.update { $0.gradient?.kind = v } })
              ) {
                Text("Linear").tag("linear")
                Text("Radial").tag("radial")
              }.labelsHidden()
              ForEach(Array(g.stops.enumerated()), id: \.element.id) { index, stop in
                HStack {
                  ColorPicker(
                    "Stop",
                    selection: Binding(
                      get: { Color(nsColor: FormColor.color(stop.color)) },
                      set: { color in
                        session.update {
                          $0.gradient?.stops[index].color = FormColor.hex(NSColor(color))
                        }
                      }), supportsOpacity: false
                  ).labelsHidden()
                  ScalarArtworkField("Position", value: stop.offset * 100, unit: "%") { v in
                    session.update { e in
                      e.gradient?.stops[index].offset = min(1, max(0, v / 100))
                      e.gradient?.stops.sort { $0.offset < $1.offset }
                    }
                  }
                }
              }
              Button("Add color stop") {
                session.update { e in
                  e.gradient?.stops.append(.init(0.5, e.color))
                  e.gradient?.stops.sort { $0.offset < $1.offset }
                }
              }.font(.system(size: 10))
              Text("Drag the gradient's start and end handles on the canvas.").font(
                .system(size: 9)
              ).foregroundStyle(Palette.secondary)
            }
          }.font(.system(size: 10))
        }
        if e.clipID != nil {
          Button("Release clipping mask") { session.update { $0.clipID = nil } }.font(
            .system(size: 10))
        }
      }
    }
  }
  var pathControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
      SectionLabel("PATH NODES")
      HStack {
        Button("Direct select") {
          session.tool = .direct
          session.canvas?.window?.makeFirstResponder(session.canvas)
        }
        Button("Corner") { session.editPath("corner") }.disabled(session.nodes.isEmpty)
        Button("Smooth") { session.editPath("smooth") }.disabled(session.nodes.isEmpty)
      }.font(.system(size: 9))
      if let e, let path = e.path {
        Text(
          "\(path.contours.reduce(0){$0+$1.nodes.count}) nodes · \(session.nodes.count) selected"
        ).font(.system(size: 9)).foregroundStyle(Palette.secondary)
        if let bounds = session.nodeBounds {
          HStack(spacing: 10) {
            ArtworkUnitField("Node X", value: bounds.x, unit: session.unit) { x in
              session.transformNodes(.translation(x - bounds.x, 0))
            }
            ArtworkUnitField("Node Y", value: bounds.y, unit: session.unit) { y in
              session.transformNodes(.translation(0, y - bounds.y))
            }
          }
          if session.nodes.count > 1 {
            HStack(spacing: 10) {
              ArtworkUnitField("Span W", value: bounds.width, unit: session.unit) {
                session.sizeNodes(width: $0)
              }
              ArtworkUnitField("Span H", value: bounds.height, unit: session.unit) {
                session.sizeNodes(height: $0)
              }
            }
            ScalarArtworkField("Rotate nodes by", value: 0, unit: "°") { angle in
              session.transformNodes(
                .translation(bounds.center.x, bounds.center.y).followed(by: .rotation(angle))
                  .followed(by: .translation(-bounds.center.x, -bounds.center.y)))
            }
          }
          HStack {
            Button("Insert midpoint") { session.editPath("insert") }.disabled(
              session.nodes.count != 1)
            Button("Split") { session.editPath("split") }.disabled(session.nodes.count != 1)
            Button("Join") { session.editPath("join") }.disabled(session.nodes.count != 2)
          }.font(.system(size: 9))
          HStack {
            Button("Symmetric") { session.editPath("symmetric") }
            Button("Delete nodes") { session.editPath("delete") }
          }.font(.system(size: 9))
        }
        HStack {
          Button("Reverse direction") { session.editPath("reverse") }
          Button("Select all nodes") {
            session.tool = .direct
            session.nodes = Set(path.contours.flatMap(\.nodes).map(\.id))
            session.canvas?.window?.makeFirstResponder(session.canvas)
          }
        }.font(.system(size: 9))
        Toggle(
          "Closed contours",
          isOn: Binding(
            get: { path.contours.allSatisfy(\.closed) },
            set: { value in
              session.editPath(value ? "close" : "open")
            })
        ).font(.system(size: 10)).toggleStyle(.checkbox)
      }
    }
  }
  @ViewBuilder func imageControls(_ e: ArtworkElement) -> some View {
    if let name = e.asset,
      let image = NSImage(contentsOf: session.assets.appendingPathComponent(name)),
      let rep = image.representations.first
    {
      Text(
        "\(rep.pixelsWide) × \(rep.pixelsHigh) px · \(Int(Double(rep.pixelsWide)/(e.width/25.4))) effective DPI"
      ).font(.system(size: 9)).foregroundStyle(Palette.secondary)
      Button("Replace image…") { session.importImage(replacing: true) }.font(.system(size: 10))
    }
  }
  func frameControls(_ object: ProductObject) -> some View {
    VStack(alignment: .leading, spacing: 15) {
      SectionLabel("ARTWORK FRAME")
      ArtworkFrameName(value: object.name) { name in store.update(object, ["name": name]) }
      let dimensions = ArtworkDrawing.dimensions(object)
      if object.recipeID == "artboard" {
        HStack(spacing: 12) {
          ArtworkUnitField("Width", value: dimensions.width, unit: session.unit) { width in
            store.update(object, ["parameters": ["width": width]])
          }
          ArtworkUnitField("Height", value: dimensions.height, unit: session.unit) { height in
            store.update(object, ["parameters": ["depth": height]])
          }
        }
      } else {
        Text("\(dimensions.width.formatted()) × \(dimensions.height.formatted()) mm").font(
          .system(size: 11, design: .monospaced)
        ).foregroundStyle(Palette.secondary)
      }
      ColorPicker(
        "Paper / background",
        selection: Binding(
          get: { Color(nsColor: FormColor.color(session.art.background)) },
          set: { color in session.mutate { $0.background = FormColor.hex(NSColor(color)) } }),
        supportsOpacity: false
      ).font(.system(size: 10))
      Divider()
      SectionLabel("PRECISION")
      Toggle(
        "Snap to edges, centers & guides",
        isOn: Binding(
          get: { session.art.snapEnabled != false },
          set: { v in session.mutate { $0.snapEnabled = v } })
      ).font(.system(size: 10)).toggleStyle(.checkbox)
      Toggle(
        "Show grid",
        isOn: Binding(
          get: { session.art.showGrid == true }, set: { v in session.mutate { $0.showGrid = v } })
      ).font(.system(size: 10)).toggleStyle(.checkbox)
      ArtworkUnitField("Grid spacing", value: session.art.gridSpacing ?? 10, unit: session.unit) {
        v in session.mutate { $0.gridSpacing = max(0.1, v) }
      }
      ArtworkUnitField("Nudge", value: session.art.nudge ?? 0.1, unit: session.unit) { v in
        session.mutate { $0.nudge = max(0.01, v) }
      }
      ArtworkUnitField("Bleed / safe guide", value: session.art.bleed, unit: session.unit) { v in
        session.mutate { $0.bleed = min(25, max(0, v)) }
      }
      HStack {
        Button("Vertical guide") { session.addGuide(axis: "x", position: dimensions.width / 2) }
        Button("Horizontal guide") { session.addGuide(axis: "y", position: dimensions.height / 2) }
      }.font(.system(size: 9))
      ForEach(session.art.guides ?? []) { guide in
        HStack {
          ArtworkUnitField(
            guide.axis == "x" ? "X guide" : "Y guide", value: guide.position, unit: session.unit
          ) { value in
            session.mutate { art in
              if let i = art.guides?.firstIndex(where: { $0.id == guide.id }) {
                art.guides?[i].position = value
              }
            }
          }.disabled(guide.locked == true)
          Button {
            session.mutate { art in
              if let i = art.guides?.firstIndex(where: { $0.id == guide.id }) {
                art.guides?[i].locked = guide.locked != true
              }
            }
          } label: {
            Image(systemName: guide.locked == true ? "lock" : "lock.open")
              .font(.system(size: 9))
          }.buttonStyle(.plain).help(guide.locked == true ? "Unlock guide" : "Lock guide")
          Button {
            session.mutate { $0.guides?.removeAll { $0.id == guide.id } }
          } label: {
            Image(systemName: "xmark").font(.system(size: 8))
          }.buttonStyle(.plain)
        }
      }
      if object.recipeID == "artboard" {
        Button("Duplicate frame") {
          store.perform(
            "form_duplicate_object", ["object_id": object.id.uuidString, "mode": "iteration"])
          session.reconcile()
          session.fit()
        }.font(.system(size: 10))
      }
      Text(
        "Select objects to edit their typography, geometry, and appearance. Shift-click extends the selection."
      ).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(3)
    }
  }
}

private struct ArtworkFrameName: View {
  let value: String
  let onCommit: (String) -> Void
  @State private var draft = ""
  @State private var lastCommitted = ""
  @FocusState private var focused: Bool
  private func commit() {
    guard draft != lastCommitted else { return }
    let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty, name.count <= 160, name != value { onCommit(name) }
    draft = name.isEmpty || name.count > 160 ? value : name
    lastCommitted = draft
  }
  var body: some View {
    TextField("Frame name", text: $draft).font(.system(size: 20, design: .serif))
      .textFieldStyle(.plain).focused($focused).onSubmit { commit() }
      .onAppear {
        draft = value
        lastCommitted = value
      }
      .onChange(of: value) { _, name in
        if !focused || draft == lastCommitted {
          draft = name
          lastCommitted = name
        }
      }
      .onChange(of: focused) { _, focus in if !focus { commit() } }
      .onReceive(NotificationCenter.default.publisher(for: .formCommitArtworkFields)) { _ in
        commit()
      }
  }
}

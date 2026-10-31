import AppKit
import FormCore
import FormGraphics
import SwiftUI

extension Notification.Name {
  static let formCommitArtworkFields = Notification.Name("studio.form.commitArtworkFields")
}

struct ArtworkUnitField: View {
  let title: String, value: Double, unit: PhysicalUnit, onCommit: (Double) throws -> Void
  var layout:InspectorFieldLayout = .row
  var accessibilityName:String?
  init(_ title: String, value: Double, unit: PhysicalUnit, layout:InspectorFieldLayout = .row,accessibilityName:String?=nil, _ onCommit: @escaping (Double) throws -> Void) {
    self.title = title
    self.value = value
    self.unit = unit
    self.onCommit = onCommit
    self.layout=layout;self.accessibilityName=accessibilityName
  }
  var body: some View {
    ArtworkInput(
      title: title, value: value / unit.millimeters, suffix: unit.rawValue,
      parser: { try unit.parse($0) / unit.millimeters },onCommit:{try onCommit($0 * unit.millimeters)},layout:layout,accessibilityName:accessibilityName)
  }
}
struct ScalarArtworkField: View {
  let title: String, value: Double, unit: String, onCommit: (Double) throws -> Void
  var increment:TypographyIncrement?
  var layout:InspectorFieldLayout = .row
  var accessibilityName:String?
  init(_ title: String, value: Double, unit: String = "",increment:TypographyIncrement?=nil,layout:InspectorFieldLayout = .row,accessibilityName:String?=nil, _ onCommit: @escaping (Double) throws -> Void) {
    self.title = title
    self.value = value
    self.unit = unit
    self.onCommit = onCommit
    self.increment=increment
    self.layout=layout;self.accessibilityName=accessibilityName
  }
  var body: some View {
    ArtworkInput(
      title: title, value: value, suffix: unit,
      parser: {
        guard let value = Double($0), value.isFinite else {
          throw FormError.invalid("Enter a finite number.")
        }
        return value
      }, onCommit: onCommit,layout:layout,accessibilityName:accessibilityName,increment:increment)
  }
}
private struct ArtworkInput: View {
  let title: String, value: Double, suffix: String, parser: (String) throws -> Double,
    onCommit: (Double) throws -> Void
  var layout:InspectorFieldLayout = .row
  var accessibilityName:String?
  var increment:TypographyIncrement?=nil
  @State private var draft = ""
  @State private var error = false
  @State private var lastCommitted = ""
  @State private var exactCommitted=0.0
  @FocusState private var focused: Bool
  func formatted() -> String {
    value.formatted(.number.precision(.fractionLength(0...(increment == nil ? 4:12))).grouping(.never))
  }
  func commit() {
    guard draft != lastCommitted else { return }
    do {
      let value = try parser(draft)
      if let increment,!increment.range.contains(value) {error=true;return}
      try onCommit(value)
      error = false
      exactCommitted=value;lastCommitted=draft
    } catch { self.error = true }
  }
  private func step(_ direction:Int,_ large:Bool)->Bool {
    guard let increment,increment.isCurrent() else{return false}
    do {
      let base=draft==lastCommitted ? exactCommitted:try parser(draft)
      guard base.isFinite,increment.range.contains(base) else{error=true;return false}
      let next=base+Double(direction)*increment.step*(large ? 10:1)
      guard next.isFinite,increment.range.contains(next),next != base else{return false}
      try onCommit(next)
      exactCommitted=next;draft=next.formatted(.number.precision(.fractionLength(0...12)).grouping(.never));lastCommitted=draft;error=false;return true
    }catch {self.error=true;return false}
  }
  @ViewBuilder private var editor:some View {
    if let increment {
      FocusedNumericArtworkField(text:$draft,title:accessibilityName ?? title,invalid:error,onFocus:{focused=$0},onSubmit:commit,onCancel:{draft=formatted();lastCommitted=draft;exactCommitted=value;error=false},onBegin:increment.begin,onStep:step)
    }else {TextField(accessibilityName ?? title,text:$draft).focused($focused).onSubmit{commit()}}
  }
  var body: some View {
    Group {
      if layout == .stacked {
        VStack(alignment:.leading,spacing:4) {
          Text(title).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
          valueBox
        }.frame(maxWidth:.infinity)
      }else {InspectorRow(title){valueBox}}
    }.font(InspectorStyle.labelFont)
  }
  private var valueBox:some View {
      InspectorValueBox(suffix: suffix, invalid: error, focused: focused) {
      editor.accessibilityLabel(accessibilityName ?? title).font(InspectorStyle.valueFont).multilineTextAlignment(.trailing).textFieldStyle(.plain).frame(minWidth:32,maxWidth:layout == .stacked ? .infinity:77).foregroundStyle(error ? Palette.accent:Palette.ink).onChange(of:focused) { _, focus in
        if !focus {
          commit()
          if !error {
            draft = formatted()
            lastCommitted = draft;exactCommitted=value
          }
        }
      }.onAppear {
        draft = formatted()
        lastCommitted = draft;exactCommitted=value
      }.onChange(of: value) { _, _ in
        if !focused || draft == lastCommitted {
          draft = formatted()
          lastCommitted = draft;exactCommitted=value
          error = false
        }
      }
      .onChange(of: suffix) { _, _ in
        if !focused {
          draft = formatted()
          lastCommitted = draft;exactCommitted=value
          error = false
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .formCommitArtworkFields)) { _ in
        commit()
      }
      }
  }
}

struct ArtworkInspector: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  var e: ArtworkElement? { session.primary.map(session.colored) }
  var type: Typography { session.inspectedTypography }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: InspectorStyle.sectionSpacing) {
        if let object = session.object {
          LinkedObjectInspectorModule(session: session)
          if let review=session.activeCanvasFrame?.sourceReview {
            Text(review).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
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
              ).font(.system(size: 15, design: .default)).textFieldStyle(.plain)
            }
            transformControls
            if session.elements.count == 1, e.objectView != nil { ObjectViewControls(session: session, element: e) }
            SewingPatternControls(session: session, element: e)
            if session.elements.count == 1, e.booleanOperation != nil { booleanControls(e) }
            if session.elements.count == 1, e.component != nil {
              ComponentInspector(session: session, element: e)
            }
            InspectorDivider()
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
              InspectorDivider()
            }
            MaskInspector(session: session, element: e)
            if !session.art.elements.contains(where: { $0.clipID == e.id }) {
              appearanceControls
              AppearanceInspector(session: session, element: e)
            }
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
            if session.elements.allSatisfy({ $0.kind == "path" && $0.objectView == nil }) { pathControls }
            if e.kind == "image" { ImageInspector(session: session,element: e) }
            InspectorDivider()
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
            ProductionRoleControls(session:session)
          } else if session.activeProjection == nil {
            frameControls(object)
          }
          if session.paperContext == nil || session.art.elements.contains(where: { $0.sewingPiece != nil }) {
            SewingPatternActions(session: session)
          }
          PublicationControls(session: session)
        } else {
          Text("Create an artwork frame to begin.").font(.system(size: 12)).foregroundStyle(
            Palette.secondary)
        }
      }.padding(InspectorStyle.panelPadding)
    }.inspectorSurface().background(Palette.paper).disabled(session.elements.contains { session.art.isLocked($0) })
  }
  @ViewBuilder var transformControls: some View {
    if let b = session.selectionBounds {
      if session.elements.count == 1, let e = session.primary {
        ArtworkOriginPicker(session:session,element:e)
      }
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
        CanvasArrangementControls(session: session)
        HStack {
          Spacer()
          Button("Group") { session.execute("group") }
        }.font(.system(size: 9))
        Menu("Combine paths") {
          Button("Make compound path") { session.editPath("combine") }
            .disabled(!session.elements.allSatisfy { $0.kind == "path" })
          Button("Convert shapes to paths") { session.convert("shape") }
          InspectorDivider()
          Button("Union") { session.boolean("union") }
          Button("Subtract") { session.boolean("subtract") }
          Button("Intersect") { session.boolean("intersect") }
          Button("Exclude") { session.boolean("exclude") }
          InspectorDivider()
          Button("Divide into editable regions") { session.boolean("union", mode: "divide") }
        }
        Button("Use bottom shape as clipping mask") { session.makeMask() }.buttonStyle(.plain).font(
          .system(size: 10)
        ).foregroundStyle(Palette.accent)
      }
      if e?.kind == "group", e?.booleanOperation == nil, e?.component == nil {
        HStack {
          Button("Edit group") {
            if let id = e?.id { session.enterGroup(id) }
          }
          Button("Ungroup") { session.execute("ungroup") }
        }.font(.system(size: 10))
      }
    }
  }
  func booleanControls(_ group: ArtworkElement) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionLabel("LIVE BOOLEAN")
      Picker(
        "Operation",
        selection: Binding(
          get: { group.booleanOperation ?? "union" },
          set: { session.boolean($0, mode: "update") })
      ) {
        ForEach(BooleanCommands.operations, id: \.self) { Text($0.capitalized).tag($0) }
      }.font(.system(size: 10))
      HStack {
        Button("Edit operands") {
          session.enterGroup(group.id)
        }
        Button("Release operands") { session.boolean("union", mode: "release") }
      }.font(.system(size: 10))
      Button("Flatten result to path") { session.boolean("union", mode: "flatten") }.font(
        .system(size: 10))
      if let path = try? BooleanGeometry.path(group, in: session.art), path.isEmpty {
        Text("Empty result. Edit the operands or choose another operation.").font(.system(size: 10))
          .foregroundStyle(Palette.accent)
      }
      Text(
        "Shape boundaries drive the result. Original fills and strokes return when operands are released."
      )
      .font(.system(size: 9)).foregroundStyle(Palette.secondary)
    }
  }
  var typographyControls: some View {
    VStack(alignment: .leading, spacing: InspectorStyle.rowSpacing + 2) {
      InspectorSectionHeader("TYPE")
      TextStylePicker(session: session)
      FontBrowserButton(session: session)
      if let font = NSFont(name: type.fontName, size: 12), let family = font.familyName {
        Picker(
          "Style",
          selection: Binding(
            get: { type.fontName }, set: { name in session.chooseFont(name) })
        ) {
          ForEach(FontCatalog.faces(family), id: \.name) { face in Text(face.style).tag(face.name) }
        }.labelsHidden().inspectorPicker()
      } else {
        Label(
          "Missing: \(type.fontName). Choose a replacement above.",
          systemImage: "exclamationmark.triangle"
        ).font(.system(size: 10)).foregroundStyle(Palette.accent)
      }
      VStack(spacing: InspectorStyle.rowSpacing) {
        ScalarArtworkField("Size", value: session.inspectedSize, unit: "pt", increment:session.numericIncrement(step:1,range:0.1...10000)) {
          session.typeSize(max(0.1, $0))
        }
        ScalarArtworkField("Leading", value: type.leading, unit: "pt", increment:session.numericIncrement(step:1,range:0...10000)) { v in
          session.typography { $0.leading = max(0, v) }
        }
      }
      HStack(spacing: 8) {
        Text("A").font(.system(size: 10)).foregroundStyle(Palette.secondary)
        InspectorSlider(value: Binding(get: { session.inspectedSize }, set: { session.typeSize($0) }),
          in: 1...max(144, session.inspectedSize), step: 1, label: "Font size",
          onEditingChanged: session.inspectorEditing)
        Text("A").font(.system(size: 17)).foregroundStyle(Palette.secondary)
      }
      VStack(spacing: InspectorStyle.rowSpacing) {
        ScalarArtworkField("Tracking", value: type.tracking, unit: "pt", increment:session.numericIncrement(step:0.1,range:-10000...10000)) { v in
          session.typography { $0.tracking = v }
        }
        ScalarArtworkField("Baseline", value: type.baseline, unit: "pt", increment:session.numericIncrement(step:0.1,range:-10000...10000)) { v in
          session.typography { $0.baseline = v }
        }
      }
      Picker("Kerning", selection: Binding(
        get: { type.kerningMode ?? "legacy" },
        set: { value in session.typography { $0.kerningMode = value == "legacy" ? nil : value } }
      )) {
        Text("Font metrics").tag("metrics")
        Text("None").tag("none")
        Text("Original spacing").tag("legacy")
      }.font(.system(size: 10))
        .help("Font metrics uses the face's built-in pair spacing. Tracking and manual pair adjustments remain independent. Original spacing preserves older artwork.")
      InspectorSymbolChoice(title: "Text alignment", selection: Binding(
        get: { type.alignment }, set: { value in session.typography { $0.alignment = value } }), choices: [
          ("left", "Align left", "text.alignleft"), ("center", "Align center", "text.aligncenter"),
          ("right", "Align right", "text.alignright"), ("justified", "Justify", "text.justify")])
      HStack(spacing: InspectorStyle.rowSpacing) {
        InspectorSymbolToggle(title: "Underline", symbol: "underline", isOn: Binding(
          get: { type.underline }, set: { value in session.typography { $0.underline = value } }))
        InspectorSymbolToggle(title: "Strikethrough", symbol: "strikethrough", isOn: Binding(
          get: { type.strikethrough }, set: { value in session.typography { $0.strikethrough = value } }))
      }
      Picker(
        "Text frame",
        selection: Binding(
          get: { type.frameMode }, set: { v in session.typography { $0.frameMode = v } })
      ) {
        Text("Area text · wraps").tag("area")
        Text("Point text · grows").tag("point")
      }.font(.system(size: 10)).disabled(session.selectedTextStory != nil)
      if session.editingText {
        Text("Selected characters keep their own fonts, sizes, colors, and spacing.").font(
          .system(size: 9)
        ).foregroundStyle(Palette.secondary)
        ScalarArtworkField("Pair kerning", value: session.canvas?.manualKerningInspection() ?? 0, unit: "pt", increment:session.numericIncrement(step:0.1,range:-10000...10000)) {
          session.manualKerning($0)
        }
      }
      if let e, TypographyEngine.overflows(e) {
        Label("Text overflows this frame.", systemImage: "plus.app").font(.system(size: 10))
          .foregroundStyle(Palette.accent)
      }
      DisclosureGroup("Paragraph & character settings") {
        VStack(spacing: 10) {
          Picker("Case",selection:Binding(
            get:{session.caseTreatments.count>1 ? "mixed" : session.caseTreatments.first ?? type.caseTreatment},
            set:{value in if value != "mixed" {session.typography{$0.caseTreatment=value}}}
          )) {
            if session.caseTreatments.count>1 {Text("Mixed").tag("mixed").disabled(true)}
            Text("Original").tag("original")
            Text("Uppercase").tag("uppercase")
            Text("Lowercase").tag("lowercase")
          }.help("Changes displayed case and preserves the original words.")
          ScalarArtworkField("Word spacing", value: type.wordSpacing, unit: "pt", increment:session.numericIncrement(step:0.1,range:-10000...10000)) { v in
            session.typography { $0.wordSpacing = v }
          }
          ScalarArtworkField("Character width", value: type.horizontalScale, unit: "%", increment:session.numericIncrement(step:1,range:1...1000)) { v in
            session.typography { $0.horizontalScale = min(1000, max(1, v)) }
          }
          ScalarArtworkField("Space before", value: type.paragraphBefore, unit: "pt", increment:session.numericIncrement(step:1,range:-10000...10000)) { v in
            session.typography { $0.paragraphBefore = v }
          }
          ScalarArtworkField("Space after", value: type.paragraphAfter, unit: "pt", increment:session.numericIncrement(step:1,range:-10000...10000)) { v in
            session.typography { $0.paragraphAfter = v }
          }
          ScalarArtworkField("Left indent", value: type.leftIndent, unit: "pt", increment:session.numericIncrement(step:1,range:-10000...10000)) { v in
            session.typography { $0.leftIndent = v }
          }
          ScalarArtworkField("Right indent", value: type.rightIndent, unit: "pt", increment:session.numericIncrement(step:1,range:-10000...10000)) { v in
            session.typography { $0.rightIndent = v }
          }
          ScalarArtworkField("First line", value: type.firstLineIndent, unit: "pt", increment:session.numericIncrement(step:1,range:-10000...10000)) { v in
            session.typography { $0.firstLineIndent = v }
          }
          ScalarArtworkField("Hyphenation", value: type.hyphenation*100, unit: "%", increment:session.numericIncrement(step:1,range:0...100)) { v in
            session.typography { $0.hyphenation = min(1,max(0,v/100)) }
          }
          Button("Tab stops…") { session.showingTabs = true }
            .sheet(isPresented: $session.showingTabs) { ParagraphTabsPanel(session: session) }
          ParagraphListControls(session:session)
          ParagraphLanguageControls(session:session,type:type)
          Picker(
            "Vertical",
            selection: Binding(
              get: { session.primary?.typography?.verticalAlignment ?? "top" },
              set: { v in
                session.canvas?.finishText()
                if session.selectedTextStory != nil {
                  session.update {if $0.kind=="text" {var t=$0.typography ?? .init();t.verticalAlignment=v;$0.typography=t}}
                } else {session.typography { $0.verticalAlignment = v }}
              })
          ) {
            Text("Top").tag("top")
            Text("Middle").tag("middle")
            Text("Bottom").tag("bottom")
          }.disabled(session.selectedTextStory.map { source in source.publicationID != nil && (source.typography?.alignToBaselineGrid==true || source.textRuns?.contains(where:{$0.typography.alignToBaselineGrid==true})==true) } ?? false)
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
      HStack {
        Button("Glyphs…") {session.showingGlyphs=true}
          .popover(isPresented:$session.showingGlyphs,arrowEdge:.leading) {
            GlyphPalette(session:session).onExitCommand {session.showingGlyphs=false}
          }
        Spacer()
        if let e=session.primary,!(e.glyphOverrides ?? []).isEmpty {
          Text("\(e.glyphOverrides!.count) glyph \(e.glyphOverrides!.count == 1 ? "choice":"choices")").foregroundStyle(Palette.secondary)
        }
      }.font(.system(size:10))
      if let e=session.primary,let issue=GlyphEngine.issues(session.colored(e)).first {
        Text(issue).font(.system(size:10)).foregroundStyle(Palette.accent)
      }
      DisclosureGroup("Font features & variations") {
        FontFeaturesInspector(session: session).padding(.top, InspectorStyle.rowSpacing)
      }.font(InspectorStyle.labelFont).tint(Palette.secondary)
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
        if e.kind != "image", e.kind != "group" || e.booleanOperation != nil {
          HStack {
            Toggle(
              "Fill",
              isOn: Binding(
                get: { e.fillEnabled != false }, set: { v in session.update { $0.fillEnabled = v } }
              )
            ).inspectorToggle()
            Spacer()
            InspectorColorPicker(
              "Fill color",
              selection: Binding(
                get: { Color(nsColor: FormColor.color(session.inspectedColor)) },
                set: { session.textColor(FormColor.hex(NSColor($0))) }), supportsOpacity: false,
              targetID: session.inspectorColorTarget("fill"), onEditingChanged: session.inspectorEditing
            ).labelsHidden()
          }.font(.system(size: 10))
          SwatchPicker(session: session, target: "fill", swatchID: session.inspectedFillSwatchID,
            mixed: session.fillSwatchReferences.count > 1)
        } else if e.kind == "group", e.component == nil {
          Text("Group fills").font(.system(size: 10))
          SwatchPicker(session: session, target: "fill", swatchID: session.inspectedFillSwatchID,
            mixed: session.fillSwatchReferences.count > 1)
        }
        ScalarArtworkField("Opacity", value: (e.opacity ?? 1) * 100, unit: "%") { v in
          session.update { $0.opacity = min(1, max(0, v / 100)) }
        }
        if !["image", "group"].contains(e.kind) || e.booleanOperation != nil {
          ScalarArtworkField("Fill opacity", value: (e.fillOpacity ?? 1) * 100, unit: "%") {
            value in
            session.update { $0.fillOpacity = min(1, max(0, value / 100)) }
          }
        }
        if !["text", "image", "group"].contains(e.kind) || e.booleanOperation != nil {
          StrokeInspector(session: session, element: e)
          if e.kind != "line" { GradientInspector(session: session, element: e) }
        }

      }
    }
  }
  var pathControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      InspectorDivider()
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
          "\(session.elements.reduce(0) { $0 + ($1.path?.contours.flatMap(\.nodes).count ?? 0) }) nodes · \(session.nodes.count) selected"
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
            session.nodes = Set(
              session.elements.flatMap { $0.path?.contours.flatMap(\.nodes).map(\.id) ?? [] })
            session.canvas?.window?.makeFirstResponder(session.canvas)
          }
        }.font(.system(size: 9))
        Toggle(
          "Closed contours",
          isOn: Binding(
            get: { session.elements.allSatisfy { $0.path?.contours.allSatisfy(\.closed) == true } },
            set: { value in
              session.editPath(value ? "close" : "open")
            })
        ).font(.system(size: 10)).inspectorToggle()
        if session.elements.count == 1, path.contours.count > 1 {
          Button("Release compound path") { session.editPath("release") }.font(.system(size: 10))
        }
        if session.elements.count > 1 {
          Text(
            "Shift-click endpoints across paths, then Join. The frontmost path supplies the appearance."
          )
          .font(.system(size: 9)).foregroundStyle(Palette.secondary)
        }
      }
    }
  }
  func frameControls(_ object: ProductObject) -> some View {
    VStack(alignment: .leading, spacing: 15) {
      SectionLabel(object.isCanvasWorkspace ? "FREEFORM CANVAS" : "ARTWORK FRAME")
      ProductionOverlayControls(session:session)
      ColorProfileControls(session: session)
      if object.recipeID=="artboard",!object.isCanvasWorkspace,let store=session.store {DecorationPreparationAction(store:store,objectID:object.id).buttonStyle(.borderless)}
      if object.isCanvasWorkspace {
        Text("Draw, type, or place images anywhere. Add a physical frame when you need one, then drag artwork onto it.")
          .font(.system(size:11)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      } else {
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
      InspectorColorPicker(
        "Paper / background",
        selection: Binding(
          get: { Color(nsColor: FormColor.color(session.backgroundColor)) },
          set: { color in session.mutate {
            $0.background = FormColor.hex(NSColor(color)); $0.backgroundSwatchID = nil
          } }),
        supportsOpacity: false, targetID: session.inspectorColorTarget("background"),
        onEditingChanged: session.inspectorEditing
      ).font(.system(size: 10))
      SwatchPicker(session: session, target: "background", swatchID: session.art.backgroundSwatchID)
      ScalarArtworkField(
        "Background opacity", value: (session.art.backgroundOpacity ?? 1) * 100, unit: "%"
      ) { value in
        session.mutate { $0.backgroundOpacity = min(1, max(0, value / 100)) }
      }
      }
      InspectorDivider()
      SectionLabel("PRECISION")
      Toggle(
        "Snap to edges, centers & guides",
        isOn: Binding(
          get: { session.art.snapEnabled != false },
          set: { v in session.mutate { $0.snapEnabled = v } })
      ).font(.system(size: 10)).inspectorToggle()
      Toggle(
        "Show grid",
        isOn: Binding(
          get: { session.art.showGrid == true }, set: { v in session.mutate { $0.showGrid = v } })
      ).font(.system(size: 10)).inspectorToggle()
      ArtworkUnitField("Grid spacing", value: session.art.gridSpacing ?? 10, unit: session.unit) {
        v in session.mutate { $0.gridSpacing = max(0.1, v) }
      }
      ArtworkUnitField("Nudge", value: session.art.nudge ?? 0.1, unit: session.unit) { v in
        session.mutate { $0.nudge = max(0.01, v) }
      }
      if let p=store.project,(try? ArtworkPageSetup.source(p,objectID:object.id)) != nil {
        ArtworkPageSetupControls(store:store,objectID:object.id).id(object.id)
      }
      HStack {
        Button("Vertical guide") { session.addGuide(axis:"x",position:object.isCanvasWorkspace ? session.canvas?.visibleCanvasRect.midX ?? 0 : ArtworkDrawing.dimensions(object).width/2) }
        Button("Horizontal guide") { session.addGuide(axis:"y",position:object.isCanvasWorkspace ? session.canvas?.visibleCanvasRect.midY ?? 0 : ArtworkDrawing.dimensions(object).height/2) }
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
            Image(systemName: "trash").font(.system(size: 11))
          }.buttonStyle(.plain)
        }
      }
      if object.recipeID == "artboard" && !object.isCanvasWorkspace {
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
    TextField("Frame name", text: $draft).font(.system(size: 20, weight: .semibold))
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

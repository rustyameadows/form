import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct ArtworkWorkspace: View {
  @EnvironmentObject var store: StudioStore
  var body: some View {
    ArtworkStudio(session:store.artworkSession).environmentObject(store)
      .focusedValue(\.designSurface,.artwork)
  }
}

struct ArtworkStudio: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  @State private var newFrame = false
  @State private var exportOptions = false
  @State private var format = "svg"
  @State private var productionOutput = "print"
  @State private var compactLayers = false
  @State private var compactInspector = false
  private var compact: Bool { store.surfaceLayout == .split }
  var body: some View {
    VStack(spacing: 0) {
      ScrollView(.horizontal,showsIndicators:false) {
      HStack(spacing: 3) {
        if compact {
          IconButton("Show Canvas layers",symbol:"sidebar.left") { compactLayers.toggle() }
          IconButton("Show Canvas inspector",symbol:"sidebar.right") { compactInspector.toggle() }
          Divider().frame(height:19).padding(.horizontal,5)
        }
        ForEach(ArtworkTool.allCases, id: \.self) { tool in
          Button {
            session.canvas?.finishText()
            session.tool = tool
            session.canvas?.window?.makeFirstResponder(session.canvas)
          } label: {
            Image(systemName: tool.symbol).font(.system(size: 13)).frame(width: 30, height: 32)
              .background(
                session.tool == tool ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 6))
          }.buttonStyle(.plain).help("\(tool.rawValue.capitalized) · \(tool.shortcut)")
        }
        Divider().frame(height: 19).padding(.horizontal, 5)
        IconButton("Place image", symbol: "photo.badge.plus") { session.importImage() }
        IconButton("Import editable SVG · ⇧⌘I", symbol: "square.and.arrow.down") {
          store.importSVGDialog()
        }
        Button {
          newFrame = true
        } label: {
          Label("Frame", systemImage: "rectangle.badge.plus").font(.system(size: 11))
        }.buttonStyle(.plain).padding(.leading, 8).popover(isPresented: $newFrame) {
          NewArtworkFrame(session: session)
        }
        Button { session.showingPalette.toggle() } label: {
          Label("Palette", systemImage: "swatchpalette").font(.system(size: 11))
        }.buttonStyle(.plain).padding(.leading, 12).popover(isPresented: $session.showingPalette) {
          SwatchPalette(session: session)
        }
        Button { session.showingTextStyles.toggle() } label: {
          Label("Text styles", systemImage: "textformat.size").font(.system(size: 11))
        }.buttonStyle(.plain).padding(.leading, 12).sheet(isPresented: $session.showingTextStyles) {
          TextStylesPanel(session: session)
        }
        Spacer(minLength: 10)
        if session.previewObject?.recipeID == "sleeve" {
          Picker("View", selection: $session.dieline) {
            Text("Artwork").tag(false)
            Text("Dieline").tag(true)
          }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
        }
        Button {
          session.preview.toggle()
        } label: {
          Image(systemName: "cube.transparent").foregroundStyle(
            session.preview ? Palette.accent : Palette.secondary)
        }.buttonStyle(.plain).help("Show live 3D preview").disabled(session.previewObject == nil || compact)
        Button {
          exportOptions = true
        } label: {
          Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 11))
        }.buttonStyle(.plain).padding(.leading, 10).disabled(session.object == nil || session.object?.isCanvasWorkspace == true && session.selection.isEmpty).popover(
          isPresented: $exportOptions
        ) {
          VStack(alignment: .leading, spacing: 16) {
            SectionLabel("EXPORT ARTWORK")
            Picker("Format", selection: $format) {
              Text("SVG").tag("svg")
              Text("PDF").tag("pdf")
              Text("PNG").tag("png")
              Text("JPEG").tag("jpeg")
            }
            ProductionExportPicker(output:$productionOutput,format:format)
            if ["png", "jpeg"].contains(format) {
              ScalarArtworkField("Resolution", value: session.exportDPI, unit: "DPI") {
                session.exportDPI = $0
              }
            }
            if format == "svg" {
              Toggle("Convert text to portable outlines", isOn: $session.exportOutline)
              if session.art.elements.contains(where: { TypographyEngine.requiresComposedOutlines($0) }) {
                Text("Tab-aligned, hyphenated, and custom-glyph text keep their exact composition as outlines.").font(.system(size:10)).foregroundStyle(Palette.secondary)
              }
            }
            Button("Export…") {
              exportOptions = false
              session.exportProduction(format,output:productionOutput)
            }
          }.padding(22).frame(width: 300)
        }
      }.padding(.horizontal, 16).frame(height: 50)
      }.frame(height:50).background(Palette.paper)
      Divider()
      HStack(spacing: 0) {
        if !compact || compactLayers {
          ArtworkLayers(session: session).frame(width:compact ? 180 : 210)
          Divider()
        }
        if store.project != nil {
          VectorCanvas(session: session, revision: store.revision)
        } else {
          VStack(spacing: 17) {
            Image(systemName: "rectangle.badge.plus").font(.system(size: 36, weight: .ultraLight))
            Text("A place to begin.").font(.system(size: 24, design: .serif))
            Text("Draw freely, then add a frame when you need a physical size.").font(.system(size: 12))
              .foregroundStyle(Palette.secondary)
          }.frame(maxWidth: .infinity, maxHeight: .infinity).background(
            Color(nsColor: NSColor(hex: "#E7E7E1")))
        }
        if !compact || compactInspector {
          Divider()
          ArtworkInspector(session: session).frame(width:286)
        }
      }
      Divider()
      HStack(spacing: 14) {
        Text(session.maskEditing != nil ? "EDITING MASK" : session.scopeID == nil ? "CANVAS" : "EDITING GROUP").font(
          .system(size: 8, weight: .medium, design: .monospaced)
        ).tracking(0.8)
        if session.maskEditing != nil {
          Button("Back to contents") { session.returnFromMask() }
            .buttonStyle(.plain).foregroundStyle(Palette.accent)
        } else if session.componentReturn != nil {
          Button("Back to instance") { session.returnToComponent() }
            .buttonStyle(.plain).foregroundStyle(Palette.accent)
        }
        if session.scopeID != nil && session.maskEditing == nil {
          Button("Leave group") {
            session.scopeID = nil
            session.choose([])
          }.buttonStyle(.plain).foregroundStyle(Palette.accent)
        }
        Text(
          session.editingText
            ? "Native text editing · Esc to finish"
            : "Space-drag to pan · Pinch to zoom · Option bypasses snapping"
        ).foregroundStyle(Palette.secondary).lineLimit(1)
        Spacer()
        Button {
          session.setZoom(session.zoom / 1.2)
        } label: {
          Image(systemName: "minus")
        }.buttonStyle(.plain)
        Menu("\(Int((session.zoom*100).rounded()))%") {
          ForEach([0.25, 0.5, 1, 2, 4, 8], id: \.self) { zoom in
            Button("\(Int(zoom*100))%") { session.setZoom(zoom) }
          }
          Divider()
          Button("Fit Canvas contents") { session.fit() }
        }.menuStyle(.borderlessButton).frame(width: 65)
        Button {
          session.setZoom(session.zoom * 1.2)
        } label: {
          Image(systemName: "plus")
        }.buttonStyle(.plain)
        IconButton("Fit Canvas contents · ⌘0", symbol: "arrow.up.left.and.arrow.down.right") {
          session.fit()
        }
        Picker(
          "Units",
          selection: Binding(
            get: { session.unit },
            set: { unit in
              NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
              session.mutate { $0.unit = unit }
            })
        ) { ForEach(PhysicalUnit.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
        .labelsHidden().frame(width: 64)
      }.font(.system(size: 9)).padding(.horizontal, 16).frame(height: 37).background(Palette.paper)
    }.onAppear {
      if session.object == nil { store.ensureCanvas() }
      session.reconcile()
    }.onChange(of: store.revision) { _, _ in session.reconcile() }
      .onChange(of: session.dieline) { _, dieline in
        if dieline { session.canvas?.finishText() }
        DispatchQueue.main.async { session.fit() }
      }
      .onChange(of: store.mode) { _, mode in if mode != .artwork && store.surfaceLayout == .single { session.canvas?.finishText() } }
  }
}

struct NewArtworkFrame: View {
  @ObservedObject var session: ArtworkSession
  @Environment(\.dismiss) var dismiss
  @State private var width = 203.2
  @State private var height = 254.0
  @State private var unit: PhysicalUnit = .inches
  @State private var name = "Untitled frame"
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SectionLabel("NEW ARTWORK FRAME")
      TextField("Frame name", text: $name).textFieldStyle(.roundedBorder)
      Menu("Physical presets") {
        Button("8 × 10 inches") {
          width = 203.2
          height = 254
          unit = .inches
        }
        Button("11 × 17 inches") {
          width = 279.4
          height = 431.8
          unit = .inches
        }
        Button("A4 · 210 × 297 mm") {
          width = 210
          height = 297
          unit = .mm
        }
        Button("US Letter") {
          width = 215.9
          height = 279.4
          unit = .inches
        }
        Button("100 mm dial") {
          width = 100
          height = 100
          unit = .mm
        }
      }
      Picker("Units", selection: $unit) {
        ForEach(PhysicalUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      ArtworkUnitField("Width", value: width, unit: unit) { width = $0 }
      ArtworkUnitField("Height", value: height, unit: unit) { height = $0 }
      Button("Create frame") {
        session.createFrame(
          width: width, height: height, name: name.isEmpty ? "Untitled frame" : name)
        session.mutate { $0.unit = unit }
        dismiss()
      }.buttonStyle(.borderedProminent).tint(Palette.ink).disabled(
        width < 1 || width > 1000 || height < 1 || height > 1000)
    }.padding(23).frame(width: 290)
  }
}

struct ArtworkLayers: View {
  @ObservedObject var session: ArtworkSession
  @State private var renaming: UUID?
  @State private var collapsed = Set<UUID>()
  var rows: [(element: ArtworkElement, depth: Int)] {
    var result: [(ArtworkElement, Int)] = []
    var seen = Set<UUID>()
    func children(_ parent: UUID?, _ depth: Int) {
      for e in session.art.elements.reversed() where e.parentID == parent && !seen.contains(e.id) {
        seen.insert(e.id)
        result.append((e, depth))
        if e.kind == "group", !collapsed.contains(e.id) { children(e.id, depth + 1) }
      }
    }
    children(nil, 0)
    return result
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        SectionLabel("CANVAS & FRAMES")
        Spacer()
        Text("\(session.frames.filter { !$0.isWorkspace }.count)").foregroundStyle(Palette.secondary).font(.system(size: 9))
      }.padding(16)
      ForEach(session.frames) { frame in
        Button {
          session.activate(frame.id)
          session.canvas?.fit(all: false)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: frame.isWorkspace ? "square.dashed" : frame.object.componentDefinition == true ? "diamond.fill" : frame.object.recipeID == "artboard" ? "rectangle" : "link")
            Text(frame.isWorkspace ? "Canvas" : frame.object.name).lineLimit(1)
            Spacer()
          }.font(.system(size: 11)).padding(.horizontal, 14).padding(.vertical, 9).background(
            session.objectID == frame.id ? Color.white : .clear)
        }.buttonStyle(.plain)
      }
      Divider().padding(.top, 12)
      HStack {
        SectionLabel("LAYERS")
        Spacer()
        if !session.selection.isEmpty {
          Menu {
            Button("Group") { session.execute("group") }
            Button("Ungroup") { session.execute("ungroup") }
            Button("Bring to front") { session.execute("reorder", ["mode": "front"]) }
            Button("Send to back") { session.execute("reorder", ["mode": "back"]) }
            Button("Duplicate") { session.execute("duplicate") }
            Button("Delete") { session.execute("delete") }
          } label: {
            Image(systemName: "ellipsis")
          }.menuStyle(.borderlessButton).frame(width: 20)
        }
      }.padding(16)
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(rows, id: \.element.id) { row in
            HStack(spacing: 6) {
              if row.element.component != nil {
                Image(systemName: "diamond").font(.system(size: 10)).frame(width: 10)
              } else if row.element.kind == "group" {
                Button {
                  if collapsed.contains(row.element.id) {
                    collapsed.remove(row.element.id)
                  } else {
                    collapsed.insert(row.element.id)
                  }
                } label: {
                  Image(
                    systemName: collapsed.contains(row.element.id)
                      ? "chevron.right" : "chevron.down"
                  ).font(.system(size: 8))
                }.buttonStyle(.plain).frame(width: 10)
              } else {
                Image(
                  systemName: row.element.kind == "text"
                    ? "textformat"
                    : row.element.kind == "path"
                      ? "point.topleft.down.to.point.bottomright.curvepath"
                      : row.element.kind == "image" ? "photo" : "square"
                ).font(.system(size: 10)).frame(width: 10)
              }
              if renaming == row.element.id {
                TextField(
                  "Layer name",
                  text: Binding(
                    get: { session.art.elements.first { $0.id == row.element.id }?.title ?? "" },
                    set: { value in
                      session.mutate { a in
                        if let i = a.elements.firstIndex(where: { $0.id == row.element.id }) {
                          a.elements[i].name = value
                        }
                      }
                    })
                ).textFieldStyle(.plain).onSubmit { renaming = nil }
              } else {
                Text(row.element.title.isEmpty ? "Text" : row.element.title).lineLimit(1).frame(
                  maxWidth: .infinity, alignment: .leading
                ).onTapGesture(count: 2) { renaming = row.element.id }
              }
              Button {
                session.canvas?.finishText()
                session.mutate { a in
                  if let i = a.elements.firstIndex(where: { $0.id == row.element.id }) {
                    a.elements[i].hidden = !(a.elements[i].hidden ?? false)
                  }
                }
              } label: {
                Image(systemName: row.element.hidden == true ? "eye.slash" : "eye").font(
                  .system(size: 9))
              }.buttonStyle(.plain).help("Toggle layer visibility")
              Button {
                session.canvas?.finishText()
                session.mutate { a in
                  if let i = a.elements.firstIndex(where: { $0.id == row.element.id }) {
                    a.elements[i].locked = !(a.elements[i].locked ?? false)
                  }
                }
              } label: {
                Image(systemName: row.element.locked == true ? "lock.fill" : "lock.open").font(
                  .system(size: 9))
              }.buttonStyle(.plain).help("Toggle layer lock")
            }.font(.system(size: 10)).foregroundStyle(
              row.element.hidden == true ? Palette.secondary : Palette.ink
            ).padding(.leading, 12 + CGFloat(min(row.depth, 6)) * 12).padding(.trailing, 9).frame(
              height: 32
            ).background(
              session.selection.contains(row.element.id) ? Color.white : .clear,
              in: RoundedRectangle(cornerRadius: 5)
            ).contentShape(Rectangle()).onTapGesture {
              if NSEvent.modifierFlags.contains(.shift) {
                if session.selection.contains(row.element.id) {
                  session.selection.remove(row.element.id)
                } else {
                  session.selection.insert(row.element.id)
                }
              } else {
                session.choose([row.element.id])
              }
            }.contextMenu {
              Button("Rename") { renaming = row.element.id }
              Button("Edit inside group") {
                session.scopeID = row.element.id
                session.choose([])
              }.disabled(row.element.kind != "group" || row.element.component != nil)
              if row.element.component != nil {
                Button("Edit component source") { session.editComponentSource(row.element) }
                Button("Detach instance") {
                  session.choose([row.element.id])
                  session.component("detach")
                }
              }
              Button("Delete") {
                session.choose([row.element.id])
                session.execute("delete")
              }
            }
          }
        }.padding(.horizontal, 5)
      }
      Spacer(minLength: 0)
    }.background(Palette.paper)
  }
}

struct ObjectPreview: NSViewRepresentable {
  @EnvironmentObject var store: StudioStore
  let object: ProductObject
  let project: Project
  let assets: URL
  func makeCoordinator() -> TableSceneController {
    TableSceneController()
  }
  func makeNSView(context: Context) -> TableSCNView {
    let view = TableSCNView(frame: .zero)
    view.controller = context.coordinator
    context.coordinator.view = view
    view.scene = context.coordinator.scene
    view.pointOfView = context.coordinator.cameraNode
    view.antialiasingMode = .multisampling4X
    view.rendersContinuously = false
    return view
  }
  func updateNSView(_ view: TableSCNView, context: Context) {
    var preview = project
    var surface = object
    surface.artwork = project.surfaceArtwork(object)
    surface.artworkSourceID = nil
    surface.artworkFit = nil
    preview.objects = [surface]
    preview.objects[0].position = .init()
    preview.objects[0].rotation = 0
    let builds = context.coordinator.geometryBuilds
    let initial = context.coordinator.objectRoot.childNodes.isEmpty
    context.coordinator.sync(
      preview, selection: [], isolated: [], showGrid: false, studio: false, preset: "Daylight",
      assets: assets, textureLimit: 1024)
    if initial || builds != context.coordinator.geometryBuilds { context.coordinator.fitAll() }
  }
}

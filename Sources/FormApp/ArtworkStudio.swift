import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct ArtworkStudio: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  @State private var newFrame = false
  @State private var exportOptions = false
  @State private var format = "svg"
  @State private var productionOutput = "print"
  @State private var showingLayers = true
  @State private var showingInspector = true
  @State private var compactLayers = false
  @State private var compactInspector = false
  private var compact: Bool { store.surfaceLayout == .split }
  private var hasContextNavigation: Bool {
    session.maskEditing != nil || session.componentReturn != nil || session.scopeID != nil
  }

  var body: some View {
    GeometryReader { geometry in
      let narrow = geometry.size.width < 900
      let layers = narrow ? compactLayers : showingLayers
      let inspector = narrow ? compactInspector : showingInspector
      let panelHeight = max(180, geometry.size.height - 116)
      ZStack {
        if store.project != nil {
          VectorCanvas(session: session, revision: store.revision, fittingInsets: NSEdgeInsets(
            top: 16, left: layers ? 266 : 16,
            bottom: hasContextNavigation ? 112 : 72, right: inspector ? 318 : 16))
        } else {
          VStack(spacing: 17) {
            Image(systemName: "rectangle.badge.plus").font(.system(size: 36, weight: .ultraLight))
            Text("A place to begin.").font(.system(size: 24, weight: .semibold))
            Text("Draw freely, then add a frame when you need a physical size.")
              .font(.system(size: 12)).foregroundStyle(Palette.secondary)
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .background(Palette.surface)
      .overlay(alignment: .topLeading) {
        if layers {
          ArtworkLayers(session: session, onClose: { toggleLayers(narrow: narrow) })
            .frame(width: 234, height: min(panelHeight, 480))
            .modifier(CanvasFloatingPanel()).padding(16)
        }
      }
      .overlay(alignment: .topTrailing) {
        if inspector {
          VStack(spacing: 0) {
            HStack {
              SectionLabel("INSPECTOR")
              Spacer()
              IconButton("Hide Canvas inspector", symbol: "xmark", size: 24) {
                toggleInspector(narrow: narrow)
              }
            }.padding(.leading, 18).padding(.trailing, 8).frame(height: 40)
            Divider()
            ArtworkInspector(session: session)
          }.frame(width: 286, height: panelHeight)
            .modifier(CanvasFloatingPanel()).padding(16)
        }
      }
      .overlay(alignment: .bottomLeading) {
        VStack(alignment: .leading, spacing: 8) {
          if hasContextNavigation {
            contextNavigation.padding(8).modifier(CanvasFloatingPanel())
          }
          tools(narrow: narrow, abbreviated: geometry.size.width < 760,
            layers: layers, inspector: inspector)
            .modifier(CanvasFloatingPanel())
        }.padding(16)
      }
    }
    .onAppear {
      if session.object == nil {
        if let object = store.primary, PaperConstruction.isPaper(object) { store.activatePaperArtwork(object) }
        else { store.ensureCanvas() }
      }
      session.reconcile()
    }
    .onChange(of: store.revision) { _, _ in session.reconcile() }
    .onChange(of: session.dieline) { _, dieline in
      if dieline { session.canvas?.finishText() }
      DispatchQueue.main.async { session.fit() }
    }
    .onChange(of: store.mode) { _, mode in
      if mode != .artwork && store.surfaceLayout == .single { session.canvas?.finishText() }
    }
  }

  private func toggleLayers(narrow: Bool) {
    if narrow {
      compactLayers.toggle()
      if compactLayers { compactInspector = false }
    } else { showingLayers.toggle() }
  }
  private func toggleInspector(narrow: Bool) {
    if narrow {
      compactInspector.toggle()
      if compactInspector { compactLayers = false }
    } else { showingInspector.toggle() }
  }
  private func openInspector(narrow: Bool) {
    if narrow { compactInspector = true; compactLayers = false }
    else { showingInspector = true }
  }
  private func chooseTool(_ tool: ArtworkTool) {
    session.canvas?.finishText()
    session.tool = tool
    session.canvas?.window?.makeFirstResponder(session.canvas)
  }

  private var contextNavigation: some View {
    HStack(spacing: 12) {
      if session.maskEditing != nil {
        Button("Back to contents", systemImage: "chevron.left") { session.returnFromMask() }
      } else if session.componentReturn != nil {
        Button("Back to instance", systemImage: "chevron.left") { session.returnToComponent() }
      }
      if session.scopeID != nil && session.maskEditing == nil {
        Button("Leave group", systemImage: "arrow.uturn.backward") {
          session.scopeID = nil
          session.choose([])
        }
      }
    }.buttonStyle(.plain).font(.system(size: 11))
  }

  private func tools(narrow: Bool, abbreviated: Bool, layers: Bool, inspector: Bool) -> some View {
    HStack(spacing: 3) {
      IconButton("Canvas & Surfaces", symbol: "sidebar.left", size: 32) { toggleLayers(narrow: narrow) }
        .background(layers ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityValue(layers ? "Shown" : "Hidden")
      IconButton("Canvas inspector", symbol: "sidebar.right", size: 32) { toggleInspector(narrow: narrow) }
        .background(inspector ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityValue(inspector ? "Shown" : "Hidden")
      Divider().frame(height: 20).padding(.horizontal, 4)
      if abbreviated {
        Menu {
          ForEach(ArtworkTool.allCases, id: \.self) { tool in
            Button { chooseTool(tool) } label: {
              Label(tool.rawValue.capitalized + " · " + tool.shortcut, systemImage: tool.symbol)
            }
          }
        } label: {
          Image(systemName: session.tool.symbol).font(.system(size: 13)).frame(width: 32, height: 32)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
        }.menuStyle(.borderlessButton).fixedSize().help(session.tool.rawValue.capitalized + " · Canvas tools")
          .accessibilityLabel("Canvas tools")
          .accessibilityValue(session.tool.rawValue.capitalized)
      } else {
        ForEach(ArtworkTool.allCases, id: \.self) { tool in
          Button { chooseTool(tool) } label: {
            Image(systemName: tool.symbol).font(.system(size: 13)).frame(width: 30, height: 32)
              .background(session.tool == tool ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
          }.buttonStyle(.plain).help("\(tool.rawValue.capitalized) · \(tool.shortcut)")
            .accessibilityLabel(tool.rawValue.capitalized + " tool")
            .accessibilityValue(session.tool == tool ? "Selected" : "")
        }
      }
      Divider().frame(height: 20).padding(.horizontal, 4)
      actions(narrow: narrow)
      zoomMenu.padding(.horizontal, 6)
    }.padding(6).fixedSize(horizontal: true, vertical: false)
  }

  private func actions(narrow: Bool) -> some View {
    Menu {
      Button("Place image…", systemImage: "photo.badge.plus") { session.importImage() }
      Button("Import editable SVG…", systemImage: "square.and.arrow.down") { store.importSVGDialog() }
      Button("New frame…", systemImage: "rectangle.badge.plus") { newFrame = true }
      Divider()
      Button("Palette…", systemImage: "swatchpalette") { session.showingPalette = true }
      Button("Text styles…", systemImage: "textformat.size") { session.showingTextStyles = true }
      if let construction = session.paperContext {
        Menu("Artwork side") {
          Picker("Artwork side", selection: Binding(get: { store.paperInside }, set: {
            store.setPaperInside($0, object: construction)
          })) {
            Text("Outside").tag(false)
            Text("Inside").tag(true)
          }
          if store.paperInside && construction.paperConstruction?.insideArtworkSourceID == nil {
            Button("Create inside artwork") { store.createPaperInside(construction) }
          }
        }
      }
      if session.previewObject?.recipeID == "sleeve" {
        Picker("View", selection: $session.dieline) {
          Text("Artwork").tag(false)
          Text("Dieline").tag(true)
        }
      }
      Divider()
      Button(session.preview ? "Hide live 3D preview" : "Show live 3D preview", systemImage: "cube.transparent") {
        session.preview.toggle()
        if session.preview { openInspector(narrow: narrow) }
      }.disabled(session.previewObject == nil || compact)
      Button("Export artwork…", systemImage: "square.and.arrow.up") { exportOptions = true }
        .disabled(session.object == nil || session.object?.isCanvasWorkspace == true && session.selection.isEmpty)
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 32, height: 32)
    }.menuStyle(.borderlessButton).fixedSize().help("Canvas actions").accessibilityLabel("Canvas actions")
      .popover(isPresented: $newFrame, arrowEdge: .bottom) { NewArtworkFrame(session: session) }
      .popover(isPresented: $session.showingPalette, arrowEdge: .bottom) { SwatchPalette(session: session) }
      .sheet(isPresented: $session.showingTextStyles) { TextStylesPanel(session: session) }
      .popover(isPresented: $exportOptions, arrowEdge: .bottom) { exportPanel }
  }

  private var zoomMenu: some View {
    Menu {
      Button("Zoom in") { session.setZoom(session.zoom * 1.2) }
      Button("Zoom out") { session.setZoom(session.zoom / 1.2) }
      Divider()
      ForEach([0.25, 0.5, 1, 2, 4, 8], id: \.self) { zoom in
        Button("\(Int(zoom * 100))%") { session.setZoom(zoom) }
      }
      Divider()
      Button("Fit Canvas contents · ⌘0") { session.fit() }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "magnifyingglass")
        Text("\(Int((session.zoom * 100).rounded()))%").monospacedDigit()
      }.font(.system(size: 10))
    }.menuStyle(.borderlessButton).fixedSize().help("Canvas zoom and fit")
      .accessibilityLabel("Canvas zoom").accessibilityValue("\(Int((session.zoom * 100).rounded())) percent")
  }

  private var exportPanel: some View {
    VStack(alignment: .leading, spacing: 16) {
      SectionLabel("EXPORT ARTWORK")
      Picker("Format", selection: $format) {
        Text("SVG").tag("svg")
        Text("PDF").tag("pdf")
        Text("PNG").tag("png")
        Text("JPEG").tag("jpeg")
      }
      ProductionExportPicker(output: $productionOutput, format: format)
      if ["png", "jpeg"].contains(format) {
        ScalarArtworkField("Resolution", value: session.exportDPI, unit: "DPI") { session.exportDPI = $0 }
      }
      if format == "svg" {
        Toggle("Convert text to portable outlines", isOn: $session.exportOutline)
        if session.art.elements.contains(where: { TypographyEngine.requiresComposedOutlines($0) }) {
          Text("Tab-aligned, hyphenated, and custom-glyph text keep their exact composition as outlines.")
            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }
      }
      Button("Export…") {
        exportOptions = false
        session.exportProduction(format, output: productionOutput)
      }
    }.padding(22).frame(width: 300)
  }
}

private struct CanvasFloatingPanel: ViewModifier {
  func body(content: Content) -> some View {
    content.background(Palette.paper)
      .clipShape(RoundedRectangle(cornerRadius: 13))
      .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.line).allowsHitTesting(false))
      .shadow(color: .black.opacity(0.06), radius: 14, y: 5)
  }
}

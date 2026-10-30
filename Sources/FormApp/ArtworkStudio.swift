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
  @State private var showingBackground = false
  @ObservedObject private var appearance = InterfaceAppearance.shared
  private var hasContextNavigation: Bool {
    session.maskEditing != nil || session.componentReturn != nil || session.scopeID != nil
  }

  var body: some View {
    GeometryReader { geometry in
      let layers = showingLayers
      let inspector = showingInspector
      let panelHeight = max(180, geometry.size.height - 116)
      ZStack {
        if store.project != nil {
          VectorCanvas(session: session, revision: store.revision, fittingInsets: NSEdgeInsets(
            top: 16, left: layers ? 266 : 16,
            bottom: hasContextNavigation ? 128 : 72, right: inspector ? 318 : 16))
        } else {
          VStack(spacing: 17) {
            Image(systemName: "rectangle.badge.plus").font(.system(size: 36, weight: .ultraLight))
            Text("A place to begin.").font(.system(size: 24, weight: .semibold))
            Text("Draw freely, then add a frame when you need a physical size.")
              .font(.system(size: 12)).foregroundStyle(Palette.secondary)
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .background(Color(nsColor: appearance.canvasBackgroundColor))
      .overlay(alignment: .topLeading) {
        if layers {
          ArtworkLayers(session: session, onClose: { showingLayers.toggle() })
            .frame(width: 234, height: min(panelHeight, 480))
            .floatingPanelSurface().padding(FloatingPanelStyle.outerPadding)
        }
      }
      .overlay(alignment: .topTrailing) {
        if inspector {
          FloatingPanel(closeLabel: "Hide Canvas inspector", onClose: { showingInspector = false }) {
            ArtworkInspector(session: session)
          }.frame(width: FloatingPanelStyle.inspectorWidth, height: panelHeight)
            .padding(FloatingPanelStyle.outerPadding)
        }
      }
      .overlay(alignment: .bottomLeading) {
        VStack(alignment: .leading, spacing: 8) {
          if hasContextNavigation {
            contextNavigation.padding(8).floatingPanelSurface()
          }
          WorkspaceToolbarSurface(maxWidth: max(1, geometry.size.width - 32)) {
            tools(layers: layers, inspector: inspector)
          }
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
    .onReceive(NotificationCenter.default.publisher(for: .formShowCanvasInspector)) { notification in
      guard (notification.object as? ArtworkSession) === session else { return }
      showingInspector = true
    }
    .onChange(of: session.dieline) { _, dieline in
      if dieline { session.canvas?.finishText() }
      DispatchQueue.main.async { session.fit() }
    }
  }

  private func chooseTool(_ tool: ArtworkTool) {
    session.canvas?.finishText()
    session.tool = tool
    session.canvas?.window?.makeFirstResponder(session.canvas)
  }

  private var contextNavigation: some View {
    HStack(spacing: WorkspaceToolbarMetrics.spacing) {
      if session.maskEditing != nil {
        WorkspaceToolbarButton("Back to contents", symbol: "chevron.left", showsTitle: true) {
          session.returnFromMask()
          session.canvas?.window?.makeFirstResponder(session.canvas)
        }
      } else if session.componentReturn != nil {
        WorkspaceToolbarButton("Back to instance", symbol: "chevron.left", showsTitle: true) {
          session.returnToComponent()
          session.canvas?.window?.makeFirstResponder(session.canvas)
        }
      }
      if let scope = session.scopeID, session.maskEditing == nil {
        WorkspaceToolbarButton("Canvas", symbol: "square.dashed", showsTitle: true,
          identifier: "canvas-group-root") { session.leaveGroup(toRoot: true) }
        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.secondary)
          .accessibilityHidden(true)
        Text(session.art.elements.first(where: { $0.id == scope })?.title ?? "Group")
          .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
          .frame(maxWidth: 160).help("Editing group contents")
        WorkspaceToolbarDivider()
        WorkspaceToolbarButton("Leave group", symbol: "arrow.uturn.backward", showsTitle: true,
          identifier: "canvas-group-leave") {
          session.leaveGroup()
        }
      }
    }.fixedSize(horizontal: true, vertical: false)
  }

  private func tools(layers: Bool, inspector: Bool) -> some View {
    HStack(spacing: WorkspaceToolbarMetrics.spacing) {
      WorkspaceToolbarButton("Canvas & Surfaces", symbol: "sidebar.left", isSelected: layers,
        value: layers ? "Shown" : "Hidden") { showingLayers.toggle() }
      WorkspaceToolbarButton("Canvas inspector", symbol: "sidebar.right", isSelected: inspector,
        value: inspector ? "Shown" : "Hidden") { showingInspector.toggle() }
      WorkspaceToolbarDivider()
      ForEach(ArtworkTool.allCases, id: \.self) { tool in
        WorkspaceToolbarButton(tool.rawValue.capitalized + " tool", symbol: tool.symbol,
          isSelected: session.tool == tool, help: "\(tool.rawValue.capitalized) · \(tool.shortcut)") { chooseTool(tool) }
      }
      WorkspaceToolbarDivider()
      actions
      CanvasArrangementMenu(session: session)
      WorkspaceToolbarButton("Canvas background", symbol: "circle.lefthalf.filled",
        isSelected: showingBackground, help: "Canvas background color") { showingBackground.toggle() }
        .popover(isPresented: $showingBackground, arrowEdge: .bottom) {
          CanvasBackgroundControls(appearance: appearance).padding(18).frame(width: 264).labInterface()
        }
      WorkspaceToolbarDivider()
      WorkspaceToolbarButton("Zoom out", symbol: "minus") { session.setZoom(session.zoom / 1.2) }
      WorkspaceToolbarButton("Zoom in", symbol: "plus") { session.setZoom(session.zoom * 1.2) }
      WorkspaceToolbarButton("Fit Canvas contents · ⌘0", symbol: "arrow.up.left.and.arrow.down.right") { session.fit() }
      zoomMenu
    }.fixedSize(horizontal: true, vertical: false)
  }

  private var actions: some View {
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
        if session.preview { showingInspector = true }
      }.disabled(session.previewObject == nil)
      Button("Export artwork…", systemImage: "square.and.arrow.up") { exportOptions = true }
        .disabled(session.object == nil || session.object?.isCanvasWorkspace == true && session.selection.isEmpty)
    } label: {
      WorkspaceToolbarMenuLabel(symbol: "ellipsis")
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
      WorkspaceToolbarMenuLabel(symbol: "magnifyingglass", value: "\(Int((session.zoom * 100).rounded()))%")
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

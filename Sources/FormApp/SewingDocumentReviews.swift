import AppKit
import FormCore
import FormGraphics
import SwiftUI
import UniformTypeIdentifiers

struct SewingPatternPreview: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) var dismiss
  @ObservedObject var session: ArtworkSession
  @StateObject private var review = PhysicalDocumentController()
  @StateObject private var model: SewingPatternReviewModel
  init(session: ArtworkSession, model: SewingPatternReviewModel? = nil) {
    self.session = session
    _model = StateObject(wrappedValue: model ?? SewingPatternReviewModel(session: session))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Cutting pattern").font(.system(size: 25, weight: .semibold))
        Spacer()
        Picker("Pattern output", selection: $model.tiled) {
          Text("Large format").tag(false)
          Text("Tiled sheets").tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 275).accessibilityLabel("Pattern output")
        AppCloseButton("Close", keyEquivalent: "\u{1b}") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      HStack(alignment: .top, spacing: 22) {
        if model.tiled {
          SewingTileSettings(draft: model.draft, saved: model.hasSavedOptions,
            save: { model.saveOptions() }, clear: { model.saveOptions(clear: true) })
        }
        VStack(alignment: .leading, spacing: 10) {
          if let proof = model.proof {
            PhysicalDocumentNavigation(controller: review)
            PhysicalDocumentCanvas(controller: review, data: proof, identifier: model.identity)
              .frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 6))
          } else {
            ContentUnavailableView("No cutting proof", systemImage: "scissors",
              description: Text(model.error.isEmpty ? "Annotate supported closed shapes in Canvas first." : model.error))
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          Text(String(format: "%.1f × %.1f mm source · %d piece templates · %d PDF pages",
            model.size.x, model.size.y, model.pieceCount, model.pageCount))
            .font(.system(size: 10, design: .monospaced))
          Text(model.gridDescription).font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }
      }.frame(maxHeight: .infinity)
      Text(model.tiled
        ? "Print at 100% / Actual size with no fit-to-page. Verify the calibration page first. Match labels, trim straight between paired gutter ticks, then butt matching edges; repeated overlap is trimmed away."
        : "Black: cut contour and notches. Blue: stitch outline. Gold: grain and fold guides. Verify the 50 mm square before cutting.")
        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
      HStack {
        ForEach(model.tiled ? ["pdf"] : ["pdf", "svg", "png"], id: \.self) { format in
          Button("Export " + (model.tiled ? "tiled PDF" : format.uppercased())) { export(format) }
            .disabled(model.proof == nil)
        }
        Spacer()
        Text("Export DPI").font(.system(size: 10))
        TextField("Export DPI", text: $model.dpi).textFieldStyle(.roundedBorder).frame(width: 70)
          .accessibilityLabel("Pattern export DPI")
        Text("Vector geometry and preview zoom stay independent.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
      }
      if model.proof != nil, !model.error.isEmpty { Text(model.error).foregroundStyle(Palette.ink).font(.system(size: 11)) }
      if !review.error.isEmpty { Text(review.error).foregroundStyle(Palette.ink).font(.system(size: 11)) }
    }.padding(26).frame(width: 1120, height: 830).background(Palette.paper)
      .onAppear { model.refresh() }
      .onChange(of: session.art) { _, _ in model.refresh() }
      .onChange(of: store.revision) { _, _ in model.refresh() }
      .onChange(of: store.project?.id) { _, _ in model.refresh() }
      .onChange(of: session.object?.id) { _, _ in model.refresh() }
      .onChange(of: model.tiled) { _, _ in model.refresh() }
      .onChange(of: model.draft.values) { _, _ in model.refresh() }
  }
  private func export(_ format: String) {
    NSApp.keyWindow?.makeFirstResponder(nil)
    guard let object = session.object else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = object.name + (model.tiled ? "-sewing-pattern-tiled." : "-sewing-pattern.") + format
    panel.allowedContentTypes = [format == "pdf" ? .pdf : format == "svg" ? .svg : .png]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if model.export(format, path: url) { store.toast("Sewing pattern exported") }
  }
}

struct SewingLayoutPDFReview: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) var dismiss
  @ObservedObject var model: SewingLayoutController
  @StateObject private var review = PhysicalDocumentController()
  @State private var proof: Data?
  @State private var sourceKey: Data?
  @State private var includeFabric = false
  @State private var error = ""
  @State private var size = Point2()
  private var identity: String {
    PhysicalDocumentController.key(
      project: model.projectID, object: model.objectID, kind: "cutting-layout")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Cutting layout PDF").font(.system(size: 25, weight: .semibold))
          Text(model.sourceName + " · vector physical proof").font(.system(size: 11))
            .foregroundStyle(Palette.secondary)
        }
        Spacer()
        Toggle("Fabric reference", isOn: $includeFabric).toggleStyle(.checkbox).font(
          .system(size: 11))
        AppCloseButton("Close", keyEquivalent: "\u{1b}") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if let proof {
        PhysicalDocumentNavigation(controller: review)
        PhysicalDocumentCanvas(controller: review, data: proof, identifier: identity).frame(
          maxWidth: .infinity, maxHeight: .infinity
        ).clipShape(RoundedRectangle(cornerRadius: 6))
        Text(
          String(
            format: "%.1f × %.1f mm · print at 100%% · verify stock dimensions", size.x,
            size.y)
        ).font(.system(size: 10, design: .monospaced))
        Text(
          "Review navigation does not move cut copies. Return to the material cutting layout to edit stock or placements. Export DPI remains in the export controls."
        ).font(.system(size: 10)).foregroundStyle(Palette.secondary)
      } else {
        ContentUnavailableView(
          "No valid layout proof", systemImage: "doc",
          description: Text(error.isEmpty ? "Complete a valid cutting layout first." : error))
      }
      if proof != nil, !error.isEmpty { Text(error).foregroundStyle(Palette.ink).font(.system(size: 11)) }
      if !review.error.isEmpty { Text(review.error).foregroundStyle(Palette.ink).font(.system(size: 11)) }
    }.padding(24).frame(width: 1080, height: 790).background(Palette.paper)
      .onAppear {
        includeFabric = model.showFabric
        refresh()
      }
      .onChange(of: includeFabric) { _, _ in refresh() }
      .onChange(of: model.layout) { _, _ in refresh() }
      .onChange(of: model.source) { _, _ in refresh() }
      .onChange(of: store.revision) { _, _ in refresh() }
  }
  private func refresh() {
    do {
      guard model.refreshContext(), model.sourceAvailable, let project = store.project,
        project.id == model.projectID
      else { throw FormError.missing("The cutting source is no longer open.") }
      let material = project.material(model.layout.materialID)
      let fabric =
        includeFabric ? try project.resolvedFabricPattern(materialID: model.layout.materialID) : nil
      var key = try JSONEncoder.form.encode(model.source)
      key.append(try JSONEncoder.form.encode(model.layout))
      key.append(try JSONEncoder.form.encode(material))
      if let fabric { key.append(try JSONEncoder.form.encode(fabric.renderDefinition)) }
      key.append(Data("\(identity)/\(includeFabric)/\(GeometryFactory.fontRevision)".utf8))
      guard sourceKey != key else { return }
      let output = try SewingLayoutOutput(
        layout: model.layout, source: model.source, fabric: fabric, fabricColor: material.color,
        includeFabricPreview: includeFabric)
      proof = try output.pdf(assets: model.assets, dpi: 150)
      size = .init(output.width, output.height)
      sourceKey = key
      error = ""
    } catch {
      proof = nil
      sourceKey = nil
      self.error = error.localizedDescription
    }
  }
}

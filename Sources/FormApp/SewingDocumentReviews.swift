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
  @State private var dpi = 150.0
  @State private var error = ""
  @State private var proof: Data?
  @State private var sourceKey: Data?
  @State private var size = Point2()
  @State private var pieceCount = 0
  private var identity: String {
    PhysicalDocumentController.key(
      project: store.project?.id, object: session.object?.id, kind: "sewing-pattern")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack {
        Text("Cutting pattern").font(.system(size: 25, design: .serif))
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if let proof {
        PhysicalDocumentNavigation(controller: review)
        PhysicalDocumentCanvas(controller: review, data: proof, identifier: identity)
          .frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(
            RoundedRectangle(cornerRadius: 6))
        HStack {
          Text(
            String(
              format: "%.1f × %.1f mm · %d piece templates · print at 100%%", size.x, size.y,
              pieceCount)
          ).font(.system(size: 10, design: .monospaced))
          Spacer()
          TextField("Export DPI", value: $dpi, format: .number).textFieldStyle(.roundedBorder)
            .frame(width: 70).accessibilityLabel("Pattern export DPI")
          Text("Export DPI").font(.system(size: 10))
        }
        Text(
          "Black: cut contour and notches. Blue: stitch outline. Gold: grain and fold guides. Verify the 50 mm square before cutting. Preview zoom and export DPI are independent."
        ).font(.system(size: 10)).foregroundStyle(Palette.secondary)
        HStack {
          ForEach(["pdf", "svg", "png"], id: \.self) { format in
            Button("Export " + format.uppercased()) { export(format) }
          }
          Spacer()
        }
      } else {
        ContentUnavailableView(
          "No cutting proof", systemImage: "scissors",
          description: Text(
            error.isEmpty ? "Annotate supported closed shapes in Canvas first." : error))
      }
      if proof != nil, !error.isEmpty { Text(error).foregroundStyle(.red).font(.system(size: 11)) }
      if !review.error.isEmpty { Text(review.error).foregroundStyle(.red).font(.system(size: 11)) }
    }.padding(26).frame(width: 1000, height: 790).background(Palette.paper)
      .onAppear { refresh() }
      .onChange(of: session.art) { _, _ in refresh() }
      .onChange(of: store.revision) { _, _ in refresh() }
      .onChange(of: store.project?.id) { _, _ in refresh() }
  }
  private func refresh() {
    do {
      var key = try JSONEncoder.form.encode(session.art)
      key.append(Data("\(identity)/\(session.assets.path)/\(GeometryFactory.fontRevision)".utf8))
      guard key != sourceKey else { return }
      let output = try SewingPatternOutput(source: session.art)
      // Technical paths stay vector. This fixed density is only for supported effect layers.
      let data = try output.pdf(assets: session.assets, dpi: 150)
      size = output.plan.frameSize
      pieceCount = output.plan.pieces.count
      proof = data
      sourceKey = key
      error = ""
    } catch {
      proof = nil
      sourceKey = nil
      self.error = error.localizedDescription
    }
  }
  private func export(_ format: String) {
    NSApp.keyWindow?.makeFirstResponder(nil)
    guard let object = session.object else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = object.name + "-sewing-pattern." + format
    panel.allowedContentTypes = [format == "pdf" ? .pdf : format == "svg" ? .svg : .png]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      _ = try store.exportSewingPattern(
        object: object, arguments: ["format": format, "path": url.path, "dpi": dpi])
      error = ""
      store.toast("Sewing pattern exported")
    } catch { self.error = error.localizedDescription }
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
          Text("Cutting layout PDF").font(.system(size: 25, design: .serif))
          Text(model.sourceName + " · vector physical proof").font(.system(size: 11))
            .foregroundStyle(Palette.secondary)
        }
        Spacer()
        Toggle("Fabric reference", isOn: $includeFabric).toggleStyle(.checkbox).font(
          .system(size: 11))
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
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
      if proof != nil, !error.isEmpty { Text(error).foregroundStyle(.red).font(.system(size: 11)) }
      if !review.error.isEmpty { Text(review.error).foregroundStyle(.red).font(.system(size: 11)) }
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

import AppKit
import FormCore
import FormGraphics
import SwiftUI

extension StudioStore {
  @discardableResult func createRoundedPouchPattern(parameters: [String: Any]) throws -> UUID {
    let template = try SewingPatternTemplates.roundedPouch(parameters)
    var created: UUID?
    try engine.edit("Created measured rounded pouch pattern", source: "Studio") { project in
      _ = try project.ensureCanvasWorkspace()
      var frame = try project.makeObject(
        recipeID: "artboard", name: "Rounded pouch / measured cutting pattern",
        parameters: ["width": template.frameSize.x, "depth": template.frameSize.y])
      frame.artwork = template.artwork
      project.objects.append(frame)
      created = frame.id
    }
    guard let created else {
      throw FormError.invalid("Open a project before creating a sewing pattern.")
    }
    changed()
    showSurface(.artwork)
    artworkSession.activate(created)
    DispatchQueue.main.async { self.artworkSession.canvas?.fit(all: false) }
    return created
  }
}

/// Explicit creation produces an independent editable document. Measurement changes never overwrite
/// manually edited source curves in an existing pattern.
struct RoundedPouchControls: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) var dismiss
  @State private var width = 260.0
  @State private var height = 180.0
  @State private var radius = 35.0
  @State private var allowance = 10.0
  @State private var facing = 40.0
  @State private var material = "flight-nylon"
  @State private var error = ""
  private var parameters: [String: Any] {
    [
      "width": width, "height": height, "corner_radius": radius, "seam_allowance": allowance,
      "facing_height": facing, "material_id": material,
    ]
  }
  private var template: SewingPatternTemplate? {
    try? SewingPatternTemplates.roundedPouch(parameters)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Measured rounded pouch").font(.system(size: 25, design: .serif))
        Spacer()
        Button("Cancel") { dismiss() }
      }
      HStack(alignment: .top, spacing: 28) {
        VStack(alignment: .leading, spacing: 13) {
          measurement("Stitch width", value: $width)
          measurement("Stitch height", value: $height)
          measurement("Lower corner radius", value: $radius)
          measurement("Uniform allowance", value: $allowance)
          measurement("Facing height", value: $facing)
          Picker("Fabric", selection: $material) {
            ForEach(store.materials.filter { $0.fabric != nil }) { Text($0.name).tag($0.id) }
          }
          Text(
            "Two main panels + two zipper facings. Editable cubic source edges, cut-copy seam pairs, physical notches and construction notes are included."
          ).font(.system(size: 11)).foregroundStyle(Palette.secondary)
          Text(
            "Dimensions describe the stitch outline. This original test pattern has no verified capacity, zipper compatibility, garment fit, or assembled cloth simulation. Make a fabric test before production."
          ).font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }.frame(width: 270)
        if let template, let output = try? SewingPatternOutput(source: template.artwork) {
          let size = output.plan.frameSize
          Image(
            nsImage: ArtworkRenderer.image(
              output.combinedArtwork, width: size.x, height: size.y, assets: store.repository.root,
              pixelsPerMM: 1)
          )
          .resizable().interpolation(.high).scaledToFit().frame(width: 390, height: 440).background(
            .white)
        } else {
          ContentUnavailableView(
            "Adjust measurements", systemImage: "scissors",
            description: Text(
              "Keep the lower radius below half the width and leave20 mm of straight side.")
          ).frame(width: 390, height: 440)
        }
      }
      if !error.isEmpty { Text(error).foregroundStyle(.red).font(.system(size: 11)) }
      HStack {
        Text("Creates a new source frame; your current drawing stays intact.").font(
          .system(size: 10)
        ).foregroundStyle(Palette.secondary)
        Spacer()
        Button("Create editable pattern") { create() }.keyboardShortcut(.defaultAction).disabled(
          template == nil)
      }
    }.padding(28).frame(width: 760).background(Palette.paper)
  }
  private func measurement(_ label: String, value: Binding<Double>) -> some View {
    HStack {
      Text(label).font(.system(size: 11))
      Spacer()
      TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder).frame(
        width: 85)
      Text("mm").font(.system(size: 10)).foregroundStyle(Palette.secondary)
    }
  }
  private func create() {
    NSApp.keyWindow?.makeFirstResponder(nil)
    do {
      _ = try store.createRoundedPouchPattern(parameters: parameters)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

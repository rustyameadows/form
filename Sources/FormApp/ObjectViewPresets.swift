import SwiftUI

/// Reusable view settings exclude the source and placement, so a preset can
/// be applied to any object without changing another placement.
struct ObjectViewPreset: Codable, Equatable, Identifiable {
  var id = UUID()
  var name: String
  var azimuth: Double
  var elevation: Double
  var style: String

  var isValid: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && azimuth.isFinite && elevation.isFinite
      && ["silhouette", "lines", "rendered"].contains(style)
  }
}

struct ObjectViewPresetControls: View {
  var azimuth: Double
  var elevation: Double
  var style: String
  var onApply: (Double, Double, String) -> Void
  @AppStorage("lab.objectViewPresets.v1") private var storedPresets = Data()
  @State private var showingSave = false
  @State private var presetName = ""

  private var decodedPresets: [ObjectViewPreset]? {
    if storedPresets.isEmpty { return [] }
    guard let values = try? JSONDecoder().decode([ObjectViewPreset].self, from: storedPresets),
      values.allSatisfy(\.isValid) else { return nil }
    return values
  }

  private var presets: [ObjectViewPreset] { decodedPresets ?? [] }

  private func save(_ values: [ObjectViewPreset]) {
    if let data = try? JSONEncoder().encode(values) { storedPresets = data }
  }

  var body: some View {
    HStack {
      Menu("View presets") {
        if decodedPresets == nil { Text("Saved presets could not be read") }
        else if presets.isEmpty { Text("No saved presets") }
        ForEach(presets) { preset in
          Button(preset.name) {
            onApply(preset.azimuth, preset.elevation, preset.style)
          }
        }
        Divider()
        Button("Save current view…") { presetName = ""; showingSave = true }
          .disabled(decodedPresets == nil)
        if !presets.isEmpty {
          Menu("Delete preset") {
            ForEach(presets) { preset in
              Button(preset.name) { save(presets.filter { $0.id != preset.id }) }
            }
          }
        }
      }
      Spacer()
    }
    .font(.system(size: 10))
    .sheet(isPresented: $showingSave) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Save view preset").font(.system(size: 16, weight: .semibold))
        TextField("Preset name", text: $presetName)
          .textFieldStyle(.roundedBorder)
          .onSubmit { saveCurrent() }
        HStack {
          Spacer()
          Button("Cancel") { showingSave = false }
          Button("Save") { saveCurrent() }
            .buttonStyle(.borderedProminent)
            .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding(20)
      .frame(width: 320)
    }
  }

  private func saveCurrent() {
    let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
    let preset = ObjectViewPreset(name: name, azimuth: azimuth, elevation: elevation, style: style)
    guard preset.isValid else { return }
    save(presets + [preset])
    showingSave = false
  }
}

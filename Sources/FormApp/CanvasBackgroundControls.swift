import AppKit
import SwiftUI

/// Workspace appearance is a local preference, independent of frame backgrounds
/// and exported artwork. The toolbar and Settings use the same controls.
struct CanvasBackgroundControls: View {
  @ObservedObject var appearance: InterfaceAppearance
  @State private var issue: String?
  private let presets: [(name: String, hex: String)] = [
    ("White", "#FFFFFF"), ("Light gray", InterfaceAppearance.defaultCanvasBackground),
    ("Medium gray", "#B8B8B8"), ("Charcoal", "#333333"), ("Black", "#161616"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Canvas background").font(.system(size: 13, weight: .semibold))
      HStack(spacing: 9) {
        ForEach(presets, id: \.hex) { preset in
          Button {
            apply { try appearance.setCanvasBackground(preset.hex) }
          } label: {
            RoundedRectangle(cornerRadius: 5)
              .fill(Color(nsColor: NSColor(hex: preset.hex)))
              .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(
                  appearance.canvasBackgroundHex == preset.hex ? Palette.accent : Palette.line,
                  lineWidth: appearance.canvasBackgroundHex == preset.hex ? 2 : 1)
              }
              .overlay {
                if appearance.canvasBackgroundHex == preset.hex {
                  Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(nsColor: appearance.canvasLabelColor))
                }
              }
              .frame(width: 32, height: 32)
              .contentShape(RoundedRectangle(cornerRadius: 5))
          }.buttonStyle(.plain).help(preset.name)
            .accessibilityLabel(preset.name + " Canvas background")
            .accessibilityValue(appearance.canvasBackgroundHex == preset.hex ? "Selected" : "")
            .accessibilityAddTraits(appearance.canvasBackgroundHex == preset.hex ? .isSelected : [])
        }
      }
      InspectorColorPicker("Custom color", selection: Binding(
        get: { Color(nsColor: appearance.canvasBackgroundColor) },
        set: { color in apply { try appearance.setCanvasBackground(NSColor(color)) } }),
        supportsOpacity: false, targetID: "canvas-background")
        .accessibilityLabel("Custom Canvas background")
      Text("Workspace only. Frame backgrounds and exports keep their own colors.")
        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let issue {
        Label(issue, systemImage: "exclamationmark.circle").font(.system(size: 11))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func apply(_ action: () throws -> Void) {
    do { try action(); issue = nil } catch { issue = error.localizedDescription }
  }
}

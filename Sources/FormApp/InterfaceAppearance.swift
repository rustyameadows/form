import AppKit
import Combine
import FormCore
import SwiftUI

extension Notification.Name {
  static let labAppearanceChanged = Notification.Name("lab.interfaceAppearanceChanged")
}

/// App preferences only: never stored in a product, artwork, or material library.
@MainActor final class InterfaceAppearance: ObservableObject {
  static let defaultAccent = "#245BFF"
  static let shared = InterfaceAppearance.environment()
  @Published private(set) var accentHex: String
  private let defaults: UserDefaults?
  private let file: URL?
  private struct Saved: Codable { var accentHex: String }
  init(defaults: UserDefaults? = nil, file: URL? = nil) {
    self.defaults = defaults; self.file = file
    let stored: String?
    if let file, let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Saved.self, from: data) { stored = value.accentHex }
    else { stored = defaults?.string(forKey: "LAB.interfaceAccent") }
    accentHex = (try? Self.normalized(stored ?? Self.defaultAccent)) ?? Self.defaultAccent
  }
  private static func environment() -> InterfaceAppearance {
    if let path = LabIdentity.libraryOverride() { return .init(file: URL(fileURLWithPath: path).appendingPathComponent("Appearance.json")) }
    return .init(defaults: .standard)
  }
  static func normalized(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    guard digits.utf8.count == 6, digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
      throw FormError.invalid("Enter a six-digit color, such as #245BFF.")
    }
    return "#" + digits.uppercased()
  }
  func setAccent(_ raw: String) throws {
    let value = try Self.normalized(raw)
    guard value != accentHex else { return }
    if let file {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(Saved(accentHex: value)).write(to: file, options: .atomic)
    }
    defaults?.set(value, forKey: "LAB.interfaceAccent")
    accentHex = value
    NotificationCenter.default.post(name: .labAppearanceChanged, object: self)
  }
  func setAccent(_ color: NSColor) throws {
    guard let c = color.usingColorSpace(.sRGB) else { throw FormError.invalid("Choose an RGB accent color.") }
    try setAccent(String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())))
  }
  static func whiteContrast(_ color: NSColor) -> Double {
    let c = color.usingColorSpace(.sRGB)!
    func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    return 1.05 / (0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent) + 0.05)
  }
  var selectedColor: NSColor { NSColor(hex: accentHex) }
  /// One hue, with a readable tone for selections and controls on white.
  var controlColor: NSColor {
    let c = selectedColor.usingColorSpace(.sRGB)!
    var scale = 1.0
    while scale > 0.001 {
      let candidate = NSColor(srgbRed: c.redComponent * scale, green: c.greenComponent * scale, blue: c.blueComponent * scale, alpha: 1)
      if Self.whiteContrast(candidate) >= 4.5 { return candidate }
      scale *= 0.94
    }
    return .black
  }
}

enum Palette {
  static let ink = Color.black
  static let secondary = Color(nsColor: secondaryNS)
  static let paper = Color.white
  static let surface = Color(nsColor: surfaceNS)
  static let line = Color(nsColor: NSColor(hex: "#DCDCDC"))
  static let secondaryNS = NSColor(hex: "#666666")
  static let surfaceNS = NSColor(hex: "#F2F2F2")
  @MainActor static var accentNS: NSColor { InterfaceAppearance.shared.controlColor }
  @MainActor static var accent: Color { Color(nsColor: accentNS) }
  static let numericFont = Font.system(size: 11, design: .monospaced)
}

private struct InterfaceStyle: ViewModifier {
  @ObservedObject private var appearance = InterfaceAppearance.shared
  func body(content: Content) -> some View {
    content.font(.system(size: 12)).foregroundStyle(Palette.ink)
      .tint(Color(nsColor: appearance.controlColor)).accentColor(Color(nsColor: appearance.controlColor))
      .preferredColorScheme(.light)
  }
}
extension View { func labInterface() -> some View { modifier(InterfaceStyle()) } }

struct AppearanceSettingsView: View {
  @ObservedObject var appearance: InterfaceAppearance
  @ObservedObject var store: StudioStore
  @State private var hex = ""
  @State private var issue: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("Settings").font(.system(size: 24, weight: .semibold))
      Text("SF for the interface. SF Mono for values and technical details.").foregroundStyle(Palette.secondary)
      Divider()
      ColorPicker("Accent color", selection: Binding(get: { Color(nsColor: appearance.selectedColor) }, set: { color in apply { try appearance.setAccent(NSColor(color)) } }), supportsOpacity: false)
        .accessibilityLabel("App accent color")
      HStack {
        TextField("#RRGGBB", text: $hex).font(Palette.numericFont).textFieldStyle(.roundedBorder).frame(width: 120).accessibilityLabel("Accent hex color").onSubmit(applyHex)
        Button("Apply", action: applyHex).accessibilityLabel("Apply app accent")
        Spacer()
        Button("Reset to blue") { apply { try appearance.setAccent(InterfaceAppearance.defaultAccent) } }
      }
      HStack(spacing: 12) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
        Text("Selected control").font(.system(size: 12, weight: .medium))
        Spacer()
        Text("125.00 mm").font(Palette.numericFont).foregroundStyle(Palette.secondary)
      }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
      if let issue { Label(issue, systemImage: "exclamationmark.circle").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
      Text("Applies throughout LAB. Pale colors use a darker tone for readable controls on white.").font(.system(size: 11)).foregroundStyle(Palette.secondary)
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        Text("Units").font(.system(size: 13, weight: .semibold))
        Picker("Project dimensions", selection: Binding(
          get: { store.project?.unit ?? "mm" },
          set: { unit in store.edit("Changed units") { $0.unit = unit } }
        )) {
          Text("Millimeters").tag("mm")
          Text("Inches").tag("in")
        }.disabled(store.showingHome || store.project == nil)
        Picker("Canvas units", selection: Binding(
          get: { store.artworkSession.unit },
          set: { unit in
            NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
            store.artworkSession.mutate { $0.unit = unit }
          }
        )) {
          Text("Millimeters").tag(PhysicalUnit.mm)
          Text("Centimeters").tag(PhysicalUnit.cm)
          Text("Inches").tag(PhysicalUnit.inches)
          Text("Points").tag(PhysicalUnit.points)
        }.disabled(store.showingHome || store.artworkSession.object == nil)
      }
    }.padding(28).frame(width: 460).background(Palette.paper).labInterface()
      .onAppear { hex = appearance.accentHex }
      .onChange(of: appearance.accentHex) { _, value in hex = value; issue = nil }
  }
  private func apply(_ body: () throws -> Void) { do { try body(); hex = appearance.accentHex; issue = nil } catch { issue = error.localizedDescription } }
  private func applyHex() { apply { try appearance.setAccent(hex) } }
}

extension StudioStore {
  func refreshInterfaceAppearance(accent: NSColor? = nil) {
    objectWillChange.send()
    artworkSession.objectWillChange.send()
    let color = accent ?? Palette.accentNS
    scene?.refreshInterfaceAccent(color)
    studioComposition.stage.refreshInterfaceAccent(color)
    artworkSession.canvas?.refreshInterfaceAccent(color)
    func redraw(_ view: NSView) { view.needsDisplay = true; for child in view.subviews { redraw(child) } }
    for window in NSApp.windows { if let view = window.contentView { redraw(view) } }
  }
}

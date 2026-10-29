import AppKit
import Combine

/// Floating-point sRGB is retained until an explicit channel/hex edit. Merely
/// displaying a color never rounds it through an eight-bit hex representation.
struct InspectorColorComponents: Equatable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double

  init?(_ color: NSColor) {
    guard let rgb = color.usingColorSpace(.extendedSRGB) else { return nil }
    red = rgb.redComponent; green = rgb.greenComponent
    blue = rgb.blueComponent; alpha = rgb.alphaComponent
    guard [red, green, blue, alpha].allSatisfy(\.isFinite) else { return nil }
  }

  init(red: Double, green: Double, blue: Double, alpha: Double) {
    self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
  }

  var color: NSColor { NSColor(colorSpace: .extendedSRGB, components: [red, green, blue, alpha], count: 4) }
  var hex: String {
    func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
  }
  var hsv: (hue: Double, saturation: Double, brightness: Double) {
    let r = min(1, max(0, red)), g = min(1, max(0, green)), b = min(1, max(0, blue))
    let high = max(r, max(g, b)), low = min(r, min(g, b)), delta = high - low
    var hue = 0.0
    if delta > 0 {
      if high == r { hue = (g - b) / delta }
      else if high == g { hue = (b - r) / delta + 2 }
      else { hue = (r - g) / delta + 4 }
      hue /= 6
      if hue < 0 { hue += 1 }
    }
    return (hue, high == 0 ? 0 : delta / high, high)
  }

  static func hsv(_ hue: Double, _ saturation: Double, _ brightness: Double, alpha: Double) -> Self {
    let h = (hue - floor(hue)) * 6, i = Int(floor(h)), f = h - floor(h)
    let s = min(1, max(0, saturation)), v = min(1, max(0, brightness))
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    let rgb: (Double, Double, Double)
    switch i % 6 {
    case 0: rgb = (v, t, p)
    case 1: rgb = (q, v, p)
    case 2: rgb = (p, v, t)
    case 3: rgb = (p, q, v)
    case 4: rgb = (t, p, v)
    default: rgb = (v, p, q)
    }
    return .init(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
  }

  func replacingHex(_ input: String, supportsOpacity: Bool) -> Self? {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
    guard digits.count == 6 || supportsOpacity && digits.count == 8,
      digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
      let number = UInt32(digits, radix: 16) else { return nil }
    let rgb = digits.count == 8 ? number >> 8 : number
    return .init(red: Double((rgb >> 16) & 255) / 255,
      green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255,
      alpha: digits.count == 8 ? Double(number & 255) / 255 : alpha)
  }
}

@MainActor final class InspectorColorState: ObservableObject {
  @Published private(set) var components = InspectorColorComponents(red: 0, green: 0, blue: 0, alpha: 1)
  @Published private(set) var hue = 0.0
  @Published private(set) var saturation = 0.0
  @Published private(set) var brightness = 0.0
  @Published var title = "Color"
  @Published var supportsOpacity = true
  @Published var isPinned = false
  @Published private(set) var targetRevision = UUID()
  @Published private(set) var issue: String?
  @Published private(set) var canEditRGB = true
  private(set) var isEditing = false
  var onChange: ((InspectorColorComponents) -> Void)?
  var onEditingChanged: ((Bool) -> Void)?

  func load(_ color: NSColor, newTarget: Bool = false) {
    if newTarget { endEditing(); targetRevision = UUID() }
    guard let value = InspectorColorComponents(color) else {
      canEditRGB = false
      issue = "This color needs the Apple picker."
      return
    }
    issue = nil; canEditRGB = true
    guard value != components || newTarget else { return }
    components = value
    let hsv = value.hsv
    if hsv.saturation > 0 { hue = hsv.hue }
    saturation = hsv.saturation; brightness = hsv.brightness
  }

  func beginEditing() {
    guard !isEditing else { return }
    isEditing = true; onEditingChanged?(true)
  }
  func endEditing() {
    guard isEditing else { return }
    isEditing = false; onEditingChanged?(false)
  }
  func setEditing(_ editing: Bool) { if editing { beginEditing() } else { endEditing() } }

  private func commit(_ value: InspectorColorComponents, updateHSV: Bool = true) {
    guard value != components else { return }
    let discrete = !isEditing
    if discrete { beginEditing() }
    components = value; issue = nil
    if updateHSV {
      let hsv = value.hsv
      if hsv.saturation > 0 { hue = hsv.hue }
      saturation = hsv.saturation; brightness = hsv.brightness
    }
    onChange?(value)
    if discrete { endEditing() }
  }

  func setHueSaturation(_ hue: Double, _ saturation: Double) {
    guard canEditRGB, hue.isFinite, saturation.isFinite else { return }
    self.hue = hue - floor(hue); self.saturation = min(1, max(0, saturation))
    commit(.hsv(self.hue, self.saturation, brightness, alpha: components.alpha), updateHSV: false)
  }
  func setBrightness(_ value: Double) {
    guard canEditRGB, value.isFinite else { return }
    brightness = min(1, max(0, value))
    commit(.hsv(hue, saturation, brightness, alpha: components.alpha), updateHSV: false)
  }
  func setAlpha(_ value: Double) {
    guard canEditRGB, supportsOpacity, value.isFinite, (0...1).contains(value) else { return }
    var next = components; next.alpha = value; commit(next, updateHSV: false)
  }
  func setChannel(_ channel: Int, _ value: Double) {
    guard canEditRGB, value.isFinite, (0...255).contains(value) else { return }
    var next = components
    switch channel { case 0: next.red = value / 255; case 1: next.green = value / 255; default: next.blue = value / 255 }
    commit(next)
  }
  @discardableResult func setHex(_ text: String) -> Bool {
    guard canEditRGB else { return false }
    guard let next = components.replacingHex(text, supportsOpacity: supportsOpacity) else {
      issue = supportsOpacity ? "Enter #RRGGBB or #RRGGBBAA." : "Enter six-digit RGB, such as #245BFF."
      return false
    }
    commit(next); issue = nil; return true
  }
  func setNativeColor(_ color: NSColor) {
    guard var next = InspectorColorComponents(color) else { return }
    if !supportsOpacity && canEditRGB { next.alpha = components.alpha }
    canEditRGB = true
    commit(next)
  }
}

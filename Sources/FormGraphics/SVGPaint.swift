import FormCore
import Foundation

struct SVGColor {
  var hex: String
  var alpha: Double = 1
  static func parse(_ raw: String, current: String = "black") throws -> SVGColor {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if text == "currentcolor" {
      return try parse(current.lowercased() == "currentcolor" ? "black" : current)
    }
    if text == "transparent" { return .init(hex: "#000000", alpha: 0) }
    if let named = SVGNamedColors.values[text] { return .init(hex: named) }
    if text.hasPrefix("#") {
      var digits = String(text.dropFirst())
      if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
      guard [6, 8].contains(digits.count), let value = UInt64(digits, radix: 16) else {
        throw FormError.invalid("Invalid SVG hex color: \(raw)")
      }
      return .init(
        hex: String(format: "#%06X", digits.count == 8 ? value >> 8 : value),
        alpha: digits.count == 8 ? Double(value & 255) / 255 : 1)
    }
    let functions = ["rgb(", "rgba(", "hsl(", "hsla("]
    guard let function = functions.first(where: text.hasPrefix), text.hasSuffix(")") else {
      throw FormError.invalid("Unsupported SVG color: \(raw)")
    }
    let fields = text.dropFirst(function.count).dropLast().split(whereSeparator: {
      $0.isWhitespace || $0 == "," || $0 == "/"
    }).map(String.init)
    guard (3...4).contains(fields.count) else {
      throw FormError.invalid("Invalid SVG color components.")
    }
    func fraction(_ value: String, denominator: Double) throws -> Double {
      guard let n = Double(value.replacingOccurrences(of: "%", with: "")), n.isFinite else {
        throw FormError.invalid("Invalid SVG color number.")
      }
      return min(1, max(0, n / (value.hasSuffix("%") ? 100 : denominator)))
    }
    let alpha = try fields.count == 4 ? fraction(fields[3], denominator: 1) : 1
    var red: Double
    var green: Double
    var blue: Double
    if function.hasPrefix("rgb") {
      red = try fraction(fields[0], denominator: 255)
      green = try fraction(fields[1], denominator: 255)
      blue = try fraction(fields[2], denominator: 255)
    } else {
      let hue = fields[0]
      var scanner = SVGScanner(hue)
      var angle = try scanner.number()
      let unit = String(decoding: scanner.bytes[scanner.index...], as: UTF8.self)
      switch unit {
      case "", "deg": break
      case "rad": angle *= 180 / .pi
      case "turn": angle *= 360
      case "grad": angle *= 0.9
      default: throw FormError.invalid("Invalid hue unit.")
      }
      let h =
        (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
      guard fields[1].hasSuffix("%"), fields[2].hasSuffix("%") else {
        throw FormError.invalid("HSL saturation and lightness need percentages.")
      }
      let saturation = try fraction(fields[1], denominator: 1)
      let lightness = try fraction(fields[2], denominator: 1)
      let c = (1 - abs(2 * lightness - 1)) * saturation
      let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
      let m = lightness - c / 2
      switch Int(h) {
      case 0: (red, green, blue) = (c, x, 0)
      case 1: (red, green, blue) = (x, c, 0)
      case 2: (red, green, blue) = (0, c, x)
      case 3: (red, green, blue) = (0, x, c)
      case 4: (red, green, blue) = (x, 0, c)
      default: (red, green, blue) = (c, 0, x)
      }
      red += m
      green += m
      blue += m
    }
    return .init(
      hex: String(
        format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
        Int((blue * 255).rounded())), alpha: alpha)
  }
}

enum SVGLength {
  static let mmPerPixel = 25.4 / 96
  static func value(_ raw: String, reference: Double = 1, font: Double = 16) throws -> Double {
    var scanner = SVGScanner(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    let number = try scanner.number()
    let unit = String(decoding: scanner.bytes[scanner.index...], as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines
    ).lowercased()
    let factor: Double
    switch unit {
    case "", "px": factor = 1
    case "%": factor = reference / 100
    case "mm": factor = 96 / 25.4
    case "cm": factor = 960 / 25.4
    case "in": factor = 96
    case "pt": factor = 96 / 72
    case "pc": factor = 16
    case "q": factor = 96 / 101.6
    case "em": factor = font
    default: throw FormError.invalid("Unsupported SVG length unit: \(unit)")
    }
    let result = number * factor
    guard result.isFinite, abs(result) <= 1e9 else {
      throw FormError.invalid("SVG length is out of range.")
    }
    return result
  }
  static func opacity(_ raw: String?) throws -> Double {
    guard let raw else { return 1 }
    return min(1, max(0, try value(raw, reference: 1)))
  }
}

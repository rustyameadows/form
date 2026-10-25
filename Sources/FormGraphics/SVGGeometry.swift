import CoreGraphics
import FormCore
import Foundation

struct SVGScanner {
  let bytes: [UInt8]
  var index = 0
  init(_ text: String) { bytes = Array(text.utf8) }
  mutating func skip() {
    while index < bytes.count && [9, 10, 13, 32, 44].contains(bytes[index]) { index += 1 }
  }
  mutating func end() -> Bool {
    skip()
    return index == bytes.count
  }
  mutating func take(_ value: UInt8) -> Bool {
    skip()
    guard index < bytes.count, bytes[index] == value else { return false }
    index += 1
    return true
  }
  mutating func letter() -> UInt8? {
    skip()
    guard index < bytes.count,
      (65...90).contains(bytes[index]) || (97...122).contains(bytes[index])
    else { return nil }
    defer { index += 1 }
    return bytes[index]
  }
  mutating func number() throws -> Double {
    skip()
    let start = index
    if index < bytes.count && [43, 45].contains(bytes[index]) { index += 1 }
    var digits = 0
    while index < bytes.count && (48...57).contains(bytes[index]) {
      index += 1
      digits += 1
    }
    if index < bytes.count && bytes[index] == 46 {
      index += 1
      while index < bytes.count && (48...57).contains(bytes[index]) {
        index += 1
        digits += 1
      }
    }
    guard digits > 0 else { throw FormError.invalid("SVG: expected a number near byte \(start).") }
    if index + 1 < bytes.count && [69, 101].contains(bytes[index])
      && ((48...57).contains(bytes[index + 1]) || [43, 45].contains(bytes[index + 1]))
    {
      index += 1
      if index < bytes.count && [43, 45].contains(bytes[index]) { index += 1 }
      let exponent = index
      while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
      guard index > exponent else { throw FormError.invalid("SVG: incomplete exponent.") }
    }
    guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)),
      value.isFinite, abs(value) <= 1e9
    else { throw FormError.invalid("SVG: number out of range.") }
    return value
  }
  mutating func flag() throws -> Bool {
    skip()
    guard index < bytes.count, [48, 49].contains(bytes[index]) else {
      throw FormError.invalid("SVG: an arc flag must be 0 or 1.")
    }
    defer { index += 1 }
    return bytes[index] == 49
  }
  static func numbers(_ text: String) throws -> [Double] {
    var scanner = Self(text)
    var result: [Double] = []
    while !scanner.end() {
      guard result.count < 200_000 else { throw FormError.invalid("SVG number list is too long.") }
      result.append(try scanner.number())
    }
    return result
  }
}

enum SVGGeometry {
  static func transform(_ text: String) throws -> Affine2 {
    var s = SVGScanner(text)
    var result = Affine2()
    while !s.end() {
      var name: [UInt8] = []
      while let c = s.letter() { name.append(c) }
      guard !name.isEmpty, s.take(40) else { throw FormError.invalid("Invalid SVG transform.") }
      var values: [Double] = []
      while !s.take(41) {
        guard values.count < 6, !s.end() else {
          throw FormError.invalid("Invalid SVG transform arguments.")
        }
        values.append(try s.number())
      }
      let t: Affine2
      switch (String(decoding: name, as: UTF8.self), values.count) {
      case ("matrix", 6):
        t = .init(
          a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
      case ("translate", 1), ("translate", 2):
        t = .translation(values[0], values.count == 2 ? values[1] : 0)
      case ("scale", 1), ("scale", 2):
        t = .scale(values[0], values.count == 2 ? values[1] : values[0])
      case ("rotate", 1): t = .rotation(values[0])
      case ("rotate", 3):
        t = .translation(values[1], values[2]).followed(by: .rotation(values[0])).followed(
          by: .translation(-values[1], -values[2]))
      case ("skewX", 1): t = .init(c: tan(values[0] * .pi / 180))
      case ("skewY", 1): t = .init(b: tan(values[0] * .pi / 180))
      default: throw FormError.invalid("Unsupported SVG transform or argument count.")
      }
      result = result.followed(by: t)
    }
    guard [result.a, result.b, result.c, result.d, result.tx, result.ty].allSatisfy(\.isFinite),
      result.inverse != nil
    else {
      throw FormError.invalid("SVG transform is singular or out of range.")
    }
    return result
  }

  static func path(_ text: String) throws -> CGPath {
    var s = SVGScanner(text)
    var command: UInt8?
    var previous: UInt8 = 0
    var point = CGPoint.zero
    var start = CGPoint.zero
    var cubic: CGPoint?
    var quadratic: CGPoint?
    var segments = 0
    let path = CGMutablePath()
    func reflected(_ control: CGPoint?) -> CGPoint {
      guard let control else { return point }
      return .init(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }
    while !s.end() {
      if let next = s.letter() { command = next }
      guard let raw = command else { throw FormError.invalid("SVG path must begin with moveto.") }
      let upper = raw >= 97 ? raw - 32 : raw
      let relative = raw >= 97
      guard segments > 0 || upper == 77 else {
        throw FormError.invalid("SVG path must begin with moveto.")
      }
      segments += 1
      guard segments <= 100_000 else {
        throw FormError.invalid("SVG path exceeds 100,000 segments.")
      }
      func nextPoint() throws -> CGPoint {
        let x = try s.number()
        let y = try s.number()
        return .init(x: x + (relative ? point.x : 0), y: y + (relative ? point.y : 0))
      }
      var nextCubic: CGPoint?
      var nextQuadratic: CGPoint?
      switch upper {
      case 77:
        point = try nextPoint()
        start = point
        path.move(to: point)
        command = relative ? 108 : 76
      case 76:
        point = try nextPoint()
        path.addLine(to: point)
      case 72:
        point.x = try s.number() + (relative ? point.x : 0)
        path.addLine(to: point)
      case 86:
        point.y = try s.number() + (relative ? point.y : 0)
        path.addLine(to: point)
      case 67:
        let c1 = try nextPoint()
        let c2 = try nextPoint()
        let end = try nextPoint()
        path.addCurve(to: end, control1: c1, control2: c2)
        point = end
        nextCubic = c2
      case 83:
        let c1 = reflected([67, 83].contains(previous) ? cubic : nil)
        let c2 = try nextPoint()
        let end = try nextPoint()
        path.addCurve(to: end, control1: c1, control2: c2)
        point = end
        nextCubic = c2
      case 81:
        let c = try nextPoint()
        let end = try nextPoint()
        path.addQuadCurve(to: end, control: c)
        point = end
        nextQuadratic = c
      case 84:
        let c = reflected([81, 84].contains(previous) ? quadratic : nil)
        let end = try nextPoint()
        path.addQuadCurve(to: end, control: c)
        point = end
        nextQuadratic = c
      case 65:
        let rx = try s.number()
        let ry = try s.number()
        let rotation = try s.number()
        let large = try s.flag()
        let sweep = try s.flag()
        let end = try nextPoint()
        try arc(
          path, from: point, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep
        )
        point = end
      case 90:
        path.closeSubpath()
        point = start
        command = nil
      default:
        throw FormError.invalid("Unknown SVG path command \(Character(UnicodeScalar(upper))).")
      }
      cubic = nextCubic
      quadratic = nextQuadratic
      previous = upper
    }
    return path
  }

  /// W3C endpoint-to-center conversion. Cubic segments span at most 45 degrees.
  private static func arc(
    _ path: CGMutablePath, from p: CGPoint, to q: CGPoint, rx inputX: Double,
    ry inputY: Double, rotation: Double, large: Bool, sweep: Bool
  ) throws {
    if p == q { return }
    var rx = abs(inputX)
    var ry = abs(inputY)
    if rx == 0 || ry == 0 {
      path.addLine(to: q)
      return
    }
    guard rx >= 1e-12, ry >= 1e-12 else {
      throw FormError.invalid("SVG arc radius is below supported precision.")
    }
    let phi = rotation.remainder(dividingBy: 360) * .pi / 180
    let c = cos(phi)
    let s = sin(phi)
    let x = c * (p.x - q.x) / 2 + s * (p.y - q.y) / 2
    let y = -s * (p.x - q.x) / 2 + c * (p.y - q.y) / 2
    let lambda = x * x / (rx * rx) + y * y / (ry * ry)
    if lambda > 1 {
      let f = sqrt(lambda)
      rx *= f
      ry *= f
    }
    let denominator = rx * rx * y * y + ry * ry * x * x
    let factor =
      (large == sweep ? -1.0 : 1.0)
      * sqrt(max(0, (rx * rx * ry * ry - denominator) / max(denominator, 1e-300)))
    let cx = factor * rx * y / ry
    let cy = -factor * ry * x / rx
    let center = CGPoint(x: c * cx - s * cy + (p.x + q.x) / 2, y: s * cx + c * cy + (p.y + q.y) / 2)
    let u = CGPoint(x: (x - cx) / rx, y: (y - cy) / ry)
    let v = CGPoint(x: (-x - cx) / rx, y: (-y - cy) / ry)
    let start = atan2(u.y, u.x)
    var angle = atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y)
    if !sweep && angle > 0 { angle -= 2 * .pi }
    if sweep && angle < 0 { angle += 2 * .pi }
    let count = max(1, Int(ceil(abs(angle) / (.pi / 4))))
    let delta = angle / Double(count)
    func at(_ t: Double) -> CGPoint {
      .init(
        x: center.x + rx * c * cos(t) - ry * s * sin(t),
        y: center.y + rx * s * cos(t) + ry * c * sin(t))
    }
    func derivative(_ t: Double) -> CGPoint {
      .init(x: -rx * c * sin(t) - ry * s * cos(t), y: -rx * s * sin(t) + ry * c * cos(t))
    }
    for i in 0..<count {
      let a = start + Double(i) * delta
      let b = a + delta
      let k = 4 / 3 * tan(delta / 4)
      let first = at(a)
      let last = at(b)
      let d1 = derivative(a)
      let d2 = derivative(b)
      path.addCurve(
        to: i == count - 1 ? q : last,
        control1: .init(x: first.x + k * d1.x, y: first.y + k * d1.y),
        control2: .init(x: last.x - k * d2.x, y: last.y - k * d2.y))
    }
  }
}

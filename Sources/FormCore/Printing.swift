import Foundation

public struct FilamentProfile: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID = UUID()
  public var name: String
  public var vendor: String
  public var polymer: String
  public var color: String
  public var diameter: Double = 1.75
  public var density: Double = 1.24
  public var nozzleTemperature: Double = 220
  public var bedTemperature: Double = 55
  public var maxVolumetricSpeed: Double = 12
  public var remainingGrams: Double = 1000
  public var costPerKg: Double = 25
  public var notes: String = ""
  public init(
    name: String, vendor: String = "Generic", polymer: String = "PLA", color: String = "#D45A37",
    nozzle: Double = 220, bed: Double = 55
  ) {
    self.name = name
    self.vendor = vendor
    self.polymer = polymer
    self.color = color
    self.nozzleTemperature = nozzle
    self.bedTemperature = bed
  }
  public func validate() throws {
    try validateColor(color)
    guard !name.isEmpty, ["PLA", "PETG", "ABS", "ASA", "TPU", "PC", "PA"].contains(polymer),
      diameter.isFinite, (1.5...3).contains(diameter), density.isFinite,
      (0.5...3).contains(density), (150...320).contains(nozzleTemperature),
      (0...120).contains(bedTemperature), (1...50).contains(maxVolumetricSpeed),
      (0...10000).contains(remainingGrams), (0...1000).contains(costPerKg)
    else {
      throw FormError.invalid(
        "Check the filament's material, diameter, temperatures, flow, and spool inventory.")
    }
  }
  public func validate(for printer: PrinterProfile) throws {
    try validate()
    if printer.model == "Bambu Lab P1S" {
      guard abs(diameter - 1.75) < 0.001, nozzleTemperature <= 300, bedTemperature <= 100 else {
        throw FormError.invalid(
          "The P1S requires 1.75 mm filament, a nozzle temperature at most 300 °C, and a bed temperature at most 100 °C."
        )
      }
    }
  }
  public static let presets: [FilamentProfile] = [
    .init(name: "Studio PLA · Vermilion", color: "#D45A37"),
    .init(name: "Studio PLA · Warm white", color: "#EDE8DA"),
    .init(name: "Studio PETG · Sage", polymer: "PETG", color: "#849381", nozzle: 255, bed: 70),
    .init(name: "Studio ABS · Graphite", polymer: "ABS", color: "#353B3C", nozzle: 260, bed: 90),
  ]
}

public struct PrinterProfile: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var name = "Studio P1S"
  public var model = "Bambu Lab P1S"
  public var host = ""
  public var serial = ""
  public var bedWidth = 256.0
  public var bedDepth = 256.0
  public var buildHeight = 256.0
  public var nozzleDiameter = 0.4
  public var plate = "Textured PEI Plate"
  public var trustedCertificateSHA256: String?
  public init() {}
  public func validate() throws {
    guard !name.isEmpty, (1...2000).contains(bedWidth), (1...2000).contains(bedDepth),
      (1...2000).contains(buildHeight), [0.2, 0.4, 0.6, 0.8].contains(nozzleDiameter)
    else { throw FormError.invalid("Invalid printer dimensions or nozzle diameter.") }
    if !host.isEmpty {
      guard host.range(of: "^[a-zA-Z0-9.:-]{1,253}$", options: .regularExpression) != nil else {
        throw FormError.invalid("Enter a printer IP address or local hostname.")
      }
    }
    if !serial.isEmpty {
      guard serial.range(of: "^[a-zA-Z0-9_-]{6,40}$", options: .regularExpression) != nil else {
        throw FormError.invalid("Enter the printer serial number shown in its settings.")
      }
    }
  }
}

public struct PrintConfiguration: Codable, Equatable, Sendable {
  public var layerHeight = 0.2
  public var infillPercent = 15.0
  public var wallLoops = 2
  public var supports = false
  public var brimWidth = 0.0
  public var scalePercent = 100.0
  public var rotation: Vector3 = .init()
  public var component = "Complete object"
  public var filamentID: UUID?
  public var printerID: UUID?
  public init() {}
  public func validate(nozzle: Double) throws {
    guard layerHeight.isFinite, layerHeight >= 0.04, layerHeight <= nozzle * 0.8,
      (0...100).contains(infillPercent), (1...12).contains(wallLoops), (0...30).contains(brimWidth),
      (1...1000).contains(scalePercent),
      [rotation.x, rotation.y, rotation.z].allSatisfy({ $0.isFinite && abs($0) <= 3600 })
    else {
      throw FormError.invalid(
        "Check layer height (at most 80% of the nozzle), infill, walls, brim, and scale.")
    }
  }
}

public struct MeshTriangle: Sendable {
  public var a: Vector3
  public var b: Vector3
  public var c: Vector3
  public init(_ a: Vector3, _ b: Vector3, _ c: Vector3) {
    self.a = a
    self.b = b
    self.c = c
  }
}
public struct PrintMesh: Sendable {
  public var triangles: [MeshTriangle]
  public init(triangles: [MeshTriangle]) { self.triangles = triangles }
  public var bounds: (minimum: Vector3, maximum: Vector3) {
    var low = Vector3(.infinity, .infinity, .infinity)
    var high = Vector3(-.infinity, -.infinity, -.infinity)
    for triangle in triangles {
      for p in [triangle.a, triangle.b, triangle.c] {
        low.x = min(low.x, p.x)
        low.y = min(low.y, p.y)
        low.z = min(low.z, p.z)
        high.x = max(high.x, p.x)
        high.y = max(high.y, p.y)
        high.z = max(high.z, p.z)
      }
    }
    return (low, high)
  }
  public var size: Vector3 {
    let b = bounds
    return .init(b.maximum.x - b.minimum.x, b.maximum.y - b.minimum.y, b.maximum.z - b.minimum.z)
  }
  public func centered(on printer: PrinterProfile) -> PrintMesh {
    let b = bounds
    let dx = printer.bedWidth / 2 - (b.minimum.x + b.maximum.x) / 2
    let dy = printer.bedDepth / 2 - (b.minimum.y + b.maximum.y) / 2
    let dz = -b.minimum.z
    func shift(_ p: Vector3) -> Vector3 { .init(p.x + dx, p.y + dy, p.z + dz) }
    return .init(triangles: triangles.map { .init(shift($0.a), shift($0.b), shift($0.c)) })
  }
  public func validate(on printer: PrinterProfile) throws {
    guard !triangles.isEmpty, triangles.count <= 2_000_000 else {
      throw FormError.invalid("Select a printable solid with at most two million triangles.")
    }
    for triangle in triangles {
      for p in [triangle.a, triangle.b, triangle.c] {
        guard [p.x, p.y, p.z].allSatisfy({ $0.isFinite && abs($0) < 100000 }) else {
          throw FormError.invalid("Mesh contains invalid coordinates.")
        }
      }
    }
    let b = bounds
    guard b.minimum.x >= -0.01, b.minimum.y >= -0.01, b.minimum.z >= -0.01,
      b.maximum.x <= printer.bedWidth + 0.01, b.maximum.y <= printer.bedDepth + 0.01,
      b.maximum.z <= printer.buildHeight + 0.01
    else {
      throw FormError.invalid(
        "The object is \(Int(size.x)) × \(Int(size.y)) × \(Int(size.z)) mm and exceeds this printer's build volume. Choose a component, rotate it, or reduce its scale."
      )
    }
    if printer.model == "Bambu Lab P1S", b.minimum.x < 18, b.minimum.y < 28,
      triangles.contains(where: Self.intersectsP1SExclusion)
    {
      throw FormError.invalid(
        "The object overlaps the P1S front-left exclusion area (18 × 28 mm). Reduce its size or change its orientation."
      )
    }
  }
  private static func intersectsP1SExclusion(_ t: MeshTriangle) -> Bool {
    let vertices = [t.a, t.b, t.c]
    guard vertices.map(\.x).min()! < 18, vertices.map(\.y).min()! < 28 else { return false }
    func cross(_ a: Vector3, _ b: Vector3, _ c: Vector3) -> Double {
      (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    func inRect(_ p: Vector3) -> Bool { p.x >= 0 && p.x <= 18 && p.y >= 0 && p.y <= 28 }
    if vertices.contains(where: inRect) { return true }
    let corners = [Vector3(0, 0, 0), Vector3(18, 0, 0), Vector3(18, 28, 0), Vector3(0, 28, 0)]
    if abs(cross(t.a, t.b, t.c)) > 1e-9 {
      for p in corners {
        let signs = [cross(t.a, t.b, p), cross(t.b, t.c, p), cross(t.c, t.a, p)]
        if !signs.contains(where: { $0 < -1e-9 }) || !signs.contains(where: { $0 > 1e-9 }) {
          return true
        }
      }
    }
    for i in 0..<3 {
      for j in 0..<4 {
        let a = vertices[i]
        let b = vertices[(i + 1) % 3]
        let c = corners[j]
        let d = corners[(j + 1) % 4]
        if max(a.x, b.x) < min(c.x, d.x) || max(c.x, d.x) < min(a.x, b.x)
          || max(a.y, b.y) < min(c.y, d.y) || max(c.y, d.y) < min(a.y, b.y)
        {
          continue
        }
        if cross(a, b, c) * cross(a, b, d) <= 0 && cross(c, d, a) * cross(c, d, b) <= 0 {
          return true
        }
      }
    }
    return false
  }
  public func binarySTL() throws -> Data {
    guard !triangles.isEmpty, triangles.count <= 2_000_000 else {
      throw FormError.invalid("Mesh is empty or too complex.")
    }
    var data = Data("FORM · millimeter mesh · Z up".utf8)
    data.append(Data(repeating: 0, count: max(0, 80 - data.count)))
    func appendUInt(_ number: UInt32) {
      var value = number.littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    func appendFloat(_ number: Double) { appendUInt(Float(number).bitPattern) }
    appendUInt(UInt32(triangles.count))
    for triangle in triangles {
      let u = Vector3(
        triangle.b.x - triangle.a.x, triangle.b.y - triangle.a.y, triangle.b.z - triangle.a.z)
      let v = Vector3(
        triangle.c.x - triangle.a.x, triangle.c.y - triangle.a.y, triangle.c.z - triangle.a.z)
      let n = Vector3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
      let length = max(sqrt(n.x * n.x + n.y * n.y + n.z * n.z), 1e-20)
      for p in [
        Vector3(n.x / length, n.y / length, n.z / length), triangle.a, triangle.b, triangle.c,
      ] {
        for value in [p.x, p.y, p.z] {
          guard value.isFinite else { throw FormError.invalid("Invalid mesh coordinate.") }
          appendFloat(value)
        }
      }
      data.append(contentsOf: [0, 0])
    }
    return data
  }
}

public struct ToolpathSegment: Sendable {
  public var from: Vector3
  public var to: Vector3
  public var layer: Int
}
public struct ToolpathPreview: Sendable {
  public var segments: [ToolpathSegment] = []
  public var layers: [Double] = []
  public var estimatedTime = ""
  public var filamentGrams = ""
  public var truncated = false
  public static func parse(_ text: String, limit: Int = 200_000) -> ToolpathPreview {
    var result = ToolpathPreview()
    var position = Vector3()
    var extrusion = 0.0
    var absolute = true
    var absoluteE = true
    let hasModelMarkers = text.contains("\n; CHANGE_LAYER") || text.contains("\n;LAYER_CHANGE")
    var modelStarted = !hasModelMarkers
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = String(raw)
      if line.hasPrefix("; CHANGE_LAYER") || line.hasPrefix(";LAYER_CHANGE") { modelStarted = true }
      if line.contains("total estimated time:"),
        let value = line.components(separatedBy: "total estimated time:").last
      {
        result.estimatedTime = value.trimmingCharacters(in: .whitespaces)
      }
      if line.contains("estimated printing time (normal mode)"),
        let value = line.split(separator: "=", maxSplits: 1).last
      {
        result.estimatedTime = value.trimmingCharacters(in: .whitespaces)
      }
      if line.contains("filament used [g]"),
        let value = line.split(separator: "=", maxSplits: 1).last
      {
        result.filamentGrams = value.trimmingCharacters(in: .whitespaces)
      }
      let code = String(line.prefix(while: { $0 != ";" }))
      let tokens = code.split(whereSeparator: { $0.isWhitespace })
      guard let command = tokens.first else { continue }
      var values: [Character: Double] = [:]
      for token in tokens.dropFirst() {
        if let key = token.first, let value = Double(token.dropFirst()), value.isFinite {
          values[key] = value
        }
      }
      if command == "G90" {
        absolute = true
        continue
      }
      if command == "G91" {
        absolute = false
        continue
      }
      if command == "M82" {
        absoluteE = true
        continue
      }
      if command == "M83" {
        absoluteE = false
        continue
      }
      if command == "G92" {
        if let e = values["E"] { extrusion = e }
        continue
      }
      let arc = command == "G2" || command == "G3"
      guard command == "G0" || command == "G1" || arc else { continue }
      var next = position
      if let x = values["X"] { next.x = absolute ? x : next.x + x }
      if let y = values["Y"] { next.y = absolute ? y : next.y + y }
      if let z = values["Z"] { next.z = absolute ? z : next.z + z }
      let e = values["E"].map { absoluteE ? $0 : extrusion + $0 } ?? extrusion
      if modelStarted, e > extrusion + 0.00001, next.x != position.x || next.y != position.y || arc
      {
        if result.layers.last.map({ abs($0 - next.z) > 0.01 }) ?? true {
          result.layers.append(next.z)
        }
        var points = [position, next]
        if arc, let i = values["I"], let j = values["J"] {
          let cx = position.x + i
          let cy = position.y + j
          let radius = hypot(i, j)
          let start = atan2(position.y - cy, position.x - cx)
          let end = atan2(next.y - cy, next.x - cx)
          var delta = end - start
          if command == "G2" {
            while delta >= 0 { delta -= 2 * .pi }
          } else {
            while delta <= 0 { delta += 2 * .pi }
          }
          let steps = max(2, min(512, Int(ceil(abs(delta) / (.pi / 48)))))
          points = (0...steps).map { step in
            let fraction = Double(step) / Double(steps)
            let angle = start + delta * fraction
            return .init(
              cx + radius * cos(angle), cy + radius * sin(angle),
              position.z + (next.z - position.z) * fraction)
          }
          points[0] = position
          points[steps] = next
        }
        for index in 1..<points.count {
          if result.segments.count < limit {
            result.segments.append(
              .init(from: points[index - 1], to: points[index], layer: result.layers.count - 1))
          } else {
            result.truncated = true
          }
        }
      }
      position = next
      extrusion = e
    }
    return result
  }
}

/// Only connection, subscription, keepalive, acknowledgement, and disconnect packets exist.
/// There is deliberately no MQTT PUBLISH encoder or printer command surface in this build.
public enum MQTTReadOnly {
  public static func string(_ text: String) -> Data {
    let bytes = Data(text.utf8)
    return Data([UInt8((bytes.count >> 8) & 255), UInt8(bytes.count & 255)]) + bytes
  }
  public static func frame(_ header: UInt8, _ body: Data) -> Data {
    var length = body.count
    var bytes = Data([header])
    repeat {
      var digit = UInt8(length % 128)
      length /= 128
      if length > 0 { digit |= 0x80 }
      bytes.append(digit)
    } while length > 0
    return bytes + body
  }
  public static func connect(clientID: String, password: String) -> Data {
    frame(
      0x10,
      string("MQTT") + Data([4, 0xC2, 0, 30]) + string(clientID) + string("bblp") + string(password)
    )
  }
  public static func subscribe(serial: String) -> Data {
    frame(0x82, Data([0, 1]) + string("device/\(serial)/report") + Data([0]))
  }
  public static func takeFrame(from buffer: inout Data) throws -> (UInt8, Data)? {
    if buffer.startIndex != 0 { buffer = Data(buffer) }
    guard buffer.count >= 2 else { return nil }
    let bytes = [UInt8](buffer.prefix(5))
    var value = 0
    var multiplier = 1
    var index = 1
    while index < bytes.count {
      let digit = bytes[index]
      value += Int(digit & 127) * multiplier
      index += 1
      if digit & 128 == 0 {
        guard value <= 2_000_000 else {
          throw FormError.invalid("Oversized printer telemetry frame.")
        }
        guard buffer.count >= index + value else { return nil }
        let payload = Data(buffer[index..<index + value])
        let header = buffer[0]
        buffer.removeFirst(index + value)
        return (header, payload)
      }
      multiplier *= 128
    }
    if index == 5 { throw FormError.invalid("Invalid MQTT frame length.") }
    return nil
  }
}

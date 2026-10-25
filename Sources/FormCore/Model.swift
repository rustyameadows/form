import Foundation

public struct Vector3: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var z: Double
  public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) {
    self.x = x
    self.y = y
    self.z = z
  }
}

public struct Parameter: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var unit: String
  public var minimum: Double
  public var maximum: Double
  public var step: Double
  public var value: Double
  public init(
    _ id: String, _ name: String, _ value: Double, _ range: ClosedRange<Double>,
    unit: String = "mm", step: Double = 1
  ) {
    self.id = id
    self.name = name
    self.value = value
    minimum = range.lowerBound
    maximum = range.upperBound
    self.unit = unit
    self.step = step
  }
}

public struct Material: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var category: String
  public var color: String
  public var roughness: Double
  public var metallic: Double
  public var thickness: Double
  public init(
    _ id: String, _ name: String, _ category: String, _ color: String, roughness: Double = 0.65,
    metallic: Double = 0, thickness: Double = 0.3
  ) {
    self.id = id
    self.name = name
    self.category = category
    self.color = color
    self.roughness = roughness
    self.metallic = metallic
    self.thickness = thickness
  }
  public static let presets: [Material] = [
    .init("cobalt", "Cyanotype blue", "Paper", "#224B9B", roughness: 0.86),
    .init("chalk", "Warm white", "Paper", "#EDE8DA", roughness: 0.93),
    .init("kraft", "Natural kraft", "Paper", "#B49A71", roughness: 0.98, thickness: 0.45),
    .init("vermillion", "Vermilion", "Powder coat", "#D45A37", roughness: 0.42),
    .init("sage", "Sage", "Powder coat", "#849381", roughness: 0.52),
    .init("butter", "Butter", "Powder coat", "#DCCB83", roughness: 0.48),
    .init("graphite", "Graphite", "Metal", "#353B3C", roughness: 0.36, metallic: 0.6),
    .init("aluminum", "Brushed aluminum", "Metal", "#BFC4C6", roughness: 0.29, metallic: 0.92),
    .init("oak", "Pale oak", "Wood", "#CDAE7D", roughness: 0.78, thickness: 18),
    .init("clay", "Unglazed clay", "Ceramic", "#B57860", roughness: 0.92, thickness: 4),
    .init("linen", "Natural linen", "Fabric", "#D4CDBB", roughness: 1, thickness: 0.8),
    .init("petg", "Frosted PETG", "Plastic", "#C4D6D3", roughness: 0.48, thickness: 1.2),
  ]
}

public struct ArtworkElement: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID = UUID()
  public var kind: String
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public var text: String
  public var color: String
  public var fontSize: Double
  public var asset: String?
  public var name: String?
  public var rotation: Double?
  public var opacity: Double?
  public var hidden: Bool?
  public var locked: Bool?
  public var parentID: UUID?
  public var contentSize: Point2?
  public var affine: Affine2?
  public var flipX: Bool?
  public var flipY: Bool?
  public var fillEnabled: Bool?
  public var fillOpacity: Double?
  public var booleanOperation: String?
  public var component: ArtworkComponentReference?
  public var stroke: ArtworkStroke?
  public var gradient: ArtworkGradient?
  public var cornerRadius: Double?
  public var sides: Int?
  public var starInset: Double?
  public var path: VectorPath?
  public var typography: Typography?
  public var textRuns: [TextSpan]?
  public var productionRole: String?
  public var clipID: UUID?
  public init(
    kind: String, x: Double, y: Double, width: Double = 60, height: Double = 30, text: String = "",
    color: String = "#FFFFFF", fontSize: Double = 14, asset: String? = nil
  ) {
    self.kind = kind
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.text = text
    self.color = color
    self.fontSize = fontSize
    self.asset = asset
  }
}

public struct Artwork: Codable, Equatable, Sendable {
  public var background: String
  public var elements: [ArtworkElement]
  public var bleed: Double
  public var unit: PhysicalUnit?
  public var guides: [ArtworkGuide]?
  public var gridSpacing: Double?
  public var showGrid: Bool?
  public var snapEnabled: Bool?
  public var nudge: Double?
  public var showGuides: Bool?
  public var canvasPosition: Point2?
  public var boundary: VectorPath?
  public var backgroundOpacity: Double?
  public var imports: [ArtworkImport]?
  public init(background: String = "#224B9B", elements: [ArtworkElement] = [], bleed: Double = 3) {
    self.background = background
    self.elements = elements
    self.bleed = bleed
  }
  public static var cyanotype: Artwork {
    .init(elements: [
      .init(
        kind: "text", x: 18, y: 22, width: 180, height: 12, text: "EXPERIMENTS IN LIGHT  /  NO. 01",
        fontSize: 9),
      .init(
        kind: "text", x: 16, y: 49, width: 180, height: 72, text: "Sun\nstudies.", fontSize: 64),
      .init(
        kind: "text", x: 18, y: 133, width: 175, height: 20,
        text: "A little light. Endless possibility.", fontSize: 12),
      .init(kind: "ellipse", x: 122, y: 160, width: 65, height: 65, color: "#E4D8A9"),
      .init(
        kind: "text", x: 18, y: 241, width: 185, height: 25, text: "CYANOTYPE KIT  /  20 SHEETS",
        fontSize: 9),
    ])
  }
}

public struct ProductObject: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID = UUID()
  public var name: String
  public var recipeID: String
  public var parameters: [String: Double]
  public var materialID: String
  public var color: String?
  public var position: Vector3
  public var rotation: Double
  public var groupID: UUID?
  public var designID: UUID
  public var parentIterationID: UUID?
  public var relationship: String
  public var artwork: Artwork?
  public var artworkSourceID: UUID?
  public var artworkFit: String?
  public var componentDefinition: Bool?
  public var asset: String?
  public var locked: Bool
  public init(
    name: String, recipeID: String, parameters: [String: Double], materialID: String = "chalk",
    position: Vector3 = .init(), rotation: Double = 0, artwork: Artwork? = nil
  ) {
    self.name = name
    self.recipeID = recipeID
    self.parameters = parameters
    self.materialID = materialID
    self.position = position
    self.rotation = rotation
    self.artwork = artwork
    designID = UUID()
    relationship = "original"
    locked = false
  }
  public subscript(_ key: String) -> Double { parameters[key] ?? 0 }
  public var footprintWidth: Double {
    max(self["width"], self["shadeDiameter"], self["baseDiameter"], self["diameter"], 100)
  }
  public var footprintDepth: Double {
    max(self["depth"], self["shadeDiameter"], self["baseDiameter"], self["diameter"], 100)
  }
}

public struct PartDefinition: Codable, Equatable, Sendable {
  public var kind: String
  public var values: [String: String]
  public var color: String?
  public init(_ kind: String, _ values: [String: String], color: String? = nil) {
    self.kind = kind
    self.values = values
    self.color = color
  }
  public func evaluate(_ parameters: [String: Double]) throws -> [String: Double] {
    try values.mapValues { try Expression.evaluate($0, variables: parameters) }
  }
}

public struct Recipe: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var symbol: String
  public var summary: String
  public var parameters: [Parameter]
  public var parts: [PartDefinition]
  public init(
    _ id: String, _ name: String, _ symbol: String, _ summary: String, _ parameters: [Parameter],
    parts: [PartDefinition] = []
  ) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.summary = summary
    self.parameters = parameters
    self.parts = parts
  }
  public var defaults: [String: Double] {
    Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.value) })
  }
  public func validate(_ values: [String: Double]) throws {
    for (key, value) in values {
      guard let parameter = parameters.first(where: { $0.id == key }) else {
        throw FormError.invalid("Unknown parameter '\(key)' for \(name).")
      }
      guard value.isFinite, value >= parameter.minimum, value <= parameter.maximum else {
        throw FormError.invalid(
          "\(parameter.name) must be between \(parameter.minimum) and \(parameter.maximum) \(parameter.unit)."
        )
      }
    }
    let all = defaults.merging(values) { _, new in new }
    for parameter in parameters where ["sheets", "pages"].contains(parameter.unit) {
      guard all[parameter.id]!.rounded() == all[parameter.id]! else {
        throw FormError.invalid("\(parameter.name) must be a whole number.")
      }
    }
    if id == "lamp" {
      guard let height = all["height"], let shadeHeight = all["shadeHeight"],
        let top = all["topDiameter"], let wall = all["wall"]
      else { throw FormError.invalid("Lamp recipe parameters are incomplete.") }
      guard height >= shadeHeight + 30 else {
        throw FormError.invalid("Lamp height must leave at least 30 mm below the shade.")
      }
      guard top > wall * 2 else {
        throw FormError.invalid("The top opening must exceed twice the shade's wall thickness.")
      }
    }
    if id == "vase" {
      guard let neck = all["neck"], let wall = all["wall"], neck / 2 > wall else {
        throw FormError.invalid("Vessel walls must leave an open neck.")
      }
    }
    if id == "clock" {
      for key in ["hour", "minute", "hands"] {
        guard let value = all[key], value.isFinite, value.rounded() == value else {
          throw FormError.invalid("Clock time and hand visibility require whole values.")
        }
      }
    }
    for part in parts {
      let evaluated = try part.evaluate(all)
      for (key, value) in evaluated {
        guard value.isFinite, abs(value) <= 100_000 else {
          throw FormError.invalid("Part value '\(key)' exceeds the supported size.")
        }
        if [
          "width", "height", "depth", "radius", "topRadius", "bottomRadius", "ringRadius",
          "pipeRadius", "corner",
        ].contains(key),
          value < 0
        {
          throw FormError.invalid("Part dimension '\(key)' cannot be negative.")
        }
      }
    }
  }
}

public struct ProjectNote: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var text: String
  public var kind: String
  public var resolved: Bool = false
  public init(_ text: String, kind: String = "decision") {
    self.text = text
    self.kind = kind
  }
}

public struct ProjectEvent: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var date = Date()
  public var source: String
  public var text: String
  public init(_ text: String, source: String = "Studio") {
    self.text = text
    self.source = source
  }
}

public struct CameraState: Codable, Equatable, Sendable {
  public var azimuth: Double = 0.55
  public var elevation: Double = 0.70
  public var distance: Double = 12
  public var target: Vector3 = .init(0, 0.6, 0)
  public var projection: String = "perspective"
  public var viewportAspect: Double?
  public init() {}
}

public struct Equipment: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var name: String
  public var width: Double
  public var height: Double
  public var format: String
  public init(_ name: String, width: Double, height: Double, format: String) {
    self.name = name
    self.width = width
    self.height = height
    self.format = format
  }
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
  public var schemaVersion = 1
  public var id: UUID = UUID()
  public var name: String
  public var subtitle: String
  public var createdAt: Date = Date()
  public var updatedAt: Date = Date()
  public var objects: [ProductObject] = []
  public var recipes: [Recipe] = []
  public var materials: [Material] = []
  public var notes: [ProjectNote] = []
  public var history: [ProjectEvent] = []
  public var camera: CameraState = .init()
  public var unit: String = "mm"
  public var conversationReference: String?
  public var printSetups: [String: PrintConfiguration]?
  public var minimumSchemaVersion: Int {
    max(
      schemaVersion,
      objects.contains { $0.componentDefinition == true || $0.artwork?.elements.contains { $0.component != nil } == true }
        ? 6
        : objects.contains { $0.artwork?.requiresSchemaFive == true }
        ? 5
        : objects.contains { $0.artwork?.requiresSchemaFour == true }
          ? 4
          : objects.contains {
            $0.artworkSourceID != nil || $0.recipeID == "clock" || $0.artwork?.boundary != nil
          } ? 3 : objects.contains { $0.artwork?.usesExtendedFormat == true } ? 2 : 1)
  }
  public init(name: String, subtitle: String = "A new place to make things.") {
    self.name = name
    self.subtitle = subtitle
  }
  public func recipe(_ id: String) -> Recipe? {
    recipes.first { $0.id == id } ?? Recipe.builtins.first { $0.id == id }
  }
  public func material(_ id: String) -> Material {
    materials.first { $0.id == id } ?? Material.presets.first { $0.id == id } ?? Material.presets[1]
  }
  public func makeObject(
    recipeID: String, name: String? = nil, parameters: [String: Double] = [:],
    materialID: String = "chalk", position: Vector3 = .init()
  ) throws -> ProductObject {
    guard let recipe = recipe(recipeID) else {
      throw FormError.invalid(
        "Unknown recipe '\(recipeID)'. Use form_list_recipes to discover available recipes.")
    }
    try recipe.validate(parameters)
    return ProductObject(
      name: name ?? recipe.name, recipeID: recipeID,
      parameters: recipe.defaults.merging(parameters) { _, new in new }, materialID: materialID,
      position: position)
  }
}

public enum FormError: LocalizedError {
  case invalid(String)
  case missing(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let message), .missing(let message): return message
    }
  }
}

public enum FormPaths {
  public static var library: URL {
    if let path = ProcessInfo.processInfo.environment["FORM_LIBRARY_PATH"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("FORM", isDirectory: true)
  }
  public static var socket: String {
    ProcessInfo.processInfo.environment["FORM_SOCKET_PATH"] ?? "/tmp/form-\(getuid()).sock"
  }
}

extension JSONEncoder {
  public static var form: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}
extension JSONDecoder {
  public static var form: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
public func jsonObject<T: Encodable>(_ value: T) throws -> Any {
  try JSONSerialization.jsonObject(with: JSONEncoder.form.encode(value))
}

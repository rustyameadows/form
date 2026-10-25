import Foundation

public struct Point2: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public init(_ x: Double = 0, _ y: Double = 0) {
    self.x = x
    self.y = y
  }
}

public struct Rect2: Equatable, Sendable {
  public var x: Double, y: Double, width: Double, height: Double
  public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
  public var maxX: Double { x + width }
  public var maxY: Double { y + height }
  public var center: Point2 { .init(x + width / 2, y + height / 2) }
  public func union(_ other: Rect2) -> Rect2 {
    let left = min(x, other.x)
    let top = min(y, other.y)
    return .init(left, top, max(maxX, other.maxX) - left, max(maxY, other.maxY) - top)
  }
}

/// Column-vector affine transform, independent of rendering frameworks.
public struct Affine2: Codable, Equatable, Sendable {
  public var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0
  public init(
    a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, tx: Double = 0, ty: Double = 0
  ) {
    self.a = a
    self.b = b
    self.c = c
    self.d = d
    self.tx = tx
    self.ty = ty
  }
  public static func translation(_ x: Double, _ y: Double) -> Self { .init(tx: x, ty: y) }
  public static func scale(_ x: Double, _ y: Double) -> Self { .init(a: x, d: y) }
  public static func rotation(_ degrees: Double) -> Self {
    let r = degrees * .pi / 180
    return .init(a: cos(r), b: sin(r), c: -sin(r), d: cos(r))
  }
  public func followed(by local: Self) -> Self {
    .init(
      a: a * local.a + c * local.b, b: b * local.a + d * local.b, c: a * local.c + c * local.d,
      d: b * local.c + d * local.d, tx: a * local.tx + c * local.ty + tx,
      ty: b * local.tx + d * local.ty + ty)
  }
  public func apply(_ p: Point2) -> Point2 { .init(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty) }
  public var inverse: Self? {
    let determinant = a * d - b * c
    guard abs(determinant) > 1e-12 else { return nil }
    return .init(
      a: d / determinant, b: -b / determinant, c: -c / determinant, d: a / determinant,
      tx: (c * ty - d * tx) / determinant, ty: (b * tx - a * ty) / determinant)
  }
  public func bounds(_ rect: Rect2) -> Rect2 {
    let p = [
      Point2(rect.x, rect.y), .init(rect.maxX, rect.y), .init(rect.maxX, rect.maxY),
      .init(rect.x, rect.maxY),
    ].map(apply)
    let x = p.map(\.x).min()!
    let y = p.map(\.y).min()!
    return .init(x, y, p.map(\.x).max()! - x, p.map(\.y).max()! - y)
  }
}

public enum PhysicalUnit: String, Codable, CaseIterable, Sendable {
  case mm, cm
  case inches = "in"
  case points = "pt"
  public var millimeters: Double {
    switch self {
    case .mm: return 1
    case .cm: return 10
    case .inches: return 25.4
    case .points: return 25.4 / 72
    }
  }
  public func display(_ mm: Double) -> Double { mm / millimeters }
  public func parse(_ input: String) throws -> Double {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let expression = "^([+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+))\\s*(mm|cm|in|inch|inches|pt|\")?$"
    let regex = try NSRegularExpression(pattern: expression)
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let numberRange = Range(match.range(at: 1), in: text), let number = Double(text[numberRange]),
      number.isFinite
    else { throw FormError.invalid("Enter a number with mm, cm, in, or pt units.") }
    var unit = self
    if let range = Range(match.range(at: 2), in: text) {
      let suffix = String(text[range])
      unit =
        ["inch", "inches", "\""].contains(suffix) ? .inches : PhysicalUnit(rawValue: suffix) ?? self
    }
    return number * unit.millimeters
  }
}

public struct BezierNode: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var anchor: Point2
  public var incoming: Point2?
  public var outgoing: Point2?
  public var mode: String?
  public init(_ anchor: Point2, incoming: Point2? = nil, outgoing: Point2? = nil) {
    self.anchor = anchor
    self.incoming = incoming
    self.outgoing = outgoing
  }
}
public struct VectorContour: Codable, Equatable, Sendable {
  public var nodes: [BezierNode]
  public var closed: Bool
  public init(_ nodes: [BezierNode], closed: Bool = true) {
    self.nodes = nodes
    self.closed = closed
  }
}
public struct VectorPath: Codable, Equatable, Sendable {
  public var width: Double
  public var height: Double
  public var contours: [VectorContour]
  public var evenOdd: Bool
  public init(width: Double, height: Double, contours: [VectorContour], evenOdd: Bool = false) {
    self.width = width
    self.height = height
    self.contours = contours
    self.evenOdd = evenOdd
  }
}
public struct ArtworkStroke: Codable, Equatable, Sendable {
  public var enabled: Bool?
  public var alignment: String?
  public var color: String
  public var swatchID: UUID?
  public var width: Double
  public var opacity: Double?
  public var cap: String?
  public var join: String?
  public var miter: Double?
  public var dash: [Double]?
  public var dashOffset: Double?
  public init(color: String = "#292D2C", width: Double = 0.5) {
    self.color = color
    self.width = width
  }
}
public struct GradientStop: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var offset: Double
  public var color: String
  public var swatchID: UUID?
  public var opacity: Double?
  public init(_ offset: Double, _ color: String) {
    self.offset = offset
    self.color = color
  }
}
public struct ArtworkGradient: Codable, Equatable, Sendable {
  public var kind: String
  public var start: Point2
  public var end: Point2
  public var stops: [GradientStop]
  public var transform: Affine2?
  public init(
    kind: String = "linear", start: Point2 = .init(0, 0), end: Point2 = .init(1, 1),
    stops: [GradientStop] = [.init(0, "#D45A37"), .init(1, "#E4D8A9")]
  ) {
    self.kind = kind
    self.start = start
    self.end = end
    self.stops = stops
  }
}
public struct ArtworkGuide: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var axis: String
  public var position: Double
  public var locked: Bool?
  public init(axis: String, position: Double) {
    self.axis = axis
    self.position = position
  }
}

/// Sizes and spacing are typographic points. Positions in artwork stay millimeters.
public struct Typography: Codable, Equatable, Sendable {
  public var fontName: String = "HelveticaNeue-Medium"
  public var tracking: Double = 0
  public var leading: Double = 0
  public var baseline: Double = 0
  public var wordSpacing: Double = 0
  public var horizontalScale: Double = 100
  public var alignment: String = "left"
  public var verticalAlignment: String = "top"
  public var paragraphBefore: Double = 0
  public var paragraphAfter: Double = 0
  public var leftIndent: Double = 0
  public var rightIndent: Double = 0
  public var firstLineIndent: Double = 0
  public var underline: Bool = false
  public var strikethrough: Bool = false
  public var ligatures: Int = 1
  public var direction: String = "natural"
  public var frameMode: String = "area"
  public var caseTreatment: String = "original"
  public var hyphenation: Double = 0
  public var features: [Int: Int] = [:]
  public var variations: [Int: Double] = [:]
  public var pairKerning: [Int: Double] = [:]
  public init() {}
  enum CodingKeys: String, CodingKey {
    case fontName, tracking, leading, baseline, wordSpacing, horizontalScale, alignment,
      verticalAlignment, paragraphBefore, paragraphAfter, leftIndent, rightIndent, firstLineIndent,
      underline, strikethrough, ligatures, direction, frameMode, caseTreatment, hyphenation,
      features, variations, pairKerning
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? fontName
    tracking = try c.decodeIfPresent(Double.self, forKey: .tracking) ?? tracking
    leading = try c.decodeIfPresent(Double.self, forKey: .leading) ?? leading
    baseline = try c.decodeIfPresent(Double.self, forKey: .baseline) ?? baseline
    wordSpacing = try c.decodeIfPresent(Double.self, forKey: .wordSpacing) ?? wordSpacing
    horizontalScale =
      try c.decodeIfPresent(Double.self, forKey: .horizontalScale) ?? horizontalScale
    alignment = try c.decodeIfPresent(String.self, forKey: .alignment) ?? alignment
    verticalAlignment =
      try c.decodeIfPresent(String.self, forKey: .verticalAlignment) ?? verticalAlignment
    paragraphBefore =
      try c.decodeIfPresent(Double.self, forKey: .paragraphBefore) ?? paragraphBefore
    paragraphAfter = try c.decodeIfPresent(Double.self, forKey: .paragraphAfter) ?? paragraphAfter
    leftIndent = try c.decodeIfPresent(Double.self, forKey: .leftIndent) ?? leftIndent
    rightIndent = try c.decodeIfPresent(Double.self, forKey: .rightIndent) ?? rightIndent
    firstLineIndent =
      try c.decodeIfPresent(Double.self, forKey: .firstLineIndent) ?? firstLineIndent
    underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? underline
    strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? strikethrough
    ligatures = try c.decodeIfPresent(Int.self, forKey: .ligatures) ?? ligatures
    direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? direction
    frameMode = try c.decodeIfPresent(String.self, forKey: .frameMode) ?? frameMode
    caseTreatment = try c.decodeIfPresent(String.self, forKey: .caseTreatment) ?? caseTreatment
    hyphenation = try c.decodeIfPresent(Double.self, forKey: .hyphenation) ?? hyphenation
    features = try c.decodeIfPresent([Int: Int].self, forKey: .features) ?? features
    variations = try c.decodeIfPresent([Int: Double].self, forKey: .variations) ?? variations
    pairKerning = try c.decodeIfPresent([Int: Double].self, forKey: .pairKerning) ?? pairKerning
  }
}
public struct TextSpan: Codable, Equatable, Sendable {
  public var location: Int
  public var length: Int
  public var typography: Typography
  public var fontSize: Double
  public var color: String
  public var swatchID: UUID?
  public init(location: Int, length: Int, typography: Typography, fontSize: Double, color: String) {
    self.location = location
    self.length = length
    self.typography = typography
    self.fontSize = fontSize
    self.color = color
  }
}

extension ArtworkElement {
  public var title: String {
    name
      ?? (kind == "text"
        ? String(text.prefix(36)).replacingOccurrences(of: "\n", with: " ") : kind.capitalized)
  }
  public var localTransform: Affine2 {
    var t = Affine2.translation(x + width / 2, y + height / 2).followed(
      by: .rotation(rotation ?? 0)
    ).followed(by: .scale(flipX == true ? -1 : 1, flipY == true ? -1 : 1)).followed(
      by: .translation(-width / 2, -height / 2))
    if kind == "group", let size = contentSize {
      t = t.followed(by: .scale(width / max(size.x, 0.001), height / max(size.y, 0.001)))
    }
    return (affine ?? .init()).followed(by: t)
  }
  public var paintSize: Point2 {
    booleanOperation != nil ? contentSize ?? .init(width, height) : .init(width, height)
  }
}
extension Artwork {
  public var requiresSchemaFive: Bool { elements.contains { $0.booleanOperation != nil } }
  public var requiresSchemaFour: Bool {
    backgroundOpacity != nil || imports != nil
      || elements.contains {
        $0.fillOpacity != nil || $0.stroke?.dashOffset != nil || $0.gradient?.transform != nil
          || $0.gradient?.stops.contains { $0.opacity != nil } == true
      }
  }
  public var usesExtendedFormat: Bool {
    if requiresSchemaFour || requiresSchemaFive || requiresSchemaEight || requiresSchemaNine || requiresSchemaTen || !referencedSwatches.isEmpty || elements.contains(where: { $0.component != nil }) { return true }
    if boundary != nil { return true }
    if unit != nil || guides != nil || gridSpacing != nil || showGrid != nil || showGuides != nil
      || snapEnabled != nil || nudge != nil || canvasPosition != nil
    {
      return true
    }
    return elements.contains { e in
      !["text", "rectangle", "ellipse", "image", "line"].contains(e.kind) || e.name != nil
        || e.rotation != nil || e.opacity != nil || e.hidden != nil || e.locked != nil
        || e.parentID != nil || e.contentSize != nil || e.affine != nil || e.flipX != nil
        || e.flipY != nil || e.fillEnabled != nil || e.stroke != nil || e.gradient != nil
        || e.cornerRadius != nil || e.sides != nil || e.starInset != nil || e.path != nil
        || e.typography != nil || e.textRuns != nil || e.productionRole != nil || e.clipID != nil
    }
  }
  public func exporting(_ ids: Set<UUID>) throws -> (artwork: Artwork, bounds: Rect2) {
    guard !ids.isEmpty, ids.isSubset(of: Set(elements.map(\.id))) else {
      throw FormError.invalid("Choose valid artwork elements to export.")
    }
    var effective = ids
    for id in ids {
      var current = elements.first { $0.id == id }
      var owner: UUID?
      var visited = Set<UUID>()
      while let e = current, visited.insert(e.id).inserted {
        if e.booleanOperation != nil { owner = e.id }
        current = e.parentID.flatMap { parent in elements.first { $0.id == parent } }
      }
      if let owner {
        effective.remove(id)
        effective.insert(owner)
      }
    }
    let roots = selectionRoots(effective)
    var bounds = roots.dropFirst().reduce(self.bounds(of: roots[0])) {
      $0.union(self.bounds(of: $1))
    }
    var required = descendants(of: effective)
    for _ in 0...elements.count {
      let before = required
      for e in elements where required.contains(e.id) {
        if let parent = e.parentID { required.insert(parent) }
        if let clip = e.clipID { required.insert(clip) }
      }
      if before == required { break }
    }
    var result = self
    result.elements = elements.filter { required.contains($0.id) }
    if result.elements.contains(where: { $0.hasVisualOverflow }) {
      let masks = Set(result.elements.compactMap(\.clipID))
      let visibleRoots = result.elements.filter { $0.parentID == nil && !masks.contains($0.id) && $0.hidden != true }
      if let first = visibleRoots.first {
        bounds = visibleRoots.dropFirst().reduce(result.visualBounds(of: first)) { $0.union(result.visualBounds(of: $1)) }
      }
    }
    if var boundary = result.boundary {
      for c in boundary.contours.indices {
        boundary.contours[c].nodes = boundary.contours[c].nodes.map {
          PathCommands.transformed($0, by: .translation(-bounds.x, -bounds.y))
        }
      }
      result.boundary = boundary
    }
    for i in result.elements.indices where result.elements[i].parentID == nil {
      ArtworkCommands.translate(&result.elements[i], dx: -bounds.x, dy: -bounds.y)
    }
    return (result, bounds)
  }
  public var renderDefinition: Artwork {
    var result = self
    result.imports = nil
    result.unit = nil
    result.guides = nil
    result.gridSpacing = nil
    result.showGrid = nil
    result.showGuides = nil
    result.snapEnabled = nil
    result.nudge = nil
    result.canvasPosition = nil
    result.bleed = 0
    let masks = Set(elements.compactMap(\.clipID))
    result.elements = elements.filter { e in
      if e.hidden == true && !masks.contains(e.id) { return false }
      if let role = e.productionRole, role != "artwork", !masks.contains(e.id) { return false }
      var parent = e.parentID
      var seen = Set<UUID>()
      while let id = parent, let item = elements.first(where: { $0.id == id }), !seen.contains(id) {
        seen.insert(id)
        if item.hidden == true || (item.productionRole != nil && item.productionRole != "artwork") {
          return false
        }
        parent = item.parentID
      }
      return true
    }
    for i in result.elements.indices {
      if result.elements[i].imageCrop == .full { result.elements[i].imageCrop = nil }
      if result.elements[i].imageAdjustments?.isIdentity == true { result.elements[i].imageAdjustments = nil }
      if result.elements[i].stroke?.alignment == "center" { result.elements[i].stroke?.alignment = nil }
      if result.elements[i].stroke?.enabled == true { result.elements[i].stroke?.enabled = nil }
      if result.elements[i].stroke?.enabled == false {
        result.elements[i].stroke = result.elements[i].kind == "line" ? ArtworkStroke(color:"#000000",width:0) : nil
      }
      result.elements[i].name = nil
      result.elements[i].locked = nil
      if result.elements[i].blendMode == "normal" { result.elements[i].blendMode = nil }
      if result.elements[i].isolatedBlending == false { result.elements[i].isolatedBlending = nil }
      if result.elements[i].blur?.enabled != true || result.elements[i].blur?.radius == 0 { result.elements[i].blur = nil }
      if result.elements[i].shadow?.enabled != true || result.elements[i].shadow?.opacity == 0 { result.elements[i].shadow = nil }
    }
    return result
  }
  public func isLocked(_ element: ArtworkElement) -> Bool {
    var current: ArtworkElement? = element
    var visited = Set<UUID>()
    while let e = current, !visited.contains(e.id) {
      visited.insert(e.id)
      if e.locked == true { return true }
      current = e.parentID.flatMap { id in elements.first { $0.id == id } }
    }
    return false
  }
  public func worldTransform(_ element: ArtworkElement) -> Affine2 {
    var result = element.localTransform
    var parent = element.parentID
    var visited: Set<UUID> = [element.id]
    while let id = parent, let item = elements.first(where: { $0.id == id }), !visited.contains(id)
    {
      visited.insert(id)
      result = item.localTransform.followed(by: result)
      parent = item.parentID
    }
    return result
  }
  public func bounds(of element: ArtworkElement) -> Rect2 {
    if element.booleanOperation != nil {
      let masks = Set(elements.compactMap(\.clipID))
      let children = Dictionary(grouping: elements, by: \.parentID)
      func operandBounds(_ e: ArtworkElement) -> Rect2 {
        if e.kind == "group" {
          let values = (children[e.id] ?? []).filter { $0.hidden != true && !masks.contains($0.id) }
          if let first = values.first {
            return values.dropFirst().reduce(operandBounds(first)) { $0.union(operandBounds($1)) }
          }
        }
        return worldTransform(e).bounds(
          .init(
            0, 0, e.kind == "group" ? e.contentSize?.x ?? e.width : e.width,
            e.kind == "group" ? e.contentSize?.y ?? e.height : e.height))
      }
      return operandBounds(element)
    }
    return worldTransform(element).bounds(
      .init(
        0, 0, element.kind == "group" ? element.contentSize?.x ?? element.width : element.width,
        element.kind == "group" ? element.contentSize?.y ?? element.height : element.height))
  }
  public func descendants(of ids: Set<UUID>) -> Set<UUID> {
    var result = ids
    for _ in 0...elements.count {
      let old = result
      for e in elements where e.parentID.map(result.contains) == true { result.insert(e.id) }
      if result == old { break }
    }
    return result
  }
  public func editable(_ element: ArtworkElement) -> Bool {
    var parent: ArtworkElement? = element
    var visited = Set<UUID>()
    while let item = parent, !visited.contains(item.id) {
      visited.insert(item.id)
      if item.hidden == true || item.locked == true { return false }
      parent = item.parentID.flatMap { id in elements.first { $0.id == id } }
    }
    return true
  }
  public func selectionRoots(_ ids: Set<UUID>) -> [ArtworkElement] {
    elements.filter { element in
      guard ids.contains(element.id) else { return false }
      var parent = element.parentID
      var seen = Set<UUID>()
      while let id = parent, !seen.contains(id) {
        if ids.contains(id) { return false }
        seen.insert(id)
        parent = elements.first { $0.id == id }?.parentID
      }
      return true
    }
  }
}

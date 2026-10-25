import Foundation

public func validateArtworkDetails(_ artwork: Artwork) throws {
  guard (0...1).contains(artwork.backgroundOpacity ?? 1), (artwork.imports?.count ?? 0) <= 200
  else {
    throw FormError.invalid("Invalid artwork background opacity or import history.")
  }
  for source in artwork.imports ?? [] {
    guard !source.asset.contains("/"), !source.asset.contains(".."), !source.asset.isEmpty,
      source.name.count <= 500, source.width.isFinite, source.height.isFinite,
      source.width > 0, source.height > 0, source.issues.count <= 500,
      source.issues.allSatisfy({ $0.count <= 2000 })
    else {
      throw FormError.invalid("Invalid imported artwork provenance.")
    }
  }
  if let boundary = artwork.boundary {
    var shape = ArtworkElement(
      kind: "path", x: 0, y: 0, width: boundary.width, height: boundary.height)
    shape.path = boundary
    try validateArtworkDetails(Artwork(elements: [shape]))
  }
  if let position = artwork.canvasPosition {
    guard [position.x, position.y].allSatisfy({ $0.isFinite && abs($0) <= 100000 }) else {
      throw FormError.invalid("Invalid artwork canvas position.")
    }
  }
  func finite(_ numbers: [Double], _ limit: Double = 100000) -> Bool {
    numbers.allSatisfy { $0.isFinite && abs($0) <= limit }
  }
  guard Set(artwork.elements.map(\.id)).count == artwork.elements.count else {
    throw FormError.invalid("Artwork layer IDs must be unique.")
  }
  if let grid = artwork.gridSpacing {
    guard grid.isFinite, grid >= 0.1, grid <= 1000 else {
      throw FormError.invalid("Grid spacing must be 0.1–1000 mm.")
    }
  }
  if let nudge = artwork.nudge {
    guard nudge.isFinite, nudge > 0, nudge <= 100 else {
      throw FormError.invalid("Nudge must be 0–100 mm.")
    }
  }
  guard (artwork.guides?.count ?? 0) <= 500 else {
    throw FormError.invalid("A frame supports up to 500 guides.")
  }
  for g in artwork.guides ?? [] {
    guard ["x", "y"].contains(g.axis), finite([g.position]) else {
      throw FormError.invalid("Invalid guide.")
    }
  }
  let byID = Dictionary(uniqueKeysWithValues: artwork.elements.map { ($0.id, $0) })
  let children = Dictionary(grouping: artwork.elements, by: \.parentID)
  func operandSize(_ e: ArtworkElement, depth: Int) throws -> (Int, Int) {
    guard e.component == nil else { throw FormError.invalid("Detach component instances before using them as boolean operands.") }
    guard depth <= 16 else {
      throw FormError.invalid("Boolean operands support at most 16 nested group levels.")
    }
    if e.kind == "group" {
      let values = (children[e.id] ?? []).filter { $0.hidden != true }
      guard values.count <= 64 else {
        throw FormError.invalid("A boolean group supports at most 64 operands.")
      }
      return try values.reduce((0, 0)) { sum, value in
        let size = try operandSize(value, depth: depth + 1)
        let count = sum.0 + size.0
        let nodes = sum.1 + size.1
        guard count <= 256, nodes <= 20000 else {
          throw FormError.invalid("Boolean operands exceed 256 vector shapes or 20,000 nodes.")
        }
        return (count, nodes)
      }
    }
    guard BooleanCommands.shapeKinds.contains(e.kind) else {
      throw FormError.invalid(
        "Boolean operands must be vector shapes or paths. Convert text or strokes to outlines first."
      )
    }
    return (1, e.path?.contours.reduce(0) { $0 + $1.nodes.count } ?? 0)
  }
  for e in artwork.elements {
    if let origin = e.transformOrigin { try ArtworkTransforms.validateOrigin(origin) }
    try ImageCommands.validate(e)
    guard AppearanceCommands.blendModes.contains(e.blendMode ?? "normal") else {
      throw FormError.invalid("Unsupported artwork blend mode.")
    }
    if let blur = e.blur {
      guard blur.radius.isFinite, (0...50).contains(blur.radius) else {
        throw FormError.invalid("Blur radius must be 0–50 mm.")
      }
    }
    if let shadow = e.shadow {
      try validateColor(shadow.color)
      guard finite([shadow.offset.x, shadow.offset.y], 100), shadow.blur.isFinite,
        (0...50).contains(shadow.blur), (0...1).contains(shadow.opacity) else {
        throw FormError.invalid("Check shadow offsets (±100 mm), blur (0–50 mm), and opacity (0–1).")
      }
    }
    if let ref = e.component {
      guard e.kind == "group", e.booleanOperation == nil, e.contentSize != nil,
        (children[e.id] ?? []).isEmpty, (ref.overrides?.count ?? 0) <= 500,
        Set((ref.overrides ?? []).map(\.elementID)).count == (ref.overrides?.count ?? 0)
      else { throw FormError.invalid("A component instance needs an empty group and unique overrides.") }
      if let color = ref.color { try validateColor(color) }
      for change in ref.overrides ?? [] {
        if let color = change.color { try validateColor(color) }
        guard (change.text?.count ?? 0) <= 10000, (0...1).contains(change.opacity ?? 1) else {
          throw FormError.invalid("Invalid component text or opacity override.")
        }
      }
    }
    if let operation = e.booleanOperation {
      guard e.kind == "group", e.contentSize != nil, BooleanCommands.operations.contains(operation)
      else {
        throw FormError.invalid(
          "A live boolean needs a group, content dimensions, and a supported operation.")
      }
      _ = try operandSize(e, depth: 0)
    }
    guard finite([e.rotation ?? 0]), (0...1).contains(e.opacity ?? 1),
      (0...1).contains(e.fillOpacity ?? 1), (e.name?.count ?? 0) <= 500
    else { throw FormError.invalid("Invalid rotation, opacity, or layer name.") }
    if let a = e.affine {
      guard finite([a.a, a.b, a.c, a.d, a.tx, a.ty]), a.inverse != nil else {
        throw FormError.invalid("Artwork transforms must be finite and invertible.")
      }
    }
    if let size = e.contentSize {
      guard finite([size.x, size.y]), size.x > 0, size.y > 0 else {
        throw FormError.invalid("Invalid group content dimensions.")
      }
    }
    var parent = e.parentID
    var seen: Set<UUID> = [e.id]
    while let id = parent {
      guard let group = byID[id], group.kind == "group", !seen.contains(id) else {
        throw FormError.invalid("Layers must have existing group parents without cycles.")
      }
      seen.insert(id)
      parent = group.parentID
    }
    if let clip = e.clipID {
      guard let mask = byID[clip], clip != e.id, mask.parentID == e.parentID, mask.kind != "group",
        mask.kind != "text", mask.kind != "image", mask.clipID == nil
      else { throw FormError.invalid("Use a vector shape in the same group as the clipping mask.") }
    }
    if let stroke = e.stroke {
      try validateColor(stroke.color)
      guard ["center","inside","outside"].contains(stroke.alignment ?? "center"),
        stroke.alignment == nil || stroke.alignment == "center" || e.supportsAlignedStroke else {
        throw FormError.invalid("Inside/outside strokes require closed vector geometry. Choose a centered stroke for open paths.")
      }
      guard finite([stroke.width, stroke.miter ?? 10, stroke.dashOffset ?? 0]),
        (0...100).contains(stroke.width),
        (0...1).contains(stroke.opacity ?? 1),
        ["butt", "round", "square"].contains(stroke.cap ?? "butt"),
        ["miter", "round", "bevel"].contains(stroke.join ?? "miter"), (stroke.miter ?? 10) > 0,
        (stroke.dash?.count ?? 0) <= 16,
        (stroke.dash ?? []).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1000 }),
        stroke.dash == nil || stroke.dash!.isEmpty || stroke.dash!.reduce(0, +) > 0
      else {
        throw FormError.invalid("Check stroke width, opacity, caps, joins, and dash lengths.")
      }
    }
    if let g = e.gradient {
      guard ["linear", "radial"].contains(g.kind),
        finite([g.start.x, g.start.y, g.end.x, g.end.y], 10), (2...32).contains(g.stops.count),
        Set(g.stops.map(\.id)).count == g.stops.count,
        g.stops.allSatisfy({ $0.offset.isFinite && (0...1).contains($0.offset) }),
        g.stops.map(\.offset) == g.stops.map(\.offset).sorted()
      else {
        throw FormError.invalid("A gradient needs two or more ordered stops and finite positions.")
      }
      for stop in g.stops { try validateColor(stop.color) }
      guard g.stops.allSatisfy({ (0...1).contains($0.opacity ?? 1) }) else {
        throw FormError.invalid("Invalid gradient stop opacity.")
      }
      if let t = g.transform {
        guard finite([t.a, t.b, t.c, t.d, t.tx, t.ty]), t.inverse != nil else {
          throw FormError.invalid("Invalid gradient transform.")
        }
      }
    }
    guard (e.sides ?? 5) >= 3, (e.sides ?? 5) <= 100, (0.01...1).contains(e.starInset ?? 0.45),
      (e.cornerRadius ?? 0).isFinite, (e.cornerRadius ?? 0) >= 0
    else { throw FormError.invalid("Check corner radius, polygon sides, and star inset.") }
    if let path = e.path {
      guard finite([path.width, path.height]), path.width > 0, path.height > 0,
        path.contours.reduce(0, { $0 + $1.nodes.count }) <= 100000
      else { throw FormError.invalid("Invalid path dimensions or node count.") }
      for node in path.contours.flatMap(\.nodes) {
        guard node.mode == nil || ["corner", "smooth", "symmetric"].contains(node.mode!) else {
          throw FormError.invalid("Unknown Bézier node mode.")
        }
        guard
          finite([
            node.anchor.x, node.anchor.y, node.incoming?.x ?? 0, node.incoming?.y ?? 0,
            node.outgoing?.x ?? 0, node.outgoing?.y ?? 0,
          ])
        else { throw FormError.invalid("Path nodes must have finite physical coordinates.") }
      }
      let nodes = path.contours.flatMap(\.nodes)
      guard Set(nodes.map(\.id)).count == nodes.count else {
        throw FormError.invalid("Node IDs must be unique within a path.")
      }
    } else if e.kind == "path" {
      throw FormError.invalid("A path element needs editable path data.")
    }
    if let style = e.typography { try validateTypography(style) }
    if let glyphs=e.glyphOverrides {
      guard e.kind=="text" || glyphs.isEmpty else {throw FormError.invalid("Glyph choices belong to text elements.")}
      try GlyphCommands.validate(glyphs,text:e.text)
    }
    var end = 0
    for run in (e.textRuns ?? []).sorted(by: { $0.location < $1.location }) {
      guard run.location >= end, run.length > 0, run.location <= e.text.utf16.count,
        run.length <= e.text.utf16.count - run.location, run.fontSize.isFinite,
        (0.1...10000).contains(run.fontSize)
      else {
        throw FormError.invalid("Rich text ranges must be disjoint and within the UTF-16 text.")
      }
      try validateColor(run.color)
      try validateTypography(run.typography)
      end = run.location + run.length
    }
    if let role = e.productionRole {
      guard ArtworkProductionRole.resolve(role) != nil else {
        throw FormError.invalid("Unknown manufacturing role.")
      }
    }
  }
}
public func validateTypography(_ t: Typography) throws {
  try ParagraphLanguage.validate(t.language)
  try t.hyphenationLimits?.validate()
  let tabs = t.tabStops ?? []
  guard tabs.count <= 64, tabs.allSatisfy({
    $0.location.isFinite && (0...10000).contains($0.location)
      && ["left", "center", "right", "decimal"].contains($0.alignment)
      && ($0.decimalSeparator == nil || ($0.alignment == "decimal" && [".", ","].contains($0.decimalSeparator!)))
  }), zip(tabs, tabs.dropFirst()).allSatisfy({ pair in pair.0.location < pair.1.location }),
    t.defaultTabInterval == nil || (t.defaultTabInterval!.isFinite && (0...10000).contains(t.defaultTabInterval!)) else {
    throw FormError.invalid("Use up to 64 increasing tab positions in 0–10000 pt, valid alignment, and a period/comma decimal separator.")
  }
  let selections = t.featureSelections ?? [:]
  let selectionCount = t.features.keys.filter { selections[$0] == nil }.count
    + selections.values.reduce(0) { $0 + $1.count }
  guard t.features.count <= 256, selections.count <= 256,
    selectionCount <= 256,
    t.features.allSatisfy({ (0...65535).contains($0.key) && (0...65535).contains($0.value) }),
    selections.allSatisfy({ type, values in
      (0...65535).contains(type) && !values.isEmpty && values.count <= 256
        && values.allSatisfy { (0...65535).contains($0) }
        && Set(values.map { $0 / 2 }).count == values.count
    })
  else { throw FormError.invalid("Use at most 256 valid font settings and one selector per on/off pair.") }
  let numbers = [
    t.tracking, t.leading, t.baseline, t.wordSpacing, t.horizontalScale, t.paragraphBefore,
    t.paragraphAfter, t.leftIndent, t.rightIndent, t.firstLineIndent,
  ]
  guard !t.fontName.isEmpty, t.fontName.count <= 250,
    numbers.allSatisfy({ $0.isFinite && abs($0) <= 10000 }), (1...1000).contains(t.horizontalScale),
    t.leading >= 0, ["left", "center", "right", "justified"].contains(t.alignment),
    ["top", "middle", "bottom"].contains(t.verticalAlignment),
    ["natural", "ltr", "rtl"].contains(t.direction), ["point", "area"].contains(t.frameMode),
    ["original", "uppercase", "lowercase"].contains(t.caseTreatment), (0...2).contains(t.ligatures),
    (0...1).contains(t.hyphenation),
    t.kerningMode == nil || ["metrics", "none"].contains(t.kerningMode!),
    t.variations.values.allSatisfy({ $0.isFinite && abs($0) < 100000 }),
    t.pairKerning.allSatisfy({ $0.key >= 0 && $0.value.isFinite && abs($0.value) <= 10000 })
  else { throw FormError.invalid("Invalid font, text spacing, paragraph, or variation setting.") }
}

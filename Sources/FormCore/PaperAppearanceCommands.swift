import Foundation

/// The same bounded appearance commands serve native controls and MCP. Source
/// artwork remains canonical; assignments belong to the physical paper owner.
public enum PaperAppearanceCommands {
  public static let names: Set<String> = ["appearance", "stock_presets", "set_finish", "remove_finish", "save_stock", "apply_stock"]
  public static let readOnlyNames: Set<String> = ["appearance", "stock_presets"]
  private static let profileKeys: Set<String> = ["texture", "color", "roughness", "textureScaleMM", "textureDepthMM", "opacity"]
  private static let plyKeys: Set<String> = ["id", "name", "color", "thicknessMM", "profile", "gsm"]
  private static let stockKeys: Set<String> = ["name", "vendor", "gsm", "thicknessMM", "grain", "sheetSizeMM", "verified", "notes", "profile", "plies"]
  private static let finishKeys: Set<String> = ["id", "name", "kind", "side", "elementIDs", "color", "depthMM", "heightMM", "roughness", "metallic", "opacity", "enabled"]

  private static func fields(_ value: Any, allowed: Set<String>, label: String) throws -> [String: Any] {
    guard let fields = value as? [String: Any], Set(fields.keys).isSubset(of: allowed) else {
      throw FormError.invalid("Unknown or invalid \(label) fields.")
    }
    return fields
  }
  private static func decode<T: Decodable>(_ value: Any, _ type: T.Type) throws -> T {
    guard JSONSerialization.isValidJSONObject(value) else { throw FormError.invalid("Paper appearance needs finite JSON values.") }
    return try JSONDecoder.form.decode(type, from: JSONSerialization.data(withJSONObject: value))
  }
  private static func profile(_ value: Any, previous: PaperSurfaceProfile? = nil) throws -> PaperSurfaceProfile? {
    if value is NSNull { return nil }
    let patch = try fields(value, allowed: profileKeys, label: "paper profile")
    var merged = try jsonObject(previous ?? PaperSurfaceProfile()) as! [String: Any]
    for (key, value) in patch { merged[key] = value }
    let result = try decode(merged, PaperSurfaceProfile.self)
    try result.validate()
    return result
  }
  /// Normalize a partial declaration before construction validation. A supplied
  /// ply array establishes its caliper; expression parameters must still agree.
  public static func stock(_ value: Any, previous: PaperStock) throws -> PaperStock {
    let patch = try fields(value, allowed: stockKeys, label: "paper stock")
    var merged = try jsonObject(previous) as! [String: Any]
    for (key, value) in patch { merged[key] = value }
    if let raw = patch["profile"] {
      merged["profile"] = try profile(raw, previous: previous.profile).map { try jsonObject($0) } ?? NSNull()
    }
    if let raw = patch["plies"], !(raw is NSNull) {
      guard let array = raw as? [Any], !array.isEmpty, array.count <= 16 else { throw FormError.invalid("Use 1–16 bonded paper plies.") }
      let plies: [PaperPly] = try array.map { raw in
        var p = try fields(raw, allowed: plyKeys, label: "paper ply")
        if p["id"] == nil { p["id"] = UUID().uuidString }
        if let raw = p["profile"] { p["profile"] = try profile(raw).map { try jsonObject($0) } ?? NSNull() }
        let value = try decode(p, PaperPly.self)
        try value.validate()
        return value
      }
      merged["plies"] = try jsonObject(plies)
      if patch["thicknessMM"] == nil { merged["thicknessMM"] = plies.reduce(0) { $0 + $1.thicknessMM } }
    }
    if let raw = patch["sheetSizeMM"], !(raw is NSNull) { _ = try fields(raw, allowed: ["x", "y"], label: "paper sheet size") }
    let result = try decode(merged, PaperStock.self)
    try result.validate()
    return result
  }
  /// Whole-definition configuration must not silently discard a misspelled
  /// appearance field, even though Codable is permissive for older projects.
  public static func validateDefinitionFields(_ value: Any) throws {
    let definition = try fields(value, allowed: ["version", "kind", "authored", "dimensions", "stock", "clearanceMM", "glueTabMM", "topFlapMM", "bottomFlapMM", "cornerRadiusMM", "foldPercent", "openingPercent", "insideArtworkSourceID", "insideArtwork", "annotations", "artworkReviewRequired", "artworkReferenceSize", "finishes"], label: "paper definition")
    if let raw = definition["stock"] {
      let stock = try fields(raw, allowed: stockKeys, label: "paper stock")
      if let raw = stock["profile"], !(raw is NSNull) { _ = try fields(raw, allowed: profileKeys, label: "paper profile") }
      if let raw = stock["plies"], !(raw is NSNull) {
        guard let plies = raw as? [Any], plies.count <= 16 else { throw FormError.invalid("Invalid paper plies.") }
        for raw in plies {
          let ply = try fields(raw, allowed: plyKeys, label: "paper ply")
          if let raw = ply["profile"], !(raw is NSNull) { _ = try fields(raw, allowed: profileKeys, label: "ply profile") }
        }
      }
      if let raw = stock["sheetSizeMM"], !(raw is NSNull) { _ = try fields(raw, allowed: ["x", "y"], label: "paper sheet size") }
    }
    if let raw = definition["finishes"], !(raw is NSNull) {
      guard let finishes = raw as? [Any], finishes.count <= 128 else { throw FormError.invalid("Use at most128 finish assignments.") }
      for raw in finishes { _ = try fields(raw, allowed: finishKeys, label: "finish") }
    }
  }
  public static var presets: [PaperStock] {
    func stock(_ name: String, _ texture: PaperSurfaceProfile.Texture, _ color: String, _ thickness: Double, _ gsm: Double,
      roughness: Double = 0.92, scale: Double = 0.8, depth: Double = 0.015, opacity: Double = 1) -> PaperStock {
      .init(name: name, gsm: gsm, thicknessMM: thickness, verified: false,
        notes: "Editable visual stock assumption; no manufacturer, measured sample or press specification is implied.",
        profile: .init(texture: texture, color: color, roughness: roughness, textureScaleMM: scale, textureDepthMM: depth, opacity: opacity))
    }
    return [stock("Cotton letterpress · visual", .cotton, "#F1EBDD", 0.8, 600, scale: 1.2, depth: 0.035),
      stock("Smooth uncoated · visual", .smooth, "#F7F5EF", 0.35, 300),
      stock("Coated white · visual", .coated, "#FAFAF7", 0.3, 280, roughness: 0.3, depth: 0.002),
      stock("Laid warm white · visual", .laid, "#EAE4D4", 0.18, 120, scale: 1.2, depth: 0.02),
      stock("Linen textured · visual", .linen, "#EBE5D5", 0.3, 240, scale: 0.6, depth: 0.025),
      stock("Recycled fibers · visual", .recycled, "#CEBEA3", 0.4, 300, scale: 1.4, depth: 0.03),
      stock("Translucent vellum · visual", .vellum, "#F4EFE5", 0.12, 100, roughness: 0.65, depth: 0.004, opacity: 0.5)]
  }
  public static func call(engine: OperationEngine, arguments args: [String: Any], source: String) throws -> Any {
    guard let command = args["command"] as? String, names.contains(command) else { throw FormError.invalid("Unknown paper appearance command.") }
    if command == "save_stock" || command == "apply_stock" {return try materialCall(engine:engine,arguments:args,source:source)}
    let specific: Set<String> = command == "set_finish" ? ["finish"] : command == "remove_finish" ? ["finish_id"] : []
    guard Set(args.keys).isSubset(of: Set(["command", "object_id"]).union(specific)) else { throw FormError.invalid("Unknown paper appearance arguments.") }
    if command == "stock_presets" {
      return ["stocks": try jsonObject(presets), "units": "millimeters", "measured": false, "ply_order": "backToFront", "finish_kinds": PaperFinishAssignment.Kind.allCases.map(\.rawValue), "relief_representation": "surfaceShading", "manufacturing_verified": false]
    }
    guard let project = engine.project, let raw = args["object_id"] as? String, let id = UUID(uuidString: raw),
      let object = project.objects.first(where: { $0.id == id }), PaperConstruction.isPaper(object) else { throw FormError.missing("Choose a paper construction in the current project.") }
    if command == "appearance" { return try jsonObject(PaperAppearance.inspect(project: project, object: object)) }
    guard !object.locked else { throw FormError.invalid("Unlock this physical paper object before editing its finishes.") }
    var paper = try PaperConstruction.definition(for: object)
    if command == "set_finish" {
      guard let raw = args["finish"] else { throw FormError.invalid("Provide a finish assignment.") }
      var patch = try fields(raw, allowed: finishKeys, label: "finish")
      var previous: PaperFinishAssignment?
      if let raw = patch["id"] {
        guard let raw = raw as? String, let id = UUID(uuidString: raw) else { throw FormError.invalid("Finish id must be a UUID.") }
        previous = paper.finishes?.first { $0.id == id }
      } else { patch["id"] = UUID().uuidString }
      let defaults: [String: Any] = ["name": "Finish", "side": "outside", "depthMM": 0, "heightMM": 0, "opacity": 1, "enabled": true]
      var merged = try previous.map { try jsonObject($0) as! [String: Any] } ?? defaults
      for (key, value) in patch { merged[key] = value }
      let finish = try decode(merged, PaperFinishAssignment.self)
      try finish.validate()
      let target = PaperAppearance.source(project: project, object: object, side: finish.side)
      let available = Set(target.artwork?.elements.map(\.id) ?? [])
      let disablingRetained = previous != nil && !finish.enabled && previous?.elementIDs==finish.elementIDs && previous?.side==finish.side
      if !disablingRetained {
        guard let artwork=target.artwork,Set(finish.elementIDs).isSubset(of:available) else {
          throw FormError.invalid("Finish targets must exist in the canonical \(finish.side.rawValue) artwork. Create the inside source first when needed.")
        }
        try PaperAppearance.validateVisibleTargets(finish,artwork:artwork,project:project)
        try PaperAppearance.validateColorOverride(finish,artwork:artwork,project:project)
      }
      var finishes = paper.finishes ?? []
      if let index = finishes.firstIndex(where: { $0.id == finish.id }) { finishes[index] = finish }
      else { finishes.append(finish) }
      guard finishes.count <= 128 else { throw FormError.invalid("Use at most128 finish assignments per physical object.") }
      paper.finishes = finishes
    } else {
      guard let raw = args["finish_id"] as? String, let id = UUID(uuidString: raw), paper.finishes?.contains(where: { $0.id == id }) == true else {
        throw FormError.invalid("Choose an existing finish_id to remove.")
      }
      paper.finishes?.removeAll { $0.id == id }
      if paper.finishes?.isEmpty == true { paper.finishes = nil }
    }
    let updated = paper
    try engine.edit(command == "set_finish" ? "Changed paper finish" : "Removed paper finish", source: source,
      coalescing: source == "Studio" ? "paper-finish-\(id)" : nil) { project in
      guard let index = project.objects.firstIndex(where: { $0.id == id }) else { throw FormError.missing("Physical paper object missing.") }
      project.objects[index].paperConstruction = updated
    }
    return try jsonObject(PaperAppearance.inspect(project: engine.project!, object: engine.project!.objects.first { $0.id == id }!))
  }
}

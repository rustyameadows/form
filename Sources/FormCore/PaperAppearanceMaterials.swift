import Foundation

extension Project {
  public func validatePaperMaterialSnapshots() throws {
    for material in materials where material.paperStock != nil {
      try material.paperStock!.validate()
      try validateColor(material.color)
      guard material.category == "Paper", material.thickness.isFinite,
        abs(material.thickness - material.paperStock!.resolvedThicknessMM) <= 1e-9,
        material.roughness.isFinite, (0...1).contains(material.roughness),
        material.metallic.isFinite, (0...1).contains(material.metallic) else {
        throw FormError.invalid("A reusable paper material must retain its Paper category, ply-summed physical caliper and bounded appearance.")
      }
    }
  }
  /// Normal material picking and the explicit stock command use this one path.
  /// A library snapshot never silently replaces an existing different project
  /// material with the same ID, and the entire application is one document edit.
  public mutating func applyPaperStockMaterial(_ material: Material, to objectID: UUID) throws {
    guard let stock = material.paperStock, let object = objects.first(where: { $0.id == objectID }),
      PaperConstruction.isPaper(object), !object.locked else { throw FormError.invalid("Apply a paper-stock material to an unlocked paper construction.") }
    try stock.validate()
    var next = try PaperConstruction.definition(for: object)
    next.stock = stock
    if var authored = next.authored, abs(try authored.number(authored.stockThickness) - stock.resolvedThicknessMM) > 1e-9 {
      let expression = authored.stockThickness.expression.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let index = authored.parameters.firstIndex(where: { $0.name == expression }) else {
        throw FormError.invalid("This stock caliper uses a composed expression. Update its source parameters and stock atomically through form_paper configure.")
      }
      authored.parameters[index].value = stock.resolvedThicknessMM
      _ = try authored.net()
      next.authored = authored
    }
    try PaperCommands.applyConfiguration(next, objectID: objectID, in: &self)
    var snapshot = material
    if let prior = materials.first(where: { $0.id == snapshot.id }), prior != snapshot {
      snapshot.id = "paper-stock-" + UUID().uuidString.lowercased()
    }
    if !materials.contains(where: { $0.id == snapshot.id }) { materials.append(snapshot) }
    if let index = objects.firstIndex(where: { $0.id == objectID }) { objects[index].materialID = snapshot.id }
    try validatePaperMaterialSnapshots()
  }
}

extension PaperAppearanceCommands {
  static func materialCall(engine: OperationEngine, arguments args: [String: Any], source: String) throws -> Any {
    let command = args["command"] as? String ?? ""
    let allowed: Set<String> = command == "save_stock" ? ["command", "object_id", "stock", "name", "material_id"] : ["command", "object_id", "material_id"]
    guard Set(args.keys).isSubset(of: allowed) else { throw FormError.invalid("Unknown stock material arguments.") }
    let object = (args["object_id"] as? String).flatMap(UUID.init(uuidString:)).flatMap { id in engine.project?.objects.first { $0.id == id } }
    if args["object_id"] != nil,object == nil {throw FormError.missing("Choose an existing physical paper object UUID.")}
    if command == "apply_stock" {
      guard let object, let id = args["material_id"] as? String,
        let material = StudioLibrary.load(from: engine.repository.root).materials.first(where: { $0.id == id && $0.paperStock != nil })
          ?? engine.project?.materials.first(where: { $0.id == id && $0.paperStock != nil }) else { throw FormError.missing("Choose a saved paper-stock material and physical paper object.") }
      try engine.edit("Applied paper stock material", source: source) { project in try project.applyPaperStockMaterial(material, to: object.id) }
      let updated = engine.project!.objects.first { $0.id == object.id }!
      var result = try jsonObject(PaperAppearance.inspect(project: engine.project!, object: updated)) as! [String: Any]
      result["material_id"] = updated.materialID
      return result
    }
    guard object != nil || args["stock"] != nil else{throw FormError.invalid("Save a declared stock or an existing paper object's stock.")}
    let previous = try object.map { try PaperConstruction.definition(for: $0).stock } ?? PaperStock()
    let stock = try args["stock"].map { try self.stock($0, previous: previous) } ?? previous
    try stock.validate()
    let id: String
    if let raw = args["material_id"] {
      guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 160,
        value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) else { throw FormError.invalid("Use a bounded material_id containing letters, digits, dash, underscore or dot.") }
      id = value
    } else { id = "paper-stock-" + UUID().uuidString.lowercased() }
    let name: String
    if let raw = args["name"] { guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 256 else { throw FormError.invalid("Use a bounded stock material name.") }; name = value }
    else { name = stock.name }
    let color = stock.plies?.last?.color ?? stock.profile?.color ?? object?.color ?? object.flatMap { engine.project?.material($0.materialID).color } ?? "#F7F5EF"
    var material = Material(id, name, "Paper", color, roughness: stock.plies?.last?.profile?.roughness ?? stock.profile?.roughness ?? 0.94, thickness: stock.resolvedThicknessMM)
    material.paperStock = stock
    var library = StudioLibrary.load(from: engine.repository.root)
    if let index = library.materials.firstIndex(where: { $0.id == id }) {
      guard library.materials[index].paperStock != nil else { throw FormError.invalid("Choose a new material_id; this existing material is not a reusable paper-stock record.") }
      library.materials[index] = material
    } else { library.materials.append(material) }
    try library.save(to: engine.repository.root)
    return ["material": try jsonObject(material), "library_saved": true, "project_changed": false, "manufacturing_verified": false]
  }
}

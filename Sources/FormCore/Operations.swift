import CoreFoundation
import Foundation
import FormCADModel

/// Used by both the native interface and the local agent bridge. Call from one serial executor.
public final class OperationEngine {
  public let repository: ProjectRepository
  /// Advances for every assignment, including direct replacements, Undo and
  /// nested value edits. Derived UI caches can observe this without hashing a
  /// document on each pointer event; it is runtime state, never persisted.
  public private(set) var projectGeneration: UInt64 = 0
  public var project: Project? {
    didSet {
      projectGeneration &+= 1
      if project == nil || project?.id != oldValue?.id { validatedArtworkLinks = nil }
    }
  }
  public var selection: Set<UUID> = []
  public private(set) var undoStack: [Project] = []
  public private(set) var redoStack: [Project] = []
  public var onStudioShotValidate:((StudioShot)throws->Void)?
  public var onView: ((String, [String: Any]) throws -> Any)?
  public var onExport: ((String, [String: Any]) throws -> Any)?
  public var onPrint: ((String, [String: Any]) throws -> Any)?
  public var onGraphics: ((String, [String: Any]) throws -> Any)?
  public var onValidatePaint: ((Project, UUID, Set<UUID>) throws -> Void)?
  public var onPrepareSwatch:((Project,inout ArtworkSwatch)throws->Void)?
  public var onPrepareGlyph: ((inout ArtworkElement, GlyphOverride?) throws -> Void)?
  public var onPrepareOptical: ((Artwork, Set<UUID>, [String:Any]) throws -> Void)?
  public var onPrepareParagraphs: ((inout Artwork, Set<UUID>) throws -> Void)?
  public var onPrepareProjectEdit: ((Project, inout Project) throws -> Void)?
  public var onProjectWillChange: (() -> Void)?
  public var onProjectDidChange: (() -> Void)?
  private var interaction: String?
  private var interactionGeneration:UUID?
  private var interactionSnapshot: (project: Project, undo: [Project], redo: [Project])?
  private var lastCoalesce: String?
  private var lastEdit = Date.distantPast
  // A single exact COW snapshot of successfully validated content, never an
  // assumption that externally assigned projects or gesture labels are valid.
  private var validatedArtworkLinks: Project?
  private(set) var artworkLinkValidationCount = 0
  private(set) var placementValidationReuseCount = 0
  public init(repository: ProjectRepository) { self.repository = repository }

  public func open(_ id: UUID) throws {
    onProjectWillChange?()
    endInteraction()
    try flush()
    project = try repository.load(id)
    selection = []
    undoStack = []
    redoStack = []
    lastCoalesce = nil
    onProjectDidChange?()
  }
  public func flush() throws { if let project { try repository.save(project) } }
  public func edit(
    _ label: String, source: String = "Studio", coalescing: String? = nil,
    _ body: (inout Project) throws -> Void
  ) throws {
    if let interaction, interaction != coalescing { endInteraction() }
    guard var value = project else { throw FormError.missing("Open or create a project first.") }
    let before = value
    try body(&value)
    try onPrepareProjectEdit?(before, &value)
    value.refreshLibrarySelections()
    try CanvasPlacementValidation.validatePositions(in: value)
    if let validatedArtworkLinks, CanvasPlacementValidation.sameContent(validatedArtworkLinks, value) {
      placementValidationReuseCount += 1
    } else {
      artworkLinkValidationCount += 1
      try value.validateArtworkLinks()
    }
    value.schemaVersion = value.minimumSchemaVersion
    validatedArtworkLinks = value
    guard before != value else { return }
    if coalescing == nil || coalescing != lastCoalesce
      || (interaction != coalescing && Date().timeIntervalSince(lastEdit) > 0.65)
    {
      undoStack.append(before)
      if undoStack.count > 80 { undoStack.removeFirst() }
      value.history.append(.init(label, source: source))
      if value.history.count > 300 { value.history.removeFirst() }
    }
    lastCoalesce = coalescing
    lastEdit = Date()
    redoStack = []
    value.updatedAt = Date()
    project = value
  }
  public func undo() {
    endInteraction()
    guard let previous = undoStack.popLast(), let current = project else { return }
    redoStack.append(current)
    project = previous
    selection = selection.intersection(Set(previous.objects.map(\.id)))
    lastCoalesce = nil
  }
  /// Async document publications wait for the current native transaction to finish.
  public var hasActiveInteraction: Bool { interaction != nil }
  /// Native command adapters may preserve a matching gesture without exposing its mutable state.
  public func isInteracting(with key:String)->Bool {interaction==key}
  public func isInteracting(withGeneration token: UUID) -> Bool { interactionGeneration == token }
  @discardableResult public func beginInteraction(_ key:String)->UUID {
    if interaction==key,let token=interactionGeneration {return token}
    endInteraction()
    interaction = key
    let token=UUID();interactionGeneration=token
    if let project {
      interactionSnapshot = (project, undoStack, redoStack)
    }
    lastCoalesce = nil
    return token
  }
  public func endInteraction(ifGeneration token:UUID) {
    guard interactionGeneration==token else{return};endInteraction()
  }
  /// Cancel only the gesture the caller began. A delayed Escape or pointer-up
  /// must not roll back a newer gesture, an unrelated command, or another project.
  @discardableResult public func cancelInteraction(ifGeneration token: UUID) -> Bool {
    guard interactionGeneration == token, let snapshot = interactionSnapshot,
      project?.id == snapshot.project.id else { return false }
    project = snapshot.project
    undoStack = snapshot.undo
    redoStack = snapshot.redo
    endInteraction()
    return true
  }
  public func endInteraction() {
    if let snapshot = interactionSnapshot, var value = project {
      // Native text undo and cancelled drags can return to the exact starting design.
      // Remove their transient history entry and preserve any pre-existing redo branch.
      value.history = snapshot.project.history
      value.updatedAt = snapshot.project.updatedAt
      value.schemaVersion = snapshot.project.schemaVersion
      if value == snapshot.project {
        project = snapshot.project
        undoStack = snapshot.undo
        redoStack = snapshot.redo
      }
    }
    interaction = nil
    interactionGeneration=nil
    interactionSnapshot = nil
    lastCoalesce = nil
  }
  public func redo() {
    endInteraction()
    guard let next = redoStack.popLast(), let current = project else { return }
    undoStack.append(current)
    project = next
    lastCoalesce = nil
  }

  @discardableResult public func call(
    _ name: String, arguments a: [String: Any] = [:], source: String = "Codex"
  ) throws -> Any {
    func string(_ key: String) throws -> String {
      guard let value = a[key] as? String, !value.isEmpty else {
        throw FormError.invalid("'\(key)' is required.")
      }
      return value
    }
    func objectID() throws -> UUID {
      guard let id = UUID(uuidString: try string("object_id")) else {
        throw FormError.invalid("Invalid object_id.")
      }
      return id
    }
    func vector(_ value: Any?) throws -> Vector3 {
      guard let value else { return .init() }
      guard let values = value as? [Double], values.count == 3,
        values.allSatisfy({ $0.isFinite && abs($0) <= 100_000 })
      else {
        throw FormError.invalid("Position must be three finite millimeter values within ±100000.")
      }
      return .init(values[0], values[1], values[2])
    }
    func requireProject() throws -> Project {
      guard let project else { throw FormError.missing("Open or create a project first.") }
      return project
    }
    switch name {
    case "form_studio_scene":return try StudioSceneCommands.call(engine:self,arguments:a,source:source)
    case "form_paper":return try PaperCommands.call(engine:self,arguments:a,source:source)
    case "form_construction":return try ConstructionCommands.call(engine:self,arguments:a,source:source)
    case "form_surface":return try PhysicalSurfaceCommands.call(engine:self,arguments:a,source:source)
    case "form_status":
      return [
        "application": LabIdentity.name, "version": LabIdentity.version,
        "project_id": project?.id.uuidString as Any? ?? NSNull(),
        "project_name": project?.name as Any? ?? NSNull(),
        "selected_objects": selection.map(\.uuidString), "external_model_calls": false,
        "library_path": repository.root.path, "can_undo": !undoStack.isEmpty,
      ]
    case "form_list_projects": return try jsonObject(repository.list())
    case "form_create_project":
      let title = try string("name")
      guard title.count <= 160 else {
        throw FormError.invalid("Project names must be 160 characters or fewer.")
      }
      onProjectWillChange?()
      endInteraction()
      try flush()
      var new = try Samples.make(a["template"] as? String ?? "blank")
      new.name = title
      new.conversationReference = a["conversation_reference"] as? String
      new.materials = StudioLibrary.load(from: repository.root).materials.filter { item in
        !Material.presets.contains(item)
      }
      try repository.save(new)
      project = new
      selection = []
      undoStack = []
      redoStack = []
      onProjectDidChange?()
      return try jsonObject(new)
    case "form_open_project":
      guard let id = UUID(uuidString: try string("project_id")) else {
        throw FormError.invalid("Invalid project_id.")
      }
      try open(id)
      return try jsonObject(requireProject())
    case "form_get_project": return try jsonObject(requireProject())
    case "form_textile_zones": return try requireProject().textileZoneReport(objectID:objectID())
    case "form_get_artwork":
      let id = try objectID()
      guard let object = project?.objects.first(where: { $0.id == id }) else {
        throw FormError.missing("Object not found.")
      }
      let context=try a["physical_frame"].map{try PhysicalArtworkFrameContext.resolve(in:project!,objectID:id,raw:$0)}
      let owner=context.flatMap{value in project!.objects.first{$0.id==value.sourceObjectID}} ?? object
      let art=project!.editableArtwork(owner) ?? Artwork(background:"#FFFFFF")
      let resolved=a["resolved"] as? Bool == true ? try project!.resolvingComponents(in:art):art
      return try jsonObject(context?.frame.display(resolved) ?? resolved)
    case "form_component":
      let command = try string("command")
      if command == "list" {
        return ["components": try requireProject().artworkComponents.map { component -> [String: Any] in
          ["id": component.id.uuidString, "name": component.name,
           "width": component.artworkSize.x, "height": component.artworkSize.y,
           "parts": try (component.artwork?.elements ?? []).map { try jsonObject($0) },
           "override_parts": (component.artwork?.componentOverrideParts ?? []).map { $0.id.uuidString }]
        }]
      }
      let target = try objectID()
      var result: [String: Any] = [:]
      try edit("Component: \(command)", source: source) { p in
        switch command {
        case "create":
          let ids = try idsArgument(a["element_ids"])
          let created = try ComponentCommands.create(in: &p, objectID: target, elements: ids,
            name: a["name"] as? String ?? "Untitled component")
          result = ["source_object_id": created.source.uuidString, "selected_elements": [created.instance.uuidString]]
        case "insert":
          guard let raw = a["source_object_id"] as? String, let sourceID = UUID(uuidString: raw) else {
            throw FormError.invalid("Choose a component source_object_id.")
          }
          let id = try ComponentCommands.insert(in: &p, objectID: target, sourceID: sourceID,
            x: a["x"] as? Double ?? 10, y: a["y"] as? Double ?? 10,
            width: a["width"] as? Double, height: a["height"] as? Double)
          result = ["source_object_id": sourceID.uuidString, "selected_elements": [id.uuidString]]
        case "detach":
          let ids = try idsArgument(a["element_ids"])
          try ComponentCommands.detach(in: &p, objectID: target, ids: ids)
          result = ["selected_elements": ids.map(\.uuidString)]
        case "override", "reset":
          let ids = try idsArgument(a["element_ids"])
          guard let object = p.objects.first(where: { $0.id == target }), var art = p.editableArtwork(object),
            ids.isSubset(of: Set(art.elements.filter { $0.component != nil && !art.isLocked($0) }.map(\.id)))
          else { throw FormError.invalid("Select unlocked component instances.") }
          for i in art.elements.indices where ids.contains(art.elements[i].id) {
            if command == "reset" {
              art.elements[i].component = .init(sourceObjectID: art.elements[i].component!.sourceObjectID)
            } else {
              if let color = a["color"] {
                guard color is NSNull || color is String else { throw FormError.invalid("Color must be a hex string or null.") }
                art.elements[i].component?.color = color as? String
                art.elements[i].component?.colorSwatchID = nil
              }
              if let overrides = a["overrides"] {
                art.elements[i].component?.overrides = try JSONDecoder().decode([ArtworkComponentOverride].self,
                  from: JSONSerialization.data(withJSONObject: overrides))
              }
            }
          }
          try p.setArtwork(art, for: target)
          result = ["selected_elements": ids.map(\.uuidString)]
        default: throw FormError.invalid("Unknown component command.")
        }
      }
      return result
    case "form_edit_paint":
      let id = try objectID(), ids = try idsArgument(a["element_ids"])
      let command = a["command"] as? String ?? "update"
      var selectedStop: UUID?
      try edit("Vector paint", source:source, coalescing:source == "Studio" ? "paint-\(id)-\(command)-\(a["stop_id"] as? String ?? "")" : nil) { p in
        selectedStop = try PaintCommands.apply(in:&p,objectID:id,ids:ids,command:command,arguments:a)
        try self.onValidatePaint?(p,id,ids)
      }
      var result: [String:Any] = ["selected_elements":ids.map(\.uuidString)]
      if let selectedStop { result["selected_stop"] = selectedStop.uuidString }
      return result
    case "form_edit_image":
      let id = try objectID(), ids = try idsArgument(a["element_ids"])
      let command = a["command"] as? String ?? "update"
      guard ["update", "reset"].contains(command) else { throw FormError.invalid("Unknown image command.") }
      try edit("Image settings", source: source, coalescing: source == "Studio" ? "artwork-\(id)" : nil) { p in
        try ImageCommands.apply(in: &p, objectID: id, ids: ids, crop: a["crop"],
          adjustments: a["adjustments"], reset: command == "reset")
      }
      return ["selected_elements": ids.map(\.uuidString)]
    case "form_appearance":
      let id = try objectID()
      let ids = try idsArgument(a["element_ids"])
      let command = a["command"] as? String ?? "update"
      guard ["update", "reset"].contains(command) else { throw FormError.invalid("Unknown appearance command.") }
      guard a["values"] == nil || a["values"] is [String: Any] else { throw FormError.invalid("Provide appearance values as an object.") }
      try edit("Artwork appearance", source: source,
        coalescing: source == "Studio" ? "appearance-\(id)-\(ids.map(\.uuidString).sorted().joined())" : nil) { p in
        try AppearanceCommands.apply(in: &p, objectID: id, ids: ids,
          values: a["values"] as? [String: Any] ?? [:], reset: command == "reset")
      }
      return ["selected_elements": ids.map(\.uuidString)]
    case "form_text_style": return try textStyleCall(a, source: source)
    case "form_story","form_publication":return try publicationCall(name,a,source:source)
    case "form_swatch":
      let command = try string("command")
      if command == "list" { return ["swatches": try jsonObject(requireProject().swatches ?? [])] }
      func uuid(_ key: String) throws -> UUID {
        guard let raw = a[key] as? String, let value = UUID(uuidString: raw) else {
          throw FormError.invalid("Provide a valid \(key).")
        }
        return value
      }
      var result: [String: Any] = [:]
      let coalescing = source == "Studio" && command == "update" ? "swatch-\(a["swatch_id"] ?? "")" : nil
      try edit("Swatch: \(command)", source: source, coalescing: coalescing) { p in
        switch command {
        case "create", "update":
          let id: UUID? = command == "update" ? try uuid("swatch_id") : nil
          let old = p.swatches?.first { $0.id == id }
          let ink=try a["print_ink"].flatMap {raw->ProductionInk? in
            if raw is NSNull {return nil}
            return try JSONDecoder.form.decode(ProductionInk.self,from:JSONSerialization.data(withJSONObject:raw))
          }
          let saved = try SwatchCommands.save(in: &p, id: id,
            name: a["name"] as? String ?? old?.name ?? "Untitled color",
            color: a["color"] as? String ?? old?.color ?? "#D45A37",printInk:ink,replacingInk:a["print_ink"] != nil)
          if let index=p.swatches?.firstIndex(where:{$0.id==saved}) {
            var value=p.swatches![index];try onPrepareSwatch?(p,&value);p.swatches![index]=value
          }
          result = ["swatch": try jsonObject(p.swatches!.first { $0.id == saved }!)]
        case "delete":
          try SwatchCommands.delete(in: &p, id: uuid("swatch_id"))
          result = ["deleted": true]
        case "assign", "detach":
          let target = a["target"] as? String ?? "fill"
          let ids = target == "background" ? Set<UUID>() : try idsArgument(a["element_ids"])
          try SwatchCommands.assign(in: &p, objectID: objectID(), ids: ids, target: target,
            swatchID: command == "assign" ? try uuid("swatch_id") : nil,
            stopID: a["stop_id"] == nil ? nil : try uuid("stop_id"),
            partID: a["part_id"] == nil ? nil : try uuid("part_id"),
            location: a["location"] as? Int, length: a["length"] as? Int)
          result = ["selected_elements": ids.map(\.uuidString)]
        default: throw FormError.invalid("Unknown swatch command.")
        }
      }
      return result
    case "form_edit_artwork":
      if a["physical_frame"] != nil,ArtworkTransferCommands.recognizes(name,a) {
        throw FormError.invalid("Portable transfers use their canonical source contract; physical_frame is not supported for file transfers.")
      }
      if ArtworkTransferCommands.recognizes(name,a) {
        guard let onGraphics else{throw FormError.missing("Portable artwork transfer requires the running LAB app.")}
        var input=a;input["_source"]=source;return try onGraphics(name,input)
      }
      let physicalID=try objectID()
      let context=try a["physical_frame"].map{try PhysicalArtworkFrameContext.resolve(in:requireProject(),objectID:physicalID,raw:$0)}
      let id=context?.sourceObjectID ?? physicalID
      let command=try string("command")
      if context != nil,["page_setup","transfer","garment_block","pattern_piece","seam_pair","pattern_template","cut_layout","pattern_tiles"].contains(command) {
        throw FormError.invalid("This source/process command does not accept physical_frame; use its canonical source contract.")
      }
      let ids = a["element_ids"] == nil ? Set<UUID>() : try idsArgument(a["element_ids"])
      var selected = Set<UUID>()
      if command == "page_setup" {
        try edit("Page setup",source:source) {p in try ArtworkPageSetup.apply(in:&p,objectID:id,arguments:a)}
        return ["object_id":id.uuidString,"page_setup":true]
      }
      if command == "garment_block" {
        guard let project else { throw FormError.missing("Open a project first.") }
        if GarmentBlockCommands.isReadOnly(a) { return try GarmentBlockCommands.read(project,arguments:a) }
        var result:Any = [:]
        try edit("Garment block: \(a["operation"] as? String ?? "create")",source:source) { p in
          result=try GarmentBlockCommands.apply(in:&p,objectID:id,arguments:a)
        }
        return result
      }
      if command == "transfer" {
        guard let target = UUID(uuidString:try string("target_object_id")) else {
          throw FormError.invalid("Provide a destination target_object_id.")
        }
        let offset:Point2?
        if a["offset_x"] != nil || a["offset_y"] != nil {
          guard let x = a["offset_x"] as? NSNumber,let y = a["offset_y"] as? NSNumber,
            CFGetTypeID(x) != CFBooleanGetTypeID(),CFGetTypeID(y) != CFBooleanGetTypeID() else {
            throw FormError.invalid("Provide both offset_x and offset_y as physical millimeter numbers.")
          }
          offset = .init(x.doubleValue,y.doubleValue)
        } else { offset = nil }
        var ownerID = target
        try edit("Transferred artwork",source:source,
          coalescing:source == "Studio" && interaction == "artwork-\(id)" ? "artwork-\(id)" : nil) { p in
          selected = try p.transferArtwork(from:id,to:target,ids:ids,offset:offset)
          if let object = p.objects.first(where: { $0.id == target }) { ownerID = p.artworkOwner(object).id }
        }
        selection = [ownerID]
        return ["selected_elements":selected.map(\.uuidString),"target_object_id":ownerID.uuidString]
      }
      try edit(
        "Artwork: \(command)", source: source,
        coalescing: source == "Studio" && interaction == "artwork-\(id)" ? "artwork-\(id)" : nil
      ) { p in
        guard let object = p.objects.first(where: { $0.id == id }) else {
          throw FormError.missing("Object not found.")
        }
        if ["font","optical","character_position","paragraph","glyph","origin","transform","language","production","list","pattern_piece","seam_pair","pattern_template","cut_layout","pattern_tiles"].contains(command), p.artworkOwner(object).locked { throw FormError.invalid("Unlock the artwork object before editing it.") }
        if let context,(p.objects.first{$0.id==context.physicalObjectID}?.locked == true || p.artworkOwner(object).locked) {
          throw FormError.invalid("Unlock the construction and its artwork source before editing a physical frame.")
        }
        let original=p.editableArtwork(object) ?? Artwork(background:"#FFFFFF")
        var art=original
        if try PublicationCommands.editText(in:&p,objectID:id,ids:ids,command:command,arguments:a,prepareGlyph:onPrepareGlyph,prepareParagraphs:onPrepareParagraphs,prepareOptical:onPrepareOptical) {selected=ids;return}
        if let context {art=context.frame.display(original)}
        selected = try ArtworkCommands.apply(command, to: &art, ids: ids, arguments: a)
        if command=="optical" {try onPrepareOptical?(art,ids,a)}
        if ["font","optical","character_position"].contains(command) {try onPrepareParagraphs?(&art,art.swatchPaintTargets(for:ids))}
        if command=="glyph" {
          let targets=art.swatchPaintTargets(for:ids)
          let location=(a["location"] as? NSNumber)?.intValue
          for i in art.elements.indices where targets.contains(art.elements[i].id) && art.elements[i].kind=="text" {
            let choice=a["glyph"] is [String:Any] ? art.elements[i].glyphOverrides?.first(where:{$0.location==location}) : nil
            try onPrepareGlyph?(&art.elements[i],choice)
          }
        }
        if ["language","paragraph","glyph","list"].contains(command) {
          let targets=command=="language" ? Set(art.elements.map(\.id)):art.swatchPaintTargets(for:ids)
          try onPrepareParagraphs?(&art,targets)
        }
        let canonical=try context.map{try $0.frame.source(from:art,original:original)} ?? art
        try p.setArtwork(canonical,for:id)
      }
      return ["selected_elements": selected.map(\.uuidString)]
    case "form_edit_path":
      let physicalID=try objectID()
      let context=try a["physical_frame"].map{try PhysicalArtworkFrameContext.resolve(in:requireProject(),objectID:physicalID,raw:$0)}
      let id=context?.sourceObjectID ?? physicalID
      let elementIDs: Set<UUID>
      if let raw = a["element_ids"] {
        guard a["element_id"] == nil, let values = raw as? [String], !values.isEmpty else {
          throw FormError.invalid("Provide either element_id or a nonempty element_ids array.")
        }
        elementIDs = try idsArgument(raw)
      } else {
        guard let elementID = UUID(uuidString: try string("element_id")) else {
          throw FormError.invalid("Invalid path element ID.")
        }
        elementIDs = [elementID]
      }
      let operation = try string("operation")
      var nodes = Set<UUID>()
      if let raw = a["node_ids"] {
        guard let values = raw as? [String] else {
          throw FormError.invalid("node_ids must be an array of UUIDs.")
        }
        if !values.isEmpty { nodes = try idsArgument(values) }
      }
      if a["matrix"] != nil { _ = try numericParameters(a["matrix"]) }
      var selectedNodes = Set<UUID>()
      var selectedElements = Set<UUID>()
      try edit(
        "Path: \(operation)", source: source,
        coalescing: source == "Studio" && interaction == "artwork-\(id)" ? "artwork-\(id)" : nil
      ) { p in
        guard let object = p.objects.first(where: { $0.id == id }),
          let original = p.editableArtwork(object)
        else {
          throw FormError.missing("Path element not found.")
        }
        if let context,(p.objects.first{$0.id==context.physicalObjectID}?.locked == true || p.artworkOwner(object).locked) {
          throw FormError.invalid("Unlock the construction and its artwork source before editing a physical frame.")
        }
        var art=context?.frame.display(original) ?? original
        let result = try PathCommands.edit(
          operation, artwork: &art, elements: elementIDs, nodes: nodes, arguments: a)
        selectedNodes = result.nodes
        selectedElements = result.elements
        let canonical=try context.map{try $0.frame.source(from:art,original:original)} ?? art
        try p.setArtwork(canonical,for:id)
      }
      return [
        "selected_nodes": selectedNodes.map(\.uuidString),
        "selected_elements": selectedElements.map(\.uuidString),
      ]
    case "form_object_library": return try objectLibraryCall(a, source: source)
    case "form_list_recipes": return try jsonObject(Recipe.builtins + (project?.recipes ?? []))
    case "form_link_artwork":
      let id = try objectID()
      var sourceID: UUID?
      if let raw = a["source_object_id"], !(raw is NSNull) {
        guard let value = raw as? String, let parsed = UUID(uuidString: value) else {
          throw FormError.invalid("Invalid artwork source ID.")
        }
        sourceID = parsed
      }
      try edit(sourceID == nil ? "Detached artwork" : "Linked artwork", source: source) {
        try $0.linkArtwork(id, sourceID: sourceID, fit: a["fit"] as? String ?? "actual")
      }
      return try jsonObject(requireProject().objects.first { $0.id == id }!)
    case "form_extract_artwork":
      let id = try objectID()
      var created: ProductObject?
      try edit("Created independent artwork document", source: source) { p in
        guard let object = p.objects.first(where: { $0.id == id }), object.supportsArtworkFace,
          var art = p.surfaceArtwork(object)
        else { throw FormError.invalid("Choose an object with editable surface artwork.") }
        guard object.artworkSourceID == nil else {
          throw FormError.invalid("This object already links to an artwork document.")
        }
        let size = object.artworkSize
        guard (1...1000).contains(size.x), (1...1000).contains(size.y) else {
          throw FormError.invalid("Artwork documents support 1–1000 mm edges.")
        }
        var sheet = try p.makeObject(
          recipeID: "artboard", name: object.name + " · Artwork",
          parameters: ["width": size.x, "depth": size.y],
          position: .init(object.position.x + object.footprintWidth + 65, 0, object.position.z))
        art.boundary = nil
        sheet.artwork = art
        p.objects.append(sheet)
        try p.linkArtwork(id, sourceID: sheet.id)
        created = sheet
      }
      return try jsonObject(created!)
    case "form_list_materials":
      let local = project?.materials ?? []
      return try jsonObject(StudioLibrary.load(from: repository.root).materials.filter { item in
        !local.contains(where: { $0.id == item.id })
      } + local)
    case "form_add_object":
      let p = try requireProject()
      let recipe = try string("recipe_id")
      guard !["importedMesh", "cadModel"].contains(recipe) else {throw FormError.invalid("Use model import or CAD feature authoring to create an object with validated source geometry.")}
      if let raw = a["canvas_workspace"] {
        guard let flag = raw as? NSNumber,CFGetTypeID(flag) == CFBooleanGetTypeID() else {
          throw FormError.invalid("canvas_workspace must be a boolean.")
        }
        if flag.boolValue {
          guard recipe == "artboard" else { throw FormError.invalid("Use recipe_id artboard for the Canvas workspace.") }
          var workspace:ProductObject?
          try edit("Opened Canvas workspace",source:source) { workspace = try $0.ensureCanvasWorkspace() }
          return try jsonObject(workspace!)
        }
      }
      let parameters = try numericParameters(a["parameters"])
      var object = try p.makeObject(
        recipeID: recipe, name: a["name"] as? String, parameters: parameters,
        materialID: a["material_id"] as? String ?? (PaperConstruction.recipeIDs.contains(recipe) ? "paper-superfine":MerchandiseBlanks.defaultMaterial(recipe) ?? "chalk"), position: try vector(a["position"]))
      if let color = a["color"] as? String {
        try validateColor(color)
        object.color = color
      }
      if let raw = a["textile"] as? [String: Any] {
        object.textile = try JSONDecoder.form.decode(TextileProduct.self, from: JSONSerialization.data(withJSONObject: raw))
      }
      if recipe == "sleeve" { object.artwork = .cyanotype }
      var clockSource: ProductObject?
      if recipe == "clock" {
        clockSource = try ClockDesign.source(for: object, in: p)
        object.artworkSourceID = clockSource!.id
        object.artworkFit = "actual"
      }
      try edit("Added \(object.name)", source: source) {
        $0.objects.append(object)
        if let clockSource { $0.objects.append(clockSource) }
      }
      selection = [object.id]
      return try jsonObject(object)
    case "form_update_object":
      let id = try objectID()
      let params = try numericParameters(a["parameters"])
      try edit(
        "Updated object parameters", source: source,
        coalescing: source == "Studio" ? "parameters-\(id)" : nil
      ) { p in
        let previousPaperObjects=p.objects
        guard let index = p.objects.firstIndex(where: { $0.id == id }),
          let recipe = p.recipe(p.objects[index].recipeID)
        else { throw FormError.missing("Object not found.") }
        if p.objects[index].patternAssembly != nil, !params.isEmpty || a["material_id"] != nil || a["color"] != nil || a["fabric_pattern"] != nil {throw FormError.invalid("Edit original pattern geometry and per-panel fabric snapshots through form_cloth configure. The assembly has no independent parametric solid or global finish.")}
        if p.objects[index].locked,(!params.isEmpty && p.objects[index].artworkParameterBindings?.isEmpty == false || a["artwork_parameter_bindings"] != nil) {
          throw FormError.invalid("Unlock the canonical artwork source before editing its parameters or bindings.")
        }
        let merged = p.objects[index].parameters.merging(params) { _, new in new }
        try recipe.validate(merged)
        let oldCloth=p.objects[index].cloth
        if oldCloth != nil,!params.isEmpty,p.objects[index].locked {throw FormError.invalid("Unlock the cloth source before rebuilding its mesh.")}
        p.objects[index].parameters = merged
        if let raw=a["artwork_parameter_bindings"] {p.objects[index].artworkParameterBindings=try ArtworkParameterBindings.decode(raw)}
        if !params.isEmpty,ClothDesign.recipeIDs.contains(p.objects[index].recipeID) {
          let rebuilt=try ClothDesign.definition(for:p.objects[index],settings:oldCloth?.settings)
          try p.setCloth(rebuilt,for:id)
        }
        if let name = a["name"] as? String {
          guard !name.isEmpty, name.count <= 160 else {
            throw FormError.invalid("Object name must contain 1–160 characters.")
          }
          p.objects[index].name = name
        }
        if let material = a["material_id"] as? String { p.objects[index].materialID = material }
        if let raw = a["fabric_pattern"] {
          let pattern: FabricPattern?
          if raw is NSNull { pattern = nil }
          else if let value = raw as? [String: Any] {
            pattern = try JSONDecoder.form.decode(FabricPattern.self, from: JSONSerialization.data(withJSONObject: value))
          } else { throw FormError.invalid("Provide a fabric pattern definition or null.") }
          try p.setFabricPattern(pattern, materialID: p.objects[index].materialID)
        }
        if let raw = a["color"] {
          if raw is NSNull {p.objects[index].color=nil}
          else {guard let color=raw as? String else{throw FormError.invalid("Color must be a HEX string or null to clear its instance override.")};try validateColor(color);p.objects[index].color=color}
        }
        if a["position"] != nil {
          guard !p.objects[index].isClothAttached else {throw FormError.invalid("Use form_cloth attach material coordinates to move this decoration on its surface, or detach it first.")}
          p.objects[index].position = try vector(a["position"])
        }
        if let rotation = a["rotation"] as? Double {
          guard rotation.isFinite else { throw FormError.invalid("Rotation must be finite.") }
          p.objects[index].rotation = rotation
        }
        if let locked = a["locked"] as? Bool { p.objects[index].locked = locked }
        if let raw = a["textile"] {
          if raw is NSNull {
            guard !p.objects[index].locked || p.objects[index].textile?.embroidery==nil else {throw FormError.invalid("Unlock this decoration before removing its embroidery program.")}
            p.objects[index].textile = nil
          }
          else if let definition = raw as? [String: Any] {
            let next=try JSONDecoder.form.decode(TextileProduct.self, from: JSONSerialization.data(withJSONObject: definition))
            guard !p.objects[index].locked || next.embroidery==p.objects[index].textile?.embroidery else {throw FormError.invalid("Unlock this decoration before editing its embroidery program.")}
            p.objects[index].textile = next
          } else { throw FormError.invalid("Provide a textile product definition or null.") }
        }
        if let raw=a["embroidery"] {
          guard !p.objects[index].locked else {throw FormError.invalid("Unlock this decoration before editing its embroidery program.")}
          guard p.objects[index].textile?.kind != .garment,p.objects[index].textile != nil else {throw FormError.invalid("Choose a textile patch or independent decoration for digitizing.")}
          if raw is NSNull {p.objects[index].textile?.embroidery=nil}
          else if let definition=raw as? [String:Any] {
            let design=try JSONDecoder.form.decode(EmbroideryDesign.self,from:JSONSerialization.data(withJSONObject:definition))
            try design.validate();p.objects[index].textile?.embroidery=design
          } else {throw FormError.invalid("Provide an embroidery design definition or null.")}
        }
        if a["position"] != nil, p.objects[index].textile?.attachment != nil {
          p.setTextileWorldPosition(id, to: try vector(a["position"]))
        }
        // Variants share parameter and artwork definitions; material and placement remain local.
        if p.objects[index].relationship == "variant"
          || p.objects.contains(where: {
            $0.relationship == "variant" && $0.designID == p.objects[index].designID
          })
        {
          let design = p.objects[index].designID
          for i in p.objects.indices where p.objects[i].designID == design {
            p.objects[i].parameters = merged
            if i != index,!params.isEmpty,ClothDesign.recipeIDs.contains(p.objects[i].recipeID) {
              let linkedID=p.objects[i].id,definition=try ClothDesign.definition(for:p.objects[i],settings:p.objects[i].cloth?.settings)
              try p.setCloth(definition,for:linkedID)
            }
          }
        }
        if !params.isEmpty || a["artwork_parameter_bindings"] != nil {
          // Preserve the established shared-parameter family before resolving
          // any member's own canonical artwork fields from those controls.
          let design=p.objects[index].designID
          let owners=p.objects.filter{$0.designID==design && $0.artworkParameterBindings?.isEmpty == false}.map(\.id)
          for owner in owners {try p.applyArtworkParameterBindings(to:owner)}
        }
        let shared=p.objects[index].relationship=="variant" || p.objects.contains{$0.designID==p.objects[index].designID&&$0.relationship=="variant"}
        for i in p.objects.indices where PaperConstruction.isPaper(p.objects[i]) && (p.objects[i].id==id || shared&&p.objects[i].designID==p.objects[index].designID){
          if !params.isEmpty,p.objects[i].locked{throw FormError.invalid("Unlock linked paper constructions before changing their dimensions.")}
          p.objects[i]=try PaperConstructionEngine.synchronized(p.objects[i],previous:previousPaperObjects.first{$0.id==p.objects[i].id})
        }
        if let materialID=a["material_id"] as? String,PaperConstruction.isPaper(p.objects[index]),
          let material=p.materials.first(where:{$0.id==materialID}) ?? StudioLibrary.load(from:repository.root).materials.first(where:{$0.id==materialID}),material.paperStock != nil {
          try p.applyPaperStockMaterial(material,to:id)
        }
      }
      return try jsonObject(requireProject().objects.first { $0.id == id }!)
    case "form_delete_objects":
      let ids = try idsArgument(a["object_ids"])
      try edit("Removed \(ids.count) object(s)", source: source) { p in
        guard ids.allSatisfy({ id in p.objects.contains { $0.id == id } }) else {
          throw FormError.missing("One or more objects were not found.")
        }
        p.detachArtworkConsumers(of: ids)
        p.detachTextileConsumers(of: ids)
        p.objects.removeAll { ids.contains($0.id) }
        PublicationCommands.retainAvailableFrames(in:&p)
      }
      selection.subtract(ids)
      return ["removed": ids.count]
    case "form_duplicate_object":
      let id = try objectID()
      let p = try requireProject()
      guard var object = p.objects.first(where: { $0.id == id }) else {
        throw FormError.missing("Object not found.")
      }
      let mode = a["mode"] as? String ?? "iteration"
      guard ["iteration", "variant", "duplicate"].contains(mode) else {
        throw FormError.invalid("Mode must be iteration, variant, or duplicate.")
      }
      if mode=="variant",p.publications?.contains(where:{$0.pages.contains(where:{$0.objectID==id})})==true || object.artwork?.elements.contains(where:{$0.storyFrame != nil})==true {
        throw FormError.invalid("A publication page needs independent frame capacity. Duplicate it as an iteration instead of a linked variant.")
      }
      object.id = UUID()
      object.groupID = nil
      if object.textile?.attachment != nil {
        let placement = p.detachedTextilePlacement(object)
        object.position = placement.position
        object.rotation = placement.rotation
        object.textile?.laidFaceDown = placement.underside
        object.textile?.attachment = nil
      }
      object.position.x += object.footprintWidth + 55
      while p.objects.contains(where: {
        abs($0.position.x - object.position.x) < ($0.footprintWidth + object.footprintWidth) / 2
          + 25
          && abs($0.position.z - object.position.z) < ($0.footprintDepth + object.footprintDepth)
            / 2 + 25
      }) {
        object.position.x += object.footprintWidth + 55
      }
      object.name =
        a["name"] as? String ?? object.name + (mode == "variant" ? " · variant" : " · iteration")
      object.relationship = mode
      if mode != "variant" {
        if object.artworkSourceID != nil {
          if object.recipeID == "importedMesh" {let size=p.artworkSize(object);object.meshAsset?.artworkSizeMM = .init(width:size.x,height:size.y)}
          object.artwork = p.surfaceArtwork(object,keepingSwatchReferences:true)
          object.artwork?.requiresInkOutput=false
          object.artworkSourceID = nil
          object.artworkFit = nil
          if object.recipeID == "clock" { object.artwork?.boundary = nil }
        }
        object.designID = UUID()
        if object.cadModel != nil {
          object.cadModel!.id = UUID()
          object.cadRepresentation?.modelID = object.cadModel!.id
          object.cadRepresentation?.definitionSHA256 = try CADRepresentation.definitionHash(object.cadModel!)
        }
        object.parentIterationID = id
      }
      if let material = a["material_id"] as? String { object.materialID = material }
      if let position=object.artwork?.canvasPosition {let width=object.artworkSize.x;object.artwork?.canvasPosition = .init(position.x+width+24,position.y)}
      try edit("Created \(mode)", source: source) { candidate in
        candidate.objects.append(object)
        try PublicationCommands.duplicatePage(in:&candidate,from:id,to:object.id)
      }
      selection = [object.id]
      return try jsonObject(object)
    case "form_group_objects":
      let ids = try idsArgument(a["object_ids"])
      let group = UUID()
      try edit("Grouped objects", source: source) { p in
        guard ids.count >= 2, ids.allSatisfy({ id in p.objects.contains { $0.id == id } }) else {
          throw FormError.invalid("Choose at least two existing objects to group.")
        }
        for i in p.objects.indices where ids.contains(p.objects[i].id) {
          p.objects[i].groupID = a["ungroup"] as? Bool == true ? nil : group
        }
      }
      return ["group_id": group.uuidString]
    case "form_set_artwork":
      let id = try objectID()
      guard let data = a["artwork"] else { throw FormError.invalid("artwork is required.") }
      let artwork = try JSONDecoder().decode(
        Artwork.self, from: JSONSerialization.data(withJSONObject: data))
      try validateArtwork(artwork)
      for element in artwork.elements where element.kind == "image" {
        guard let asset = element.asset,
          FileManager.default.fileExists(
            atPath: try repository.assetURL(asset, in: requireProject().id).path)
        else {
          throw FormError.missing(
            "Artwork image asset not found. Import the image into this project first.")
        }
      }
      try edit(
        "Edited artwork", source: source, coalescing: source == "Studio" ? "artwork-\(id)" : nil
      ) { p in
        try p.setArtwork(artwork, for: id)
      }
      return ["updated": id.uuidString]
    case "form_add_note":
      let text = try string("text")
      let kind = a["kind"] as? String ?? "decision"
      guard ["decision", "question"].contains(kind), text.count <= 4000 else {
        throw FormError.invalid("Use a decision or question with at most 4000 characters.")
      }
      let note = ProjectNote(text, kind: kind)
      try edit("Added \(kind)", source: source) { $0.notes.append(note) }
      return try jsonObject(note)
    case "form_create_recipe":
      guard let value = a["recipe"] as? [String: Any] else {
        throw FormError.invalid("recipe is required.")
      }
      let recipe = try decodeRecipe(value)
      try edit("Added parametric recipe: \(recipe.name)", source: source) { p in
        if let i=p.recipes.firstIndex(where:{$0.id==recipe.id}) {
          guard a["replace"] as? Bool == true else{throw FormError.invalid("Recipe ID already exists. Use replace:true to edit its project-owned definition.")}
          for j in p.objects.indices where p.objects[j].recipeID==recipe.id {
            let values=recipe.defaults.merging(p.objects[j].parameters){_,new in new};try recipe.validate(values);p.objects[j].parameters=values
          }
          p.recipes[i]=recipe
        }else{
          guard p.recipe(recipe.id)==nil else{throw FormError.invalid("Built-in recipes cannot be replaced by a project.")}
          p.recipes.append(recipe)
        }
      }
      return try jsonObject(recipe)
    case "form_import_reference":
      let p = try requireProject()
      let asset = try repository.importAsset(URL(fileURLWithPath: try string("path")), into: p.id)
      var object = try p.makeObject(
        recipeID: "reference",
        name: a["name"] as? String
          ?? URL(fileURLWithPath: try string("path")).deletingPathExtension().lastPathComponent,
        position: try vector(a["position"]))
      object.asset = asset
      try edit("Imported reference", source: source) { $0.objects.append(object) }
      selection = [object.id]
      return try jsonObject(object)
    case "form_set_view":
      if a["view"] as? String == "studio", a["studio_command"] != nil, a["studio_command"] as? String != "recall" {
        guard let current=project else {throw FormError.missing("Open a project first.")}
        if StudioShotCommands.isInspection(a) {return try StudioShotCommands.inspect(current,args:a)}
        var result:StudioShot?
        try edit("Edited Studio shot",source:source) {result=try StudioShotCommands.apply(&$0,args:a);if let result,["capture","update"].contains(a["studio_command"] as? String ?? ""){try onStudioShotValidate?(result)}}
        return try result.map {try jsonObject($0)} ?? ["deleted":true]
      }
      guard let onView else {
        throw FormError.missing("View controls require the running LAB app.")
      }
      return try onView(try string("view"), a)
    case "form_export":
      guard let onExport else { throw FormError.missing("Export requires the running LAB app.") }
      try flush()
      return try onExport(try string("format"), a)
    case "form_undo":
      undo()
      return ["undone": true]
    case "form_redo":
      redo()
      return ["redone": true]
    case "form_batch":
      guard !ArtworkTransferCommands.rejectsBatch(name,a) else{throw FormError.invalid("Portable file transfers require individual calls; batch rollback cannot cover their external assets/files.")}
      guard let operations = a["operations"] as? [[String: Any]], !operations.isEmpty,
        operations.count <= 100
      else { throw FormError.invalid("Provide 1–100 operations.") }
      let allowed = Set([
        "form_object_library",
        "form_add_object", "form_update_object", "form_duplicate_object", "form_group_objects",
        "form_set_artwork", "form_add_note", "form_create_recipe", "form_delete_objects",
        "form_edit_artwork",
        "form_edit_path",
        "form_boolean_artwork", "form_convert_to_paths", "form_component", "form_swatch", "form_text_style", "form_appearance", "form_edit_image", "form_edit_paint",
        "form_link_artwork", "form_extract_artwork",
        "form_story","form_publication","form_color_profile",
      ])
      guard operations.allSatisfy({ allowed.contains($0["name"] as? String ?? "") }) else {
        throw FormError.invalid(
          "Batch accepts only object, artwork, recipe, group, and note edits.")
      }
      guard operations.allSatisfy({ operation in
        operation["name"] as? String != "form_color_profile"
          || ["set", "clear"].contains((operation["arguments"] as? [String: Any])?["command"] as? String ?? "list")
      }) else { throw FormError.invalid("Color-profile batches accept set or clear commands only.") }
      let original = project
      let oldUndo = undoStack
      let oldRedo = redoStack
      let selected = selection
      do {
        var results: [Any] = []
        for operation in operations {
          results.append(
            try call(
              operation["name"] as! String,
              arguments: operation["arguments"] as? [String: Any] ?? [:], source: source))
        }
        undoStack = oldUndo
        if let original { undoStack.append(original) }
        redoStack = []
        return ["results": results]
      } catch {
        project = original
        undoStack = oldUndo
        redoStack = oldRedo
        selection = selected
        throw error
      }
    default:
      if MCP.printToolNames.contains(name), let onPrint { return try onPrint(name, a) }
      if MCP.graphicsToolNames.contains(name), let onGraphics { return try onGraphics(name, a) }
      throw FormError.invalid("Unknown tool '\(name)'.")
    }
  }
}

private func numericParameters(_ value: Any?) throws -> [String: Double] {
  guard let value else { return [:] }
  guard let dict = value as? [String: Any] else {
    throw FormError.invalid("parameters must be a dictionary of numbers.")
  }
  var result: [String: Double] = [:]
  for (key, value) in dict {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite
    else { throw FormError.invalid("Parameter '\(key)' must be a finite number.") }
    result[key] = number.doubleValue
  }
  return result
}
private func idsArgument(_ value: Any?) throws -> Set<UUID> {
  guard let strings = value as? [String], !strings.isEmpty else {
    throw FormError.invalid("object_ids must be a nonempty array.")
  }
  let ids = strings.compactMap(UUID.init(uuidString:))
  guard ids.count == strings.count else { throw FormError.invalid("Invalid object ID.") }
  return Set(ids)
}
public func validateColor(_ color: String) throws {
  guard color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
    throw FormError.invalid("Colors must be six-digit hex values, such as #D45A37.")
  }
}
public func validateArtwork(_ artwork: Artwork,maxTextCharacters:Int=10000) throws {
  try ParagraphLanguage.validate(artwork.language)
  try validateColor(artwork.background)
  guard artwork.safeInset.map({$0.isFinite && $0>=0}) ?? true else{throw FormError.invalid("Safe inset must be finite and nonnegative.")}
  guard artwork.elements.count <= 5000, artwork.bleed.isFinite, (0...25).contains(artwork.bleed)
  else { throw FormError.invalid("Artwork supports up to 5000 elements and 0–25 mm bleed.") }
  for element in artwork.elements {
    try validateColor(element.color)
    guard
      ["text", "rectangle", "ellipse", "image", "line", "polygon", "star", "path", "group"]
        .contains(element.kind),
      [element.x, element.y, element.width, element.height, element.fontSize].allSatisfy({
        $0.isFinite && abs($0) <= 10000
      }), element.width > 0, element.height > 0, element.fontSize > 0, element.text.count <= maxTextCharacters
    else { throw FormError.invalid("Invalid artwork element dimensions, type, or text.") }
    if element.kind == "image" {
      guard let asset = element.asset, !asset.contains("/"), !asset.contains("..") else {
        throw FormError.invalid("Images must reference an imported project asset.")
      }
    }
  }
  try validateArtworkDetails(artwork)
}
public func decodeRecipe(_ value: [String: Any]) throws -> Recipe {
  guard let id = value["id"] as? String,
    id.range(of: "^[a-zA-Z][a-zA-Z0-9_]{0,63}$", options: .regularExpression) != nil,
    let name = value["name"] as? String, !name.isEmpty,
    let params = value["parameters"] as? [[String: Any]], !params.isEmpty, params.count <= 24,
    let parts = value["parts"] as? [[String: Any]], parts.count <= 100
  else { throw FormError.invalid("A recipe needs an ID, name, 1–24 parameters, and 0–100 primitive parts. An independent canonical artwork source may use an empty parts array.") }
  let parameters: [Parameter] = try params.map { p in
    guard let key = p["id"] as? String, key != "pi",
      key.range(of: "^[a-zA-Z][a-zA-Z0-9_]{0,47}$", options: .regularExpression) != nil,
      let title = p["name"] as? String,
      let min = p["minimum"] as? Double, let max = p["maximum"] as? Double,
      let initial = p["value"] as? Double,
      min.isFinite, max.isFinite, min < max, initial.isFinite, initial >= min, initial <= max,
      abs(min) <= 10000, abs(max) <= 10000
    else {
      throw FormError.invalid(
        "Each parameter needs an ID, name, finite minimum < maximum, and a default value in range.")
    }
    let step = p["step"] as? Double ?? 1
    guard step.isFinite, step > 0 else {
      throw FormError.invalid("Parameter step must be positive.")
    }
    return .init(key, title, initial, min...max, unit: p["unit"] as? String ?? "mm", step: step)
  }
  guard Set(parameters.map(\.id)).count == parameters.count else {
    throw FormError.invalid("Parameter IDs must be unique.")
  }
  let definitions: [PartDefinition] = try parts.map { part in
    guard let kind = part["kind"] as? String,
      ["box", "cylinder", "cone", "sphere", "torus"].contains(kind),
      let values = part["values"] as? [String: String]
    else {
      throw FormError.invalid(
        "Parts support box, cylinder, cone, sphere, or torus with arithmetic expression values.")
    }
    let allowed = Set([
      "width", "height", "depth", "radius", "topRadius", "bottomRadius", "ringRadius", "pipeRadius",
      "x", "y", "z", "rotationX", "rotationY", "rotationZ", "corner",
    ])
    let required: [String] =
      kind == "box"
      ? ["width", "height", "depth"]
      : kind == "cylinder"
        ? ["radius", "height"]
        : kind == "cone"
          ? ["topRadius", "bottomRadius", "height"]
          : kind == "sphere" ? ["radius"] : ["ringRadius", "pipeRadius"]
    guard Set(values.keys).isSubset(of: allowed), required.allSatisfy({ values[$0] != nil }) else {
      throw FormError.invalid(
        "Part '\(kind)' needs \(required.joined(separator:", ")) and only supported expression fields."
      )
    }
    if let color = part["color"] as? String { try validateColor(color) }
    return .init(kind, values, color: part["color"] as? String)
  }
  let solid:ParametricSolid?
  if let raw=value["solid"] {
    guard parts.isEmpty,let dictionary=raw as? [String:Any] else{throw FormError.invalid("Use either ordinary parts or a solid construction.")}
    let data=try JSONSerialization.data(withJSONObject:dictionary)
    guard data.count<=512_000 else{throw FormError.invalid("Solid definition exceeds 512 KB.")}
    solid=try JSONDecoder().decode(ParametricSolid.self,from:data)
  }else{solid=nil}
  let requirements:[CADModelRequirement]?
  if let raw=value["requirements"],!(raw is NSNull) {
    guard let values=raw as? [[String:Any]],values.count<=128,
      JSONSerialization.isValidJSONObject(values) else {
      throw FormError.invalid("Recipe requirements must contain at most 128 JSON-safe comparison rules.")
    }
    let data=try JSONSerialization.data(withJSONObject:values)
    guard data.count<=512_000 else{throw FormError.invalid("Recipe requirements exceed 512 KB.")}
    requirements=try JSONDecoder().decode([CADModelRequirement].self,from:data)
  }else{requirements=nil}
  let recipe = Recipe(
    id, name, value["symbol"] as? String ?? "cube.transparent",
    value["summary"] as? String ?? "A custom parametric object.", parameters, parts: definitions,requirements:requirements,solid:solid)
  try recipe.validate(recipe.defaults)
  return recipe
}

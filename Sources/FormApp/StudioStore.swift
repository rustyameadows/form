import AppKit
import FormCore
import FormGraphics
import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceMode: String, CaseIterable {
  case table = "Table"
  case artwork = "Canvas"
  case studio = "Studio"
}

enum TableTool: String, CaseIterable {
  case orbit = "Orbit"
  case move = "Move"
  var symbol: String {
    switch self {
    case .orbit: return "rotate.3d"
    case .move: return "cursorarrow"
    }
  }
  var shortcut: String {
    switch self {
    case .orbit: return "O"
    case .move: return "V"
    }
  }
  var hint: String {
    switch self {
    case .orbit: return "Drag to orbit · Shift-drag to pan · Scroll to zoom"
    case .move: return "Drag objects to move · Shift snaps placement · O returns to navigation"
    }
  }
}

@MainActor final class StudioStore: ObservableObject {
  static let shared = StudioStore()
  let repository: ProjectRepository
  let engine: OperationEngine
  let bridge = LocalBridgeServer()
  @Published var revision = 0
  @Published var showingHome = true
  @Published var mode: WorkspaceMode = .table
  @Published var surfaceLayout: DesignSurfaceLayout = .single
  var canvasWindowController: CanvasWindowController?
  @Published var projects: [ProjectSummary] = []
  @Published var notice: String?
  @Published var error: String?
  @Published var showingLibrary = false
  @Published var showingProjectInfo = false
  @Published var showingBridge = false
  @Published var showingPrint = false
  @Published var svgImport: SVGImportReview?
  @Published var showGrid = false
  @Published var tableTool: TableTool = .orbit
  @Published var isolated: Set<UUID> = []
  @Published var studioPreset = "Daylight"
  @Published var previewVersion = 0
  @Published var saving = false
  @Published var library: StudioLibrary
  var scene: TableSceneController?
  lazy var printing = PrintCoordinator(store: self)
  @Published var showingDocumentFonts=false
  var fontLibraryPreferences=FontLibraryPreferences.environment()
  lazy var cloth = ClothCoordinator(store:self)
  lazy var artworkSession = ArtworkSession(store: self)
  private var saveWork: DispatchWorkItem?
  private var previewWork: DispatchWorkItem?
  private var noticeWork: DispatchWorkItem?
  var bridgeReady = false
  var choosingSVG = false
  var project: Project? { engine.project }
  var selected: [ProductObject] {
    project?.objects.filter { !$0.isCanvasWorkspace && engine.selection.contains($0.id) } ?? []
  }
  var primary: ProductObject? { selected.first }
  var materials: [FormCore.Material] {
    let overrides = project?.materials ?? []
    let ids = Set(overrides.map(\.id))
    return library.materials.filter { !ids.contains($0.id) } + overrides
  }

  init(repository suppliedRepository: ProjectRepository? = nil, seedLibrary: Bool = true) {
    do {
      repository = try suppliedRepository ?? ProjectRepository()
      engine = OperationEngine(repository: repository)
      library = StudioLibrary.load(from: repository.root)
      try library.save(to: repository.root)
      if seedLibrary { try repository.seedIfEmpty() }
      projects = try repository.list()
    } catch { fatalError("FORM could not open its project library: \(error.localizedDescription)") }
    engine.onView = { [weak self] view, args in
      guard let self else { return [:] }
      try self.applyView(view, args)
      return ["view": view]
    }
    engine.onExport = { [weak self] format, args in
      guard let self else { return [:] }
      return try self.export(format: format, arguments: args)
    }
    engine.onPrint = { [weak self] name, args in
      guard let self else { throw FormError.missing("FORM is closing.") }
      return try self.printing.call(name, args)
    }
    engine.onGraphics = { [weak self] name, args in
      guard let self else { throw FormError.missing("FORM is closing.") }
      return try self.graphicsCall(name, args)
    }
    engine.onValidatePaint = { p,id,ids in
      guard let object = p.objects.first(where:{$0.id == id}), let raw = p.editableArtwork(object) else { return }
      let art = try BooleanGeometry.materialized(p.resolvingComponents(in:raw))
      for e in art.elements where ids.contains(e.id) && e.visibleStroke != nil { _ = try VectorGeometry.expandedStroke(e) }
    }
    engine.onPrepareSwatch = { [weak self] project,swatch in
      guard let self else{throw FormError.missing("FORM is closing.")}
      try self.prepareProductionSwatch(project,&swatch)
    }
    engine.onPrepareGlyph = { element, choice in
      if let choice {try GlyphEngine.validateSelection(element, choice: choice)}
      if element.typography?.frameMode=="point" {
        let size=TypographyEngine.measured(element)
        element.width=max(1,size.width+0.5)
        element.height=max(element.fontSize/TypographyEngine.pointsPerMM*1.4,size.height+0.5)
      }
    }
    engine.onPrepareParagraphs = { artwork, ids in
      for i in artwork.elements.indices where ids.contains(artwork.elements[i].id)
        && artwork.elements[i].kind=="text" && artwork.elements[i].typography?.frameMode=="point" {
        let element=artwork.elements[i].inheritingLanguage(artwork.language)
        let size=TypographyEngine.measured(element)
        artwork.elements[i].width=max(1,size.width+0.5)
        artwork.elements[i].height=max(element.fontSize/TypographyEngine.pointsPerMM*1.4,size.height+0.5)
      }
    }
    engine.onProjectWillChange = { [weak self] in self?.finishArtworkEditing() }
    engine.onProjectDidChange = { [weak self] in
      self?.closeDetachedCanvas()
      self?.printing.resetForProjectChange()
      self?.cloth.clear()
      self?.showingPrint = false
      self?.artworkSession.showingTextStyles = false
      self?.artworkSession.showingPalette = false
      self?.artworkSession.showingTabs = false
      self?.artworkSession.showingGlyphs = false
      self?.showingDocumentFonts=false
    }
  }
  func finishArtworkEditing() {
    artworkSession.croppingImageID = nil
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
    artworkSession.canvas?.finishText()
    artworkSession.canvas?.finishPath()
    NSApp.keyWindow?.makeFirstResponder(nil)
  }
  func startBridge() {
    do {
      try bridge.start { [weak self] name, args, completion in
        DispatchQueue.main.async {
          guard let self else {
            completion(.failure(FormError.missing("FORM is closing.")))
            return
          }
          do {
            if name == "form_cloth" {completion(.success(try self.bridgeClothCall(args)));return}
            let readOnly =
              [
                "form_status", "form_list_projects", "form_get_project", "form_list_recipes", "form_textile_zones",
                "form_list_materials", "form_get_print_setup", "form_get_slice_status",
                "form_list_filaments", "form_list_printers", "form_get_artwork",
                "form_list_fonts", "form_font_features", "form_image_info", "form_export_publication",
              ].contains(name) || (name == "form_import_svg" && args["dry_run"] as? Bool == true)
                || (name=="form_export_artwork" && args["ink_output"] as? String=="preflight")
                || (name == "form_replace_font" && args["dry_run"] as? Bool==true)
                || (name == "form_component" && args["command"] as? String == "list")
                || (name == "form_swatch" && args["command"] as? String == "list")
                || (name == "form_text_style" && args["command"] as? String == "list")
                || (name == "form_color_profile" && ["list", "get"].contains(args["command"] as? String ?? "list"))
                || (["form_textile_stock","form_production_job"].contains(name) && ["list","get"].contains(args["command"] as? String ?? "list"))
                || (name == "form_story" && ["list","get","layout"].contains(args["command"] as? String ?? "list"))
                || (name == "form_publication" && ["list","get","preflight"].contains(args["command"] as? String ?? "list"))
            if !readOnly {
              try self.preflightInkHandoff(name,args)
              try self.preflightFontHandoff(name,args)
              try self.preflightPublicationHandoff(name,args);self.finishArtworkEditing()
            }
            var result = try self.engine.call(name, arguments: args)
            if ["form_undo","form_redo"].contains(name) {self.cloth.historyChanged()}
            if !readOnly { self.artworkSession.showingTabs = false;self.artworkSession.showingGlyphs=false }
            if name == "form_status", var status = result as? [String: Any] {
              status["renderer"] = self.scene?.diagnostics ?? [:]
              status["artwork_renderer"] = self.artworkSession.canvas?.diagnostics ?? [:]
              status["design_surfaces"] = [
                "layout": self.surfaceLayout.rawValue,
                "focused_surface": self.mode.rawValue.lowercased(),
                "canvas_window_open": self.canvasWindowController?.window?.isVisible == true,
                "canvas_workspace_id": self.project?.canvasWorkspace.map { $0.id.uuidString as Any } ?? NSNull(),
                "artwork_object_id": self.artworkSession.objectID.map { $0.uuidString as Any } ?? NSNull(),
              ]
              status["cloth_preview"] = ["object_id":self.cloth.preview.source?.objectID.uuidString as Any? ?? NSNull(),"diagnostics":self.cloth.preview.diagnostics.flatMap {try? jsonObject($0)} ?? NSNull(),"runtime_persisted":false]
              status["boolean_geometry"] = BooleanGeometry.diagnostics
              status["component_resolution"] = ComponentCommands.resolutionDiagnostics
              status["appearance_renderer"] = AppearanceRenderer.diagnostics
              status["image_renderer"] = ImageRenderer.diagnostics
              status["stroke_geometry"] = StrokeGeometry.diagnostics
              result = status
            }
            if !readOnly {
              if ["form_create_project", "form_open_project"].contains(name) {
                self.restoreProjectWorkspace()
              }
              if self.project != nil && name != "form_set_view" { self.showingHome = false }
              self.changed()
              try self.engine.flush()
              self.saving = false
              self.toast("Updated from Codex", symbol: "sparkle")
            }
            completion(.success(result))
          } catch { completion(.failure(error)) }
        }
      }
      bridgeReady = true
    } catch { self.error = error.localizedDescription }
  }
  func perform(_ name: String, _ args: [String: Any] = [:]) {
    do {
      try engine.call(name, arguments: args, source: "Studio")
      changed()
    } catch { self.error = error.localizedDescription }
  }
  func changed(save: Bool = true) {
    let ids = Set(project?.objects.map(\.id) ?? [])
    engine.selection.formIntersection(ids)
    let visible = isolated.intersection(ids)
    if visible != isolated { isolated = visible }
    printing.reconcile()
    cloth.reconcile()
    revision &+= 1
    if save { scheduleSave() }
  }
  func cameraChanged() {
    guard project != nil else { return }
    scheduleSave()
  }
  private func scheduleSave() {
    if !saving { saving = true }
    saveWork?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.save() }
    saveWork = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
  }
  func setTableTool(_ tool: TableTool) {
    tableTool = tool
    if let view = scene?.view {
      view.window?.makeFirstResponder(view)
      view.window?.invalidateCursorRects(for: view)
    }
  }
  func save() {
    do {
      try engine.flush()
      projects = try repository.list()
      saving = false
    } catch { self.error = "Could not save: \(error.localizedDescription)" }
  }
  func edit(_ label: String, coalescing: String? = nil, _ body: (inout Project) throws -> Void) {
    do {
      try engine.edit(label, coalescing: coalescing, body)
      changed()
    } catch { self.error = error.localizedDescription }
  }
  func createProject(template: String = "blank") {
    let base = Samples.templates.first { $0.id == template }?.name ?? "Untitled study"
    let count = projects.filter { $0.name.hasPrefix(base) }.count
    perform(
      "form_create_project",
      ["name": count == 0 ? base : "\(base) \(count+1)", "template": template])
    mode = .table
    showingHome = false
    isolated = []
    scene?.resetCamera()
    if template == "blank" { showSurface(.artwork) }
  }
  func openProject(_ id: UUID) {
    do {
      capturePreview()
      try engine.open(id)
      restoreProjectWorkspace()
      showingHome = false
      changed(save: false)
    } catch { self.error = error.localizedDescription }
  }
  private func restoreProjectWorkspace() {
    isolated = []
    mode = .table
    if let first=project?.publications?.first?.pages.first,project?.objects.contains(where:{$0.id==first.objectID})==true {
      mode = .artwork
      artworkSession.activate(first.objectID)
    } else if let project,project.physicalObjectCount == 0,let workspace = project.canvasWorkspace {
      mode = .artwork
      artworkSession.activate(workspace.id)
    }
    scene?.resetCamera()
  }
  func home() {
    cloth.clear()
    closeDetachedCanvas()
    surfaceLayout = .single
    finishArtworkEditing()
    save()
    capturePreview()
    showingHome = true
    engine.selection = []
    isolated = []
    generateMissingPreviews()
  }
  func select(_ id: UUID?, extending: Bool = false) {
    guard let id else {
      if !extending { engine.selection = [] }
      changed(save: false)
      return
    }
    let group = project?.objects.first { $0.id == id }?.groupID
    let ids = Set(
      project?.objects.filter { group != nil ? $0.groupID == group : $0.id == id }.map(\.id) ?? [id]
    )
    if extending {
      if engine.selection.isSuperset(of: ids) {
        engine.selection.subtract(ids)
      } else {
        engine.selection.formUnion(ids)
      }
    } else {
      engine.selection = ids
    }
    changed(save: false)
  }
  func add(_ recipe: Recipe) {
    let width = max(
      recipe.defaults["width"] ?? 0, recipe.defaults["shadeDiameter"] ?? 0,
      recipe.defaults["diameter"] ?? 0, 150)
    let edge = project?.objects.filter { !$0.isCanvasWorkspace }.map { $0.position.x + $0.footprintWidth / 2 }.max()
    let x = edge.map { $0 + width / 2 + 70 } ?? 0
    perform(
      "form_add_object",
      [
        "recipe_id": recipe.id, "position": [x, 0, 0],
        "material_id": MerchandiseBlanks.defaultMaterial(recipe.id) ?? (ClothDesign.recipeIDs.contains(recipe.id) ? "linen" : recipe.id == "bomberJacket" ? "flight-nylon" : recipe.id == "textilePatch" ? "patch-twill" : recipe.id == "textileLabel" ? "label-ecru" : recipe.id == "lamp" ? "vermillion" : recipe.id == "vase" ? "clay" : "chalk"),
      ])
    if recipe.id == "artboard", let object = primary {
      saveArtwork(.init(background: "#F2EDE1"), for: object)
      mode = .artwork
    }
    synchronizeScene()
    scene?.focusSelection()
    toast("\(recipe.name) added")
  }
  func update(_ object: ProductObject, _ values: [String: Any]) {
    var args = values
    args["object_id"] = object.id.uuidString
    perform("form_update_object", args)
  }
  func duplicate(_ mode: String) {
    if self.mode == .artwork {
      if !artworkSession.selection.isEmpty { artworkSession.execute("duplicate") }
      return
    }
    guard let object = primary else { return }
    perform("form_duplicate_object", ["object_id": object.id.uuidString, "mode": mode])
    synchronizeScene()
    scene?.fitAll()
  }
  func deleteSelection() {
    if mode == .artwork {
      artworkSession.execute("delete")
      return
    }
    guard !selected.isEmpty else { return }
    perform("form_delete_objects", ["object_ids": selected.map { $0.id.uuidString }])
  }
  func undo() {
    if mode == .artwork, artworkSession.canvas?.undoText() == true {
      objectWillChange.send()
      return
    }
    engine.undo()
    cloth.historyChanged()
    changed()
    toast("Undone")
  }
  func redo() {
    if mode == .artwork, artworkSession.canvas?.redoText() == true {
      objectWillChange.send()
      return
    }
    engine.redo()
    cloth.historyChanged()
    changed()
    toast("Redone")
  }
  func group() {
    if mode == .artwork {
      artworkSession.execute("group")
      return
    }
    guard selected.count > 1 else { return }
    perform("form_group_objects", ["object_ids": selected.map { $0.id.uuidString }])
  }
  func isolate() {
    if isolated.isEmpty {
      isolated = engine.selection
      scene?.focusSelection()
    } else {
      isolated = []
      scene?.fitAll()
    }
    changed(save: false)
  }
  func applyView(_ view: String, _ args: [String: Any] = [:]) throws {
    if ["perspective", "overhead", "front", "fit", "focus", "isolate", "show_all"].contains(view) {
      synchronizeScene()
    }
    if let raw = args["object_id"] as? String {
      guard let id = UUID(uuidString: raw),
        project?.objects.contains(where: { $0.id == id }) == true
      else { throw FormError.missing("Object not found.") }
      select(id)
    }
    switch view {
    case "home": home()
    case "table":
      showSurface(.table)
    case "canvas":
      showSurface(.artwork)
    case "split":
      showSplit()
    case "canvas_window":
      detachCanvas()
    case "artwork":
      closeDetachedCanvas()
      surfaceLayout = .single
      showingHome = false
      mode = .artwork
      artworkSession.reconcile()
    case "studio":
      showSurface(.studio)
    case "focus": scene?.focusSelection()
    case "isolate":
      guard !engine.selection.isEmpty else {
        throw FormError.invalid("Select an object to isolate.")
      }
      isolated = engine.selection
      scene?.focusSelection()
    case "show_all":
      isolated = []
      scene?.fitAll()
    case "fit": scene?.fitAll()
    case "perspective", "overhead", "front": scene?.preset(view)
    case "print_bed":
      if printing.object == nil { printing.open() }
      showingPrint = true
      printing.frame("bed")
    case "print_object":
      if printing.object == nil { printing.open() }
      showingPrint = true
      printing.frame("object")
    default: throw FormError.invalid("Unknown view.")
    }
    if ["artwork", "canvas", "split", "canvas_window"].contains(view) {
      if let raw = args["object_id"] as? String, let id = UUID(uuidString:raw) {
        guard let object = project?.objects.first(where:{$0.id == id}), project?.editableArtwork(object) != nil
        else { throw FormError.invalid("The selected object has no editable artwork.") }
        artworkSession.activate(id)
      }
      if let raw = args["element_ids"] as? [String] {
        let ids = Set(raw.compactMap(UUID.init(uuidString:)))
        guard ids.count == raw.count, ids.isSubset(of:Set(artworkSession.art.elements.map(\.id)))
        else { throw FormError.invalid("Unknown artwork selection.") }
        artworkSession.choose(ids)
        let parents = Set(artworkSession.elements.map(\.parentID))
        artworkSession.scopeID = parents.count == 1 ? parents.first! : nil
      }
      if let raw = args["node_ids"] as? [String] {
        let ids = Set(raw.compactMap(UUID.init(uuidString:)))
        let available = Set(artworkSession.elements.flatMap { $0.path?.contours.flatMap(\.nodes).map(\.id) ?? [] })
        guard ids.count == raw.count, ids.isSubset(of:available)
        else { throw FormError.invalid("Unknown path node selection.") }
        artworkSession.nodes = ids
        if !ids.isEmpty { artworkSession.tool = .direct }
      }
    }
    changed(save: false)
  }
  func synchronizeScene() {
    guard let project else { return }
    if scene == nil { scene = TableSceneController(store: self) }
    scene?.sync(
      project, selection: engine.selection, isolated: isolated, showGrid: showGrid,
      studio: mode == .studio, preset: studioPreset,
      assets: repository.url(for: project.id).appendingPathComponent("Assets"))
  }
  func toast(_ text: String, symbol: String = "checkmark") {
    noticeWork?.cancel()
    notice = text
    let item = DispatchWorkItem { [weak self] in withAnimation { self?.notice = nil } }
    noticeWork = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: item)
  }
  func previewURL(_ id: UUID) -> URL {
    repository.url(for: id).appendingPathComponent("Preview.png")
  }
  func capturePreview() {
    guard let project else { return }
    do {
      let image = ProjectPreview.image(
        project: project, size: CGSize(width: 1000, height: 650),
        assets: repository.url(for: project.id).appendingPathComponent("Assets"))
      try image.pngData()?.write(to: previewURL(project.id), options: .atomic)
      previewVersion += 1
    } catch { self.error = "Could not save project preview: \(error.localizedDescription)" }
  }
  func generateMissingPreviews() {
    for (index, summary) in projects.enumerated()
    where !FileManager.default.fileExists(atPath: previewURL(summary.id).path) {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.3) { [weak self] in
        guard let self, let project = try? self.repository.load(summary.id) else { return }
        let image = ProjectPreview.image(
          project: project, size: CGSize(width: 1000, height: 650),
          assets: self.repository.url(for: project.id).appendingPathComponent("Assets"))
        try? image.pngData()?.write(to: self.previewURL(project.id), options: .atomic)
        self.previewVersion += 1
      }
    }
  }
  func importReference() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image, .pdf, .svg]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    if panel.runModal() == .OK {
      for url in panel.urls { perform("form_import_reference", ["path": url.path]) }
      scene?.fitAll()
    }
  }
  func openPackage() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { importPackage(url) }
  }
  func importPackage(_ url: URL) {
    do {
      var loaded = try repository.load(url: url)
      var target = repository.url(for: loaded.id)
      if target.standardizedFileURL != url.standardizedFileURL {
        if FileManager.default.fileExists(atPath: target.path) {
          loaded.id = UUID()
          loaded.name += " (imported)"
          target = repository.url(for: loaded.id)
        }
        try FileManager.default.copyItem(at: url, to: target)
        try repository.save(loaded)
      }
      openProject(loaded.id)
    } catch { self.error = error.localizedDescription }
  }
  func saveCopy() {
    guard let project else { return }
    save()
    let panel = NSSavePanel()
    panel.nameFieldStringValue = project.name + ".form"
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      do {
        guard !FileManager.default.fileExists(atPath: url.path) else {
          throw FormError.invalid("Choose a new filename for the project copy.")
        }
        try FileManager.default.copyItem(at: repository.url(for: project.id), to: url)
        toast("Project copy saved")
      } catch { self.error = error.localizedDescription }
    }
  }
  func saveArtwork(_ artwork: Artwork, for object: ProductObject) {
    do {
      try validateArtwork(artwork)
      edit("Edited artwork", coalescing: "artwork-\(object.id)") { p in
        try p.setArtwork(artwork, for: object.id)
      }
    } catch { self.error = error.localizedDescription }
  }
  func saveLibrary() {
    do {
      try library.save(to: repository.root)
      if project != nil {
        edit("Updated Studio Library") {
          let physicalMaterials = library.materials.filter { item in
            !FormCore.Material.presets.contains(item)
          }
          $0.materials = $0.mergingStudioMaterials(physicalMaterials)
        }
      }
      revision += 1
    } catch { self.error = error.localizedDescription }
  }
}

extension NSImage {
  func pngData() -> Data? {
    guard let tiffRepresentation, let rep = NSBitmapImageRep(data: tiffRepresentation) else {
      return nil
    }
    return rep.representation(using: .png, properties: [:])
  }
}

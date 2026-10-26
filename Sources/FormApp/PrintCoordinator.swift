import AppKit
import FormCore
import SwiftUI

@MainActor final class PrintCoordinator: ObservableObject {
  weak var store: StudioStore?
  @Published var objectID: UUID?
  @Published var configuration = PrintConfiguration()
  @Published var mesh: PrintMesh?
  @Published var meshVersion = 0
  @Published var toolpathVersion = 0
  @Published var toolpath: ToolpathPreview?
  @Published var layer = 0
  @Published var showToolpath = false
  @Published var status = "Ready to prepare"
  @Published var validationError: String?
  @Published var busy = false
  @Published var jobID: String?
  @Published var outputDirectory: URL?
  @Published var log = ""
  @Published var cameraRevision = 0
  var cameraRequest = "bed"
  func frame(_ target: String) {
    cameraRequest = target
    cameraRevision += 1
  }
  let monitor = BambuMonitor()
  private var process: Process?
  private var cancelled = false
  private(set) var preparedProjectID: UUID?
  private struct PreparationInput: Equatable {
    var projectID: UUID
    var objectID: UUID
    var recipeID: String
    var recipe: Recipe?
    var parameters: [String: Double]
    var asset: String?
    var configuration: PrintConfiguration
    var printer: PrinterProfile
    var filament: FilamentProfile
  }
  struct SliceRequest: Equatable {
    let id: String
    let projectID: UUID
    let objectID: UUID
  }
  private var preparedInput: PreparationInput?
  private var lastStoredConfiguration: PrintConfiguration?
  private(set) var activeRequest: SliceRequest?
  var canSlice: Bool {
    guard !busy, let mesh, object != nil, preparedProjectID == store?.project?.id,
      preparedInput == currentInput, engineURL != nil
    else { return false }
    do {
      try mesh.validate(on: printer)
      try configuration.validate(nozzle: printer.nozzleDiameter)
      try filament.validate(for: printer)
      return true
    } catch { return false }
  }
  init(store: StudioStore) { self.store = store }
  var object: ProductObject? { store?.project?.objects.first { $0.id == objectID } }
  var printer: PrinterProfile {
    store?.library.printers.first { $0.id == configuration.printerID } ?? store?.library.printers
      .first ?? .init()
  }
  var filament: FilamentProfile {
    store?.library.filaments.first { $0.id == configuration.filamentID } ?? store?.library.filaments
      .first ?? FilamentProfile.presets[0]
  }
  var engineURL: URL? {
    guard let store else { return nil }
    return OrcaEngine.appURL(configured: store.library.orcaAppPath, library: store.repository.root)
  }
  var components: [String] {
    if object?.recipeID=="deskClock" {return DeskClockDesign.components}
    if object?.recipeID == "clock" {
      return ["Dial", "Hour hand", "Minute hand", "Complete object"]
    }
    return object?.recipeID == "lamp"
      ? ["Shade", "Stem", "Base", "Complete object"] : ["Complete object"]
  }
  private var currentInput: PreparationInput? {
    guard let project = store?.project, let object else { return nil }
    return .init(
      projectID: project.id, objectID: object.id, recipeID: object.recipeID,
      recipe: project.recipe(object.recipeID), parameters: object.parameters, asset: object.asset,
      configuration: configuration, printer: printer, filament: filament)
  }
  private func invalidateSlice() {
    // Invalidate ownership before stopping the worker. A completion queued on
    // the main actor must never publish into the next project's workspace.
    activeRequest = nil
    jobID = nil
    let oldProcess = process
    process = nil
    busy = false
    cancelled = false
    if oldProcess?.isRunning == true { oldProcess?.terminate() }
  }
  private func clearPreview(status: String) {
    mesh = nil
    meshVersion += 1
    toolpath = nil
    toolpathVersion += 1
    showToolpath = false
    layer = 0
    outputDirectory = nil
    log = ""
    validationError = nil
    jobID = nil
    self.status = status
  }
  func resetForProjectChange() {
    invalidateSlice()
    preparedProjectID = nil
    preparedInput = nil
    lastStoredConfiguration = nil
    objectID = nil
    configuration = .init()
    clearPreview(status: "Ready to prepare")
    frame("bed")
  }
  func reconcile() {
    guard objectID != nil else { return }
    guard preparedProjectID == store?.project?.id else {
      resetForProjectChange()
      store?.showingPrint = false
      return
    }
    guard object != nil else {
      resetForProjectChange()
      status = "Choose an object to prepare"
      return
    }
    let stored = store?.project?.printSetups?[objectID!.uuidString]
    if stored != lastStoredConfiguration {
      invalidateSlice()
      configuration = configurationForObject()
      prepare()
    } else if preparedInput != currentInput {
      invalidateSlice()
      prepare()
    }
  }
  private func configurationForObject() -> PrintConfiguration {
    let saved = store?.project?.printSetups?[objectID?.uuidString ?? ""]
    var value = saved ?? .init()
    if value.printerID == nil { value.printerID = store?.library.printers.first?.id }
    if value.filamentID == nil { value.filamentID = store?.library.filaments.first?.id }
    if saved == nil {
      if object?.recipeID == "lamp" { value.component = "Shade" }
      if object?.recipeID == "clock" { value.component = "Dial" }
      if object?.recipeID == "deskClock" {value.component = "Case shell";value.rotation.x=90}
    }
    return value
  }
  func updateConfiguration(_ change: (inout PrintConfiguration) -> Void) {
    guard !busy else { return }
    let before = configuration
    change(&configuration)
    if configuration != before { prepare(persist: true) }
  }
  func open(objectID: UUID? = nil) {
    if busy {
      store?.showingPrint = true
      return
    }
    self.objectID =
      objectID ?? store?.primary?.id ?? store?.project?.objects.first {
        !["reference", "swatch", "paperStack", "booklet", "sleeve", "artboard"].contains(
          $0.recipeID)
      }?.id ?? store?.project?.objects.first?.id
    configuration = configurationForObject()
    prepare()
    store?.showingPrint = true
  }
  func prepare(persist: Bool = false) {
    guard !busy else { return }
    invalidateSlice()
    clearPreview(status: "Choose an object to prepare")
    guard let store, let project = store.project, let object else {
      preparedProjectID = nil
      preparedInput = nil
      validationError = "Select an object on the Table to prepare it for printing."
      return
    }
    preparedProjectID = project.id
    lastStoredConfiguration = project.printSetups?[object.id.uuidString]
    preparedInput = currentInput
    do {
      guard !object.isFlexibleSurface else {throw FormError.invalid(ClothStudy.unsupportedPrintReason)}
      try configuration.validate(nozzle: printer.nozzleDiameter)
      try filament.validate(for: printer)
      try printer.validate()
      let generated = try PrintMeshBuilder.mesh(
        object: object, project: project,
        assets: store.repository.url(for: project.id).appendingPathComponent("Assets"),
        configuration: configuration
      ).centered(on: printer)
      mesh = generated
      meshVersion += 1
      status = "Ready to slice locally"
      do {
        try generated.validate(on: printer)
        validationError = nil
      } catch { validationError = error.localizedDescription }
      if persist {
        lastStoredConfiguration = configuration
        store.edit("Updated print setup", coalescing: "print-\(object.id)") { p in
          if p.printSetups == nil { p.printSetups = [:] }
          p.printSetups?[object.id.uuidString] = configuration
        }
      }
    } catch {
      status = "Check print setup"
      validationError = error.localizedDescription
    }
  }
  func chooseObject(_ id: UUID) {
    guard !busy else { return }
    objectID = id
    configuration = configurationForObject()
    prepare()
  }
  func slice() throws {
    reconcile()
    guard !busy else { throw FormError.invalid("A slicing job is already running.") }
    guard let store, let project = store.project, let object, let mesh else {
      throw FormError.invalid("Choose a printable object first.")
    }
    try configuration.validate(nozzle: printer.nozzleDiameter)
    try filament.validate(for: printer)
    try mesh.validate(on: printer)
    guard let app = engineURL else {
      throw FormError.missing(
        "Choose the official OrcaSlicer app in Studio settings to enable local slicing.")
    }
    let id = UUID().uuidString
    let directory = store.repository.url(for: project.id).appendingPathComponent(
      "Exports/Print/\(id)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try mesh.binarySTL().write(to: directory.appendingPathComponent("model.stl"), options: .atomic)
    try JSONSerialization.data(
      withJSONObject: [
        "object_id": object.id.uuidString, "object": object.name,
        "component": configuration.component, "printer_model": printer.model,
        "filament": try jsonObject(filament), "configuration": try jsonObject(configuration),
        "print_jobs_sent": 0,
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: directory.appendingPathComponent("Preparation.json"), options: .atomic)
    let args = try OrcaEngine.prepare(
      app: app, directory: directory, printer: printer, filament: filament,
      configuration: configuration)
    let process = Process()
    let pipe = Pipe()
    process.executableURL = app.appendingPathComponent("Contents/MacOS/OrcaSlicer")
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = pipe
    process.currentDirectoryURL = app.appendingPathComponent("Contents/MacOS")
    let request = try beginSlice(process: process, directory: directory, id: id)
    do { try process.run() } catch {
      busy = false
      self.process = nil
      activeRequest = nil
      status = "Could not start OrcaSlicer"
      throw error
    }
    Task {
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          () -> (String, ToolpathPreview) in
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          let log = String(data: data, encoding: .utf8) ?? ""
          try data.write(to: directory.appendingPathComponent("Orca.log"), options: .atomic)
          guard process.terminationStatus == 0 else {
            throw FormError.invalid(
              "OrcaSlicer could not complete this slice (code \(process.terminationStatus)). Open the slice files and check Orca.log for details."
            )
          }
          let gcode = directory.appendingPathComponent("plate_1.gcode")
          guard
            FileManager.default.fileExists(
              atPath: directory.appendingPathComponent("prepared.3mf").path),
            let text = try? String(contentsOf: gcode, encoding: .utf8)
          else {
            throw FormError.invalid(
              "OrcaSlicer did not produce a complete plate. See the saved Orca.log for details.")
          }
          let preview = ToolpathPreview.parse(text)
          guard !preview.segments.isEmpty else {
            throw FormError.invalid("The sliced file has no extrusion paths.")
          }
          return (String(log.suffix(12000)), preview)
        }.value
        finishSlice(.success(result), request: request)
      } catch {
        finishSlice(.failure(error), request: request)
      }
    }
  }
  @discardableResult func beginSlice(
    process: Process, directory: URL, id: String = UUID().uuidString
  ) throws -> SliceRequest {
    guard !busy, let project = store?.project, let object, mesh != nil,
      preparedProjectID == project.id, preparedInput == currentInput
    else {
      throw FormError.invalid("Prepare the current object before slicing.")
    }
    let request = SliceRequest(id: id, projectID: project.id, objectID: object.id)
    self.process = process
    activeRequest = request
    toolpath = nil
    toolpathVersion += 1
    showToolpath = false
    layer = 0
    busy = true
    cancelled = false
    jobID = id
    status = "Slicing with OrcaSlicer…"
    validationError = nil
    log = ""
    outputDirectory = directory
    return request
  }
  func finishSlice(_ result: Result<(String, ToolpathPreview), Error>, request: SliceRequest) {
    guard activeRequest == request, store?.project?.id == request.projectID,
      objectID == request.objectID, preparedProjectID == request.projectID
    else { return }
    busy = false
    process = nil
    activeRequest = nil
    if cancelled {
      status = "Slicing cancelled"
      return
    }
    switch result {
    case .success(let result):
      log = result.0
      toolpath = result.1
      layer = max(0, result.1.layers.count - 1)
      showToolpath = true
      toolpathVersion += 1
      status = "Slice ready · saved locally"
      store?.toast("Slice prepared. Nothing sent to printer.")
    case .failure(let error):
      status = "Slicing failed"
      validationError = error.localizedDescription
    }
  }
  func cancel() {
    guard busy else { return }
    cancelled = true
    if process?.isRunning == true { process?.terminate() }
    status = "Cancelling…"
  }
  func exportSTL() {
    guard let mesh else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = (object?.name ?? "Object") + ".stl"
    if panel.runModal() == .OK, let url = panel.url {
      do {
        try mesh.binarySTL().write(to: url, options: .atomic)
        store?.toast("Millimeter STL exported")
      } catch { store?.error = error.localizedDescription }
    }
  }
  func revealFiles() { if let outputDirectory { NSWorkspace.shared.open(outputDirectory) } }
  func connectPrinter() {
    do {
      let ca = engineURL?.appendingPathComponent("Contents/Resources/cert/printer.cer")
      try monitor.connect(printer, caURL: ca)
    } catch { store?.error = error.localizedDescription }
  }
  func setupSummary() throws -> [String: Any] {
    [
      "project_id": store?.project?.id.uuidString as Any? ?? NSNull(),
      "prepared_project_id": preparedProjectID?.uuidString as Any? ?? NSNull(),
      "workspace_presented": store?.showingPrint ?? false,
      "object_id": objectID?.uuidString as Any? ?? NSNull(), "component": configuration.component,
      "configuration": try jsonObject(configuration), "printer": try jsonObject(printer),
      "filament": try jsonObject(filament),
      "mesh_size_mm": mesh.map { [$0.size.x, $0.size.y, $0.size.z] } as Any? ?? NSNull(),
      "validation_error": validationError as Any? ?? NSNull(), "engine_available": engineURL != nil,
      "engine_version": engineURL.map(OrcaEngine.version) as Any? ?? NSNull(), "status": status,
      "busy": busy, "job_id": jobID as Any? ?? NSNull(),
      "output_directory": outputDirectory?.path as Any? ?? NSNull(),
      "layers": toolpath?.layers.count ?? 0, "estimated_time": toolpath?.estimatedTime ?? "",
      "filament_grams": toolpath?.filamentGrams ?? "", "print_commands_enabled": false,
      "printer_status": monitor.summary,
    ]
  }
  func call(_ name: String, _ a: [String: Any]) throws -> Any {
    guard let store else { throw FormError.missing("LAB is closing.") }
    switch name {
    case "form_open_print":
      let id: UUID?
      if let value = a["object_id"] {
        guard let raw = value as? String, let parsed = UUID(uuidString: raw) else {
          throw FormError.invalid("Use a valid object_id UUID.")
        }
        id = parsed
      } else {
        id = nil
      }
      if let id, store.project?.objects.contains(where: { $0.id == id }) != true {
        throw FormError.missing("Object not found.")
      }
      if busy, let id, id != objectID {
        throw FormError.invalid(
          "Cancel or finish the active local slice before choosing another object.")
      }
      open(objectID: id)
      return try setupSummary()
    case "form_get_print_setup", "form_get_slice_status": return try setupSummary()
    case "form_set_print_options":
      guard !busy else {
        throw FormError.invalid("Cancel or finish the active slice before changing its settings.")
      }
      var value = try jsonObject(configuration) as! [String: Any]
      let allowed = Set([
        "layerHeight", "infillPercent", "wallLoops", "supports", "brimWidth", "scalePercent",
        "rotation", "component", "filamentID", "printerID",
      ])
      guard Set(a.keys).isSubset(of: allowed) else {
        throw FormError.invalid("Unknown print option.")
      }
      value.merge(a) { _, new in new }
      let changed = try JSONDecoder().decode(
        PrintConfiguration.self, from: JSONSerialization.data(withJSONObject: value))
      guard let targetPrinter = store.library.printers.first(where: { $0.id == changed.printerID }),
        let targetFilament = store.library.filaments.first(where: { $0.id == changed.filamentID })
      else {
        throw FormError.invalid("Choose a saved printer and filament from the Studio library.")
      }
      try changed.validate(nozzle: targetPrinter.nozzleDiameter)
      try targetFilament.validate(for: targetPrinter)
      configuration = changed
      prepare(persist: true)
      return try setupSummary()
    case "form_slice":
      try slice()
      return try setupSummary()
    case "form_cancel_slice":
      cancel()
      return try setupSummary()
    case "form_list_filaments": return try jsonObject(store.library.filaments)
    case "form_save_filament":
      guard let input = a["filament"] as? [String: Any] else {
        throw FormError.invalid("filament is required.")
      }
      var value = try jsonObject(FilamentProfile(name: "New filament")) as! [String: Any]
      value.merge(input) { _, new in new }
      let profile = try JSONDecoder().decode(
        FilamentProfile.self, from: JSONSerialization.data(withJSONObject: value))
      try profile.validate()
      if let i = store.library.filaments.firstIndex(where: { $0.id == profile.id }) {
        store.library.filaments[i] = profile
      } else {
        store.library.filaments.append(profile)
      }
      store.saveLibrary()
      return try jsonObject(profile)
    case "form_list_printers":
      return ["printers": try jsonObject(store.library.printers), "status": monitor.summary]
    case "form_connect_printer":
      try monitor.connect(
        printer, caURL: engineURL?.appendingPathComponent("Contents/Resources/cert/printer.cer"))
      return monitor.summary
    default: throw FormError.invalid("Unknown print operation.")
    }
  }
}

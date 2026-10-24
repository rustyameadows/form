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
  var canSlice: Bool {
    guard !busy, let mesh, engineURL != nil else { return false }
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
    object?.recipeID == "lamp" ? ["Shade", "Stem", "Base", "Complete object"] : ["Complete object"]
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
    configuration = store?.project?.printSetups?[self.objectID?.uuidString ?? ""] ?? .init()
    if configuration.printerID == nil {
      configuration.printerID = store?.library.printers.first?.id
    }
    if configuration.filamentID == nil {
      configuration.filamentID = store?.library.filaments.first?.id
    }
    if object?.recipeID == "lamp", configuration.component == "Complete object" {
      configuration.component = "Shade"
    }
    prepare()
    store?.showingPrint = true
  }
  func prepare(persist: Bool = false) {
    guard !busy else { return }
    guard let store, let project = store.project, let object else {
      mesh = nil
      validationError = "Select an object on the Table to prepare it for printing."
      return
    }
    do {
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
      showToolpath = false
      toolpath = nil
      outputDirectory = nil
      status = "Ready to slice locally"
      do {
        try generated.validate(on: printer)
        validationError = nil
      } catch { validationError = error.localizedDescription }
      if persist {
        store.edit("Updated print setup", coalescing: "print-\(object.id)") { p in
          if p.printSetups == nil { p.printSetups = [:] }
          p.printSetups?[object.id.uuidString] = configuration
        }
      }
    } catch {
      mesh = nil
      validationError = error.localizedDescription
    }
  }
  func chooseObject(_ id: UUID) {
    objectID = id
    configuration = store?.project?.printSetups?[id.uuidString] ?? .init()
    configuration.printerID = printer.id
    configuration.filamentID = filament.id
    if object?.recipeID == "lamp" { configuration.component = "Shade" }
    prepare()
  }
  func slice() throws {
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
    self.process = process
    busy = true
    cancelled = false
    jobID = id
    status = "Slicing with OrcaSlicer…"
    validationError = nil
    log = ""
    outputDirectory = directory
    do { try process.run() } catch {
      busy = false
      self.process = nil
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
        guard jobID == id else { return }
        busy = false
        self.process = nil
        if cancelled {
          status = "Slicing cancelled"
          return
        }
        log = result.0
        toolpath = result.1
        layer = max(0, result.1.layers.count - 1)
        showToolpath = true
        toolpathVersion += 1
        status = "Slice ready · saved locally"
        store.toast("Slice prepared. Nothing sent to printer.")
      } catch {
        guard jobID == id else { return }
        busy = false
        self.process = nil
        status = cancelled ? "Slicing cancelled" : "Slicing failed"
        if !cancelled { validationError = error.localizedDescription }
      }
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
    guard let store else { throw FormError.missing("FORM is closing.") }
    switch name {
    case "form_open_print":
      let id = (a["object_id"] as? String).flatMap(UUID.init(uuidString:))
      if let id, store.project?.objects.contains(where: { $0.id == id }) != true {
        throw FormError.missing("Object not found.")
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

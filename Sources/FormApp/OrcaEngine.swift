import FormCore
import Foundation

enum OrcaEngine {
  static func appURL(configured: String?, library: URL) -> URL? {
    let candidates: [String] = [
      configured, ProcessInfo.processInfo.environment["FORM_ORCA_APP_PATH"],
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OrcaSlicer.app").path,
      "/Applications/OrcaSlicer.app", library.appendingPathComponent("Engines/OrcaSlicer.app").path,
      Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".local/engines/OrcaSlicer.app").path,
    ].compactMap { $0 }
    return candidates.map { URL(fileURLWithPath: $0) }.first {
      FileManager.default.isExecutableFile(
        atPath: $0.appendingPathComponent("Contents/MacOS/OrcaSlicer").path)
    }
  }
  static func version(_ app: URL) -> String {
    (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?[
      "CFBundleShortVersionString"] as? String) ?? "OrcaSlicer"
  }
  static func resolvedProfile(root: URL, kind: String, name: String, visited: Set<String> = [])
    throws -> [String: Any]
  {
    guard !name.contains("/"), !visited.contains(name), visited.count < 20 else {
      throw FormError.invalid("Invalid or circular Orca preset inheritance.")
    }
    let file = root.appendingPathComponent(kind).appendingPathComponent(name + ".json")
    guard let data = try? Data(contentsOf: file),
      let child = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw FormError.missing(
        "Orca preset '\(name)' is unavailable in this engine. Choose the official OrcaSlicer 2.4.2 app or another compatible release."
      )
    }
    var result: [String: Any] = [:]
    if let parent = child["inherits"] as? String, !parent.isEmpty {
      var chain = visited
      chain.insert(name)
      result = try resolvedProfile(root: root, kind: kind, name: parent, visited: chain)
    }
    result.merge(child) { _, new in new }
    result.removeValue(forKey: "inherits")
    result["from"] = "system"
    result["instantiation"] = "true"
    return result
  }
  static func prepare(
    app: URL, directory: URL, printer: PrinterProfile, filament: FilamentProfile,
    configuration: PrintConfiguration
  ) throws -> [String] {
    let profiles = app.appendingPathComponent("Contents/Resources/profiles/BBL")
    let nozzle = String(format: "%.1f", printer.nozzleDiameter)
    var machine = try resolvedProfile(
      root: profiles, kind: "machine", name: "Bambu Lab P1S \(nozzle) nozzle")
    var process = try resolvedProfile(
      root: profiles, kind: "process",
      name: printer.nozzleDiameter == 0.2
        ? "0.10mm Standard @BBL X1C 0.2 nozzle"
        : (printer.nozzleDiameter == 0.6
          ? "0.30mm Standard @BBL X1C"
          : printer.nozzleDiameter == 0.8 ? "0.40mm Standard @BBL X1C" : "0.20mm Standard @BBL X1C")
          + (printer.nozzleDiameter == 0.4 ? "" : " \(nozzle) nozzle"))
    let filamentDirectory = profiles.appendingPathComponent("filament")
    let names = try FileManager.default.contentsOfDirectory(atPath: filamentDirectory.path).filter {
      $0.hasPrefix("Generic \(filament.polymer)") && $0.hasSuffix(".json")
    }
    let preferred =
      names.first { $0 == "Generic \(filament.polymer) @BBL X1C.json" } ?? names.first {
        $0.contains("P1S")
      } ?? names.first
    guard let preferred else {
      throw FormError.missing("No Orca material preset found for \(filament.polymer).")
    }
    var material = try resolvedProfile(
      root: profiles, kind: "filament", name: String(preferred.dropLast(5)))
    machine["printable_area"] = [
      "0x0", "\(printer.bedWidth)x0", "\(printer.bedWidth)x\(printer.bedDepth)",
      "0x\(printer.bedDepth)",
    ]
    machine["printable_height"] = String(printer.buildHeight)
    process["layer_height"] = String(configuration.layerHeight)
    process["initial_layer_print_height"] = String(configuration.layerHeight)
    process["sparse_infill_density"] = "\(configuration.infillPercent)%"
    process["wall_loops"] = String(configuration.wallLoops)
    process["enable_support"] = configuration.supports ? "1" : "0"
    process["brim_width"] = String(configuration.brimWidth)
    process["brim_type"] = configuration.brimWidth > 0 ? "outer_only" : "no_brim"
    process["curr_bed_type"] = printer.plate
    process["post_process"] = []
    material["nozzle_temperature"] = [String(Int(filament.nozzleTemperature))]
    material["nozzle_temperature_initial_layer"] = [String(Int(filament.nozzleTemperature))]
    material["textured_plate_temp"] = [String(Int(filament.bedTemperature))]
    material["textured_plate_temp_initial_layer"] = [String(Int(filament.bedTemperature))]
    material["hot_plate_temp"] = [String(Int(filament.bedTemperature))]
    material["hot_plate_temp_initial_layer"] = [String(Int(filament.bedTemperature))]
    material["filament_diameter"] = [String(filament.diameter)]
    material["filament_density"] = [String(filament.density)]
    material["filament_max_volumetric_speed"] = [String(filament.maxVolumetricSpeed)]
    material["filament_colour"] = [filament.color]
    material["filament_cost"] = [String(filament.costPerKg)]
    for (name, value) in [("machine", machine), ("process", process), ("filament", material)] {
      try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }
    return [
      "--slice", "0", "--arrange", "0", "--orient", "0", "--ensure-on-bed", "--load-settings",
      directory.appendingPathComponent("machine.json").path + ";"
        + directory.appendingPathComponent("process.json").path, "--load-filaments",
      directory.appendingPathComponent("filament.json").path, "--export-3mf",
      "prepared.3mf", "--outputdir", directory.path,
      "--datadir", directory.appendingPathComponent("OrcaData").path, "--mstpp", "180",
      directory.appendingPathComponent("model.stl").path,
    ]
  }
}

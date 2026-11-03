import CoreFoundation
import CryptoKit
import Foundation

/// The compiled contract, independent of any client's cached tool wrapper.
/// The helper and running app each report their own copy; neither can inspect
/// or silently refresh a host application's cached declarations.
public enum MCPCapabilities {
  public static let maximumSchemas = 8
  public static let maximumCatalogPage = 32
  public static let maximumResponseBytes = 1_048_576
  public static let recoverySchemaNames = ["form_publication", "form_export_publication"]
  private static let catalog = MCP.tools.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
  public static let schemaFingerprint = try! fingerprint(of: catalog)

  /// Sort dictionary keys and tool order; descriptions, annotations, required
  /// fields and nested schemas are all part of the advertised contract.
  public static func fingerprint(of tools: [[String: Any]]) throws -> String {
    let sorted = tools.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    let data = try JSONSerialization.data(withJSONObject: sorted, options: [.sortedKeys, .withoutEscapingSlashes])
    return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func entry(_ tool: [String: Any]) -> [String: Any] {
    let name = tool["name"] as? String ?? ""
    let schema = tool["inputSchema"] as? [String: Any] ?? [:]
    let properties = schema["properties"] as? [String: Any] ?? [:]
    let commands = (properties["command"] as? [String: Any])?["enum"] as? [String] ?? []
    return ["name": name, "fields": properties.keys.sorted(), "commands": commands,
      "required": schema["required"] as? [String] ?? [],
      "read_only": (tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool ?? false,
      "schema_fingerprint": (try? fingerprint(of: [tool])) ?? "unavailable",
      "schema_resource": "form://schema/" + name]
  }

  private static var header: [String: Any] {
    ["catalog_version": 1, "schema_fingerprint": schemaFingerprint,
      "tool_count": catalog.count, "runtime": MCPRuntimeIdentity.current,
      "discovery_tool": "form_capabilities", "catalog_resource": "form://capabilities",
      "schema_resource_template": "form://schema/{tool_name}",
      "limits": ["schemas_per_request": maximumSchemas, "catalog_page": maximumCatalogPage,
        "response_bytes": maximumResponseBytes],
      "client_wrapper_observation": "unavailable",
      "recovery_notice": "The running app reports its compiled contract. This does not refresh a client's cached wrapper. Use explicit supported fields only; never silently drop an unsupported field or reinterpret its meaning."]
  }

  /// Kept small enough for legacy no-argument status callers. Only publication
  /// recovery schemas are embedded; all other schemas have explicit resources.
  public static let status: [String: Any] = {
    var result = header
    let relevant = Set(recoverySchemaNames + ["form_story", "form_studio_scene", "form_get_context", "form_set_view"])
    result["tool_support"] = catalog.filter { relevant.contains($0["name"] as? String ?? "") }.map(entry)
    var schemas: [[String: Any]] = []
    var omitted: [String] = []
    for name in recoverySchemaNames {
      guard let tool = catalog.first(where: { $0["name"] as? String == name }) else { continue }
      let proposed = schemas + [tool]
      if let data = try? JSONSerialization.data(withJSONObject: proposed), data.count <= 131_072 {
        schemas = proposed
      } else { omitted.append(name) }
    }
    result["recovery_schemas"] = schemas
    result["recovery_schemas_complete"] = omitted.isEmpty
    result["omitted_recovery_schemas"] = omitted
    return result
  }()

  public static func call(_ arguments: [String: Any]) throws -> [String: Any] {
    let allowed: Set<String> = ["command", "tool_names", "offset", "limit", "expected_schema_fingerprint"]
    guard Set(arguments.keys).isSubset(of: allowed) else { throw FormError.invalid("Unknown capability discovery argument.") }
    let command: String
    if let value = arguments["command"] {
      guard let value = value as? String else { throw FormError.invalid("Use summary, list or schema.") }
      command = value
    } else { command = "summary" }
    guard ["summary", "list", "schema"].contains(command) else { throw FormError.invalid("Use summary, list or schema.") }
    var result = header
    if let value = arguments["expected_schema_fingerprint"] {
      guard let expected = value as? String, expected.utf8.count <= 128, !expected.isEmpty else {
        throw FormError.invalid("Provide an expected schema fingerprint of at most 128 bytes.")
      }
      result["expected_schema_fingerprint"] = expected
      result["schema_match"] = expected == schemaFingerprint
      if expected != schemaFingerprint {
        result["diagnostic"] = "schema_mismatch"
        result["message"] = "The supplied schema fingerprint differs from this running process. Inspect its returned schemas before editing; the host's wrapper has not been refreshed by this call."
      }
    } else { result["schema_match"] = NSNull() }
    switch command {
    case "summary":
      guard arguments["tool_names"] == nil, arguments["offset"] == nil, arguments["limit"] == nil else {
        throw FormError.invalid("Summary accepts only an optional expected_schema_fingerprint.")
      }
      result["tools"] = catalog.map(entry)
    case "list":
      guard arguments["tool_names"] == nil else { throw FormError.invalid("List uses offset/limit, not tool_names.") }
      let offset = try integer(arguments["offset"], default: 0, range: 0...catalog.count, name: "offset")
      let limit = try integer(arguments["limit"], default: 16, range: 1...maximumCatalogPage, name: "limit")
      let end = min(catalog.count, offset + limit)
      result["tools"] = catalog[offset..<end].map(entry)
      result["offset"] = offset; result["total"] = catalog.count
      result["next_offset"] = end < catalog.count ? end as Any : NSNull()
    default:
      guard arguments["offset"] == nil, arguments["limit"] == nil,
        let names = arguments["tool_names"] as? [String], !names.isEmpty,
        names.count <= maximumSchemas, Set(names).count == names.count,
        names.allSatisfy({ $0.utf8.count <= 128 }) else {
        throw FormError.invalid("Schema needs 1–8 distinct tool_names and no pagination arguments.")
      }
      let byName = Dictionary(uniqueKeysWithValues: catalog.map { ($0["name"] as! String, $0) })
      guard names.allSatisfy({ byName[$0] != nil }) else { throw FormError.invalid("Unknown tool name; inspect the capability catalog first.") }
      result["tools"] = names.map { byName[$0]! }
      result["schemas_complete"] = true
    }
    guard try JSONSerialization.data(withJSONObject: result).count <= maximumResponseBytes else {
      throw FormError.invalid("Discovery response exceeds 1 MiB. Request fewer individual tool schemas.")
    }
    return result
  }

  private static func integer(_ value: Any?, default fallback: Int, range: ClosedRange<Int>, name: String) throws -> Int {
    guard let value else { return fallback }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
      number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else {
      throw FormError.invalid("\(name) must be an integer in \(range.lowerBound)…\(range.upperBound).")
    }
    return number.intValue
  }
}

public enum MCPRuntimeIdentity {
  public static let current: [String: Any] = {
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    var result: [String: Any] = ["application": LabIdentity.name, "version": LabIdentity.version,
      "process_id": ProcessInfo.processInfo.processIdentifier, "process_instance_id": UUID().uuidString,
      "executable_path": executable.standardizedFileURL.path,
      "packaged_build": NSNull(), "build_metadata_source": "unavailable"]
    if let build = packagedBuild(executable: executable) {
      result["packaged_build"] = build; result["build_metadata_source"] = "bundle_resource"
    }
    return result
  }()

  static func packagedBuild(executable: URL) -> [String: Any]? {
    let macOS = executable.deletingLastPathComponent()
    guard macOS.lastPathComponent == "MacOS", macOS.deletingLastPathComponent().lastPathComponent == "Contents" else { return nil }
    let url = macOS.deletingLastPathComponent().appendingPathComponent("Resources/LABBuild.json")
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
      let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      value["format_version"] as? Int == 1 else { return nil }
    return value
  }
}

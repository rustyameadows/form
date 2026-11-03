import Foundation

/// Observes the helper/app boundary only. A client's generated wrapper is not
/// observable from this protocol and is never reported as refreshed or current.
public enum MCPConnectionDiagnostics {
  public static func report(applicationStatus: [String: Any]?,
                            helperFingerprint: String = MCPCapabilities.schemaFingerprint,
                            helperRuntime: [String: Any] = MCPRuntimeIdentity.current,
                            connectionError: String? = nil) -> [String: Any] {
    let app = applicationStatus?["capabilities"] as? [String: Any]
    let appFingerprint = app?["schema_fingerprint"] as? String
    let appRuntime = app?["runtime"] as? [String: Any]
    let helperBuild = (helperRuntime["packaged_build"] as? [String: Any])?["build_id"] as? String
    let appBuild = (appRuntime?["packaged_build"] as? [String: Any])?["build_id"] as? String
    let schemaMatch = appFingerprint.map { $0 == helperFingerprint }
    let buildMatch = helperBuild.flatMap { helper in appBuild.map { $0 == helper } }
    let state: String
    if applicationStatus == nil { state = "app_unavailable" }
    else if appFingerprint == nil { state = "app_metadata_unavailable" }
    else if schemaMatch == false { state = "app_helper_schema_mismatch" }
    else if buildMatch == false { state = "app_helper_build_mismatch" }
    else { state = "app_helper_schema_match" }
    var result: [String: Any] = ["state": state,
      "helper_schema_fingerprint": helperFingerprint,
      "app_schema_fingerprint": appFingerprint as Any? ?? NSNull(),
      "schema_match": schemaMatch as Any? ?? NSNull(),
      "packaged_build_match": buildMatch as Any? ?? NSNull(),
      "helper_runtime": helperRuntime, "app_runtime": appRuntime as Any? ?? NSNull(),
      "client_wrapper_status": "not_observable",
      "client_refresh_performed": false,
      "guidance": "tools/list describes this helper's compiled contract; form_capabilities and form://schema/{tool_name} query the running app. If they differ, relaunch the matching ordinary app/helper, then reconnect or inspect a fresh client. A matching fingerprint does not prove the client wrapper has refreshed."]
    if let connectionError { result["connection_error"] = String(connectionError.prefix(512)) }
    return result
  }
}

/// Used by both stdio and --call so process freshness diagnostics cannot diverge.
public final class MCPBridgeConnection {
  private let call: (String, [String: Any]) throws -> Any
  private var lastObservation: [String: Any]?
  public init(call: @escaping (String, [String: Any]) throws -> Any = {
    try LocalBridgeClient.call($0, arguments: $1)
  }) {
    self.call = call
    // Capture process metadata at connection startup, before a bundle could be
    // replaced on disk. The compiled schema hash is independent of that file.
    _ = MCPRuntimeIdentity.current
  }

  public func diagnostics() -> [String: Any] {
    if var lastObservation {
      lastObservation["app_observation"] = "previous_explicit_tool_call"
      return lastObservation
    }
    var result = MCPConnectionDiagnostics.report(applicationStatus: nil)
    result["state"] = "app_not_observed"
    result["app_observation"] = "none"
    // Discovery must work when the app is closed or its main thread is busy.
    // A fresh form_status supplies the actual app/helper comparison.
    return result
  }

  public func invoke(_ name: String, arguments: [String: Any]) throws -> Any {
    let value = try call(name, arguments)
    guard var result = value as? [String: Any], ["form_status", "form_capabilities"].contains(name) else { return value }
    let status = name == "form_status" ? result : ["capabilities": result]
    var observation = MCPConnectionDiagnostics.report(applicationStatus: status)
    observation["app_observation"] = "this_tool_call"
    observation["observed_at"] = ISO8601DateFormatter().string(from: Date())
    lastObservation = observation
    result["mcp_connection"] = observation
    return result
  }
}

import FormCore
import Foundation

let connection = MCPBridgeConnection()
if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--call" {
  do {
    let raw = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "{}"
    let arguments = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
    let result = try connection.invoke(CommandLine.arguments[2], arguments: arguments)
    let data = try JSONSerialization.data(
      withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    FileHandle.standardOutput.write(data)
    print()
  } catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
  }
} else if CommandLine.arguments.contains("--catalog") {
  let value: [String: Any] = ["catalog_version": 1, "schema_fingerprint": MCPCapabilities.schemaFingerprint, "tools": MCP.tools]
  let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  FileHandle.standardOutput.write(data); print()
} else if CommandLine.arguments.contains("--help") {
  print(
    "LAB MCP server \(LabIdentity.version)\n\nRun without arguments for MCP over stdio. Open LAB first.\nDirect invocation: lab-mcp --call form_status '{}'\nOffline compiled catalog: lab-mcp --catalog\nOptional environment: LAB_SOCKET_PATH (FORM_SOCKET_PATH remains supported)\n"
  )
} else {
  while let line = readLine() {
    guard line.utf8.count <= 8 * 1024 * 1024 else { continue }
    if let response = MCP.respond(
      to: Data(line.utf8), invoke: { try connection.invoke($0, arguments: $1) }, runtimeDiagnostics: { connection.diagnostics() }),
      let data = try? JSONSerialization.data(
        withJSONObject: response, options: [.sortedKeys, .fragmentsAllowed])
    {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data([10]))
    }
  }
}

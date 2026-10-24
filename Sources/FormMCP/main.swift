import FormCore
import Foundation

if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--call" {
  do {
    let raw = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "{}"
    let arguments = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
    let result = try LocalBridgeClient.call(CommandLine.arguments[2], arguments: arguments)
    let data = try JSONSerialization.data(
      withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    FileHandle.standardOutput.write(data)
    print()
  } catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
  }
} else if CommandLine.arguments.contains("--help") {
  print(
    "FORM MCP server 0.1\n\nRun without arguments for MCP over stdio. Open FORM first.\nDirect invocation: form-mcp --call form_status '{}'\nOptional environment: FORM_SOCKET_PATH\n"
  )
} else {
  while let line = readLine() {
    guard line.utf8.count <= 8 * 1024 * 1024 else { continue }
    if let response = MCP.respond(
      to: Data(line.utf8), invoke: { try LocalBridgeClient.call($0, arguments: $1) }),
      let data = try? JSONSerialization.data(
        withJSONObject: response, options: [.sortedKeys, .fragmentsAllowed])
    {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data([10]))
    }
  }
}

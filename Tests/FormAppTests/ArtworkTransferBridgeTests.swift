import AppKit
import Darwin
import Foundation
import XCTest
@testable import FormApp
@testable import FormCore

@MainActor final class ArtworkTransferBridgeTests:XCTestCase {
  func testRealStdioHelperAndAsyncPrivateBridgeFileWorkflow()async throws {
    _=NSApplication.shared
    let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root=source.appendingPathComponent(".local/validation/transfer48-ipc-"+UUID().uuidString),socket="/tmp/form-transfer48-"+UUID().uuidString+".sock"
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let prior=ProcessInfo.processInfo.environment["FORM_SOCKET_PATH"]
    setenv("FORM_SOCKET_PATH",socket,1)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    if let prior {setenv("FORM_SOCKET_PATH",prior,1)}else{unsetenv("FORM_SOCKET_PATH")}
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"));store.startBridge()
    defer{store.bridge.stop();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    XCTAssertTrue(store.bridgeReady)
    #if DEBUG
    let configuration="Debug"
    #else
    let configuration="Release"
    #endif
    let supplied=ProcessInfo.processInfo.environment["FORM_TRANSFER_MCP_BINARY"],defaultBinary=source.appendingPathComponent(".build/out/Products/"+configuration+"/form-mcp")
    let executable=URL(fileURLWithPath:supplied ?? defaultBinary.path)
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath:executable.path),"Build the real form-mcp executable before this bridge test.")
    let process=Process(),output=Pipe(),errors=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3");process.arguments=[source.appendingPathComponent("scripts/smoke_artwork_transfer.py").path]
    var environment=ProcessInfo.processInfo.environment;environment["FORM_SOCKET_PATH"]=socket;environment["FORM_TRANSFER_TEST_LIBRARY"]=root.path;environment["FORM_TRANSFER_MCP_BINARY"]=executable.path;process.environment=environment;process.currentDirectoryURL=source;process.standardOutput=output;process.standardError=errors
    try process.run()
    for _ in 0..<1800 {if !process.isRunning{break};try await Task.sleep(nanoseconds:50_000_000)}
    if process.isRunning {process.terminate();XCTFail("Portable file MCP smoke exceeded90seconds")}
    let stdout=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self),stderr=String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
    XCTAssertEqual(process.terminationStatus,0,stdout+"\n"+stderr)
    XCTAssertTrue(stdout.contains("passed"),stdout+stderr)
    print("TRANSFER48_REAL_BRIDGE",executable.path,stdout.trimmingCharacters(in:.whitespacesAndNewlines))
  }
}

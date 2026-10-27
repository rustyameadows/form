import Darwin
import Foundation

private let maximumMessageBytes = 8 * 1024 * 1024
private func address(_ path: String) throws -> sockaddr_un {
  var result = sockaddr_un()
  result.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8) + [0]
  guard bytes.count <= MemoryLayout.size(ofValue: result.sun_path) else {
    throw FormError.invalid("Local bridge socket path is too long.")
  }
  withUnsafeMutableBytes(of: &result.sun_path) { buffer in buffer.copyBytes(from: bytes) }
  result.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  return result
}
private func withAddress<T>(
  _ value: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
) -> T {
  withUnsafePointer(to: &value) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
}
private func readMessage(_ fd: Int32) throws -> Data {
  var result = Data()
  var buffer = [UInt8](repeating: 0, count: 16384)
  while result.count <= maximumMessageBytes {
    let count = Darwin.read(fd, &buffer, buffer.count)
    if count == 0 { break }
    if count < 0 {
      if errno == EINTR { continue }
      throw FormError.invalid("Local bridge read failed.")
    }
    result.append(contentsOf: buffer.prefix(count))
    if let end = result.firstIndex(of: 10) { return result.prefix(upTo: end) }
  }
  guard !result.isEmpty, result.count <= maximumMessageBytes else {
    throw FormError.invalid("Empty or oversized bridge message.")
  }
  return result
}
private func writeMessage(_ data: Data, to fd: Int32) throws {
  var frame = data
  frame.append(10)
  try frame.withUnsafeBytes { buffer in
    var offset = 0
    while offset < frame.count {
      let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), frame.count - offset)
      if count < 0 {
        if errno == EINTR { continue }
        throw FormError.invalid("Local bridge write failed.")
      }
      offset += count
    }
  }
}

public enum LocalBridgeClient {
  public static func call(
    _ name: String, arguments: [String: Any], socketPath: String = FormPaths.socket
  ) throws -> Any {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw FormError.invalid("Could not create local socket.") }
    defer { close(fd) }
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    // Scene video streams up to 600 real GPU frames before publishing. Keep the
    // bounded export connected beyond the ordinary interactive-operation limit.
    let sceneVideo = name == "form_export" && arguments["format"] as? String == "mp4" && arguments["scene_id"] as? String != nil
    var timeout = timeval(tv_sec: sceneVideo ? 600 : 30, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var addr = try address(socketPath)
    guard withAddress(&addr, { Darwin.connect(fd, $0, $1) }) == 0 else {
      throw FormError.missing("Open LAB first. The local bridge is not running at \(socketPath).")
    }
    let request: [String: Any] = ["name": name, "arguments": arguments]
    try writeMessage(JSONSerialization.data(withJSONObject: request), to: fd)
    let response = try JSONSerialization.jsonObject(with: readMessage(fd)) as? [String: Any] ?? [:]
    if let error = response["error"] as? String { throw FormError.invalid(error) }
    return response["result"] ?? [:]
  }
}

public final class LocalBridgeServer {
  private var fd: Int32 = -1
  private let path: String
  private let queue = DispatchQueue(label: "studio.form.bridge", qos: .userInitiated)
  public init(path: String = FormPaths.socket) { self.path = path }
  public func start(
    handler: @escaping (String, [String: Any], @escaping (Result<Any, Error>) -> Void) -> Void
  ) throws {
    guard fd < 0 else { return }
    // Refuse to replace a live app's bridge; remove only a stale socket owned by this user.
    var info = stat()
    if lstat(path, &info) == 0 {
      guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else {
        throw FormError.invalid("Bridge path is occupied by another file.")
      }
      if (try? LocalBridgeClient.call("form_status", arguments: [:], socketPath: path)) != nil {
        throw FormError.invalid("Another LAB window already owns the local bridge.")
      }
      unlink(path)
    }
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw FormError.invalid("Could not start local bridge.") }
    var addr = try address(path)
    guard withAddress(&addr, { Darwin.bind(listener, $0, $1) }) == 0 else {
      close(listener)
      throw FormError.invalid("Could not bind local bridge: \(String(cString:strerror(errno)))")
    }
    chmod(path, 0o600)
    guard listen(listener, 16) == 0 else {
      close(listener)
      unlink(path)
      throw FormError.invalid("Could not listen on local bridge.")
    }
    fd = listener
    queue.async {
      while true {
        let client = accept(listener, nil, nil)
        if client < 0 {
          if errno == EINTR { continue }
          return
        }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else {
          close(client)
          continue
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        do {
          let request =
            try JSONSerialization.jsonObject(with: readMessage(client)) as? [String: Any] ?? [:]
          guard let name = request["name"] as? String, MCP.toolNames.contains(name) else {
            throw FormError.invalid("Unknown bridge operation.")
          }
          let semaphore = DispatchSemaphore(value: 0)
          var response: [String: Any] = [:]
          handler(name, request["arguments"] as? [String: Any] ?? [:]) { result in
            switch result {
            case .success(let value): response = ["result": value]
            case .failure(let error): response = ["error": error.localizedDescription]
            }
            semaphore.signal()
          }
          semaphore.wait()
          try writeMessage(JSONSerialization.data(withJSONObject: response), to: client)
        } catch {
          if let data = try? JSONSerialization.data(withJSONObject: [
            "error": error.localizedDescription
          ]) {
            try? writeMessage(data, to: client)
          }
        }
        close(client)
      }
    }
  }
  public func stop() {
    if fd >= 0 {
      shutdown(fd, SHUT_RDWR)
      close(fd)
      unlink(path)
      fd = -1
    }
  }
  deinit { stop() }
}

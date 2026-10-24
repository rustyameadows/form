import CryptoKit
import FormCore
import Foundation
import Network
import Security

enum PrinterCredentials {
  static func save(_ code: String, printerID: UUID) throws {
    guard code.count == 8, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
      throw FormError.invalid("The printer's LAN access code must contain eight letters or digits.")
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "studio.form.printer",
      kSecAttrAccount as String: printerID.uuidString,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: Data(code.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
    ]
    let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if result == errSecItemNotFound {
      var item = query
      item.merge(attributes) { _, new in new }
      let status = SecItemAdd(item as CFDictionary, nil)
      guard status == errSecSuccess else {
        throw FormError.invalid("Could not save printer access code in Keychain (\(status)).")
      }
    } else if result != errSecSuccess {
      throw FormError.invalid("Could not update printer access code in Keychain (\(result)).")
    }
  }
  static func read(_ id: UUID) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "studio.form.printer", kSecAttrAccount as String: id.uuidString,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

@MainActor final class BambuMonitor: ObservableObject {
  @Published var status = "Not connected"
  @Published var report: [String: Any] = [:]
  @Published var pendingFingerprint: String?
  @Published var connected = false
  @Published var lastReport: Date?
  private var connection: NWConnection?
  private var buffer = Data()
  private var timer: Timer?
  private var profile: PrinterProfile?
  private var generation = UUID()
  func connect(_ printer: PrinterProfile, caURL: URL? = nil) throws {
    try printer.validate()
    guard !printer.host.isEmpty, !printer.serial.isEmpty else {
      throw FormError.invalid(
        "Enter this printer's local IP address and serial number in Studio settings.")
    }
    guard let code = PrinterCredentials.read(printer.id) else {
      throw FormError.missing(
        "Save the printer's LAN access code in Studio settings first. It stays in your Mac's Keychain."
      )
    }
    disconnect()
    profile = printer
    status = "Connecting to \(printer.host)…"
    pendingFingerprint = nil
    buffer = Data()
    report = [:]
    let token = UUID()
    generation = token
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, printer.serial)
    let fingerprint = printer.trustedCertificateSHA256?.lowercased()
    var anchor: SecCertificate?
    if let caURL, let raw = try? Data(contentsOf: caURL) {
      var data = raw
      if let pem = String(data: raw, encoding: .utf8), pem.contains("BEGIN CERTIFICATE") {
        data =
          Data(
            base64Encoded: pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }
              .joined()) ?? raw
      }
      anchor = SecCertificateCreateWithData(nil, data as CFData)
    }
    sec_protocol_options_set_verify_block(
      tls.securityProtocolOptions,
      { [weak self] _, trust, completion in
        let certificateTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        SecTrustSetPolicies(certificateTrust, SecPolicyCreateSSL(true, printer.serial as CFString))
        if let anchor {
          SecTrustSetAnchorCertificates(certificateTrust, [anchor] as CFArray)
          SecTrustSetAnchorCertificatesOnly(certificateTrust, true)
        }
        if SecTrustEvaluateWithError(certificateTrust, nil) {
          completion(true)
          return
        }
        guard let chain = SecTrustCopyCertificateChain(certificateTrust) as? [SecCertificate],
          let leaf = chain.first
        else {
          completion(false)
          return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map {
          String(format: "%02x", $0)
        }.joined()
        if fingerprint == digest {
          completion(true)
          return
        }
        DispatchQueue.main.async {
          guard self?.generation == token else { return }
          self?.pendingFingerprint = digest
          self?.status = "Printer certificate needs verification"
        }
        completion(false)
      }, DispatchQueue.global(qos: .userInitiated))
    let connection = NWConnection(
      host: NWEndpoint.Host(printer.host), port: 8883,
      using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
    self.connection = connection
    connection.stateUpdateHandler = { [weak self] state in
      DispatchQueue.main.async {
        guard let self, self.generation == token else { return }
        switch state {
        case .ready:
          self.status = "Authenticating locally…"
          self.send(
            MQTTReadOnly.connect(clientID: "form-" + UUID().uuidString.prefix(12), password: code))
          self.receive(token)
        case .failed(let error):
          self.connected = false
          if self.pendingFingerprint == nil {
            self.status = "Connection failed: \(error.localizedDescription)"
          }
          self.timer?.invalidate()
        case .waiting: self.status = "Waiting for the local network…"
        case .cancelled: self.connected = false
        default: break
        }
      }
    }
    connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
      guard let self, self.generation == token, !self.connected, self.pendingFingerprint == nil
      else { return }
      self.status =
        "Connection timed out. Check the IP, LAN access code, and printer network settings."
      self.connection?.cancel()
    }
  }
  private func send(_ data: Data) {
    connection?.send(content: data, completion: .contentProcessed { _ in })
  }
  private func receive(_ token: UUID) {
    connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, complete, error in
      DispatchQueue.main.async {
        guard let self, self.generation == token else { return }
        if let data {
          self.buffer.append(data)
          do {
            while let (header, payload) = try MQTTReadOnly.takeFrame(from: &self.buffer) {
              try self.handle(header, payload)
            }
          } catch {
            self.status = error.localizedDescription
            self.connection?.cancel()
            return
          }
        }
        if error != nil || complete {
          self.connected = false
          self.status = "Printer connection closed"
          self.timer?.invalidate()
        } else {
          self.receive(token)
        }
      }
    }
  }
  private func handle(_ header: UInt8, _ payload: Data) throws {
    let bytes = [UInt8](payload)
    switch header >> 4 {
    case 2:
      guard bytes.count >= 2, bytes[1] == 0, let profile else {
        throw FormError.invalid(
          "Printer rejected the LAN login. Check its access code and network mode.")
      }
      connected = true
      status = "Connected · status only"
      send(MQTTReadOnly.subscribe(serial: profile.serial))
      timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.send(Data([0xC0, 0])) }
      }
    case 3:
      guard bytes.count >= 2 else { return }
      let topicSize = Int(bytes[0]) * 256 + Int(bytes[1])
      var start = 2 + topicSize
      let qos = (header >> 1) & 3
      if qos > 0 {
        guard bytes.count >= start + 2 else { return }
        send(MQTTReadOnly.frame(0x40, Data(bytes[start..<start + 2])))
        start += 2
      }
      guard start <= bytes.count,
        let message = try? JSONSerialization.jsonObject(with: Data(bytes[start...]))
          as? [String: Any], let update = message["print"] as? [String: Any]
      else { return }
      report.merge(update) { _, new in new }
      lastReport = Date()
      status = "Connected · receiving live status"
    default: break
    }
  }
  func disconnect() {
    generation = UUID()
    timer?.invalidate()
    timer = nil
    connection?.cancel()
    connection = nil
    connected = false
    status = "Not connected"
  }
  var summary: [String: Any] {
    [
      "connected": connected, "status": status, "nozzle_c": report["nozzle_temper"] ?? NSNull(),
      "bed_c": report["bed_temper"] ?? NSNull(),
      "progress_percent": report["mc_percent"] ?? NSNull(),
      "print_state": report["gcode_state"] ?? NSNull(), "ams": report["ams"] ?? NSNull(),
      "last_report": lastReport?.ISO8601Format() as Any? ?? NSNull(),
      "print_commands_enabled": false,
    ]
  }
}

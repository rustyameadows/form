import AppKit
import CryptoKit
import FormCore

public struct InstalledOutputProfile: Identifiable {
  public var id: String { path }
  public let name: String
  public let path: String
  public let model: String
  public let sha256: String
  public var json: [String: Any] { ["name": name, "path": path, "model": model, "sha256": sha256] }
}

/// ColorSync-backed ICC spaces. Raw bytes are kept in the package, never inferred
/// from a display name or replaced with another profile when missing.
public struct ICCOutputProfile {
  public static let maximumBytes = 16_000_000
  public let data: Data
  public let space: CGColorSpace
  public let reference: ArtworkOutputProfile

  public init(data: Data, name: String) throws {
    guard data.count >= 132, data.count <= Self.maximumBytes,
      data[36..<40] == Data("acsp".utf8),
      let space = CGColorSpace(iccData: data as CFData), space.supportsOutput,
      (space.model == .rgb && space.numberOfComponents == 3)
        || (space.model == .cmyk && space.numberOfComponents == 4)
    else { throw FormError.invalid("Choose a valid RGB or CMYK ICC profile under 16 MB.") }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let description = NSColorSpace(iccProfileData: data)?.localizedName
    let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.data = data; self.space = space
    reference = .init(name: label.isEmpty ? description ?? "ICC output profile" : label,
      asset: "icc-" + digest + ".icc", sha256: digest, model: space.model == .cmyk ? "CMYK" : "RGB")
    try reference.validate()
  }
  public init(url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/") else { throw FormError.invalid("Choose a local ICC profile.") }
    let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= Self.maximumBytes else {
      throw FormError.invalid("Choose an ICC profile file under 16 MB.")
    }
    let data = try Data(contentsOf: url)
    let name = NSColorSpace(iccProfileData: data)?.localizedName ?? url.deletingPathExtension().lastPathComponent
    try self.init(data: data, name: name)
  }
  public init(reference: ArtworkOutputProfile, assets: URL) throws {
    try reference.validate()
    let url = assets.appendingPathComponent(reference.asset)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw FormError.missing("The saved ICC output profile is missing. Reimport \(reference.name) before PDF export.")
    }
    let loaded = try Self(url: url)
    guard loaded.reference.sha256 == reference.sha256, loaded.reference.model == reference.model else {
      throw FormError.invalid("The ICC output profile bytes do not match the saved profile. Reimport the intended profile.")
    }
    self.data = loaded.data; self.space = loaded.space; self.reference = reference
  }
  public func store(in assets: URL) throws {
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let url = assets.appendingPathComponent(reference.asset)
    if FileManager.default.fileExists(atPath: url.path) {
      guard try Data(contentsOf: url) == data else { throw FormError.invalid("An ICC asset with this digest has conflicting bytes.") }
    } else { try data.write(to: url, options: .atomic) }
  }
  public static func installed() -> [InstalledOutputProfile] {
    let roots = ["/System/Library/ColorSync/Profiles", "/Library/ColorSync/Profiles",
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/ColorSync/Profiles").path]
    var result: [InstalledOutputProfile] = []
    var seen = Set<String>()
    for root in roots {
      let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root),
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: .skipsHiddenFiles)) ?? []
      for url in urls.sorted(by: { $0.path < $1.path }).prefix(512)
        where ["icc", "icm"].contains(url.pathExtension.lowercased()) {
        guard let p = try? Self(url: url), seen.insert(p.reference.sha256).inserted else { continue }
        result.append(.init(name: p.reference.name, path: url.path, model: p.reference.model, sha256: p.reference.sha256))
      }
    }
    return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  public func convert(_ color: CGColor) throws -> CGColor {
    guard let converted = color.converted(to: space, intent: .relativeColorimetric, options: nil) else {
      throw FormError.invalid("ColorSync could not convert this color to \(reference.name).")
    }
    return converted
  }
}

import CryptoKit
import Foundation

public struct ProjectSummary: Codable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var subtitle: String
  public var updatedAt: Date
  public var objectCount: Int
  public var url: URL
}

private struct ObjectReference: Codable {
  var id: UUID
  var file: String
}
private struct Manifest: Codable {
  var project: Project
  var objects: [ObjectReference]
}

public final class ProjectRepository {
  public let root: URL
  public init(root: URL = FormPaths.library) throws {
    self.root = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  public func url(for id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString + ".form", isDirectory: true)
  }
  public func list() throws -> [ProjectSummary] {
    try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "form" }
      .compactMap { url in
        guard
          let manifest = try? JSONDecoder.form.decode(
            Manifest.self, from: Data(contentsOf: url.appendingPathComponent("Manifest.json")))
        else { return nil }
        return ProjectSummary(
          id: manifest.project.id, name: manifest.project.name, subtitle: manifest.project.subtitle,
          updatedAt: manifest.project.updatedAt, objectCount: manifest.objects.count, url: url)
      }.sorted { $0.updatedAt > $1.updatedAt }
  }
  public func load(_ id: UUID) throws -> Project { try load(url: url(for: id)) }
  public func load(url: URL) throws -> Project {
    let manifest = try JSONDecoder.form.decode(
      Manifest.self, from: Data(contentsOf: url.appendingPathComponent("Manifest.json")))
    guard manifest.project.schemaVersion == 1 else {
      throw FormError.invalid("This project uses a newer file format. Update FORM to open it.")
    }
    var project = manifest.project
    project.objects = try manifest.objects.map { ref in
      guard !ref.file.contains("/"), ref.file.hasSuffix(".json") else {
        throw FormError.invalid("Invalid object reference.")
      }
      let object = try JSONDecoder.form.decode(
        ProductObject.self,
        from: Data(
          contentsOf: url.appendingPathComponent("Objects").appendingPathComponent(ref.file)))
      guard object.id == ref.id else {
        throw FormError.invalid("Object identity mismatch in project package.")
      }
      return object
    }
    return project
  }
  public func save(_ project: Project) throws {
    let package = url(for: project.id)
    let objectFolder = package.appendingPathComponent("Objects", isDirectory: true)
    try FileManager.default.createDirectory(at: objectFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: package.appendingPathComponent("Assets"), withIntermediateDirectories: true)
    var references: [ObjectReference] = []
    for object in project.objects {
      let data = try JSONEncoder.form.encode(object)
      let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
      let filename = object.id.uuidString + "-" + hash + ".json"
      let target = objectFolder.appendingPathComponent(filename)
      if !FileManager.default.fileExists(atPath: target.path) {
        try data.write(to: target, options: .atomic)
      }
      references.append(.init(id: object.id, file: filename))
    }
    var metadata = project
    metadata.objects = []
    // Immutable object revisions are written first; publishing the manifest is one atomic operation.
    try JSONEncoder.form.encode(Manifest(project: metadata, objects: references)).write(
      to: package.appendingPathComponent("Manifest.json"), options: .atomic)
  }
  public func importAsset(_ source: URL, into id: UUID) throws -> String {
    guard
      ["png", "jpg", "jpeg", "tiff", "heic", "pdf", "svg"].contains(
        source.pathExtension.lowercased())
    else { throw FormError.invalid("Choose a PNG, JPEG, TIFF, HEIC, PDF, or SVG image.") }
    let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
    guard (attrs[.size] as? Int ?? 0) <= 50_000_000 else {
      throw FormError.invalid("Reference images must be under 50 MB.")
    }
    let name = UUID().uuidString + "." + source.pathExtension.lowercased()
    let assets = url(for: id).appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: assets.appendingPathComponent(name))
    return name
  }
  public func assetURL(_ name: String, in id: UUID) throws -> URL {
    guard !name.contains("/"), !name.contains("..") else {
      throw FormError.invalid("Invalid asset name.")
    }
    return url(for: id).appendingPathComponent("Assets").appendingPathComponent(name)
  }
  public func seedIfEmpty() throws {
    if try list().isEmpty {
      for project in [Samples.cyanotype(), Samples.lamps(), Samples.studies()] { try save(project) }
    }
  }
}

public struct StudioLibrary: Codable, Equatable {
  public var materials: [Material] = Material.presets
  public var filaments: [FilamentProfile] = FilamentProfile.presets
  public var printers: [PrinterProfile] = [.init()]
  public var orcaAppPath: String?
  public var equipment: [Equipment] = [
    .init("Studio printer · A3", width: 297, height: 420, format: "PDF"),
    .init("Desktop cutter", width: 305, height: 610, format: "SVG"),
  ]
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case materials, equipment, filaments, printers, orcaAppPath
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    materials = try values.decodeIfPresent([Material].self, forKey: .materials) ?? Material.presets
    equipment =
      try values.decodeIfPresent([Equipment].self, forKey: .equipment) ?? StudioLibrary().equipment
    filaments =
      try values.decodeIfPresent([FilamentProfile].self, forKey: .filaments)
      ?? FilamentProfile.presets
    printers = try values.decodeIfPresent([PrinterProfile].self, forKey: .printers) ?? [.init()]
    orcaAppPath = try values.decodeIfPresent(String.self, forKey: .orcaAppPath)
  }
  public static func load(from root: URL) -> StudioLibrary {
    (try? JSONDecoder.form.decode(
      Self.self, from: Data(contentsOf: root.appendingPathComponent("Studio.json")))) ?? .init()
  }
  public func save(to root: URL) throws {
    try JSONEncoder.form.encode(self).write(
      to: root.appendingPathComponent("Studio.json"), options: .atomic)
  }
}

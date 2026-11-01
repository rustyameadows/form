import CryptoKit
import Foundation

public struct ProjectSummary: Codable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var subtitle: String
  public var updatedAt: Date
  public var objectCount: Int
  public var url: URL
  public var canvasItemCount: Int?
}

private struct ObjectReference: Codable {
  var id: UUID
  var file: String
  var canvasWorkspace: Bool?
  var canvasSourceOnly: Bool?
  var canvasItemCount: Int?
}
private struct Manifest: Codable {
  var project: Project
  var objects: [ObjectReference]
}

public final class ProjectRepository {
  public let root: URL
  private struct SavedObject {
    let object:ProductObject,reference:ObjectReference
  }
  private struct SavedSnapshot {
    let projectID:UUID,objects:[UUID:SavedObject]
    let encoded:Int,reused:Int
  }
  private let saveCacheLock=NSLock()
  // One successfully published project only. Exact values retain their shared
  // array storage; no second serialized copy of dense artwork is held in RAM.
  private var savedSnapshot:SavedSnapshot?
  var lastSaveEncodedObjectCount:Int {
    saveCacheLock.lock();defer{saveCacheLock.unlock()};return savedSnapshot?.encoded ?? 0
  }
  var lastSaveReusedObjectCount:Int {
    saveCacheLock.lock();defer{saveCacheLock.unlock()};return savedSnapshot?.reused ?? 0
  }
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
        var physicalCount = 0,canvasCount = 0
        for ref in manifest.objects {
          if ref.canvasSourceOnly == true {continue}
          if let workspace = ref.canvasWorkspace {
            if workspace { canvasCount += max(0,ref.canvasItemCount ?? 0) }
            else { physicalCount += 1 }
          } else if manifest.project.schemaVersion >= 19,
            !ref.file.contains("/"),ref.file.hasSuffix(".json"),
            let data = try? Data(contentsOf:url.appendingPathComponent("Objects").appendingPathComponent(ref.file)),
            let object = try? JSONDecoder.form.decode(ProductObject.self,from:data),object.id == ref.id,
            object.isCanvasWorkspace {
            // Early schema-19 packages predate summary metadata. New saves keep
            // these counts in the manifest, avoiding object reads on Home.
            canvasCount += ProjectContent.looseItems(in:object.artwork)
          } else { physicalCount += 1 }
        }
        return ProjectSummary(
          id: manifest.project.id, name: manifest.project.name, subtitle: manifest.project.subtitle,
          updatedAt: manifest.project.updatedAt, objectCount:physicalCount, url:url,canvasItemCount:canvasCount)
      }.sorted { $0.updatedAt > $1.updatedAt }
  }
  public func load(_ id: UUID) throws -> Project { try load(url: url(for: id)) }
  public func load(url: URL) throws -> Project {
    let manifest = try JSONDecoder.form.decode(
      Manifest.self, from: Data(contentsOf: url.appendingPathComponent("Manifest.json")))
    guard (1...Project.maximumSchemaVersion).contains(manifest.project.schemaVersion) else {
      throw FormError.invalid("This project uses a newer file format. Update LAB to open it.")
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
    try project.validateArtworkLinks()
    return project
  }
  public func save(_ project: Project) throws {
    try project.validateArtworkLinks()
    saveCacheLock.lock()
    let previous=savedSnapshot?.projectID==project.id ? savedSnapshot?.objects ?? [:]:[:]
    saveCacheLock.unlock()
    let package = url(for: project.id)
    let objectFolder = package.appendingPathComponent("Objects", isDirectory: true)
    try FileManager.default.createDirectory(at: objectFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: package.appendingPathComponent("Assets"), withIntermediateDirectories: true)
    var references: [ObjectReference] = []
    var saved:[UUID:SavedObject]=[:],encoded=0,reused=0
    func regularFileExists(_ url:URL)->Bool {
      guard let attributes=try? FileManager.default.attributesOfItem(atPath:url.path) else{return false}
      return attributes[.type] as? FileAttributeType == .typeRegular
    }
    for object in project.objects {
      if let cached=previous[object.id],cached.object==object,
        regularFileExists(objectFolder.appendingPathComponent(cached.reference.file)) {
        references.append(cached.reference);saved[object.id]=cached;reused+=1;continue
      }
      let data = try JSONEncoder.form.encode(object)
      encoded+=1
      let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
      let filename = object.id.uuidString + "-" + hash + ".json"
      let target = objectFolder.appendingPathComponent(filename)
      if !regularFileExists(target) {
        try data.write(to: target, options: .atomic)
      }
      let reference=ObjectReference(id:object.id,file:filename,canvasWorkspace:object.isCanvasWorkspace,
        canvasSourceOnly:object.canvasSourceOnly,
        canvasItemCount:object.isCanvasWorkspace ? ProjectContent.looseItems(in:object.artwork) : nil)
      references.append(reference);saved[object.id] = .init(object:object,reference:reference)
    }
    var metadata = project
    metadata.schemaVersion = project.minimumSchemaVersion
    metadata.objects = []
    // Immutable object revisions are written first; publishing the manifest is one atomic operation.
    try JSONEncoder.form.encode(Manifest(project: metadata, objects: references)).write(
      to: package.appendingPathComponent("Manifest.json"), options: .atomic)
    // Failed object writes or manifest publication must not advance this cache.
    saveCacheLock.lock()
    savedSnapshot = .init(projectID:project.id,objects:saved,encoded:encoded,reused:reused)
    saveCacheLock.unlock()
  }
  public func importAsset(_ source: URL, into id: UUID) throws -> String {
    guard
      ["png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "gif", "bmp", "webp", "pdf", "svg"].contains(
        source.pathExtension.lowercased())
    else { throw FormError.invalid("Choose a PNG, JPEG, TIFF, HEIC, GIF, BMP, WebP, PDF, or SVG image.") }
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
  public var textileProduction:TextileProductionLibrary?
  public var equipment: [Equipment] = [
    .init("Studio printer · A3", width: 297, height: 420, format: "PDF"),
    .init("Desktop cutter", width: 305, height: 610, format: "SVG"),
  ]
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case materials, equipment, filaments, printers, orcaAppPath, textileProduction
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    materials = try values.decodeIfPresent([Material].self, forKey: .materials) ?? Material.presets
    for material in materials {try material.paperStock?.validate()}
    for material in TextileDesign.materials where !materials.contains(where: { $0.id == material.id }) {
      materials.append(material)
    }
    if !materials.contains(where:{$0.id=="paper-superfine"}),let paper=Material.presets.first(where:{$0.id=="paper-superfine"}){materials.append(paper)}
    equipment =
      try values.decodeIfPresent([Equipment].self, forKey: .equipment) ?? StudioLibrary().equipment
    filaments =
      try values.decodeIfPresent([FilamentProfile].self, forKey: .filaments)
      ?? FilamentProfile.presets
    printers = try values.decodeIfPresent([PrinterProfile].self, forKey: .printers) ?? [.init()]
    orcaAppPath = try values.decodeIfPresent(String.self, forKey: .orcaAppPath)
    textileProduction=try values.decodeIfPresent(TextileProductionLibrary.self,forKey:.textileProduction)
  }
  public static func load(from root: URL) -> StudioLibrary {
    (try? JSONDecoder.form.decode(
      Self.self, from: Data(contentsOf: root.appendingPathComponent("Studio.json")))) ?? .init()
  }
  public func save(to root: URL) throws {
    try textileProduction?.validate()
    for material in materials {try material.paperStock?.validate()}
    guard materials.allSatisfy({ $0.fabric?.pattern == nil }) else {
      throw FormError.invalid("Fabric patterns reference project artwork. Save repeat designs in the project rather than the shared Studio Library.")
    }
    try JSONEncoder.form.encode(self).write(
      to: root.appendingPathComponent("Studio.json"), options: .atomic)
  }
}

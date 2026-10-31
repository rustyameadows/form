import AppKit
import FormCore
import FormGraphics
import SwiftUI

@MainActor final class FontLibraryPreferences: ObservableObject {
  static let maximumEncodedBytes = 2_000_000
  private struct Value: Codable {
    var favorites: [String] = []
    var recent: [String] = []
    var legacyFamilies: [String] = []
    var malformedFields: [String] = []
    init(favorites: [String] = [], recent: [String] = [], legacyFamilies: [String] = []) {
      self.favorites = favorites; self.recent = recent; self.legacyFamilies = legacyFamilies
    }
    enum CodingKeys: String, CodingKey { case favorites, recent, legacyFamilies }
    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      // Missing keys are normal for older files. Present malformed fields make
      // the file read-only while still recovering its independent valid fields.
      var malformed: [String] = []
      func names(_ key: CodingKeys) -> [String] {
        guard values.contains(key) else { return [] }
        do { return try values.decode([String].self, forKey: key) }
        catch { malformed.append(key.rawValue); return [] }
      }
      favorites = names(.favorites); recent = names(.recent); legacyFamilies = names(.legacyFamilies)
      malformedFields = malformed
    }
  }
  @Published private(set) var favorites: [String] = []
  @Published private(set) var recent: [String] = []
  @Published private(set) var legacyFamilies: [String] = []
  @Published private(set) var error: String?
  private let defaults: UserDefaults?
  private let file: URL?
  /// A load failure must never turn the next routine Recents update into a
  /// destructive replacement of a file whose contents we could not recover.
  private var loadFailure: String?

  init(defaults: UserDefaults? = nil, file: URL? = nil) {
    self.defaults = defaults; self.file = file
    var loaded: Value?
    if let file, FileManager.default.fileExists(atPath: file.path) {
      do {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumEncodedBytes else { throw FormError.invalid("Font preferences exceed their size limit.") }
        let data = try Data(contentsOf: file)
        guard data.count <= Self.maximumEncodedBytes else { throw FormError.invalid("Font preferences exceed their size limit.") }
        loaded = try JSONDecoder().decode(Value.self, from: data)
        if let fields = loaded?.malformedFields, !fields.isEmpty {
          let message = "Could not read font preference fields: " + fields.joined(separator: ", ")
            + ". The original file is preserved; repair or restore it before saving preferences."
          loadFailure = message; self.error = message
        }
      } catch {
        let message = "Could not read font preferences: " + error.localizedDescription
          + " The original file is preserved; repair or restore it before saving preferences."
        loadFailure = message; self.error = message
      }
    }
    if loaded == nil, let defaults {
      var value = Value(favorites: defaults.stringArray(forKey: "FORM.favoriteFontFaces") ?? [],
        recent: defaults.stringArray(forKey: "FORM.recentFontFaces") ?? [],
        legacyFamilies: defaults.stringArray(forKey: "FORM.favoriteFontFamilies") ?? [])
      if value.recent.isEmpty {
        value.recent = (defaults.stringArray(forKey: "FORM.recentFontFamilies") ?? [])
          .compactMap { FontCatalog.faces($0).first?.name }
      }
      loaded = value
    }
    let value = Self.normalized(loaded ?? .init())
    favorites = value.favorites; recent = value.recent; legacyFamilies = value.legacyFamilies
  }
  static func environment() -> FontLibraryPreferences {
    if let path = LabIdentity.libraryOverride() {
      return .init(file: URL(fileURLWithPath: path).appendingPathComponent("FontPreferences.json"))
    }
    return .init(defaults: .standard)
  }
  func favorite(_ face: InstalledFontFace) -> Bool {
    Self.containsFace(favorites, name: face.name) || legacyFamilies.contains(face.family)
  }
  func favorite(_ name: String) -> Bool {
    guard ProjectFontLibrary.validFaceName(name) else { return false }
    if Self.containsFace(favorites, name: name) { return true }
    guard !legacyFamilies.isEmpty, let face = FontLibraryCatalog.face(named: name) else { return false }
    return legacyFamilies.contains(face.family)
  }
  func toggle(_ face: InstalledFontFace) { toggle(name: face.name, family: face.family) }
  func toggle(_ name: String) {
    guard ProjectFontLibrary.validFaceName(name) else { error = "Choose a valid exact font face name."; return }
    toggle(name: name, family: FontLibraryCatalog.face(named: name)?.family)
  }
  private func toggle(name: String, family: String?) {
    guard ProjectFontLibrary.validFaceName(name) else { error = "Choose a valid exact font face name."; return }
    let name = FontLibraryCatalog.canonicalName(name)
    var value = Value(favorites: favorites, recent: recent, legacyFamilies: legacyFamilies)
    if let family, value.legacyFamilies.contains(family) {
      value.legacyFamilies.removeAll { $0 == family }
      value.favorites.removeAll { FontLibraryCatalog.canonicalName($0) == name }
      for sibling in FontLibraryCatalog.faces where sibling.family == family && sibling.name != name && !Self.containsFace(value.favorites, name: sibling.name) {
        value.favorites.append(sibling.name)
      }
    } else if Self.containsFace(value.favorites, name: name) { value.favorites.removeAll { FontLibraryCatalog.canonicalName($0) == name } }
    else { value.favorites.append(name) }
    guard value.favorites.count <= ProjectFontLibrary.maximumFaces else {
      error = "The Studio font collection is full. Remove a saved face before adding another."; return
    }
    save(value)
  }
  func used(_ name: String) {
    guard ProjectFontLibrary.validFaceName(name) else { return }
    let name = FontLibraryCatalog.canonicalName(name)
    var value = Value(favorites: favorites, recent: recent, legacyFamilies: legacyFamilies)
    value.recent.removeAll { FontLibraryCatalog.canonicalName($0) == name }; value.recent.insert(name, at: 0)
    value.recent = Array(value.recent.prefix(12)); save(value)
  }
  private static func containsFace(_ names: [String], name: String) -> Bool {
    let canonical = FontLibraryCatalog.canonicalName(name)
    return names.contains { FontLibraryCatalog.canonicalName($0) == canonical }
  }
  private static func normalized(_ value: Value) -> Value {
    func unique(_ values: [String], limit: Int) -> [String] {
      var seen = Set<String>(), result: [String] = []
      for value in values where ProjectFontLibrary.validFaceName(value) {
        if seen.insert(value).inserted { result.append(value) }
        if result.count == limit { break }
      }
      return result
    }
    return .init(favorites: unique(value.favorites, limit: ProjectFontLibrary.maximumFaces),
      recent: unique(value.recent, limit: 12), legacyFamilies: unique(value.legacyFamilies, limit: 256))
  }
  private func save(_ candidate: Value) {
    guard loadFailure == nil else { error = loadFailure; return }
    let value = Self.normalized(candidate)
    do {
      let data = try JSONEncoder().encode(value)
      guard data.count <= Self.maximumEncodedBytes else { throw FormError.invalid("Font preferences exceed their size limit.") }
      if let file {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
      }
      if let defaults {
        defaults.set(value.favorites, forKey: "FORM.favoriteFontFaces")
        defaults.set(value.recent, forKey: "FORM.recentFontFaces")
        defaults.set(value.legacyFamilies, forKey: "FORM.favoriteFontFamilies")
      }
      favorites = value.favorites; recent = value.recent; legacyFamilies = value.legacyFamilies; error = nil
    } catch { self.error = "Could not save font preferences: " + error.localizedDescription }
  }
}

import AppKit
import FormGraphics
import SwiftUI

@MainActor final class FontLibraryPreferences:ObservableObject {
  private struct Value:Codable {var favorites:[String]=[];var recent:[String]=[];var legacyFamilies:[String]=[]}
  @Published private(set) var favorites:[String]=[]
  @Published private(set) var recent:[String]=[]
  @Published private(set) var legacyFamilies:[String]=[]
  @Published private(set) var error:String?
  private let defaults:UserDefaults?
  private let file:URL?
  init(defaults:UserDefaults?=nil,file:URL?=nil) {
    self.defaults=defaults;self.file=file
    if let file,let data=try? Data(contentsOf:file),let value=try? JSONDecoder().decode(Value.self,from:data) {
      favorites=Array(value.favorites.prefix(1024));recent=Array(value.recent.prefix(12));legacyFamilies=value.legacyFamilies
    } else if let defaults {
      favorites=defaults.stringArray(forKey:"FORM.favoriteFontFaces") ?? []
      recent=defaults.stringArray(forKey:"FORM.recentFontFaces") ?? []
      legacyFamilies=defaults.stringArray(forKey:"FORM.favoriteFontFamilies") ?? []
      if recent.isEmpty {
        recent=(defaults.stringArray(forKey:"FORM.recentFontFamilies") ?? []).compactMap{family in FontCatalog.faces(family).first?.name}
      }
    }
    func unique(_ values:[String],limit:Int)->[String] {var seen=Set<String>();return Array(values.filter{!$0.isEmpty && $0.count<=300 && seen.insert($0).inserted}.prefix(limit))}
    favorites=unique(favorites,limit:1024);recent=unique(recent,limit:12);legacyFamilies=unique(legacyFamilies,limit:256)
  }
  static func environment()->FontLibraryPreferences {
    if let path=ProcessInfo.processInfo.environment["FORM_LIBRARY_PATH"],!path.isEmpty {
      return .init(file:URL(fileURLWithPath:path).appendingPathComponent("FontPreferences.json"))
    }
    return .init(defaults:.standard)
  }
  func favorite(_ face:InstalledFontFace)->Bool {favorites.contains(face.name) || legacyFamilies.contains(face.family)}
  func toggle(_ face:InstalledFontFace) {
    if legacyFamilies.contains(face.family) {
      legacyFamilies.removeAll{$0==face.family};favorites.removeAll{$0==face.name}
      for sibling in FontLibraryCatalog.faces where sibling.family==face.family && sibling.name != face.name && !favorites.contains(sibling.name) {favorites.append(sibling.name)}
    } else if favorites.contains(face.name) {favorites.removeAll{$0==face.name}}
    else {favorites.append(face.name)}
    save()
  }
  func used(_ name:String) {recent.removeAll{$0==name};recent.insert(name,at:0);recent=Array(recent.prefix(12));save()}
  private func save() {
    error=nil
    if let defaults {
      defaults.set(favorites,forKey:"FORM.favoriteFontFaces");defaults.set(recent,forKey:"FORM.recentFontFaces")
      defaults.set(legacyFamilies,forKey:"FORM.favoriteFontFamilies")
    }
    if let file {
      do {try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(Value(favorites:favorites,recent:recent,legacyFamilies:legacyFamilies)).write(to:file,options:.atomic)
      } catch {self.error="Could not save font preferences: "+error.localizedDescription}
    }
  }
}

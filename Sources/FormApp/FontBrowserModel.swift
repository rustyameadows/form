import Foundation
import FormGraphics

enum FontBrowserScope:String,CaseIterable,Identifiable,Sendable {
  case all,project,studio,recent
  var id:String {rawValue}
  var title:String {switch self {case .all:return "All fonts";case .project:return "Project";case .studio:return "Saved in Studio";case .recent:return "Recent"}}
}

enum FontBrowserCategory:String,CaseIterable,Identifiable,Sendable {
  case all,serif,sans,mono,script,variable
  var id:String {rawValue}
  var title:String {switch self {case .all:return "All";case .serif:return "Serif";case .sans:return "Sans";case .mono:return "Mono";case .script:return "Script";case .variable:return "Variable"}}
  func includes(_ face:InstalledFontFace)->Bool {
    switch self {
    case .all:return true
    case .serif:return face.traits.classification == .serif
    case .sans:return face.traits.classification == .sans
    case .mono:return face.traits.isMonospaced
    case .script:return face.traits.classification == .script
    case .variable:return face.traits.isVariable
    }
  }
}

struct FontBrowserRow:Equatable,Identifiable,Sendable {
  var id:String {family.name}
  let family:InstalledFontFamily
  let face:InstalledFontFace
}

struct FontBrowserSection:Equatable,Identifiable,Sendable {
  enum Kind:String,Sendable {case projectSaved,projectUsed,studioSaved,recent,installed}
  let kind:Kind
  var id:String {kind.rawValue}
  var title:String {
    switch kind {
    case .projectSaved:return "Saved in this project"
    case .projectUsed:return "Used in this project"
    case .studioSaved:return "Saved in Studio"
    case .recent:return "Recently used"
    case .installed:return "Installed on this Mac"
    }
  }
  let rows:[FontBrowserRow]
}

/// A read-only snapshot. Browsing does not save faces, update recent history or
/// change text; callers pass exact face identities from their own source scopes.
struct FontBrowserModel:Sendable {
  let families:[InstalledFontFamily]
  private let byName:[String:InstalledFontFace]
  private let aliases:[String:String]
  private let projectSaved:[String],projectUsed:[String],studioSaved:[String],recent:[String]
  init(faces:[InstalledFontFace],projectSaved:[String]=[],projectUsed:[String]=[],studioSaved:[String]=[],recent:[String]=[],legacyStudioFamilies:[String]=[],aliases:[String:String]=[:]) {
    families=InstalledFontFamily.grouping(faces)
    let indexed=Dictionary(families.flatMap(\.faces).map{($0.name,$0)},uniquingKeysWith:{first,_ in first})
    byName=indexed
    let resolvedAliases=aliases.filter{indexed[$0.key]==nil && indexed[$0.value] != nil}
    self.aliases=resolvedAliases
    func resolved(_ names:[String])->[String] {Self.unique(names.map{resolvedAliases[$0] ?? $0})}
    self.projectSaved=resolved(projectSaved);self.projectUsed=resolved(projectUsed);self.recent=resolved(recent)
    let legacy=Set(legacyStudioFamilies)
    self.studioSaved=resolved(studioSaved+families.filter{legacy.contains($0.name)}.flatMap{family in
      family.representative().map{[$0.name]} ?? []
    })
  }
  private static func unique(_ values:[String])->[String] {
    var seen=Set<String>();return values.filter{!$0.isEmpty && seen.insert($0).inserted}
  }
  private func sources(_ scope:FontBrowserScope)->[(FontBrowserSection.Kind,[String])] {
    switch scope {
    case .all:return [(.projectSaved,projectSaved),(.projectUsed,projectUsed),(.studioSaved,studioSaved),(.recent,recent),(.installed,families.compactMap{$0.representative()?.name})]
    case .project:return [(.projectSaved,projectSaved),(.projectUsed,projectUsed)]
    case .studio:return [(.studioSaved,studioSaved)]
    case .recent:return [(.recent,recent)]
    }
  }
  func unavailableFaces(scope:FontBrowserScope = .all,query:String="")->[String] {
    Self.unique(sources(scope).flatMap(\.1)).filter{name in
      byName[name]==nil && InstalledFontFace(name:name,family:name,style:"").matches(query)
    }
  }
  func sections(scope:FontBrowserScope = .all,category:FontBrowserCategory = .all,query:String="",currentFace:String?=nil)->[FontBrowserSection] {
    let current=currentFace.flatMap{byName[aliases[$0] ?? $0]}
    let familyByName=Dictionary(uniqueKeysWithValues:families.map{($0.name,$0)})
    var seen=Set<String>(),result:[FontBrowserSection]=[]
    for (kind,names) in sources(scope) {
      let sectionFaces=Set(names)
      var rows:[FontBrowserRow]=[]
      for name in names {
        guard let seed=byName[name],!seen.contains(seed.family),let family=familyByName[seed.family] else{continue}
        let eligible=family.matchingFaces(query).filter{
          category.includes($0) && (kind == .installed || sectionFaces.contains($0.name))
        }
        let candidates=InstalledFontFamily(name:family.name,faces:eligible)
        // A recent family represents its newest matching exact face, rather
        // than changing history's meaning to suit the current text's style.
        let preferred=kind == .recent ? seed:current ?? seed
        guard let face=candidates.representative(preserving:preferred) else{continue}
        seen.insert(family.name);rows.append(.init(family:family,face:face))
      }
      // Recent is intentionally chronological. Other scope lists have a
      // deterministic family order independent of save order or dictionary order.
      if kind != .recent {
        let rank=Dictionary(uniqueKeysWithValues:families.enumerated().map{($0.element.name,$0.offset)})
        rows.sort{rank[$0.id]!<rank[$1.id]!}
      }
      if !rows.isEmpty {result.append(.init(kind:kind,rows:rows))}
    }
    return result
  }
}

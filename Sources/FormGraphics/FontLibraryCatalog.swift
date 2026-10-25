import AppKit
import CoreText
import FormCore

public struct InstalledFontFace:Equatable,Identifiable,Sendable {
  public var id:String {name}
  public var name:String,family:String,style:String
  public var json:[String:String] {["id":id,"name":name,"family":family,"style":style]}
}

@MainActor public enum FontLibraryCatalog {
  private static var index:[InstalledFontFace]?
  private static var buildMilliseconds=0.0,builds=0,previewBuilds=0
  private static let previews:NSCache<NSString,NSFont> = {let c=NSCache<NSString,NSFont>();c.countLimit=128;return c}()
  public static func invalidate() {index=nil;previews.removeAllObjects()}
  public static var faces:[InstalledFontFace] {
    if let index {return index}
    let start=Date();var seen=Set<String>(),result:[InstalledFontFace]=[]
    for family in FontCatalog.families {for face in FontCatalog.faces(family) where seen.insert(face.name).inserted {
      result.append(.init(name:face.name,family:family,style:face.style))
    }}
    result.sort {a,b in a.family==b.family ? a.style.localizedStandardCompare(b.style) == .orderedAscending:a.family.localizedStandardCompare(b.family) == .orderedAscending}
    index=result;builds+=1;buildMilliseconds=Date().timeIntervalSince(start)*1000;return result
  }
  public static func search(_ query:String)->[InstalledFontFace] {
    let terms=query.split(whereSeparator:{$0.isWhitespace}).map(String.init)
    return faces.filter {face in terms.allSatisfy {term in [face.family,face.style,face.name].contains{$0.localizedCaseInsensitiveContains(term)}}}
  }
  public static func preview(_ name:String,size:Double=18)->NSFont? {
    let key="\(name)/\(size)" as NSString
    if let value=previews.object(forKey:key) {return value}
    guard let font=NSFont(name:name,size:size) else{return nil}
    previewBuilds+=1;previews.setObject(font,forKey:key);return font
  }
  public static let defaultPreview="Aa  Form  0123456789"
  public static func previewText(_ requested:String,font:NSFont)->(text:String,usesFallback:Bool) {
    func covered(_ text:String)->Bool {
      let needed=CharacterSet(charactersIn:text).subtracting(.whitespacesAndNewlines)
      return needed.isSubset(of:font.coveredCharacterSet)
    }
    if requested.isEmpty || requested==defaultPreview {
      let samples=[defaultPreview,"الشكل والنور","צורה ואור","形与光","かたちと光","형태와빛","रूप और प्रकाश","வடிவம் ஒளி","รูปทรงและแสง","Φως και μορφή","Форма и свет","😀 🌙 💡","☀ ♫ ♡ ★"]
      if let sample=samples.first(where:covered) {return(sample,false)}
    }
    let text=requested.isEmpty ? defaultPreview:requested
    return(text,!covered(text))
  }
  public static func installed(_ name:String)->Bool {NSFont(name:name,size:12) != nil}
  public static var diagnostics:[String:Any] {["installed_face_count":faces.count,"installed_family_count":Set(faces.map(\.family)).count,"index_builds":builds,"index_build_ms":buildMilliseconds,"preview_builds":previewBuilds,"preview_cache_limit":128]}
  public static func settingsWarnings(_ project:Project,face:String)->[String] {
    guard installed(face) else{return []}
    var types:[Typography]=[]
    func collect(_ element:ArtworkElement) {
      if let type=element.typography,type.fontName==face {types.append(type)}
      types += (element.textRuns ?? []).map(\.typography).filter{$0.fontName==face}
    }
    for object in project.objects {for element in object.artwork?.elements ?? [] where element.kind=="text" && element.storyFrame==nil {collect(element)}}
    for story in project.textStories ?? [] {collect(story.sourceElement)}
    types += (project.textStyles ?? []).map(\.typography).filter{$0.fontName==face}
    let details=FontCatalog.details(face),axes=details["axes"] as? [[String:Any]] ?? [],features=details["features"] as? [[String:Any]] ?? []
    var warnings=Set<String>()
    for type in types {
      for (id,value) in type.variations {
        if let axis=axes.first(where:{$0["id"] as? Int==id}),let minimum=axis["minimum"] as? Double,let maximum=axis["maximum"] as? Double {
          if value<minimum || value>maximum {warnings.insert("Retained axis \(id) value \(value) is outside this face's supported range.")}
        } else {warnings.insert("Retained variation axis \(id) is not offered by \(face).")}
      }
      var requested=type.featureSelections ?? [:]
      for (id,selector) in type.features where requested[id]==nil {requested[id]=[selector]}
      for (id,selectors) in requested {
        guard let feature=features.first(where:{$0["id"] as? Int==id}) else{warnings.insert("Retained feature group \(id) is not offered by \(face).");continue}
        let supported=Set((feature["selectors"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? Int})
        if !Set(selectors).isSubset(of:supported) {warnings.insert("Some retained selectors in feature group \(id) are not offered by \(face).")}
      }
    }
    return warnings.sorted()
  }
  public static func usage(_ project:Project)->[[String:Any]] {
    let grouped=Dictionary(grouping:FontUsage.uses(in:project),by:{$0.fontName})
    return grouped.keys.sorted().map {name in
      let uses=grouped[name]!,font=NSFont(name:name,size:12)
      return ["font_name":name,"available":font != nil,"resolved_face":font?.fontName as Any? ?? NSNull(),
        "family":font?.familyName as Any? ?? NSNull(),"assignment_count":uses.count,
        "exact_glyph_count":uses.filter{$0.kind=="exact_glyph"}.count,"uses":uses.map(\.json),"settings_warnings":settingsWarnings(project,face:name)]
    }
  }
}

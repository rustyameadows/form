import AppKit
import CoreText
import FormCore

public struct InstalledFontFace:Equatable,Identifiable,Sendable {
  public var id:String {name}
  public var name:String,family:String,style:String
  public var traits:InstalledFontTraits
  public init(name:String,family:String,style:String,traits:InstalledFontTraits = .init()) {
    self.name=name;self.family=family;self.style=style;self.traits=traits
  }
  public var json:[String:String] {["id":id,"name":name,"family":family,"style":style]}
  public func matches(_ query:String)->Bool {
    query.split(whereSeparator:{$0.isWhitespace}).allSatisfy {term in
      [family,style,name].contains{$0.range(of:String(term),options:[.caseInsensitive,.diacriticInsensitive],locale:FontCatalogOrdering.locale) != nil}
    }
  }
}

/// Classification is supplied by CoreText's OS/2 stylistic class, never by
/// matching family or face names. Unclassified faces remain available in All.
public struct InstalledFontTraits:Equatable,Sendable {
  public enum Classification:String,Sendable {case unknown,serif,sans,script}
  public var classification:Classification
  public var isMonospaced:Bool,isVariable:Bool,isItalic:Bool,isBold:Bool
  public var weight:Double,width:Double,slant:Double
  public init(classification:Classification = .unknown,isMonospaced:Bool=false,isVariable:Bool=false,
    isItalic:Bool=false,isBold:Bool=false,weight:Double=0,width:Double=0,slant:Double=0) {
    self.classification=classification;self.isMonospaced=isMonospaced;self.isVariable=isVariable
    self.isItalic=isItalic;self.isBold=isBold;self.weight=weight;self.width=width;self.slant=slant
  }
  public init(font:CTFont) {
    let symbolic=CTFontGetSymbolicTraits(font)
    // CTFontTraits.h: the upper four bits contain the OS/2 class. Class 6 is
    // reserved; 9 (ornamental) and 12 (symbolic) are deliberately not guessed.
    switch (symbolic.rawValue >> 28) & 15 {
    case 1...5,7:classification = .serif
    case 8:classification = .sans
    case 10:classification = .script
    default:classification = .unknown
    }
    isMonospaced=symbolic.contains(.traitMonoSpace);isItalic=symbolic.contains(.traitItalic);isBold=symbolic.contains(.traitBold)
    isVariable = !(CTFontCopyVariationAxes(font) as? [Any] ?? []).isEmpty
    let values=CTFontCopyTraits(font) as NSDictionary
    func number(_ key:CFString)->Double {
      let value=(values[key] as? NSNumber)?.doubleValue ?? 0
      return value.isFinite ? value:0
    }
    weight=number(kCTFontWeightTrait);width=number(kCTFontWidthTrait);slant=number(kCTFontSlantTrait)
  }
}

public struct InstalledFontFamily:Equatable,Identifiable,Sendable {
  public var id:String {name}
  public let name:String
  public let faces:[InstalledFontFace]
  public init(name:String,faces:[InstalledFontFace]) {
    self.name=name
    var seen=Set<String>()
    self.faces=faces.filter{$0.family==name && seen.insert($0.name).inserted}.sorted(by:FontCatalogOrdering.face)
  }
  public static func grouping(_ faces:[InstalledFontFace])->[Self] {
    Dictionary(grouping:faces,by: \.family).map{Self(name:$0.key,faces:$0.value)}.sorted{FontCatalogOrdering.before($0.name,$1.name)}
  }
  public func matchingFaces(_ query:String)->[InstalledFontFace] {faces.filter{$0.matches(query)}}
  public func representative(preserving current:InstalledFontFace?=nil)->InstalledFontFace? {
    if let current,let exact=faces.first(where:{$0.name==current.name}) {return exact}
    if let current,let sameStyle=faces.first(where:{
      $0.style.compare(current.style,options:[.caseInsensitive,.diacriticInsensitive],locale:FontCatalogOrdering.locale) == .orderedSame
    }) {return sameStyle}
    let target=current?.traits ?? .init()
    func distance(_ value:InstalledFontFace)->Double {
      let traits=value.traits
      return (traits.isItalic==target.isItalic ? 0:10)+(traits.isBold==target.isBold ? 0:2)
        + abs(traits.weight-target.weight)*3 + abs(traits.width-target.width)*4 + abs(traits.slant-target.slant)
    }
    return faces.min {a,b in
      let left=distance(a),right=distance(b)
      return left==right ? FontCatalogOrdering.face(a,b):left<right
    }
  }
}

private enum FontCatalogOrdering {
  static let locale=Locale(identifier:"en_US_POSIX")
  static func before(_ a:String,_ b:String)->Bool {
    let result=a.compare(b,options:[.caseInsensitive,.diacriticInsensitive,.numeric],locale:locale)
    return result == .orderedSame ? a<b:result == .orderedAscending
  }
  static func face(_ a:InstalledFontFace,_ b:InstalledFontFace)->Bool {
    if a.family != b.family {return before(a.family,b.family)}
    if a.traits.weight != b.traits.weight {return a.traits.weight<b.traits.weight}
    if a.traits.width != b.traits.width {return a.traits.width<b.traits.width}
    if a.traits.isItalic != b.traits.isItalic {return !a.traits.isItalic}
    if a.style != b.style {return before(a.style,b.style)}
    return before(a.name,b.name)
  }
}

@MainActor public enum FontLibraryCatalog {
  private static var index:[InstalledFontFace]?
  private static var familyIndex:[InstalledFontFamily]?
  private static var faceIndex:[String:InstalledFontFace]?
  private static var aliases:[String:String]=[:]
  private static var missingNames=Set<String>()
  private static var buildMilliseconds=0.0,builds=0,previewBuilds=0
  private static let previews:NSCache<NSString,NSFont> = {let c=NSCache<NSString,NSFont>();c.countLimit=128;return c}()
  public static func invalidate() {index=nil;familyIndex=nil;faceIndex=nil;aliases.removeAll();missingNames.removeAll();previews.removeAllObjects()}
  public static var faces:[InstalledFontFace] {
    if let index {return index}
    let start=Date();var seen=Set<String>(),result:[InstalledFontFace]=[]
    for family in FontCatalog.families {for face in FontCatalog.faces(family) where seen.insert(face.name).inserted {
      let font=CTFontCreateWithName(face.name as CFString,12,nil)
      result.append(.init(name:face.name,family:family,style:face.style,traits:.init(font:font)))
    }}
    result.sort(by:FontCatalogOrdering.face)
    index=result;builds+=1;buildMilliseconds=Date().timeIntervalSince(start)*1000;return result
  }
  public static func search(_ query:String)->[InstalledFontFace] {
    faces.filter{$0.matches(query)}
  }
  public static var families:[InstalledFontFamily] {
    if let familyIndex {return familyIndex}
    let value=InstalledFontFamily.grouping(faces);familyIndex=value;return value
  }
  /// Resolve installed aliases at the browsing boundary without changing the
  /// authored name. NSFont rejects missing names instead of substituting a face.
  public static func face(named name:String)->InstalledFontFace? {
    if faceIndex == nil {faceIndex=Dictionary(faces.map{($0.name,$0)},uniquingKeysWith:{first,_ in first})}
    if let exact=faceIndex?[name] {return exact}
    if let alias=aliases[name] {return faceIndex?[alias]}
    guard !missingNames.contains(name) else{return nil}
    guard let resolved=NSFont(name:name,size:12)?.fontName,let face=faceIndex?[resolved] else {
      if missingNames.count<2048 {missingNames.insert(name)}
      return nil
    }
    if aliases.count<2048 {aliases[name]=face.name}
    return face
  }
  public static func canonicalName(_ name:String)->String {face(named:name)?.name ?? name}
  public static func family(named name:String)->InstalledFontFamily? {families.first{$0.name==name}}
  public static func searchFamilies(_ query:String)->[InstalledFontFamily] {families.filter{!$0.matchingFaces(query).isEmpty}}
  public static func preview(_ name:String,size:Double=18)->NSFont? {
    guard size.isFinite,size>0,size<=512 else{return nil}
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
    for art in project.storedArtworks {for element in art.elements where element.kind=="text" && element.storyFrame==nil {collect(element)}}
    for story in project.textStories ?? [] {collect(story.sourceElement)}
    types += (project.textStyles ?? []).map(\.typography).filter{$0.fontName==face}
    let details=FontCatalog.details(face),axes=details["axes"] as? [[String:Any]] ?? [],features=details["features"] as? [[String:Any]] ?? []
    var warnings=Set<String>()
    for type in types {
      if let warning=OpticalTypography.warning(type) {warnings.insert(warning)}
      for (id,value) in type.variations where type.opticalSizing == nil || id != OpticalSizing.axisID {
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

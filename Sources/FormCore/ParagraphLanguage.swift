import Foundation

/// Optional limits apply to language-dictionary hyphenation, in Unicode characters.
public struct HyphenationLimits: Codable, Equatable, Sendable {
  public var minimumWordLength: Int
  public var minimumPrefix: Int
  public var minimumSuffix: Int
  public init(minimumWordLength:Int=5,minimumPrefix:Int=2,minimumSuffix:Int=2) {
    self.minimumWordLength=minimumWordLength;self.minimumPrefix=minimumPrefix;self.minimumSuffix=minimumSuffix
  }
  public func validate() throws {
    guard (2...100).contains(minimumWordLength),(1...30).contains(minimumPrefix),(1...30).contains(minimumSuffix) else {
      throw FormError.invalid("Hyphenation needs a 2–100 character minimum word and 1–30 character prefix/suffix limits.")
    }
  }
}

public enum ParagraphLanguage {
  public static func canonical(_ identifier:String) throws -> String {
    let normalized=identifier.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"_",with:"-")
    guard normalized.count<=80,normalized.range(of:"^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$",options:.regularExpression) != nil else {
      throw FormError.invalid("Use a BCP 47 language identifier such as en, de, fr, tr, or en-US.")
    }
    return Locale.canonicalLanguageIdentifier(from:normalized).replacingOccurrences(of:"_",with:"-")
  }
  public static func validate(_ identifier:String?) throws {
    if let identifier,try canonical(identifier) != identifier {
      throw FormError.invalid("Use the canonical language identifier \(try canonical(identifier)).")
    }
  }
  public static func setDefault(_ artwork:inout Artwork,arguments:[String:Any]) throws {
    guard let value=arguments["language"] else {throw FormError.invalid("Provide a language identifier or null to use automatic language.")}
    if value is NSNull {artwork.language=nil}
    else if let identifier=value as? String {artwork.language=try canonical(identifier)}
    else {throw FormError.invalid("Language must be a BCP 47 identifier or null.")}
  }
}

extension Typography {
  public var usesPublicationLanguage:Bool {language != nil || hyphenationLimits != nil}
}
extension ArtworkElement {
  /// Render-only inheritance. It never enters an encoded Typography value.
  public func inheritingLanguage(_ language:String?)->Self {
    guard language != nil || typography?.inheritedLanguage != nil else {return self}
    var result=self
    if result.kind=="text" {
      var type=result.typography ?? .init();type.inheritedLanguage=language;result.typography=type
      for i in result.textRuns?.indices ?? 0..<0 {result.textRuns?[i].typography.inheritedLanguage=type.language ?? language}
    }
    return result
  }
}
extension Artwork {
  public var requiresSchemaTwenty:Bool {
    language != nil || elements.contains{$0.typography?.usesPublicationLanguage == true || $0.textRuns?.contains{$0.typography.usesPublicationLanguage} == true}
  }
  public var withInheritedLanguage:Self {
    guard language != nil else {return self}
    var result=self;result.elements=elements.map{$0.inheritingLanguage(language)};return result
  }
}

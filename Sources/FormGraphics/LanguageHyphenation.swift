import AppKit
import CoreFoundation
import CoreText
import FormCore

public enum LanguageHyphenation {
  public static let languageKey=NSAttributedString.Key(kCTLanguageAttributeName as String)
  public static let inheritedLanguageKey=NSAttributedString.Key("studio.form.documentLanguage")
  private static let styleKey=NSAttributedString.Key("studio.form.typography")
  private final class LocaleEntry:NSObject {let locale:CFLocale;init(_ locale:CFLocale){self.locale=locale}}
  private static let locales:NSCache<NSString,LocaleEntry> = {let c=NSCache<NSString,LocaleEntry>();c.countLimit=64;return c}()
  private static func locale(_ identifier:String)->CFLocale {
    if let existing=locales.object(forKey:identifier as NSString){return existing.locale}
    let result=CFLocaleCreate(nil,CFLocaleIdentifier(rawValue:identifier as CFString))!
    locales.setObject(LocaleEntry(result),forKey:identifier as NSString);return result
  }
  public static func dictionaryAvailable(_ identifier:String)->Bool {
    CFStringIsHyphenationAvailableForLocale(locale(identifier))
  }
  public static func candidate(in text:String,before index:Int,range:NSRange,language:String,limits:HyphenationLimits?=nil)->Int {
    let string=text as NSString
    guard range.location>=0,range.length<=string.length-range.location,index>range.location,index<=NSMaxRange(range),
      range.location<=string.length,dictionaryAvailable(language),let swiftRange=Range(range,in:text) else {return NSNotFound}
    var word:NSRange?
    text.enumerateSubstrings(in:swiftRange,options:[.byWords,.substringNotRequired]) {_,part,_,stop in
      let candidate=NSRange(part,in:text)
      if candidate.location<index,NSMaxRange(candidate)>=index {word=candidate;stop=true}
    }
    guard let word else{return NSNotFound}
    let policy=limits ?? HyphenationLimits(minimumWordLength:2,minimumPrefix:1,minimumSuffix:1)
    let source=string.substring(with:word)
    guard source.count>=policy.minimumWordLength else{return NSNotFound}
    var search=min(index,NSMaxRange(word)),hyphen:UTF32Char=0
    while search>word.location {
      let position=CFStringGetHyphenationLocationBeforeIndex(text as CFString,search,CFRange(location:word.location,length:word.length),0,locale(language),&hyphen)
      guard position != kCFNotFound,position>word.location,position<NSMaxRange(word) else{return NSNotFound}
      let prefix=NSRange(location:word.location,length:position-word.location),suffix=NSRange(location:position,length:NSMaxRange(word)-position)
      if Range(prefix,in:text) != nil,Range(suffix,in:text) != nil,
        string.substring(with:prefix).count>=policy.minimumPrefix,string.substring(with:suffix).count>=policy.minimumSuffix {return position}
      search=position
    }
    return NSNotFound
  }
  static func settings(_ attrs:[NSAttributedString.Key:Any])->(language:String?,limits:HyphenationLimits?) {
    let type=(attrs[styleKey] as? Data).flatMap{try? JSONDecoder.form.decode(Typography.self,from:$0)}
    return (type?.language ?? attrs[languageKey] as? String,type?.hyphenationLimits)
  }
}

/// AppKit calls this overridable NSAttributedString boundary while typesetting.
/// Explicit language and limits therefore drive the actual native/generated glyphs.
public class PublicationTextStorage:NSTextStorage {
  private let backing=NSMutableAttributedString(string:"")
  public override var string:String {backing.string}
  public override func attributes(at location:Int,effectiveRange range:NSRangePointer?)->[NSAttributedString.Key:Any] {
    backing.attributes(at:location,effectiveRange:range)
  }
  public override func replaceCharacters(in range:NSRange,with value:String) {
    beginEditing();backing.replaceCharacters(in:range,with:value)
    edited(.editedCharacters,range:range,changeInLength:value.utf16.count-range.length);endEditing()
  }
  public override func setAttributes(_ attrs:[NSAttributedString.Key:Any]?,range:NSRange) {
    beginEditing();backing.setAttributes(attrs,range:range);edited(.editedAttributes,range:range,changeInLength:0);endEditing()
  }
  public override func lineBreakByHyphenating(before location:Int,within range:NSRange)->Int {
    guard length>0,location>0 else{return NSNotFound}
    let settings=LanguageHyphenation.settings(attributes(at:min(length-1,location-1),effectiveRange:nil))
    guard settings.language != nil || settings.limits != nil else {return super.lineBreakByHyphenating(before:location,within:range)}
    return LanguageHyphenation.candidate(in:string,before:location,range:range,
      language:settings.language ?? Locale.preferredLanguages.first ?? "en",limits:settings.limits)
  }
}

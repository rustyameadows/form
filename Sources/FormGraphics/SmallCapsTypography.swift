import AppKit
import FormCore

/// Existing font controls remain the only small-cap controls. No synthetic caps.
@MainActor public enum SmallCapsTypography {
  public struct Report:Equatable {
    public var range:NSRange,status:String,message:String
  }
  private static func requests(_ type:Typography)->[(Int,Int,Int)] {
    type.resolvedFeatureSelections.compactMap {feature in
      if feature.type==37,feature.selector==1 {return(37,1,1)}
      if feature.type==38,feature.selector==1 {return(38,1,2)}
      if feature.type==3,[3,5].contains(feature.selector) {return(3,feature.selector,1)}
      return nil
    }
  }
  public static func isRequested(_ type:Typography)->Bool {!requests(type).isEmpty}
  public static func requiresOutlines(_ e:ArtworkElement)->Bool {
    let source=e.storyFrame?.resolved?.story.sourceElement ?? e
    return source.typography.map(isRequested)==true || source.textRuns?.contains{isRequested($0.typography)}==true
  }
  public static func reports(in text:NSAttributedString,range:NSRange?=nil)->[Report] {
    let target=range ?? NSRange(location:0,length:text.length)
    guard target.location>=0,target.length>=0,target.location<=text.length,target.length<=text.length-target.location else{return []}
    var result:[Report]=[],budget=CharacterCoverage.maximumCallClusters
    text.enumerateAttributes(in:target) {attrs,part,_ in
      guard let type=TypographyEngine.assignedTypography(in:attrs),let candidate=attrs[.font] as? NSFont else{return}
      for (feature,selector,eligible) in requests(type) {
        if attrs[GlyphEngine.overrideKey] != nil {result.append(.init(range:part,status:"exact_glyph",message:"An exact glyph choice overrides small-cap substitution for these source characters; its identity stays recorded."));continue}
        let words=(text.string as NSString).substring(with:part),letters=eligible==1 ? CharacterSet.lowercaseLetters:CharacterSet.uppercaseLetters
        guard words.unicodeScalars.contains(where:letters.contains) else {
          result.append(.init(range:part,status:"not_applicable",message:"This small-cap request has no eligible "+(eligible==1 ? "lowercase":"uppercase")+" characters after the current case treatment."));continue
        }
        guard CharacterCoverage.offers(candidate,type:feature,selector:selector) else {
          result.append(.init(range:part,status:"unavailable",message:type.fontName+" does not offer the requested small-cap form. Source assignments and unsupported characters remain unchanged."));continue
        }
        var settings=(candidate.fontDescriptor.object(forKey:.featureSettings) as? [[NSFontDescriptor.FeatureKey:Any]] ?? []).filter{($0[.typeIdentifier] as? NSNumber)?.intValue != feature}
        settings.append([.typeIdentifier:feature,.selectorIdentifier:0])
        let base=NSFont(descriptor:candidate.fontDescriptor.addingAttributes([.featureSettings:settings]),size:candidate.pointSize) ?? candidate
        let check=CharacterCoverage.complete(words,base:base,candidate:candidate,language:type.language ?? type.inheritedLanguage,ligatures:type.ligatures,budget:&budget,eligibleCase:eligible)
        let status=check.complete ? "supported":check.limited ? "unreviewed":"partial"
        let message=check.complete ? "Font-authored small caps cover the eligible characters in this span.":check.limited ? "Small-cap coverage review reached its work limit; no text or font assignment was changed.":"Partial font-authored small caps; unsupported characters remain their original forms. "+check.reason.replacingOccurrences(of:" The whole shaping span uses geometry.",with:"")
        result.append(.init(range:part,status:status,message:message))
      }
    }
    return result
  }
  public static func warnings(_ artwork:Artwork)->[String] {
    var result=Set<String>()
    let sources=artwork.elements.filter{$0.kind=="text" && $0.hidden != true && requiresOutlines($0)}
    if sources.count>256 {result.insert("Small-cap coverage review is limited to 256 text sources; additional requests remain recorded and unreviewed.")}
    for e in sources.prefix(256) {
      let source=e.storyFrame?.resolved?.story.sourceElement ?? e
      for report in reports(in:TypographyEngine.attributed(source,preservingSource:true)) where report.status != "supported" {result.insert(e.title+": "+report.message)}
    }
    return result.sorted()
  }
}

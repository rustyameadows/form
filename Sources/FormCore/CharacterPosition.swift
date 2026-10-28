import Foundation
import CoreFoundation

/// Authored intent only. Omission preserves legacy font-feature behavior.
/// Derived font size/offset and coverage are never stored in a project.
public enum CharacterPosition:String,Codable,CaseIterable,Sendable {
  case normal,superscript,`subscript`
  public var displayName:String {rawValue.capitalized}
  public var geometricScale:Double {self == .normal ? 1:0.65}
  public var geometricOffsetEm:Double {self == .superscript ? 0.35:self == .subscript ? -0.15:0}
}

public enum CharacterPositionCommands {
  public static let maximumCommandUTF16=1_000_000
  public static let maximumTargets=256
  public static let maximumSourceSpans=4096
  public static func setting(_ arguments:[String:Any])throws->CharacterPosition? {
    guard let raw=arguments["position"] else {throw FormError.invalid("Choose normal, superscript, subscript, or null to restore legacy font-feature behavior.")}
    if raw is NSNull {return nil}
    guard let name=raw as? String,let value=CharacterPosition(rawValue:name) else {throw FormError.invalid("Character position must be normal, superscript, subscript, or null.")}
    return value
  }
  public static func isCompleteRange(_ range:NSRange,in text:String,allowCaret:Bool=false)->Bool {
    let source=text as NSString
    guard range.location>=0,range.length>=0,range.location<=source.length,range.length<=source.length-range.location else{return false}
    if range.length==0 {return allowCaret && (range.location==0 || range.location==source.length || source.rangeOfComposedCharacterSequence(at:range.location).location==range.location)}
    return source.rangeOfComposedCharacterSequences(for:range)==range
  }
  public static func assign(_ artwork:inout Artwork,ids:Set<UUID>,arguments:[String:Any],maxTextCharacters:Int=10000)throws {
    let value=try setting(arguments)
    guard (arguments["location"]==nil)==(arguments["length"]==nil) else {throw FormError.invalid("Provide both source UTF-16 location and length.")}
    let targets=artwork.swatchPaintTargets(for:ids),texts=artwork.elements.filter{targets.contains($0.id) && $0.kind=="text"}
    guard !texts.isEmpty,texts.count<=maximumTargets,texts.allSatisfy({!artwork.isLocked($0)}) else {throw FormError.invalid("Select up to 256 unlocked text sources for character positioning.")}
    var total=0
    for text in texts {let count=text.text.utf16.count;guard count<=maximumCommandUTF16-total else{throw FormError.invalid("Character-position edits support at most one million source UTF-16 units per operation.")};total+=count}
    let range:NSRange?
    if arguments["location"] != nil {
      guard texts.count==1,let n=arguments["location"] as? NSNumber,let l=arguments["length"] as? NSNumber,
        CFGetTypeID(n) != CFBooleanGetTypeID(),CFGetTypeID(l) != CFBooleanGetTypeID(),n.doubleValue.isFinite,l.doubleValue.isFinite,
        n.doubleValue==n.doubleValue.rounded(),l.doubleValue==l.doubleValue.rounded(),n.doubleValue>=0,l.doubleValue>=1,
        n.doubleValue<=Double(texts[0].text.utf16.count),l.doubleValue<=Double(texts[0].text.utf16.count) else {throw FormError.invalid("Choose a nonempty integer source UTF-16 range.")}
      let selected=NSRange(location:n.intValue,length:l.intValue)
      guard isCompleteRange(selected,in:texts[0].text) else{throw FormError.invalid("Character positioning must preserve complete graphemes, including combining marks and joined emoji.")}
      range=selected
    }else{range=nil}
    var candidate=artwork
    for i in candidate.elements.indices where targets.contains(candidate.elements[i].id) && candidate.elements[i].kind=="text" {
      var element=candidate.elements[i]
      if let range {
        let old=element.textRuns ?? [],edges=Set([0,element.text.utf16.count,range.location,NSMaxRange(range)]+old.flatMap{[$0.location,$0.location+$0.length]}).sorted()
        element.textRuns=zip(edges,edges.dropFirst()).compactMap{start,end in
          guard end>start else{return nil}
          var run=old.first{$0.location<=start && $0.location+$0.length>=end} ?? TextStyleCommands.span(element);run.location=start;run.length=end-start
          if start>=range.location,end<=NSMaxRange(range) {let before=run;run.typography.characterPosition=value;run=TextStyleCommands.recording(run,from:before)}
          return run
        }
      }else {
        var type=element.typography ?? .init();type.characterPosition=value;element.typography=type
        for r in element.textRuns?.indices ?? 0..<0 {element.textRuns![r].typography.characterPosition=value}
      }
      candidate.elements[i]=element
    }
    try validateArtwork(candidate,maxTextCharacters:maxTextCharacters);artwork=candidate
  }
}
extension Artwork {
  public var requiresCharacterPositionSchema:Bool {elements.contains{$0.typography?.characterPosition != nil || $0.textRuns?.contains{$0.typography.characterPosition != nil}==true}}
}
extension Project {
  public var requiresCharacterPositionSchema:Bool {
    objects.contains{$0.artwork?.requiresCharacterPositionSchema==true}
      || textStyles?.contains{$0.typography.characterPosition != nil}==true
      || textStories?.contains{$0.typography?.characterPosition != nil || $0.textRuns?.contains{$0.typography.characterPosition != nil}==true}==true
  }
}

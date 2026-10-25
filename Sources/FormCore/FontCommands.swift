import Foundation
import CoreFoundation

public enum FontCommands {
  public static func assign(_ artwork:inout Artwork,ids:Set<UUID>,arguments:[String:Any],maxTextCharacters:Int=10000) throws {
    guard let name=arguments["font_name"] as? String,!name.isEmpty,name.count<=300,
      (arguments["location"]==nil)==(arguments["length"]==nil) else{throw FormError.invalid("Provide a face name and, optionally, one global UTF-16 location/length.")}
    let targets=artwork.swatchPaintTargets(for:ids),texts=artwork.elements.filter{targets.contains($0.id) && $0.kind=="text"}
    guard !texts.isEmpty,texts.allSatisfy({!artwork.isLocked($0)}) else{throw FormError.invalid("Select unlocked text for a font assignment.")}
    let range:NSRange?
    if arguments["location"] != nil {
      guard texts.count==1,let number=arguments["location"] as? NSNumber,let size=arguments["length"] as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),CFGetTypeID(size) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite,size.doubleValue.isFinite,number.doubleValue==number.doubleValue.rounded(),size.doubleValue==size.doubleValue.rounded(),
        number.doubleValue>=0,number.doubleValue<=Double(texts[0].text.utf16.count),size.doubleValue>=1,size.doubleValue<=Double(texts[0].text.utf16.count) else{throw FormError.invalid("Choose a nonempty integer UTF-16 range.")}
      let location=number.intValue,length=size.intValue,utf16=texts[0].text as NSString
      func boundary(_ offset:Int)->Bool {offset==0 || offset==utf16.length || !(0xD800...0xDBFF).contains(utf16.character(at:offset-1)) || !(0xDC00...0xDFFF).contains(utf16.character(at:offset))}
      guard location>=0,length>0,location<=texts[0].text.utf16.count,length<=texts[0].text.utf16.count-location,
        boundary(location),boundary(location+length),Range(NSRange(location:location,length:length),in:texts[0].text) != nil else{throw FormError.invalid("Choose a nonempty UTF-16 source range at character boundaries.")}
      range=NSRange(location:location,length:length)
    } else {range=nil}
    var candidate=artwork
    for i in candidate.elements.indices where targets.contains(candidate.elements[i].id) && candidate.elements[i].kind=="text" {
      var e=candidate.elements[i]
      if let range {
        let old=e.textRuns ?? [],count=e.text.utf16.count
        let edges=Set([0,count,range.location,NSMaxRange(range)]+old.flatMap{[$0.location,$0.location+$0.length]}).sorted()
        e.textRuns=zip(edges,edges.dropFirst()).compactMap {start,end in
          guard end>start else{return nil}
          var run=old.first{$0.location<=start && $0.location+$0.length>=end} ?? TextStyleCommands.span(e)
          run.location=start;run.length=end-start
          if start>=range.location,end<=NSMaxRange(range) {let before=run;run.typography.fontName=name;run=TextStyleCommands.recording(run,from:before)}
          return run
        }
      } else {
        var type=e.typography ?? .init();type.fontName=name;e.typography=type
        for r in e.textRuns?.indices ?? 0..<0 {e.textRuns![r].typography.fontName=name}
      }
      candidate.elements[i]=e
    }
    try validateArtwork(candidate,maxTextCharacters:maxTextCharacters);artwork=candidate
  }
}

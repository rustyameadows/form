import Foundation
import CoreFoundation

/// A new policy is separate from a legacy explicit opsz assignment. Omission
/// preserves the original font creation path; dormant source axes stay stored.
public struct OpticalSizing:Codable,Equatable,Sendable {
  public enum Mode:String,Codable,CaseIterable,Sendable {case automatic,explicit,none}
  public var mode:Mode
  public var points:Double?
  public init(_ mode:Mode,points:Double?=nil) {self.mode=mode;self.points=points}
  public static let axisID=Int(0x6f70737a)
  public func validate()throws {
    if mode == .explicit {
      guard let points,points.isFinite,(0.1...10000).contains(points) else{throw FormError.invalid("An explicit optical size needs finite 0.1–10000 typographic points.")}
    }else if points != nil {throw FormError.invalid("Only explicit optical sizing accepts a point value.")}
  }
}
extension Typography {
  public mutating func setOpticalSizing(_ value:OpticalSizing?) {
    opticalSizing=value
    if value==nil {variations.removeValue(forKey:OpticalSizing.axisID)}
  }
}
extension Artwork {
  public var requiresSchemaFortyTwo:Bool {elements.contains{$0.typography?.opticalSizing != nil || $0.textRuns?.contains{$0.typography.opticalSizing != nil}==true}}
}
extension Project {
  public var requiresOpticalSizingSchema:Bool {
    objects.contains{$0.artwork?.requiresSchemaFortyTwo==true} || textStyles?.contains{$0.typography.opticalSizing != nil}==true
      || textStories?.contains{$0.typography?.opticalSizing != nil || $0.textRuns?.contains{$0.typography.opticalSizing != nil}==true}==true
  }
}

public enum OpticalCommands {
  public static func setting(_ arguments:[String:Any])throws->OpticalSizing? {
    guard let raw=arguments["optical_sizing"] else{throw FormError.invalid("Provide optical_sizing automatic, explicit(points), none, or null for an intentional reset.")}
    if raw is NSNull {return nil}
    guard let object=raw as? [String:Any],Set(object.keys).isSubset(of:["mode","points"]) else{throw FormError.invalid("Optical sizing accepts mode and explicit points only.")}
    let value=try JSONDecoder.form.decode(OpticalSizing.self,from:JSONSerialization.data(withJSONObject:object));try value.validate();return value
  }
  public static func assign(_ artwork:inout Artwork,ids:Set<UUID>,arguments:[String:Any],maxTextCharacters:Int=10000)throws {
    let setting=try setting(arguments)
    guard (arguments["location"]==nil)==(arguments["length"]==nil) else{throw FormError.invalid("Provide both source UTF-16 location and length.")}
    let targets=artwork.swatchPaintTargets(for:ids),texts=artwork.elements.filter{targets.contains($0.id) && $0.kind=="text"}
    guard !texts.isEmpty,texts.allSatisfy({!artwork.isLocked($0)}) else{throw FormError.invalid("Select unlocked text for optical sizing.")}
    let range:NSRange?
    if arguments["location"] != nil {
      guard texts.count==1,let n=arguments["location"] as? NSNumber,let l=arguments["length"] as? NSNumber,
        CFGetTypeID(n) != CFBooleanGetTypeID(),CFGetTypeID(l) != CFBooleanGetTypeID(),n.doubleValue.isFinite,l.doubleValue.isFinite,
        n.doubleValue==n.doubleValue.rounded(),l.doubleValue==l.doubleValue.rounded(),n.doubleValue>=0,l.doubleValue>=1,
        n.doubleValue<=Double(texts[0].text.utf16.count),l.doubleValue<=Double(texts[0].text.utf16.count) else{throw FormError.invalid("Choose a nonempty integer UTF-16 optical-sizing range.")}
      let r=NSRange(location:n.intValue,length:l.intValue),text=texts[0].text as NSString
      func boundary(_ i:Int)->Bool {i==0 || i==text.length || !(0xD800...0xDBFF).contains(text.character(at:i-1)) || !(0xDC00...0xDFFF).contains(text.character(at:i))}
      guard r.length<=text.length-r.location,boundary(r.location),boundary(NSMaxRange(r)),Range(r,in:texts[0].text) != nil else{throw FormError.invalid("Optical sizing must preserve source character boundaries.")};range=r
    }else{range=nil}
    var candidate=artwork
    for i in candidate.elements.indices where targets.contains(candidate.elements[i].id) && candidate.elements[i].kind=="text" {
      var e=candidate.elements[i]
      if let range {
        let prior=e.textRuns ?? [],edges=Set([0,e.text.utf16.count,range.location,NSMaxRange(range)]+prior.flatMap{[$0.location,$0.location+$0.length]}).sorted()
        e.textRuns=zip(edges,edges.dropFirst()).compactMap{start,end in
          guard end>start else{return nil}
          var run=prior.first{$0.location<=start && $0.location+$0.length>=end} ?? TextStyleCommands.span(e);run.location=start;run.length=end-start
          if start>=range.location,end<=NSMaxRange(range) {let before=run;run.typography.setOpticalSizing(setting);run=TextStyleCommands.recording(run,from:before)}
          return run
        }
      }else {
        var type=e.typography ?? .init();type.setOpticalSizing(setting);e.typography=type
        for r in e.textRuns?.indices ?? 0..<0 {e.textRuns![r].typography.setOpticalSizing(setting)}
      }
      candidate.elements[i]=e
    }
    try validateArtwork(candidate,maxTextCharacters:maxTextCharacters);artwork=candidate
  }
}

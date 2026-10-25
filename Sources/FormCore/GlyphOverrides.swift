import CoreFoundation
import Foundation

/// Named glyphs survive font reordering. Numeric fallbacks require a matching font signature.
public struct FontGlyph: Codable, Equatable, Sendable {
  public var fontName:String
  public var glyphID:Int
  public var glyphName:String?
  public var fontSignature:String
  public init(fontName:String,glyphID:Int,glyphName:String?=nil,fontSignature:String) {
    self.fontName=fontName;self.glyphID=glyphID;self.glyphName=glyphName;self.fontSignature=fontSignature
  }
}

/// Glyph selection belongs to source characters, independently of reusable styles.
public struct GlyphOverride: Codable, Equatable, Identifiable, Sendable {
  public var id=UUID()
  public var location:Int
  public var sourceText:String
  public var glyph:FontGlyph
  public var length:Int {sourceText.utf16.count}
  public var range:NSRange {NSRange(location:location,length:length)}
  public init(location:Int,sourceText:String,glyph:FontGlyph) {
    self.location=location;self.sourceText=sourceText;self.glyph=glyph
  }
}

public enum GlyphCommands {
  public static func validate(_ glyph:FontGlyph) throws {
    guard !glyph.fontName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
      glyph.fontName.count<=200,!glyph.fontName.contains("\0"),(1...65535).contains(glyph.glyphID),
      glyph.glyphName == nil || (!glyph.glyphName!.isEmpty && glyph.glyphName!.count<=256 && !glyph.glyphName!.contains("\0")),
      glyph.fontSignature.utf8.count==64,
      glyph.fontSignature.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) else {
      throw FormError.invalid("Choose an installed font glyph with its name/ID and font signature.")
    }
  }
  private static func validBoundary(_ index:Int,in text:NSString)->Bool {
    index==0 || index==text.length || !(0xD800...0xDBFF).contains(text.character(at:index-1)) || !(0xDC00...0xDFFF).contains(text.character(at:index))
  }
  public static func sourceText(in text:String,range:NSRange) throws -> String {
    let source=text as NSString
    guard range.location>=0,(1...64).contains(range.length),range.location<=source.length,
      range.length<=source.length-range.location,validBoundary(range.location,in:source),validBoundary(NSMaxRange(range),in:source) else {
      throw FormError.invalid("Choose 1–64 source UTF-16 units without splitting a surrogate pair.")
    }
    return source.substring(with:range)
  }
  public static func validate(_ values:[GlyphOverride],text:String) throws {
    guard values.count<=256,Set(values.map(\.id)).count==values.count else {
      throw FormError.invalid("Text supports up to 256 distinct glyph choices.")
    }
    let original=text as NSString
    var end=0
    for choice in values.sorted(by:{$0.location<$1.location}) {
      try validate(choice.glyph)
      guard choice.location>=end,choice.length>0,choice.length<=64,
        choice.location<=original.length,choice.length<=original.length-choice.location,
        validBoundary(choice.location,in:original),validBoundary(choice.location+choice.length,in:original),
        !choice.sourceText.unicodeScalars.contains(where:{[0,9,10,11,12,13,0x85,0x2028,0x2029].contains($0.value)}),
        (original.substring(with:choice.range) as NSString).isEqual(to:choice.sourceText) else {
        throw FormError.invalid("Glyph choices need disjoint source ranges of 1–64 UTF-16 units, without paragraph breaks or tabs.")
      }
      end=choice.location+choice.length
    }
  }
  public static func edit(_ art:inout Artwork,ids:Set<UUID>,arguments:[String:Any]) throws {
    guard !ids.isEmpty,arguments.keys.contains("glyph") else {throw FormError.invalid("Select text and provide a glyph or null to clear its choices.")}
    let targets=art.swatchPaintTargets(for:ids)
    let textIDs=Set(art.elements.filter{targets.contains($0.id) && $0.kind=="text"}.map(\.id))
    guard !textIDs.isEmpty,art.elements.filter({textIDs.contains($0.id)}).allSatisfy({!art.isLocked($0)}) else {
      throw FormError.invalid("Choose unlocked text for glyph editing.")
    }
    let glyph:FontGlyph?
    if arguments["glyph"] is NSNull {glyph=nil}
    else {
      guard let raw=arguments["glyph"] as? [String:Any] else {throw FormError.invalid("Provide glyph metadata from font discovery.")}
      glyph=try JSONDecoder.form.decode(FontGlyph.self,from:JSONSerialization.data(withJSONObject:raw));try validate(glyph!)
    }
    let hasRange=arguments["location"] != nil || arguments["length"] != nil
    var range:NSRange?
    if hasRange {
      guard textIDs.count==1,
        let location=arguments["location"] as? NSNumber,CFGetTypeID(location) != CFBooleanGetTypeID(),
        let length=arguments["length"] as? NSNumber,CFGetTypeID(length) != CFBooleanGetTypeID(),
        location.doubleValue.isFinite,length.doubleValue.isFinite,
        location.doubleValue==location.doubleValue.rounded(),length.doubleValue==length.doubleValue.rounded(),
        (0...20000).contains(location.doubleValue),(1...64).contains(length.doubleValue) else {
        throw FormError.invalid("Choose one text element and an integer UTF-16 glyph range of 1–64 units.")
      }
      range=NSRange(location:location.intValue,length:length.intValue)
    }
    guard glyph==nil || range != nil else {throw FormError.invalid("Applying a glyph needs a source location and length.")}
    var candidate=art
    for i in candidate.elements.indices where textIDs.contains(candidate.elements[i].id) {
      var e=candidate.elements[i]
      if let range {
        let original=e.text as NSString
        _ = try sourceText(in:e.text,range:range)
        var values=e.glyphOverrides ?? []
        let previous=values.first{$0.range==range}
        values.removeAll{NSIntersectionRange($0.range,range).length>0}
        if let glyph {
          var value=GlyphOverride(location:range.location,sourceText:original.substring(with:range),glyph:glyph)
          if let previous,previous.sourceText==value.sourceText,previous.glyph==glyph {value.id=previous.id}
          values.append(value)
        }
        e.glyphOverrides=values.isEmpty ? nil : values.sorted{$0.location<$1.location}
      } else {e.glyphOverrides=nil}
      candidate.elements[i]=e
    }
    try validateArtwork(candidate);art=candidate
  }
}

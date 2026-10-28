import AppKit
import CoreText
import FormCore

public struct OpticalFontAxis:Equatable,Sendable {
  public var minimum:Double,defaultValue:Double,maximum:Double
}
@MainActor public enum OpticalTypography {
  public nonisolated static let resolvedFaceKey=NSAttributedString.Key("studio.form.opticalResolvedFace")
  public static func axis(_ fontName:String)->OpticalFontAxis? {
    guard let font=NSFont(name:fontName,size:12),let axes=CTFontCopyVariationAxes(font as CTFont) as? [[String:Any]],
      let raw=axes.first(where:{($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue==OpticalSizing.axisID}),
      let minimum=raw[kCTFontVariationAxisMinimumValueKey as String] as? Double,
      let defaultValue=raw[kCTFontVariationAxisDefaultValueKey as String] as? Double,
      let maximum=raw[kCTFontVariationAxisMaximumValueKey as String] as? Double,
      minimum.isFinite,maximum.isFinite,defaultValue.isFinite,minimum<=defaultValue,defaultValue<=maximum else{return nil}
    return .init(minimum:minimum,defaultValue:defaultValue,maximum:maximum)
  }
  public static func validateEdit(_ value:OpticalSizing?,fontName:String)throws {
    guard let value else{return};try value.validate()
    guard NSFont(name:fontName,size:12) != nil,let axis=axis(fontName) else{throw FormError.invalid("\(fontName) does not expose a supported optical-size axis. Choose a supported installed face before assigning optical sizing.")}
    if value.mode == .explicit,let points=value.points,!(axis.minimum...axis.maximum).contains(points) {throw FormError.invalid("Optical size for \(fontName) must be from \(axis.minimum) to \(axis.maximum) pt; the edited value was not clamped.")}
  }
  public static func effectiveCoordinate(_ type:Typography,nominalPoints:Double)->Double? {
    guard let axis=axis(type.fontName) else{return nil}
    let font=TypographyEngine.font(type,size:nominalPoints)
    return (CTFontCopyVariation(font as CTFont) as? [NSNumber:NSNumber])?[NSNumber(value:OpticalSizing.axisID)]?.doubleValue ?? axis.defaultValue
  }
  public static func warning(_ type:Typography)->String? {
    guard let policy=type.opticalSizing else{return nil}
    guard let axis=axis(type.fontName) else{return "Retained optical-sizing policy is not offered by \(type.fontName). The original assignment is preserved."}
    if policy.mode == .explicit,let points=policy.points,!(axis.minimum...axis.maximum).contains(points) {return "Retained optical size \(points) pt is outside \(type.fontName)'s \(axis.minimum)–\(axis.maximum) pt range. The source is preserved; the preview uses the supported boundary."}
    return nil
  }
  public static func font(_ type:Typography,size:Double,nominalPoints:Double)->NSFont {
    var baseType=type;baseType.opticalSizing=nil;baseType.variations.removeValue(forKey:OpticalSizing.axisID)
    let base=TypographyEngine.font(baseType,size:size)
    guard let policy=type.opticalSizing,let axis=axis(type.fontName) else{return base}
    let requested:Double
    switch policy.mode {case .automatic:requested=nominalPoints;case .explicit:requested=policy.points ?? nominalPoints;case .none:requested=axis.defaultValue}
    let coordinate=min(axis.maximum,max(axis.minimum,requested))
    var axes=baseType.variations;axes[OpticalSizing.axisID]=coordinate
    var attrs:[NSFontDescriptor.AttributeName:Any]=[.variation:Dictionary(uniqueKeysWithValues:axes.map{(NSNumber(value:$0.key),NSNumber(value:$0.value))})]
    let key=NSFontDescriptor.AttributeName(rawValue:kCTFontOpticalSizeAttribute as String)
    // Named instances can drop this attribute unless an agreeing axis value is
    // supplied. Source dictionaries stay untouched; these are resolved values.
    attrs[key]=policy.mode == .none ? "none" as Any:NSNumber(value:requested)
    return NSFont(descriptor:base.fontDescriptor.addingAttributes(attrs),size:size) ?? base
  }
  public static func validateAssigned(_ element:ArtworkElement,value:OpticalSizing?)throws {
    guard element.kind=="text" else{return}
    try validateEdit(value,fontName:element.typography?.fontName ?? Typography().fontName)
    for run in element.textRuns ?? [] {try validateEdit(value,fontName:run.typography.fontName)}
  }
  public static func validateCommand(_ artwork:Artwork,ids:Set<UUID>,arguments:[String:Any])throws {
    let value=try OpticalCommands.setting(arguments);guard value != nil else{return}
    let targets=artwork.swatchPaintTargets(for:ids)
    for e in artwork.elements where targets.contains(e.id) && e.kind=="text" {
      let range:NSRange
      if let location=arguments["location"] as? NSNumber,let length=arguments["length"] as? NSNumber {range = .init(location:location.intValue,length:length.intValue)}
      else {range = .init(location:0,length:e.text.utf16.count)}
      let runs=e.textRuns ?? [],edges=Set([range.location,NSMaxRange(range)]+runs.flatMap{[max(range.location,min(NSMaxRange(range),$0.location)),max(range.location,min(NSMaxRange(range),$0.location+$0.length))]}).sorted()
      if range.length==0 {try validateEdit(value,fontName:e.typography?.fontName ?? Typography().fontName)}
      for (start,end) in zip(edges,edges.dropFirst()) where end>start {
        let type=runs.first{$0.location<=start && $0.location+$0.length>=end}?.typography ?? e.typography ?? .init()
        try validateEdit(value,fontName:type.fontName)
      }
    }
  }
  public static func requiresOutlines(_ e:ArtworkElement)->Bool {
    e.typography?.opticalSizing != nil || e.textRuns?.contains{$0.typography.opticalSizing != nil}==true
      || e.storyFrame?.resolved.map{$0.story.typography?.opticalSizing != nil || $0.story.textRuns?.contains{$0.typography.opticalSizing != nil}==true}==true
  }

  public static func warnings(_ artwork:Artwork)->[String] {
    var types:[Typography]=[]
    for e in artwork.elements where e.kind=="text" && e.hidden != true {
      let source=e.storyFrame?.resolved?.story.sourceElement ?? e
      if let type=source.typography {types.append(type)};types += source.textRuns?.map(\.typography) ?? []
    }
    return Array(Set(types.compactMap(warning))).sorted()
  }

}

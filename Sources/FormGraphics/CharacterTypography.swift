import AppKit
import FormCore

/// Transient derivation is separate from authored font size and manual baseline.
@MainActor public enum CharacterTypography {
  public nonisolated static let seedKey=NSAttributedString.Key("studio.form.positionSource")
  public nonisolated static let resolutionKey=NSAttributedString.Key("studio.form.positionResolution")
  public nonisolated static let resolvedFontKey=NSAttributedString.Key("studio.form.positionResolvedFont")
  public nonisolated static let sourceFontKey=NSAttributedString.Key("studio.form.positionNominalFont")
  public nonisolated static let markerFontKey=NSAttributedString.Key("studio.form.positionMarkerFont")
  public nonisolated static let markerBaselineKey=NSAttributedString.Key("studio.form.positionMarkerBaseline")
  private static let keys:[NSAttributedString.Key]=[resolutionKey,resolvedFontKey,sourceFontKey,markerFontKey,markerBaselineKey]
  private struct Seed:Codable,Equatable {var nominalPoints:Double,factor:Double}
  public struct Resolution:Codable,Equatable {
    public var position:CharacterPosition,method:String,reason:String
    public var nominalPoints:Double,factor:Double,manualBaseline:Double,scale:Double,offsetPoints:Double,displayBaseline:Double
  }
  private struct Unit {var range:NSRange,type:Typography,seed:Seed,baseline:Double}
  public static func seed(size:Double,factor:Double)->Data? {try? JSONEncoder.form.encode(Seed(nominalPoints:size,factor:factor))}
  public static func resolution(_ attrs:[NSAttributedString.Key:Any])->Resolution? {
    guard let data=attrs[resolutionKey] as? Data,data.count<=8192,let r=try? JSONDecoder.form.decode(Resolution.self,from:data),r.nominalPoints.isFinite,(0.1...10000).contains(r.nominalPoints),r.factor.isFinite,(r.factor==1 || abs(r.factor-1/TypographyEngine.pointsPerMM)<1e-12),r.scale.isFinite,(r.scale==1 || r.scale==0.65),r.manualBaseline.isFinite,abs(r.manualBaseline)<=100000,r.offsetPoints.isFinite,r.displayBaseline.isFinite else{return nil};return r
  }
  private static func context(_ attrs:[NSAttributedString.Key:Any])->Seed? {
    guard let data=attrs[seedKey] as? Data,data.count<=1024,let seed=try? JSONDecoder.form.decode(Seed.self,from:data),seed.nominalPoints.isFinite,(0.1...10000).contains(seed.nominalPoints),seed.factor.isFinite,(seed.factor==1 || abs(seed.factor-1/TypographyEngine.pointsPerMM)<1e-12) else{return nil};return seed
  }
  public static func sourcePointSize(in attrs:[NSAttributedString.Key:Any])->Double? {context(attrs)?.nominalPoints}
  public static func sourceBaseline(in attrs:[NSAttributedString.Key:Any])->Double? {
    guard let seed=context(attrs),let baseline=attrs[.baselineOffset] as? NSNumber else{return nil}
    let type=TypographyEngine.assignedTypography(in:attrs)
    if let type,abs(baseline.doubleValue-type.baseline*seed.factor)<1e-9 {return type.baseline}
    return baseline.doubleValue/seed.factor
  }
  public static func invalidate(){CharacterCoverage.invalidate()}
  public static var diagnostics:[String:Any] {CharacterCoverage.diagnostics}
  private static func positionedType(_ type:Typography,selector:Int)->Typography {
    var t=type;t.characterPosition=nil;t.features[10]=selector;t.featureSelections?.removeValue(forKey:10)
    if t.featureSelections?.isEmpty==true {t.featureSelections=nil};return t
  }
  private static func font(_ type:Typography,size:Double,nominal:Double)->NSFont {TypographyEngine.font(type,size:size,opticalPointSize:nominal)}
  /// Reconstruct only source attributes. Unchanged derived values return the exact
  /// authored size/baseline; intentional native size/baseline changes decompose once.
  public static func authored(_ input:NSAttributedString)->NSAttributedString {
    guard input.length>0 else{return input}
    var patches:[(NSRange,[NSAttributedString.Key:Any])]=[]
    input.enumerateAttributes(in:NSRange(location:0,length:input.length)) {attrs,range,_ in
      guard let record=resolution(attrs),let actual=attrs[.font] as? NSFont else{return}
      var values=attrs
      let expected=attrs[resolvedFontKey] as? NSFont,unchanged=expected?.isEqual(actual)==true
      let nominal=unchanged ? record.nominalPoints:actual.pointSize/(record.factor*record.scale)
      let current=(attrs[.baselineOffset] as? NSNumber)?.doubleValue ?? record.displayBaseline
      let baseline=abs(current-record.displayBaseline)<1e-9 ? record.manualBaseline:record.manualBaseline+(current-record.displayBaseline)/record.factor
      let type=TypographyEngine.assignedTypography(in:attrs) ?? .init()
      if unchanged,let original=attrs[sourceFontKey] as? NSFont {values[.font]=original}
      else {
        // Remove only derived vertical forms; retain the authored dormant selectors.
        var feature=(actual.fontDescriptor.object(forKey:.featureSettings) as? [[NSFontDescriptor.FeatureKey:Any]] ?? []).filter{($0[.typeIdentifier] as? NSNumber)?.intValue != 10}
        feature += type.resolvedFeatureSelections.filter{$0.type==10}.map{[.typeIdentifier:$0.type,.selectorIdentifier:$0.selector]}
        values[.font]=NSFont(descriptor:actual.fontDescriptor.addingAttributes([.featureSettings:feature]),size:nominal*record.factor) ?? actual
      }
      values[.baselineOffset]=baseline*record.factor;values[seedKey]=seed(size:nominal,factor:record.factor)
      for key in keys {values.removeValue(forKey:key)}
      patches.append((range,values))
    }
    guard !patches.isEmpty else{return input}
    let result=NSMutableAttributedString(attributedString:input);for(range,attrs)in patches {result.setAttributes(attrs,range:range)};return result
  }
  /// Called after locale/case display mapping, before exact glyph-info assignment.
  public static func resolved(_ input:NSAttributedString,exactRanges:[NSRange]=[])->NSAttributedString {
    guard input.length>0 else{return input}
    let source=authored(input);var units:[Unit]=[]
    source.enumerateAttributes(in:NSRange(location:0,length:source.length)) {attrs,range,_ in
      guard let type=TypographyEngine.assignedTypography(in:attrs),type.characterPosition != nil,let face=attrs[.font] as? NSFont else{return}
      let seed=context(attrs) ?? Seed(nominalPoints:face.pointSize,factor:1)
      let baseline=sourceBaseline(in:attrs) ?? type.baseline
      if let last=units.last,NSMaxRange(last.range)==range.location,last.type==type,last.seed==seed,last.baseline==baseline {units[units.count-1].range.length+=range.length}
      else {units.append(Unit(range:range,type:type,seed:seed,baseline:baseline))}
    }
    guard !units.isEmpty else{return source}
    let result=NSMutableAttributedString(attributedString:source);var budget=CharacterCoverage.maximumCallClusters
    for unit in units {
      let position=unit.type.characterPosition!,points=unit.seed.nominalPoints,factor=unit.seed.factor
      let baseType=positionedType(unit.type,selector:0),base=font(baseType,size:points,nominal:points),text=(source.string as NSString).substring(with:unit.range)
      var method="normal",reason="Explicit normal position; authored feature assignments remain stored.",scale=1.0,offset=0.0,displayType=baseType
      if position != .normal {
        let selector=position == .superscript ? 1:2,candidateType=positionedType(unit.type,selector:selector),candidate=font(candidateType,size:points,nominal:points)
        let check:CharacterCoverage.Result
        if exactRanges.contains(where:{NSIntersectionRange($0,unit.range).length>0}) {check = .init(complete:false,reason:"An exact glyph choice keeps its original identity; position uses geometry instead of substituting a glyph.")}
        else if NSFont(name:unit.type.fontName,size:12)==nil {check = .init(complete:false,reason:"The assigned font is unavailable. Its original assignment is retained; geometry uses the existing preview fallback.")}
        else if budget<=0 {check = .init(complete:false,reason:"The bounded font-coverage call budget was reached; the complete span uses geometry.")}
        else if !CharacterCoverage.offers(base,type:10,selector:selector) {check = .init(complete:false,reason:"The selected font does not offer this position form; the whole span uses geometry.")}
        else if !CharacterPositionCommands.isCompleteRange(unit.range,in:source.string) {check = .init(complete:false,reason:"Mixed source styling crosses a grapheme boundary; geometry retains the original styling and complete source.")}
        else {check=CharacterCoverage.complete(text,base:base,candidate:candidate,language:unit.type.language ?? unit.type.inheritedLanguage,ligatures:unit.type.ligatures,budget:&budget)}
        if check.complete {method="font-authored";displayType=candidateType;reason=check.reason}
        else {method="geometric-fallback-v1";scale=position.geometricScale;offset=points*position.geometricOffsetEm;reason=check.reason}
      }
      let display=font(displayType,size:points*scale*factor,nominal:points*scale)
      let original=font(unit.type,size:points*factor,nominal:points)
      let marker=font(baseType,size:points*factor,nominal:points)
      let record=Resolution(position:position,method:method,reason:reason,nominalPoints:points,factor:factor,manualBaseline:unit.baseline,scale:scale,offsetPoints:offset,displayBaseline:(unit.baseline+offset)*factor)
      let patch:[NSAttributedString.Key:Any]=[.font:display,.baselineOffset:record.displayBaseline,resolutionKey:(try? JSONEncoder.form.encode(record)) ?? Data(),resolvedFontKey:display,sourceFontKey:original,markerFontKey:marker,markerBaselineKey:offset*factor,seedKey:seed(size:points,factor:factor) ?? Data()]
      result.addAttributes(patch,range:unit.range)
    }
    return result
  }
  public static func withoutRuntime(_ input:NSAttributedString)->NSAttributedString {
    let sourceKeys=[resolutionKey,resolvedFontKey,sourceFontKey,seedKey]
    var found=false;input.enumerateAttributes(in:NSRange(location:0,length:input.length)){attrs,_,stop in if sourceKeys.contains(where:{attrs[$0] != nil}){found=true;stop.pointee=true}};guard found else{return input}
    // Marker font/baseline are render inputs, also needed by physical output.
    let result=NSMutableAttributedString(attributedString:input);for key in sourceKeys {result.removeAttribute(key,range:NSRange(location:0,length:result.length))};return result
  }
  public static func requiresOutlines(_ e:ArtworkElement)->Bool {
    let source=e.storyFrame?.resolved?.story.sourceElement ?? e
    return source.typography?.characterPosition != nil || source.textRuns?.contains{$0.typography.characterPosition != nil}==true
  }
  public static func records(in source:NSAttributedString)->[(NSRange,Resolution)] {
    var result:[(NSRange,Resolution)]=[];source.enumerateAttributes(in:NSRange(location:0,length:source.length)){attrs,range,_ in if let r=resolution(attrs){result.append((range,r))}};return result
  }
  public static func warnings(_ artwork:Artwork)->[String] {
    var result=Set<String>(),count=0
    for e in artwork.elements where e.kind=="text" && e.hidden != true && requiresOutlines(e) {
      count+=1;guard count<=256 else{result.insert("Character-position report reached its 256-source review bound; source/output content was not truncated.");break}
      let source=e.storyFrame?.resolved?.story.sourceElement ?? e
      for(_,record)in records(in:TypographyEngine.attributed(source,preservingSource:true)) where record.method != "normal" {result.insert(e.title+": "+record.method+". "+record.reason)}
    }
    return result.sorted()
  }
}

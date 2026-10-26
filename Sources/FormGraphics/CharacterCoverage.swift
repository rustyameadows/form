import AppKit
import CoreText
import FormCore

/// Conservative, bounded feature coverage. A feature declaration alone is not coverage.
@MainActor enum CharacterCoverage {
  static let maximumUnitUTF16=4096,maximumClusters=256,maximumClusterUTF16=128,maximumCallClusters=2048
  struct Result {var complete:Bool;var reason:String;var limited=false}
  private final class Key:NSObject {
    let text:String,base:NSFont,candidate:NSFont,language:String?,ligatures:Int,eligibleCase:Int
    init(_ text:String,_ base:NSFont,_ candidate:NSFont,_ language:String?,_ ligatures:Int,_ eligibleCase:Int) {self.text=text;self.base=base;self.candidate=candidate;self.language=language;self.ligatures=ligatures;self.eligibleCase=eligibleCase}
    override var hash:Int {text.hashValue ^ base.hash ^ candidate.hash ^ ligatures ^ eligibleCase ^ (language?.hashValue ?? 0)}
    override func isEqual(_ other:Any?)->Bool {guard let other=other as? Key else{return false};return text==other.text && base.isEqual(other.base) && candidate.isEqual(other.candidate) && language==other.language && ligatures==other.ligatures && eligibleCase==other.eligibleCase}
  }
  private final class Entry {let value:Result;init(_ value:Result){self.value=value}}
  private static let cache:NSCache<Key,Entry> = {let c=NSCache<Key,Entry>();c.countLimit=512;c.totalCostLimit=2_000_000;return c}()
  private(set) static var builds=0,hits=0,clusterChecks=0
  static func invalidate(){cache.removeAllObjects()}
  static var diagnostics:[String:Any] {["coverage_builds":builds,"coverage_hits":hits,"coverage_cluster_checks":clusterChecks,"coverage_cache_limit":512,"coverage_cache_bytes":2_000_000]}
  private struct Shape:Equatable {var glyphs:[Int]=[],positions:[Point2]=[],advances:[Double]=[],bounds:[Double]=[]}
  private static func shape(_ string:String,font:NSFont,language:String?,ligatures:Int)->Shape? {
    var attrs:[NSAttributedString.Key:Any]=[.font:font,.ligature:ligatures]
    if let language {attrs[LanguageHyphenation.languageKey]=language}
    let line=CTLineCreateWithAttributedString(NSAttributedString(string:string,attributes:attrs));var result=Shape()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
      let count=CTRunGetGlyphCount(run);guard count<=512 else{return nil}
      let actual=(CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
      guard CTFontCopyPostScriptName(actual) as String==font.fontName else{return nil}
      var glyphs=[CGGlyph](repeating:0,count:count),points=[CGPoint](repeating:.zero,count:count),advances=[CGSize](repeating:.zero,count:count)
      CTRunGetGlyphs(run,CFRange(),&glyphs);CTRunGetPositions(run,CFRange(),&points);CTRunGetAdvances(run,CFRange(),&advances)
      guard !glyphs.contains(0),points.allSatisfy({$0.x.isFinite && $0.y.isFinite}),advances.allSatisfy({$0.width.isFinite && $0.height.isFinite}) else{return nil}
      result.glyphs += glyphs.map(Int.init);result.positions += points.map{Point2($0.x,$0.y)};result.advances += advances.flatMap{[$0.width,$0.height]}
      for var glyph in glyphs {let b=CTFontGetBoundingRectsForGlyphs(actual,.horizontal,&glyph,nil,1);result.bounds += [b.minX,b.minY,b.width,b.height]}
    }
    return result
  }
  static func offers(_ font:NSFont,type:Int,selector:Int)->Bool {
    (CTFontCopyFeatures(font as CTFont) as? [[String:Any]] ?? []).contains {group in
      guard (group[kCTFontFeatureTypeIdentifierKey as String] as? NSNumber)?.intValue==type else{return false}
      return (group[kCTFontFeatureTypeSelectorsKey as String] as? [[String:Any]] ?? []).contains{($0[kCTFontFeatureSelectorIdentifierKey as String] as? NSNumber)?.intValue==selector}
    }
  }
  static func complete(_ text:String,base:NSFont,candidate:NSFont,language:String?,ligatures:Int,budget:inout Int,eligibleCase:Int=0)->Result {
    guard text.utf16.count<=maximumUnitUTF16 else{return .init(complete:false,reason:"The complete shaping span exceeds the 4,096 UTF-16 coverage budget; geometric fallback keeps every source character.",limited:true)}
    let key=Key(text,base,candidate,language,ligatures,eligibleCase)
    if let entry=cache.object(forKey:key){hits+=1;return entry.value}
    builds+=1;var checked=0,missing:[String]=[],result:Result?
    for character in text {
      let cluster=String(character)
      if eligibleCase==1,!cluster.unicodeScalars.contains(where:CharacterSet.lowercaseLetters.contains) {continue}
      if eligibleCase==2,!cluster.unicodeScalars.contains(where:CharacterSet.uppercaseLetters.contains) {continue}
      if cluster.unicodeScalars.allSatisfy({CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)}){continue}
      guard checked<maximumClusters,budget>0,cluster.utf16.count<=maximumClusterUTF16 else {result = .init(complete:false,reason:"The complete-grapheme coverage work limit was reached; the whole span uses geometry without truncation.",limited:true);break}
      checked+=1;budget-=1;clusterChecks+=1
      guard let original=shape(cluster,font:base,language:language,ligatures:ligatures),let changed=shape(cluster,font:candidate,language:language,ligatures:ligatures),original != changed else {
        if missing.count<8 {missing.append(cluster)}
        continue
      }
    }
    let value=result ?? Result(complete:missing.isEmpty,reason:missing.isEmpty ? "Complete non-whitespace cluster coverage by the selected font.":"No complete font-form coverage for: "+missing.joined(separator:" ")+". The whole shaping span uses geometry.")
    // Do not cache a result that depends on another span consuming this call's budget.
    if result==nil {cache.setObject(Entry(value),forKey:key,cost:256+text.utf16.count*2)}
    return value
  }
}

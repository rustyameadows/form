import FormCore
import FormGraphics
import SwiftUI

struct CharacterFontVariant:Identifiable {var id:Int,name:String}
struct CharacterPositionControls:View {
  @ObservedObject var session:ArtworkSession
  var fontVariants:[CharacterFontVariant]=[]
  @State private var error=""
  private var types:[Typography] {session.opticalInspectionTypes}
  private func choice(_ type:Typography)->String {
    if let mode=type.characterPosition{return mode.rawValue}
    let values=type.featureSelections?[10] ?? type.features[10].map{[$0]} ?? []
    guard let selector=values.sorted().last,selector != 0 else{return "normal"}
    return "font:\(selector)"
  }
  private var choices:Set<String> {Set(types.map(choice))}
  private var first:Typography {types.first ?? session.inspectedTypography}
  private var variants:[CharacterFontVariant] {fontVariants.filter{![0,1,2].contains($0.id)}}
  private var legacy:String? {let value=choice(first);return value.hasPrefix("font:") ? value:nil}
  private var records:[CharacterTypography.Resolution] {session.characterPositionInspection}
  var body:some View {
    VStack(alignment:.leading,spacing:5) {
      Picker("Position",selection:Binding(get:{choices.count>1 ? "mixed":choice(first)},set:{value in
        do {
          if let mode=CharacterPosition(rawValue:value) {try session.characterPosition(mode)}
          else if value.hasPrefix("font:"),let selector=Int(value.dropFirst(5)) {
            session.typography{$0.characterPosition=nil;$0.resetFeature(10);$0.features[10]=selector}
          }
          error=""
        }catch{self.error=error.localizedDescription}
      })) {
        if choices.count>1 {Text("Mixed").tag("mixed").disabled(true)}
        if let legacy,!variants.contains(where:{"font:\($0.id)"==legacy}) {Text((fontVariants.first{"font:\($0.id)"==legacy}?.name ?? "Retained font form")+" (font only)").tag(legacy).disabled(true)}
        ForEach(CharacterPosition.allCases,id:\.rawValue){Text($0.displayName).tag($0.rawValue)}
        ForEach(variants){Text($0.name).tag("font:\($0.id)")}
      }.font(.system(size:10)).accessibilityIdentifier("character-position")
      let methods=Set(records.map(\.method))
      if methods.contains("geometric-fallback-v1") {
        Text(methods.contains("font-authored") ? "Font forms and geometric fallback across the selection.":"Geometric fallback · 65% size; nominal size and manual baseline stay unchanged.").font(.system(size:9)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      }else if methods.contains("font-authored") {Text("Font-authored forms · original words and nominal size retained.").font(.system(size:9)).foregroundStyle(Palette.secondary)}
      ForEach(Array(Set(records.filter{$0.method=="geometric-fallback-v1"}.map(\.reason))).sorted().prefix(2),id:\.self){Text($0).font(.system(size:9)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)}
      if !error.isEmpty {Text(error).font(.system(size:9)).foregroundStyle(Palette.ink).fixedSize(horizontal:false,vertical:true)}
    }
  }
}

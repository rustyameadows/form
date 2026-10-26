import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct OpticalSizingControls:View {
  @ObservedObject var session:ArtworkSession
  @State private var error=""
  private var types:[Typography] {session.opticalInspectionTypes}
  private var first:Typography {types.first ?? session.inspectedTypography}
  private func choice(_ type:Typography)->String {type.opticalSizing?.mode.rawValue ?? (type.variations[OpticalSizing.axisID]==nil ? "default":"stored")}
  private var choices:Set<String> {Set(types.map(choice))}
  private var isMixed:Bool {Set(types.map{type in
    let mode=choice(type)
    return mode+":"+(mode=="explicit" ? String(describing:type.opticalSizing?.points):mode=="stored" ? String(describing:type.variations[OpticalSizing.axisID]):"")
  }).count>1}
  private var axes:[OpticalFontAxis] {types.compactMap{OpticalTypography.axis($0.fontName)}}
  private var allSupported:Bool {!types.isEmpty && axes.count==types.count}
  private var commonRange:ClosedRange<Double>? {
    guard allSupported,let minimum=axes.map(\.minimum).max(),let maximum=axes.map(\.maximum).min(),minimum<=maximum else{return nil}
    return minimum...maximum
  }
  private var value:Double {first.opticalSizing?.points ?? first.variations[OpticalSizing.axisID] ?? OpticalTypography.axis(first.fontName)?.defaultValue ?? session.inspectedSize}
  private var warnings:[String] {Array(Set(types.compactMap{OpticalTypography.warning($0)})).sorted()}
  private func apply(_ value:OpticalSizing?)throws {do {try session.opticalSizing(value);error=""}catch {self.error=error.localizedDescription;throw error}}
  var body:some View {
    VStack(alignment:.leading,spacing:7) {
      Picker("Optical size",selection:Binding(get:{isMixed ? "mixed":choice(first)},set:{mode in
        do {
          switch mode {
          case "default":try apply(nil)
          case "automatic":try apply(.init(.automatic))
          case "none":try apply(.init(.none))
          case "explicit":
            guard let range=commonRange else{throw FormError.invalid("The selected fonts have no shared explicit optical-size range.")}
            let resolved=OpticalTypography.effectiveCoordinate(first,nominalPoints:session.inspectedSize) ?? value
            let initial=min(range.upperBound,max(range.lowerBound,resolved));try apply(.init(.explicit,points:initial))
          default:break
          }
        }catch {self.error=error.localizedDescription}
      })) {
        if isMixed {Text("Mixed").tag("mixed").disabled(true)}
        if choices.contains("stored") {Text("Stored axis").tag("stored").disabled(true)}
        Text("Font default").tag("default")
        Text("Automatic").tag("automatic").disabled(!allSupported)
        Text("Explicit").tag("explicit").disabled(commonRange==nil)
        Text("Off").tag("none").disabled(!allSupported)
      }.font(.system(size:10))
      if !isMixed,["explicit","stored"].contains(choice(first)),let range=commonRange {
        ScalarArtworkField("Optical size",value:value,unit:"pt",increment:session.numericIncrement(step:1,range:range)) {points in try apply(.init(.explicit,points:points))}
        if range.lowerBound<range.upperBound {Slider(value:Binding(get:{min(range.upperBound,max(range.lowerBound,value))},set:{points in do{try apply(.init(.explicit,points:points))}catch{}}),in:range,onEditingChanged:{editing in if editing{session.beginGesture()}else{session.endGesture()}}).controlSize(.mini)}
      }
      if let range=commonRange {Text("Supported \(range.lowerBound.formatted())–\(range.upperBound.formatted()) pt · automatic follows document size, independent of zoom.").font(.system(size:9)).foregroundStyle(Palette.secondary)}
      if !allSupported {Text("Some selected fonts do not offer an optical-size axis. Existing assignments stay recorded; choose a supported face or reset to Font default.").font(.system(size:9)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)}
      ForEach(warnings,id:\.self) {Text($0).font(.system(size:9)).foregroundStyle(Palette.accent).fixedSize(horizontal:false,vertical:true)}
      if !error.isEmpty {Text(error).font(.system(size:9)).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
    }
  }
}

extension ArtworkSession {
  var opticalInspectionTypes:[Typography] {
    if let values=canvas?.opticalSizingInspection() {return values}
    var values:[Typography]=[]
    let targets=art.swatchPaintTargets(for:selection)
    for selected in art.elements where targets.contains(selected.id) && selected.kind=="text" {
      let source=(selected.storyFrame?.storyID).flatMap{id in store?.project?.textStories?.first{$0.id==id}?.sourceElement} ?? selected
      values.append(source.typography ?? .init());values += source.textRuns?.map(\.typography) ?? []
    }
    return values.isEmpty ? [inspectedTypography]:values
  }
}

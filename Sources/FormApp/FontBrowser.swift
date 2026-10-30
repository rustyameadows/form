import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct FontBrowserButton: View {
  @ObservedObject var session: ArtworkSession
  @State private var showing = false
  var body: some View {
    Button {
      showing = true
    } label: {
      HStack {
        Text(
          NSFont(name: session.inspectedTypography.fontName, size: 12)?.familyName
            ?? session.inspectedTypography.fontName
        ).lineLimit(1)
        Spacer()
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
      }.font(InspectorStyle.labelFont).padding(.horizontal, 9).frame(height: InspectorStyle.controlHeight)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: InspectorStyle.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: InspectorStyle.controlRadius).strokeBorder(Palette.line.opacity(0.7)).allowsHitTesting(false))
    }.buttonStyle(.plain).popover(isPresented: $showing) { FontBrowser(session: session) }
  }
}
struct FontBrowser: View {
  @ObservedObject var session:ArtworkSession
  var onChoose:((String)->Void)?
  @Environment(\.dismiss) private var dismiss
  @StateObject private var preferences:FontLibraryPreferences
  init(session:ArtworkSession,onChoose:((String)->Void)?=nil) {
    self.session=session;self.onChoose=onChoose
    _preferences=StateObject(wrappedValue:session.store?.fontLibraryPreferences ?? .environment())
  }
  @State private var query=""
  @State private var sample=FontLibraryCatalog.defaultPreview
  @State private var favoriteOnly=false
  @State private var showingUsage=false
  @State private var fontRevision=0
  private var faces:[InstalledFontFace] {
    _ = fontRevision
    let all=FontLibraryCatalog.search(query).filter{!favoriteOnly || preferences.favorite($0)}
    guard query.isEmpty,!favoriteOnly else{return all}
    let ranks=Dictionary(uniqueKeysWithValues:preferences.recent.enumerated().map{($0.element,$0.offset)})
    return all.enumerated().sorted {a,b in
      let left=ranks[a.element.name] ?? Int.max,right=ranks[b.element.name] ?? Int.max
      return left==right ? a.offset<b.offset:left<right
    }.map(\.element)
  }
  var body:some View {
    VStack(spacing:12) {
      HStack { SectionLabel("FONTS"); Spacer(); AppCloseButton("Close fonts", keyEquivalent: "\u{1b}") { dismiss() } }
      InspectorDivider()
      HStack {
        TextField("Search family, style or face",text:$query).textFieldStyle(InspectorTextFieldStyle())
        Button {favoriteOnly.toggle()} label:{Image(systemName:favoriteOnly ? "star.fill":"star")}
          .buttonStyle(.plain).help("Show favorite font faces")
      }
      TextField("Preview text",text:$sample).textFieldStyle(InspectorTextFieldStyle())
        .onChange(of:sample) {_,value in if value.count>128 {sample=String(value.prefix(128))}}
      HStack {SectionLabel("FONT FACES ON THIS MAC");Spacer();Text(faces.count == 1 ? "1 face":"\(faces.count) faces").font(.system(size:9)).foregroundStyle(Palette.secondary)}
      ScrollView {
        LazyVStack(spacing:3) {
          ForEach(faces) {face in
            HStack(spacing:5) {
              Button {
                if let onChoose {onChoose(face.name)} else{session.chooseFont(face.name)}
                dismiss()
              } label:{
                VStack(alignment:.leading,spacing:4) {
                  HStack {
                    Text(face.family+" · "+face.style).font(.system(size:10)).foregroundStyle(Palette.secondary)
                    if preferences.recent.contains(face.name) {Image(systemName:"clock").font(.system(size:8)).foregroundStyle(Palette.secondary)}
                    Spacer()
                    if session.inspectedTypography.fontName==face.name {Image(systemName:"checkmark").font(.system(size:9)).foregroundStyle(Palette.accent)}
                  }
                  if let font=FontLibraryCatalog.preview(face.name) {
                    let preview=FontLibraryCatalog.previewText(sample,font:font)
                    Text(preview.text).font(Font(font)).lineLimit(1).foregroundStyle(Palette.ink)
                    if preview.usesFallback {Text("Some preview characters use system fallback").font(.system(size:8)).foregroundStyle(Palette.secondary)}
                  }
                  else {Text("Unavailable").font(.system(size:11)).foregroundStyle(Palette.secondary)}
                  Text(face.name).font(.system(size:8,design:.monospaced)).foregroundStyle(Palette.secondary).lineLimit(1)
                }.padding(10).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
              }.buttonStyle(.plain)
              Button {preferences.toggle(face)} label:{Image(systemName:preferences.favorite(face) ? "star.fill":"star").font(.system(size:11))}
                .buttonStyle(.plain).foregroundStyle(preferences.favorite(face) ? Palette.accent:Palette.secondary)
                .help("Favorite \(face.name)").padding(.trailing,12)
            }.background(.white.opacity(0.6),in:RoundedRectangle(cornerRadius:6))
          }
          if faces.isEmpty {Text("No matching installed faces.").font(.system(size:12)).foregroundStyle(Palette.secondary).padding(20)}
        }
      }
      if let error=preferences.error {Text(error).font(.system(size:10)).foregroundStyle(Palette.accent)}
      if onChoose==nil {
        Button("Document font usage & replacements…",systemImage:"doc.text.magnifyingglass") {showingUsage=true}
          .buttonStyle(.borderless).font(.system(size:11)).frame(maxWidth:.infinity,alignment:.leading)
      }
    }.padding(18).frame(width:400,height:530).background(Palette.paper)
      .onReceive(NotificationCenter.default.publisher(for:NSFont.fontSetChangedNotification)) {_ in FontLibraryCatalog.invalidate();fontRevision+=1}
      .sheet(isPresented:$showingUsage) {DocumentFontsPanel(session:session)}
  }
}

private struct FontAxis: Identifiable {
  var id: Int, name: String, minimum: Double, maximum: Double, defaultValue: Double
  init?(_ raw: [String: Any]) {
    guard let id = raw["id"] as? Int, let name = raw["name"] as? String,
      let min = raw["minimum"] as? Double, let max = raw["maximum"] as? Double,
      let value = raw["default"] as? Double, min < max
    else { return nil }
    self.id = id
    self.name = name
    minimum = min
    maximum = max
    defaultValue = value
  }
}
private struct FontFeature: Identifiable {
  struct Choice: Identifiable { var id: Int, name: String }
  var id: Int, name: String, choices: [Choice], exclusive: Bool
  init?(_ raw: [String: Any]) {
    guard let id = raw["id"] as? Int, let name = raw["name"] as? String else { return nil }
    self.id = id
    self.name = name
    exclusive = raw["exclusive"] as? Bool ?? true
    choices = (raw["selectors"] as? [[String: Any]] ?? []).compactMap { v in
      guard let id = v["id"] as? Int, let name = v["name"] as? String else { return nil }
      return .init(id: id, name: name)
    }
  }
}
struct FontFeaturesInspector: View {
  @ObservedObject var session: ArtworkSession
  var details: [String: Any] { FontCatalog.details(session.inspectedTypography.fontName) }
  private var axes: [FontAxis] {
    (details["axes"] as? [[String: Any]] ?? []).compactMap(FontAxis.init)
  }
  private var features: [FontFeature] {
    (details["features"] as? [[String: Any]] ?? []).compactMap(FontFeature.init)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CharacterPositionControls(session:session,fontVariants:features.first{$0.id==10}?.choices.map{CharacterFontVariant(id:$0.id,name:$0.name)} ?? [])
      if axes.contains(where:{$0.id==OpticalSizing.axisID}) || session.opticalInspectionTypes.contains(where:{$0.opticalSizing != nil || $0.variations[OpticalSizing.axisID] != nil}) {OpticalSizingControls(session:session)}
      if axes.contains(where:{$0.id != OpticalSizing.axisID}) {
        DisclosureGroup("Variable font axes") {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(axes.filter{$0.id != OpticalSizing.axisID}) { axis in
              VStack(alignment: .leading, spacing: 5) {
                HStack {
                  Text(axis.name).font(.system(size: 10))
                  Spacer()
                  Button("Reset") {
                    session.typography { $0.variations.removeValue(forKey: axis.id) }
                  }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Palette.accent)
                }
                InspectorSlider(
                  value: Binding(
                    get: {
                      min(
                        axis.maximum,
                        max(
                          axis.minimum,
                          session.inspectedTypography.variations[axis.id] ?? axis.defaultValue))
                    }, set: { value in session.typography { $0.variations[axis.id] = value } }),
                  in: axis.minimum...axis.maximum
                ).controlSize(.mini)
                ScalarArtworkField(
                  "Value",
                  value: session.inspectedTypography.variations[axis.id] ?? axis.defaultValue,
                  increment:session.numericIncrement(step:axis.maximum-axis.minimum>=10 ? 1:min(0.01,max(0.000000001,(axis.maximum-axis.minimum)/100)),range:axis.minimum...axis.maximum)
                ) { value in
                  session.typography {
                    $0.variations[axis.id] = min(axis.maximum, max(axis.minimum, value))
                  }
                }
              }
            }
          }.padding(.top, 8)
        }.font(.system(size: 10))
      }
      if !features.isEmpty {
        DisclosureGroup("OpenType features") {
          VStack(alignment: .leading, spacing: 9) {
            Button("Reset font features") {
              session.typography { $0.features = [:]; $0.featureSelections = nil }
            }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Palette.accent)
            ForEach(features.filter{$0.id != 10}) { feature in
              VStack(alignment: .leading, spacing: 3) {
                Text(feature.name).font(.system(size: 9)).foregroundStyle(Palette.secondary)
                if feature.exclusive { Picker(
                  feature.name,
                  selection: Binding(
                    get: { session.inspectedTypography.features[feature.id] ?? -1 },
                    set: { value in
                      session.typography {
                        $0.resetFeature(feature.id)
                        if value == -1 {
                          $0.features.removeValue(forKey: feature.id)
                        } else {
                          $0.features[feature.id] = value
                        }
                      }
                    })
                ) {
                  Text("Font default").tag(-1)
                  ForEach(feature.choices) { Text($0.name).tag($0.id) }
                }.labelsHidden().font(.system(size: 10))
                } else {
                  ForEach(feature.choices.filter { $0.id % 2 == 0 }) { choice in
                    VStack(alignment: .leading, spacing: 3) {
                      Text(choice.name).font(.system(size: 10))
                      Picker(choice.name, selection: Binding(
                        get: {
                          session.inspectedTypography.independentFeature(feature.id, selector: choice.id)
                            .map { $0 ? 1 : 0 } ?? -1
                        },
                        set: { value in
                          session.typography {
                            $0.setIndependentFeature(feature.id, selector: choice.id,
                              value: value == -1 ? nil : value == 1)
                          }
                        })) {
                          Text("Default").tag(-1)
                          Text("On").tag(1)
                          Text("Off").tag(0)
                        }.labelsHidden().inspectorSegmented().controlSize(.mini)
                    }.padding(.vertical, 3)
                  }
                }
              }
            }
          }.padding(.top, 8)
        }.font(.system(size: 10))
      }
      ForEach(session.smallCapWarnings,id:\.self) {Text($0).font(.system(size:9)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)}
    }
  }
}

import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct FontBrowserButton: View {
  @ObservedObject var session: ArtworkSession
  @State private var browsing: FontBrowsingState?
  @State private var exploration: FontBrowsingState?
  var body: some View {
    HStack(spacing: 5) {
      Button {
        browsing = FontBrowsingState(session: session)
      } label: {
        HStack(spacing: 8) {
          Text(NSFont(name: session.inspectedTypography.fontName, size: 12)?.familyName ?? session.inspectedTypography.fontName)
            .font(Font(NSFont(name: session.inspectedTypography.fontName, size: 17) ?? .systemFont(ofSize: 17)))
            .lineLimit(1)
          Spacer(minLength: 0)
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
        }.padding(.horizontal, 10).frame(height: 36).contentShape(Rectangle())
          .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
      }.buttonStyle(.plain).accessibilityLabel("Choose font family").accessibilityIdentifier("font-browser-open")
        .popover(item: $browsing) { state in
          FontBrowser(session: session, state: state, onExplore: { browsing = nil; exploration = state })
        }
      FontPressable(title: "Explore fonts", identifier: "font-explorer-open", action: {
        exploration = FontBrowsingState(session: session)
      }) {
        Image(systemName: "rectangle.grid.2x2").font(.system(size: 13)).frame(width: 32, height: 36)
          .contentShape(Rectangle())
          .padding(.horizontal, 8).padding(.vertical, 6)
          .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(Palette.ink)
      }.help("Explore fonts with your text")
    }.sheet(item: $exploration) { state in
      FontExplorer(session: session, state: state)
    }
  }
}

struct FontBrowser: View {
  @ObservedObject var session: ArtworkSession
  var onChoose: ((String) -> Void)?
  var onExplore: (() -> Void)?
  @Environment(\.dismiss) private var dismiss
  @StateObject private var state: FontBrowsingState
  @State private var exploring = false
  init(session: ArtworkSession, onChoose: ((String) -> Void)? = nil,
    state: FontBrowsingState? = nil, onExplore: (() -> Void)? = nil) {
    self.session = session; self.onChoose = onChoose; self.onExplore = onExplore
    _state = StateObject(wrappedValue: state ?? FontBrowsingState(session: session))
  }
  var body: some View {
    Group {
      if let store = session.store {
        FontLibraryContent(session: session, store: store, preferences: store.fontLibraryPreferences,
          state: state, expanded: false, onChoose: onChoose, onClose: { dismiss() }, onExplore: {
            if let onExplore { onExplore() } else { exploring = true }
          })
      }
    }.frame(width: 460, height: 590).background(Palette.paper)
      .sheet(isPresented: $exploring, onDismiss: { if state.didApply { dismiss() } }) {
        FontExplorer(session: session, state: state, onChoose: onChoose)
      }
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

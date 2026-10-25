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
      }.font(.system(size: 13)).padding(9).background(.white, in: RoundedRectangle(cornerRadius: 6))
    }.buttonStyle(.plain).popover(isPresented: $showing) { FontBrowser(session: session) }
  }
}
struct FontBrowser: View {
  @ObservedObject var session: ArtworkSession
  @Environment(\.dismiss) var dismiss
  @State private var query = ""
  @State private var favorites =
    UserDefaults.standard.stringArray(forKey: "FORM.favoriteFontFamilies") ?? []
  @State private var recent =
    UserDefaults.standard.stringArray(forKey: "FORM.recentFontFamilies") ?? []
  @State private var favoriteOnly = false
  var families: [String] {
    let all = FontCatalog.families.filter {
      query.isEmpty || $0.localizedCaseInsensitiveContains(query)
    }.filter { !favoriteOnly || favorites.contains($0) }
    if query.isEmpty && !favoriteOnly {
      return recent.filter { all.contains($0) } + all.filter { !recent.contains($0) }
    }
    return all
  }
  var body: some View {
    VStack(spacing: 13) {
      HStack {
        TextField("Search installed fonts", text: $query).textFieldStyle(.roundedBorder)
        Button {
          favoriteOnly.toggle()
        } label: {
          Image(systemName: favoriteOnly ? "star.fill" : "star")
        }.buttonStyle(.plain).help("Show favorite typefaces")
      }
      HStack {
        SectionLabel("FONTS ON THIS MAC")
        Spacer()
        Text("\(families.count) families").font(.system(size: 9)).foregroundStyle(Palette.secondary)
      }
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(families, id: \.self) { family in
            HStack {
              Button {
                let face = FontCatalog.faces(family).first?.name ?? family
                session.typography {
                  $0.fontName = face
                  $0.features = [:]
                  $0.featureSelections = nil
                  $0.variations = [:]
                }
                recent.removeAll { $0 == family }
                recent.insert(family, at: 0)
                recent = Array(recent.prefix(12))
                UserDefaults.standard.set(recent, forKey: "FORM.recentFontFamilies")
                dismiss()
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  Text(family).font(.system(size: 9)).foregroundStyle(Palette.secondary)
                  Text("Aa  Form  0123456789").font(
                    Font(
                      NSFont(name: FontCatalog.faces(family).first?.name ?? family, size: 18)
                        ?? .systemFont(ofSize: 18))
                  ).foregroundStyle(Palette.ink).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
              }.buttonStyle(.plain)
              Button {
                if favorites.contains(family) {
                  favorites.removeAll { $0 == family }
                } else {
                  favorites.append(family)
                }
                UserDefaults.standard.set(favorites, forKey: "FORM.favoriteFontFamilies")
              } label: {
                Image(systemName: favorites.contains(family) ? "star.fill" : "star").font(
                  .system(size: 11)
                ).foregroundStyle(favorites.contains(family) ? Palette.accent : Palette.secondary)
              }.buttonStyle(.plain).padding(.trailing, 12)
            }.background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
          }
        }
      }
    }.padding(18).frame(width: 380, height: 460).background(Palette.paper)
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
      if !axes.isEmpty {
        DisclosureGroup("Variable font axes") {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(axes) { axis in
              VStack(alignment: .leading, spacing: 5) {
                HStack {
                  Text(axis.name).font(.system(size: 10))
                  Spacer()
                  Button("Reset") {
                    session.typography { $0.variations.removeValue(forKey: axis.id) }
                  }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Palette.accent)
                }
                Slider(
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
                  value: session.inspectedTypography.variations[axis.id] ?? axis.defaultValue
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
            ForEach(features) { feature in
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
                        }.labelsHidden().pickerStyle(.segmented).controlSize(.mini)
                    }.padding(.vertical, 3)
                  }
                }
              }
            }
          }.padding(.top, 8)
        }.font(.system(size: 10))
      }
    }
  }
}

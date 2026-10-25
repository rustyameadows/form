import FormCore
import FormGraphics
import SwiftUI

struct ColorProfileControls: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var session: ArtworkSession
  @State private var profiles: [InstalledOutputProfile] = []
  var body: some View {
    DisclosureGroup("Color output") {
      Text("Editing color space · sRGB").font(.system(size: 10))
      Menu {
        Button("Preserve source sRGB") {
          if let id = session.objectID { store.setOutputColorProfile(nil, objectID: id) }
        }
        Divider()
        ForEach(profiles) { profile in
          Button("\(profile.name) · \(profile.model)") {
            if let id = session.objectID { store.setOutputColorProfile(profile.path, objectID: id) }
          }
        }
        Divider()
        Button("Import ICC profile…") {
          if let id = session.objectID { store.importOutputColorProfile(objectID: id) }
        }
      } label: {
        Text(session.art.outputColorProfile.map { "PDF · \($0.name) (\($0.model))" } ?? "PDF · Preserve source sRGB")
      }.accessibilityLabel("PDF output profile")
      Text("PDF colors convert through the selected ICC profile. Editable colors, Table previews, SVG, PNG and JPEG remain sRGB.")
        .font(.system(size: 9)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
      if session.art.outputColorProfile?.name.localizedCaseInsensitiveContains("generic") == true {
        Text("A generic profile is a conversion study. Choose your print provider's profile for a specific production condition.")
          .font(.system(size: 9)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }.font(.system(size: 10)).onAppear { profiles = ICCOutputProfile.installed() }
  }
}

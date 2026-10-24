import FormCore
import SwiftUI

struct ArtworkSourcePanel: View {
  @EnvironmentObject var store: StudioStore
  let object: ProductObject
  let project: Project
  var sources: [ProductObject] {
    project.objects.filter {
      $0.recipeID == "artboard" && $0.id != object.id && $0.artworkSourceID == nil
        && $0.artwork != nil
    }
  }
  func link(_ value: String, fit: String? = nil) {
    var args: [String: Any] = [
      "object_id": object.id.uuidString, "fit": fit ?? object.artworkFit ?? "actual",
    ]
    if !value.isEmpty { args["source_object_id"] = value }
    store.perform("form_link_artwork", args)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Divider().padding(.vertical, 5)
      SectionLabel("SURFACE ARTWORK")
      Picker(
        "Artwork source",
        selection: Binding(get: { object.artworkSourceID?.uuidString ?? "" }, set: { link($0) })
      ) {
        Text("Owned by this object").tag("")
        ForEach(sources) { Text($0.name).tag($0.id.uuidString) }
      }.labelsHidden().font(.system(size: 10))
      if let id = object.artworkSourceID, let source = project.objects.first(where: { $0.id == id })
      {
        Picker(
          "Placement",
          selection: Binding(
            get: { object.artworkFit ?? "actual" }, set: { link(id.uuidString, fit: $0) })
        ) {
          Text("Actual size · centered").tag("actual")
          Text("Fit proportionally").tag("fit")
        }.labelsHidden().font(.system(size: 10))
        let size = source.artworkSize
        let face = object.artworkSize
        let scale = object.artworkFit == "fit" ? min(face.x / size.x, face.y / size.y) : 1
        Text(
          "\(Int(size.x)) × \(Int(size.y)) mm source · \((scale*100).formatted(.number.precision(.fractionLength(0...1))))% on surface"
        )
        .font(.system(size: 9)).foregroundStyle(Palette.secondary)
        if abs(face.x - size.x) > 0.1 || abs(face.y - size.y) > 0.1 {
          Text(
            object.artworkFit == "fit"
              ? "Artwork scales with this surface; the source document keeps its dimensions."
              : "The surface and source have different dimensions. Artwork keeps its physical type sizes."
          )
          .font(.system(size: 9)).foregroundStyle(Palette.accent)
        }
        HStack {
          Button("Edit source") { store.mode = .artwork }
          Spacer()
          Button("Detach") { link("") }
        }.font(.system(size: 10))
      } else if object.recipeID != "artboard", project.editableArtwork(object) != nil {
        Button("Make independent artwork document") {
          store.perform("form_extract_artwork", ["object_id": object.id.uuidString])
        }.font(.system(size: 10))
      }
    }
  }
}

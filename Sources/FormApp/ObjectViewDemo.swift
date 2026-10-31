import AppKit
import FormCore
import SwiftUI

extension StudioStore {
  /// Creates a disposable study using the same projection and rendering paths
  /// as ordinary placements, so every copy is a normal editable project.
  func createObjectViewDemo() {
    let oldID = project?.id
    createProject()
    guard let initial = project, initial.id != oldID else { return }
    Task { @MainActor in
      var writtenAsset: URL?
      do {
        var draft = initial
        draft.name = "Object views / Toy car study"
        // Project-local procedural parts remain editable source geometry.
        let carRecipe = Recipe("object-view-demo-car", "Toy car", "car", "A simple editable toy car for object-view studies.",
          [.init("length", "Length", 160, 120...220), .init("depth", "Width", 66, 50...95)], parts: [
            .init("box", ["width":"length", "height":"28", "depth":"depth", "corner":"7", "segments":"3", "y":"34"], color:"#D75237"),
            .init("box", ["width":"length*0.46", "height":"28", "depth":"depth*0.84", "corner":"6", "segments":"3", "x":"-length*0.08", "y":"61"], color:"#D75237"),
            .init("box", ["width":"length*0.27", "height":"17", "depth":"2", "corner":"2", "segments":"2", "x":"-length*0.08", "y":"63", "z":"depth*0.425"], color:"#8CBCC3"),
            .init("box", ["width":"length*0.27", "height":"17", "depth":"2", "corner":"2", "segments":"2", "x":"-length*0.08", "y":"63", "z":"-depth*0.425"], color:"#8CBCC3"),
            .init("box", ["width":"2", "height":"17", "depth":"depth*0.65", "corner":"1", "segments":"2", "x":"length*0.155", "y":"63"], color:"#8CBCC3"),
            .init("cylinder", ["radius":"18", "height":"10", "x":"-length*0.30", "y":"18", "z":"depth*0.5", "segments":"24", "rotationX":"90"], color:"#303533"),
            .init("cylinder", ["radius":"18", "height":"10", "x":"length*0.30", "y":"18", "z":"depth*0.5", "segments":"24", "rotationX":"90"], color:"#303533"),
            .init("cylinder", ["radius":"18", "height":"10", "x":"-length*0.30", "y":"18", "z":"-depth*0.5", "segments":"24", "rotationX":"90"], color:"#303533"),
            .init("cylinder", ["radius":"18", "height":"10", "x":"length*0.30", "y":"18", "z":"-depth*0.5", "segments":"24", "rotationX":"90"], color:"#303533"),
            .init("box", ["width":"3", "height":"8", "corner":"0", "depth":"depth*0.25", "x":"length*0.5", "y":"37", "z":"depth*0.3"], color:"#F7D88B"),
            .init("box", ["width":"3", "height":"8", "corner":"0", "depth":"depth*0.25", "x":"length*0.5", "y":"37", "z":"-depth*0.3"], color:"#F7D88B")
          ])
        draft.recipes.append(carRecipe)
        var car = try draft.makeObject(recipeID: carRecipe.id, name: "Toy car")
        car.position = .init(-160, 0, 0)
        draft.objects.append(car)
        var page = try draft.makeObject(recipeID: "artboard", name: "Four views", parameters: ["width": 220, "depth": 250])
        let assets = repository.url(for: draft.id).appendingPathComponent("Assets")
        let layouts: [(String, Double, Double, String, Double, Double)] = [
          ("01 / SIDE SILHOUETTE", 0, 0, "silhouette", 15, 44),
          ("02 / FRONT LINEWORK", 90, 0, "lines", 115, 44),
          ("03 / TOP SILHOUETTE", 0, 90, "silhouette", 15, 145),
        ]
        func label(_ value: String, x: Double, y: Double, size: Double) -> ArtworkElement {
          ArtworkElement(kind: "text", x: x, y: y, width: 90, height: size * 0.6 + 5,
            text: value, color: "#343B38", fontSize: size)
        }
        var art = Artwork(background: "#F5F2E9")
        var title = label("ONE OBJECT / FOUR VIEWS", x: 15, y: 12, size: 22)
        title.width = 190; title.height = 14
        art.elements.append(title)
        for (name, azimuth, elevation, style, x, y) in layouts {
          var view = try ObjectViewProjection.make(object: car, project: draft, assets: assets,
            azimuth: azimuth, elevation: elevation, style: style)
          let frame = ArtworkElement(kind: "path", x: x, y: y, width: 80, height: 80)
          guard let fitted = ObjectViewProjection.fit(view, into: frame) else {
            throw FormError.invalid("The demo view could not be fitted to its frame.")
          }
          view.x = x; view.y = y; view.width = 80; view.height = 80; view.path = fitted
          view.name = name
          view.objectView = .init(sourceID: car.id, azimuth: azimuth, elevation: elevation,
            style: style, linked: true)
          art.elements.append(view)
          art.elements.append(label(name, x: x, y: y + 83, size: 8))
        }
        let rendered = try await ObjectViewRendering.render(object: car, project: draft, assets: assets,
          azimuth: -28, elevation: 14, frameSize: CGSize(width: 80, height: 80), pixels: 1200)
        guard project?.id == initial.id else { return }
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let file = UUID().uuidString + ".png"
        let assetURL = assets.appendingPathComponent(file)
        try rendered.write(to: assetURL, options: .atomic)
        writtenAsset = assetURL
        var image = ArtworkElement(kind: "image", x: 115, y: 145, width: 80, height: 80, asset: file)
        image.name = "04 / RENDERED VIEW"
        image.objectView = .init(sourceID: car.id, azimuth: -28, elevation: 14,
          style: "rendered", linked: false)
        art.elements.append(image)
        art.elements.append(label("04 / RENDERED VIEW", x: 115, y: 228, size: 8))
        page.artwork = art
        draft.objects.append(page)
        try engine.edit("Created object view study") { project in
          guard project.id == initial.id else { throw FormError.invalid("The project changed while preparing the study.") }
          project.name = draft.name
          project.recipes.append(carRecipe)
          project.objects.append(contentsOf: [car, page])
        }
        writtenAsset = nil
        changed()
        artworkSession.activate(page.id)
        showSplit(.sideBySide)
        mode = .artwork
        DispatchQueue.main.async { self.artworkSession.fit(); self.scene?.fitAll() }
      } catch {
        if let writtenAsset { try? FileManager.default.removeItem(at: writtenAsset) }
        self.error = "Could not create the object view study: \(error.localizedDescription)"
      }
    }
  }
}

import AppKit
import FormCore
import SwiftUI

extension ArtworkSession {
  func cancelObjectViewRendering() {
    objectViewRenderToken = UUID()
    objectViewRenderTask?.cancel(); objectViewRenderTask = nil
    objectViewRendering = false
  }
  /// A cold source is prepared without replacing the focused editor or blocking
  /// native events. A later source, target or project invalidates this request.
  private func prepareSolidObjectView(_ source:ProductObject,project:Project,then:@escaping @MainActor (SolidSurface)->Void)->Bool {
    guard let definition=project.recipe(source.recipeID)?.solid,
      (try? SolidRecipeGeometry.cachedSurface(definition,parameters:source.parameters))==nil else{return false}
    cancelObjectViewRendering()
    let token=objectViewRenderToken,target=objectID,projection=projectionFrameID,selected=selection
    let state=LinkedObjectViewRenderer.state(source,in:project)
    objectViewRendering=true
    objectViewRenderTask=Task{[weak self] in
      defer{if let self,self.objectViewRenderToken==token {self.objectViewRendering=false;self.objectViewRenderTask=nil}}
      do {
        let solids=try await SolidRecipeGeometry.prepareFullSources(project:project,objectIDs:[source.id])
        try Task.checkCancellation()
        guard let self,self.objectViewRenderToken==token,self.objectID==target,self.projectionFrameID==projection,self.selection==selected,
          let current=self.store?.project,current.id==project.id,
          let latest=current.objects.first(where:{$0.id==source.id}),LinkedObjectViewRenderer.state(latest,in:current)==state,
          let surface=solids[source.id] else{return}
        self.objectViewRendering=false;self.objectViewRenderTask=nil;then(surface)
      }catch {
        guard let self,self.objectViewRenderToken==token else{return}
        self.objectViewRendering=false;self.objectViewRenderTask=nil
        if !Task.isCancelled {self.store?.error=error.localizedDescription}
      }
    }
    return true
  }
  /// Each projection has its own camera and never moves or edits the source.
  func placeObjectView(_ source: ProductObject, fourViews: Bool = false,solidSurface:SolidSurface?=nil) {
    guard let project = store?.project else { return }
    if solidSurface==nil,prepareSolidObjectView(source,project:project,then:{[weak self] surface in self?.placeObjectView(source,fourViews:fourViews,solidSurface:surface)}) {return}
    do {
      let angles: [(String, Double)] = fourViews
        ? [("Front", 0), ("Right", 90), ("Back", 180), ("Left", -90)] : [("Front", 0)]
      var views = try angles.map { label, angle in
        var view = try ObjectViewProjection.make(object: source, project: project, assets: assets,
          azimuth: angle, elevation: 0, style: "silhouette",solidSurface:solidSurface)
        var settings = ObjectViewSettings(sourceID: source.id, azimuth: angle, elevation: 0,
          style: "silhouette", linked: true)
        settings.referenceAspect = settings.framingAspect(for: view)
        view.objectView = settings
        view.name = source.name + " · " + label
        return view
      }
      let maxWidth = views.map(\.width).max() ?? 60, maxHeight = views.map(\.height).max() ?? 60
      let columns = fourViews ? 2 : 1, rows = fourViews ? 2 : 1, gap = 8.0
      let width = Double(columns) * maxWidth + Double(columns - 1) * gap
      let height = Double(rows) * maxHeight + Double(rows - 1) * gap
      let center: Point2
      if object?.isCanvasWorkspace == true, let rect = canvas?.visibleCanvasRect {
        center = .init(rect.midX, rect.midY)
      } else if let frame = object {
        let size = project.artworkSize(frame); center = .init(size.x / 2, size.y / 2)
      } else { center = .init(width / 2, height / 2) }
      for i in views.indices {
        views[i].x = center.x - width / 2 + Double(i % columns) * (maxWidth + gap) + (maxWidth - views[i].width) / 2
        views[i].y = center.y - height / 2 + Double(i / columns) * (maxHeight + gap) + (maxHeight - views[i].height) / 2
      }
      add(views)
    } catch { store?.error = error.localizedDescription }
  }

  func configureObjectView(_ settings: ObjectViewSettings, changeStyle: Bool = false,
    render: @escaping LinkedObjectViewRenderer.Render = { object, project, assets, azimuth, elevation, size, pixels in
      try await ObjectViewRendering.render(object: object, project: project, assets: assets,
        azimuth: azimuth, elevation: elevation, frameSize: size, pixels: pixels)
    },solidSurface:SolidSurface?=nil) {
    cancelObjectViewRendering()
    let token = objectViewRenderToken
    guard let store, let project = store.project,
      let source = project.objects.first(where: { $0.id == settings.sourceID }),
      let selected = primary else {
      store?.error = "The source object is no longer available. The last view remains on the canvas."
      return
    }
    if settings.style != "rendered",solidSurface==nil,
      prepareSolidObjectView(source,project:project,then:{[weak self] surface in self?.configureObjectView(settings,changeStyle:changeStyle,render:render,solidSurface:surface)}) {return}
    var settings = settings
    settings.referenceAspect = settings.framingAspect(for: selected)
    settings.renderPending = nil
    if settings.style == "rendered" {
      let targetFrame = objectID
      let targetProjection = projectionFrameID
      let folder = assets
      objectViewRendering = true
      objectViewRenderTask = Task { @MainActor [weak self, weak store] in
        guard let self, let store else { return }
        defer {
          if self.objectViewRenderToken == token {
            self.objectViewRendering = false; self.objectViewRenderTask = nil
          }
        }
        do {
          let png = try await render(source, project, folder, settings.azimuth, settings.elevation,
            .init(width: settings.referenceAspect ?? 1, height: 1),
            min(4096, max(256, settings.pixels ?? 2048)))
          guard self.objectViewRenderToken == token, self.objectID == targetFrame,
            self.projectionFrameID == targetProjection, self.selection.contains(selected.id),
            self.art.elements.first(where: { $0.id == selected.id }) == selected else { return }
          self.canvas?.finishText()
          guard self.objectViewRenderToken == token, self.objectID == targetFrame,
            self.projectionFrameID == targetProjection, self.selection.contains(selected.id),
            self.art.elements.first(where: { $0.id == selected.id }) == selected else { return }
          guard store.project == project else {
            store.error = "The project changed while the object view was rendering. Refresh the view to try again."
            return
          }
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          let name = "object-view-" + UUID().uuidString + ".png"
          try png.write(to: folder.appendingPathComponent(name), options: .atomic)
          // Selection can expand while the capture is in flight. Publish only
          // the placement that requested it, never the current multiselection.
          self.mutate { artwork in
            guard let i = artwork.elements.firstIndex(where: { $0.id == selected.id }) else { return }
            ObjectViewRenderResult.apply(to: &artwork.elements[i], asset: name, settings: settings)
          }
          if self.art.elements.first(where: { $0.id == selected.id })?.asset != name {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
          }
        } catch {
          if self.objectViewRenderToken == token { store.error = error.localizedDescription }
        }
      }
      return
    }
    do {
      let result = try ObjectViewProjection.make(object: source, project: project, assets: assets,
        azimuth: settings.azimuth, elevation: settings.elevation, style: settings.style,solidSurface:solidSurface)
      guard let fitted = ObjectViewProjection.fit(result, into: settings.framingTarget(for: selected)) else {
        throw FormError.invalid("The view cannot be fitted to this artwork frame.")
      }
      update { element in
        element.kind = "path"; element.asset = nil; element.imageCrop = nil; element.imageAdjustments = nil
        element.path = fitted
        if changeStyle {
          element.fillEnabled = result.fillEnabled
          element.stroke = result.stroke
        }
        element.objectView = settings
      }
    } catch { store.error = error.localizedDescription }
  }

}

enum ObjectViewRenderResult {
  /// Image appearance edits belong to the placement, not to a particular capture.
  static func apply(to element: inout ArtworkElement, asset: String, settings: ObjectViewSettings) {
    if element.kind != "image" {
      element.imageCrop = nil; element.imageAdjustments = nil
    }
    element.kind = "image"; element.asset = asset; element.path = nil
    element.objectView = settings
  }
}

struct ObjectViewControls: View {
  @ObservedObject var session: ArtworkSession
  let element: ArtworkElement
  @State private var spin = 0.0
  @State private var spinning = false
  private var settings: ObjectViewSettings? { element.objectView }
  private var source: ProductObject? {
    guard let settings else { return nil }
    return session.store?.project?.objects.first { $0.id == settings.sourceID }
  }
  var body: some View {
    if let settings {
      InspectorDivider()
      SectionLabel("OBJECT VIEW")
      Text(source?.name ?? "Source unavailable")
        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
      if let source, let project = session.store?.project {
        ObjectViewPreview(object: source, project: project, assets: session.assets,
          azimuth: spinning ? spin : settings.azimuth, elevation: settings.elevation) { azimuth, elevation in
          var next = settings; next.azimuth = azimuth; next.elevation = elevation
          session.configureObjectView(next)
        }
        .frame(height: 150).cornerRadius(6)
        Text("Drag to rotate the view").font(.system(size: 9)).foregroundStyle(Palette.secondary)
        Picker("View", selection: Binding(get: { viewName(settings) }, set: { choice in
          var next = settings
          switch choice {
          case "front": next.azimuth = 0; next.elevation = 0
          case "back": next.azimuth = 180; next.elevation = 0
          case "left": next.azimuth = -90; next.elevation = 0
          case "right": next.azimuth = 90; next.elevation = 0
          case "top": next.azimuth = 0; next.elevation = 90
          default: return
          }
          session.configureObjectView(next)
        })) {
          Text("Custom").tag("custom")
          Text("Front").tag("front")
          Text("Back").tag("back")
          Text("Left").tag("left")
          Text("Right").tag("right")
          Text("Top").tag("top")
        }
        HStack {
          Text("Spin").font(InspectorStyle.labelFont)
          Slider(value: $spin, in: -180...180, onEditingChanged: { editing in
            spinning = editing
            if !editing { var next = settings; next.azimuth = spin; session.configureObjectView(next) }
          })
        }.onAppear { spin = normalizedSpin(settings.azimuth) }
          .onChange(of: settings.azimuth) { _, value in
            if !spinning { spin = normalizedSpin(value) }
          }
        ScalarArtworkField("Azimuth", value: settings.azimuth, unit: "°") { value in
          var next = settings; next.azimuth = value; session.configureObjectView(next)
        }
        ScalarArtworkField("Elevation", value: settings.elevation, unit: "°") { value in
          var next = settings; next.elevation = min(90, max(-90, value)); session.configureObjectView(next)
        }
        Picker("Treatment", selection: Binding(get: { settings.style }, set: { value in
          var next = settings; next.style = value; session.configureObjectView(next, changeStyle: true)
        })) {
          Text("Silhouette").tag("silhouette")
          Text("Line illustration").tag("lines")
          Text("Rendered").tag("rendered")
        }
        if settings.style == "rendered" {
          ScalarArtworkField("Resolution", value: Double(settings.pixels ?? 2048), unit: "px") { value in
            var next = settings; next.pixels = Int(min(4096, max(256, value)).rounded())
            session.configureObjectView(next)
          }
          Text("Pixels on the longest edge").font(.system(size: 9)).foregroundStyle(Palette.secondary)
        }
        if session.objectViewRendering {
          ProgressView("Rendering view…").controlSize(.small)
        }
        if let bounds = session.selectionBounds {
          ArtworkUnitField("Size", value: max(bounds.width, bounds.height), unit: session.unit) { value in
            guard value > 0 else { return }
            let factor = value / max(0.001, max(bounds.width, bounds.height))
            session.transformBounds(width: bounds.width * factor, height: bounds.height * factor)
          }
        }
        ObjectViewPresetControls(azimuth: settings.azimuth, elevation: settings.elevation,
          style: settings.style) { azimuth, elevation, style in
          var next = settings
          next.azimuth = azimuth; next.elevation = elevation; next.style = style
          session.configureObjectView(next, changeStyle: style != settings.style)
        }
        Toggle("Update with source", isOn: Binding(get: { settings.linked }, set: { linked in
          var next = settings; next.linked = linked
          if !linked { next.renderPending = nil }
          if linked { session.configureObjectView(next) }
          else { session.update { $0.objectView = next } }
        }))
        Button("Refresh view") { session.configureObjectView(settings) }
      }
      Button(element.kind == "image" ? "Convert to image" : "Convert to editable path") {
        session.cancelObjectViewRendering()
        session.update { $0.objectView = nil }
      }
        .font(.system(size: 10))
    }
  }
  private func normalizedSpin(_ degrees: Double) -> Double {
    let wrapped = (degrees + 180).truncatingRemainder(dividingBy: 360)
    return (wrapped < 0 ? wrapped + 360 : wrapped) - 180
  }
  private func viewName(_ s: ObjectViewSettings) -> String {
    if s.elevation == 90 && s.azimuth == 0 { return "top" }
    guard s.elevation == 0 else { return "custom" }
    switch s.azimuth { case 0: return "front"; case 180: return "back"; case -90: return "left"; case 90: return "right"; default: return "custom" }
  }
}

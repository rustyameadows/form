import Foundation
import FormCore
import FormGeometry

/// Keep the stored path current so canvas previews, pattern tiles and exports all
/// consume the same artwork. The last valid path remains if a source is unavailable.
@MainActor enum ObjectViewUpdates {
  static func refreshChangedSources(before: Project, project: inout Project, assets: URL) -> [String] {
    let sources = Set(project.storedArtworks.flatMap(\.elements).compactMap { element -> UUID? in
      guard let view = element.objectView, view.linked, view.style != "rendered" else { return nil }
      return view.sourceID
    })
    let old = Dictionary(uniqueKeysWithValues: before.objects.map { ($0.id, $0) })
    let changed = Set(project.objects.compactMap { object -> UUID? in
      guard sources.contains(object.id), let previous = old[object.id],
        LinkedObjectViewRenderer.state(previous, in: before) != LinkedObjectViewRenderer.state(object, in: project)
      else { return nil }
      return object.id
    })
    return refreshSources(changed,project:&project,assets:assets)
  }
  static func refreshSources(_ changed:Set<UUID>,project:inout Project,assets:URL,solidSurfaces:[UUID:SolidSurface]=[:])->[String] {
    guard !changed.isEmpty else { return [] }
    // Generate against a stable snapshot, not against partially rewritten artwork.
    let snapshot = project
    var failures = Set<String>()
    for index in project.objects.indices {
      project.objects[index].updateStoredArtworks { art in
        for i in art.elements.indices {
          guard let view = art.elements[i].objectView, view.linked, view.style != "rendered", changed.contains(view.sourceID),
            let source = snapshot.objects.first(where: { $0.id == view.sourceID }) else { continue }
          do {
            // An agent edit can arrive before an authoritative CPU surface has
            // finished. Keep the last valid path and durable pending marker.
            if let definition=snapshot.recipe(source.recipeID)?.solid,solidSurfaces[source.id]==nil,
              try SolidRecipeGeometry.cachedSurface(definition,parameters:source.parameters)==nil {
              art.elements[i].objectView?.renderPending=true;continue
            }
            guard !LinkedObjectViewRenderer.hasCycle(from: view.sourceID, project: snapshot) else {
              throw FormError.invalid("The linked view forms a cycle through source artwork. Convert it to an editable path to keep its appearance.")
            }
            let result = try ObjectViewProjection.make(object: source, project: snapshot, assets: assets,
              azimuth: view.azimuth, elevation: view.elevation, style: view.style,solidSurface:solidSurfaces[source.id])
            guard let fitted = ObjectViewProjection.fit(result, into: view.framingTarget(for: art.elements[i])) else {
              throw FormError.invalid("The view cannot be fitted to its artwork frame.")
            }
            art.elements[i].path = fitted
            art.elements[i].objectView?.renderPending=false
          } catch {
            failures.insert("\(source.name): \(error.localizedDescription)")
          }
        }
      }
    }
    return failures.sorted()
  }

}

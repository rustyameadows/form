import AppKit
import FormCore
import Foundation

/// Refreshes rendered linked views after a source edit. The image is derived
/// state: updating it does not add an undo step or replace an undo snapshot.
@MainActor final class LinkedObjectViewRenderer {
  typealias Render = @MainActor (ProductObject, Project, URL, Double, Double, CGSize, Int) async throws -> Data
  private weak var store: StudioStore?
  private let render: Render
  private var observed: Project?
  private var jobs: [Key: Task<Void, Never>] = [:]

  init(store: StudioStore, render: @escaping Render = { object, project, assets, azimuth, elevation, size, pixels in
    try await ObjectViewRendering.render(object: object, project: project, assets: assets,
      azimuth: azimuth, elevation: elevation, frameSize: size, pixels: pixels)
  }) { self.store = store; self.render = render }

  func reset() {
    for job in jobs.values { job.cancel() }
    jobs.removeAll(); taskTokens.removeAll(); observed = nil
  }

  private struct Key: Hashable {
    let sourceID: UUID
    let azimuth: Double, elevation: Double, aspect: Double
    let pixels: Int
  }
  private struct Target: Equatable {
    let ownerID: UUID, elementID: UUID
    let settings: ObjectViewSettings
    let width: Double, height: Double
    let aspect: Double
    let originalAsset: String?
  }
  struct SourceState: Equatable {
    let object: ProductObject
    let surface: Artwork?, outside: Artwork?, inside: Artwork?
    let physical: [Artwork?]
    let materials: [FormCore.Material]
    let fabric, recipe, merchandise, merchandiseMaterials: Data?
    let paperFontRevision: Int?
  }
  static func state(_ object: ProductObject, in project: Project) -> SourceState {
    var normalized = ObjectViewSourceChanges.withoutCanvasPlacement(object)
    normalized.position = .init(); normalized.rotation = 0
    // Canvas placement belongs to the editor, not the physical source. Keep it
    // out of both raw and resolved identities so dragging a frame cannot rebuild
    // its linked vector projections or start another GPU capture.
    func artwork(_ source: Artwork?) -> Artwork? {
      guard var source else { return nil }
      source.canvasPosition = nil
      return source
    }
    let encoder = JSONEncoder.form
    let fabric = (try? project.resolvedFabricPattern(materialID: object.materialID))?.renderDefinition
    let surface = artwork(project.surfaceArtwork(normalized))
    let isPaper = PaperConstruction.isPaper(normalized)
    let inside: Artwork?
    if let source = project.paperArtwork(for: normalized, inside: true) {
      // Detached inside artwork still needs its component and swatch sources.
      // Retain the value, including runtime story snapshots, rather than JSON
      // encoding it again just to compare its hash. The complete raw object
      // above already covers every construction/parameter input to paper shape.
      let expanded = (try? project.resolvingComponents(in: source)) ?? source
      inside = artwork(project.resolvingSwatches(in: expanded))
    } else { inside = nil }
    return .init(object: normalized, surface: surface,
      outside: isPaper ? surface : nil,
      inside: inside,
      physical: (normalized.surfaceArtworkBindings ?? []).map { artwork(project.physicalSurfaceArtwork($0)) },
      materials: project.materials,
      fabric: fabric.flatMap { try? encoder.encode($0) },
      recipe: project.recipe(object.recipeID).flatMap { try? encoder.encode($0) },
      merchandise: project.conformedMerchandiseSignature(object).flatMap { try? encoder.encode($0) },
      merchandiseMaterials: project.merchandiseMaterialDependencies(object).flatMap { try? encoder.encode($0) },
      paperFontRevision: isPaper ? GeometryFactory.fontRevision : nil)
  }

  /// Mark affected raster views in the same transaction as a source edit, so
  /// quitting or saving before the GPU returns cannot lose a pending update.
  static func markPending(before: Project, project: inout Project) {
    guard !ObjectViewSourceChanges.sameExceptCanvasPlacement(before, project) else { return }
    let targets = Self.targets(in: project)
    let sources = Set(targets.map { $0.target.settings.sourceID })
    let old = Dictionary(uniqueKeysWithValues: before.objects.map { ($0.id, $0) })
    let changed = Set(project.objects.compactMap { object -> UUID? in
      guard sources.contains(object.id) else { return nil }
      guard let previous = old[object.id] else { return object.id }
      return Self.state(previous, in: before) != Self.state(object, in: project) ? object.id : nil
    })
    guard !changed.isEmpty else { return }
    for index in project.objects.indices {
      project.objects[index].updateStoredArtworks { artwork in
        for i in artwork.elements.indices {
          guard artwork.elements[i].kind == "image", var view = artwork.elements[i].objectView,
            view.linked, view.style == "rendered", changed.contains(view.sourceID) else { continue }
          view.renderPending = true
          artwork.elements[i].objectView = view
        }
      }
    }
  }

  /// Called after committed edits and on open. Pending images are recovered on
  /// open, while an already running job is left alone on unrelated changes.
  func synchronize(_ project: Project?) {
    guard let project else { reset(); return }
    if observed?.id != project.id { reset() }
    let before = observed ?? project
    observed = project
    let oldObjects = Dictionary(uniqueKeysWithValues: before.objects.map { ($0.id, $0) })
    let currentTargets = Self.targets(in: project)
    let sources = Set(currentTargets.map { $0.target.settings.sourceID })
    var changed = Set<UUID>()
    if !ObjectViewSourceChanges.sameExceptCanvasPlacement(before, project) {
      for object in project.objects where sources.contains(object.id) {
        guard let old = oldObjects[object.id] else { changed.insert(object.id); continue }
        if Self.state(old, in: before) != Self.state(object, in: project) { changed.insert(object.id) }
      }
    }
    var oldTargets: [String: Target] = [:]
    for item in Self.targets(in: before) { oldTargets[item.identity] = item.target }
    for (key, job) in jobs where changed.contains(key.sourceID) { job.cancel(); jobs.removeValue(forKey:key) }
    let assets = store?.repository.url(for: project.id).appendingPathComponent("Assets")
    guard let assets else { return }
    var groups: [Key: [Target]] = [:]
    for item in currentTargets {
      let t = item.target, previous = oldTargets[item.identity]
      func cameraSettings(_ value: ObjectViewSettings) -> ObjectViewSettings {
        var result = value; result.renderPending = nil; return result
      }
      let changedView = previous.map { cameraSettings($0.settings) != cameraSettings(t.settings)
        || $0.width != t.width || $0.height != t.height } ?? false
      let key = Key(sourceID:t.settings.sourceID, azimuth:t.settings.azimuth,
        elevation:t.settings.elevation, aspect:t.aspect, pixels:min(4096, max(256, t.settings.pixels ?? 2048)))
      let requiresStart = t.settings.renderPending == true && jobs[key] == nil
      guard changed.contains(t.settings.sourceID) || changedView || requiresStart else { continue }
      groups[key, default: []].append(t)
    }
    for (key, _) in groups {
      jobs.removeValue(forKey:key)?.cancel()
      let targets = currentTargets.map(\.target).filter {
        $0.settings.sourceID == key.sourceID && $0.settings.azimuth == key.azimuth
          && $0.settings.elevation == key.elevation && $0.aspect == key.aspect
          && min(4096, max(256, $0.settings.pixels ?? 2048)) == key.pixels
      }
      guard !targets.isEmpty, let source = project.objects.first(where: {$0.id == key.sourceID}) else { continue }
      if Self.hasCycle(from: key.sourceID, project: project) {
        store?.error = "A linked object view forms a cycle through source artwork. Freeze or detach one view to update it."
        continue
      }
      let signature = Self.state(source, in: project), token = UUID()
      // A unique token prevents a cancelled task from removing its replacement.
      taskTokens[key] = token
      jobs[key] = Task { [weak self] in
        guard let self else { return }
        defer { if self.taskTokens[key] == token { self.jobs.removeValue(forKey:key); self.taskTokens.removeValue(forKey:key) } }
        do {
          let data = try await self.render(source, project, assets, key.azimuth, key.elevation,
                                           CGSize(width:key.aspect,height:1),key.pixels)
          try Task.checkCancellation()
          try self.publish(data, key:key, targets:targets, signature:signature, projectID:project.id, assets:assets)
        } catch is CancellationError { }
        catch {
          guard !Task.isCancelled, let current = self.store?.project, current.id == project.id,
            let latest = current.objects.first(where: {$0.id == key.sourceID}),
            Self.state(latest, in: current) == signature else { return }
          self.store?.error = "Could not update linked render for \(source.name): \(error.localizedDescription)"
        }
      }
    }
  }
  private var taskTokens: [Key: UUID] = [:]

  private struct LocatedTarget {
    let identity: String, target: Target
  }
  private static func targets(in project: Project) -> [LocatedTarget] {
    var result: [LocatedTarget] = []
    for owner in project.objects {
      for artwork in owner.storedArtworks {
        for element in artwork.elements {
          guard element.kind == "image", let view = element.objectView, view.linked,
            view.style == "rendered", view.azimuth.isFinite, view.elevation.isFinite,
            element.width.isFinite, element.height.isFinite, element.width > 0, element.height > 0 else { continue }
          result.append(.init(identity:owner.id.uuidString+":"+element.id.uuidString,
            target:.init(ownerID:owner.id,elementID:element.id,settings:view,width:element.width,
                         height:element.height,aspect:view.framingAspect(for:element),originalAsset:element.asset)))
        }
      }
    }
    return result
  }

  private func publish(_ png: Data, key: Key, targets: [Target], signature: SourceState,
                       projectID: UUID, assets: URL) throws {
    guard let store, var project = store.project, project.id == projectID,
      let source = project.objects.first(where: {$0.id == key.sourceID}),
      Self.state(source, in: project) == signature, !Self.hasCycle(from:key.sourceID,project:project) else { return }
    var expected: [String: Target] = [:]
    for target in targets { expected[target.ownerID.uuidString+":"+target.elementID.uuidString] = target }
    let name = UUID().uuidString + ".png"
    var updated = false
    for index in project.objects.indices {
      let owner = project.objects[index].id
      project.objects[index].updateStoredArtworks { artwork in
        for i in artwork.elements.indices {
          let element = artwork.elements[i], id = owner.uuidString+":"+element.id.uuidString
          guard let target = expected[id], element.kind == "image", element.objectView == target.settings,
            element.width == target.width, element.height == target.height,
            element.asset == target.originalAsset else { continue }
          artwork.elements[i].asset = name
          artwork.elements[i].objectView?.renderPending = false
          updated = true
        }
      }
    }
    guard updated else { return }
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try png.write(to: assets.appendingPathComponent(name), options: [.atomic])
    // No suspension occurs between the last source/target check and publication.
    // Keep old assets: undo and redo snapshots may still refer to them.
    store.engine.project = project
    store.changed()
  }

  /// A view on its own source (or on a chain that leads back to it) has no
  /// stable fixed point. Preserve its last image instead of recapturing forever.
  static func hasCycle(from sourceID: UUID, project: Project) -> Bool {
    var visiting = Set<UUID>(), visited = Set<UUID>()
    func visit(_ id: UUID) -> Bool {
      if visiting.contains(id) { return true }
      if visited.contains(id) { return false }
      guard let object = project.objects.first(where: {$0.id == id}) else { return false }
      visiting.insert(id)
      var artworks = [project.surfaceArtwork(object), project.paperArtwork(for:object,inside:false),
                      project.paperArtwork(for:object,inside:true)].compactMap {$0}
      artworks += (object.surfaceArtworkBindings ?? []).compactMap { project.physicalSurfaceArtwork($0) }
      for element in artworks.flatMap(\.elements) {
        if let view = element.objectView, view.linked, visit(view.sourceID) { return true }
      }
      visiting.remove(id); visited.insert(id); return false
    }
    return visit(sourceID)
  }
}

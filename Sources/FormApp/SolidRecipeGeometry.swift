import AppKit
import CryptoKit
import FormCore
import FormGeometry
import simd

/// Main-actor cache and scene adapter. Interactive callers build Sendable CPU
/// surfaces off-actor; synchronous export/print callers retain the same full
/// authoritative surface and exact geometry behavior.
@MainActor enum SolidRecipeGeometry {
  private final class CacheValue: NSObject {
    let surface: SolidSurface
    init(_ surface: SolidSurface) { self.surface = surface }
  }
  private static let cache: NSCache<NSString, CacheValue> = {
    let result = NSCache<NSString, CacheValue>()
    result.totalCostLimit = 96_000_000
    result.countLimit = 12
    return result
  }()

  nonisolated static func sourceKey(_ definition: ParametricSolid, parameters: [String: Double], isEditingPreview: Bool) throws -> String {
    var signature = try JSONEncoder.form.encode(definition)
    signature.append(try JSONEncoder.form.encode(parameters))
    signature.append(isEditingPreview ? 1 : 0)
    return SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined()
  }

  static func cachedSurface(_ definition: ParametricSolid, parameters: [String: Double], useEditingPreview: Bool = false) throws -> SolidSurface? {
    let isPreview = useEditingPreview && definition.previewNodes != nil
    return cache.object(forKey: try sourceKey(definition, parameters: parameters, isEditingPreview: isPreview) as NSString)?.surface
  }

  static func remember(_ surface: SolidSurface, definition: ParametricSolid, parameters: [String: Double]) throws {
    // Large finished meshes can still be displayed/exported, but must not evict
    // the entire small-preview cache merely by exceeding its total budget.
    guard surface.byteCount <= cache.totalCostLimit else { return }
    cache.setObject(CacheValue(surface), forKey: try sourceKey(definition, parameters: parameters, isEditingPreview: surface.isEditingPreview) as NSString, cost: surface.byteCount)
  }


  /// Full-detail capture/print preparation never reads the interactive preview
  /// slot. Return strong per-object surfaces so cache eviction cannot turn a
  /// prepared capture back into a cold synchronous build.
  static func prepareFullSources(project:Project,objectIDs:Set<UUID>?=nil,maximumRetainedBytes:Int=512*1024*1024)async throws->[UUID:SolidSurface] {
    var results:[UUID:SolidSurface]=[:],bytes=0,seen=Set<UUID>()
    for object in project.objects where objectIDs?.contains(object.id) ?? true {
      guard let recipe=project.recipe(object.recipeID),let definition=recipe.solid else{continue}
      try Task.checkCancellation()
      let surface:SolidSurface
      if let cached=try cachedSurface(definition,parameters:object.parameters) {surface=cached}
      else {
        let cancellation=OrganicMeshCancellation()
        let worker=Task.detached(priority:.userInitiated){try await SolidSurfaceWorkPool.build(recipe:recipe,parameters:object.parameters,preview:false,cancellation:cancellation)}
        surface=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{cancellation.cancel();worker.cancel()})
        try Task.checkCancellation();try remember(surface,definition:definition,parameters:object.parameters)
      }
      guard !surface.isEditingPreview else{throw FormError.invalid("A full-detail solid capture cannot use editing geometry.")}
      if seen.insert(surface.storageID).inserted {bytes+=surface.byteCount}
      guard bytes<=max(1,min(512*1024*1024,maximumRetainedBytes)) else{throw FormError.invalid("Full-detail solid capture exceeds its 512 MB source buffer budget.")}
      results[object.id]=surface
    }
    return results
  }

  static func surface(_ definition: ParametricSolid, parameters: [String: Double]) throws -> (positions: [SIMD3<Double>], indices: [UInt32], normals: [SIMD3<Double>]) {
    let result: SolidSurface
    if let stored = try cachedSurface(definition, parameters: parameters) { result = stored }
    else {
      result = try SolidSurfaceBuilder.build(definition, parameters: parameters)
      try remember(result, definition: definition, parameters: parameters)
    }
    return (result.positions, result.indices, result.normals)
  }

  static func make(_ object: ProductObject, definition: ParametricSolid, project: Project) throws -> MeshNode {
    let result: SolidSurface
    if let stored = try cachedSurface(definition, parameters: object.parameters) { result = stored }
    else {
      result = try SolidSurfaceBuilder.build(definition, parameters: object.parameters)
      try remember(result, definition: definition, parameters: object.parameters)
    }
    return make(object, from: result, project: project)
  }

  static func make(_ object: ProductObject, from surface: SolidSurface, project: Project) -> MeshNode {
    let root = MeshNode()
    root.name = "solid.construction"
    let material = GeometryFactory.material(object, project: project)
    for (index, chunk) in surface.displayChunks.enumerated() {
      let geometry = MeshGeometry(
        sources: [.init(values: chunk.positions, components: 3, semantic: .vertex), .init(values: chunk.normals, components: 3, semantic: .normal)],
        elements: [.init(indices: chunk.indices, primitiveType: .triangles)]
      )
      let node = GeometryFactory.solid(geometry, material)
      node.name = "solid.surface.\(index)"
      root.addChildNode(node)
    }
    return root
  }
}

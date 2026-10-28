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

  private static func key(_ definition: ParametricSolid, parameters: [String: Double], isEditingPreview: Bool) throws -> NSString {
    var signature = try JSONEncoder.form.encode(definition)
    signature.append(try JSONEncoder.form.encode(parameters))
    signature.append(isEditingPreview ? 1 : 0)
    return SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined() as NSString
  }

  static func cachedSurface(_ definition: ParametricSolid, parameters: [String: Double], useEditingPreview: Bool = false) throws -> SolidSurface? {
    let isPreview = useEditingPreview && definition.previewNodes != nil
    return cache.object(forKey: try key(definition, parameters: parameters, isEditingPreview: isPreview))?.surface
  }

  static func remember(_ surface: SolidSurface, definition: ParametricSolid, parameters: [String: Double]) throws {
    // Large finished meshes can still be displayed/exported, but must not evict
    // the entire small-preview cache merely by exceeding its total budget.
    guard surface.byteCount <= cache.totalCostLimit else { return }
    cache.setObject(CacheValue(surface), forKey: try key(definition, parameters: parameters, isEditingPreview: surface.isEditingPreview), cost: surface.byteCount)
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

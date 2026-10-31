import FormCore
import FormGeometry
import Foundation
import simd

/// Immutable CPU geometry transferred from a modeling worker to the native view.
/// Buffer preparation deliberately stays with construction, away from the main
/// actor; scene objects and materials are created only by the display adapter.
struct SolidSurface: Sendable {
  struct DisplayChunk: Sendable {
    /// Display coordinates use the historical 100 mm construction unit.
    let positions: [Double]
    let normals: [Double]
    let indices: [UInt32]
    var byteCount: Int { (positions.capacity + normals.capacity) * MemoryLayout<Double>.stride + indices.capacity * MemoryLayout<UInt32>.stride }
  }

  let positions: [SIMD3<Double>]
  let indices: [UInt32]
  let normals: [SIMD3<Double>]
  let displayChunks: [DisplayChunk]
  let isEditingPreview: Bool
  var byteCount: Int {
    (positions.capacity + normals.capacity) * MemoryLayout<SIMD3<Double>>.stride
      + indices.capacity * MemoryLayout<UInt32>.stride
      + displayChunks.reduce(0) { $0 + $1.byteCount }
  }
}

/// Pure, synchronous CPU work with Sendable inputs/output. Call from a detached
/// task for interactive use. The authoritative construction is always selected
/// unless the caller explicitly requests a project-authored editing preview.
enum SolidSurfaceBuilder {
  static func build(_ definition: ParametricSolid, parameters: [String: Double], useEditingPreview: Bool = false) throws -> SolidSurface {
    try Task.checkCancellation()
    var source = definition
    let isPreview = useEditingPreview && definition.previewNodes != nil
    if isPreview { source.nodes = definition.previewNodes! }
    let construction = try source.evaluate(parameters)
    try Task.checkCancellation()

    var solid = OrganicSolid()
    for (index, primitive) in construction.primitives.enumerated() {
      if index % 128 == 0 { try Task.checkCancellation() }
      let values = primitive.values
      let center = SIMD3(values["x"]!, values["y"]!, values["z"]!)
      if primitive.kind == "segment" {
        solid.segment(center, .init(values["endX"]!, values["endY"]!, values["endZ"]!), values["radius"]!, values["endRadius"]!, aspect: values["aspect"] ?? 1, endAspect: values["endAspect"] ?? 1, roll: values["roll"] ?? 0, blend: values["blend"] ?? 0)
      } else {
        solid.ellipsoid(center, radii: .init(values["radiusX"]!, values["radiusY"]!, values["radiusZ"]!), axis: .init(values["axisX"] ?? 0, values["axisY"] ?? 1, values["axisZ"] ?? 0), roll: values["roll"] ?? 0, blend: values["blend"] ?? 0)
      }
    }
    var positions: [SIMD3<Double>] = [], indices: [UInt32] = [], normals: [SIMD3<Double>] = []
    if !construction.primitives.isEmpty {
      try Task.checkCancellation()
      let sampled = try solid.mesh(spacing: construction.spacing, floorY: construction.floorY, fillVoids: construction.fillVoids)
      try Task.checkCancellation()
      positions = sampled.positions
      indices = sampled.indices
      normals = Array(repeating: .zero, count: positions.count)
      for i in stride(from: 0, to: indices.count, by: 3) {
        if i % 12_000 == 0 { try Task.checkCancellation() }
        let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
        let normal = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
        normals[a] += normal; normals[b] += normal; normals[c] += normal
      }
      for i in normals.indices {
        if i % 4096 == 0 { try Task.checkCancellation() }
        normals[i] = simd_length_squared(normals[i]) > 1e-24 ? simd_normalize(normals[i]) : .init(0, 1, 0)
      }
    }
    for sweep in construction.sweeps {
      try Task.checkCancellation()
      let sections = sweep.sections.map { values in
        SweepSection(center: .init(values["x"]!, values["y"]!, values["z"]!), radii: .init(values["radiusX"]!, values["radiusY"]!), roll: values["roll"] ?? 0)
      }
      let profile = sweep.profile.map { $0.map { SIMD2<Double>($0[0], $0[1]) } } ?? AnalyticSweep.ellipseProfile(segments: sweep.sides)
      let normal = sweep.initialNormal.map { SIMD3<Double>($0[0], $0[1], $0[2]) }
      let analytic = try AnalyticSweep.mesh(sections: sections, profile: profile, initialNormal: normal, smoothProfile: sweep.smoothProfile)
      guard indices.count + analytic.indices.count <= 6_000_000, positions.count + analytic.positions.count <= 4_000_000 else {
        throw FormError.invalid("Combined construction exceeds two million triangles or four million indexed vertices.")
      }
      let offset = UInt32(positions.count)
      positions.append(contentsOf: analytic.positions)
      normals.append(contentsOf: analytic.normals)
      indices.append(contentsOf: analytic.indices.map { $0 + offset })
    }
    if let height = construction.normalizeHeight {
      var low = Double.infinity, high = -Double.infinity
      for point in positions { low = min(low, point.y); high = max(high, point.y) }
      guard low.isFinite, high.isFinite, high - low > 1e-12 else { throw FormError.invalid("A normalized construction must have a nonzero vertical extent.") }
      let scale = height / (high - low)
      for i in positions.indices {
        if i % 4096 == 0 { try Task.checkCancellation() }
        positions[i] = .init(positions[i].x * scale, (positions[i].y - low) * scale, positions[i].z * scale)
      }
    }
    let displayChunks = try prepareChunks(positions: positions, normals: normals, indices: indices)
    try Task.checkCancellation()
    return .init(positions: positions, indices: indices, normals: normals, displayChunks: displayChunks, isEditingPreview: isPreview)
  }

  private static func prepareChunks(positions: [SIMD3<Double>], normals: [SIMD3<Double>], indices: [UInt32]) throws -> [SolidSurface.DisplayChunk] {
    var chunks: [SolidSurface.DisplayChunk] = []
    for offset in stride(from: 0, to: indices.count, by: 600_000) {
      try Task.checkCancellation()
      let end = min(offset + 600_000, indices.count)
      var remap: [UInt32: UInt32] = [:], vertices: [Double] = [], vertexNormals: [Double] = [], localIndices: [UInt32] = []
      localIndices.reserveCapacity(end - offset)
      for i in offset..<end {
        if i % 12_000 == 0 { try Task.checkCancellation() }
        let id = indices[i]
        if let local = remap[id] { localIndices.append(local) }
        else {
          let local = UInt32(vertices.count / 3), point = positions[Int(id)] / 100, normal = normals[Int(id)]
          remap[id] = local
          vertices.append(contentsOf: [point.x, point.y, point.z])
          vertexNormals.append(contentsOf: [normal.x, normal.y, normal.z])
          localIndices.append(local)
        }
      }
      chunks.append(.init(positions: vertices, normals: vertexNormals, indices: localIndices))
    }
    return chunks
  }
}

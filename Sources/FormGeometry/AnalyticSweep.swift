import CFormMesher
import Foundation
import simd

/// One sampled section of an analytic sweep. All coordinates and radii are in
/// the caller's physical units; no voxel grid or implicit rounding is applied.
public struct SweepSection: Equatable, Sendable {
  public var center: SIMD3<Double>
  public var radii: SIMD2<Double>
  /// Rotation about the transported path tangent, in radians.
  public var roll: Double

  public init(center: SIMD3<Double>, radii: SIMD2<Double>, roll: Double = 0) {
    self.center = center
    self.radii = radii
    self.roll = roll
  }
}

/// An indexed CPU surface, usable by display and export adapters alike. Cap
/// vertices are split from side vertices to retain the authored edge character.
public struct AnalyticSweepMesh: Sendable {
  public let positions: [SIMD3<Double>]
  public let normals: [SIMD3<Double>]
  public let indices: [UInt32]

  public func geometry() -> MeshGeometry {
    MeshGeometry(
      sources: [.init(vertices: positions.map(MeshVector3.init)), .init(normals: normals.map(MeshVector3.init))],
      elements: [.init(indices: indices, primitiveType: .triangles)]
    )
  }
}

public enum AnalyticSweepError: Error, LocalizedError, Equatable {
  case invalidSections
  case invalidProfile
  case invalidOrientation
  case exceedsBudget
  case triangulationFailed

  public var errorDescription: String? {
    switch self {
    case .invalidSections: return "A sweep needs finite, distinct path samples and positive section radii."
    case .invalidProfile: return "A sweep profile must be a finite, simple closed polygon with at least three distinct points."
    case .invalidOrientation: return "The sweep orientation is parallel to its path, or the path reverses direction at a section."
    case .exceedsBudget: return "The sweep exceeds the bounded tessellation budget."
    case .triangulationFailed: return "The sweep profile could not be capped."
    }
  }
}

/// Directly tessellates authored closed profiles along a sampled centerline.
/// Parallel transport avoids the spinning and singularities of Frenet frames.
/// This constructs a surface, not a Boolean union or self-intersection repair.
public enum AnalyticSweep {
  /// A normalized circular profile. Scaling its two axes at each section gives
  /// circular, elliptical, flattened, or tapered constructions without changing
  /// the resolution of unrelated objects in a project.
  public static func ellipseProfile(segments: Int = 32) -> [SIMD2<Double>] {
    let count = max(3, min(512, segments))
    return (0..<count).map { i in
      let angle = Double(i) * 2 * Double.pi / Double(count)
      return .init(cos(angle), sin(angle))
    }
  }

  /// `profile` is a simple polygon in section coordinates; clockwise input is
  /// accepted and normalized. Repeating the first point at the end is optional.
  /// `initialNormal` fixes the first profile's X axis. Subsequent sections use
  /// minimum-rotation transport, followed by their individual `roll` values.
  /// With `smoothProfile: false`, each profile edge retains its own side normal.
  /// Positive radii retain real, capped tip dimensions instead of degeneracies.
  public static func mesh(
    sections: [SweepSection],
    profile rawProfile: [SIMD2<Double>],
    initialNormal: SIMD3<Double>? = nil,
    capped: Bool = true,
    smoothProfile: Bool = true
  ) throws -> AnalyticSweepMesh {
    guard sections.count >= 2 else { throw AnalyticSweepError.invalidSections }
    guard sections.count <= 4096, rawProfile.count <= 513 else { throw AnalyticSweepError.exceedsBudget }
    guard sections.allSatisfy({ finite($0.center) && finite($0.radii) && $0.radii.x > 0 && $0.radii.y > 0 && $0.roll.isFinite }) else {
      throw AnalyticSweepError.invalidSections
    }
    var profile = rawProfile
    if profile.count > 3, profile.first == profile.last { profile.removeLast() }
    try validateProfile(profile)
    let signedArea = profile.indices.reduce(0.0) { sum, i in
      sum + cross(profile[i], profile[(i + 1) % profile.count])
    }
    if signedArea < 0 { profile.reverse() }
    let count = profile.count
    let perRing = smoothProfile ? count : count * 2
    guard sections.count * perRing + (capped ? count * 2 : 0) <= 2_000_000 else {
      throw AnalyticSweepError.exceedsBudget
    }

    var directions: [SIMD3<Double>] = []
    directions.reserveCapacity(sections.count - 1)
    for i in 0..<sections.count - 1 {
      let delta = sections[i + 1].center - sections[i].center
      guard simd_length_squared(delta) > 1e-20 else { throw AnalyticSweepError.invalidSections }
      directions.append(simd_normalize(delta))
    }
    var tangents = [directions[0]]
    for i in 1..<sections.count - 1 {
      let sum = directions[i - 1] + directions[i]
      guard simd_length_squared(sum) > 1e-12 else { throw AnalyticSweepError.invalidOrientation }
      tangents.append(simd_normalize(sum))
    }
    tangents.append(directions.last!)
    let startTangent = tangents[0]
    let reference = initialNormal ?? leastAlignedAxis(startTangent)
    guard finite(reference) else { throw AnalyticSweepError.invalidOrientation }
    var transported = reference - startTangent * simd_dot(reference, startTangent)
    guard simd_length_squared(transported) > 1e-20 else { throw AnalyticSweepError.invalidOrientation }
    transported = simd_normalize(transported)

    var rings: [[SIMD3<Double>]] = []
    rings.reserveCapacity(sections.count)
    for i in sections.indices {
      let tangent = tangents[i]
      if i > 0 {
        guard simd_dot(tangents[i - 1], tangent) > -0.999999999 else { throw AnalyticSweepError.invalidOrientation }
        transported = simd_quatd(from: tangents[i - 1], to: tangent).act(transported)
        // Re-orthogonalization bounds drift on long or nearly straight paths.
        transported = simd_normalize(transported - tangent * simd_dot(transported, tangent))
      }
      let unrolledY = simd_cross(tangent, transported)
      let x = transported * cos(sections[i].roll) + unrolledY * sin(sections[i].roll)
      let y = simd_cross(tangent, x)
      rings.append(profile.map {
        sections[i].center + x * ($0.x * sections[i].radii.x) + y * ($0.y * sections[i].radii.y)
      })
    }

    var positions: [SIMD3<Double>] = []
    positions.reserveCapacity(sections.count * perRing + (capped ? count * 2 : 0))
    for ring in rings {
      if smoothProfile { positions.append(contentsOf: ring) }
      else {
        for i in profile.indices { positions.append(ring[i]); positions.append(ring[(i + 1) % count]) }
      }
    }
    var normals = Array(repeating: SIMD3<Double>.zero, count: positions.count)
    var indices: [UInt32] = []
    indices.reserveCapacity((sections.count - 1) * count * 6 + (capped ? (count - 2) * 6 : 0))
    func triangle(_ a: Int, _ b: Int, _ c: Int) throws {
      let normal = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
      guard finite(normal), simd_length_squared(normal) > 1e-28 else { throw AnalyticSweepError.invalidSections }
      indices.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
      normals[a] += normal; normals[b] += normal; normals[c] += normal
    }
    for j in 0..<sections.count - 1 {
      for i in profile.indices {
        let a = j * perRing + (smoothProfile ? i : i * 2)
        let b = j * perRing + (smoothProfile ? (i + 1) % count : i * 2 + 1)
        let c = b + perRing, d = a + perRing
        try triangle(a, b, c)
        try triangle(a, c, d)
      }
    }
    for i in normals.indices {
      guard simd_length_squared(normals[i]) > 1e-28 else { throw AnalyticSweepError.invalidSections }
      normals[i] = simd_normalize(normals[i])
    }
    if capped {
      let cap = try triangulate(profile)
      for end in [false, true] {
        let start = positions.count
        let ringIndex = end ? rings.count - 1 : 0
        positions.append(contentsOf: rings[ringIndex])
        normals.append(contentsOf: Array(repeating: tangents[ringIndex] * (end ? 1 : -1), count: count))
        for i in stride(from: 0, to: cap.count, by: 3) {
          let a = UInt32(start) + cap[i]
          let b = UInt32(start) + cap[i + (end ? 1 : 2)]
          let c = UInt32(start) + cap[i + (end ? 2 : 1)]
          indices.append(contentsOf: [a, b, c])
        }
      }
    }
    return .init(positions: positions, normals: normals, indices: indices)
  }

  private static func finite(_ p: SIMD3<Double>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
  private static func finite(_ p: SIMD2<Double>) -> Bool { p.x.isFinite && p.y.isFinite }
  private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
  private static func leastAlignedAxis(_ tangent: SIMD3<Double>) -> SIMD3<Double> {
    if abs(tangent.x) <= abs(tangent.y), abs(tangent.x) <= abs(tangent.z) { return .init(1, 0, 0) }
    return abs(tangent.y) <= abs(tangent.z) ? .init(0, 1, 0) : .init(0, 0, 1)
  }

  private static func validateProfile(_ p: [SIMD2<Double>]) throws {
    guard p.count >= 3, p.count <= 512, p.allSatisfy(finite) else { throw AnalyticSweepError.invalidProfile }
    let extent = p.reduce(0.0) { max($0, abs($1.x), abs($1.y)) }
    guard extent > 1e-12, extent < 1e12 else { throw AnalyticSweepError.invalidProfile }
    let tolerance = extent * extent * 1e-12
    func orientation(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double { cross(b - a, c - a) }
    func onSegment(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ q: SIMD2<Double>) -> Bool {
      abs(orientation(a, b, q)) <= tolerance && q.x >= min(a.x, b.x) - 1e-12 * extent && q.x <= max(a.x, b.x) + 1e-12 * extent && q.y >= min(a.y, b.y) - 1e-12 * extent && q.y <= max(a.y, b.y) + 1e-12 * extent
    }
    for i in p.indices {
      let a = p[i], b = p[(i + 1) % p.count]
      guard simd_length_squared(b - a) > tolerance * 1e-12 else { throw AnalyticSweepError.invalidProfile }
      let previous = p[(i + p.count - 1) % p.count]
      guard abs(orientation(previous, a, b)) > tolerance else { throw AnalyticSweepError.invalidProfile }
      for j in i + 1..<p.count {
        if j == i + 1 || (i == 0 && j == p.count - 1) { continue }
        let c = p[j], d = p[(j + 1) % p.count]
        let abC = orientation(a, b, c), abD = orientation(a, b, d)
        let cdA = orientation(c, d, a), cdB = orientation(c, d, b)
        if (abC > tolerance && abD < -tolerance || abC < -tolerance && abD > tolerance) && (cdA > tolerance && cdB < -tolerance || cdA < -tolerance && cdB > tolerance) {
          throw AnalyticSweepError.invalidProfile
        }
        if onSegment(a, b, c) || onSegment(a, b, d) || onSegment(c, d, a) || onSegment(c, d, b) { throw AnalyticSweepError.invalidProfile }
      }
    }
    let area = p.indices.reduce(0.0) { $0 + cross(p[$1], p[($1 + 1) % p.count]) }
    guard abs(area) > tolerance else { throw AnalyticSweepError.invalidProfile }
  }

  private static func triangulate(_ profile: [SIMD2<Double>]) throws -> [UInt32] {
    let xy = profile.flatMap { [$0.x, $0.y] }
    let sizes = [UInt32(profile.count)]
    var result = FMIndexBuffer()
    let status = xy.withUnsafeBufferPointer { points in
      sizes.withUnsafeBufferPointer { rings in
        fm_triangulate(points.baseAddress, profile.count, rings.baseAddress, sizes.count, &result)
      }
    }
    defer { fm_free_indices(&result) }
    guard status == 0, let raw = result.indices, result.count == (profile.count - 2) * 3 else { throw AnalyticSweepError.triangulationFailed }
    var triangles = Array(UnsafeBufferPointer(start: raw, count: result.count))
    for i in stride(from: 0, to: triangles.count, by: 3) {
      let a = profile[Int(triangles[i])], b = profile[Int(triangles[i + 1])], c = profile[Int(triangles[i + 2])]
      if cross(b - a, c - a) < 0 { triangles.swapAt(i + 1, i + 2) }
    }
    return triangles
  }
}

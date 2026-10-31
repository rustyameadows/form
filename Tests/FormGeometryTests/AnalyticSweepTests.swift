import XCTest
@testable import FormGeometry
import simd

final class AnalyticSweepTests: XCTestCase {
  private struct Point: Hashable {
    let x: Int64, y: Int64, z: Int64
    init(_ p: SIMD3<Double>) { x = Int64((p.x * 1e8).rounded()); y = Int64((p.y * 1e8).rounded()); z = Int64((p.z * 1e8).rounded()) }
  }
  private struct Edge: Hashable {
    let a: Int, b: Int
    init(_ a: Int, _ b: Int) { self.a = min(a, b); self.b = max(a, b) }
  }
  private func audit(_ mesh: AnalyticSweepMesh, file: StaticString = #filePath, line: UInt = #line) -> Double {
    XCTAssertEqual(mesh.positions.count, mesh.normals.count, file: file, line: line)
    XCTAssertTrue(mesh.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && abs(simd_length($0) - 1) < 1e-10 }, file: file, line: line)
    var points: [Point: Int] = [:], remap: [Int] = [], edges: [Edge: (count: Int, direction: Int)] = [:]
    for p in mesh.positions {
      let key = Point(p)
      if let i = points[key] { remap.append(i) }
      else { let i = points.count; points[key] = i; remap.append(i) }
    }
    var volume = 0.0
    for i in stride(from: 0, to: mesh.indices.count, by: 3) {
      let a = Int(mesh.indices[i]), b = Int(mesh.indices[i + 1]), c = Int(mesh.indices[i + 2])
      XCTAssertTrue(a < mesh.positions.count && b < mesh.positions.count && c < mesh.positions.count, file: file, line: line)
      let p = mesh.positions[a], q = mesh.positions[b], r = mesh.positions[c], normal = simd_cross(q - p, r - p)
      XCTAssertGreaterThan(simd_length_squared(normal), 1e-28, file: file, line: line)
      XCTAssertGreaterThan(simd_dot(normal, mesh.normals[a] + mesh.normals[b] + mesh.normals[c]), 0, file: file, line: line)
      volume += simd_dot(p, simd_cross(q, r)) / 6
      for (x, y) in [(remap[a], remap[b]), (remap[b], remap[c]), (remap[c], remap[a])] {
        let key = Edge(x, y), previous = edges[key] ?? (0, 0)
        edges[key] = (previous.count + 1, previous.direction + (x < y ? 1 : -1))
      }
    }
    XCTAssertTrue(edges.values.allSatisfy { $0.count == 2 && $0.direction == 0 }, "Every welded edge must have two oppositely wound adjacent faces.", file: file, line: line)
    XCTAssertGreaterThan(volume, 0, file: file, line: line)
    return volume
  }

  func testEllipticalTaperIsClosedOutwardAndIndependentOfScale() throws {
    let sections: [SweepSection] = [
      .init(center: .init(0, 0, 0), radii: .init(3, 1)),
      .init(center: .init(0, 12, 0), radii: .init(1.5, 0.5)),
      .init(center: .init(0, 20, 0), radii: .init(0.15, 0.08))
    ]
    let profile = AnalyticSweep.ellipseProfile(segments: 48)
    let mesh = try AnalyticSweep.mesh(sections: sections, profile: profile, initialNormal: .init(1, 0, 0))
    let volume = audit(mesh)
    XCTAssertEqual(mesh.positions.count, 5 * 48)
    XCTAssertEqual(mesh.indices.count / 3, 4 * 48 + 2 * 46)
    let larger = try AnalyticSweep.mesh(sections: sections.map { .init(center: $0.center * 6, radii: $0.radii * 6, roll: $0.roll) }, profile: profile, initialNormal: .init(1, 0, 0))
    XCTAssertEqual(larger.indices, mesh.indices)
    XCTAssertEqual(audit(larger), volume * 216, accuracy: volume * 1e-9)
    XCTAssertEqual(mesh.geometry().sources(for: .normal).first?.vectorCount, mesh.positions.count)
  }

  func testAsymmetricBeveledPolygonRetainsCrispSidesAndCorrectConcaveCaps() throws {
    // An asymmetric lipped section, useful for trim, ribs, handles, and folded
    // constructions. Its re-entrant corner requires a real cap triangulation.
    let profile: [SIMD2<Double>] = [
      .init(-1, -0.4), .init(0.8, -0.4), .init(1, -0.2), .init(1, 0.15),
      .init(0.7, 0.4), .init(0.05, 0.4), .init(0.05, 0.05), .init(-1, 0.05)
    ]
    let sections: [SweepSection] = (0...16).map { i in
      let t = Double(i) / 16
      return .init(center: .init(2 * t * t, 15 * t, sin(t) * 1.5), radii: .init(1.1 - t * 0.5, 0.8 + t * 0.2), roll: t * 0.2)
    }
    let mesh = try AnalyticSweep.mesh(sections: sections, profile: profile, initialNormal: .init(1, 0, 0), smoothProfile: false)
    _ = audit(mesh)
    XCTAssertEqual(mesh.positions.count, sections.count * profile.count * 2 + profile.count * 2)
    // Adjacent profile edges use coincident positions and distinct normals.
    XCTAssertEqual(mesh.positions[1], mesh.positions[2])
    XCTAssertLessThan(simd_dot(mesh.normals[1], mesh.normals[2]), 0.9)
    let clockwise = try AnalyticSweep.mesh(sections: sections, profile: profile.reversed(), initialNormal: .init(1, 0, 0), smoothProfile: false)
    XCTAssertEqual(audit(clockwise), audit(mesh), accuracy: 1e-9)
  }

  func testTransportCrossesVerticalWithoutFrameFlipsAndIsDeterministic() throws {
    let sections: [SweepSection] = (0...100).map { i in
      let t = Double(i) / 100
      return .init(center: .init(0.2 * cos(t * .pi), 20 * t, 0.3 * sin(t * .pi)), radii: .init(1, 0.2))
    }
    let profile = AnalyticSweep.ellipseProfile(segments: 16)
    let first = try AnalyticSweep.mesh(sections: sections, profile: profile)
    let second = try AnalyticSweep.mesh(sections: sections, profile: profile)
    XCTAssertEqual(first.positions, second.positions)
    XCTAssertEqual(first.normals, second.normals)
    XCTAssertEqual(first.indices, second.indices)
    _ = audit(first)
    for i in 1..<sections.count {
      let previous = simd_normalize(first.positions[(i - 1) * 16] - sections[i - 1].center)
      let current = simd_normalize(first.positions[i * 16] - sections[i].center)
      XCTAssertGreaterThan(simd_dot(previous, current), 0.999)
    }
  }

  func testRejectsInvalidProfilesAndSamplesRatherThanProducingBrokenTriangles() throws {
    let sections: [SweepSection] = [.init(center: .zero, radii: .init(1, 1)), .init(center: .init(0, 2, 0), radii: .init(1, 1))]
    let circle = AnalyticSweep.ellipseProfile(segments: 8)
    for profile: [SIMD2<Double>] in [
      [.init(-1, -1), .init(1, 1), .init(-1, 1), .init(1, -1)],
      [.init(0, 0), .init(1, 0), .init(2, 0)],
      [.init(0, 0), .init(1, 0), .init(2, 0), .init(2, 1), .init(0, 1)],
      [.init(0, 0), .init(1, 0), .init(1, 0), .init(0, 1)],
      [.init(0, 0), .init(.nan, 0), .init(0, 1)]
    ] {
      XCTAssertThrowsError(try AnalyticSweep.mesh(sections: sections, profile: profile)) { XCTAssertEqual($0 as? AnalyticSweepError, .invalidProfile) }
    }
    XCTAssertThrowsError(try AnalyticSweep.mesh(sections: [sections[0], sections[0]], profile: circle))
    XCTAssertThrowsError(try AnalyticSweep.mesh(sections: sections, profile: circle, initialNormal: .init(0, 1, 0)))
    XCTAssertThrowsError(try AnalyticSweep.mesh(sections: sections + [.init(center: .zero, radii: .init(1, 1))], profile: circle))
    XCTAssertThrowsError(try AnalyticSweep.mesh(sections: [.init(center: .zero, radii: .init(-1, 1)), sections[1]], profile: circle))
    let closed = try AnalyticSweep.mesh(sections: sections, profile: circle + [circle[0]])
    _ = audit(closed)
  }
}

import AppKit
import FormCore
import SceneKit

@MainActor enum PrintMeshBuilder {
  static func mesh(
    object: ProductObject, project: Project, assets: URL, configuration: PrintConfiguration
  ) throws -> PrintMesh {
    let root = GeometryFactory.object(object, project: project, assets: assets)
    if object.recipeID == "lamp" {
      let index = ["Base": 0, "Stem": 1, "Shade": 2][configuration.component]
      for (i, node) in root.childNodes.enumerated() where index != nil ? i != index : i == 3 {
        node.removeFromParentNode()
      }
    }
    var triangles: [MeshTriangle] = []
    var failure: Error?
    root.enumerateChildNodes { node, stop in
      guard let geometry = node.geometry, !(geometry is SCNPlane),
        let source = geometry.sources(for: .vertex).first
      else { return }
      guard source.usesFloatComponents, [4, 8].contains(source.bytesPerComponent),
        source.componentsPerVector >= 3
      else {
        failure = FormError.invalid("Unsupported mesh vertex format.")
        stop.pointee = true
        return
      }
      func vertex(_ index: Int) -> Vector3 {
        let base = source.dataOffset + index * source.dataStride
        let values: [Double] = source.data.withUnsafeBytes { bytes in
          (0..<3).map { i in
            let offset = base + i * source.bytesPerComponent
            return source.bytesPerComponent == 4
              ? Double(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self))
              : bytes.loadUnaligned(fromByteOffset: offset, as: Double.self)
          }
        }
        let p = node.convertPosition(SCNVector3(values[0], values[1], values[2]), to: root)
        var point = Vector3(Double(p.x) * 100, -Double(p.z) * 100, Double(p.y) * 100)
        let rotation = configuration.rotation
        for (axis, degrees) in [(0, rotation.x), (1, rotation.y), (2, rotation.z)] {
          let a = degrees * .pi / 180
          let c = cos(a)
          let s = sin(a)
          let old = point
          if axis == 0 {
            point.y = old.y * c - old.z * s
            point.z = old.y * s + old.z * c
          }
          if axis == 1 {
            point.x = old.x * c + old.z * s
            point.z = -old.x * s + old.z * c
          }
          if axis == 2 {
            point.x = old.x * c - old.y * s
            point.y = old.x * s + old.y * c
          }
        }
        let scale = configuration.scalePercent / 100
        return .init(point.x * scale, point.y * scale, point.z * scale)
      }
      for element in geometry.elements {
        guard [.triangles, .triangleStrip].contains(element.primitiveType) else { continue }
        let data = element.data
        let width = element.bytesPerIndex
        guard [1, 2, 4].contains(width) else { continue }
        let indices: [Int] = data.withUnsafeBytes { bytes in
          (0..<data.count / width).map { i in
            if width == 1 { return Int(bytes[i]) }
            if width == 2 {
              return Int(bytes.loadUnaligned(fromByteOffset: i * width, as: UInt16.self))
            }
            return Int(bytes.loadUnaligned(fromByteOffset: i * width, as: UInt32.self))
          }
        }
        let count =
          element.primitiveType == .triangles ? indices.count / 3 : max(0, indices.count - 2)
        for i in 0..<count {
          let a: Int
          let b: Int
          let c: Int
          if element.primitiveType == .triangles {
            a = indices[i * 3]
            b = indices[i * 3 + 1]
            c = indices[i * 3 + 2]
          } else {
            a = indices[i]
            b = indices[i + (i % 2 == 0 ? 1 : 2)]
            c = indices[i + (i % 2 == 0 ? 2 : 1)]
          }
          guard a < source.vectorCount, b < source.vectorCount, c < source.vectorCount else {
            continue
          }
          if a != b, b != c, a != c { triangles.append(.init(vertex(a), vertex(b), vertex(c))) }
        }
      }
    }
    if let failure { throw failure }
    guard !triangles.isEmpty else {
      throw FormError.invalid("This object has no printable solid geometry.")
    }
    return .init(triangles: triangles)
  }
}

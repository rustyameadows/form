import FormGeometry
import simd

@MainActor enum SheetPanelMeshTransform {
  static func apply(_ source:MeshGeometry,matrix:simd_double4x4)->MeshGeometry {
    let normalMatrix=matrix.inverse.transpose
    let positions=(source.sources(for:.vertex).first?.vectors ?? []).map { p -> MeshVector3 in
      let v=matrix*SIMD4(p.simd,1);return .init(v.x/v.w,v.y/v.w,v.z/v.w)
    }
    let normals=(source.sources(for:.normal).first?.vectors ?? []).map { n -> MeshVector3 in
      let v=normalMatrix*SIMD4(n.simd,0);return .init(simd_normalize(SIMD3(v.x,v.y,v.z)))
    }
    let mesh=MeshGeometry(sources:[.init(vertices:positions),.init(normals:normals)]+source.sources(for:.texcoord),elements:source.elements)
    mesh.materials=source.materials;mesh.name=source.name;return mesh
  }
}

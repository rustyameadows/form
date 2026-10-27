import AppKit
import FormGeometry
import FormCore

/// Bounded open-surface presentation. Topology and material UV sources are reused
/// while only vertex/normal sources change. Scene units match FORM: 100 mm/unit.
@MainActor public final class ClothSurface {
  public let node:MeshNode
  public let mesh:ClothMesh
  public let material:MeshMaterial
  public let panelIDsByGeometryElement:[Int]
  private let uvSource:MeshGeometrySource
  private let elements:[MeshGeometryElement]
  private let materials:[MeshMaterial]
  public private(set) var bounds:ClothBounds
  public convenience init(mesh:ClothMesh,frame:ClothFrame,material:MeshMaterial)throws {
    try self.init(mesh:mesh,frame:frame,panelMaterials:[:],fallbackMaterial:material)
  }
  public init(mesh:ClothMesh,frame:ClothFrame,panelMaterials:[Int:MeshMaterial],fallbackMaterial:MeshMaterial)throws {
    try mesh.validate()
    guard !mesh.triangles.isEmpty,mesh.uv.count==mesh.restPositionsMm.count else {throw FormError.invalid("Native cloth preview requires triangles and fixed material UV coordinates.")}
    self.mesh=mesh
    let panels=Array(Set(mesh.panelIDs ?? [0])).sorted();panelIDsByGeometryElement=panels
    // Preserve the original single-material API: updating .material must still
    // affect every panel when no per-panel assignments were requested.
    let shared=panelMaterials.isEmpty ? fallbackMaterial.copy() as? MeshMaterial:nil
    shared?.isDoubleSided=true
    let copies=panels.map {panel -> MeshMaterial in
      if let shared {return shared}
      let copy=(panelMaterials[panel] ?? fallbackMaterial).copy() as! MeshMaterial;copy.isDoubleSided=true;return copy
    }
    materials=copies;self.material=copies[0]
    // SceneKit samples NSImage in image coordinates. Material v already points down
    // the artwork; flipping it here mirrors printed type and placement vertically.
    uvSource=MeshGeometrySource(textureCoordinates:mesh.uv.map {CGPoint(x:$0.x,y:$0.y)})
    elements=panels.map {panel in
      let indices=mesh.triangles.filter {(mesh.panelIDs?[$0.a] ?? 0)==panel}.flatMap {[UInt32($0.a),UInt32($0.b),UInt32($0.c)]}
      return MeshGeometryElement(indices:indices,primitiveType:.triangles)
    }
    bounds=try ClothBounds(positionsMm:frame.positionsMm)
    node=MeshNode();node.name="Simulated open cloth surface"
    try update(frame)
  }
  public func update(_ frame:ClothFrame)throws {
    guard frame.positionsMm.count==mesh.restPositionsMm.count,frame.normals.count==mesh.restPositionsMm.count,
      frame.positionsMm.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && max(abs($0.x),abs($0.y),abs($0.z))<=10_000_000}),
      frame.normals.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && abs($0.x*$0.x+$0.y*$0.y+$0.z*$0.z-1)<1e-4}) else {throw FormError.invalid("Native cloth preview needs a finite matching position/normal frame.")}
    let geometry=MeshGeometry(sources:[MeshGeometrySource(vertices:frame.positionsMm.map {MeshVector3(Float($0.x/100),Float($0.y/100),Float($0.z/100))}),MeshGeometrySource(normals:frame.normals.map {MeshVector3(Float($0.x),Float($0.y),Float($0.z))}),uvSource],elements:elements)
    geometry.materials=materials
    let nextBounds=try ClothBounds(positionsMm:frame.positionsMm)
    node.geometry=geometry;bounds=nextBounds
  }
}

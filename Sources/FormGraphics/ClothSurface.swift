import AppKit
import SceneKit
import FormCore

/// Bounded open-surface presentation. Topology and material UV sources are reused
/// while only vertex/normal sources change. Scene units match FORM: 100 mm/unit.
@MainActor public final class ClothSurface {
  public let node:SCNNode
  public let mesh:ClothMesh
  public let material:SCNMaterial
  private let uvSource:SCNGeometrySource
  private let element:SCNGeometryElement
  public private(set) var bounds:ClothBounds
  public init(mesh:ClothMesh,frame:ClothFrame,material:SCNMaterial)throws {
    try mesh.validate()
    guard !mesh.triangles.isEmpty,mesh.uv.count==mesh.restPositionsMm.count else {throw FormError.invalid("Native cloth preview requires triangles and fixed material UV coordinates.")}
    self.mesh=mesh;self.material=material.copy() as! SCNMaterial
    self.material.isDoubleSided=true
    // SceneKit samples NSImage in image coordinates. Material v already points down
    // the artwork; flipping it here mirrors printed type and placement vertically.
    uvSource=SCNGeometrySource(textureCoordinates:mesh.uv.map {CGPoint(x:$0.x,y:$0.y)})
    let indices=mesh.triangles.flatMap {[UInt32($0.a),UInt32($0.b),UInt32($0.c)]}
    element=SCNGeometryElement(indices:indices,primitiveType:.triangles)
    bounds=try ClothBounds(positionsMm:frame.positionsMm)
    node=SCNNode();node.name="Simulated open cloth surface"
    try update(frame)
  }
  public func update(_ frame:ClothFrame)throws {
    guard frame.positionsMm.count==mesh.restPositionsMm.count,frame.normals.count==mesh.restPositionsMm.count,
      frame.positionsMm.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && max(abs($0.x),abs($0.y),abs($0.z))<=10_000_000}),
      frame.normals.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && abs($0.x*$0.x+$0.y*$0.y+$0.z*$0.z-1)<1e-4}) else {throw FormError.invalid("Native cloth preview needs a finite matching position/normal frame.")}
    let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:frame.positionsMm.map {SCNVector3(Float($0.x/100),Float($0.y/100),Float($0.z/100))}),SCNGeometrySource(normals:frame.normals.map {SCNVector3(Float($0.x),Float($0.y),Float($0.z))}),uvSource],elements:[element])
    geometry.materials=[material]
    let nextBounds=try ClothBounds(positionsMm:frame.positionsMm)
    SCNTransaction.begin();SCNTransaction.animationDuration=0
    node.geometry=geometry;bounds=nextBounds
    SCNTransaction.commit()
  }
}

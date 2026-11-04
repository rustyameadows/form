import AppKit
import FormCore
import FormGeometry
import FormGraphics
import simd

/// Real installed wire paths from the generic join resolver. Tape remains an
/// ordinary material component and is rendered by the regular panel pipeline.
@MainActor enum PlanarFastenerGeometry {
  static let prefix="paper.fastener:"
  static func mesh(_ staple:ResolvedPlanarStaple)throws->MeshGeometry {
    let rings=try PlanarWireSection.corners(pointsMM:staple.pointsMM,widthMM:staple.wireWidthMM,depthMM:staple.wireDepthMM)
    var positions=[MeshVector3](),normals=[MeshVector3](),indices=[UInt32]()
    func quad(_ a:Vector3,_ b:Vector3,_ c:Vector3,_ d:Vector3) {
      let aa=SIMD3(a.x,a.y,a.z),bb=SIMD3(b.x,b.y,b.z),cc=SIMD3(c.x,c.y,c.z)
      let normal=simd_normalize(simd_cross(bb-aa,cc-aa)),start=UInt32(positions.count)
      positions += [a,b,c,d].map{.init($0.x/100,$0.y/100,$0.z/100)}
      normals += Array(repeating:MeshVector3(normal.x,normal.y,normal.z),count:4)
      indices += [start,start+1,start+2,start,start+2,start+3]
    }
    for index in 0..<rings.count-1 {for side in 0..<4 {
      let next=(side+1)%4;quad(rings[index][side],rings[index][next],rings[index+1][next],rings[index+1][side])
    }}
    quad(rings[0][3],rings[0][2],rings[0][1],rings[0][0])
    let last=rings.last!;quad(last[0],last[1],last[2],last[3])
    let geometry=MeshGeometry(sources:[.init(vertices:positions),.init(normals:normals)],elements:[.init(indices:indices,primitiveType:.triangles)])
    let material=MeshMaterial();material.name="Installed rectangular wire";material.lightingModel = .physicallyBased
    material.diffuse.contents=FormColor.color("#9DA5AB");material.roughness.contents=0.26;material.metalness.contents=0.92
    geometry.materials=[material];return geometry
  }
  static func install(_ root:MeshNode,staples:[ResolvedPlanarStaple])throws {
    var nodes=Dictionary(uniqueKeysWithValues:root.childNodes.compactMap{node->(String,MeshNode)? in
      guard let name=node.name,name.hasPrefix(prefix) else{return nil};return(String(name.dropFirst(prefix.count)),node)
    })
    for staple in staples {
      let node=nodes.removeValue(forKey:staple.id) ?? MeshNode();node.name=prefix+staple.id
      node.geometry=try mesh(staple);node.categoryBitMask=2
      node.childNode(withName:PaperGeometry.highlightName,recursively:false)?.removeFromParentNode()
      if let base=node.geometry {
        let overlay=MeshGeometry(sources:base.sources,elements:base.elements),material=MeshMaterial()
        material.name="Selected installed wire";material.lightingModel = .constant;material.diffuse.contents=FormColor.color("#CC6C43")
        material.readsFromDepthBuffer=false;material.writesToDepthBuffer=false;overlay.materials=[material]
        let highlight=MeshNode(geometry:overlay);highlight.name=PaperGeometry.highlightName;highlight.categoryBitMask=4;highlight.renderingOrder=111;highlight.castsShadow=false;highlight.isHidden=true
        node.addChildNode(highlight)
      }
      if node.parent !== root {root.addChildNode(node)}
    }
    for node in nodes.values {node.removeFromParentNode()}
  }
  static func highlight(_ root:MeshNode,staples:[ResolvedPlanarStaple],instanceID:String?,definitionID:String?) {
    for staple in staples {
      let selected=instanceID.map{$0==staple.id} ?? definitionID.map{$0==staple.definitionID} ?? false
      root.childNode(withName:prefix+staple.id,recursively:false)?.childNode(withName:PaperGeometry.highlightName,recursively:false)?.isHidden = !selected
    }
  }
  static func updatePose(_ root:MeshNode,staples:[ResolvedPlanarStaple],restPanels:[PaperResolvedPanel],posedPanels:[PaperResolvedPanel])throws {
    guard !staples.isEmpty else{return}
    func matrix(_ p:PaperResolvedPanel)->simd_double4x4 {
      let m=p.flatToWorld
      return .init(SIMD4(m[0],m[4],m[8],m[12]),SIMD4(m[1],m[5],m[9],m[13]),SIMD4(m[2],m[6],m[10],m[14]),SIMD4(m[3],m[7],m[11],m[15]))
    }
    let rest=Dictionary(uniqueKeysWithValues:restPanels.map{($0.panelID,matrix($0))}),posed=Dictionary(uniqueKeysWithValues:posedPanels.map{($0.panelID,matrix($0))})
    for staple in staples {
      guard let a=rest[staple.entryPanelID],let b=posed[staple.entryPanelID],let node=root.childNode(withName:prefix+staple.id,recursively:false) else {
        throw FormError.invalid("An installed fastener lost its actual entry frame.")
      }
      var delta=b*a.inverse;delta.columns.3.x/=100;delta.columns.3.y/=100;delta.columns.3.z/=100
      node.transform = .init(delta)
    }
  }
}

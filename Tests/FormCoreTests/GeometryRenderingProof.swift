import AppKit
import FormGeometry
import LabRendering
import simd

extension MeshNode {
  var simdWorldRight:SIMD3<Double> {let v=worldTransform.raw.columns.0;return simd_normalize(.init(v.x,v.y,v.z))}
  var simdWorldUp:SIMD3<Double> {let v=worldTransform.raw.columns.1;return simd_normalize(.init(v.x,v.y,v.z))}
}

/// Real RealityKit capture for the lower-level physical cloth/material proofs.
/// Tests retain exact source geometry, material slots, UVs, camera and pixels.
@MainActor enum GeometryRenderingProof {
  static func capture(_ scene:MeshScene,camera:MeshNode,size:CGSize)async throws->NSImage {
    let renderer=try RealityKitSceneRenderer(),owner=UUID()
    func color(_ value:Any?,fallback:NSColor = .white)->SIMD4<Float> {
      let c=((value as? NSColor) ?? fallback).usingColorSpace(.sRGB)!
      return .init(Float(c.redComponent),Float(c.greenComponent),Float(c.blueComponent),Float(c.alphaComponent))
    }
    func walk(_ node:MeshNode,path:String,hidden:Bool)throws {
      let hidden=hidden || node.isHidden
      if let g=node.geometry {
        let positions=g.sources(for:.vertex).first?.vectors.map{$0.simd*100} ?? []
        if !positions.isEmpty {
          let sourceMaterials=g.materials.isEmpty ? [MeshMaterial()]:g.materials
          let parts=g.elements.enumerated().compactMap{index,part->SceneMeshPart? in guard part.primitiveType == .triangles else{return nil};return .init(materialIndex:index%sourceMaterials.count,triangleIndices:part.indices,semanticID:"element:\(index)")}
          if !parts.isEmpty {
            let materials=sourceMaterials.enumerated().map {index,m -> SceneMaterialPayload in
              var p=SceneMaterialPayload(id:path+"/material:\(index)",baseColor:color(m.diffuse.contents),metallic:Float((m.metalness.contents as? NSNumber)?.doubleValue ?? 0),roughness:Float((m.roughness.contents as? NSNumber)?.doubleValue ?? 0.6),doubleSided:m.isDoubleSided,unlit:m.lightingModel == .constant)
              p.baseColor.w *= Float(m.transparency*node.opacity)
              if let image=m.diffuse.contents as? NSImage,let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) {p.baseColorTexture = .init(image:cg,revision:path+"/texture",wrapS:m.diffuse.wrapS == .repeat ? .repeatMode:.clamp,wrapT:m.diffuse.wrapT == .repeat ? .repeatMode:.clamp);p.alphaMode = .blend}
              if p.baseColor.w<0.999 {p.alphaMode = .blend}
              return p
            }
            // Source hierarchy is baked in Double mm for this proof path. No
            // renderer entity or model authority enters the CPU construction graph.
            let matrix=node.worldTransform.raw,normMatrix=simd_double3x3(columns:(SIMD3(matrix.columns.0.x,matrix.columns.0.y,matrix.columns.0.z),SIMD3(matrix.columns.1.x,matrix.columns.1.y,matrix.columns.1.z),SIMD3(matrix.columns.2.x,matrix.columns.2.y,matrix.columns.2.z))).inverse.transpose
            let transformed=positions.map{p->SIMD3<Double> in let q=matrix*SIMD4(p/100,1);return SIMD3(q.x,q.y,q.z)*100}
            let normals=g.sources(for:.normal).first?.vectors.map{SIMD3<Float>(simd_normalize(normMatrix*$0.simd))} ?? []
            let uv=g.sources(for:.texcoord).first?.points.map{SIMD2<Float>(Float($0.x),Float($0.y))} ?? []
            try renderer.upsert(.init(componentID:path,objectID:owner,mesh:.init(id:path,revision:"proof",positionsMM:transformed,normals:normals,uvs:uv,parts:parts),materials:materials,visible:!hidden,pickable:false))
          }
        }
      }
      for (index,child) in node.childNodes.enumerated(){try walk(child,path:path+"/\(index)",hidden:hidden)}
    }
    try walk(scene.rootNode,path:"proof",hidden:false)
    let lens=camera.camera ?? MeshCamera();var matrix=camera.worldTransform.raw;matrix.columns.3.x *= 100;matrix.columns.3.y *= 100;matrix.columns.3.z *= 100
    try renderer.setCamera(.init(worldFromCameraMM:matrix,projection:lens.usesOrthographicProjection ? .orthographic(verticalSpanMM:lens.orthographicScale*200):.perspective(verticalFieldOfViewDegrees:lens.fieldOfView),nearMM:lens.zNear*100,farMM:lens.zFar*100))
    let key=scene.rootNode.childNodes.first{$0.light?.type != .ambient && $0.light != nil},ambient=scene.rootNode.childNodes.first{$0.light?.type == .ambient}
    let direction=key.map{-SIMD3<Float>($0.worldPosition.simd)} ?? .init(-0.5,-1,-0.6)
    try renderer.setLighting(.init(background:color(scene.background.contents),keyDirection:direction,keyIntensity:Float(key?.light?.intensity ?? 800)*3.75,fillIntensity:Float(ambient?.light?.intensity ?? 400)*1.2))
    let image=try await renderer.capture(width:Int(size.width),height:Int(size.height))
    return NSImage(cgImage:image,size:size)
  }
}

import AppKit
import Foundation
import FormCore
import FormGraphics
import LabRendering

/// Artwork is an appearance revision over immutable CAD buffers. The physical
/// frame supplies UVs; editing a source never invokes the exact evaluator.
@MainActor enum CADSurfaceAppearance {
  private final class Texture:NSObject {
    let image:CGImage
    init(_ image:CGImage){self.image=image}
  }
  private static let cache:NSCache<NSString,Texture> = {
    let value=NSCache<NSString,Texture>();value.totalCostLimit=64*1024*1024;value.countLimit=64;return value
  }()
  private(set) static var textureBuilds=0

  static func apply(_ prepared:CADSceneAdapter.Prepared,object:ProductObject,project:Project,assets:URL,materials:[FormCore.Material])throws->[SceneRenderablePayload] {
    var scene=CADSceneAdapter.renderables(prepared,for:object,materials:materials)
    guard let bindings=object.surfaceArtworkBindings,!bindings.isEmpty else{return scene}
    let surfaces=object.cadRepresentation?.resolvedSurfaces ?? []
    let maximumEdge=min(2048,Int(sqrt(Double(64*1024*1024/max(1,bindings.count))/4)))
    for index in scene.indices {
      try Task.checkCancellation()
      let slots=prepared.surfaceSlots[scene[index].componentID] ?? [:]
      for (slot,surfaceID) in slots {
        try Task.checkCancellation()
        guard scene[index].materials.indices.contains(slot),let binding=bindings.first(where:{$0.surfaceID==surfaceID}),
          let surface=surfaces.first(where:{$0.id==surfaceID}),let artwork=project.physicalSurfaceArtwork(binding) else{continue}
        let original=scene[index].materials[slot]
        let artData=try artwork.renderCacheData()
        var signature=artData
        signature.append(try CADSceneAdapter.canonicalData(surface))
        signature.append(Data("\(assets.path)|\(binding.widthMM)|\(binding.heightMM)|\(original.baseColor)|\(original.colorEncoding)|edge:\(maximumEdge)|font:\(GeometryFactory.fontRevision)".utf8))
        let revision=CADSceneAdapter.digest(signature),image:CGImage
        if let value=cache.object(forKey:revision as NSString){image=value.image}
        else {
          try ArtworkRenderer.validateGlyphOutput(artwork,assets:assets)
          let scale=min(4,Double(maximumEdge)/max(surface.width,surface.height)),width=max(1,Int((surface.width*scale).rounded())),height=max(1,Int((surface.height*scale).rounded()))
          guard width<=2048,height<=2048,let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw FormError.invalid("The named CAD surface exceeds the artwork texture budget.")}
          func srgb(_ value:Float)->CGFloat {
            if original.colorEncoding == .srgb{return CGFloat(value)}
            let v=Double(value);return CGFloat(v<=0.0031308 ? v*12.92:1.055*pow(v,1/2.4)-0.055)
          }
          context.setFillColor(red:srgb(original.baseColor.x),green:srgb(original.baseColor.y),blue:srgb(original.baseColor.z),alpha:CGFloat(original.baseColor.w))
          context.fill(.init(x:0,y:0,width:Double(width),height:Double(height)))
          context.saveGState()
          let boundary=CGMutablePath()
          if let first=surface.boundary.first {
            boundary.move(to:.init(x:first.x*scale,y:Double(height)-first.y*scale))
            for p in surface.boundary.dropFirst(){boundary.addLine(to:.init(x:p.x*scale,y:Double(height)-p.y*scale))}
            boundary.closeSubpath();context.addPath(boundary);context.clip()
          }
          // Render at the source's saved physical size. A larger target surface
          // extends the stock; it does not stretch text or crop coordinates.
          let sourceScale=min(scale,Double(maximumEdge)/max(binding.widthMM,binding.heightMM))
          let source=ArtworkRenderer.image(artwork,width:binding.widthMM,height:binding.heightMM,assets:assets,pixelsPerMM:sourceScale)
          guard let pixels=source.cgImage(forProposedRect:nil,context:nil,hints:nil) else{throw FormError.invalid("The linked surface artwork did not produce pixels.")}
          context.draw(pixels,in:.init(x:0,y:Double(height)-binding.heightMM*scale,width:binding.widthMM*scale,height:binding.heightMM*scale))
          context.restoreGState()
          try Task.checkCancellation()
          guard let output=context.makeImage() else{throw FormError.invalid("Could not compose the physical surface artwork.")}
          image=output;cache.setObject(Texture(output),forKey:revision as NSString,cost:output.bytesPerRow*output.height);textureBuilds+=1
        }
        var material=original
        material.id+="/surface/"+surfaceID;material.revision+="/artwork/"+revision
        material.baseColor = .init(1,1,1,1);material.colorEncoding = .srgb
        material.baseColorTexture = .init(image:image,revision:revision,wrapS:.clamp,wrapT:.clamp)
        material.alphaMode = .blend
        scene[index].materials[slot]=material
      }
    }
    return scene
  }
}

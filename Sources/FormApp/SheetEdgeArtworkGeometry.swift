import AppKit
import FormCore
import FormGeometry
import FormGraphics
import simd

/// Page-edge printing uses closed-block material coordinates. It is a thin ink
/// layer above the real, independently colored stock edges, not a block decal.
@MainActor enum SheetEdgeArtworkGeometry {
  static let templatePrefix="sheet.edge.template:",displayPrefix="sheet.edge.display:"
  struct Source {var edge:String,face:ResolvedSheetAssemblyFace,size:Point2
    var key:String {"sheet.edge:"+edge}}
  static func sources(_ resolved:ResolvedSheetAssembly)->[Source] {
    guard let edges=resolved.edgeArtwork,resolved.textBlockThickness>0 else{return []}
    return [("head",edges.head,resolved.trimWidth),("tail",edges.tail,resolved.trimWidth),("foreEdge",edges.foreEdge,resolved.trimHeight)].compactMap {edge,face,width in
      face.map{.init(edge:edge,face:$0,size:.init(width,resolved.textBlockThickness))}
    }
  }
  static func material(_ source:Source,project:Project,assets:URL,plan:SourceTextureRasterPlan)throws->MeshMaterial {
    guard let art=SheetAssemblyGeometry.prepared(source.face,size:source.size,inside:false,project:project) else{throw FormError.invalid("An edge treatment needs its canonical artwork source.")}
    let owner=project.objects.first{$0.id==source.face.sourceObjectID}
    let finishes=(owner.flatMap{try? PaperConstruction.definition(for:$0)}?.finishes ?? []).filter{$0.side==source.face.sourceSide}
    let prepared=try PaperSurfaceRasterizer.PreparedArtwork(art,finishes:finishes,assets:assets)
    let profile=PaperSurfaceProfile(texture:.smooth,color:"#FFFFFF",roughness:0.8,textureDepthMM:0)
    let maps=try PaperSurfaceRasterizer.make(rect:.init(x:0,y:0,width:source.size.x,height:source.size.y),netSize:source.size,
      profile:profile,color:"#FFFFFF",grain:.unknown,artwork:art,finishes:finishes,assets:assets,
      maximumEdge:plan.maximumEdge,pixelBudget:plan.maximumPixels,preparedArtwork:prepared)
    // Preserve the canonical ink alpha, so a mixed-stock gather retains its
    // real colored fiber wherever the edge source has no ink.
    let printArt=try prepared.printSources().print
    let image=try alphaRegistered(color:maps.color,artwork:printArt,size:source.size,assets:assets,width:maps.width,height:maps.height)
    let material=MeshMaterial();material.name="Paper / registered "+source.edge+" edge ink"
    material.diffuse.contents=image;material.normal.contents=maps.normal;material.roughness.contents=maps.roughness;material.metalness.contents=maps.metallic
    material.writesToDepthBuffer=false;return material
  }
  private static func alphaRegistered(color:NSImage,artwork:Artwork,size:Point2,assets:URL,width:Int,height:Int)throws->NSImage {
    let count=width*height
    func pixels(_ draw:(CGContext)->Void)throws->[UInt8] {
      var bytes=[UInt8](repeating:0,count:count*4)
      let valid=bytes.withUnsafeMutableBytes{buffer->Bool in
        guard let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
          space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
        draw(context);return true
      };guard valid else{throw FormError.invalid("Edge ink could not allocate its bounded raster.")};return bytes
    }
    guard let cg=color.cgImage(forProposedRect:nil,context:nil,hints:nil) else{throw FormError.invalid("Edge ink has no printable color map.")}
    let ink=try pixels{context in
      NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
      context.translateBy(x:0,y:Double(height));context.scaleBy(x:Double(width)/size.x,y:-Double(height)/size.y)
      ArtworkRenderer.draw(artwork,width:size.x,height:size.y,assets:assets);NSGraphicsContext.restoreGraphicsState()
    }
    var output=try pixels{$0.draw(cg,in:.init(x:0,y:0,width:width,height:height))}
    for i in 0..<count {let j=i*4,a=Int(ink[j+3]),white=255-a
      for c in 0..<3 {output[j+c]=UInt8(max(0,min(a,Int(output[j+c])-white)))};output[j+3]=UInt8(a)
    }
    let data=Data(output) as CFData
    guard let provider=CGDataProvider(data:data),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{throw FormError.invalid("Edge ink could not build its registered texture.")}
    return NSImage(cgImage:image,size:.init(width:width,height:height))
  }
  static func register(_ base:MeshGeometry,size:Point2,thickness:Double,depthOffset:Double,totalDepth:Double,edge:String,material:MeshMaterial)throws->MeshGeometry? {
    let positions=base.sources(for:.vertex).first?.vectors ?? [],normals=base.sources(for:.normal).first?.vectors ?? []
    guard positions.count==normals.count,totalDepth>0 else{throw FormError.invalid("Edge ink needs physical edge buffers and positive closed block depth.")}
    var output=[MeshVector3](),ns=[MeshVector3](),uv=[CGPoint](),indices=[UInt32]()
    for element in base.elements.dropFirst(2) {
      for offset in stride(from:0,to:element.indices.count,by:3) where offset+2<element.indices.count {
        let ids=element.indices[offset..<offset+3].map(Int.init)
        guard ids.allSatisfy({positions.indices.contains($0)}) else{throw FormError.invalid("Edge ink encountered an invalid stock index.")}
        let normal=ids.reduce(SIMD3<Double>.zero){$0+normals[$1].simd}/3
        let p=ids.reduce(SIMD3<Double>.zero){$0+positions[$1].simd}*(100.0/3)
        let matches=edge=="head" ? normal.y>0.2 && abs(p.y)<0.1:edge=="tail" ? normal.y < -0.2 && abs(p.y+size.y)<0.1:normal.x>0.2 && abs(p.x-size.x)<0.1
        guard matches else{continue}
        for id in ids {
          let p=positions[id],n=normals[id],index=UInt32(output.count)
          output.append(.init(p.simd+n.simd*0.00002));ns.append(n)
          let u=edge=="foreEdge" ? -p.y*100/size.y:p.x*100/size.x
          uv.append(.init(x:u,y:(depthOffset+thickness/2-p.z*100)/totalDepth));indices.append(index)
        }
      }
    }
    guard !indices.isEmpty else{return nil}
    let mesh=MeshGeometry(sources:[.init(vertices:output),.init(normals:ns),.init(textureCoordinates:uv)],elements:[.init(indices:indices,primitiveType:.triangles),.init(indices:[UInt32](),primitiveType:.triangles)])
    mesh.materials=[material,material];return mesh
  }
  /// Hidden local templates retain undeformed registration. A single visible
  /// mesh per edge shares its texture across every moving physical leaf.
  static func updatePose(_ root:MeshNode) {
    for edge in ["head","tail","foreEdge"] {
      var positions=[MeshVector3](),normals=[MeshVector3](),uv=[CGPoint](),indices=[UInt32](),materials=[MeshMaterial]()
      root.enumerateChildNodes {node,_ in
        guard node.name==templatePrefix+edge,let source=node.geometry else{return}
        let matrix=root.worldTransform.raw.inverse*node.worldTransform.raw
        let posed=SheetPanelMeshTransform.apply(source,matrix:matrix),offset=UInt32(positions.count)
        positions += posed.sources(for:.vertex).first?.vectors ?? [];normals += posed.sources(for:.normal).first?.vectors ?? [];uv += posed.sources(for:.texcoord).first?.points ?? []
        indices += (posed.elements.first?.indices ?? []).map{$0+offset};materials=source.materials
      }
      root.childNode(withName:displayPrefix+edge,recursively:false)?.removeFromParentNode()
      guard !indices.isEmpty else{continue}
      let geometry=MeshGeometry(sources:[.init(vertices:positions),.init(normals:normals),.init(textureCoordinates:uv)],elements:[.init(indices:indices,primitiveType:.triangles),.init(indices:[UInt32](),primitiveType:.triangles)])
      geometry.materials=materials;let node=MeshNode(geometry:geometry);node.name=displayPrefix+edge;root.addChildNode(node)
    }
  }
}

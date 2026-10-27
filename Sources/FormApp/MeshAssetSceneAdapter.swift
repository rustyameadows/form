import AppKit
import CoreGraphics
import Foundation
import FormMeshAssets
import ImageIO
import LabRendering
import simd

struct MeshAssetPreparedComponent:Sendable {
  var id:String,name:String,materialIndex:Int
  var sourceMesh:SceneMeshPayload
  var artworkMesh:SceneMeshPayload
  var sourceUV:MeshTextureBinding?
  var sourceTransform:SceneTransformPayload
}
struct MeshAssetPreparedScene:@unchecked Sendable {
  let components:[MeshAssetPreparedComponent]
  let materials:[MeshAssetMaterial],textures:[MeshAssetTexture]
  let images:[CGImage]
  let imageRevisions:[String]
  let gltfLinearFactors:Bool
  let warnings:[String]
  let approximateBytes:Int
}
struct MeshAssetSceneAppearance:Sendable {
  struct Component:Sendable {var id:String,mesh:SceneMeshPayload,material:SceneMaterialPayload,sourceTransform:SceneTransformPayload}
  let components:[Component]
  let warnings:[String]
  let approximateBytes:Int
}

/// Renderer-neutral adaptation; call prepare/appearance on a controlled worker.
/// Only renderables(), which wraps immutable buffers in current placements, is intended for the UI thread.
enum MeshAssetSceneAdapter {
  private static let identityUV=MeshTextureBinding(textureIndex:0)
  static func prepare(document:MeshAssetDocument,reference:MeshAssetReference)throws->MeshAssetPreparedScene {
    try MeshAssetGeometry.validate(document);try reference.validate()
    let offset=ModelAssetCoordinator.sourceToTableOffset(reference)
    var images:[CGImage]=[]
    for image in document.images {
      if Task.isCancelled {throw CancellationError()}
      guard let source=CGImageSourceCreateWithData(image.data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),let cg=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),cg.width==image.width,cg.height==image.height else{throw MeshAssetError.invalid("Texture decoding failed after metadata validation.")}
      images.append(cg)
    }
    var shared:[String:(SceneMeshPayload,SceneMeshPayload)]=[:]
    var output:[MeshAssetPreparedComponent]=[],warnings:[String]=[],cost=images.reduce(0){$0+$1.bytesPerRow*$1.height}
    for node in document.nodes where node.inSelectedScene {
      guard let meshIndex=node.meshIndex else{continue}
      for primitive in document.meshes[meshIndex].primitives {
        if Task.isCancelled {throw CancellationError()}
        let sourceTransform=decomposed(node.worldTransform,offset:offset)
        let p=try sourceTransform==nil ? MeshAssetGeometry.transformed(primitive,by:node.worldTransform):primitive,index=p.materialIndex ?? 0
        guard document.materials.indices.contains(index) else{throw MeshAssetError.invalid("Renderable primitive has no resolved material slot.")}
        let m=document.materials[index],choice=m.baseColorTexture ?? m.normalTexture ?? m.metallicRoughnessTexture ?? m.emissiveTexture ?? m.occlusionTexture
        let id=node.id+"/"+p.id,meshKey=reference.normalizedSHA256+"/"+(sourceTransform==nil ? id:p.id)
        if let cached=shared[meshKey] {output.append(.init(id:id,name:node.name,materialIndex:index,sourceMesh:cached.0,artworkMesh:cached.1,sourceUV:choice,sourceTransform:sourceTransform ?? .init()));continue}
        let sourceUV=try mappedUVs(p,using:choice),add=sourceTransform==nil ? offset:.init()
        let positions=p.positionsMM.map{SIMD3<Double>($0.x+add.x,$0.y+add.y,$0.z+add.z)},normals=p.normals.map(\.simd)
        let tangent=choice==nil || isIdentity(choice!) && choice!.texCoord==0 ? p.tangents.map{SIMD4<Float>($0.x,$0.y,$0.z,$0.w)}:[]
        let mesh=SceneMeshPayload(id:meshKey,revision:reference.geometryRevision+"/source",positionsMM:positions,normals:normals,uvs:sourceUV,tangents:tangent.isEmpty && !sourceUV.isEmpty ? tangents(positions:positions,normals:normals,uvs:sourceUV,indices:p.indices):tangent,colors:p.colors.map{SIMD4($0.r,$0.g,$0.b,$0.a)},parts:[.init(triangleIndices:p.indices,semanticID:p.id)])
        var artwork=mesh
        if !p.uv0.isEmpty,choice != nil && (!isIdentity(choice!) || choice!.texCoord != 0) {
          artwork.id+="/artwork-uv0";artwork.revision=reference.geometryRevision+"/artwork-uv0";artwork.uvs=p.uv0.map(\.simd);artwork.tangents=tangents(positions:positions,normals:normals,uvs:artwork.uvs,indices:p.indices)
          cost+=artwork.uvs.count*MemoryLayout<SIMD2<Float>>.stride+artwork.tangents.count*MemoryLayout<SIMD4<Float>>.stride
        }
        if !p.colors.isEmpty {warnings.append("\(node.name): vertex colors remain in source/neutral buffers; the current RealityKit material path does not display COLOR_0.")}
        for (channel,binding) in [("normal",m.normalTexture),("metallic/roughness",m.metallicRoughnessTexture),("emissive",m.emissiveTexture),("occlusion",m.occlusionTexture)] {
          if let binding,!sameMapping(binding,choice) {warnings.append("\(node.name): \(channel) uses a different UV mapping from base appearance and is omitted from this renderer; source mappings are retained.")}
        }
        cost+=mesh.approximateBytes;shared[meshKey]=(mesh,artwork);output.append(.init(id:id,name:node.name,materialIndex:index,sourceMesh:mesh,artworkMesh:artwork,sourceUV:choice,sourceTransform:sourceTransform ?? .init()))
      }
    }
    return .init(components:output,materials:document.materials,textures:document.textures,images:images,imageRevisions:document.images.map(\.sha256),gltfLinearFactors:reference.format=="glb" || reference.format=="gltf",warnings:Array(Set(warnings)).sorted(),approximateBytes:cost)
  }
  private static func decomposed(_ transform:MeshAssetTransform,offset:MeshPoint3)->SceneTransformPayload? {
    let m=transform.matrix,a=SIMD3<Double>(m[0],m[1],m[2]),b=SIMD3<Double>(m[4],m[5],m[6]),c=SIMD3<Double>(m[8],m[9],m[10]),scale=SIMD3(simd_length(a),simd_length(b),simd_length(c))
    guard scale.x>1e-12,scale.y>1e-12,scale.z>1e-12,transform.determinant>0 else{return nil}
    let x=a/scale.x,y=b/scale.y,z=c/scale.z
    guard abs(simd_dot(x,y))<1e-8,abs(simd_dot(x,z))<1e-8,abs(simd_dot(y,z))<1e-8,simd_dot(simd_cross(x,y),z)>0.99999999 else{return nil}
    let q=simd_quatd(simd_double3x3(x,y,z))
    return .init(translationMM:.init(m[12]+offset.x,m[13]+offset.y,m[14]+offset.z),rotationXYZW:q.vector,scale:scale)
  }
  private static func isIdentity(_ b:MeshTextureBinding)->Bool {b.offset == .init() && b.scale == .init(1,1) && b.rotation==0}
  private static func sameMapping(_ a:MeshTextureBinding,_ b:MeshTextureBinding?)->Bool {
    guard let b else{return a.texCoord==0 && isIdentity(a)}
    return a.texCoord==b.texCoord && a.offset==b.offset && a.scale==b.scale && a.rotation==b.rotation
  }
  private static func mappedUVs(_ primitive:MeshAssetPrimitive,using binding:MeshTextureBinding?)throws->[SIMD2<Float>] {
    guard let binding else{return primitive.uv0.map(\.simd)}
    let source=binding.texCoord==0 ? primitive.uv0:primitive.uv1
    guard source.count==primitive.positionsMM.count else{throw MeshAssetError.invalid("A required UV channel is unavailable.")}
    return source.map{binding.transformed($0).simd}
  }
  private static func tangents(positions:[SIMD3<Double>],normals:[SIMD3<Float>],uvs:[SIMD2<Float>],indices:[UInt32])->[SIMD4<Float>] {
    var first=[SIMD3<Double>](repeating:.zero,count:positions.count),second=first
    for i in stride(from:0,to:indices.count,by:3) {
      let a=Int(indices[i]),b=Int(indices[i+1]),c=Int(indices[i+2]),u=positions[b]-positions[a],v=positions[c]-positions[a],x=SIMD2<Double>(uvs[b]-uvs[a]),y=SIMD2<Double>(uvs[c]-uvs[a]),denom=x.x*y.y-y.x*x.y
      guard abs(denom)>1e-20 else{continue};let s=(u*y.y-v*x.y)/denom,t=(v*x.x-u*y.x)/denom
      for id in [a,b,c] {first[id]+=s;second[id]+=t}
    }
    return positions.indices.map {i in let n=SIMD3<Double>(normals[i]),raw=first[i]-n*simd_dot(n,first[i]);let t=simd_length_squared(raw)>1e-20 ? simd_normalize(raw):simd_normalize(abs(n.y)<0.9 ? simd_cross(n,SIMD3(0,1,0)):simd_cross(n,SIMD3(1,0,0)));return .init(Float(t.x),Float(t.y),Float(t.z),simd_dot(simd_cross(n,t),second[i])<0 ? -1:1)}
  }
  static func appearance(_ prepared:MeshAssetPreparedScene,reference:MeshAssetReference,artwork:CGImage?=nil,artworkRevision:String="none")throws->MeshAssetSceneAppearance {
    try reference.validate();var components:[MeshAssetSceneAppearance.Component]=[],warnings=prepared.warnings,cost=0,composites:[Int:CGImage]=[:],recolors:[Int:CGImage]=[:]
    for component in prepared.components {
      if Task.isCancelled {throw CancellationError()}
      let slot=component.materialIndex,source=prepared.materials[slot],override=reference.materialOverrides.first{$0.materialIndex==slot}
      var factor=SIMD4<Float>(Float(source.baseColor[0]),Float(source.baseColor[1]),Float(source.baseColor[2]),Float(source.baseColor[3]))
      if let hex=override?.colorHex {let color=rgb(hex);factor.x=prepared.gltfLinearFactors ? linear(color.x):color.x;factor.y=prepared.gltfLinearFactors ? linear(color.y):color.y;factor.z=prepared.gltfLinearFactors ? linear(color.z):color.z}
      if let opacity=override?.opacity {factor.w=Float(opacity)}
      let binding=reference.artworkBindings.first{$0.materialIndex==slot && ($0.primitiveIDs.isEmpty || $0.primitiveIDs.contains(component.id))},applyArtwork=binding != nil && artwork != nil
      let activeMapping=applyArtwork ? identityUV:component.sourceUV
      func texture(_ binding:MeshTextureBinding?,_ channel:SceneTextureChannel = .rgba)throws->SceneTexturePayload? {
        guard let binding,sameMapping(binding,activeMapping) else{return nil}
        let texture=prepared.textures[binding.textureIndex]
        func wrap(_ value:Int)->SceneTextureWrap {value==33071 ? .clamp:value==33648 ? .mirror:.repeatMode}
        return .init(image:prepared.images[texture.imageIndex],revision:prepared.imageRevisions[texture.imageIndex],uvIndex:0,wrapS:wrap(texture.wrapS),wrapT:wrap(texture.wrapT),channel:channel)
      }
      let originalMode:SceneAlphaMode=source.alphaMode=="MASK" ? .mask:source.alphaMode=="BLEND" ? .blend:.opaque
      let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
      let slotRevision=MeshAssetHash.sha256(try encoder.encode(override)),revision=slotRevision+"/"+(applyArtwork ? "uv:"+artworkRevision:"source")
      var material=SceneMaterialPayload(id:reference.normalizedSHA256+"/slot-\(slot)",revision:revision,baseColor:factor,colorEncoding:prepared.gltfLinearFactors ? .linearSRGB:.srgb,emissiveColor:.init(Float(source.emissive[0]),Float(source.emissive[1]),Float(source.emissive[2])),emissiveTexture:try texture(source.emissiveTexture),metallic:Float(override?.metallic ?? source.metallic),roughness:Float(override?.roughness ?? source.roughness),doubleSided:source.doubleSided,unlit:source.unlit,alphaMode:factor.w<1 ? .blend:originalMode,alphaCutoff:Float(source.alphaCutoff),normalScale:Float(source.normalTexture?.strength ?? 1),baseColorTexture:try texture(source.baseColorTexture),normalTexture:try texture(source.normalTexture),metallicTexture:try texture(source.metallicRoughnessTexture,.blue),roughnessTexture:try texture(source.metallicRoughnessTexture,.green),ambientOcclusionTexture:try texture(source.occlusionTexture,.red))
      var recoloredBase:CGImage?
      if let hex=override?.colorHex,let binding=source.baseColorTexture {
        let texture=prepared.textures[binding.textureIndex],image:CGImage
        if let cached=recolors[slot] {image=cached}else{image=try recolor(prepared.images[texture.imageIndex],color:rgb(hex));recolors[slot]=image;cost+=image.bytesPerRow*image.height}
        recoloredBase=image
        if var displayed=material.baseColorTexture {displayed.image=image;displayed.revision=prepared.imageRevisions[texture.imageIndex]+"/recolor:"+hex.uppercased();material.baseColorTexture=displayed}
        // Chosen color is the replacement surface color; original texture luminance supplies detail.
        material.baseColor = .init(1,1,1,factor.w)
      }
      if applyArtwork,let artwork {
        let image:CGImage
        if let cached=composites[slot] {image=cached}else {image=try composite(artwork:artwork,source:source,prepared:prepared,factor:material.baseColor,baseImage:recoloredBase);composites[slot]=image;cost+=image.bytesPerRow*image.height}
        let revision=material.revision+"/uv-composite"
        material.baseColorTexture = .init(image:image,revision:revision,wrapS:.clamp,wrapT:.clamp);material.baseColor = .init(repeating:1)
        for (channel,value) in [("normal",source.normalTexture),("metallic/roughness",source.metallicRoughnessTexture),("emissive",source.emissiveTexture),("occlusion",source.occlusionTexture)] {if let value,!sameMapping(value,identityUV) {warnings.append("\(component.name): \(channel) map is omitted while artwork uses original UV0; independent source mappings remain retained.")}}
      }
      guard cost<=64*1024*1024 else{throw MeshAssetError.limit("Derived colorway/UV display textures exceed the 64 MiB appearance budget. Map fewer slots or use smaller artwork.")}
      components.append(.init(id:component.id,mesh:applyArtwork ? component.artworkMesh:component.sourceMesh,material:material,sourceTransform:component.sourceTransform))
    }
    return .init(components:components,warnings:Array(Set(warnings)).sorted(),approximateBytes:cost)
  }
  static func renderables(_ appearance:MeshAssetSceneAppearance,objectID:UUID,positionMM:SIMD3<Double> = .zero,yawDegrees:Double=0,scalePercent:Double=100)->[SceneRenderablePayload] {
    let q=simd_quatd(angle:yawDegrees*Double.pi/180,axis:.init(0,1,0)),scale=scalePercent/100
    return appearance.components.map {component in
      let source=component.sourceTransform,rotation=q*simd_quatd(vector:source.rotationXYZW),transform=SceneTransformPayload(translationMM:positionMM+q.act(source.translationMM*scale),rotationXYZW:rotation.vector,scale:source.scale*scale)
      return .init(componentID:objectID.uuidString+"/"+component.id,objectID:objectID,mesh:component.mesh,materials:[component.material],transform:transform)
    }
  }
  private static func rgb(_ hex:String)->SIMD3<Float> {let n=UInt32(hex.dropFirst(),radix:16) ?? 0;return .init(Float((n>>16)&255)/255,Float((n>>8)&255)/255,Float(n&255)/255)}
  private static func linear(_ value:Float)->Float {value<=0.04045 ? value/12.92:pow((value+0.055)/1.055,2.4)}
  private static func encoded(_ value:Float)->UInt8 {let v=max(0,min(1,value));return UInt8(max(0,min(255,(255*(v<=0.0031308 ? 12.92*v:1.055*pow(v,1/2.4)-0.055)).rounded())))}
  private struct Pixels {var width:Int,height:Int,data:[UInt8]}
  private static func pixels(_ image:CGImage)throws->Pixels {
    guard image.width>0,image.height>0,image.width<=8192,image.height<=8192,image.width*image.height<=16_777_216 else{throw MeshAssetError.limit("UV appearance input exceeds 16,777,216 pixels or an 8192-pixel edge.")}
    var data=[UInt8](repeating:0,count:image.width*image.height*4)
    let okay=data.withUnsafeMutableBytes{raw->Bool in guard let context=CGContext(data:raw.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue) else{return false};context.draw(image,in:.init(x:0,y:0,width:image.width,height:image.height));return true}
    guard okay else{throw MeshAssetError.limit("Could not allocate UV appearance pixels.")};return .init(width:image.width,height:image.height,data:data)
  }
  private static func sample(_ pixels:Pixels,uv:SIMD2<Double>,wrapS:Int=33071,wrapT:Int=33071)->SIMD4<Float> {
    func coordinate(_ v:Double,_ mode:Int)->Double {if mode==10497 {return v-floor(v)};if mode==33648 {let n=v-floor(v/2)*2;return n<=1 ? n:2-n};return min(1,max(0,v))}
    let x=coordinate(uv.x,wrapS)*Double(pixels.width-1),y=coordinate(uv.y,wrapT)*Double(pixels.height-1),x0=Int(floor(x)),y0=Int(floor(y)),x1=min(pixels.width-1,x0+1),y1=min(pixels.height-1,y0+1),fx=Float(x-Double(x0)),fy=Float(y-Double(y0))
    func pixel(_ x:Int,_ y:Int)->SIMD4<Float> {let i=(y*pixels.width+x)*4,a=Float(pixels.data[i+3])/255;guard a>0 else{return .zero};return .init(Float(pixels.data[i])/255/a,Float(pixels.data[i+1])/255/a,Float(pixels.data[i+2])/255/a,a)}
    return (pixel(x0,y0)*(1-fx)+pixel(x1,y0)*fx)*(1-fy)+(pixel(x0,y1)*(1-fx)+pixel(x1,y1)*fx)*fy
  }
  /// Replaces baked texture chroma with a chosen surface color while retaining relative weave detail.
  /// Source pixels remain immutable. Mean-normalized linear luminance avoids near-black factor tints.
  private static func recolor(_ source:CGImage,color:SIMD3<Float>)throws->CGImage {
    let ratio=min(1,2048/Double(max(source.width,source.height))),width=max(1,Int(Double(source.width)*ratio)),height=max(1,Int(Double(source.height)*ratio))
    guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw MeshAssetError.limit("Could not allocate a derived colorway.")}
    context.interpolationQuality = .high;context.draw(source,in:.init(x:0,y:0,width:width,height:height))
    guard let scaled=context.makeImage() else{throw MeshAssetError.invalid("Source color texture could not be read.")}
    let sourcePixels=try pixels(scaled);var luminance=[Float](repeating:0,count:width*height),total=0.0,weight=0.0
    for i in luminance.indices {
      if i%8192==0 {try Task.checkCancellation()}
      let offset=i*4,a=Float(sourcePixels.data[offset+3])/255
      guard a>0 else{continue}
      let r=linear(Float(sourcePixels.data[offset])/255/a),g=linear(Float(sourcePixels.data[offset+1])/255/a),b=linear(Float(sourcePixels.data[offset+2])/255/a),value=r*0.2126+g*0.7152+b*0.0722
      luminance[i]=value;total+=Double(value*a);weight+=Double(a)
    }
    let mean=Float(weight>0 ? total/weight:0),target=SIMD3(linear(color.x),linear(color.y),linear(color.z));var result=sourcePixels.data
    for i in luminance.indices {
      if i%8192==0 {try Task.checkCancellation()}
      let detail=mean>1e-8 ? min(1.8,max(0.35,luminance[i]/mean)):1,offset=i*4,rgb=target*detail
      result[offset]=encoded(rgb.x);result[offset+1]=encoded(rgb.y);result[offset+2]=encoded(rgb.z)
    }
    guard let provider=CGDataProvider(data:Data(result) as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{throw MeshAssetError.limit("Could not publish a derived colorway.")};return image
  }
  /// A display-only UV0 composite preserves the underlying material outside transparent artwork.
  /// It is bounded to 2048² pixels and intentionally carries no physical print-size certification.
  private static func composite(artwork:CGImage,source:MeshAssetMaterial,prepared:MeshAssetPreparedScene,factor:SIMD4<Float>,baseImage:CGImage?=nil)throws->CGImage {
    let art=try pixels(artwork),binding=source.baseColorTexture,texture=binding.map{prepared.textures[$0.textureIndex]},base=try texture.map{try pixels(baseImage ?? prepared.images[$0.imageIndex])}
    let width=min(2048,max(art.width,base?.width ?? 1)),height=min(2048,max(art.height,base?.height ?? 1));var result=[UInt8](repeating:0,count:width*height*4)
    let linearFactor=prepared.gltfLinearFactors ? factor:SIMD4(linear(factor.x),linear(factor.y),linear(factor.z),factor.w)
    for y in 0..<height {if y%16==0,Task.isCancelled {throw CancellationError()};for x in 0..<width {
      let uv=SIMD2<Double>((Double(x)+0.5)/Double(width),(Double(y)+0.5)/Double(height)),a=sample(art,uv:uv)
      var b=SIMD4<Float>(repeating:1)
      if let base,let binding,let texture {let mapped=binding.transformed(.init(Float(uv.x),Float(uv.y)));b=sample(base,uv:.init(Double(mapped.u),Double(mapped.v)),wrapS:texture.wrapS,wrapT:texture.wrapT)}
      let alpha=b.w*linearFactor.w,baseRGB=SIMD3<Float>(linear(b.x),linear(b.y),linear(b.z))*SIMD3(linearFactor.x,linearFactor.y,linearFactor.z),artRGB=SIMD3<Float>(linear(a.x),linear(a.y),linear(a.z)),mixed=baseRGB*(1-a.w)+artRGB*a.w,i=(y*width+x)*4
      result[i]=encoded(mixed.x);result[i+1]=encoded(mixed.y);result[i+2]=encoded(mixed.z);result[i+3]=UInt8(max(0,min(255,(alpha*255).rounded())))
    }}
    guard let provider=CGDataProvider(data:Data(result) as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{throw MeshAssetError.limit("UV composite could not be published.")};return image
  }
}

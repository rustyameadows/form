import Foundation
import ImageIO

public enum MeshAssetGeometry {
  public static func vertexNormals(points:[MeshPoint3],indices:[UInt32])->[MeshVector3] {
    var sums=[SIMD3<Double>](repeating:.zero,count:points.count)
    for i in stride(from:0,to:indices.count,by:3) {
      let a=Int(indices[i]),b=Int(indices[i+1]),c=Int(indices[i+2]);let u=points[b].simd-points[a].simd,v=points[c].simd-points[a].simd
      let n=SIMD3<Double>(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
      sums[a]+=n;sums[b]+=n;sums[c]+=n
    }
    return sums.map {n in let length=sqrt(n.x*n.x+n.y*n.y+n.z*n.z);return length>1e-20 ? .init(Float(n.x/length),Float(n.y/length),Float(n.z/length)):.init(0,1,0)}
  }
  /// Bake a node's complete affine transform, including nonuniform scales, shear and reflection.
  /// The document hierarchy remains intact; this is a derived renderer/fabrication representation.
  public static func transformed(_ primitive:MeshAssetPrimitive,by transform:MeshAssetTransform,id:String?=nil)throws->MeshAssetPrimitive {
    guard transform.matrix.count==16,transform.matrix.allSatisfy(\.isFinite) else{throw MeshAssetError.invalid("Derived mesh transform is not a finite affine matrix.")}
    var output=primitive;output.id=id ?? primitive.id
    output.positionsMM=primitive.positionsMM.map(transform.point)
    output.normals=primitive.normals.map(transform.normal)
    output.tangents=primitive.tangents.enumerated().map {index,t in
      let m=transform.matrix,n=output.normals[index],nx=Double(n.x),ny=Double(n.y),nz=Double(n.z)
      var x=m[0]*Double(t.x)+m[4]*Double(t.y)+m[8]*Double(t.z),y=m[1]*Double(t.x)+m[5]*Double(t.y)+m[9]*Double(t.z),z=m[2]*Double(t.x)+m[6]*Double(t.y)+m[10]*Double(t.z)
      let dot=x*nx+y*ny+z*nz;x-=dot*nx;y-=dot*ny;z-=dot*nz
      let length=sqrt(x*x+y*y+z*z)
      return length>1e-20 ? .init(Float(x/length),Float(y/length),Float(z/length),t.w*(transform.determinant<0 ? -1:1)):.init(1,0,0,1)
    }
    if transform.determinant<0 {for i in stride(from:0,to:output.indices.count,by:3) {output.indices.swapAt(i+1,i+2)}}
    return output
  }
  public static func flattenedPrimitives(_ document:MeshAssetDocument)throws->[MeshAssetPrimitive] {
    try validate(document)
    return try document.nodes.filter(\.inSelectedScene).flatMap {node->[MeshAssetPrimitive] in
      guard let index=node.meshIndex else{return []}
      return try document.meshes[index].primitives.map {try transformed($0,by:node.worldTransform,id:node.id+"/"+$0.id)}
    }
  }
  /// Validate normalized resources again before using untrusted decoded project JSON.
  public static func validate(_ document:MeshAssetDocument,limits:MeshImportLimits = .init())throws {
    guard document.meshes.count<=limits.meshes,document.nodes.count<=limits.nodes,document.materials.count<=limits.materials,document.images.count<=limits.images else{throw MeshAssetError.limit("Normalized resource counts exceed their configured budgets.")}
    guard document.sourceData.count<=limits.sourceBytes,document.provenance.sourceByteCount==document.sourceData.count,MeshAssetHash.sha256(document.sourceData)==document.provenance.sourceSHA256,Set(document.nodes.map(\.id)).count==document.nodes.count,Set(document.meshes.map(\.id)).count==document.meshes.count else{throw MeshAssetError.invalid("Normalized source bytes/digest or semantic IDs are invalid.")}
    var externalBytes=0
    for resource in document.externalResources {
      let path=resource.relativePath.removingPercentEncoding ?? ""
      guard !path.isEmpty,!path.hasPrefix("/"),!path.contains(":"),!path.contains("\\"),!path.contains("\0"),path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}),resource.data.count<=limits.resourceBytes,resource.sha256==MeshAssetHash.sha256(resource.data) else{throw MeshAssetError.invalid("Normalized external resource path, bytes or digest is invalid.")}
      externalBytes+=resource.data.count;guard externalBytes<=limits.totalResourceBytes else{throw MeshAssetError.limit("Normalized external resource aggregate exceeds its budget.")}
    }
    var vertices=0,triangles=0,primitives=0
    for mesh in document.meshes {for primitive in mesh.primitives {
      let n=primitive.positionsMM.count;vertices+=n;triangles+=primitive.indices.count/3;primitives+=1
      guard n>0,vertices<=limits.vertices,triangles<=limits.triangles,primitives<=limits.primitives,primitive.indices.count%3==0,!primitive.indices.isEmpty,
        primitive.indices.allSatisfy({Int($0)<n}),primitive.normals.count==n,
        primitive.uv0.isEmpty || primitive.uv0.count==n,primitive.uv1.isEmpty || primitive.uv1.count==n,
        primitive.colors.isEmpty || primitive.colors.count==n,primitive.tangents.isEmpty || primitive.tangents.count==n,
        primitive.positionsMM.allSatisfy({p in [p.x,p.y,p.z].allSatisfy{$0.isFinite && abs($0)<=limits.coordinateMM}}),
        primitive.normals.allSatisfy({[$0.x,$0.y,$0.z].allSatisfy(\.isFinite)}),
        primitive.colors.allSatisfy({[$0.r,$0.g,$0.b,$0.a].allSatisfy{$0.isFinite && (0...1).contains($0)}}),
        primitive.tangents.allSatisfy({[$0.x,$0.y,$0.z,$0.w].allSatisfy(\.isFinite)}),
        primitive.uv0.allSatisfy({$0.u.isFinite && $0.v.isFinite}),primitive.uv1.allSatisfy({$0.u.isFinite && $0.v.isFinite}) else{throw MeshAssetError.invalid("Normalized mesh buffers are inconsistent or exceed the supported domain.")}
      if let i=primitive.materialIndex {guard document.materials.indices.contains(i) else{throw MeshAssetError.invalid("Normalized mesh material index is invalid.")}}
    }}
    var instanceVertices=0,instanceTriangles=0,instancePrimitives=0,parents=[Int?](repeating:nil,count:document.nodes.count)
    for (i,node) in document.nodes.enumerated() {
      for transform in [node.localTransform,node.worldTransform] {guard transform.matrix.count==16,transform.matrix.allSatisfy(\.isFinite),[0,1,2,4,5,6,8,9,10].allSatisfy({Float(transform.matrix[$0]).isFinite}),abs(transform.matrix[3])<1e-12,abs(transform.matrix[7])<1e-12,abs(transform.matrix[11])<1e-12,abs(transform.matrix[15]-1)<1e-12 else{throw MeshAssetError.invalid("Normalized node transform is invalid or exceeds the viewport's finite affine domain.")}}
      guard Set(node.children).count==node.children.count else{throw MeshAssetError.invalid("Normalized node repeats a child.")}
      for child in node.children {guard document.nodes.indices.contains(child),child != i,parents[child]==nil else{throw MeshAssetError.invalid("Normalized hierarchy contains an invalid/shared child.")};parents[child]=i}
      if let mesh=node.meshIndex {
        guard document.meshes.indices.contains(mesh) else{throw MeshAssetError.invalid("Normalized node mesh index is invalid.")}
        if node.inSelectedScene {instancePrimitives+=document.meshes[mesh].primitives.count;instanceVertices+=document.meshes[mesh].primitives.reduce(0){$0+$1.positionsMM.count};instanceTriangles+=document.meshes[mesh].primitives.reduce(0){$0+$1.indices.count/3}}
      }
      guard instancePrimitives<=limits.primitives,instanceVertices<=limits.instanceVertices,instanceTriangles<=limits.instanceTriangles else{throw MeshAssetError.limit("Normalized instance complexity exceeds its configured budget.")}
    }
    for i in document.nodes.indices {
      var path=Set<Int>(),next:Int?=i
      while let j=next {guard path.insert(j).inserted,path.count<=limits.hierarchyDepth+1 else{throw MeshAssetError.invalid("Normalized hierarchy contains a cycle or excessive depth.")};next=parents[j]}
    }
    guard Set(document.sceneRoots).count==document.sceneRoots.count,document.sceneRoots.allSatisfy({document.nodes.indices.contains($0) && parents[$0]==nil}) else{throw MeshAssetError.invalid("Normalized scene roots are invalid.")}
    var active=Set<Int>(),pending=document.sceneRoots
    while let i=pending.popLast() {if active.insert(i).inserted {pending+=document.nodes[i].children}}
    guard document.nodes.enumerated().allSatisfy({$0.element.inSelectedScene==active.contains($0.offset)}) else{throw MeshAssetError.invalid("Normalized selected-scene flags disagree with hierarchy roots.")}
    var low=MeshPoint3(.infinity,.infinity,.infinity),high=MeshPoint3(-.infinity,-.infinity,-.infinity),selectedVertices=0
    for (index,node) in document.nodes.enumerated() {
      try Task.checkCancellation()
      let expected=parents[index].map{document.nodes[$0].worldTransform.followed(by:node.localTransform)} ?? node.localTransform
      guard expected.matrix.allSatisfy(\.isFinite),zip(expected.matrix,node.worldTransform.matrix).allSatisfy({abs($0-$1)<=1e-10*max(1,abs($0))}) else{throw MeshAssetError.invalid("Normalized world transforms disagree with their local hierarchy.")}
      guard node.inSelectedScene,let meshIndex=node.meshIndex else{continue}
      for primitive in document.meshes[meshIndex].primitives {for p in primitive.positionsMM {
        if selectedVertices%8192==0 {try Task.checkCancellation()};selectedVertices+=1
        let q=node.worldTransform.point(p)
        guard [q.x,q.y,q.z].allSatisfy({$0.isFinite && abs($0)<=limits.coordinateMM}) else{throw MeshAssetError.limit("Normalized transformed geometry exceeds its finite millimeter coordinate budget.")}
        low.x=min(low.x,q.x);low.y=min(low.y,q.y);low.z=min(low.z,q.z);high.x=max(high.x,q.x);high.y=max(high.y,q.y);high.z=max(high.z,q.z)
      }}
    }
    let actual=[low.x,low.y,low.z,high.x,high.y,high.z],claimed=[document.boundsMM.minimum.x,document.boundsMM.minimum.y,document.boundsMM.minimum.z,document.boundsMM.maximum.x,document.boundsMM.maximum.y,document.boundsMM.maximum.z]
    guard selectedVertices>0,zip(actual,claimed).allSatisfy({$0.isFinite && $1.isFinite && abs($0-$1)<=0.000001}) else{throw MeshAssetError.invalid("Normalized bounds disagree with the selected transformed source geometry.")}
    for texture in document.textures {guard document.images.indices.contains(texture.imageIndex) else{throw MeshAssetError.invalid("Normalized texture image index is invalid.")}}
    for material in document.materials {
      guard material.baseColor.count==4,material.emissive.count==3,material.baseColor.allSatisfy({$0.isFinite && (0...1).contains($0)}),material.emissive.allSatisfy({$0.isFinite && (0...1).contains($0)}),[material.metallic,material.roughness,material.alphaCutoff].allSatisfy({$0.isFinite && (0...1).contains($0)}),["OPAQUE","MASK","BLEND"].contains(material.alphaMode) else{throw MeshAssetError.invalid("Normalized material factors are invalid.")}
      for binding in [material.baseColorTexture,material.normalTexture,material.metallicRoughnessTexture,material.occlusionTexture,material.emissiveTexture].compactMap({$0}) {guard document.textures.indices.contains(binding.textureIndex),[0,1].contains(binding.texCoord),[Double(binding.offset.u),Double(binding.offset.v),Double(binding.scale.u),Double(binding.scale.v),binding.rotation,binding.strength].allSatisfy(\.isFinite),binding.strength>=0 else{throw MeshAssetError.invalid("Normalized texture binding is invalid.")}}
    }
    var bytes=0,pixels=0
    for image in document.images {
      guard image.data.count<=limits.textureBytes,image.width>0,image.height>0,image.width<=limits.textureEdge,image.height<=limits.textureEdge,image.height<=limits.texturePixels/image.width,MeshAssetHash.sha256(image.data)==image.sha256 else{throw MeshAssetError.invalid("Normalized image bytes, digest or dimensions are invalid.")}
      guard let source=CGImageSourceCreateWithData(image.data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetCount(source)==1,let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=props[kCGImagePropertyPixelWidth] as? Int,let height=props[kCGImagePropertyPixelHeight] as? Int,width==image.width,height==image.height else{throw MeshAssetError.invalid("Normalized texture dimensions disagree with original encoded pixels.")}
      bytes+=image.data.count;pixels+=image.width*image.height
      guard bytes<=limits.totalResourceBytes,pixels<=limits.totalTexturePixels else{throw MeshAssetError.limit("Normalized texture aggregate exceeds its budget.")}
    }
  }
}

public struct MeshTopologyReport:Codable,Equatable,Sendable {
  public var triangles:Int,weldedVertices:Int,boundaryEdges:Int,nonManifoldEdges:Int,inconsistentlyOrientedEdges:Int,degenerateTriangles:Int
  public var signedVolumeMM3:Double
  public var weldToleranceMM:Double
  public var selfIntersectionsChecked:Bool = false
  public var isClosedOrientedSurface:Bool {triangles>0 && boundaryEdges==0 && nonManifoldEdges==0 && inconsistentlyOrientedEdges==0 && degenerateTriangles==0}
}
public enum MeshTopology {
  private struct Vertex:Hashable {var x:Int64,y:Int64,z:Int64}
  private struct Edge:Hashable {var a:Int,b:Int}
  /// Bounded geometric-weld inspection. It is not a self-intersection test or manufacturing certification.
  public static func inspect(_ primitive:MeshAssetPrimitive,toleranceMM:Double=0.00001,maximumTriangles:Int=300_000)throws->MeshTopologyReport {
    guard toleranceMM.isFinite,(1e-8...0.1).contains(toleranceMM),primitive.indices.count%3==0,primitive.indices.count/3<=maximumTriangles,primitive.indices.allSatisfy({Int($0)<primitive.positionsMM.count}) else{throw MeshAssetError.limit("Topology inspection needs valid indices, a supported weld tolerance and at most \(maximumTriangles) triangles.")}
    var lookup:[Vertex:Int]=[:],welded:[Int]=[];welded.reserveCapacity(primitive.positionsMM.count)
    for (index,p) in primitive.positionsMM.enumerated() {
      if index%8192==0 {try Task.checkCancellation()}
      guard [p.x,p.y,p.z].allSatisfy({$0.isFinite && abs($0/toleranceMM)<Double(Int64.max)-1}) else{throw MeshAssetError.invalid("Topology vertex cannot be represented at this weld tolerance.")}
      let key=Vertex(x:Int64((p.x/toleranceMM).rounded()),y:Int64((p.y/toleranceMM).rounded()),z:Int64((p.z/toleranceMM).rounded()))
      if let id=lookup[key] {welded.append(id)}else{let id=lookup.count;lookup[key]=id;welded.append(id)}
    }
    var edges:[Edge:(count:Int,direction:Int)]=[:],degenerate=0,volume=0.0
    let anchor=primitive.positionsMM.first?.simd ?? .zero
    for i in stride(from:0,to:primitive.indices.count,by:3) {
      if i%8190==0 {try Task.checkCancellation()}
      let a=Int(primitive.indices[i]),b=Int(primitive.indices[i+1]),c=Int(primitive.indices[i+2]),ids=[welded[a],welded[b],welded[c]]
      let p=primitive.positionsMM[a].simd-anchor,q=primitive.positionsMM[b].simd-anchor,r=primitive.positionsMM[c].simd-anchor,u=q-p,v=r-p,cross=SIMD3<Double>(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
      if Set(ids).count<3 || cross.x*cross.x+cross.y*cross.y+cross.z*cross.z<=pow(toleranceMM,4) {degenerate+=1;continue}
      volume+=(p.x*(q.y*r.z-q.z*r.y)+p.y*(q.z*r.x-q.x*r.z)+p.z*(q.x*r.y-q.y*r.x))/6
      for j in 0..<3 {let x=ids[j],y=ids[(j+1)%3],key=Edge(a:min(x,y),b:max(x,y));var value=edges[key] ?? (0,0);value.count+=1;value.direction+=x<y ? 1:-1;edges[key]=value}
    }
    return .init(triangles:primitive.indices.count/3,weldedVertices:lookup.count,boundaryEdges:edges.values.filter{$0.count==1}.count,nonManifoldEdges:edges.values.filter{$0.count>2}.count,inconsistentlyOrientedEdges:edges.values.filter{$0.count==2 && $0.direction != 0}.count,degenerateTriangles:degenerate,signedVolumeMM3:volume,weldToleranceMM:toleranceMM)
  }
}

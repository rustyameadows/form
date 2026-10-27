import Foundation
import ImageIO

/// A bounded native glTF 2.0/GLB reader. No network fetches, script execution, SceneKit, or lossy recipe substitution.
public enum GLTFImporter {
  public static func importFile(_ url:URL,options:MeshImportOptions = .init()) throws -> MeshAssetDocument {
    let source=url.resolvingSymlinksInPath().standardizedFileURL
    let data=try boundedRead(source,limit:options.limits.sourceBytes)
    let directory=source.deletingLastPathComponent()
    return try importData(data,fileName:url.lastPathComponent,options:options) { uri in
      let decoded=try safeRelativePath(uri)
      let file=directory.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
      guard file.path.hasPrefix(directory.path+"/") else {throw MeshAssetError.invalid("An external resource escapes the selected asset directory.")}
      return try boundedRead(file,limit:options.limits.resourceBytes)
    }
  }
  /// The resolver receives only validated relative resource names. It must not fetch remote URLs.
  public static func importData(_ data:Data,fileName:String="Imported.glb",options:MeshImportOptions = .init(),externalResource:((String)throws->Data)?=nil) throws -> MeshAssetDocument {
    guard !data.isEmpty,data.count<=options.limits.sourceBytes else{throw MeshAssetError.limit("Source file exceeds the configured byte budget.")}
    let content=try container(data,limits:options.limits)
    let root:Root
    do {root=try JSONDecoder().decode(Root.self,from:content.json)}catch{throw MeshAssetError.invalid("glTF JSON cannot be decoded: \(error.localizedDescription)")}
    var reader=Reader(root:root,options:options,resolver:externalResource,binary:content.binary)
    return try reader.read(source:data,fileName:fileName,format:data.count>=4 && u32(data,0)==0x46546c67 ? "glb":"gltf")
  }
  private static func boundedRead(_ url:URL,limit:Int)throws->Data {
    let values=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
    guard values.isRegularFile==true,let count=values.fileSize,count>0,count<=limit else{throw MeshAssetError.limit("Choose a nonempty regular file within the source/resource byte budget.")}
    let data=try Data(contentsOf:url,options:[])
    guard data.count<=limit else{throw MeshAssetError.limit("The source grew beyond its byte budget while reading.")};return data
  }
  private static func safeRelativePath(_ uri:String)throws->String {
    guard uri.utf8.count<=4096,!uri.contains("\\"),!uri.contains("\0"),let decoded=uri.removingPercentEncoding,
      !decoded.hasPrefix("/"),!decoded.contains(":"),!decoded.contains("?"),!decoded.contains("#"),!decoded.contains("\\"),!decoded.contains("\0"),
      decoded.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({!$0.isEmpty && $0 != ".." && $0 != "."}) else{throw MeshAssetError.invalid("External resources must be ordinary relative file paths inside the asset directory.")}
    return decoded
  }
  private static func u32(_ data:Data,_ offset:Int)->UInt32 {
    UInt32(data[offset]) | UInt32(data[offset+1])<<8 | UInt32(data[offset+2])<<16 | UInt32(data[offset+3])<<24
  }
  private static func container(_ data:Data,limits:MeshImportLimits)throws->(json:Data,binary:Data?) {
    if data.count>=4,u32(data,0)==0x46546c67 {
      guard data.count>=20,u32(data,4)==2,Int(u32(data,8))==data.count else{throw MeshAssetError.invalid("GLB header/version/length does not match this file.")}
      var offset=12,json:Data?,binary:Data?,chunks=0
      while offset<data.count {
        guard offset<=data.count-8 else{throw MeshAssetError.invalid("GLB has a truncated chunk header.")}
        let length=Int(u32(data,offset)),kind=u32(data,offset+4);offset+=8
        guard length%4==0,length<=data.count-offset else{throw MeshAssetError.invalid("GLB chunk length is unaligned or exceeds the file.")}
        chunks+=1;guard chunks<=64 else{throw MeshAssetError.limit("Too many GLB chunks.")}
        if chunks==1 && kind != 0x4e4f534a {throw MeshAssetError.invalid("The first GLB chunk must be JSON.")}
        if kind==0x4e4f534a {
          guard json==nil,length<=limits.jsonBytes else{throw MeshAssetError.invalid("GLB contains duplicate or oversized JSON chunks.")};json=data.subdata(in:offset..<offset+length)
        } else if kind==0x004e4942 {
          guard binary==nil else{throw MeshAssetError.invalid("GLB contains multiple binary chunks.")};binary=data.subdata(in:offset..<offset+length)
        }
        offset+=length
      }
      guard let json else{throw MeshAssetError.invalid("GLB has no JSON chunk.")};return(json,binary)
    }
    guard data.count<=limits.jsonBytes else{throw MeshAssetError.limit("glTF JSON exceeds the configured byte budget.")};return(data,nil)
  }

  private struct Root:Decodable {
    var asset:Asset;var extensionsRequired:[String]?;var extensionsUsed:[String]?
    var buffers:[Buffer]?;var bufferViews:[BufferView]?;var accessors:[Accessor]?
    var meshes:[Mesh]?;var nodes:[Node]?;var scenes:[Scene]?;var scene:Int?
    var materials:[Material]?;var textures:[Texture]?;var images:[Image]?;var samplers:[Sampler]?
    var skins:[Ignored]?;var animations:[Ignored]?
  }
  private struct Ignored:Decodable {}
  private struct Asset:Decodable {var version:String;var minVersion:String?;var generator:String?}
  private struct Buffer:Decodable {var uri:String?;var byteLength:Int}
  private struct BufferView:Decodable {var buffer:Int;var byteOffset:Int?;var byteLength:Int;var byteStride:Int?}
  private struct Accessor:Decodable {var bufferView:Int?;var byteOffset:Int?;var componentType:Int;var normalized:Bool?;var count:Int;var type:String;var sparse:Sparse?}
  private struct Sparse:Decodable {var count:Int;var indices:SparseIndices;var values:SparseValues}
  private struct SparseIndices:Decodable {var bufferView:Int;var byteOffset:Int?;var componentType:Int}
  private struct SparseValues:Decodable {var bufferView:Int;var byteOffset:Int?}
  private struct Mesh:Decodable {var name:String?;var primitives:[Primitive];var weights:[Double]?}
  private struct Primitive:Decodable {var attributes:[String:Int];var indices:Int?;var material:Int?;var mode:Int?;var targets:[[String:Int]]?}
  private struct Node:Decodable {var name:String?;var mesh:Int?;var children:[Int]?;var matrix:[Double]?;var translation:[Double]?;var rotation:[Double]?;var scale:[Double]?;var skin:Int?;var weights:[Double]?}
  private struct Scene:Decodable {var name:String?;var nodes:[Int]?}
  private struct Texture:Decodable {var source:Int?;var sampler:Int?;var name:String?}
  private struct Image:Decodable {var name:String?;var uri:String?;var mimeType:String?;var bufferView:Int?}
  private struct Sampler:Decodable {var wrapS:Int?;var wrapT:Int?;var minFilter:Int?;var magFilter:Int?}
  private struct Material:Decodable {var name:String?;var pbrMetallicRoughness:PBR?;var normalTexture:Binding?;var occlusionTexture:Binding?;var emissiveTexture:Binding?;var emissiveFactor:[Double]?;var alphaMode:String?;var alphaCutoff:Double?;var doubleSided:Bool?;var extensions:MaterialExtensions?}
  private struct MaterialExtensions:Decodable {var KHR_materials_unlit:Ignored?}
  private struct PBR:Decodable {var baseColorFactor:[Double]?;var baseColorTexture:Binding?;var metallicFactor:Double?;var roughnessFactor:Double?;var metallicRoughnessTexture:Binding?}
  private struct Binding:Decodable {var index:Int;var texCoord:Int?;var scale:Double?;var strength:Double?;var extensions:BindingExtensions?}
  private struct BindingExtensions:Decodable {var KHR_texture_transform:TextureTransform?}
  private struct TextureTransform:Decodable {var offset:[Double]?;var rotation:Double?;var scale:[Double]?;var texCoord:Int?}

  private struct Reader {
    let root:Root,options:MeshImportOptions,resolver:((String)throws->Data)?,binary:Data?
    var buffers:[Data]=[],external:[String:MeshAssetResource]=[:],warnings:[String]=[]
    var resourceBytes=0,vertices=0,triangles=0,primitives=0,totalTexturePixels=0
    var defaultMaterialIndex:Int?
    var limit:MeshImportLimits {options.limits}
    var unit:MeshSourceUnit {options.sourceUnit ?? .meter}
    func at<T>(_ list:[T]?,_ index:Int,_ kind:String)throws->T {guard let list,index>=0,index<list.count else{throw MeshAssetError.invalid("\(kind) index \(index) is out of range.")};return list[index]}
    func count(_ n:Int,_ maximum:Int,_ label:String)throws {guard n>=0,n<=maximum else{throw MeshAssetError.limit("\(label) exceeds \(maximum).")}}
    mutating func read(source:Data,fileName:String,format:String)throws->MeshAssetDocument {
      guard root.asset.version=="2.0",root.asset.minVersion==nil || root.asset.minVersion=="2.0" else{throw MeshAssetError.unsupported("Only glTF 2.0 is supported.")}
      let supported:Set<String>=["KHR_materials_unlit","KHR_texture_transform"]
      for ext in root.extensionsRequired ?? [] where !supported.contains(ext) {throw MeshAssetError.unsupported("Required extension \(ext) is not implemented; export an uncompressed static glTF 2.0 asset.")}
      for ext in root.extensionsUsed ?? [] where !supported.contains(ext) {warnings.append("Optional extension \(ext) is retained in the original source but not evaluated.")}
      guard (root.skins ?? []).isEmpty else{throw MeshAssetError.unsupported("Skinning is not evaluated. Export the posed garment as a static mesh.")}
      if !(root.animations ?? []).isEmpty {warnings.append("Animations are retained in source; the imported object uses the declared static node transforms.")}
      try count(root.nodes?.count ?? 0,limit.nodes,"Nodes");try count(root.meshes?.count ?? 0,limit.meshes,"Meshes");try count(root.materials?.count ?? 0,limit.materials,"Materials");try count(root.images?.count ?? 0,limit.images,"Images")
      try count(root.accessors?.count ?? 0,limit.primitives*16,"Accessors");try count(root.bufferViews?.count ?? 0,limit.primitives*16,"Buffer views");try count(root.buffers?.count ?? 0,1024,"Buffers");try count(root.textures?.count ?? 0,limit.images*8,"Textures");try count(root.samplers?.count ?? 0,limit.images*8,"Samplers")
      for (index,buffer) in (root.buffers ?? []).enumerated() {
        try count(buffer.byteLength,limit.resourceBytes,"Buffer bytes");guard buffer.byteLength>0 else{throw MeshAssetError.invalid("Buffers must not be empty.")}
        let data:Data
        if let uri=buffer.uri {data=try resource(uri,kind:"buffer")}
        else {guard index==0,let binary else{throw MeshAssetError.invalid("A buffer without URI requires the first GLB BIN chunk.")};data=binary}
        guard data.count>=buffer.byteLength,data.count-buffer.byteLength<=3 || buffer.uri != nil else{throw MeshAssetError.invalid("Buffer length does not agree with the GLB BIN chunk.")}
        buffers.append(data.prefix(buffer.byteLength))
      }
      for view in root.bufferViews ?? [] {_ = try bytes(view)}
      let images=try readImages(),textures=try readTextures(imageCount:images.count)
      var materials=try readMaterials(textureCount:textures.count)
      if (root.meshes ?? []).contains(where:{$0.primitives.contains(where:{$0.material==nil})}) {defaultMaterialIndex=materials.count;materials.append(.init(id:"material-default",name:"glTF default material"))}
      var meshes:[MeshAssetMesh]=[]
      for (meshIndex,mesh) in (root.meshes ?? []).enumerated() {
        guard mesh.weights==nil || mesh.weights!.isEmpty else{throw MeshAssetError.unsupported("Morph-weight meshes require a static applied export.")}
        var parts:[MeshAssetPrimitive]=[]
        for (primitiveIndex,primitive) in mesh.primitives.enumerated() {parts.append(try readPrimitive(primitive,mesh:meshIndex,index:primitiveIndex,materialCount:materials.count))}
        guard !parts.isEmpty else{throw MeshAssetError.invalid("Mesh \(meshIndex) has no primitives.")}
        meshes.append(.init(id:"mesh-\(meshIndex)",name:mesh.name ?? "Mesh \(meshIndex+1)",primitives:parts))
      }
      guard !meshes.isEmpty else{throw MeshAssetError.invalid("No triangle mesh geometry was found.")}
      let hierarchy=try readNodes(meshes:meshes)
      try validateTextureCoordinates(meshes:meshes,materials:materials)
      var lo=MeshPoint3(.infinity,.infinity,.infinity),hi=MeshPoint3(-.infinity,-.infinity,-.infinity),instances=0,instanceVertices=0,instanceTriangles=0,instancePrimitives=0
      for node in hierarchy.nodes where node.inSelectedScene {
        guard let meshIndex=node.meshIndex else{continue};instances+=1
        for primitive in meshes[meshIndex].primitives {
          instancePrimitives+=1;try count(instancePrimitives,limit.primitives,"Instanced primitives")
          instanceVertices+=primitive.positionsMM.count;instanceTriangles+=primitive.indices.count/3
          try count(instanceVertices,limit.instanceVertices,"Instanced vertices");try count(instanceTriangles,limit.instanceTriangles,"Instanced triangles")
          for p in primitive.positionsMM {
            let q=node.worldTransform.point(p)
            guard [q.x,q.y,q.z].allSatisfy({$0.isFinite && abs($0)<=limit.coordinateMM}) else{throw MeshAssetError.limit("World-space coordinates exceed the finite millimeter domain.")}
            lo.x=min(lo.x,q.x);lo.y=min(lo.y,q.y);lo.z=min(lo.z,q.z);hi.x=max(hi.x,q.x);hi.y=max(hi.y,q.y);hi.z=max(hi.z,q.z)
          }
        }
      }
      guard instances>0 else{throw MeshAssetError.invalid("The selected scene has no mesh instances.")}
      let declaration=options.sourceUnit==nil ? "glTF 2.0 declares meters":"Explicit user override of glTF meter units"
      let provenance=MeshAssetProvenance(format:format,fileName:fileName,sourceSHA256:MeshAssetHash.sha256(source),sourceByteCount:source.count,unit:unit,unitDeclaration:declaration,warnings:Array(Set(warnings)).sorted())
      return .init(provenance:provenance,sourceData:source,externalResources:external.values.sorted{$0.relativePath<$1.relativePath},meshes:meshes,nodes:hierarchy.nodes,sceneRoots:hierarchy.roots,materials:materials,images:images,textures:textures,boundsMM:.init(minimum:lo,maximum:hi))
    }
    mutating func resource(_ uri:String,kind:String)throws->Data {
      let data:Data
      if uri.hasPrefix("data:") {
        guard let comma=uri.firstIndex(of:",") else{throw MeshAssetError.invalid("Malformed embedded resource URI.")}
        let header=String(uri[..<comma]),payload=uri[uri.index(after:comma)...]
        let allowed=kind=="image" ? ["data:image/png;base64","data:image/jpeg;base64"]:["data:application/octet-stream;base64","data:application/gltf-buffer;base64"]
        guard allowed.contains(header),payload.utf8.count<=((limit.resourceBytes+2)/3)*4+4,let decoded=Data(base64Encoded:String(payload)) else{throw MeshAssetError.invalid("Embedded resources need bounded supported base64 data.")};data=decoded
      }else {
        _=try GLTFImporter.safeRelativePath(uri)
        if let cached=external[uri] {return cached.data}
        guard let resolver else{throw MeshAssetError.invalid("External resource \(uri) is unavailable; import from its containing directory.")}
        data=try resolver(uri);external[uri] = .init(relativePath:uri,data:data)
      }
      try count(data.count,limit.resourceBytes,"Resource bytes")
      guard data.count<=limit.totalResourceBytes-resourceBytes else{throw MeshAssetError.limit("Aggregate resource bytes exceed the configured budget.")};resourceBytes+=data.count
      return data
    }
    func bytes(_ view:BufferView)throws->Data {
      let buffer=try at(buffers,view.buffer,"Buffer"),offset=view.byteOffset ?? 0
      guard offset>=0,view.byteLength>0,offset<=buffer.count,view.byteLength<=buffer.count-offset else{throw MeshAssetError.invalid("A buffer view exceeds its parent buffer.")}
      if let stride=view.byteStride {guard (4...252).contains(stride),stride%4==0 else{throw MeshAssetError.invalid("Vertex byteStride must be a multiple of four between 4 and 252.")}}
      return buffer.subdata(in:offset..<offset+view.byteLength)
    }
    func componentBytes(_ type:Int)throws->Int {switch type {case 5120,5121:return 1;case 5122,5123:return 2;case 5125,5126:return 4;default:throw MeshAssetError.invalid("Unknown accessor component type \(type).")}}
    func component(_ bytes:UnsafeRawBufferPointer,_ offset:Int,_ type:Int,_ normalized:Bool)->Double {
      switch type {
      case 5120:let n=bytes.loadUnaligned(fromByteOffset:offset,as:Int8.self);return normalized ? max(-1,Double(n)/127):Double(n)
      case 5121:let n=bytes.loadUnaligned(fromByteOffset:offset,as:UInt8.self);return normalized ? Double(n)/255:Double(n)
      case 5122:let n=Int16(littleEndian:bytes.loadUnaligned(fromByteOffset:offset,as:Int16.self));return normalized ? max(-1,Double(n)/32767):Double(n)
      case 5123:let n=UInt16(littleEndian:bytes.loadUnaligned(fromByteOffset:offset,as:UInt16.self));return normalized ? Double(n)/65535:Double(n)
      case 5125:return Double(UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self)))
      default:return Double(Float(bitPattern:UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self))))
      }
    }
    func values(viewIndex:Int,offset:Int,count:Int,dimensions:Int,type:Int,normalized:Bool,allowStride:Bool)throws->[Double] {
      let view=try at(root.bufferViews,viewIndex,"Buffer view"),buffer=try at(buffers,view.buffer,"Buffer"),size=try componentBytes(type),element=size*dimensions,stride=view.byteStride ?? element,base=view.byteOffset ?? 0
      guard offset>=0,offset%size==0,base>=0,base%size==0,stride>=element,(allowStride || view.byteStride==nil),count>0,
        offset<=view.byteLength,element<=view.byteLength-offset,
        count-1<=(view.byteLength-offset-element)/stride,
        base<=buffer.count,view.byteLength<=buffer.count-base else{throw MeshAssetError.invalid("Accessor count, offset, alignment or stride exceeds its buffer view.")}
      var result=[Double](repeating:0,count:count*dimensions)
      try buffer.withUnsafeBytes { bytes in
        for i in 0..<count {if i%8192==0,Task.isCancelled {throw CancellationError()};for j in 0..<dimensions {
          let v=component(bytes,base+offset+i*stride+j*size,type,normalized)
          guard v.isFinite else{throw MeshAssetError.invalid("Accessor contains a non-finite value.")};result[i*dimensions+j]=v
        }}
      };return result
    }
    func accessor(_ index:Int,type:String,components:[Int],maximum:Int,vertex:Bool=true)throws->[Double] {
      let a=try at(root.accessors,index,"Accessor"),dimensions:[String:Int] = ["SCALAR":1,"VEC2":2,"VEC3":3,"VEC4":4]
      guard a.type==type,components.contains(a.componentType),let dimension=dimensions[type],a.count>0,a.count<=maximum else{throw MeshAssetError.invalid("Accessor \(index) has an unsupported type, count or component format.")}
      let normalized=a.normalized ?? false
      guard !(normalized && [5125,5126].contains(a.componentType)) else{throw MeshAssetError.invalid("Float and unsigned-int accessors cannot be normalized.")}
      var result:[Double]
      if let view=a.bufferView {result=try values(viewIndex:view,offset:a.byteOffset ?? 0,count:a.count,dimensions:dimension,type:a.componentType,normalized:normalized,allowStride:vertex)}
      else {guard a.byteOffset==nil else{throw MeshAssetError.invalid("An implicit-zero accessor cannot have a byte offset.")};result=[Double](repeating:0,count:a.count*dimension)}
      if let sparse=a.sparse {
        guard sparse.count>0,sparse.count<=a.count,[5121,5123,5125].contains(sparse.indices.componentType) else{throw MeshAssetError.invalid("Invalid sparse accessor count/index format.")}
        let ids=try values(viewIndex:sparse.indices.bufferView,offset:sparse.indices.byteOffset ?? 0,count:sparse.count,dimensions:1,type:sparse.indices.componentType,normalized:false,allowStride:false)
        let replacements=try values(viewIndex:sparse.values.bufferView,offset:sparse.values.byteOffset ?? 0,count:sparse.count,dimensions:dimension,type:a.componentType,normalized:normalized,allowStride:false)
        var previous = -1
        for i in 0..<sparse.count {let id=Int(ids[i]);guard id>previous,id<a.count else{throw MeshAssetError.invalid("Sparse accessor indices must be increasing and inside the destination.")};previous=id;for j in 0..<dimension {result[id*dimension+j]=replacements[i*dimension+j]}}
      }
      return result
    }
    mutating func readPrimitive(_ p:Primitive,mesh:Int,index:Int,materialCount:Int)throws->MeshAssetPrimitive {
      primitives+=1;try count(primitives,limit.primitives,"Primitives")
      guard p.targets==nil || p.targets!.isEmpty else{throw MeshAssetError.unsupported("Morph targets are not applied; export a static evaluated mesh.")}
      guard let position=p.attributes["POSITION"] else{throw MeshAssetError.invalid("Mesh primitive has no POSITION attribute.")}
      let raw=try accessor(position,type:"VEC3",components:[5126],maximum:limit.vertices),n=raw.count/3
      guard n<=limit.vertices-vertices else{throw MeshAssetError.limit("Aggregate vertices exceed \(limit.vertices).")};vertices+=n
      var points:[MeshPoint3]=[];points.reserveCapacity(n)
      for i in 0..<n {let v=MeshPoint3(raw[i*3]*unit.millimeters,raw[i*3+1]*unit.millimeters,raw[i*3+2]*unit.millimeters);guard [v.x,v.y,v.z].allSatisfy({abs($0)<=limit.coordinateMM}) else{throw MeshAssetError.limit("Mesh coordinates exceed the millimeter domain.")};points.append(v)}
      var indices:[UInt32]
      if let source=p.indices {
        let a=try at(root.accessors,source,"Index accessor");guard a.normalized != true else{throw MeshAssetError.invalid("Triangle indices cannot be normalized.")}
        let values=try accessor(source,type:"SCALAR",components:[5121,5123,5125],maximum:limit.triangles*3,vertex:false)
        guard values.allSatisfy({$0<Double(n)}) else{throw MeshAssetError.invalid("A triangle references a vertex outside its POSITION accessor.")};indices=values.map{UInt32($0)}
      }else{indices=(0..<n).map(UInt32.init)}
      switch p.mode ?? 4 {
      case 4:guard indices.count%3==0 else{throw MeshAssetError.invalid("Triangle index count must be divisible by three.")}
      case 5:
        guard indices.count>=3 else{throw MeshAssetError.invalid("Triangle strip needs at least three indices.")};guard indices.count-2<=limit.triangles-triangles else{throw MeshAssetError.limit("Triangle strip/fan exceeds the remaining triangle budget.")};let source=indices;indices=[];indices.reserveCapacity((source.count-2)*3)
        for i in 2..<source.count {indices += i%2==0 ? [source[i-2],source[i-1],source[i]]:[source[i-1],source[i-2],source[i]]}
      case 6:
        guard indices.count>=3 else{throw MeshAssetError.invalid("Triangle fan needs at least three indices.")};guard indices.count-2<=limit.triangles-triangles else{throw MeshAssetError.limit("Triangle strip/fan exceeds the remaining triangle budget.")};let source=indices;indices=[];indices.reserveCapacity((source.count-2)*3)
        for i in 2..<source.count {indices += [source[0],source[i-1],source[i]]}
      default:throw MeshAssetError.unsupported("Point and line primitives are not surface meshes.")
      }
      guard !indices.isEmpty,indices.count/3<=limit.triangles-triangles else{throw MeshAssetError.limit("Aggregate triangles exceed \(limit.triangles).")};triangles+=indices.count/3
      var normals:[MeshVector3]=[],tangents:[MeshTangent]=[],colors:[MeshVertexColor]=[]
      let generated=p.attributes["NORMAL"]==nil
      if let id=p.attributes["NORMAL"] {
        let raw=try accessor(id,type:"VEC3",components:[5126],maximum:n);guard raw.count==n*3 else{throw MeshAssetError.invalid("NORMAL and POSITION counts differ.")}
        for i in 0..<n {let x=raw[i*3],y=raw[i*3+1],z=raw[i*3+2],length=sqrt(x*x+y*y+z*z);guard length>1e-20 else{throw MeshAssetError.invalid("A vertex normal is zero.")};normals.append(.init(Float(x/length),Float(y/length),Float(z/length)))}
      }else {warnings.append("Missing vertex normals were generated with flat triangle shading, as required by glTF; export authored normals to retain smooth boundaries.")}
      if let id=p.attributes["TANGENT"] {
        let raw=try accessor(id,type:"VEC4",components:[5126],maximum:n);guard raw.count==n*4 else{throw MeshAssetError.invalid("TANGENT and POSITION counts differ.")}
        for i in 0..<n {guard abs(abs(raw[i*4+3])-1)<1e-4 else{throw MeshAssetError.invalid("Tangent handedness must be +1 or -1.")};tangents.append(.init(Float(raw[i*4]),Float(raw[i*4+1]),Float(raw[i*4+2]),Float(raw[i*4+3])))}
      }
      if let id=p.attributes["COLOR_0"] {
        let a=try at(root.accessors,id,"Color accessor");let dim=a.type=="VEC3" ? 3:4
        guard a.componentType==5126 || a.normalized==true else{throw MeshAssetError.invalid("Integer vertex colors must be normalized.")}
        let raw=try accessor(id,type:dim==3 ? "VEC3":"VEC4",components:[5126,5121,5123],maximum:n)
        guard raw.count==n*dim,raw.allSatisfy({(0...1).contains($0)}) else{throw MeshAssetError.invalid("Vertex colors need matching counts and unit-range values.")}
        for i in 0..<n {colors.append(.init(Float(raw[i*dim]),Float(raw[i*dim+1]),Float(raw[i*dim+2]),dim==4 ? Float(raw[i*dim+3]):1))}
      }
      func uv(_ name:String)throws->[MeshUV] {
        guard let id=p.attributes[name] else{return []};let a=try at(root.accessors,id,"UV accessor");guard a.componentType==5126 || a.normalized==true else{throw MeshAssetError.invalid("Integer UVs must be normalized.")}
        let raw=try accessor(id,type:"VEC2",components:[5126,5121,5123],maximum:n);guard raw.count==n*2 else{throw MeshAssetError.invalid("UV and POSITION counts differ.")}
        guard raw.allSatisfy({abs($0)<=1e6}) else{throw MeshAssetError.limit("UV coordinates exceed the supported domain.")}
        return stride(from:0,to:raw.count,by:2).map{.init(Float(raw[$0]),Float(raw[$0+1]))}
      }
      if let material=p.material {guard material>=0,material<materialCount else{throw MeshAssetError.invalid("Primitive material index is out of range.")}}
      for key in p.attributes.keys where !["POSITION","NORMAL","TANGENT","TEXCOORD_0","TEXCOORD_1","COLOR_0"].contains(key) {warnings.append("Attribute \(key) remains in source but is not evaluated.")}
      var output=MeshAssetPrimitive(id:"mesh-\(mesh)-primitive-\(index)",positionsMM:points,normals:normals,tangents:tangents,colors:colors,uv0:try uv("TEXCOORD_0"),uv1:try uv("TEXCOORD_1"),indices:indices,materialIndex:p.material ?? defaultMaterialIndex,generatedNormals:generated)
      if generated {
        guard indices.count<=limit.vertices-(vertices-n) else{throw MeshAssetError.limit("Flat normal generation exceeds the vertex budget; export authored vertex normals for a compact smooth mesh.")}
        vertices+=indices.count-n
        output.positionsMM=indices.map{points[Int($0)]}
        output.uv0=output.uv0.isEmpty ? []:indices.map{output.uv0[Int($0)]}
        output.uv1=output.uv1.isEmpty ? []:indices.map{output.uv1[Int($0)]}
        output.colors=colors.isEmpty ? []:indices.map{colors[Int($0)]}
        output.tangents=[]
        output.indices=(0..<indices.count).map(UInt32.init)
        output.normals=MeshAssetGeometry.vertexNormals(points:output.positionsMM,indices:output.indices)
      }
      return output
    }
    mutating func readImages()throws->[MeshAssetImage] {
      var result:[MeshAssetImage]=[]
      for (index,image) in (root.images ?? []).enumerated() {
        if Task.isCancelled {throw CancellationError()}
        guard (image.uri != nil) != (image.bufferView != nil) else{throw MeshAssetError.invalid("Images need exactly one URI or buffer view.")}
        let data:Data
        if let uri=image.uri {data=try resource(uri,kind:"image")}else{data=try bytes(at(root.bufferViews,image.bufferView!,"Image buffer view"))}
        guard data.count<=limit.textureBytes,let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetCount(source)==1,
          let type=CGImageSourceGetType(source) as String?,["public.png","public.jpeg"].contains(type),
          let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=props[kCGImagePropertyPixelWidth] as? Int,let height=props[kCGImagePropertyPixelHeight] as? Int,
          width>0,height>0,width<=limit.textureEdge,height<=limit.textureEdge,height<=limit.texturePixels/width else{throw MeshAssetError.limit("Textures must be single-frame PNG/JPEG within byte, edge and pixel budgets.")}
        let mime=type=="public.png" ? "image/png":"image/jpeg"
        if image.bufferView != nil {guard image.mimeType != nil else{throw MeshAssetError.invalid("Embedded buffer-view images require a MIME type.")}}
        if let uri=image.uri,uri.hasPrefix("data:"),!uri.hasPrefix("data:"+mime+";base64,") {throw MeshAssetError.invalid("Embedded image URI MIME type disagrees with its bytes.")}
        guard image.mimeType==nil || image.mimeType==mime else{throw MeshAssetError.invalid("Image MIME type disagrees with its bytes.")}
        guard width*height<=limit.totalTexturePixels-totalTexturePixels else{throw MeshAssetError.limit("Aggregate decoded texture pixels exceed the configured budget.")};totalTexturePixels+=width*height
        result.append(.init(id:"image-\(index)",name:image.name ?? "Image \(index+1)",mimeType:mime,sha256:MeshAssetHash.sha256(data),data:data,width:width,height:height))
      };return result
    }
    func readTextures(imageCount:Int)throws->[MeshAssetTexture] {
      try (root.textures ?? []).enumerated().map { index,t in
        guard let image=t.source,image>=0,image<imageCount else{throw MeshAssetError.invalid("Texture requires a valid image source.")}
        let sampler=try t.sampler.map{try at(root.samplers,$0,"Sampler")},s=sampler?.wrapS ?? 10497,tWrap=sampler?.wrapT ?? 10497
        guard [33071,33648,10497].contains(s),[33071,33648,10497].contains(tWrap),sampler?.magFilter==nil || [9728,9729].contains(sampler!.magFilter!),sampler?.minFilter==nil || [9728,9729,9984,9985,9986,9987].contains(sampler!.minFilter!) else{throw MeshAssetError.invalid("Texture sampler enum is invalid.")}
        return .init(id:"texture-\(index)",imageIndex:image,wrapS:s,wrapT:tWrap,minFilter:sampler?.minFilter,magFilter:sampler?.magFilter)
      }
    }
    func vector(_ values:[Double]?,count:Int,default fallback:[Double],unitRange:Bool=false)throws->[Double] {
      let values=values ?? fallback;guard values.count==count,values.allSatisfy({$0.isFinite && (!unitRange || (0...1).contains($0))}) else{throw MeshAssetError.invalid("A material/transform vector has invalid dimensions or values.")};return values
    }
    mutating func readMaterials(textureCount:Int)throws->[MeshAssetMaterial] {
      func binding(_ raw:Binding?)throws->MeshTextureBinding? {
        guard let raw else{return nil};let tr=raw.extensions?.KHR_texture_transform,uv=tr?.texCoord ?? raw.texCoord ?? 0
        guard raw.index>=0,raw.index<textureCount,[0,1].contains(uv) else{throw MeshAssetError.invalid("Texture binding needs an existing texture and UV0 or UV1.")}
        let offset=try vector(tr?.offset,count:2,default:[0,0]),scale=try vector(tr?.scale,count:2,default:[1,1]),rotation=tr?.rotation ?? 0,strength=raw.scale ?? raw.strength ?? 1
        guard rotation.isFinite,strength.isFinite,strength>=0,abs(rotation)<=1e6,offset.allSatisfy({abs($0)<=1e6}),scale.allSatisfy({abs($0)<=1e6}) else{throw MeshAssetError.invalid("Texture transform/strength is outside its supported domain.")}
        return .init(textureIndex:raw.index,texCoord:uv,offset:.init(Float(offset[0]),Float(offset[1])),scale:.init(Float(scale[0]),Float(scale[1])),rotation:rotation,strength:strength)
      }
      var result:[MeshAssetMaterial]=[]
      for (index,m) in (root.materials ?? []).enumerated() {
        let p=m.pbrMetallicRoughness,base=try vector(p?.baseColorFactor,count:4,default:[1,1,1,1],unitRange:true),emissive=try vector(m.emissiveFactor,count:3,default:[0,0,0],unitRange:true),metal=p?.metallicFactor ?? 1,rough=p?.roughnessFactor ?? 1,alpha=m.alphaMode ?? "OPAQUE",cutoff=m.alphaCutoff ?? 0.5
        guard [metal,rough,cutoff].allSatisfy({$0.isFinite && (0...1).contains($0)}),["OPAQUE","MASK","BLEND"].contains(alpha) else{throw MeshAssetError.invalid("Material PBR or alpha factors are invalid.")}
        let normal=try binding(m.normalTexture)
        if let normal,normal.strength != 1 {warnings.append("Material \(m.name ?? String(index)) retains normal scale \(normal.strength); a renderer must apply it or report its shading limitation.")}
        result.append(.init(id:"material-\(index)",name:m.name ?? "Material \(index+1)",baseColor:base,metallic:metal,roughness:rough,emissive:emissive,doubleSided:m.doubleSided ?? false,unlit:m.extensions?.KHR_materials_unlit != nil,alphaMode:alpha,alphaCutoff:cutoff,baseColorTexture:try binding(p?.baseColorTexture),normalTexture:normal,metallicRoughnessTexture:try binding(p?.metallicRoughnessTexture),emissiveTexture:try binding(m.emissiveTexture),occlusionTexture:try binding(m.occlusionTexture)))
      };return result
    }
    func transform(_ node:Node)throws->MeshAssetTransform {
      if let matrix=node.matrix {
        guard node.translation==nil,node.rotation==nil,node.scale==nil,matrix.count==16,matrix.allSatisfy(\.isFinite),abs(matrix[3])<1e-12,abs(matrix[7])<1e-12,abs(matrix[11])<1e-12,abs(matrix[15]-1)<1e-12 else{throw MeshAssetError.invalid("Node matrix must be affine and cannot be mixed with TRS.")}
        var m=matrix;for i in [12,13,14] {m[i]*=unit.millimeters};return .init(matrix:m)
      }
      let t=try vector(node.translation,count:3,default:[0,0,0]),s=try vector(node.scale,count:3,default:[1,1,1]),q=try vector(node.rotation,count:4,default:[0,0,0,1]),length=sqrt(q.reduce(0){$0+$1*$1})
      guard abs(length-1)<1e-3 else{throw MeshAssetError.invalid("Node rotation must be a unit quaternion.")}
      let x=q[0]/length,y=q[1]/length,z=q[2]/length,w=q[3]/length
      return .init(matrix:[(1-2*y*y-2*z*z)*s[0],(2*x*y+2*z*w)*s[0],(2*x*z-2*y*w)*s[0],0, (2*x*y-2*z*w)*s[1],(1-2*x*x-2*z*z)*s[1],(2*y*z+2*x*w)*s[1],0, (2*x*z+2*y*w)*s[2],(2*y*z-2*x*w)*s[2],(1-2*x*x-2*y*y)*s[2],0,t[0]*unit.millimeters,t[1]*unit.millimeters,t[2]*unit.millimeters,1])
    }
    func readNodes(meshes:[MeshAssetMesh])throws->(nodes:[MeshAssetNode],roots:[Int]) {
      let raw=root.nodes ?? [];guard !raw.isEmpty else{throw MeshAssetError.invalid("The asset has no scene nodes.")}
      var parents=[Int?](repeating:nil,count:raw.count),local:[MeshAssetTransform]=[]
      for (i,node) in raw.enumerated() {
        if let mesh=node.mesh {guard mesh>=0,mesh<meshes.count else{throw MeshAssetError.invalid("Node mesh index is out of range.")}}
        guard node.skin==nil,node.weights==nil || node.weights!.isEmpty else{throw MeshAssetError.unsupported("Node skins/morph weights require a static applied export.")}
        let children=node.children ?? [];guard Set(children).count==children.count else{throw MeshAssetError.invalid("Node children contain duplicate IDs.")}
        for child in children {guard child>=0,child<raw.count,child != i,parents[child]==nil else{throw MeshAssetError.invalid("Node hierarchy contains an invalid child or multiple parents.")};parents[child]=i}
        local.append(try transform(node))
      }
      var depths=[Int](repeating:0,count:raw.count),colors=[UInt8](repeating:0,count:raw.count),world=[MeshAssetTransform](repeating:.identity,count:raw.count)
      func visit(_ index:Int,_ depth:Int)throws {
        guard depth<=limit.hierarchyDepth else{throw MeshAssetError.limit("Node hierarchy exceeds \(limit.hierarchyDepth) levels.")}
        guard colors[index] != 1 else{throw MeshAssetError.invalid("Node hierarchy contains a cycle.")};if colors[index]==2{return};colors[index]=1
        if let parent=parents[index] {try visit(parent,depth+1);depths[index]=depths[parent]+1;world[index]=world[parent].followed(by:local[index])}else{world[index]=local[index]}
        guard depths[index]<=limit.hierarchyDepth else{throw MeshAssetError.limit("Node hierarchy exceeds its depth budget.")}
        guard world[index].matrix.allSatisfy(\.isFinite) else{throw MeshAssetError.invalid("Node transform overflows finite coordinates.")};colors[index]=2
      }
      for i in raw.indices {try visit(i,0)}
      let roots:[Int]
      if let scenes=root.scenes,!scenes.isEmpty {
        let selected=root.scene ?? 0;guard selected>=0,selected<scenes.count else{throw MeshAssetError.invalid("Default scene index is out of range.")}
        for scene in scenes {
          let ids=scene.nodes ?? [];guard Set(ids).count==ids.count,ids.allSatisfy({$0>=0 && $0<raw.count && parents[$0]==nil}) else{throw MeshAssetError.invalid("Scene roots must be unique parentless nodes.")}
        };roots=scenes[selected].nodes ?? []
      }else {guard root.scene==nil else{throw MeshAssetError.invalid("Default scene references an absent scene list.")};roots=raw.indices.filter{parents[$0]==nil}}
      var active=Set<Int>()
      func activate(_ i:Int) {guard active.insert(i).inserted else{return};for child in raw[i].children ?? [] {activate(child)}}
      for i in roots {activate(i)}
      return(raw.enumerated().map{i,n in .init(id:"node-\(i)",name:n.name ?? "Node \(i+1)",meshIndex:n.mesh,children:n.children ?? [],localTransform:local[i],worldTransform:world[i],inSelectedScene:active.contains(i))},roots)
    }
    func validateTextureCoordinates(meshes:[MeshAssetMesh],materials:[MeshAssetMaterial])throws {
      for mesh in meshes {for p in mesh.primitives {guard let i=p.materialIndex else{continue};let m=materials[i]
        for binding in [m.baseColorTexture,m.normalTexture,m.metallicRoughnessTexture,m.emissiveTexture,m.occlusionTexture].compactMap({$0}) {
          guard binding.texCoord==0 ? !p.uv0.isEmpty:!p.uv1.isEmpty else{throw MeshAssetError.invalid("A material texture references missing UV coordinates on \(p.id).")}
        }
      }}
    }
  }
}

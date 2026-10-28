import Foundation
import CryptoKit

public enum MeshAssetError: Error, LocalizedError, Equatable, Sendable {
  case invalid(String), unsupported(String), limit(String), unitRequired(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let text): return "Invalid 3D asset: " + text
    case .unsupported(let text): return "Unsupported 3D asset feature: " + text
    case .limit(let text): return "3D asset limit: " + text
    case .unitRequired(let text): return "Choose source units: " + text
    }
  }
}

public struct MeshImportLimits: Sendable {
  public var sourceBytes = 256 * 1024 * 1024
  public var jsonBytes = 16 * 1024 * 1024
  public var resourceBytes = 256 * 1024 * 1024
  public var totalResourceBytes = 512 * 1024 * 1024
  public var nodes = 4096
  public var hierarchyDepth = 128
  public var meshes = 2048
  public var primitives = 8192
  public var vertices = 2_000_000
  public var triangles = 2_000_000
  public var instanceVertices = 8_000_000
  public var instanceTriangles = 8_000_000
  public var materials = 2048
  public var images = 256
  public var textureBytes = 32 * 1024 * 1024
  public var textureEdge = 8192
  public var texturePixels = 16_777_216
  public var totalTexturePixels = 67_108_864
  public var coordinateMM = 1_000_000_000.0
  public init() {}
}

public enum MeshSourceUnit: String, Codable, CaseIterable, Sendable {
  case millimeter, centimeter, meter, inch
  public var millimeters: Double {
    switch self { case .millimeter: return 1; case .centimeter: return 10; case .meter: return 1000; case .inch: return 25.4 }
  }
}
public struct MeshImportOptions: Sendable {
  /// glTF declares meters. Unitless OBJ/STL require this choice. Overrides remain in provenance.
  public var sourceUnit: MeshSourceUnit?
  public var limits: MeshImportLimits
  public init(sourceUnit: MeshSourceUnit? = nil, limits: MeshImportLimits = .init()) {
    self.sourceUnit = sourceUnit; self.limits = limits
  }
}

public struct MeshPoint3: Codable, Equatable, Sendable {
  public var x: Double, y: Double, z: Double
  public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) { self.x=x; self.y=y; self.z=z }
  public var simd: SIMD3<Double> { .init(x,y,z) }
}
public struct MeshVector3: Codable, Equatable, Sendable {
  public var x: Float, y: Float, z: Float
  public init(_ x: Float = 0, _ y: Float = 0, _ z: Float = 0) { self.x=x; self.y=y; self.z=z }
  public var simd: SIMD3<Float> { .init(x,y,z) }
}
public struct MeshUV: Codable, Equatable, Sendable {
  public var u: Float, v: Float
  public init(_ u: Float = 0, _ v: Float = 0) { self.u=u; self.v=v }
  public var simd: SIMD2<Float> { .init(u,v) }
}
public struct MeshVertexColor: Codable, Equatable, Sendable {
  public var r:Float, g:Float, b:Float, a:Float
  public init(_ r:Float,_ g:Float,_ b:Float,_ a:Float=1) {self.r=r;self.g=g;self.b=b;self.a=a}
}
public struct MeshTangent: Codable, Equatable, Sendable {
  public var x: Float, y: Float, z: Float, w: Float
  public init(_ x: Float, _ y: Float, _ z: Float, _ w: Float) { self.x=x; self.y=y; self.z=z; self.w=w }
}

/// Column-major affine matrix. Translation and positions use millimeters; its linear part is dimensionless.
public struct MeshAssetTransform: Codable, Equatable, Sendable {
  public var matrix: [Double]
  public init(matrix: [Double]) { self.matrix=matrix }
  public static let identity = Self(matrix:[1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1])
  public func followed(by child: Self) -> Self {
    precondition(matrix.count == 16 && child.matrix.count == 16)
    var result=[Double](repeating:0,count:16)
    for col in 0..<4 { for row in 0..<4 { for k in 0..<4 { result[col*4+row] += matrix[k*4+row]*child.matrix[col*4+k] } } }
    return .init(matrix:result)
  }
  public func point(_ p: MeshPoint3) -> MeshPoint3 {
    .init(matrix[0]*p.x+matrix[4]*p.y+matrix[8]*p.z+matrix[12], matrix[1]*p.x+matrix[5]*p.y+matrix[9]*p.z+matrix[13], matrix[2]*p.x+matrix[6]*p.y+matrix[10]*p.z+matrix[14])
  }
  public var determinant: Double {
    matrix[0]*(matrix[5]*matrix[10]-matrix[9]*matrix[6])-matrix[4]*(matrix[1]*matrix[10]-matrix[9]*matrix[2])+matrix[8]*(matrix[1]*matrix[6]-matrix[5]*matrix[2])
  }
  public func normal(_ n: MeshVector3) -> MeshVector3 {
    let a=matrix[0],b=matrix[4],c=matrix[8],d=matrix[1],e=matrix[5],f=matrix[9],g=matrix[2],h=matrix[6],i=matrix[10],det=determinant
    guard abs(det)>1e-20 else { return .init() }
    let x=((e*i-f*h)*Double(n.x)+(f*g-d*i)*Double(n.y)+(d*h-e*g)*Double(n.z))/det
    let y=((c*h-b*i)*Double(n.x)+(a*i-c*g)*Double(n.y)+(b*g-a*h)*Double(n.z))/det
    let z=((b*f-c*e)*Double(n.x)+(c*d-a*f)*Double(n.y)+(a*e-b*d)*Double(n.z))/det
    let length=sqrt(x*x+y*y+z*z);guard length>1e-20 else{return .init()}
    return .init(Float(x/length),Float(y/length),Float(z/length))
  }
}

public struct MeshAssetBounds: Codable, Equatable, Sendable {
  public var minimum: MeshPoint3, maximum: MeshPoint3
  public var size: MeshPoint3 { .init(maximum.x-minimum.x,maximum.y-minimum.y,maximum.z-minimum.z) }
  public init(minimum: MeshPoint3, maximum: MeshPoint3) {self.minimum=minimum;self.maximum=maximum}
}
public struct MeshAssetPrimitive: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var positionsMM: [MeshPoint3]
  public var normals: [MeshVector3]
  public var tangents: [MeshTangent]
  public var colors: [MeshVertexColor]
  public var uv0: [MeshUV]
  public var uv1: [MeshUV]
  public var indices: [UInt32]
  public var materialIndex: Int?
  public var generatedNormals: Bool
  public init(id:String, positionsMM:[MeshPoint3], normals:[MeshVector3], tangents:[MeshTangent]=[], colors:[MeshVertexColor]=[], uv0:[MeshUV]=[], uv1:[MeshUV]=[], indices:[UInt32], materialIndex:Int?=nil, generatedNormals:Bool=false) {
    self.id=id;self.positionsMM=positionsMM;self.normals=normals;self.tangents=tangents;self.colors=colors;self.uv0=uv0;self.uv1=uv1;self.indices=indices;self.materialIndex=materialIndex;self.generatedNormals=generatedNormals
  }
}
public struct MeshAssetMesh: Codable, Equatable, Sendable, Identifiable {
  public var id: String, name: String
  public var primitives: [MeshAssetPrimitive]
  public init(id:String,name:String,primitives:[MeshAssetPrimitive]) {self.id=id;self.name=name;self.primitives=primitives}
}
public struct MeshAssetNode: Codable, Equatable, Sendable, Identifiable {
  public var id: String, name: String
  public var meshIndex: Int?
  public var children: [Int]
  public var localTransform: MeshAssetTransform
  public var worldTransform: MeshAssetTransform
  public var inSelectedScene: Bool
  public init(id:String,name:String,meshIndex:Int?,children:[Int],localTransform:MeshAssetTransform,worldTransform:MeshAssetTransform,inSelectedScene:Bool) {
    self.id=id;self.name=name;self.meshIndex=meshIndex;self.children=children;self.localTransform=localTransform;self.worldTransform=worldTransform;self.inSelectedScene=inSelectedScene
  }
}
public struct MeshTextureBinding: Codable, Equatable, Sendable {
  public var textureIndex: Int
  public var texCoord: Int
  public var offset: MeshUV
  public var scale: MeshUV
  public var rotation: Double
  public var strength: Double
  public init(textureIndex:Int,texCoord:Int=0,offset:MeshUV = .init(),scale:MeshUV = .init(1,1),rotation:Double=0,strength:Double=1) {
    self.textureIndex=textureIndex;self.texCoord=texCoord;self.offset=offset;self.scale=scale;self.rotation=rotation;self.strength=strength
  }
  public func transformed(_ uv:MeshUV)->MeshUV {
    let x=Double(uv.u*scale.u),y=Double(uv.v*scale.v),c=cos(rotation),s=sin(rotation)
    return .init(Float(x*c-y*s)+offset.u,Float(x*s+y*c)+offset.v)
  }
}
public struct MeshAssetMaterial: Codable, Equatable, Sendable, Identifiable {
  public var id:String, name:String
  public var baseColor:[Double]
  public var metallic:Double, roughness:Double
  public var emissive:[Double]
  public var doubleSided:Bool, unlit:Bool
  public var alphaMode:String
  public var alphaCutoff:Double
  public var baseColorTexture:MeshTextureBinding?
  public var normalTexture:MeshTextureBinding?
  public var metallicRoughnessTexture:MeshTextureBinding?
  public var emissiveTexture:MeshTextureBinding?
  public var occlusionTexture:MeshTextureBinding?
  public init(id:String,name:String,baseColor:[Double]=[1,1,1,1],metallic:Double=1,roughness:Double=1,emissive:[Double]=[0,0,0],doubleSided:Bool=false,unlit:Bool=false,alphaMode:String="OPAQUE",alphaCutoff:Double=0.5,baseColorTexture:MeshTextureBinding?=nil,normalTexture:MeshTextureBinding?=nil,metallicRoughnessTexture:MeshTextureBinding?=nil,emissiveTexture:MeshTextureBinding?=nil,occlusionTexture:MeshTextureBinding?=nil) {
    self.id=id;self.name=name;self.baseColor=baseColor;self.metallic=metallic;self.roughness=roughness;self.emissive=emissive;self.doubleSided=doubleSided;self.unlit=unlit;self.alphaMode=alphaMode;self.alphaCutoff=alphaCutoff;self.baseColorTexture=baseColorTexture;self.normalTexture=normalTexture;self.metallicRoughnessTexture=metallicRoughnessTexture;self.emissiveTexture=emissiveTexture;self.occlusionTexture=occlusionTexture
  }
}
public struct MeshAssetImage: Codable, Equatable, Sendable, Identifiable {
  public var id:String, name:String, mimeType:String, sha256:String
  public var data:Data
  public var width:Int, height:Int
  public init(id:String,name:String,mimeType:String,sha256:String,data:Data,width:Int,height:Int) {self.id=id;self.name=name;self.mimeType=mimeType;self.sha256=sha256;self.data=data;self.width=width;self.height=height}
}
public struct MeshAssetTexture: Codable, Equatable, Sendable, Identifiable {
  public var id:String
  public var imageIndex:Int
  public var wrapS:Int, wrapT:Int
  public var minFilter:Int?, magFilter:Int?
  public init(id:String,imageIndex:Int,wrapS:Int=10497,wrapT:Int=10497,minFilter:Int?=nil,magFilter:Int?=nil) {self.id=id;self.imageIndex=imageIndex;self.wrapS=wrapS;self.wrapT=wrapT;self.minFilter=minFilter;self.magFilter=magFilter}
}
public struct MeshAssetResource: Codable, Equatable, Sendable {
  public var relativePath:String
  public var data:Data
  public var sha256:String
  public init(relativePath:String,data:Data) {self.relativePath=relativePath;self.data=data;self.sha256=MeshAssetHash.sha256(data)}
}
public struct MeshAssetProvenance: Codable, Equatable, Sendable {
  public var format:String, fileName:String, sourceSHA256:String
  public var sourceByteCount:Int
  public var unit:MeshSourceUnit
  public var unitDeclaration:String
  public var coordinateConvention:String
  public var normalizationVersion:Int
  public var warnings:[String]
  public init(format:String,fileName:String,sourceSHA256:String,sourceByteCount:Int,unit:MeshSourceUnit,unitDeclaration:String,warnings:[String]=[]) {self.format=format;self.fileName=fileName;self.sourceSHA256=sourceSHA256;self.sourceByteCount=sourceByteCount;self.unit=unit;self.unitDeclaration=unitDeclaration;self.coordinateConvention="Right-handed, +Y up; document geometry in millimeters";self.normalizationVersion=1;self.warnings=warnings}
}
public struct MeshAssetDocument: Codable, Equatable, Sendable {
  public var provenance:MeshAssetProvenance
  public var sourceData:Data
  public var externalResources:[MeshAssetResource]
  public var meshes:[MeshAssetMesh]
  public var nodes:[MeshAssetNode]
  public var sceneRoots:[Int]
  public var materials:[MeshAssetMaterial]
  public var images:[MeshAssetImage]
  public var textures:[MeshAssetTexture]
  public var boundsMM:MeshAssetBounds
  public var vertexCount:Int {meshes.reduce(0){$0+$1.primitives.reduce(0){$0+$1.positionsMM.count}}}
  public var triangleCount:Int {meshes.reduce(0){$0+$1.primitives.reduce(0){$0+$1.indices.count/3}}}
  public var instanceTriangleCount:Int {nodes.filter(\.inSelectedScene).reduce(0){sum,node in sum+(node.meshIndex.map{meshes[$0].primitives.reduce(0){$0+$1.indices.count/3}} ?? 0)}}
  public init(provenance:MeshAssetProvenance,sourceData:Data,externalResources:[MeshAssetResource]=[],meshes:[MeshAssetMesh],nodes:[MeshAssetNode],sceneRoots:[Int],materials:[MeshAssetMaterial],images:[MeshAssetImage]=[],textures:[MeshAssetTexture]=[],boundsMM:MeshAssetBounds) {self.provenance=provenance;self.sourceData=sourceData;self.externalResources=externalResources;self.meshes=meshes;self.nodes=nodes;self.sceneRoots=sceneRoots;self.materials=materials;self.images=images;self.textures=textures;self.boundsMM=boundsMM}
}
public enum MeshAssetHash {
  public static func sha256(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
}

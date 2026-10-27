import AppKit
import CoreGraphics
import Foundation
import simd

/// All model-space positions remain Double millimeters. Rendering adapters alone
/// convert them to their GPU units. These payloads contain no renderer entities.
public struct SceneMeshPart: Sendable {
  public var materialIndex: Int
  public var triangleIndices: [UInt32]
  public var semanticID: String?
  public init(materialIndex: Int = 0, triangleIndices: [UInt32], semanticID: String? = nil) {
    self.materialIndex = materialIndex; self.triangleIndices = triangleIndices; self.semanticID = semanticID
  }
}
public struct SceneMeshPayload: Sendable {
  public var id: String
  /// Immutable content revision: replace whenever any buffer or part changes.
  public var revision: String
  public var positionsMM: [SIMD3<Double>]
  public var normals: [SIMD3<Float>]
  /// Image UV origin is top-left, shared by glTF and existing LAB artwork.
  public var uvs: [SIMD2<Float>]
  public var uvs1: [SIMD2<Float>]
  public var tangents: [SIMD4<Float>]
  public var colors: [SIMD4<Float>]
  public var parts: [SceneMeshPart]
  public init(id: String, revision: String, positionsMM: [SIMD3<Double>], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], uvs1: [SIMD2<Float>] = [], tangents: [SIMD4<Float>] = [], colors: [SIMD4<Float>] = [], parts: [SceneMeshPart]) {
    self.id=id; self.revision=revision; self.positionsMM=positionsMM; self.normals=normals; self.uvs=uvs; self.uvs1=uvs1; self.tangents=tangents; self.colors=colors; self.parts=parts
  }
  public var triangleCount: Int { parts.reduce(0) { $0 + $1.triangleIndices.count / 3 } }
  public var approximateBytes: Int { positionsMM.count*24 + normals.count*12 + (uvs.count+uvs1.count)*8 + (tangents.count+colors.count)*16 + triangleCount*12 }
  public func validate(materialCount: Int) throws {
    guard !id.isEmpty, !revision.isEmpty, !positionsMM.isEmpty, positionsMM.count <= 2_000_000, triangleCount <= 2_000_000, !parts.isEmpty, materialCount > 0 else { throw SceneRendererError.invalidMesh("A mesh needs an identity, revision, vertices, parts and materials; the limit is two million vertices/triangles.") }
    guard positionsMM.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && simd_reduce_max(simd_abs($0)) <= 1e12}) else { throw SceneRendererError.invalidMesh("Mesh coordinates must be finite millimeters within the supported numeric domain.") }
    guard normals.isEmpty || normals.count==positionsMM.count, uvs.isEmpty || uvs.count==positionsMM.count, uvs1.isEmpty || uvs1.count==positionsMM.count, tangents.isEmpty || tangents.count==positionsMM.count, colors.isEmpty || colors.count==positionsMM.count else { throw SceneRendererError.invalidMesh("Vertex attributes must match the position count.") }
    guard normals.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && simd_length_squared($0)>1e-20}), uvs.allSatisfy({$0.x.isFinite && $0.y.isFinite}), uvs1.allSatisfy({$0.x.isFinite && $0.y.isFinite}), tangents.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite}), colors.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite}) else { throw SceneRendererError.invalidMesh("Vertex attributes must be finite; supplied normals cannot be zero.") }
    for part in parts {
      guard part.materialIndex >= 0, part.materialIndex < materialCount, part.triangleIndices.count % 3 == 0, part.triangleIndices.allSatisfy({$0 < positionsMM.count}) else { throw SceneRendererError.invalidMesh("A mesh part has an invalid material or triangle index.") }
    }
  }
}
public enum SceneTextureWrap: String, Sendable { case repeatMode, clamp, mirror }
public enum SceneTextureChannel: String, Sendable { case rgba, red, green, blue, alpha }
/// CGImage pixels are immutable. Decoding/import budgets belong to the asset
/// service; the renderer additionally enforces a 16 MP / 8192 edge upload cap.
public struct SceneTexturePayload: @unchecked Sendable {
  public var image: CGImage
  public var revision: String
  public var uvIndex: Int
  public var wrapS: SceneTextureWrap
  public var wrapT: SceneTextureWrap
  public var channel: SceneTextureChannel
  public init(image: CGImage, revision: String, uvIndex: Int = 0, wrapS: SceneTextureWrap = .repeatMode, wrapT: SceneTextureWrap = .repeatMode, channel: SceneTextureChannel = .rgba) {
    self.image=image; self.revision=revision; self.uvIndex=uvIndex; self.wrapS=wrapS; self.wrapT=wrapT; self.channel=channel
  }
}
public enum SceneColorEncoding: String, Sendable { case srgb, linearSRGB }
public enum SceneAlphaMode: String, Sendable { case opaque, mask, blend }
public struct SceneMaterialPayload: Sendable {
  public var id: String
  public var revision: String
  public var baseColor: SIMD4<Float>
  public var colorEncoding: SceneColorEncoding
  public var emissiveColor: SIMD3<Float>
  public var emissiveIntensity: Float
  public var emissiveTexture: SceneTexturePayload?
  public var metallic: Float
  public var roughness: Float
  public var doubleSided: Bool
  public var readsDepth: Bool
  public var writesDepth: Bool
  public var unlit: Bool
  public var alphaMode: SceneAlphaMode
  public var alphaCutoff: Float
  public var normalScale: Float
  public var baseColorTexture: SceneTexturePayload?
  public var normalTexture: SceneTexturePayload?
  public var metallicTexture: SceneTexturePayload?
  public var roughnessTexture: SceneTexturePayload?
  public var ambientOcclusionTexture: SceneTexturePayload?
  public init(id: String, revision: String = "1", baseColor: SIMD4<Float> = .init(1,1,1,1), colorEncoding: SceneColorEncoding = .srgb, emissiveColor: SIMD3<Float> = .zero, emissiveIntensity: Float = 1, emissiveTexture: SceneTexturePayload? = nil, metallic: Float = 0, roughness: Float = 0.6, doubleSided: Bool = false, readsDepth: Bool = true, writesDepth: Bool = true, unlit: Bool = false, alphaMode: SceneAlphaMode = .opaque, alphaCutoff: Float = 0.5, normalScale: Float = 1, baseColorTexture: SceneTexturePayload? = nil, normalTexture: SceneTexturePayload? = nil, metallicTexture: SceneTexturePayload? = nil, roughnessTexture: SceneTexturePayload? = nil, ambientOcclusionTexture: SceneTexturePayload? = nil) {
    self.id=id; self.revision=revision; self.baseColor=baseColor; self.colorEncoding=colorEncoding; self.emissiveColor=emissiveColor; self.emissiveIntensity=emissiveIntensity; self.emissiveTexture=emissiveTexture; self.metallic=metallic; self.roughness=roughness; self.doubleSided=doubleSided; self.readsDepth=readsDepth; self.writesDepth=writesDepth; self.unlit=unlit; self.alphaMode=alphaMode; self.alphaCutoff=alphaCutoff; self.normalScale=normalScale; self.baseColorTexture=baseColorTexture; self.normalTexture=normalTexture; self.metallicTexture=metallicTexture; self.roughnessTexture=roughnessTexture; self.ambientOcclusionTexture=ambientOcclusionTexture
  }
}
public struct SceneTransformPayload: Sendable, Equatable {
  public var translationMM: SIMD3<Double>
  public var rotationXYZW: SIMD4<Double>
  public var scale: SIMD3<Double>
  public init(translationMM: SIMD3<Double> = .zero, rotationXYZW: SIMD4<Double> = .init(0,0,0,1), scale: SIMD3<Double> = .init(repeating:1)) { self.translationMM=translationMM; self.rotationXYZW=rotationXYZW; self.scale=scale }
  public var matrixMM: simd_double4x4 {
    var m=simd_double4x4(simd_quatd(vector:simd_normalize(rotationXYZW))); m.columns.0 *= scale.x; m.columns.1 *= scale.y; m.columns.2 *= scale.z; m.columns.3 = SIMD4(translationMM,1); return m
  }
  public func validate() throws {
    guard translationMM.x.isFinite,translationMM.y.isFinite,translationMM.z.isFinite,rotationXYZW.x.isFinite,rotationXYZW.y.isFinite,rotationXYZW.z.isFinite,rotationXYZW.w.isFinite,simd_length_squared(rotationXYZW)>1e-20,scale.x.isFinite,scale.y.isFinite,scale.z.isFinite,abs(scale.x)>1e-12,abs(scale.y)>1e-12,abs(scale.z)>1e-12 else { throw SceneRendererError.invalidTransform }
  }
}
public struct SceneRenderablePayload: Sendable {
  public var componentID: String
  public var objectID: UUID
  public var mesh: SceneMeshPayload
  public var materials: [SceneMaterialPayload]
  public var transform: SceneTransformPayload
  public var visible: Bool
  public var pickable: Bool
  public init(componentID: String, objectID: UUID, mesh: SceneMeshPayload, materials: [SceneMaterialPayload], transform: SceneTransformPayload = .init(), visible: Bool = true, pickable: Bool = true) {self.componentID=componentID;self.objectID=objectID;self.mesh=mesh;self.materials=materials;self.transform=transform;self.visible=visible;self.pickable=pickable}
}
public enum SceneCameraProjection: Sendable, Equatable { case perspective(verticalFieldOfViewDegrees: Double), orthographic(verticalSpanMM: Double) }
public struct SceneCameraPayload: Sendable {
  /// Columns are camera right, up, outward and position. Camera looks along -Z.
  public var worldFromCameraMM: simd_double4x4
  public var projection: SceneCameraProjection
  public var nearMM: Double
  public var farMM: Double
  public init(worldFromCameraMM: simd_double4x4 = matrix_identity_double4x4, projection: SceneCameraProjection = .perspective(verticalFieldOfViewDegrees:39), nearMM: Double = 1, farMM: Double = 150_000) {self.worldFromCameraMM=worldFromCameraMM;self.projection=projection;self.nearMM=nearMM;self.farMM=farMM}
  public static func looking(from eye: SIMD3<Double>, at target: SIMD3<Double>, up: SIMD3<Double> = .init(0,1,0), projection: SceneCameraProjection = .perspective(verticalFieldOfViewDegrees:39)) -> Self {
    let z=simd_normalize(eye-target),x=simd_normalize(simd_cross(up,z)),y=simd_cross(z,x)
    return .init(worldFromCameraMM:.init(SIMD4(x,0),SIMD4(y,0),SIMD4(z,0),SIMD4(eye,1)),projection:projection)
  }
  public func validate() throws {
    let c=worldFromCameraMM.columns
    let vectors=[c.0,c.1,c.2,c.3]
    guard vectors.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite}),nearMM.isFinite,farMM.isFinite,nearMM>0,farMM>nearMM,abs(c.0.w)<1e-12,abs(c.1.w)<1e-12,abs(c.2.w)<1e-12,abs(c.3.w-1)<1e-12 else { throw SceneRendererError.invalidCamera }
    let x=SIMD3(c.0.x,c.0.y,c.0.z),y=SIMD3(c.1.x,c.1.y,c.1.z),z=SIMD3(c.2.x,c.2.y,c.2.z)
    guard abs(simd_length(x)-1)<1e-6,abs(simd_length(y)-1)<1e-6,abs(simd_length(z)-1)<1e-6,abs(simd_dot(x,y))<1e-6,abs(simd_dot(x,z))<1e-6,abs(simd_dot(y,z))<1e-6,simd_dot(simd_cross(x,y),z)>0.999999 else { throw SceneRendererError.invalidCamera }
    switch projection {
    case .perspective(let fov):guard fov.isFinite,fov>0.01,fov<179 else{throw SceneRendererError.invalidCamera}
    case .orthographic(let span):guard span.isFinite,span>0 else{throw SceneRendererError.invalidCamera}
    }
  }
}
public struct SceneLightingPayload: Sendable {
  public var background: SIMD4<Float>
  public var keyDirection: SIMD3<Float>
  public var keyColor: SIMD3<Float>
  public var keyIntensity: Float
  public var fillIntensity: Float
  public var shadows: Bool
  public var toneMappingEnabled: Bool
  public init(background: SIMD4<Float> = .init(242.0/255,242.0/255,242.0/255,1), keyDirection: SIMD3<Float> = .init(-0.5,-1,-0.6), keyColor: SIMD3<Float> = .init(1,1,1), keyIntensity: Float = 3000, fillIntensity: Float = 600, shadows: Bool = true, toneMappingEnabled: Bool = true) {self.toneMappingEnabled=toneMappingEnabled;self.background=background;self.keyDirection=keyDirection;self.keyColor=keyColor;self.keyIntensity=keyIntensity;self.fillIntensity=fillIntensity;self.shadows=shadows}
}
public struct SceneRay: Sendable { public var originMM: SIMD3<Double>;public var direction: SIMD3<Double>;public init(originMM:SIMD3<Double>,direction:SIMD3<Double>){self.originMM=originMM;self.direction=simd_normalize(direction)} }
public struct ScenePick: Sendable {public var objectID:UUID;public var componentID:String;public var partID:String?;public var triangle:Int;public var distanceMM:Double;public var pointMM:SIMD3<Double>}
public struct SceneRendererDiagnostics: Sendable {
  public internal(set) var meshBuilds=0,materialBuilds=0,textureUploads=0,transformUpdates=0,frames=0,offscreenCaptures=0
  public internal(set) var componentCount=0,meshCacheBytes=0,textureCacheBytes=0
  public internal(set) var lastFrameMilliseconds=0.0,lastCaptureMilliseconds=0.0
  public internal(set) var warnings:[String]=[]
  public init(){}
}
public enum SceneRendererError: LocalizedError {
  case invalidMesh(String), invalidTransform, invalidCamera, invalidTexture(String), unavailableMetal, invalidCapture, cancelled
  public var errorDescription:String? {
    switch self {case .invalidMesh(let s):return s;case .invalidTransform:return "Use finite non-singular physical transforms.";case .invalidCamera:return "Use a finite orthonormal camera and valid physical clip/projection limits.";case .invalidTexture(let s):return s;case .unavailableMetal:return "This renderer requires a supported Metal device.";case .invalidCapture:return "Choose positive output dimensions within the 32-megapixel capture budget.";case .cancelled:return "The render was superseded or cancelled."}
  }
}
@MainActor public protocol FormSceneRenderer: AnyObject {
  var nativeView: NSView {get}
  var diagnostics: SceneRendererDiagnostics {get}
  func upsert(_ payload: SceneRenderablePayload) throws
  func remove(componentID:String)
  func reset()
  func setTransform(_ transform:SceneTransformPayload,componentID:String)throws
  func setCamera(_ camera:SceneCameraPayload)throws
  func setLighting(_ lighting:SceneLightingPayload)throws
  func setSelection(_ objectIDs:Set<UUID>)
  func setVisibleObjects(_ objectIDs:Set<UUID>?)
  func pick(atTopLeft point:CGPoint,viewport:CGSize)->ScenePick?
  func ray(atTopLeft point:CGPoint,viewport:CGSize)->SceneRay?
  func capture(width:Int,height:Int,transparent:Bool,camera:SceneCameraPayload?)async throws->CGImage
}

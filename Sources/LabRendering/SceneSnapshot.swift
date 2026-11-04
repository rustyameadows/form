import Foundation
import simd

public enum ScenePhysicalTextureChannel: String, CaseIterable, Sendable {
  case baseColor, roughness, metallic, normal, emission, alpha, bump, displacement, anisotropy, sheen, sheenTint, coat, transmission, diffuseTransmission, subsurface
}

/// Generic physical surface channels; all lengths remain millimeters until the
/// renderer boundary. Texture colors and data carry separate encoding tags.
public struct ScenePhysicalAppearance: Sendable {
  public var ior: Double = 1.5
  public var transmission: Double = 0
  public var diffuseTransmission: Double = 0
  public var subsurface: Double = 0
  public var subsurfaceRadiusMM: SIMD3<Double> = .init(repeating:0.1)
  public var sheen: Double = 0
  public var sheenRoughness: Double = 0.5
  public var sheenTint: SIMD3<Float> = .init(repeating:1)
  public var anisotropy: Double = 0
  public var anisotropyRotation: Double = 0
  public var coat: Double = 0
  public var coatRoughness: Double = 0.03
  public var bumpStrength: Double = 1
  public var normalStrength: Double = 1
  public var displacementScaleMM: Double = 0
  public var displacementMidlevel: Double = 0.5
  public var textures: [ScenePhysicalTextureChannel:SceneTexturePayload] = [:]
  public init() {}
  public func validate() throws {
    let unit = [transmission,diffuseTransmission,subsurface,sheen,sheenRoughness,anisotropy,anisotropyRotation,coat,coatRoughness,displacementMidlevel]
    guard ior.isFinite,(1...4).contains(ior),unit.allSatisfy({$0.isFinite && (0...1).contains($0)}),
      [subsurfaceRadiusMM.x,subsurfaceRadiusMM.y,subsurfaceRadiusMM.z].allSatisfy({$0.isFinite && (0...1000).contains($0)}),
      [sheenTint.x,sheenTint.y,sheenTint.z].allSatisfy({$0.isFinite && (0...1).contains($0)}),
      bumpStrength.isFinite,abs(bumpStrength)<=1000,normalStrength.isFinite,(0...10).contains(normalStrength),displacementScaleMM.isFinite,abs(displacementScaleMM)<=1000 else {
      throw CyclesRenderError.invalidScene("Physical material channels must have finite supported values.")
    }
  }
}

public struct ScenePhysicalMaterialLayer:Sendable {
  public var mask:SceneTexturePayload
  public var appearance:ScenePhysicalAppearance?
  /// Explicit factors replace inherited maps unless the layer supplies its own.
  public var roughness:Double?,metallic:Double?
  public init(mask:SceneTexturePayload,appearance:ScenePhysicalAppearance?=nil,roughness:Double?=nil,metallic:Double?=nil){self.mask=mask;self.appearance=appearance;self.roughness=roughness;self.metallic=metallic}
}

public struct SceneCurvePayload: Sendable {
  public var id: String
  public var revision: String
  public var objectID: UUID
  public var pointsMM: [SIMD3<Double>]
  public var radiiMM: [Float]
  /// First point of each independent curve; the final curve ends at points.count.
  public var firstKey: [UInt32]
  /// Per-key physical texture coordinates. U follows the strand in millimeters;
  /// V is a circumferential offset in millimeters. The renderer adds angular
  /// distance around the strand. Empty UV0 derives transformed centerline arc.
  /// Nonuniform scale follows Cycles' equivalent-volume radius approximation;
  /// it does not create an elliptical strand cross-section.
  public var uvsMM:[SIMD2<Float>]
  public var uvs1MM:[SIMD2<Float>]
  public var material: SceneMaterialPayload
  public var transform: SceneTransformPayload
  public var visible: Bool
  public init(id:String,revision:String,objectID:UUID,pointsMM:[SIMD3<Double>],radiiMM:[Float],firstKey:[UInt32],material:SceneMaterialPayload,transform:SceneTransformPayload = .init(),visible:Bool = true,uvsMM:[SIMD2<Float>]=[],uvs1MM:[SIMD2<Float>]=[]) {
    self.id=id;self.revision=revision;self.objectID=objectID;self.pointsMM=pointsMM;self.radiiMM=radiiMM;self.firstKey=firstKey;self.material=material;self.transform=transform;self.visible=visible;self.uvsMM=uvsMM;self.uvs1MM=uvs1MM
  }
  public func validate() throws {
    try transform.validate()
    guard !id.isEmpty,!revision.isEmpty,!firstKey.isEmpty,firstKey.first==0,pointsMM.count<=2_000_000,radiiMM.count==pointsMM.count,
      pointsMM.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && simd_reduce_max(simd_abs($0))<=1e12}),radiiMM.allSatisfy({$0.isFinite && $0>0 && $0<=1000}) else {
      throw CyclesRenderError.invalidScene("Curves need finite positions, positive physical radii and ordered curve starts.")
    }
    guard [uvsMM,uvs1MM].allSatisfy({values in
      (values.isEmpty || values.count==pointsMM.count) && values.allSatisfy{$0.x.isFinite && $0.y.isFinite && abs($0.x)<=1e12 && abs($0.y)<=1e12}
    }) else {throw CyclesRenderError.invalidScene("Curve texture coordinates must contain one finite millimeter pair per key.")}
    for i in firstKey.indices {
      let end=i+1<firstKey.count ? Int(firstKey[i+1]):pointsMM.count
      guard Int(firstKey[i])+2<=end,end<=pointsMM.count else {throw CyclesRenderError.invalidScene("Each independent curve needs at least two points.")}
    }
  }
  /// Bounded Simpson integration of the same clamped Catmull-Rom centerline
  /// used by Cycles. Each independent strand starts at zero; travel is excluded.
  public func resolvedTextureCoordinatesMM()throws->[SIMD2<Float>] {
    try validate();if !uvsMM.isEmpty {return uvsMM}
    var values=Array(repeating:SIMD2<Float>.zero,count:pointsMM.count)
    for strand in firstKey.indices {
      let start=Int(firstKey[strand]),end=strand+1<firstKey.count ? Int(firstKey[strand+1]):pointsMM.count
      var distance=0.0
      for key in start..<end-1 {
        let p0=pointsMM[max(start,key-1)]*transform.scale,p1=pointsMM[key]*transform.scale,p2=pointsMM[key+1]*transform.scale,p3=pointsMM[min(end-1,key+2)]*transform.scale
        let a=(p2-p0)*0.5,b=(p0*2-p1*5+p2*4-p3),c=(-p0+p1*3-p2*3+p3)*1.5
        var sum=0.0
        for step in 0...8 {
          let t=Double(step)/8,weight=step==0 || step==8 ? 1.0:step.isMultiple(of:2) ? 2.0:4.0
          sum+=simd_length(a+b*t+c*t*t)*weight
        }
        distance+=sum/24
        guard distance.isFinite,distance<=1e12 else{throw CyclesRenderError.invalidScene("A curve exceeds the physical texture-coordinate length budget.")}
        values[key+1] = .init(Float(distance),0)
      }
    }
    return values
  }
}

public struct SceneAreaLight: Sendable {
  public enum Kind:String,Sendable {case area,point,sun}
  public enum Shape:String,Sendable {case rectangle,disk}
  public var kind:Kind
  public var shape:Shape = .rectangle
  /// Local -Z is the emitted direction; translation is millimeters.
  public var transform:simd_double4x4
  public var color:SIMD3<Float>
  public var power:Double
  public var sizeMM:SIMD2<Double>
  public init(kind:Kind = .area,shape:Shape = .rectangle,transform:simd_double4x4 = matrix_identity_double4x4,color:SIMD3<Float> = .init(repeating:1),power:Double = 100,sizeMM:SIMD2<Double> = .init(500,500)) {
    self.kind=kind;self.shape=shape;self.transform=transform;self.color=color;self.power=power;self.sizeMM=sizeMM
  }
}

public struct SceneRenderEnvironment: Sendable {
  public var color:SIMD3<Float>
  public var strength:Double
  public var texture:SceneTexturePayload?
  public var rotationDegrees:Double
  public init(color:SIMD3<Float> = .init(repeating:0.15),strength:Double = 1,texture:SceneTexturePayload? = nil,rotationDegrees:Double = 0) {self.color=color;self.strength=strength;self.texture=texture;self.rotationDegrees=rotationDegrees}
}

/// A value snapshot contains no native scene/view objects. A revision identifies
/// geometry, appearance, runtime deformation, camera, lights and source assets.
public struct SceneSnapshot: Sendable {
  public var projectID:UUID?
  public var revision:String
  public var renderables:[SceneRenderablePayload]
  public var curves:[SceneCurvePayload]
  public var camera:SceneCameraPayload
  public var lights:[SceneAreaLight]
  public var environment:SceneRenderEnvironment
  public var apertureFStop:Double?
  public var focusDistanceMM:Double?
  public init(revision:String,renderables:[SceneRenderablePayload],curves:[SceneCurvePayload] = [],camera:SceneCameraPayload,lights:[SceneAreaLight] = [],environment:SceneRenderEnvironment = .init(),apertureFStop:Double? = nil,focusDistanceMM:Double? = nil) {
    self.revision=revision;self.renderables=renderables;self.curves=curves;self.camera=camera;self.lights=lights;self.environment=environment;self.apertureFStop=apertureFStop;self.focusDistanceMM=focusDistanceMM
  }
}

public struct SceneRenderSettings: Sendable, Equatable {
  public enum Device:String,Sendable {case auto,cpu,metal}
  public enum Purpose:String,Sendable {case preview,review,final}
  public var purpose:Purpose
  public var width:Int
  public var height:Int
  public var samples:Int
  public var adaptiveThreshold:Double
  public var denoise:Bool
  public var device:Device
  public var seed:Int
  public var transparent:Bool
  public var exposureEV:Double = 0
  public var maxBounces:Int = 12
  public var displacementDicingRate:Double = 2
  public var displacementMaxTriangles:Int = 2_000_000
  public var displacementMaxSubdivisions:Int = 10
  public init(purpose:Purpose = .final,width:Int = 3000,height:Int = 2000,samples:Int = 512,adaptiveThreshold:Double = 0.01,denoise:Bool = true,device:Device = .auto,seed:Int = 0,transparent:Bool = false) {self.purpose=purpose;self.width=width;self.height=height;self.samples=samples;self.adaptiveThreshold=adaptiveThreshold;self.denoise=denoise;self.device=device;self.seed=seed;self.transparent=transparent}
  public func validate() throws {
    guard (1...8192).contains(width),(1...8192).contains(height),width*height<=32_000_000,(1...65536).contains(samples),adaptiveThreshold.isFinite,(0...1).contains(adaptiveThreshold),seed>=0,seed<=Int(UInt32.max),exposureEV.isFinite,(-20...20).contains(exposureEV),(1...64).contains(maxBounces) else {throw CyclesRenderError.invalidScene("Use positive dimensions up to 8192 per edge / 32 MP, 1–65536 samples and finite sampling/exposure values.")}
    guard purpose == .final || max(width,height)<=1280 else{throw CyclesRenderError.invalidScene("Progressive previews and shot reviews are limited to 1280 pixels per edge.")}
    guard displacementDicingRate.isFinite,(0.25...64).contains(displacementDicingRate),(1...2_000_000).contains(displacementMaxTriangles),(0...10).contains(displacementMaxSubdivisions) else{throw CyclesRenderError.invalidScene("Displacement needs 0.25–64 pixel dicing, at most two million generated triangles and 0–10 subdivisions.")}
  }
}

/// Compatibility spelling retained for existing Cycles integration call sites.
public typealias CyclesRenderConfiguration = SceneRenderSettings

public enum CyclesRenderError: LocalizedError {
  case unavailable(String),invalidScene(String),helperFailed(String),protocolViolation(String),busy,cancelled
  public var errorDescription:String? {
    switch self {
    case .unavailable(let s),.invalidScene(let s),.helperFailed(let s),.protocolViolation(let s):return s
    case .busy:return "A higher-priority Cycles render is running. Cancel or finish it before starting this job."
    case .cancelled:return "The Cycles render was cancelled or superseded."
    }
  }
}

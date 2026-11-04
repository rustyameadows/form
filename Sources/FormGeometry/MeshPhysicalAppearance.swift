import Foundation
import simd

/// Physical surface intent travels with construction materials, including their
/// copies. It contains no project models or renderer objects.
public struct MeshPhysicalAppearance {
  public var ior=1.5,transmission=0.0,diffuseTransmission=0.0,subsurface=0.0
  public var subsurfaceRadiusMM=SIMD3<Double>(1,0.2,0.1)
  public var sheen=0.0,sheenRoughness=0.5,anisotropy=0.0,anisotropyRotation=0.0
  public var sheenTint=SIMD3<Float>(repeating:1)
  public var coat=0.0,coatRoughness=0.03,bumpStrength=1.0,normalStrength=1.0
  public var displacementScaleMM=0.0,displacementMidlevel=0.5
  public var textures:[String:MeshPhysicalTexture]=[:]
  public init(){}
}

public struct MeshPhysicalTexture {
  public enum Encoding:String {case srgb,linearSRGB,data}
  public var url:URL?
  public var assetName:String
  public var sha256:String
  public var encoding:Encoding
  public var uvIndex:Int
  public var wrapS:MeshWrapMode,wrapT:MeshWrapMode
  public var scale:SIMD2<Double>,offset:SIMD2<Double>
  public var rotationDegrees:Double
  public init(url:URL?,assetName:String,sha256:String,encoding:Encoding,uvIndex:Int,wrapS:MeshWrapMode,wrapT:MeshWrapMode,
    scale:SIMD2<Double>,offset:SIMD2<Double>,rotationDegrees:Double) {
    self.url=url;self.assetName=assetName;self.sha256=sha256;self.encoding=encoding;self.uvIndex=uvIndex
    self.wrapS=wrapS;self.wrapT=wrapT;self.scale=scale;self.offset=offset;self.rotationDegrees=rotationDegrees
  }
}

public struct MeshPhysicalMaterialLayer {
  public var mask:MeshMaterialProperty
  /// Nil inherits the substrate's optical response without resetting it.
  public var appearance:MeshPhysicalAppearance?
  public var roughness:Double?,metallic:Double?
  public init(mask:MeshMaterialProperty,appearance:MeshPhysicalAppearance?=nil,roughness:Double?=nil,metallic:Double?=nil){self.mask=mask;self.appearance=appearance;self.roughness=roughness;self.metallic=metallic}
}

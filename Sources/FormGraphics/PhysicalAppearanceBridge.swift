import AppKit
import FormCore
import FormGeometry
import simd

extension PhysicalAppearance {
  /// Resolution is independent of the final renderer. Physical repeat size is
  /// converted to this surface's UV dimensions; artwork keeps its own mapping.
  public func meshAppearance(assets:URL?=nil,surfaceSizeMM:Point2)->MeshPhysicalAppearance {
    var result=MeshPhysicalAppearance()
    result.ior=ior;result.transmission=transmission;result.diffuseTransmission=diffuseTransmission
    result.subsurface=subsurface;result.subsurfaceRadiusMM = .init(subsurfaceRadiusMM.x,subsurfaceRadiusMM.y,subsurfaceRadiusMM.z)
    result.sheen=sheen;result.sheenRoughness=sheenRoughness
    let tint=FormColor.color(sheenTint).usingColorSpace(.sRGB) ?? .white
    func linear(_ v:CGFloat)->Float {Float(v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4))}
    result.sheenTint = .init(linear(tint.redComponent),linear(tint.greenComponent),linear(tint.blueComponent))
    result.anisotropy=anisotropy;result.anisotropyRotation=anisotropyRotation
    result.coat=coat;result.coatRoughness=coatRoughness;result.bumpStrength=bumpStrength;result.normalStrength=normalStrength
    result.displacementScaleMM=displacementScaleMM;result.displacementMidlevel=displacementMidlevel
    func wrap(_ value:PhysicalTextureReference.Wrap)->MeshWrapMode {
      switch value {case .repeat:return .repeat;case .clamp:return .clamp;case .mirror:return .mirror}
    }
    for (channel,texture) in textures {
      var scale=SIMD2(texture.scale.x,texture.scale.y)
      if let size=texture.scaleMM {scale *= .init(surfaceSizeMM.x/size.x,surfaceSizeMM.y/size.y)}
      result.textures[channel] = .init(url:assets?.appendingPathComponent(texture.asset),assetName:texture.asset,sha256:texture.sha256,
        encoding:.init(rawValue:texture.colorSpace.rawValue) ?? .data,uvIndex:texture.uvIndex,
        wrapS:wrap(texture.wrapS),wrapT:wrap(texture.wrapT),scale:scale,
        offset:.init(texture.offset.x,texture.offset.y),rotationDegrees:texture.rotationDegrees)
    }
    return result
  }
}

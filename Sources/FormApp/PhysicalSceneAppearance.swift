import AppKit
import FormCore
import FormGraphics
import ImageIO
import LabRendering

/// Resolves a portable optical material for adapters that already own neutral
/// scene buffers (CAD and imported meshes), without rebuilding their geometry.
@MainActor enum PhysicalSceneAppearance {
  static func resolve(_ appearance:PhysicalAppearance,assets:URL,surfaceSizeMM:Point2?)throws->ScenePhysicalAppearance {
    try appearance.validate()
    if appearance.textures.values.contains(where:{$0.scaleMM != nil}),surfaceSizeMM == nil {
      throw FormError.invalid("A physical texture repeat needs a named surface with millimeter UV dimensions. Use ordinary UV scale on an uncalibrated CAD or imported surface.")
    }
    for texture in appearance.textures.values {
      let url=try texture.verifiedURL(in:assets)
      guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil),image.width<=8192,image.height<=8192,image.width*image.height<=16_777_216 else{throw FormError.invalid("The physical material image cannot be decoded within the 16 MP / 8192-pixel render texture budget.")}
    }
    let neutral=appearance.meshAppearance(assets:assets,surfaceSizeMM:surfaceSizeMM ?? .init(1,1))
    return try GeometryPayloadAdapter.physicalPayload(neutral,assets:assets)
  }
}

import AppKit
import FormCore
import FormGeometry

extension Material {
  /// Cloth simulation owns a zero-thickness center surface. The physical
  /// renderer derives both optical faces and the finite edge from this record.
  @MainActor public func bindClothPhysical(to material:MeshMaterial,assets:URL,surfaceSizeMM:Point2) {
    guard appearance != nil || backSurface != nil else {return}
    material.physicalThicknessMM=thickness
    material.physicalAppearance=(appearance ?? PhysicalAppearance()).meshAppearance(assets:assets,surfaceSizeMM:surfaceSizeMM)
    material.physicalBaseColor.contents=FormColor.color(color)
    if let response=backSurface {
      let back=MeshMaterial();back.name="Reverse / \(id)";back.lightingModel = .physicallyBased
      back.diffuse.contents=FormColor.color(response.color);back.roughness.contents=response.roughness;back.metalness.contents=response.metallic
      back.physicalAppearance=response.appearance?.meshAppearance(assets:assets,surfaceSizeMM:surfaceSizeMM)
      material.physicalBackMaterial=back
    }
  }
}

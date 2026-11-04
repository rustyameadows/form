import AppKit
import XCTest
import FormCore
import FormGeometry
import FormGraphics

@MainActor final class ClothPhysicalMaterialTests:XCTestCase {
  func testReverseResponseAndCaliperAreIndependentFromFrontAndClone()throws {
    var source=Material("two-faces","Two finished faces","Fabric","#EEEEEE",roughness:0.22,thickness:0.18)
    source.backSurface = .init(color:"#AAAAAA",roughness:0.85,metallic:0,appearance:.init())
    source.backSurface!.appearance!.sheen=0.1
    let front=MeshMaterial();front.roughness.contents=source.roughness
    source.bindClothPhysical(to:front,assets:URL(fileURLWithPath:"/tmp"),surfaceSizeMM:.init(140,110))
    XCTAssertEqual(front.physicalThicknessMM,0.18);XCTAssertEqual(front.roughness.contents as? Double,0.22)
    let back=try XCTUnwrap(front.physicalBackMaterial)
    XCTAssertEqual(back.roughness.contents as? Double,0.85);XCTAssertEqual(back.physicalAppearance?.sheen,0.1)
    XCTAssertEqual(back.physicalThicknessMM,0);XCTAssertNil(back.physicalBackMaterial)
    let copied=try XCTUnwrap(front.copy() as? MeshMaterial)
    XCTAssertFalse(copied.physicalBackMaterial === back)
    copied.physicalBackMaterial?.roughness.contents=0.3
    XCTAssertEqual(back.roughness.contents as? Double,0.85)
    let legacy=MeshMaterial()
    Material("old","Legacy fabric","Fabric","#FFFFFF",thickness:2).bindClothPhysical(to:legacy,assets:URL(fileURLWithPath:"/tmp"),surfaceSizeMM:.init(100,100))
    XCTAssertEqual(legacy.physicalThicknessMM,0);XCTAssertNil(legacy.physicalBackMaterial)
  }
}

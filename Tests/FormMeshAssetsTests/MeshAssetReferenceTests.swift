import Foundation
import XCTest
import FormMeshAssets

final class MeshAssetReferenceTests:XCTestCase {
  func fixture()throws->MeshAssetReference {
    let f=MeshAssetFixtures.triangle(),d=try GLTFImporter.importData(MeshAssetFixtures.glb(f.json,binary:f.binary)),normalized=try JSONEncoder().encode(d)
    return .init(document:d,sourceAsset:"original.glb",normalizedAsset:"normalized.mesh.json",normalizedSHA256:MeshAssetHash.sha256(normalized))
  }
  func testSmallReferenceRetainsEditabilityAndSeparatesAppearanceFromGeometry()throws {
    var reference=try fixture();try reference.validate();let geometry=reference.geometryRevision,appearance=reference.appearanceRevision
    reference.materialOverrides=[.init(materialIndex:0,colorHex:"#D45A37",roughness:0.3)];reference.artworkBindings=[.init(materialIndex:0)];reference.artworkSizeMM = .init(width:180,height:100);try reference.validate()
    XCTAssertEqual(reference.geometryRevision,geometry);XCTAssertNotEqual(reference.appearanceRevision,appearance);XCTAssertEqual(reference.editability,"visualMesh");XCTAssertEqual(reference.tableAnchor,"boundsBottomCenter")
    XCTAssertEqual(try JSONDecoder().decode(MeshAssetReference.self,from:JSONEncoder().encode(reference)),reference)
  }
  func testReferencesRejectEscapingAssetsMalformedSlotsAndFalsePhysicalCertification()throws {
    var reference=try fixture();reference.sourceAsset="../other.glb";XCTAssertThrowsError(try reference.validate())
    reference=try fixture();reference.materialOverrides=[.init(materialIndex:2,colorHex:"#123456")];XCTAssertThrowsError(try reference.validate())
    reference=try fixture();reference.materials[0].baseColor=[];XCTAssertThrowsError(try reference.validate())
    reference=try fixture();var binding=MeshAssetArtworkBinding(materialIndex:0);binding.physicalScaleVerified=true;reference.artworkBindings=[binding];XCTAssertThrowsError(try reference.validate())
    reference=try fixture();reference.artworkBindings=[.init(materialIndex:0,primitiveIDs:["missing"])];XCTAssertThrowsError(try reference.validate())
    reference=try fixture();reference.artworkSizeMM = .init(width:.infinity,height:100);XCTAssertThrowsError(try reference.validate())
  }
}

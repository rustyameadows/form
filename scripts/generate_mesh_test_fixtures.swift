import Foundation
import FormMeshAssets

/// Build alongside Tests/FormMeshAssetsTests/MeshAssetFixtures.swift; no XCTest dependency.
/// Outputs original procedural assets only, never a supplier garment reconstruction.
@main enum GenerateMeshTestFixtures {
  static func main() throws {
    guard CommandLine.arguments.count==2 else{throw MeshAssetError.invalid("Pass an output directory.")}
    let directory=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    for (name,fixture) in [("LAB-synthetic-flight-jacket",MeshAssetFixtures.jacket()),("LAB-device-assembly",MeshAssetFixtures.cube())] {
      let data=MeshAssetFixtures.glb(fixture.json,binary:fixture.binary),url=directory.appendingPathComponent(name+".glb")
      try data.write(to:url,options:.atomic)
      let document=try GLTFImporter.importFile(url)
      print(name,"vertices",document.vertexCount,"triangles",document.triangleCount,"source_sha256",document.provenance.sourceSHA256)
    }
  }
}

import AppKit
import XCTest
import FormCore
import FormCADModel
@testable import FormApp

@MainActor final class CollectionDetachedArtworkTests:XCTestCase {
  func testOriginalAssetMetadataIncludesDetachedSurfaceImagesImportsAndProfiles()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("detached-collection-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root),store=StudioStore(repository:repository,seedLibrary:false)
    var project=Project(name:"Detached original artwork")
    let image=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!
    let profile=CGColorSpace(name:CGColorSpace.sRGB)!.copyICCData()! as Data
    let digest=ArtworkTransferBundle.digest(profile),profileName="icc-"+digest+".icc"
    var artwork=Artwork(elements:[.init(kind:"image",x:0,y:0,width:20,height:10,asset:"original.png")])
    artwork.imports=[.init(asset:"original.svg",name:"Original vector source",width:20,height:10)]
    artwork.outputColorProfile = .init(name:"sRGB",asset:profileName,sha256:digest,model:"RGB")
    var binding=PhysicalSurfaceArtworkBinding(surfaceID:"front",sourceObjectID:UUID(),widthMM:20,heightMM:10)
    binding.sourceObjectID=nil;binding.artwork=artwork
    let feature=CADFeatureNode(name:"Body",operation:.init(.box,values:["width":20,"height":10,"depth":5]))
    var object=ProductObject(name:"Retained original",recipeID:"cadModel",parameters:[:])
    object.cadModel=CADModelDefinition(name:"Body",features:[feature],outputs:[feature.id])
    object.surfaceArtworkBindings=[binding];project.objects=[object]
    let assets=repository.url(for:project.id).appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    let files=["original.png":image,"original.svg":Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\"/>".utf8),profileName:profile]
    for (name,data) in files{try data.write(to:assets.appendingPathComponent(name))}
    let source=try CollectionSource(project:project,plan:.init(name:"Original source",runs:[.init(objectID:object.id)]))
    let metadata=try store.collectionOriginalAssetMetadata(source)
    XCTAssertEqual(Set(metadata.map(\.name)),Set(files.keys.map{"Sources/Assets/"+$0}))
    XCTAssertEqual(metadata.reduce(0){$0+$1.bytes},files.values.reduce(0){$0+$1.count})
    XCTAssertEqual(metadata.first{$0.profile != nil}?.profile?.sha256,digest)
    for item in metadata{XCTAssertEqual(try Data(contentsOf:item.url),files[String(item.name.dropFirst("Sources/Assets/".count))])}
  }
}

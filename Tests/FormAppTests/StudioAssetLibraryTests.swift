import AppKit
import CryptoKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class StudioAssetLibraryTests:XCTestCase {
  private func fixture()throws->URL {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("studio-assets-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    addTeardownBlock {try? FileManager.default.removeItem(at:root)}
    return root
  }
  private func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  private func png()throws->Data {
    let image=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:12,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:64,bitsPerPixel:32))
    for y in 0..<12 {for x in 0..<16 {image.setColor(NSColor(srgbRed:0.2,green:0.4,blue:0.8,alpha:1),atX:x,y:y)}}
    return try XCTUnwrap(image.representation(using:.png,properties:[:]))
  }
  private func project(_ root:URL)throws->(ProjectRepository,Project) {
    let repository=try ProjectRepository(root:root)
    var value=Project(name:"Canonical source stays unchanged")
    var object=try value.makeObject(recipeID:"artboard",name:"Independent source")
    object.artwork=Artwork(elements:[.init(kind:"text",x:10,y:12,text:"Original editable source")])
    value.objects=[object];try repository.save(value)
    // The repository's ISO-8601 contract rounds Date values on persistence.
    // Compare against the accepted decoded source, alongside exact package bytes.
    return(repository,try repository.load(value.id))
  }
  private func files(_ folder:URL)throws->[String:Data] {
    let enumerator=try XCTUnwrap(FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey]))
    var result=[String:Data]()
    for case let url as URL in enumerator where (try url.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile==true {
      result[String(url.path.dropFirst(folder.path.count+1))]=try Data(contentsOf:url)
    }
    return result
  }

  func testOwnedGeneratedAssetRoundTripsRelativeIdentityChecksumAndMockProvenance()throws {
    let root=try fixture(),library=StudioAssetLibrary(root:root),data=try png(),projectID=UUID(),sceneID=UUID(),runID=UUID()
    let input=try library.register(data:data,filename:"scene-input.png",name:"Scene input",metadata:.init(kind:.image,origin:.exported,projectID:projectID))
    let metadata=StudioAssetMetadata(kind:.image,origin:.generated,projectID:projectID,projectName:"Dispatch",sceneID:sceneID,generationID:runID,isMock:true,sourceAssetIDs:[input.id],prompt:"A quiet studio still",provider:"Local demo",options:["transport":"none","quality":"high"])
    let asset=try library.register(data:data,filename:"demo.png",name:"Dispatch demo",metadata:metadata)
    XCTAssertEqual(asset.sha256,hash(data));XCTAssertEqual(asset.metadata,metadata)
    XCTAssertEqual(asset.relativePath,"StudioAssets/Files/\(asset.id.uuidString)/demo.png")
    XCTAssertFalse(asset.relativePath.hasPrefix("/"));XCTAssertEqual(try Data(contentsOf:library.fileURL(for:asset)),data)
    let reopened=StudioAssetLibrary(root:root),current=try XCTUnwrap(reopened.asset(id:asset.id))
    XCTAssertNil(reopened.issue);XCTAssertEqual(current,asset);XCTAssertTrue(current.isMock)
    XCTAssertEqual(current.metadata.sourceAssetIDs,[input.id]);XCTAssertEqual(current.metadata.generationID,runID)
    let index=try String(contentsOf:root.appendingPathComponent("StudioAssets/Index.json"))
    XCTAssertFalse(index.contains(root.path),"Durable asset locations are Library-relative.")
  }

  func testImportRenameFavoriteCopyAndArchiveNeverMutateOrDeleteThePickedOriginal()async throws {
    let root=try fixture(),library=StudioAssetLibrary(root:root),picked=root.appendingPathComponent("Picked originals/shape.svg")
    try FileManager.default.createDirectory(at:picked.deletingLastPathComponent(),withIntermediateDirectories:true)
    let bytes=Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'><rect width='20' height='10'/></svg>".utf8)
    try bytes.write(to:picked)
    let asset=try await library.importFile(picked)
    XCTAssertEqual(asset.origin,.uploaded);XCTAssertEqual(asset.kind,.vector)
    XCTAssertNotEqual(try library.fileURL(for:asset),picked)
    try library.rename(asset.id,to:"Editable source shape");try library.setFavorite(asset.id,true)
    let copy=root.appendingPathComponent("selected-copy.svg")
    try library.saveCopy(asset.id,to:copy);XCTAssertEqual(try Data(contentsOf:copy),bytes)
    XCTAssertThrowsError(try library.saveCopy(asset.id,to:copy));XCTAssertEqual(try Data(contentsOf:copy),bytes)
    try Data("Previous destination".utf8).write(to:copy)
    try library.saveCopy(asset.id,to:copy,replaceExisting:true)
    XCTAssertEqual(try Data(contentsOf:copy),bytes);XCTAssertEqual(try Data(contentsOf:picked),bytes)
    XCTAssertThrowsError(try library.saveCopy(asset.id,to:library.fileURL(for:asset),replaceExisting:true))
    try library.archive(asset.id)
    XCTAssertTrue(library.visibleItems.isEmpty);XCTAssertEqual(try Data(contentsOf:picked),bytes)
    let reopened=StudioAssetLibrary(root:root),retained=try XCTUnwrap(reopened.asset(id:asset.id))
    XCTAssertEqual(retained.name,"Editable source shape");XCTAssertTrue(retained.favorite);XCTAssertNotNil(retained.archivedAt)
    XCTAssertEqual(try Data(contentsOf:reopened.fileURL(for:retained)),bytes)
  }

  func testProjectAssetsAndExportMediaAreReferencedReadOnlyAndArchivedReferencesStayRemoved()async throws {
    let root=try fixture(),(repository,project)=try self.project(root),package=repository.url(for:project.id)
    let input=package.appendingPathComponent("Assets/source.png"),folder=package.appendingPathComponent("Exports/scene.render")
    try png().write(to:input);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let output=folder.appendingPathComponent("Scene.png");try png().write(to:output)
    let sceneID=UUID()
    try JSONSerialization.data(withJSONObject:["application":"LAB","scene":["id":sceneID.uuidString],"renderer":"RealityKit"]).write(to:folder.appendingPathComponent("render.json"))
    try Data("glTF".utf8).write(to:package.appendingPathComponent("Assets/source.glb"))
    let before=try files(package),library=StudioAssetLibrary(root:root)
    await library.refresh()
    XCTAssertEqual(library.visibleItems.count,3,library.issue ?? "")
    XCTAssertTrue(library.items.allSatisfy{$0.storage == .projectReference})
    XCTAssertFalse(library.items.contains{$0.filename=="render.json"})
    let exported=try XCTUnwrap(library.items.first{$0.origin == .exported})
    XCTAssertEqual(exported.metadata.sceneID,sceneID);XCTAssertEqual(exported.metadata.projectID,project.id)
    XCTAssertEqual(try library.fileURL(for:exported),output.standardizedFileURL.resolvingSymlinksInPath())
    XCTAssertTrue(library.items.contains{$0.kind == .model && $0.filename=="source.glb"})
    try library.rename(exported.id,to:"Saved studio still");try library.setFavorite(exported.id,true);try library.archive(exported.id)
    await library.refresh()
    XCTAssertFalse(library.visibleItems.contains{$0.id==exported.id})
    let reopened=StudioAssetLibrary(root:root);await reopened.refresh()
    XCTAssertEqual(reopened.asset(id:exported.id)?.name,"Saved studio still");XCTAssertEqual(reopened.asset(id:exported.id)?.favorite,true)
    XCTAssertNotNil(reopened.asset(id:exported.id)?.archivedAt)
    XCTAssertEqual(try files(package),before,"Scanning and asset metadata edits must preserve every project source, export and history byte.")
    XCTAssertEqual(try repository.load(project.id),project)
  }

  func testMissingFilesKeepMetadataAndInvalidImagesUseGracefulPreviewFallback()async throws {
    let root=try fixture(),library=StudioAssetLibrary(root:root)
    let invalid=try library.register(data:Data("not an image".utf8),filename:"unreadable.png",metadata:.init(kind:.image,origin:.uploaded))
    let invalidPreview=await library.thumbnail(for:invalid);XCTAssertNil(invalidPreview)
    let asset=try library.register(data:try png(),filename:"present.png",metadata:.init(kind:.image,origin:.uploaded))
    let preview=await library.thumbnail(for:asset,maxPixelSize:96)
    XCTAssertNotNil(preview);XCTAssertLessThanOrEqual(preview?.size.width ?? .infinity,96)
    try FileManager.default.removeItem(at:library.fileURL(for:asset))
    await library.refresh()
    let missing=try XCTUnwrap(library.asset(id:asset.id));XCTAssertTrue(missing.isMissing)
    XCTAssertEqual(missing.sha256,asset.sha256);XCTAssertEqual(missing.name,asset.name)
    XCTAssertThrowsError(try library.fileURL(for:missing))
    let missingPreview=await library.thumbnail(for:missing);XCTAssertNil(missingPreview)
    let reopened=StudioAssetLibrary(root:root)
    XCTAssertTrue(try XCTUnwrap(reopened.asset(id:asset.id)).isMissing)
  }

  func testEscapingReferencesAndCorruptIndexesFailClosedWithoutOverwritingMetadata()async throws {
    let root=try fixture(),outside=try fixture(),(repository,project)=try self.project(root)
    let secret=outside.appendingPathComponent("outside.png"),original=try png();try original.write(to:secret)
    let link=repository.url(for:project.id).appendingPathComponent("Assets/linked.png")
    try FileManager.default.createSymbolicLink(at:link,withDestinationURL:secret)
    let library=StudioAssetLibrary(root:root);await library.refresh()
    XCTAssertTrue(library.items.isEmpty)
    let asset=try library.register(data:Data("local".utf8),filename:"safe.txt",metadata:.init(kind:.file,origin:.uploaded))
    var escaped=asset;escaped.relativePath="../outside.png"
    XCTAssertThrowsError(try library.fileURL(for:escaped))
    let index=root.appendingPathComponent("StudioAssets/Index.json")
    var raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:index)) as? [String:Any])
    var values=try XCTUnwrap(raw["items"] as? [[String:Any]])
    values[0]["relativePath"]="../../outside.png";raw["items"]=values
    let corrupted=try JSONSerialization.data(withJSONObject:raw);try corrupted.write(to:index)
    let reopened=StudioAssetLibrary(root:root)
    XCTAssertNotNil(reopened.issue);XCTAssertTrue(reopened.items.isEmpty)
    XCTAssertThrowsError(try reopened.register(data:Data("another".utf8),filename:"later.txt",metadata:.init(kind:.file,origin:.uploaded)))
    await reopened.refresh();XCTAssertEqual(try Data(contentsOf:index),corrupted)
    XCTAssertEqual(try Data(contentsOf:secret),original)
  }

  func testFailedIndexPublicationRollsBackOnlyTheNewOwnedCopy()throws {
    let root=try fixture(),library=StudioAssetLibrary(root:root)
    let original=try library.register(data:Data("previous owned original".utf8),filename:"original.txt",metadata:.init(kind:.file,origin:.uploaded))
    let before=library.items,originalBytes=try Data(contentsOf:library.fileURL(for:original))
    let index=root.appendingPathComponent("StudioAssets/Index.json")
    let oldIndex=try Data(contentsOf:index),backup=root.appendingPathComponent("accepted-index-backup.json")
    try FileManager.default.moveItem(at:index,to:backup)
    try FileManager.default.createDirectory(at:index,withIntermediateDirectories:true)
    XCTAssertThrowsError(try library.registerBatch([
      .init(data:Data("new first output".utf8),filename:"first.txt",metadata:.init(kind:.file,origin:.generated,isMock:true)),
      .init(data:Data("new second output".utf8),filename:"second.txt",metadata:.init(kind:.file,origin:.generated,isMock:true))]))
    XCTAssertEqual(library.items,before)
    let files=root.appendingPathComponent("StudioAssets/Files")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:files,includingPropertiesForKeys:nil).map(\.lastPathComponent),[original.id.uuidString])
    XCTAssertEqual(try Data(contentsOf:library.fileURL(for:original)),originalBytes)
    XCTAssertEqual(try Data(contentsOf:backup),oldIndex)
    // The URL cached the original file's resource values before moveItem. Query the filesystem.
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:index.path)[.type] as? FileAttributeType,.typeDirectory)
  }

  func testBoundedScanFinishesWithoutChangingUnscannedOriginals()async throws {
    let root=try fixture(),(repository,project)=try self.project(root),package=repository.url(for:project.id)
    for i in 0..<12 {try Data("Original \(i)".utf8).write(to:package.appendingPathComponent("Assets/\(i).txt"))}
    let before=try files(package),library=StudioAssetLibrary(root:root,limits:.init(projects:1,files:3,hashBytes:1024,manifestBytes:1024*1024))
    await library.refresh()
    XCTAssertFalse(library.isLoading);XCTAssertLessThanOrEqual(library.visibleItems.count,3);XCTAssertNotNil(library.issue)
    XCTAssertEqual(try files(package),before)
    let complete=StudioAssetLibrary(root:root);await complete.refresh()
    XCTAssertEqual(complete.visibleItems.count,12,complete.issue ?? "");XCTAssertEqual(Set(complete.items.map(\.id)).count,12)
    XCTAssertEqual(try files(package),before)
  }

  func testLongOriginalFilenamesAndInvalidOptionalExportProvenanceRemainReadableAfterRestart()async throws {
    let root=try fixture(),(repository,project)=try self.project(root),package=repository.url(for:project.id)
    let filename=String(repeating:"L",count:248)+".txt"
    let original=package.appendingPathComponent("Assets/"+filename),originalBytes=Data("Untouched long-name original".utf8)
    try originalBytes.write(to:original)
    let folder=package.appendingPathComponent("Exports/untrusted.render")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    try png().write(to:folder.appendingPathComponent("Scene.png"))
    let record=try JSONSerialization.data(withJSONObject:["application":String(repeating:"x",count:201),"renderer":String(repeating:"y",count:4001),"scene":["id":UUID().uuidString],"isMock":true])
    try record.write(to:folder.appendingPathComponent("render.json"))
    let before=try files(package),library=StudioAssetLibrary(root:root)
    await library.refresh()
    XCTAssertNil(library.issue);XCTAssertEqual(library.visibleItems.count,2)
    let source=try XCTUnwrap(library.items.first{$0.filename==filename})
    XCTAssertEqual(source.name,String(repeating:"L",count:240));XCTAssertEqual(source.filename,filename)
    XCTAssertEqual(try Data(contentsOf:library.fileURL(for:source)),originalBytes)
    let output=try XCTUnwrap(library.items.first{$0.origin == .exported})
    XCTAssertNil(output.metadata.provider);XCTAssertNil(output.metadata.options);XCTAssertNil(output.metadata.sceneID)
    XCTAssertFalse(output.isMock);XCTAssertEqual(output.metadata.projectID,project.id)
    let reopened=StudioAssetLibrary(root:root)
    XCTAssertNil(reopened.issue);XCTAssertEqual(Set(reopened.items.map(\.id)),Set(library.items.map(\.id)))
    await reopened.refresh()
    XCTAssertNil(reopened.issue);XCTAssertEqual(reopened.items.count,2)
    XCTAssertEqual(reopened.asset(id:source.id),source);XCTAssertEqual(reopened.asset(id:output.id),output)
    XCTAssertEqual(try files(package),before);XCTAssertEqual(try repository.load(project.id),project)
  }

  func testBatchPublicationCommitsAllOutputsAndInvalidSecondInputLeavesAcceptedIndexExact()throws {
    let root=try fixture(),library=StudioAssetLibrary(root:root),metadata=StudioAssetMetadata(kind:.image,origin:.generated,isMock:true)
    let data=try png()
    let assets=try library.registerBatch([
      .init(data:data,filename:"first.png",name:"First demo",metadata:metadata),
      .init(data:data,filename:"second.png",name:"Second demo",metadata:metadata)])
    XCTAssertEqual(assets.count,2);XCTAssertEqual(Set(assets.map(\.id)).count,2)
    XCTAssertEqual(StudioAssetLibrary(root:root).items,assets)
    let index=root.appendingPathComponent("StudioAssets/Index.json"),before=try Data(contentsOf:index),accepted=library.items
    XCTAssertThrowsError(try library.registerBatch([
      .init(data:data,filename:"valid.png",metadata:metadata),.init(data:data,filename:"../invalid.png",metadata:metadata)]))
    XCTAssertEqual(library.items,accepted);XCTAssertEqual(try Data(contentsOf:index),before)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("StudioAssets/Files"),includingPropertiesForKeys:nil).count,2)
    for asset in assets {XCTAssertEqual(try Data(contentsOf:library.fileURL(for:asset)),data)}
  }
}

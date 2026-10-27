import Foundation
import AppKit
import LabRendering
import FormCore
import FormMeshAssets
import ImageIO
import XCTest
@testable import FormApp

@MainActor final class ModelAssetEditingTests:XCTestCase {
  private func fixture(textured:Bool=false)throws->(StudioStore,URL,URL) {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),repository=try ProjectRepository(root:root),store=StudioStore(repository:repository,seedLibrary:false)
    var project=Project(name:"Imported visual mesh lifecycle"),frame=try project.makeObject(recipeID:"artboard",parameters:["width":180,"depth":100]);frame.artwork=Artwork(elements:[.init(kind:"text",x:5,y:5,width:80,height:15,text:"UV source")]);project.objects=[frame];try repository.save(project);try store.engine.open(project.id);store.showingHome=false
    let file=root.appendingPathComponent("Original.glb");try source(textured:textured).write(to:file)
    addTeardownBlock{ @MainActor in store.modelAssets.reset();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return(store,root,file)
  }
  private func source(textured:Bool=false)->Data {
    var binary=Data()
    for f:Float in [0,0,0,0.04,0,0,0,0.03,0, 0,0,1,0,0,1,0,0,1, 0,0,1,0,0,1] {var word=f.bitPattern.littleEndian;withUnsafeBytes(of:&word){binary.append(contentsOf:$0)}}
    for n:UInt32 in [0,1,2] {var word=n.littleEndian;withUnsafeBytes(of:&word){binary.append(contentsOf:$0)}}
    var root:[String:Any]=["asset":["version":"2.0"],"buffers":[["byteLength":binary.count]],"bufferViews":[["buffer":0,"byteOffset":0,"byteLength":36],["buffer":0,"byteOffset":36,"byteLength":36],["buffer":0,"byteOffset":72,"byteLength":24],["buffer":0,"byteOffset":96,"byteLength":12]],"accessors":[["bufferView":0,"componentType":5126,"count":3,"type":"VEC3"],["bufferView":1,"componentType":5126,"count":3,"type":"VEC3"],["bufferView":2,"componentType":5126,"count":3,"type":"VEC2"],["bufferView":3,"componentType":5125,"count":3,"type":"SCALAR"]],"meshes":[["primitives":[["attributes":["POSITION":0,"NORMAL":1,"TEXCOORD_0":2],"indices":3,"material":0]]]],"materials":[["name":"Surface","pbrMetallicRoughness":["metallicFactor":0,"roughnessFactor":0.7]]],"nodes":[["mesh":0]],"scenes":[["nodes":[0]]],"scene":0]
    if textured {
      func png(_ rgba:[UInt8])->String {
        let provider=CGDataProvider(data:Data(rgba) as CFData)!,image=CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!,data=NSMutableData(),destination=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil);precondition(CGImageDestinationFinalize(destination));return "data:image/png;base64,"+(data as Data).base64EncodedString()
      }
      root["images"]=[["uri":png([8,12,24,255,16,22,38,255,16,22,38,255,8,12,24,255])],["uri":png(Array(repeating:[UInt8(128),128,255,255],count:4).flatMap{$0})],["uri":png(Array(repeating:[UInt8(255),180,25,255],count:4).flatMap{$0})]]
      root["textures"]=[["source":0],["source":1],["source":2]]
      root["materials"]=[["name":"Textured shell","pbrMetallicRoughness":["baseColorTexture":["index":0],"metallicRoughnessTexture":["index":2],"metallicFactor":0.7,"roughnessFactor":0.7],"normalTexture":["index":1]],["name":"Independent trim","pbrMetallicRoughness":["metallicFactor":0,"roughnessFactor":0.8]]]
      var meshes=root["meshes"] as! [[String:Any]],primitives=meshes[0]["primitives"] as! [[String:Any]],trim=primitives[0];trim["material"]=1;primitives.append(trim);meshes[0]["primitives"]=primitives;root["meshes"]=meshes
    }
    var json=try! JSONSerialization.data(withJSONObject:root);while json.count%4 != 0{json.append(0x20)};var output=Data()
    func word(_ x:UInt32){var n=x.littleEndian;withUnsafeBytes(of:&n){output.append(contentsOf:$0)}}
    word(0x46546c67);word(2);word(UInt32(28+json.count+binary.count));word(UInt32(json.count));word(0x4e4f534a);output.append(json);word(UInt32(binary.count));word(0x004e4942);output.append(binary);return output
  }
  private func ready(_ store:StudioStore,_ file:URL)async throws->ModelImportReview {
    let job=try store.modelAssets.beginImport(url:file,sourceUnit:nil,name:"Visual model",present:false)
    for _ in 0..<400 {if job.state != "preparing" {break};try await Task.sleep(for:.milliseconds(10))}
    XCTAssertEqual(job.state,"ready",job.error ?? "");return job
  }
  private func publish(_ store:StudioStore,_ job:ModelImportReview)async throws->ProductObject {
    try store.modelAssets.commit(job)
    XCTAssertEqual(job.state,"publishing")
    for _ in 0..<400 {if job.state != "publishing" {break};try await Task.sleep(for:.milliseconds(10))}
    XCTAssertEqual(job.state,"committed",job.error ?? "")
    return try XCTUnwrap(store.project?.objects.first{$0.id==job.objectID})
  }
  func testActualImportPreservesOriginalPublishesOneUndoAndReopensWithoutSourceFile()async throws {
    let(store,_,file)=try fixture(),before=store.project!,raw=try Data(contentsOf:file),job=try await ready(store,file)
    let object=try await publish(store,job),reference=try XCTUnwrap(object.meshAsset),assets=store.repository.url(for:before.id).appendingPathComponent("Assets")
    XCTAssertEqual(object.recipeID,"importedMesh");XCTAssertEqual(object["scalePercent"],100);XCTAssertEqual(reference.editability,"visualMesh");XCTAssertEqual(store.engine.undoStack.count,1)
    XCTAssertEqual(try Data(contentsOf:assets.appendingPathComponent(reference.sourceAsset)),raw);try store.engine.flush();try FileManager.default.removeItem(at:file)
    let saved=try store.repository.load(before.id);XCTAssertEqual(saved.objects.last?.meshAsset,reference)
    let document=try ModelAssetCoordinator.readAsset(reference,assets:assets);XCTAssertEqual(document.sourceData,raw);XCTAssertEqual(document.triangleCount,1)
    store.undo();XCTAssertEqual(store.project,before);store.redo();XCTAssertEqual(store.project?.objects.first(where:{$0.id==object.id})?.meshAsset,reference)
  }
  func testCameraChangeDoesNotStaleImportButGenuineSourceChangeAndEpochRoundtripDo()async throws {
    let(store,_,file)=try fixture(),job=try await ready(store,file)
    store.engine.project?.camera.azimuth=0.7;_ = try await publish(store,job)
    let next=try await ready(store,file),source=store.project!
    try store.engine.edit("Changed source"){$0.subtitle="A real source edit"};let changed=store.project!
    XCTAssertThrowsError(try store.modelAssets.commit(next));XCTAssertEqual(store.project,changed)
    store.engine.project=source
    let roundtrip=try await ready(store,file);store.invalidateArtworkTransferProject()
    XCTAssertThrowsError(try store.modelAssets.commit(roundtrip));XCTAssertEqual(store.project,source)
  }
  func testSlotOverridesAndUVLinksAreOneUndoAndDoNotChangeGeometryAssets()async throws {
    let(store,_,file)=try fixture(),job=try await ready(store,file),object=try await publish(store,job),before=store.project!,reference=object.meshAsset!,source=before.objects.first!
    _=try store.modelAssets.call(["command":"material","object_id":object.id.uuidString,"material_index":0,"color":"#D45A37","roughness":0.2])
    var current=try XCTUnwrap(store.project?.objects.first{$0.id==object.id});XCTAssertEqual(current.meshAsset?.normalizedSHA256,reference.normalizedSHA256);XCTAssertEqual(current.meshAsset?.materialOverrides.first?.colorHex,"#D45A37")
    _=try store.modelAssets.call(["command":"material","object_id":object.id.uuidString,"material_index":0,"roughness":0.4])
    XCTAssertEqual(store.project?.objects.first{$0.id==object.id}?.meshAsset?.materialOverrides.first?.colorHex,"#D45A37")
    store.undo()
    store.undo();XCTAssertEqual(store.project,before)
    _=try store.modelAssets.call(["command":"artwork","object_id":object.id.uuidString,"material_index":0,"source_object_id":source.id.uuidString])
    current=try XCTUnwrap(store.project?.objects.first{$0.id==object.id});XCTAssertEqual(current.artworkSourceID,source.id);XCTAssertEqual(current.meshAsset?.artworkSizeMM,.init(width:180,height:100));XCTAssertEqual(current.meshAsset?.artworkBindings.count,1);XCTAssertEqual(current.meshAsset?.normalizedSHA256,reference.normalizedSHA256)
    store.undo();XCTAssertEqual(store.project,before)
    XCTAssertThrowsError(try store.modelAssets.call(["command":"material","object_id":object.id.uuidString,"material_index":99,"color":"#D45A37"]))
    XCTAssertThrowsError(try store.modelAssets.call(["command":"material","object_id":object.id.uuidString,"material_index":99,"clear":true]))
    XCTAssertThrowsError(try store.modelAssets.call(["command":"material","object_id":object.id.uuidString,"material_index":0,"color":false]))
    XCTAssertThrowsError(try store.modelAssets.call(["command":"artwork","object_id":object.id.uuidString,"material_index":0,"source_object_id":source.id.uuidString,"primitive_ids":"all"]))
    XCTAssertEqual(store.project,before)
  }
  func testCancellationAndCorruptNormalizedResourceNeverPublishGeometry()async throws {
    let(store,_,file)=try fixture(),before=store.project!
    let cancelled=try store.modelAssets.beginImport(url:file,sourceUnit:nil,name:nil,present:false);store.modelAssets.cancel(cancelled)
    try await Task.sleep(for:.milliseconds(50));XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty);XCTAssertNil(cancelled.document)
    let job=try await ready(store,file),object=try await publish(store,job),reference=object.meshAsset!,assets=store.repository.url(for:before.id).appendingPathComponent("Assets")
    try Data("corrupt".utf8).write(to:assets.appendingPathComponent(reference.normalizedAsset));XCTAssertThrowsError(try ModelAssetCoordinator.readAsset(reference,assets:assets))
  }
  func testPreparedSceneTransformsReuseGeometryAndTransparentUVArtworkRetainsBase()async throws {
    let(store,_,file)=try fixture(),job=try await ready(store,file),scene=try XCTUnwrap(job.preparedScene)
    var reference=try XCTUnwrap(job.reference)
    let first=try MeshAssetSceneAdapter.appearance(scene,reference:reference),a=MeshAssetSceneAdapter.renderables(first,objectID:UUID()),b=MeshAssetSceneAdapter.renderables(first,objectID:UUID(),positionMM:.init(50,20,10),yawDegrees:30,scalePercent:150)
    XCTAssertEqual(a.first?.mesh.id,b.first?.mesh.id);XCTAssertEqual(a.first?.mesh.revision,b.first?.mesh.revision);XCTAssertEqual(a.first?.mesh.positionsMM,b.first?.mesh.positionsMM)
    XCTAssertNotEqual(a.first?.transform,b.first?.transform);XCTAssertEqual(a.first?.materials.first?.colorEncoding,.linearSRGB)
    reference.artworkBindings=[.init(materialIndex:0)]
    var pixels=[UInt8](repeating:0,count:8*8*4)
    for y in 0..<8 {for x in 0..<4 {let i=(y*8+x)*4;pixels[i]=255;pixels[i+3]=255}}
    let provider=try XCTUnwrap(CGDataProvider(data:Data(pixels) as CFData)),image=try XCTUnwrap(CGImage(width:8,height:8,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:32,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent))
    let composite=try MeshAssetSceneAdapter.appearance(scene,reference:reference,artwork:image,artworkRevision:"version1"),texture=try XCTUnwrap(composite.components.first?.material.baseColorTexture),bytes=try XCTUnwrap(texture.image.dataProvider?.data) as Data
    XCTAssertEqual(texture.image.width,8);XCTAssertGreaterThan(bytes[0],240);XCTAssertLessThan(bytes[1],10)
    let last=7*4;XCTAssertGreaterThan(bytes[last],240);XCTAssertGreaterThan(bytes[last+1],240);XCTAssertGreaterThan(bytes[last+2],240);XCTAssertEqual(bytes[last+3],255)
    let next=try MeshAssetSceneAdapter.appearance(scene,reference:reference,artwork:image,artworkRevision:"version2")
    XCTAssertEqual(composite.components.first?.mesh.revision,next.components.first?.mesh.revision);XCTAssertNotEqual(composite.components.first?.material.revision,next.components.first?.material.revision)
  }

  func testResizedUVSourceDetachesAndDuplicatesWithoutInventingPhysicalCalibration()async throws {
    let(store,root,file)=try fixture(),job=try await ready(store,file),object=try await publish(store,job),source=store.project!.objects.first!
    _=try store.modelAssets.call(["command":"artwork","object_id":object.id.uuidString,"material_index":0,"source_object_id":source.id.uuidString])
    try store.engine.edit("Resize artwork source") {project in
      let index=project.objects.firstIndex{$0.id==source.id}!;project.objects[index].parameters["width"]=240;project.objects[index].parameters["depth"]=160
    }
    let current=try XCTUnwrap(store.project?.objects.first{$0.id==object.id}),expected=store.project!.editableArtwork(current)
    XCTAssertEqual(store.project!.artworkSize(current),.init(240,160))
    _=try store.engine.call("form_duplicate_object",arguments:["object_id":object.id.uuidString,"mode":"iteration"])
    let duplicate=try XCTUnwrap(store.project?.objects.last)
    XCTAssertNil(duplicate.artworkSourceID);XCTAssertEqual(duplicate.artwork,expected);XCTAssertEqual(duplicate.meshAsset?.artworkSizeMM,.init(width:240,height:160));XCTAssertEqual(duplicate.meshAsset?.normalizedSHA256,current.meshAsset?.normalizedSHA256)
    try store.engine.edit("Detach imported UV source") {project in try project.linkArtwork(object.id,sourceID:nil)}
    let detached=try XCTUnwrap(store.project?.objects.first{$0.id==object.id})
    XCTAssertNil(detached.artworkSourceID);XCTAssertEqual(detached.artwork,expected);XCTAssertEqual(detached.artworkSize,.init(240,160))
    XCTAssertThrowsError(try store.exportArtwork(object:detached,arguments:["format":"pdf","path":root.appendingPathComponent("unverified.pdf").path]))
    XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("unverified.pdf").path))
    XCTAssertThrowsError(try store.project!.decorationSourceSnapshot(objectID:detached.id))
    XCTAssertFalse(detached.meshAsset!.artworkBindings[0].physicalScaleVerified)
  }

  func testSourceChangeDuringDetachedPublicationRollsBackOnlyItsStagedResources()async throws {
    let(store,_,file)=try fixture(),job=try await ready(store,file),reference=try XCTUnwrap(job.reference),assets=store.repository.url(for:store.project!.id).appendingPathComponent("Assets")
    store.modelAssets.publicationCheckpoint={try? await Task.sleep(for:.milliseconds(80))}
    try store.modelAssets.commit(job)
    XCTAssertEqual(job.state,"publishing");XCTAssertEqual(store.project!.objects.count,1)
    try store.engine.edit("Changed source during disk staging"){$0.subtitle="New source revision"}
    for _ in 0..<400 {if job.state != "publishing" {break};try await Task.sleep(for:.milliseconds(10))}
    XCTAssertEqual(job.state,"failed");XCTAssertEqual(store.project!.objects.count,1)
    XCTAssertFalse(FileManager.default.fileExists(atPath:assets.appendingPathComponent(reference.sourceAsset).path));XCTAssertFalse(FileManager.default.fileExists(atPath:assets.appendingPathComponent(reference.normalizedAsset).path))
    XCTAssertEqual(store.engine.undoStack.count,1)
  }

  func testDerivedTexturedColorwaysAreVisibleLocalAndClearRestoresOriginalSource()async throws {
    let(store,_,file)=try fixture(textured:true),job=try await ready(store,file),scene=try XCTUnwrap(job.preparedScene),original=try Data(contentsOf:file)
    var reference=try XCTUnwrap(job.reference)
    let source=try MeshAssetSceneAdapter.appearance(scene,reference:reference),sourceTexture=try XCTUnwrap(source.components[0].material.baseColorTexture)
    reference.materialOverrides=[.init(materialIndex:0,colorHex:"#C56836")]
    let red=try MeshAssetSceneAdapter.appearance(scene,reference:reference)
    reference.materialOverrides=[.init(materialIndex:0,colorHex:"#32483B")]
    let green=try MeshAssetSceneAdapter.appearance(scene,reference:reference)
    func color(_ appearance:MeshAssetSceneAppearance,_ x:Int)throws->NSColor {let image=try XCTUnwrap(appearance.components[0].material.baseColorTexture?.image);return try XCTUnwrap(NSBitmapImageRep(cgImage:image).colorAt(x:x,y:0)?.usingColorSpace(.sRGB))}
    let r=try color(red,0),g=try color(green,0)
    XCTAssertGreaterThan(r.redComponent,r.greenComponent*1.5);XCTAssertGreaterThan(g.greenComponent,g.redComponent*1.2);XCTAssertGreaterThan(r.redComponent,0.3)
    XCTAssertNotEqual(try color(red,0).redComponent,try color(red,1).redComponent)
    XCTAssertEqual(source.components[1].material.id,red.components[1].material.id);XCTAssertEqual(source.components[1].material.revision,red.components[1].material.revision)
    XCTAssertEqual(red.components[1].material.revision,green.components[1].material.revision)
    XCTAssertEqual(source.components[0].mesh.revision,red.components[0].mesh.revision);XCTAssertEqual(red.components[0].mesh.revision,green.components[0].mesh.revision)
    XCTAssertEqual(source.components[0].material.normalTexture?.revision,red.components[0].material.normalTexture?.revision);XCTAssertEqual(source.components[0].material.metallicTexture?.revision,red.components[0].material.metallicTexture?.revision)
    reference.materialOverrides=[]
    let restored=try MeshAssetSceneAdapter.appearance(scene,reference:reference)
    XCTAssertEqual(restored.components[0].material.baseColorTexture?.revision,sourceTexture.revision);XCTAssertEqual(restored.components[0].material.revision,source.components[0].material.revision);XCTAssertEqual(try Data(contentsOf:file),original)
    XCTAssertEqual(job.document?.sourceData,original)
  }
  func testImportPlacementClearsExistingRotatedPhysicalBoundsWithoutChangingSource()async throws {
    let(store,_,file)=try fixture(),source=try Data(contentsOf:file)
    try store.engine.edit("Existing rotated product") {project in
      var box=try project.makeObject(recipeID:"box",parameters:["width":40,"depth":240,"height":30]);box.position = .init(400,0,100);box.rotation=90;project.objects.append(box)
    }
    let job=try await ready(store,file),reference=try XCTUnwrap(job.reference),object=try await publish(store,job)
    XCTAssertEqual(object.position.x,400+120+25+reference.boundsMM.size.x/2,accuracy:0.00001);XCTAssertEqual(object.position.y,0);XCTAssertEqual(object.position.z,0)
    XCTAssertEqual(object.meshAsset?.boundsMM,reference.boundsMM);XCTAssertEqual(ModelAssetCoordinator.sourceToTableOffset(reference),.init(-reference.boundsMM.size.x/2,0,0));XCTAssertEqual(try Data(contentsOf:file),source)
  }

}

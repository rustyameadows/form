import AppKit
import FormCore
import LabRendering
import XCTest
@testable import FormApp

@MainActor final class CyclesArtworkAssetGenerationTests:XCTestCase {
  private func image(_ color:NSColor,to url:URL)throws {
    let rgb=try XCTUnwrap(color.usingColorSpace(.sRGB))
    let context=try XCTUnwrap(CGContext(data:nil,width:16,height:16,bitsPerComponent:8,bytesPerRow:64,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red:rgb.redComponent,green:rgb.greenComponent,blue:rgb.blueComponent,alpha:1)
    context.fill(.init(x:0,y:0,width:16,height:16))
    // Assert the explicitly sRGB context samples before AppKit assigns its
    // calibrated bitmap profile during conversion to NSBitmapImageRep.
    let pixel=try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self),index=8*context.bytesPerRow+8*4
    XCTAssertEqual(Double(pixel[index])/255,Double(rgb.redComponent),accuracy:1.0/255)
    XCTAssertEqual(Double(pixel[index+1])/255,Double(rgb.greenComponent),accuracy:1.0/255)
    let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url)
  }
  private enum Effect:Equatable {case none,legacyBlur,nativeBlur}
  private func source(effect:Effect = .none)throws->(StudioStore,Project,ProductObject,StudioShot,URL,URL) {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("cycles-artwork-generation-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    var project=Project(name:"Linked image render contract"),artboard=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":100])
    var element=ArtworkElement(kind:"image",x:0,y:0,width:100,height:100);element.asset="linked-image.png"
    if effect == .legacyBlur {element.blur = .init()}
    if effect == .nativeBlur {element.effectStack = .init(effects:[.init(kind:"blur",blur:1)])}
    artboard.artwork=Artwork(elements:[element])
    var object=try project.makeObject(recipeID:"box",parameters:["width":100,"depth":100,"height":50])
    object.artworkSourceID=artboard.id;object.artworkFit="fit";project.objects=[artboard,object]
    project.camera.viewportAspect=1.5
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    try image(.red,to:assets.appendingPathComponent("linked-image.png"))
    store.engine.project=project;store.showingHome=false
    var shot=StudioShot(name:"Linked artwork",camera:project.camera,referenceAspect:1.5)
    shot.visibility = .init(mode:.objects,objectIDs:[object.id]);shot.pixels = .init(width:192,height:128)
    addTeardownBlock{ @MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return(store,project,object,shot,assets,root)
  }
  private func colors(_ snapshot:SceneSnapshot,objectID:UUID)->[NSColor] {
    snapshot.renderables.filter{$0.objectID==objectID}.flatMap(\.materials).compactMap {material in
      guard let image=(material.artworkTexture ?? material.baseColorTexture)?.image else{return nil}
      return NSBitmapImageRep(cgImage:image).colorAt(x:image.width/2,y:image.height/2)?.usingColorSpace(.deviceRGB)
    }
  }
  func testFinalSnapshotUsesChangedLinkedImageBytesAndMatchingProvenanceWithoutMutatingLiveScene()async throws {
    try await checkChangedImage(effect:.none)
  }
  func testFinalSnapshotInvalidatesLegacyAndNativeBlurCompositesForChangedLinkedImage()async throws {
    try await checkChangedImage(effect:.legacyBlur)
    try await checkChangedImage(effect:.nativeBlur)
  }
  private func checkChangedImage(effect:Effect)async throws {
    let (store,project,object,shot,assets,_)=try source(effect:effect),preparer=StudioShotRenderer(),settings=CyclesRenderSettings()
    store.scene=TableSceneController(store:store);store.synchronizeScene()
    let live=try XCTUnwrap(store.scene)
    let initialNode=try XCTUnwrap(live.objectRoot.childNode(withName:"object:"+object.id.uuidString,recursively:false))
    let firstResources=try StudioShotRenderer.resources(project:project,assets:assets)
    XCTAssertEqual(firstResources.compactMap{$0["id"]},["asset:linked-image.png"])
    XCTAssertEqual(try StudioShotRenderer.resources(project:project,assets:assets.resolvingSymlinksInPath()),firstResources)
    let first=try await preparer.cyclesTableSnapshot(project:project,shot:shot,assets:assets,settings:settings,live:live,resources:firstResources)
    XCTAssertTrue(colors(first,objectID:object.id).contains{$0.redComponent>0.8 && $0.greenComponent<0.2})
    let file=assets.appendingPathComponent("linked-image.png"),timestamp=try file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate!
    try image(.green,to:file);try FileManager.default.setAttributes([.modificationDate:timestamp],ofItemAtPath:file.path)
    let nextResources=try StudioShotRenderer.resources(project:project,assets:assets)
    XCTAssertNotEqual(firstResources,nextResources)
    let next=try await preparer.cyclesTableSnapshot(project:project,shot:shot,assets:assets,settings:settings,live:live,resources:nextResources)
    let nextColors=colors(next,objectID:object.id)
    XCTAssertTrue(nextColors.contains{$0.greenComponent>0.8 && $0.redComponent<0.2})
    XCTAssertFalse(nextColors.contains{$0.redComponent>0.8 && $0.greenComponent<0.2},"A warm texture must not retain old image pixels under new resource hashes.")
    XCTAssertNotEqual(next.revision,first.revision)
    XCTAssertTrue(live.objectRoot.childNode(withName:"object:"+object.id.uuidString,recursively:false) === initialNode);XCTAssertEqual(store.project,project)
    let generation=GeometryFactory.fontRevision
    _ = try await preparer.cyclesSnapshot(project:project,shot:shot,assets:assets,settings:settings,resources:nextResources)
    XCTAssertEqual(GeometryFactory.fontRevision,generation,"Unchanged hashes must preserve the shared raster generation.")
  }
  func testDeletedLinkedImageRejectsWarmFinalBeforeCreatingDestination()async throws {
    let (store,project,_,shot,assets,root)=try source(),preparer=StudioShotRenderer()
    _ = try await preparer.cyclesSnapshot(project:project,shot:shot,assets:assets,settings:.init())
    try FileManager.default.removeItem(at:assets.appendingPathComponent("linked-image.png"))
    let exports=store.repository.url(for:project.id).appendingPathComponent("Exports",isDirectory:true)
    try FileManager.default.createDirectory(at:exports,withIntermediateDirectories:true)
    let output=exports.appendingPathComponent("missing-linked-image.render")
    do {_ = try await store.cycles.renderShot(shot,to:output);XCTFail("A cached linked image must not conceal its missing source.")}
    catch {XCTAssertTrue(error.localizedDescription.contains("linked-image.png"),error.localizedDescription)}
    XCTAssertFalse(FileManager.default.fileExists(atPath:output.path));XCTAssertEqual(store.project,project)
    let paths=(FileManager.default.enumerator(atPath:root.path)?.allObjects as? [String]) ?? []
    XCTAssertFalse(paths.contains{$0.contains(".renderpartial")})
  }
}

import AppKit
import CryptoKit
import FormCore
import FormGeometry
import ImageIO
import LabRendering
import XCTest
@testable import FormApp

@MainActor final class CyclesScenePreparationTests:XCTestCase {
  /// Optional external evidence: uses the ordinary complete Table preparation,
  /// reads an arbitrary supplied package and writes only temporary render data.
  func testOptionalProjectTableTextureTransferBudget()async throws {
    guard let path=ProcessInfo.processInfo.environment["LAB_CYCLES_TEST_PROJECT"] else {
      throw XCTSkip("Set LAB_CYCLES_TEST_PROJECT to run the read-only external project transfer diagnostic.")
    }
    _=NSApplication.shared
    let package=URL(fileURLWithPath:path),root=FileManager.default.temporaryDirectory.appendingPathComponent("cycles-project-budget-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
    let capturedAt=ISO8601DateFormatter().string(from:Date()),capturedManifest=try Data(contentsOf:package.appendingPathComponent("Manifest.json"))
    let captured=root.appendingPathComponent("source"),objects=captured.appendingPathComponent("Objects")
    try FileManager.default.createDirectory(at:objects,withIntermediateDirectories:true)
    try capturedManifest.write(to:captured.appendingPathComponent("Manifest.json"))
    let rawManifest=try XCTUnwrap(JSONSerialization.jsonObject(with:capturedManifest) as? [String:Any])
    for reference in try XCTUnwrap(rawManifest["objects"] as? [[String:Any]]) {
      let name=try XCTUnwrap(reference["file"] as? String)
      guard !name.contains("/"),name.hasSuffix(".json") else {throw FormError.invalid("Invalid object reference in diagnostic source.")}
      try Data(contentsOf:package.appendingPathComponent("Objects").appendingPathComponent(name)).write(to:objects.appendingPathComponent(name))
    }
    // The atomic manifest names immutable object files. Capture exactly that
    // generation while another client may continue saving the original project.
    let project=try ProjectRepository(root:root.appendingPathComponent("repository")).load(url:captured)
    let controller=TableSceneController(),settings=CyclesRenderSettings(),assets=package.appendingPathComponent("Assets")
    controller.sync(project,selection:[],isolated:[],showGrid:false,studio:false,preset:"Paper",assets:assets)
    let snapshot=try await controller.cyclesSnapshot(settings:settings)
    let output=root.appendingPathComponent("transfer"),configuration=LabCyclesRuntime.configuration(settings,pixels:.init(width:1280,height:800),preview:true)
    let manifest=try CyclesSceneManifest.write(snapshot:snapshot,settings:configuration,jobID:UUID(),directory:output)
    let document=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
    var textureReferences=0,paths=Set<String>()
    func visit(_ value:Any) {
      if let object=value as? [String:Any] {
        if let path=object["path"] as? String,(path.hasSuffix(".png") || path.hasSuffix(".rgba32f")) {textureReferences+=1;paths.insert(path)}
        object.values.forEach(visit)
      } else if let values=value as? [Any] {values.forEach(visit)}
    }
    visit(document)
    var textureBytes=0,geometryBytes=0,records=[[String:Any]]()
    for name in paths.sorted() {
      let url=output.appendingPathComponent(name),size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
      let decoded:Int
      if name.hasSuffix(".rgba32f") {decoded=size}
      else {
        let source=try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil)),image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        decoded=image.width*image.height*4
      }
      textureBytes+=decoded;records.append(["path":name,"decodedBytes":decoded,"fileBytes":size])
    }
    for url in try FileManager.default.contentsOfDirectory(at:output,includingPropertiesForKeys:[.fileSizeKey]) where url.pathExtension=="bin" {
      geometryBytes+=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
    }
    XCTAssertLessThanOrEqual(textureBytes+geometryBytes,1_073_741_824)
    let report:[String:Any]=["projectID":project.id.uuidString,"capturedAt":capturedAt,"manifestSHA256":SHA256.hash(data:capturedManifest).map{String(format:"%02x",$0)}.joined(),"sourceDesignDigest":try project.studioDesignDigest(),"snapshotRevision":snapshot.revision,
      "physicalObjects":project.tablePresentationObjects.count,"renderables":snapshot.renderables.count,"curves":snapshot.curves.count,
      "triangles":snapshot.renderables.reduce(0){$0+$1.mesh.triangleCount},"textureReferences":textureReferences,"uniqueTextures":paths.count,
      "decodedTextureBytes":textureBytes,"geometryBytes":geometryBytes,"totalBudgetBytes":textureBytes+geometryBytes,
      "transferBudgetBytes":1_073_741_824,"downsampled":false,"textures":records]
    if let destination=ProcessInfo.processInfo.environment["LAB_CYCLES_PROJECT_BUDGET_REPORT"] {
      let url=URL(fileURLWithPath:destination);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
      try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }
    print("Read-only Table transfer diagnostic: \(project.tablePresentationObjects.count) objects, \(paths.count) unique textures, \(textureBytes+geometryBytes) / 1073741824 bytes.")
  }
  func testLiveSnapshotKeepsPhysicalObjectsAndCameraButExcludesEditorGraphics()async throws {
    _=NSApplication.shared
    var project=Project(name:"Render contracts")
    var object=try project.makeObject(recipeID:"box",name:"Solid",parameters:["width":180,"depth":120,"height":100])
    object.position = .init(32,18,-21);project.objects=[object];project.camera.viewportAspect=1.5
    let before=project,scene=TableSceneController(),assets=FileManager.default.temporaryDirectory
    scene.sync(project,selection:[object.id],isolated:[],showGrid:true,studio:false,preset:"Paper",assets:assets)
    let settings=CyclesRenderSettings(),snapshot=try await scene.cyclesSnapshot(settings:settings)
    XCTAssertEqual(snapshot.projectID,project.id)
    let physicalFloor=try XCTUnwrap(snapshot.renderables.first{scene.adapter.nodes[$0.componentID] === scene.floorNode})
    XCTAssertEqual(physicalFloor.transform.translationMM.y,0)
    XCTAssertEqual(scene.floorNode.position.y,-0.008,"The Fast editor keeps its own Z-fighting clearance.")
    XCTAssertTrue(snapshot.renderables.contains{$0.objectID==object.id})
    XCTAssertFalse(snapshot.renderables.contains{$0.componentID.contains("selection") || $0.componentID.contains("grid")})
    XCTAssertTrue(snapshot.renderables.allSatisfy{$0.visible})
    XCTAssertEqual(snapshot.camera.worldFromCameraMM,scene.cameraPayload().worldFromCameraMM)
    XCTAssertEqual(project,before)
    let first=try scene.cyclesSceneKey(settings:settings),geometry=snapshot.renderables.map(\.mesh.revision)
    scene.camera.target.x+=24;scene.updateCamera()
    let navigated=try await scene.cyclesSnapshot(settings:settings)
    XCTAssertNotEqual(try scene.cyclesSceneKey(settings:settings),first)
    XCTAssertEqual(navigated.renderables.map(\.mesh.revision),geometry,"Navigation must retain prepared physical geometry.")
    object.position.x+=48;project.objects=[object]
    scene.sync(project,selection:[],isolated:[],showGrid:false,studio:false,preset:"Paper",assets:assets)
    let moved=try await scene.cyclesSnapshot(settings:settings)
    XCTAssertNotEqual(moved.revision,navigated.revision)
    XCTAssertNotEqual(moved.renderables.first{$0.objectID==object.id}?.transform,navigated.renderables.first{$0.objectID==object.id}?.transform)
  }
  func testSettingsPreservePreviewBoundsAndPhysicalDicing()throws {
    var settings=CyclesRenderSettings();settings.displacementDicingRate=3.25;settings.displacementMaxSubdivisions=5
    settings.displacementMaxTriangles=345678;settings.exposure = -1.25
    let preview=LabCyclesRuntime.configuration(settings,pixels:.init(width:3000,height:2000),preview:true)
    XCTAssertEqual(preview.width,1280);XCTAssertLessThanOrEqual(preview.height,1280)
    XCTAssertEqual(preview.samples,64);XCTAssertEqual(preview.adaptiveThreshold,0.05)
    let final=LabCyclesRuntime.configuration(settings,pixels:.init(width:3000,height:2000),preview:false)
    XCTAssertEqual(final.width,3000);XCTAssertEqual(final.height,2000);XCTAssertEqual(final.samples,512)
    XCTAssertEqual(final.displacementDicingRate,3.25);XCTAssertEqual(final.displacementMaxTriangles,345678)
    XCTAssertEqual(final.displacementMaxSubdivisions,5);XCTAssertEqual(final.exposureEV,-1.25)
    XCTAssertEqual(final.device,.metal,"New native renders default to Metal; fallback requires Automatic mode.")
  }
  func testTableFinalSnapshotFreezesDisplayedClothWithoutCommittingOrResettingIt()async throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("cycles-table-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    defer{store.cloth.preview.reset();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    var project=Project(name:"Displayed cloth"),cloth=try project.makeObject(recipeID:"clothPanel")
    cloth.cloth!.settings.frameStepSeconds=1/60;project.objects=[cloth];project.camera.viewportAspect=1.5
    store.engine.project=project;store.scene=TableSceneController(store:store);store.synchronizeScene()
    try store.cloth.activate(cloth.id);try store.cloth.preview.stepImmediately(frames:3)
    let source=try XCTUnwrap(store.project),frame=try XCTUnwrap(store.cloth.preview.frame),live=try XCTUnwrap(store.scene)
    let settings=CyclesRenderSettings(),displayed=try await live.cyclesSnapshot(settings:settings)
    let component=try XCTUnwrap(displayed.renderables.first{$0.componentID.contains("cloth.surface")})
    let shot=StudioShot(name:"Table",camera:source.camera,referenceAspect:1.5)
    let frozen=try await StudioShotRenderer().cyclesTableSnapshot(project:source,shot:shot,assets:root.appendingPathComponent("Assets"),settings:settings,live:live)
    let prepared=try XCTUnwrap(frozen.renderables.first{$0.componentID==component.componentID})
    XCTAssertEqual(prepared.mesh.positionsMM,component.mesh.positionsMM)
    XCTAssertEqual(prepared.transform,component.transform)
    XCTAssertEqual(frozen.revision.count,64)
    XCTAssertEqual(store.project,source);XCTAssertEqual(store.cloth.preview.frame,frame)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertThrowsError(try store.studioShots.runtimePreflight(source,shot),"Saved shots still require committed cloth.")
  }
  func testPhysicalCaliperUsesOriginalTopologyAndDistinctBackWithoutChangingFastMesh()throws {
    let scene=MeshScene(),front=MeshMaterial(),back=MeshMaterial()
    front.diffuse.contents=NSColor.blue;front.physicalThicknessMM=0.6
    back.diffuse.contents=NSColor.red;back.roughness.contents=0.9;front.physicalBackMaterial=back
    let geometry=MeshGeometry(sources:[
      .init(vertices:[.init(0,0,0),.init(1,0,0),.init(1,1,0),.init(0,1,0)]),
      .init(normals:Array(repeating:.init(0,0,1),count:4)),
      .init(textureCoordinates:[.init(x:0,y:0),.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)])
    ],elements:[.init(indices:[UInt32(0),1,2,0,2,3],primitiveType:.triangles)])
    geometry.materials=[front];scene.rootNode.addChildNode(.init(geometry:geometry))
    let adapter=GeometryPayloadAdapter(),fast=try XCTUnwrap(adapter.renderables(scene:scene).first)
    let physical=try XCTUnwrap(adapter.pathTracingRenderables(scene:scene,assets:FileManager.default.temporaryDirectory).first)
    XCTAssertEqual(fast.mesh.triangleCount,2);XCTAssertEqual(physical.mesh.triangleCount,12)
    XCTAssertEqual(physical.materials.count,3);XCTAssertEqual(physical.materials[1].baseColor.x,1,accuracy:1e-6)
    XCTAssertEqual(physical.materials[1].roughness,0.9,accuracy:1e-6)
    XCTAssertEqual(physical.mesh.positionsMM[0].z,0.3,accuracy:1e-9)
    XCTAssertEqual(physical.mesh.positionsMM[4].z,-0.3,accuracy:1e-9)
    XCTAssertEqual(geometry.sources(for:.vertex).first?.vectorCount,4)
    XCTAssertEqual(adapter.renderables(scene:scene).first?.mesh.triangleCount,2)
  }
  func testPresetLightsKeepTheirActualStateAndInvalidateOnFillOrFloorChanges()async throws {
    _=NSApplication.shared
    var project=Project(name:"Physical preset contract");project.objects=[try project.makeObject(recipeID:"box")]
    let scene=TableSceneController(),settings=CyclesRenderSettings()
    scene.sync(project,selection:[],isolated:[],showGrid:false,studio:true,preset:"Graphite",assets:FileManager.default.temporaryDirectory)
    scene.applyShotLighting("classic-v1",studio:true)
    let classic=try await scene.cyclesSnapshot(settings:settings)
    XCTAssertEqual(classic.lights.map(\.power),[8.25,2.75])
    scene.applyShotLighting("soft-side-v1",studio:true)
    let soft=try await scene.cyclesSnapshot(settings:settings)
    XCTAssertEqual(soft.lights[0].power,8.25*900/850,accuracy:1e-12)
    XCTAssertEqual(soft.lights[1].power,2.75*180/100,accuracy:1e-12)
    XCTAssertEqual(soft.lights[1].transform.columns.3,.init(600,500,-200,1))
    XCTAssertEqual(soft.environment.strength,settings.environmentStrength*250/400,accuracy:1e-12)
    XCTAssertNotEqual(soft.lights[0].color,classic.lights[0].color)
    let before=try scene.cyclesSceneKey(settings:settings)
    let fill=try XCTUnwrap(scene.scene.rootNode.childNodes.first{$0.light?.type == .omni})
    fill.light?.intensity+=10
    let relit=try scene.cyclesSceneKey(settings:settings);XCTAssertNotEqual(relit,before)
    scene.floorNode.geometry?.firstMaterial?.diffuse.contents=NSColor.orange
    XCTAssertNotEqual(try scene.cyclesSceneKey(settings:settings),relit)
    var authored=settings;authored.areaLights=[.init()];authored.areaLights?[0].powerWatts=45
    let explicit=try await scene.cyclesSnapshot(settings:authored)
    XCTAssertEqual(explicit.lights[0].power,45);XCTAssertEqual(explicit.environment.strength,settings.environmentStrength)
  }
  func testTableFinalPreservesDisplayedPresentationFloor()async throws {
    _=NSApplication.shared
    var project=Project(name:"Table presentation surface");project.objects=[try project.makeObject(recipeID:"box")]
    project.camera.viewportAspect=1.5
    let assets=FileManager.default.temporaryDirectory.appendingPathComponent("cycles-floor-"+UUID().uuidString),live=TableSceneController(),settings=CyclesRenderSettings()
    live.sync(project,selection:[],isolated:[],showGrid:false,studio:true,preset:"Graphite",assets:assets)
    let displayed=try await live.cyclesSnapshot(settings:settings),ids=Set(project.objects.map(\.id))
    let floor=try XCTUnwrap(displayed.renderables.first{!ids.contains($0.objectID)})
    let shot=StudioShot(name:"Table",camera:live.camera,referenceAspect:1.5)
    let final=try await StudioShotRenderer().cyclesTableSnapshot(project:project,shot:shot,assets:assets,settings:settings,live:live)
    let captured=try XCTUnwrap(final.renderables.first{!ids.contains($0.objectID)})
    XCTAssertEqual(captured.materials[0].baseColor,floor.materials[0].baseColor)
    XCTAssertEqual(captured.transform,floor.transform)
    XCTAssertEqual(final.renderables.filter{!ids.contains($0.objectID)}.count,1)
  }
}

import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class StudioPreviewPerformanceTests:XCTestCase {
  private func project(copies:Int=1)throws->(Project,StudioComposition) {
    var project=Project(name:"Repeated products")
    var object=try project.makeObject(recipeID:"box",parameters:["width":100,"height":80,"depth":60])
    object.color="#426DB2"
    object.artwork = .init(elements:[.init(kind:"text",x:5,y:5,width:80,height:20,text:"Shared artwork",fontSize:16)])
    project.objects=[object]
    var scene=StudioComposition(name:"Saved composition",camera:project.camera)
    scene.camera.distance=4;scene.camera.target = .init(0,0.4,0)
    scene.instances=(0..<copies).map{.init(name:"Product \($0+1)",sourceObjectID:object.id,positionMM:.init(Double($0)*110,0,0))}
    project.studioPresentation = .init();project.studioPresentation?.scenes=[scene]
    return (project,scene)
  }
  private func directory()throws->URL {
    let result=FileManager.default.temporaryDirectory.appendingPathComponent("studio-preview-cache-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:result,withIntermediateDirectories:true)
    addTeardownBlock{try? FileManager.default.removeItem(at:result)};return result
  }

  func testThumbnailKeysAvoidRepeatedSerializationAndIgnoreOnlyNonvisualSceneChanges()throws {
    var (project,scene)=try project(copies:105)
    let cache=StudioSceneThumbnailCache(),assets=try directory()
    cache.synchronize(project:project,assets:assets)
    let key=cache.key(for:scene),revision=cache.revision
    for i in 0..<40 {
      project.camera.azimuth=Double(i);project.updatedAt=Date()
      cache.synchronize(project:project,assets:assets)
      XCTAssertEqual(cache.key(for:scene),key)
    }
    XCTAssertEqual(cache.keyBuildCount,1);XCTAssertEqual(cache.revision,revision)
    scene.name="Renamed saved composition";scene.revision+=1;scene.motion.orbitDegrees=90
    project.studioPresentation?.scenes=[scene];cache.synchronize(project:project,assets:assets)
    XCTAssertEqual(cache.key(for:scene),key);XCTAssertEqual(cache.keyBuildCount,1)
    scene.camera.azimuth+=0.25
    XCTAssertNotEqual(cache.key(for:scene),key,"Saved camera changes still invalidate the actual still")
    let changedCamera=cache.key(for:scene)
    project.objects[0].artwork?.elements[0].text="Changed linked design"
    project.studioPresentation?.scenes=[scene];cache.synchronize(project:project,assets:assets)
    XCTAssertNotEqual(cache.key(for:scene),changedCamera)
    let beforePath=cache.key(for:scene)
    cache.synchronize(project:project,assets:assets.appendingPathComponent("another-assets-folder"))
    XCTAssertNotEqual(cache.key(for:scene),beforePath)
  }

  func testCompletedNativeThumbnailSurvivesWorkspaceSuspensionAndStillRunsRuntimeGuard()async throws {
    _ = NSApplication.shared
    var (project,scene)=try project()
    let cache=StudioSceneThumbnailCache(),assets=try directory()
    defer{cache.reset()}
    cache.synchronize(project:project,assets:assets)
    let image=try await cache.image(for:scene,preflight:{_,_ in})
    XCTAssertEqual(cache.renderCount,1)
    cache.suspend()
    project.objects[0].artwork?.canvasPosition = .init(500,-250)
    project.objects[0].canvasProjectionPositions = ["front":.init(-350,200)]
    project.camera.distance+=10;scene.name="Same saved view, new label";scene.revision+=1
    project.studioPresentation?.scenes=[scene];cache.synchronize(project:project,assets:assets)
    let reused=try await cache.image(for:scene,preflight:{_,_ in})
    XCTAssertTrue(image === reused);XCTAssertEqual(cache.renderCount,1)
    do {_ = try await cache.image(for:scene,preflight:{_,_ in throw FormError.invalid("Unpersisted cloth")});XCTFail("A retained image does not bypass runtime validation")}
    catch {XCTAssertTrue(error.localizedDescription.contains("Unpersisted cloth"))}
    cache.reset();cache.synchronize(project:project,assets:assets)
    _ = try await cache.image(for:scene,preflight:{_,_ in})
    XCTAssertEqual(cache.renderCount,2,"Project reset intentionally drops cached images")
  }

  func testThumbnailSourceIgnoresOnlyCanvasPlacementAcrossStoredSurfaces()throws {
    var (project,scene)=try project()
    var paper=try project.makeObject(recipeID:"tuckCarton")
    var construction=try PaperConstruction.definition(for:paper)
    construction.insideArtwork = .init(elements:[.init(kind:"rectangle",x:1,y:1,width:10,height:10)])
    paper.paperConstruction=construction
    var binding=PhysicalSurfaceArtworkBinding(surfaceID:"detached",sourceObjectID:UUID(),widthMM:20,heightMM:20)
    binding.sourceObjectID=nil;binding.artwork=construction.insideArtwork
    paper.surfaceArtworkBindings=[binding];project.objects.append(paper)
    let original=project,cache=StudioSceneThumbnailCache(),assets=try directory()
    cache.synchronize(project:project,assets:assets)
    let key=cache.key(for:scene)
    for index in project.objects.indices {
      project.objects[index].canvasProjectionPositions=["front":.init(350,-120)]
      project.objects[index].artwork?.canvasPosition = .init(100,200)
      project.objects[index].paperConstruction?.insideArtwork?.canvasPosition = .init(500,600)
      project.objects[index].surfaceArtworkBindings?[0].artwork?.canvasPosition = .init(700,800)
    }
    cache.synchronize(project:project,assets:assets)
    XCTAssertEqual(cache.key(for:scene),key)
    XCTAssertEqual(cache.keyBuildCount,1)
    XCTAssertEqual(StudioPreviewSource.thumbnailDesign(project),StudioPreviewSource.thumbnailDesign(original))
    let moved=project
    project.objects[1].paperConstruction?.insideArtwork?.elements[0].color="#336699"
    cache.synchronize(project:project,assets:assets)
    XCTAssertNotEqual(cache.key(for:scene),key,"Actual printed interior ink remains a thumbnail dependency")
    project=moved;cache.synchronize(project:project,assets:assets)
    let placementKey=cache.key(for:scene)
    project.objects[0].position.x+=10
    cache.synchronize(project:project,assets:assets)
    XCTAssertNotEqual(cache.key(for:scene),placementKey,"Physical object placement is not Canvas placement")
    scene.camera.azimuth+=0.2
    XCTAssertNotEqual(cache.key(for:scene),placementKey)
  }

  func testResolutionCacheReappliesPlacementAndCurrentMetadataWithoutReexpandingFamilies()throws {
    var (project,scene)=try project(copies:24)
    let cache=StudioCompositionResolutionCache()
    let first=try cache.resolve(scene,in:project)
    XCTAssertEqual(first.project,try scene.resolved(in:project).project);XCTAssertEqual(cache.builds,1)
    for index in 0..<20 {
      scene.instances[0].positionMM = .init(Double(index)*7,12,-31)
      scene.instances[0].rotationDegrees=Double(index)*3;scene.instances[0].name="Moved copy"
      scene.camera.azimuth+=0.01;project.camera.distance+=1;project.updatedAt=Date()
      project.studioPresentation?.scenes=[scene]
      let actual=try cache.resolve(scene,in:project),expected=try scene.resolved(in:project)
      XCTAssertEqual(actual.project,expected.project);XCTAssertEqual(actual.visible,expected.visible)
    }
    XCTAssertEqual(cache.builds,1,"Placement updates reuse the source/attachment expansion")
    var alternate=scene;alternate.instances[0].materialID="chalk"
    _ = try cache.resolve(alternate,in:project);XCTAssertEqual(cache.builds,2)
    _ = try cache.resolve(scene,in:project);XCTAssertEqual(cache.builds,2,"Returning to an unchanged saved composition reuses its expansion")
    project.objects[0].artwork?.elements[0].text="Revised source"
    XCTAssertEqual(try cache.resolve(scene,in:project).project,try scene.resolved(in:project).project)
    XCTAssertEqual(cache.builds,3)
    project.objects=[]
    XCTAssertThrowsError(try cache.resolve(scene,in:project),"A removed source cannot survive in a cached preview")
  }

  func testCachedAttachmentIDsAndPlacementMatchUncachedResolution()throws {
    var project=Project(name:"Attached decoration")
    let garment=try project.makeObject(recipeID:"bomberJacket",materialID:"flight-nylon")
    var patch=try project.makeObject(recipeID:"textilePatch",materialID:"patch-twill")
    patch.textile?.attachment = .init(garmentID:garment.id,zone:.leftChest,offset:.init(),rotation:0,clearance:2)
    project.objects=[garment,patch]
    var scene=StudioComposition(name:"Attached product copies",camera:project.camera)
    scene.instances=(0..<8).map{.init(name:"Copy \($0)",sourceObjectID:garment.id)}
    let cache=StudioCompositionResolutionCache()
    _ = try cache.resolve(scene,in:project)
    scene.instances[3].positionMM = .init(60,40,-10);scene.instances[3].rotationDegrees=63
    let actual=try cache.resolve(scene,in:project),expected=try scene.resolved(in:project)
    XCTAssertEqual(actual.project,expected.project);XCTAssertEqual(actual.visible.count,16)
    XCTAssertEqual(cache.builds,1)
    scene.instances[2].visible=false
    XCTAssertEqual(try cache.resolve(scene,in:project).project,try scene.resolved(in:project).project)
    XCTAssertEqual(cache.builds,2)
  }

  func testSelectionReconcileAndCameraChangesSkipGeometrySynchronizationButSourceChangesDoNot()throws {
    _ = NSApplication.shared
    let (project,scene)=try project(copies:12),root=try directory()
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.engine.project=project
    let controller=store.studioComposition
    defer{controller.reset();store.engine.project=nil}
    controller.reconcile()
    let syncs=controller.stageSyncCount,builds=controller.resolutionBuildCount
    for index in 0..<24 {
      controller.selectInstance(scene.instances[index%12].id);controller.reconcile()
    }
    controller.change{$0.camera.azimuth+=0.25}
    XCTAssertEqual(controller.stageSyncCount,syncs)
    XCTAssertEqual(controller.resolutionBuildCount,builds)
    XCTAssertEqual(controller.stage.camera.azimuth,controller.draft?.camera.azimuth)
    XCTAssertEqual(store.project,project);XCTAssertTrue(store.engine.undoStack.isEmpty)
    store.engine.project?.objects[0].color="#B14E36";controller.reconcile()
    XCTAssertEqual(controller.stageSyncCount,syncs+1)
    XCTAssertEqual(controller.resolutionBuildCount,builds+1)
    controller.change{$0.pixels.width=0}
    XCTAssertNotNil(controller.error,"A geometry cache hit must still validate camera/output settings")
    XCTAssertTrue(controller.stage.objectRoot.childNodes.isEmpty)
  }

  func testGlyphValidationChecksEveryUniqueArtworkAndStillRejectsInvalidSecondSource()throws {
    let (project,scene)=try project(copies:24),assets=try directory()
    var resolved=try scene.resolved(in:project)
    let renderer=StudioShotRenderer()
    try renderer.validateCaptureArtwork(project:resolved.project,objectIDs:resolved.visible,assets:assets)
    XCTAssertEqual(renderer.lastValidatedArtworkCount,1)
    let index=try XCTUnwrap(resolved.project.objects.firstIndex{$0.id==scene.instances.last?.id})
    resolved.project.objects[index].artwork?.elements[0].glyphOverrides=[.init(location:999,sourceText:"Q",glyph:.init(fontName:"Georgia",glyphID:1,fontSignature:String(repeating:"a",count:64)))]
    XCTAssertThrowsError(try renderer.validateCaptureArtwork(project:resolved.project,objectIDs:resolved.visible,assets:assets))
    XCTAssertEqual(renderer.lastValidatedArtworkCount,1,"The invalid distinct source must be validated instead of reusing the first source's success")
  }

  func testUntexturedBoxSamplingChangesReuseGeometryButArtworkAndShapeStillInvalidate()throws {
    _ = NSApplication.shared
    var project=Project(name:"Untextured primitive sampling")
    let object=try project.makeObject(recipeID:"box",parameters:["width":60,"height":50,"depth":40])
    project.objects=[object]
    let assets=try directory(),stage=TableSceneController()
    func sync(_ limit:Int,sampling:SourceTextureSamplingPlan?=nil) {
      stage.sync(project,selection:[],isolated:[],showGrid:false,studio:true,preset:"Daylight",assets:assets,
        textureLimit:limit,sourceSampling:sampling.map{[object.id:$0]} ?? [:])
    }
    sync(2048)
    let first=try XCTUnwrap(stage.logicalNode(for:object.id)),builds=stage.geometryBuilds
    sync(256)
    sync(1024,sampling:.init(raster:.init(maximumEdge:1024,maximumPixels:1_048_576),isFinalCapture:true))
    sync(2048)
    XCTAssertTrue(stage.logicalNode(for:object.id) === first)
    XCTAssertEqual(stage.geometryBuilds,builds,"Output sampling cannot change this untextured primitive")
    project.objects[0].parameters["width"]=75
    sync(256)
    XCTAssertEqual(stage.geometryBuilds,builds+1,"Physical geometry remains a cache dependency")
    project.objects[0].artwork = .init(elements:[.init(kind:"rectangle",x:1,y:1,width:20,height:20,color:"#B1462B")])
    sync(128)
    let withArtwork=stage.geometryBuilds
    sync(256)
    XCTAssertEqual(stage.geometryBuilds,withArtwork+1,"Once artwork is present, raster quality must invalidate the geometry/materials")
    XCTAssertTrue(GeometryFactory.usesTextureSampling(project.objects[0],project:project,artwork:project.surfaceArtwork(project.objects[0])))
    let paper=try project.makeObject(recipeID:"tuckCarton")
    XCTAssertTrue(GeometryFactory.usesTextureSampling(paper,project:project,artwork:nil),"Paper stock always retains its texture and relief sampling dependencies")
  }
}

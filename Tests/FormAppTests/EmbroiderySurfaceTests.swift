import AppKit
import Metal
import FormGeometry
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class EmbroiderySurfaceTests:XCTestCase {
  private func fixture()throws -> (Project,UUID,UUID) {
    _ = NSApplication.shared
    var p=Project(name:"Shared needle surfaces")
    var source=try p.makeObject(recipeID:"artboard",parameters:["width":80,"depth":60])
    let line=ArtworkElement(kind:"line",x:10,y:15,width:50,height:0.1,color:"#C75332")
    let star=ArtworkElement(kind:"star",x:30,y:25,width:30,height:28,color:"#285B8A")
    source.artwork=Artwork(background:"#13C927",elements:[line,star],bleed:0)
    var patch=try p.makeObject(recipeID:"textilePatch",name:"Needle face",parameters:["width":80,"depth":60,"corner":3])
    patch.artwork=nil;patch.artworkSourceID=source.id
    var region=EmbroideryRegion(elementIDs:[line.id],method:.satin);region.spacing=0.7;region.satinWidth=3;region.stitchLength=4
    var fill=EmbroideryRegion(elementIDs:[star.id],method:.fill,threadIndex:1);fill.spacing=0.65
    var design=EmbroideryDesign(threads:[.init(name:"Orange",color:line.color),.init(name:"Blue",color:star.color)],regions:[region,fill]);design.process=EmbroideryProcess()
    patch.textile?.embroidery=design
    var copy=patch;copy.id=UUID();copy.designID=UUID();copy.name="Independent process";copy.position.x=120
    p.objects=[source,patch,copy];return (p,patch.id,copy.id)
  }
  private func node(_ scene:TableSceneController,_ id:UUID)throws -> MeshNode {try XCTUnwrap(scene.objectRoot.childNode(withName:"object:\(id.uuidString)",recursively:false))}
  private func face(_ node:MeshNode)throws -> MeshNode {try XCTUnwrap(node.childNode(withName:EmbroiderySceneSurface.faceName,recursively:true))}
  func testSelectedInPlaceThreadAppearanceDoesNotGrowPhysicalBoundsOrFit() throws {
    var (project,id,_)=try fixture()
    project.objects.removeAll{$0.id != id && $0.artworkSourceID != nil}
    let index=try XCTUnwrap(project.objects.firstIndex{$0.id==id}),controller=TableSceneController(),assets=FileManager.default.temporaryDirectory
    defer{controller.renderer?.reset()}
    func sync(){controller.sync(project,selection:[id],isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:assets,textureLimit:128)}
    func coordinates(_ b:(min:MeshVector3,max:MeshVector3))->[Double] {[b.min.x,b.min.y,b.min.z,b.max.x,b.max.y,b.max.z]}
    sync();controller.fitAll()
    let initialBounds=coordinates(try XCTUnwrap(controller.localBounds(for:id))),initialCamera=controller.camera,builds=controller.geometryBuilds
    let original=try node(controller,id),base=try XCTUnwrap(original.childNode(withName:"Independent textile base",recursively:true)),geometry=try XCTUnwrap(base.geometry)
    for diameter in [0.45,0.5,0.4,0.45,0.5,0.4] {
      project.objects[index].textile?.embroidery?.process?.threadDiameter=diameter;sync()
      for (expected,actual) in zip(initialBounds,coordinates(try XCTUnwrap(controller.localBounds(for:id)))) {XCTAssertEqual(actual,expected,accuracy:1e-9)}
      controller.fitAll();XCTAssertEqual(controller.camera,initialCamera)
      XCTAssertTrue(try node(controller,id) === original);XCTAssertTrue(base.geometry === geometry)
    }
    XCTAssertEqual(controller.geometryBuilds,builds,"Thread appearance must stay on the in-place update path.")
  }
  func testSourceProcessAndFontEditsUpdateOnlyFaceMaterialAndShareActualProgram()throws {
    var (p,id,copyID)=try fixture()
    let scene=TableSceneController(),assets=FileManager.default.temporaryDirectory
    func sync() {scene.sync(p,selection:[],isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:assets,textureLimit:320)}
    sync();let builds=scene.geometryBuilds,object=try node(scene,id),other=try node(scene,copyID)
    let base=try XCTUnwrap(object.childNode(withName:"Independent textile base",recursively:true)),geometry=try XCTUnwrap(base.geometry),baseMaterial=try XCTUnwrap(geometry.firstMaterial)
    let first=try face(object),oldImage=try XCTUnwrap(first.geometry?.firstMaterial?.diffuse.contents as? NSImage)
    XCTAssertEqual(first.geometry?.firstMaterial?.name,"Actual generated embroidery")
    XCTAssertNotNil(first.geometry?.firstMaterial?.normal.contents as? NSImage)
    let otherImage=try XCTUnwrap(try face(other).geometry?.firstMaterial?.diffuse.contents as? NSImage)
    let patchIndex=p.objects.firstIndex {$0.id==id}!
    let generated=try EmbroideryDigitizer.generate(object:p.objects[patchIndex],project:p)
    XCTAssertEqual(scene.embroiderySourceDigest(for:id),generated.sourceDigest)
    p.objects[patchIndex].textile?.embroidery?.process?.threadDiameter=0.5;sync()
    XCTAssertEqual(scene.geometryBuilds,builds)
    XCTAssertTrue(try node(scene,id) === object);XCTAssertTrue(base.geometry === geometry);XCTAssertTrue(base.geometry?.firstMaterial === baseMaterial)
    let changed=try face(object);XCTAssertFalse(changed.geometry?.firstMaterial?.diffuse.contents as? NSImage === oldImage)
    XCTAssertTrue(try face(other).geometry?.firstMaterial?.diffuse.contents as? NSImage === otherImage)
    let beforeSource=scene.geometryBuilds
    p.objects[0].artwork!.elements[0].width=38;sync()
    XCTAssertEqual(scene.geometryBuilds,beforeSource+1) // The source frame itself rebuilds; both patch bases do not.
    XCTAssertTrue(try node(scene,id) === object);XCTAssertTrue(try node(scene,copyID) === other)
    let beforeFont=scene.geometryBuilds,programs=EmbroiderySurface.programBuilds
    GeometryFactory.invalidateFontResources();sync()
    XCTAssertEqual(scene.geometryBuilds,beforeFont+1) // Independent source-frame texture refresh.
    XCTAssertGreaterThan(EmbroiderySurface.programBuilds,programs)
    XCTAssertTrue(base.geometry === geometry)
    let idle=EmbroiderySurface.programBuilds,tex=EmbroiderySurface.textureBuilds,count=scene.geometryBuilds
    for _ in 0..<4 {sync()}
    XCTAssertEqual(EmbroiderySurface.programBuilds,idle);XCTAssertEqual(EmbroiderySurface.textureBuilds,tex);XCTAssertEqual(scene.geometryBuilds,count)
    p.objects[patchIndex].position.x+=150;sync()
    XCTAssertEqual(scene.geometryBuilds,count);XCTAssertEqual(EmbroiderySurface.programBuilds,idle)
  }
  func testInvalidProgramIsCachedAndClearlySuppressesPrintedFallbackUntilRecovered()throws {
    var (p,id,_)=try fixture();let scene=TableSceneController(),assets=FileManager.default.temporaryDirectory
    func sync() {scene.sync(p,selection:[],isolated:[],showGrid:false,studio:false,preset:"Daylight",assets:assets,textureLimit:256)}
    sync();let object=try node(scene,id),index=p.objects.firstIndex {$0.id==id}!,valid=p.objects[index].textile!.embroidery!
    p.objects[index].textile?.embroidery?.regions[0].elementIDs=[UUID()];sync()
    XCTAssertNotNil(scene.embroideryIssue(for:id));XCTAssertTrue(try face(object).isHidden)
    XCTAssertNotNil(object.childNode(withName:"Independent textile base",recursively:true))
    let programs=EmbroiderySurface.programBuilds,builds=scene.geometryBuilds
    sync();XCTAssertEqual(EmbroiderySurface.programBuilds,programs);XCTAssertEqual(scene.geometryBuilds,builds)
    p.objects[index].textile?.embroidery=valid;sync()
    XCTAssertNil(scene.embroideryIssue(for:id));XCTAssertFalse(try face(object).isHidden)
    XCTAssertEqual(scene.geometryBuilds,builds)
    p.objects[index].textile?.embroidery=nil;sync()
    XCTAssertEqual(try face(object).geometry?.firstMaterial?.name,nil)
    XCTAssertFalse(try face(object).isHidden);XCTAssertEqual(scene.geometryBuilds,builds)
  }
  func testProcessPreflightAndExportsExposeActualUnderlayTiesAndPreserveSourceUndo()throws {
    let (project,id,_)=try fixture(),root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root);try repository.save(project)
    let store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(project.id);defer {store.engine.project=nil}
    let original=store.project!,object=original.objects.first {$0.id==id}!
    var design=object.textile!.embroidery!;design.regions[0].underlay = .init(method:.centerWalk);design.regions[1].underlay = .init(method:.sparseFill);design.process?.tieIn=true;design.process?.tieOff=true
    _ = try store.engine.call("form_update_object",arguments:["object_id":id.uuidString,"embroidery":try jsonObject(design)],source:"Studio")
    let updated=store.project!;XCTAssertEqual(updated.schemaVersion,28)
    let edited=updated.objects.first {$0.id==id}!
    let result=try store.exportEmbroidery(object:edited,arguments:["format":"preflight"]) as! [String:Any]
    XCTAssertGreaterThan(result["underlay_stitches"] as! Int,10);XCTAssertGreaterThan(result["tie_in_stitches"] as! Int,0);XCTAssertGreaterThan(result["tie_off_stitches"] as! Int,0)
    let folder=ProcessInfo.processInfo.environment["FORM_EMBROIDERY_PROCESS_PROOF_DIR"].map {URL(fileURLWithPath:$0)} ?? root
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    for format in ["dst","json","svg"] {
      _ = try store.exportEmbroidery(object:edited,arguments:["format":format,"path":folder.appendingPathComponent("process."+format).path])
    }
    let svg=try String(contentsOf:folder.appendingPathComponent("process.svg"),encoding:.utf8)
    XCTAssertTrue(svg.contains("data-purpose=\"underlay\""));XCTAssertTrue(svg.contains("data-purpose=\"tieIn\""));XCTAssertTrue(svg.contains("data-purpose=\"tieOff\""))
    XCTAssertEqual(store.project,updated)
    store.engine.undo();XCTAssertEqual(store.project,original);store.engine.redo();XCTAssertEqual(store.project,updated)
  }
  func testNativeSceneRendersActualNeedleSurfaceWithBoundedFaceMaps()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else {throw XCTSkip("Native needle preview requires Metal.")}
    var (p,id,_)=try fixture();p.objects.removeAll {$0.id != id};p.objects[0].artworkSourceID=nil
    let (source,_,_)=try fixture();p.objects[0].artwork=source.objects[0].artwork
    let ids=p.objects[0].artwork!.elements.map(\.id)
    p.objects[0].textile?.embroidery?.regions[0].elementIDs=[ids[0]]
    p.objects[0].textile?.embroidery?.regions[1].elementIDs=[ids[1]]
    let scene=TableSceneController();scene.sync(p,selection:[],isolated:[],showGrid:false,studio:true,preset:"Daylight",assets:FileManager.default.temporaryDirectory,textureLimit:1024)
    scene.camera.target = .init();scene.camera.distance=2;scene.camera.elevation=1.05;scene.camera.azimuth=0.1;scene.updateCamera()
    let rendered=try await scene.snapshot(size:.init(width:1000,height:800));let png=try XCTUnwrap(rendered.pngData());XCTAssertGreaterThan(png.count,10000)
    if let folder=ProcessInfo.processInfo.environment["FORM_EMBROIDERY_PROCESS_PROOF_DIR"] {
      try png.write(to:URL(fileURLWithPath:folder).appendingPathComponent("native-stitch-surface.png"))
    }
    let texture=try XCTUnwrap(try face(try node(scene,id)).geometry?.firstMaterial?.diffuse.contents as? NSImage)
    XCTAssertLessThanOrEqual(texture.representations.first!.pixelsWide,1024)
  }
}

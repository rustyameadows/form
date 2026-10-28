import AppKit
import FormGeometry
import XCTest
@testable import FormCore
@testable import FormGraphics
@testable import FormApp

@MainActor final class PatternAssemblyIntegrationTests:XCTestCase {
  private func fixture(spacing:Double = 22,fullSolver:Bool = true)throws -> (StudioStore,URL,UUID) {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("assembly36-\(UUID().uuidString)"),repository=try ProjectRepository(root:root)
    var (p,d)=try PatternAssemblySamples.roundedPouch();d.maximumEdgeMm=spacing;if !fullSolver {d.settings.substeps=3;d.settings.iterations=3}
    let id=try p.addPatternAssembly(d);try repository.save(p)
    let store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(p.id);store.showingHome=false;store.synchronizeScene()
    return(store,root,id)
  }
  private func call(_ store:StudioStore,_ command:String,_ id:UUID,_ extra:[String:Any] = [:])throws -> [String:Any] {
    var args=extra;args["command"]=command;args["object_id"]=id.uuidString
    let result=try store.bridgeClothCall(args)
    return try XCTUnwrap(result as? [String:Any])
  }
  private func prepare(_ store:StudioStore,_ id:UUID)throws -> [Double] {
    _ = try call(store,"get",id);try store.cloth.activate(id)
    let initial=store.cloth.preview.frame!.positionsMm;var batches:[Double]=[]
    while store.cloth.preview.diagnostics?.preparation?.status != .ready {
      guard batches.count<1024 else{throw FormError.invalid("Native preparation exceeded its bounded batch count.")}
      let t=Date();try store.cloth.preview.stepImmediately();batches.append(Date().timeIntervalSince(t)*1000)
      XCTAssertEqual(store.cloth.preview.diagnostics?.completedFrames,0)
      if store.cloth.preview.diagnostics?.preparation?.status != .ready {XCTAssertEqual(store.cloth.preview.frame?.positionsMm,initial)}
    }
    return batches
  }
  func testNativeRuntimeUsesOneOwnerAndLeavesSourceHistoryDraftsFilesAndCameraUntouched()throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    let before=store.project!,undo=store.engine.undoStack,revision=store.revision,camera=store.scene!.camera,builds=store.scene!.geometryBuilds,meshes=AssemblyProducts.builds,textures=AssemblyMaterialRenderer.textureBuilds
    let file=store.repository.url(for:before.id).appendingPathComponent("Manifest.json"),bytes=try Data(contentsOf:file)
    var commits=0
    let observer=NotificationCenter.default.addObserver(forName:.formCommitArtworkFields,object:nil,queue:.main) {_ in commits+=1};defer {NotificationCenter.default.removeObserver(observer)}
    let get=try call(store,"get",id)
    XCTAssertNotNil(get["assembly"]);XCTAssertEqual(get["derived_mesh_persisted"] as? Bool,false)
    let initial=try call(store,"snapshot",id)
    _ = try prepare(store,id)
    for _ in 0..<3 {_ = try call(store,"step",id,["frames":1])};_ = try call(store,"stop",id)
    XCTAssertEqual(store.cloth.preview.diagnostics?.completedFrames,3)
    let moving=try call(store,"snapshot",id)
    XCTAssertNotEqual(String(describing:initial["mesh"]),String(describing:moving["mesh"]))
    for _ in 0..<5 {_ = try call(store,"get",id)}
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack,undo);XCTAssertEqual(store.revision,revision)
    XCTAssertEqual(try Data(contentsOf:file),bytes);XCTAssertEqual(commits,0);XCTAssertFalse(store.saving)
    XCTAssertEqual(store.scene!.camera,camera);XCTAssertEqual(store.scene!.geometryBuilds,builds)
    XCTAssertEqual(AssemblyProducts.builds,meshes);XCTAssertEqual(AssemblyMaterialRenderer.textureBuilds,textures)
    _ = try call(store,"reset",id);XCTAssertEqual(store.cloth.preview.diagnostics?.completedFrames,0)
    XCTAssertEqual(store.project,before)
  }
  func testSourceCurveAndUndoRebuildFromOriginalWhileBrokenReferenceDropsOldPreview()throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    _ = try call(store,"step",id)
    let before=store.project!,initial=store.cloth.preview.mesh!,digest=store.cloth.preview.source!.revision
    try store.engine.edit("Changed matching source curves") {p in
      p.objects[0].artwork!.elements[0].path!.contours[0].nodes[2].outgoing!.y+=3
      p.objects[0].artwork!.elements[0].path!.contours[0].nodes[5].incoming!.y+=3
    }
    store.changed(save:false);store.synchronizeScene()
    XCTAssertNotEqual(store.cloth.preview.mesh,initial);XCTAssertNotEqual(store.cloth.preview.source?.revision,digest)
    XCTAssertEqual(store.cloth.preview.diagnostics?.completedFrames,0)
    store.undo();XCTAssertEqual(store.project,before);XCTAssertEqual(store.cloth.preview.mesh,initial)
    try store.engine.edit("Changed one source edge") {$0.objects[0].artwork!.elements[0].path!.contours[0].nodes[2].outgoing!.y+=4}
    store.changed(save:false);store.synchronizeScene()
    XCTAssertNil(store.cloth.preview.frame);XCTAssertNotNil(store.cloth.preview.lastError)
    let bad=try call(store,"get",id);XCTAssertNotNil(bad["issue"]);XCTAssertNil(bad["definition"])
    store.undo();XCTAssertEqual(store.project,before);XCTAssertEqual(store.cloth.preview.mesh,initial)
    store.redo();XCTAssertNil(store.cloth.preview.frame)
    XCTAssertThrowsError(try call(store,"step",id))
    store.undo();XCTAssertEqual(store.project,before);XCTAssertEqual(store.cloth.preview.mesh,initial)
  }
  func testPaintAndFontInvalidationDoNotRemeshAndPoseEditingIsOneUndo()throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    _ = try call(store,"step",id);let meshes=AssemblyProducts.builds,source=store.cloth.preview.source!.revision
    try store.engine.edit("Print source") {$0.objects[0].artwork!.elements[2].color="#44AACC"};store.changed(save:false);store.synchronizeScene()
    XCTAssertEqual(AssemblyProducts.builds,meshes);XCTAssertEqual(store.cloth.preview.diagnostics?.completedFrames,0)
    XCTAssertNotEqual(store.cloth.preview.source?.revision,source)
    _ = try call(store,"step",id);GeometryFactory.invalidateFontResources();store.changed(save:false);store.synchronizeScene()
    XCTAssertEqual(AssemblyProducts.builds,meshes);XCTAssertEqual(store.cloth.preview.diagnostics?.completedFrames,0)
    let swatch=ArtworkSwatch(name:"Assembly print",color:"#337799")
    try store.engine.edit("Live print swatch") {p in p.swatches=[swatch];p.objects[0].artwork!.elements[2].fillSwatchID=swatch.id}
    store.changed(save:false);store.synchronizeScene();let oldPaint=store.cloth.preview.source!.revision
    _ = try call(store,"step",id)
    try store.engine.edit("Changed source swatch") {$0.swatches![0].color="#AA4433"}
    store.changed(save:false);store.synchronizeScene()
    XCTAssertNotEqual(store.cloth.preview.source?.revision,oldPaint);XCTAssertEqual(store.cloth.preview.diagnostics?.completedFrames,0);XCTAssertEqual(AssemblyProducts.builds,meshes)
    let before=store.project!;var declaration=before.objects.first{$0.id==id}!.patternAssembly!
    declaration.panels[0].pose.originMm.x+=7
    _ = try call(store,"configure",id,["assembly":try jsonObject(declaration)])
    XCTAssertEqual(store.project!.history.count,before.history.count+1)
    store.undo();XCTAssertEqual(store.project,before)
  }
  func testPhysicalAttachmentSurvivesResolutionAndRuntimeThenReopenKeepsOnlyDeclaration()throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    let before=store.project!,object=before.objects.first{$0.id==id}!,product=try XCTUnwrap(AssemblyProducts.product(for:object,in:before)),panel=try XCTUnwrap(product.panels.first{$0.materialSizeMm.y>100})
    let label=try before.makeObject(recipeID:"textileLabel",parameters:["width":40,"depth":18])
    try store.engine.edit("Label") {$0.objects.append(label)};store.changed(save:false)
    _ = try call(store,"attach",label.id,["surface_object_id":id.uuidString,"panel":panel.panelIndex,"material_x_mm":130,"material_y_mm":80,"offset_mm":2])
    store.synchronizeScene();let originalAnchor=store.project!.objects.last!.patternAssemblyAttachment!.anchor
    let initial=try XCTUnwrap(store.cloth.placement(of:store.project!.objects.last!,in:store.project!))
    _ = try prepare(store,id)
    for _ in 0..<3 {_ = try call(store,"step",id,["frames":1])}
    let moved=try XCTUnwrap(store.cloth.placement(of:store.project!.objects.last!,in:store.project!));XCTAssertNotEqual(initial.positionMm,moved.positionMm)
    var d=store.project!.objects.first{$0.id==id}!.patternAssembly!;d.maximumEdgeMm=36
    _ = try call(store,"configure",id,["assembly":try jsonObject(d)])
    XCTAssertEqual(store.project!.objects.last!.patternAssemblyAttachment!.anchor,originalAnchor)
    let current=try XCTUnwrap(store.cloth.placement(of:store.project!.objects.last!,in:store.project!))
    XCTAssertEqual(current.positionMm.x,initial.positionMm.x,accuracy:1e-7);XCTAssertEqual(current.positionMm.z,initial.positionMm.z,accuracy:1e-7)
    store.save();let reopened=StudioStore(repository:store.repository,seedLibrary:false);try reopened.engine.open(before.id);reopened.showingHome=false
    let get=try call(reopened,"get",id);XCTAssertEqual(get["runtime_persisted"] as? Bool,false);XCTAssertNil(reopened.cloth.preview.frame)
    XCTAssertEqual(reopened.project!.objects.first{$0.id==id}!.patternAssembly,d);XCTAssertNil(reopened.project!.objects.first{$0.id==id}!.cloth)
    XCTAssertEqual(reopened.project!.schemaVersion,36);reopened.cloth.clear()
  }
  func testFullSizeNativeStepReportsCostAndIdleCountersWithoutSourceWrites()throws {
    let (store,root,id)=try fixture(spacing:22,fullSolver:true);defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    try store.cloth.activate(id)
    let before=store.project!,meshes=AssemblyProducts.builds,textures=AssemblyMaterialRenderer.textureBuilds,sceneBuilds=store.scene!.geometryBuilds
    let preparationBatches=try prepare(store,id)
    var timings:[Double]=[]
    for _ in 0..<30 {let begin=Date();try store.cloth.preview.stepImmediately();timings.append(Date().timeIntervalSince(begin)*1000)}
    let bridgeBegin=Date();_ = try call(store,"step",id);let bridgeMilliseconds=Date().timeIntervalSince(bridgeBegin)*1000
    let frames=store.cloth.preview.diagnostics!.completedFrames,evaluations=store.cloth.preview.diagnostics!.evaluations
    for _ in 0..<20 {_ = try call(store,"get",id)}
    XCTAssertEqual(store.project,before);XCTAssertEqual(AssemblyProducts.builds,meshes);XCTAssertEqual(AssemblyMaterialRenderer.textureBuilds,textures);XCTAssertEqual(store.scene!.geometryBuilds,sceneBuilds)
    XCTAssertEqual(store.cloth.preview.diagnostics!.completedFrames,frames);XCTAssertEqual(store.cloth.preview.diagnostics!.evaluations,evaluations)
    let sorted=timings.sorted()
    #if DEBUG
    let configuration="debug"
    #else
    let configuration="release"
    #endif
    let report:[String:Any]=["configuration":configuration,"vertices":store.cloth.preview.mesh!.restPositionsMm.count,"constraints":store.cloth.preview.mesh!.links.count,"preparation_main_thread_batch_ms":preparationBatches,"worker_max_ms":store.cloth.preview.maximumWorkerMilliseconds,"publication_max_ms":store.cloth.preview.maximumPublishMilliseconds,"native_step_median_ms":sorted[sorted.count/2],"native_step_p95_ms":sorted[Int(Double(sorted.count-1)*0.95)],"native_step_max_ms":sorted.last!,"bridge_step_with_metadata_ms":bridgeMilliseconds,"idle_geometry_builds":0,"idle_texture_builds":0,"idle_solver_evaluations":0,"document_unchanged":true]
    if let path=ProcessInfo.processInfo.environment["FORM_ASSEMBLY_PROOF_DIR"] {try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path).appendingPathComponent("assembly-native-performance-\(configuration).json"))}
  }
  func testOpenSurfacePrintRejectionLockedRollbackAndHomeClear()throws {
    let (store,root,id)=try fixture();defer {store.cloth.clear();try? FileManager.default.removeItem(at:root)}
    let object=store.project!.objects.first{$0.id==id}!
    XCTAssertThrowsError(try PrintMeshBuilder.mesh(object:object,project:store.project!,assets:root,configuration:.init())) {XCTAssertTrue($0.localizedDescription.contains("open flexible surface"))}
    store.printing.open(objectID:id);XCTAssertNil(store.printing.mesh)
    XCTAssertTrue(store.printing.validationError?.contains("open flexible surface")==true)
    _ = try call(store,"step",id)
    store.home();XCTAssertNil(store.cloth.preview.frame);XCTAssertThrowsError(try call(store,"step",id))
    store.showingHome=false
    try store.engine.edit("Lock") {p in p.objects[p.objects.firstIndex{$0.id==id}!].locked=true}
    let before=store.project!,undo=store.engine.undoStack
    XCTAssertThrowsError(try call(store,"configure",id,["settings":["friction":0.6]]))
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack,undo)
  }
}

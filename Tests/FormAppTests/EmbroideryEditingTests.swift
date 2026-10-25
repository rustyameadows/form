import AppKit
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class EmbroideryEditingTests:XCTestCase {
  private func fixture()throws -> (StudioStore,URL,UUID,EmbroideryDesign) {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),repository=try ProjectRepository(root:root)
    var p=Project(name:"Embroidery workshop")
    var patch=try p.makeObject(recipeID:"textilePatch",name:"ORBIT / stitch proof",parameters:["width":80,"depth":60,"corner":3])
    var running=ArtworkElement(kind:"line",x:8,y:8,width:30,height:0.1,color:"#C74C32");running.name="Running / orange orbit"
    var satin=ArtworkElement(kind:"line",x:8,y:18,width:30,height:0.1,color:"#E9DDB7");satin.name="Satin / pale rail"
    var fill=ArtworkElement(kind:"star",x:45,y:10,width:25,height:35,color:"#285B8A");fill.name="Fill / blue star"
    patch.artwork=Artwork(background:"#FFFFFF",elements:[running,satin,fill],bleed:0);p.objects=[patch];try repository.save(p)
    var a=EmbroideryRegion(elementIDs:[running.id],method:.running),b=EmbroideryRegion(elementIDs:[satin.id],method:.satin,threadIndex:1),c=EmbroideryRegion(elementIDs:[fill.id],method:.fill,threadIndex:2)
    a.stitchLength=2;b.stitchLength=4;b.satinWidth=3;b.spacing=0.5;c.spacing=0.65;c.angle=15
    let design=EmbroideryDesign(threads:[.init(name:"Signal orange",color:running.color),.init(name:"Ecru",color:satin.color),.init(name:"Orbital blue",color:fill.color)],regions:[a,b,c])
    let store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(p.id)
    return (store,root,patch.id,design)
  }
  private func clean(_ store:StudioStore,_ root:URL) {store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
  func testSharedDigitizingSettingsHaveOneUndoAtomicLockedRollbackAndDiskRestart()throws {
    let (store,root,id,design)=try fixture();defer {clean(store,root)}
    let before=store.project!,art=before.objects[0].artwork
    _ = try store.engine.call("form_update_object",arguments:["object_id":id.uuidString,"embroidery":try jsonObject(design)],source:"Studio")
    let configured=store.project!;XCTAssertEqual(configured.schemaVersion,25);XCTAssertEqual(configured.objects[0].artwork,art)
    XCTAssertEqual(configured.objects[0].textile?.embroidery,design);XCTAssertEqual(store.engine.undoStack.count,1)
    store.engine.undo();XCTAssertEqual(store.project,before);store.engine.redo();XCTAssertEqual(store.project,configured)
    store.engine.project!.objects[0].locked=true;let locked=store.project!
    XCTAssertThrowsError(try store.engine.call("form_update_object",arguments:["object_id":id.uuidString,"embroidery":NSNull()]))
    var bypass=locked.objects[0].textile!;bypass.embroidery=nil
    XCTAssertThrowsError(try store.engine.call("form_update_object",arguments:["object_id":id.uuidString,"textile":try jsonObject(bypass)]))
    XCTAssertThrowsError(try store.engine.call("form_update_object",arguments:["object_id":id.uuidString,"textile":NSNull()]))
    XCTAssertEqual(store.project,locked)
    store.engine.project=configured;try store.engine.flush()
    let restarted=StudioStore(repository:store.repository,seedLibrary:false);defer {restarted.engine.project=nil}
    try restarted.engine.open(configured.id)
    XCTAssertEqual(restarted.project!.objects[0].textile?.embroidery,design)
    XCTAssertEqual(restarted.project!.objects[0].artwork,art)
    var invalid=try jsonObject(design) as! [String:Any];invalid["hoopWidth"]=10
    XCTAssertThrowsError(try restarted.engine.call("form_update_object",arguments:["object_id":id.uuidString,"embroidery":invalid]))
    XCTAssertEqual(restarted.project!.objects[0].textile?.embroidery,design)
  }
  func testPhysicalExportsPreflightSidecarAndRegenerationKeepProjectAndHistoryExact()throws {
    let (store,root,id,design)=try fixture();defer {clean(store,root)}
    _ = try store.engine.call("form_update_object",arguments:["object_id":id.uuidString,"embroidery":try jsonObject(design)])
    let before=store.project!,object=before.objects[0],undos=store.engine.undoStack.count
    let preflight=try store.graphicsCall("form_export_artwork",["object_id":id.uuidString,"format":"preflight"]) as! [String:Any]
    XCTAssertGreaterThan(preflight["stitches"] as! Int,200);XCTAssertEqual(preflight["verified_sew_out"] as? Bool,false)
    XCTAssertEqual(preflight["hoop_width_mm"] as? Double,100)
    for format in ["dst","json","svg"] {
      let path=root.appendingPathComponent("orbital."+format)
      let result=try store.exportArtwork(object:object,arguments:["format":format,"embroidery_format":format,"path":path.path]) as! [String:Any]
      XCTAssertEqual(result["source_digest"] as? String,preflight["source_digest"] as? String)
      XCTAssertEqual(result["bytes"] as? Int,try Data(contentsOf:path).count)
      if format == "dst" {
        let side=try XCTUnwrap(result["thread_sidecar_path"] as? String),manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:side))) as! [String:Any]
        let sequence=manifest["thread_sequence"] as! [[String:Any]]
        XCTAssertEqual(sequence.map {$0["color"] as! String},design.threads.map(\.color))
        XCTAssertEqual(sequence.map {$0["thread_index"] as! Int},[0,1,2])
        if let proof=ProcessInfo.processInfo.environment["FORM_EMBROIDERY_PROOF_DIR"] {
          let directory=URL(fileURLWithPath:proof);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
          try Data(contentsOf:path).write(to:directory.appendingPathComponent("orbital.dst"));try Data(contentsOf:URL(fileURLWithPath:side)).write(to:directory.appendingPathComponent("orbital.threads.json"))
        }
      }
      if format == "json" {let program=try JSONDecoder.form.decode(EmbroideryProgram.self,from:Data(contentsOf:path));try program.validate();XCTAssertEqual(program.design,design)}
      if format == "svg" {let svg=try String(contentsOf:path,encoding:.utf8);XCTAssertTrue(svg.contains("width=\"100.000mm\""));XCTAssertTrue(svg.contains("data-command=\"jump\""))}
      if let proof=ProcessInfo.processInfo.environment["FORM_EMBROIDERY_PROOF_DIR"] {try Data(contentsOf:path).write(to:URL(fileURLWithPath:proof).appendingPathComponent("orbital."+format))}
    }
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undos)
    var edited=before;edited.objects[0].artwork!.elements[0].width=20;store.engine.project=edited
    let revised=try store.exportEmbroidery(object:edited.objects[0],arguments:["format":"preflight"]) as! [String:Any]
    XCTAssertNotEqual(revised["source_digest"] as? String,preflight["source_digest"] as? String)
  }
  func testMixedOutputsAndHoopFailureNeverReplaceExistingFiles()throws {
    let (store,root,id,design)=try fixture();defer {clean(store,root)}
    _ = try store.engine.call("form_update_object",arguments:["object_id":id.uuidString,"embroidery":try jsonObject(design)])
    let object=store.project!.objects[0],path=root.appendingPathComponent("keep.dst"),side=root.appendingPathComponent("keep.threads.json"),sentinel=Data("Approved output".utf8)
    try sentinel.write(to:path);try sentinel.write(to:side)
    for selector in [["roles":["stitch"] as Any],["fabric_pattern_material":"patch-twill"],["pattern_pieces":true],["element_ids":[UUID().uuidString]]] {
      var args:[String:Any]=["format":"dst","path":path.path];args.merge(selector){_,new in new}
      XCTAssertThrowsError(try store.exportArtwork(object:object,arguments:args))
      XCTAssertEqual(try Data(contentsOf:path),sentinel);XCTAssertEqual(try Data(contentsOf:side),sentinel)
    }
    store.engine.project!.objects[0].textile!.embroidery!.hoopWidth=20
    XCTAssertThrowsError(try store.exportArtwork(object:store.project!.objects[0],arguments:["format":"dst","path":path.path]))
    XCTAssertEqual(try Data(contentsOf:path),sentinel);XCTAssertEqual(try Data(contentsOf:side),sentinel)
    store.engine.project!.objects[0].textile!.embroidery=design
    try FileManager.default.removeItem(at:side);try FileManager.default.createDirectory(at:side,withIntermediateDirectories:true)
    XCTAssertThrowsError(try store.exportArtwork(object:object,arguments:["format":"dst","path":path.path]))
    XCTAssertEqual(try Data(contentsOf:path),sentinel)
  }
  func testNativePreviewDrawsGeneratedCommandsAndSeparatesTravelWithoutMutatingSource()throws {
    let (store,root,_,design)=try fixture();defer {clean(store,root)}
    let before=store.project!,program=try EmbroideryDigitizer.generate(object:before.objects[0],project:before,design:design)
    let preview=EmbroideryPreviewView(frame:.init(x:0,y:0,width:720,height:620));preview.program=program
    func render(_ jumps:Bool,_ through:Int)->Data {
      preview.showJumps=jumps;preview.through=through
      let rep=preview.bitmapImageRepForCachingDisplay(in:preview.bounds)!;preview.cacheDisplay(in:preview.bounds,to:rep)
      return rep.representation(using:.png,properties:[:])!
    }
    let needle=render(false,program.commands.count),travel=render(true,program.commands.count),start=render(true,0)
    XCTAssertNotEqual(needle,travel);XCTAssertNotEqual(start,needle)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    if let folder=ProcessInfo.processInfo.environment["FORM_EMBROIDERY_PROOF_DIR"] {
      let directory=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
      try travel.write(to:directory.appendingPathComponent("native-preview.png"))
    }
  }
}

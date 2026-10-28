import AppKit
import PDFKit
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class TextileProductionEditingTests:XCTestCase {
  private func fixture()throws -> (StudioStore,URL,UUID,UUID) {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),repository=try ProjectRepository(root:root)
    var p=Project(name:"Revision-linked embroidery")
    var source=try p.makeObject(recipeID:"artboard",name:"Editable badge source",parameters:["width":80,"depth":60])
    let satin=ArtworkElement(kind:"line",x:8,y:12,width:40,height:0.1,color:"#C75332"),fill=ArtworkElement(kind:"rectangle",x:45,y:25,width:25,height:25,color:"#285B8A")
    source.artwork=Artwork(background:"#FFFFFF",elements:[satin,fill],bleed:0)
    var garment=try p.makeObject(recipeID:"bomberJacket",name:"Concept bomber");garment.textile?.sku="CONCEPT-M"
    var patch=try p.makeObject(recipeID:"textilePatch",name:"Mission patch",parameters:["width":80,"depth":60,"corner":3],materialID:"patch-twill")
    patch.artwork=nil;patch.artworkSourceID=source.id;patch.textile?.attachment = .init(garmentID:garment.id,zone:.leftChest,offset:.init(1,2),rotation:7)
    var a=EmbroideryRegion(elementIDs:[satin.id],method:.satin),b=EmbroideryRegion(elementIDs:[fill.id],method:.fill,threadIndex:1)
    a.satinWidth=3;a.stitchLength=4;a.spacing=0.7;a.underlay = .init(method:.centerWalk);b.spacing=0.8
    var design=EmbroideryDesign(threads:[.init(name:"Orange",color:satin.color),.init(name:"Blue",color:fill.color)],regions:[a,b]);design.process=EmbroideryProcess();design.process?.tieIn=true;design.process?.tieOff=true
    patch.textile?.embroidery=design;p.objects=[source,garment,patch];try repository.save(p)
    let store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(p.id)
    return (store,root,patch.id,source.id)
  }
  private func clean(_ store:StudioStore,_ root:URL) {store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
  private func thread(_ store:StudioStore)throws -> StudioThread {
    let value:[String:Any]=["command":"save_thread","thread":["name":"Recorded orange spool","color":"#C75332","brand":"Test thread","sku":"OR-01","supplier":"Declared local source","availableMeters":100,"spoolMeters":1000,"spoolPrice":12,"currency":"USD"]]
    let result=try store.graphicsCall("form_textile_stock",value)
    return try JSONDecoder.form.decode(StudioThread.self,from:JSONSerialization.data(withJSONObject:result))
  }
  private func capture(_ store:StudioStore,_ id:UUID,equipment:UUID? = nil)throws -> ProductionJob {
    var args:[String:Any]=["command":"create","object_id":id.uuidString,"name":"ORBIT / run 01","quantity":4,"outputs":["dst","svg","json"],"assumptions":["upperThreadFactor":1.3,"allowanceMetersPerThreadPerItem":0.02,"notes":"Declared sample assumptions; no machine measurement."]]
    if let equipment {args["equipment_id"]=equipment.uuidString}
    let result=try store.productionCall("form_production_job",arguments:args,source:"Studio") as! [String:Any]
    return try JSONDecoder.form.decode(ProductionJob.self,from:JSONSerialization.data(withJSONObject:result["job"]!))
  }
  func testStudioStockPersistsWithoutProjectMutationAndAssignmentIsPortableUndoableAndLocked()throws {
    let (store,root,id,_)=try fixture();defer {clean(store,root)}
    let before=store.project!,stock=try thread(store)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    let loaded=StudioLibrary.load(from:root);XCTAssertEqual(loaded.textileProduction?.threads.first?.sku,"OR-01")
    _ = try store.productionCall("form_textile_stock",arguments:["command":"assign_thread","object_id":id.uuidString,"thread_index":0,"stock_id":stock.id.uuidString],source:"Studio")
    let assigned=store.project!,patch=assigned.objects.first {$0.id==id}!
    XCTAssertEqual(assigned.schemaVersion,29);XCTAssertEqual(patch.textile?.embroidery?.threads[0].stock?.sku,"OR-01");XCTAssertEqual(patch.textile?.embroidery?.threads[0].color,stock.color)
    XCTAssertEqual(store.engine.undoStack.count,1);store.engine.undo();XCTAssertEqual(store.project,before);store.engine.redo();XCTAssertEqual(store.project,assigned)
    var updated=stock;updated.spoolPrice=99;updated.availableMeters=2
    _ = try store.productionCall("form_textile_stock",arguments:["command":"save_thread","thread":try jsonObject(updated)],source:"Studio")
    XCTAssertEqual(store.project,assigned);XCTAssertEqual(store.project!.objects.first {$0.id==id}?.textile?.embroidery?.threads[0].stock?.spoolPrice,12)
    _ = try store.productionCall("form_textile_stock",arguments:["command":"remove_thread","stock_id":stock.id.uuidString],source:"Studio")
    XCTAssertEqual(store.project,assigned)
    _ = try store.productionCall("form_textile_stock",arguments:["command":"save_thread","thread":try jsonObject(stock)],source:"Studio")
    XCTAssertThrowsError(try store.productionCall("form_textile_stock",arguments:["command":"assign_thread","object_id":id.uuidString,"thread_index":true,"stock_id":stock.id.uuidString]))
    XCTAssertEqual(store.project,assigned)
    let index=store.project!.objects.firstIndex {$0.id==id}!;store.engine.project!.objects[index].locked=true
    let locked=store.project!
    XCTAssertThrowsError(try store.productionCall("form_textile_stock",arguments:["command":"assign_thread","object_id":id.uuidString,"thread_index":0,"stock_id":stock.id.uuidString]))
    XCTAssertEqual(store.project,locked)
  }
  func testCaptureIsOneUndoWithImmutableProgramAndUserRecordsTiedToItsSource()throws {
    let (store,root,id,sourceID)=try fixture();defer {clean(store,root)}
    let stock=try thread(store)
    _ = try store.productionCall("form_textile_stock",arguments:["command":"assign_thread","object_id":id.uuidString,"thread_index":0,"stock_id":stock.id.uuidString])
    let before=store.project!,undos=store.engine.undoStack.count,job=try capture(store,id)
    let captured=store.project!;XCTAssertEqual(captured.schemaVersion,29);XCTAssertEqual(store.engine.undoStack.count,undos+1)
    let revision=try store.productionRevision(job:job),program=try store.productionProgram(job:job)
    XCTAssertEqual(revision.usage,ThreadNeedleUsage.measure(program));XCTAssertEqual(revision.sourceDigest,job.sourceDigest);XCTAssertEqual(revision.object.artworkSourceID,nil)
    XCTAssertEqual(revision.garment?.textile?.sku,"CONCEPT-M");XCTAssertEqual(revision.object.textile?.attachment?.offset,.init(1,2));XCTAssertEqual(revision.object.textile?.embroidery?.threads[0].stock?.availableMeters,100)
    XCTAssertEqual(store.library.textileProduction?.threads[0].availableMeters,100)
    store.engine.undo();XCTAssertEqual(store.project,before);store.engine.redo();XCTAssertEqual(store.project,captured)
    let sourceIndex=store.project!.objects.firstIndex {$0.id==sourceID}!
    store.engine.project!.objects[sourceIndex].artwork!.elements[0].width=30
    let changed=try store.productionCall("form_production_job",arguments:["command":"get","job_id":job.id.uuidString]) as! [String:Any]
    XCTAssertEqual(changed["current_source"] as? String,"changed")
    XCTAssertEqual(try store.productionProgram(job:job),program)
    let record:[String:Any]=["kind":"quality","notes":"User reports the sample is acceptable on the tested twill.","outcome":"pass","recordedBy":"Validation user","reportedMeters":1.2]
    _ = try store.productionCall("form_production_job",arguments:["command":"event","job_id":job.id.uuidString,"record":record],source:"Studio")
    let recorded=store.project!,live=recorded.productionJobs!.first {$0.id==job.id}!
    XCTAssertEqual(live.status,.planned);XCTAssertEqual(live.records[0].sourceDigest,job.sourceDigest);XCTAssertEqual(live.records[0].outcome,.pass)
    var invalid=record;invalid["sourceDigest"]=String(repeating:"f",count:64)
    XCTAssertThrowsError(try store.productionCall("form_production_job",arguments:["command":"event","job_id":job.id.uuidString,"record":invalid]))
    XCTAssertEqual(store.project,recorded)
    store.engine.undo();XCTAssertEqual(store.project!.productionJobs!.first!.records.count,0)
  }
  func testPacketsContainArchivedPhysicalOutputsDigestsThreadScheduleAndActualSizePDF()throws {
    let (store,root,id,_)=try fixture();defer {clean(store,root)}
    let stock=try thread(store)
    _ = try store.productionCall("form_textile_stock",arguments:["command":"assign_thread","object_id":id.uuidString,"thread_index":0,"stock_id":stock.id.uuidString])
    let equipmentRaw:[String:Any]=["name":"Declared 100 mm embroidery machine","hoops":[["name":"100 mm hoop","width":100,"height":100]],"formats":["dst"],"needleCount":1]
    let equipment=try store.productionCall("form_textile_stock",arguments:["command":"save_equipment","equipment":equipmentRaw]) as! [String:Any]
    let job=try capture(store,id,equipment:UUID(uuidString:equipment["id"] as! String)!),before=store.project!,undos=store.engine.undoStack.count
    let folder=root.appendingPathComponent("ReviewPacket")
    let result=try store.productionCall("form_production_job",arguments:["command":"export","job_id":job.id.uuidString,"format":"folder","path":folder.path]) as! [String:Any]
    XCTAssertEqual(result["inventory_deducted"] as? Bool,false);XCTAssertEqual(result["machine_contacted"] as? Bool,false)
    let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("Manifest.json"))) as! [String:Any],files=manifest["files"] as! [String:[String:Any]]
    XCTAssertEqual(Set(files.keys),["Job.json","Revision.json","Estimate.json","Review.pdf","Program.json","Needle.svg","Needle.dst","Needle.threads.json"])
    for (name,metadata) in files {let data=try Data(contentsOf:folder.appendingPathComponent(name));XCTAssertEqual(ProductionAssets.digest(data),metadata["sha256"] as? String);XCTAssertEqual(data.count,metadata["bytes"] as? Int)}
    XCTAssertEqual(files["Revision.json"]?["sha256"] as? String,job.revisionDigest);XCTAssertEqual(files["Program.json"]?["sha256"] as? String,job.programDigest)
    let pdf=try XCTUnwrap(PDFDocument(url:folder.appendingPathComponent("Review.pdf")))
    XCTAssertGreaterThanOrEqual(pdf.pageCount,2);XCTAssertTrue(pdf.string!.contains(job.sourceDigest));XCTAssertTrue(pdf.string!.contains("Unknown"))
    let last=pdf.page(at:pdf.pageCount-1)!.bounds(for:.mediaBox)
    XCTAssertEqual(last.width/TypographyEngine.pointsPerMM,132,accuracy:0.001);XCTAssertEqual(last.height/TypographyEngine.pointsPerMM,132,accuracy:0.001)
    let threadManifest=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("Needle.threads.json"))) as! [String:Any]
    XCTAssertEqual(threadManifest["source_digest"] as? String,job.sourceDigest)
    XCTAssertEqual((threadManifest["thread_sequence"] as! [[String:Any]]).map {$0["color"] as! String},["#C75332","#285B8A"])
    let zip=root.appendingPathComponent("Packet.zip")
    _ = try store.productionCall("form_production_job",arguments:["command":"export","job_id":job.id.uuidString,"format":"zip","path":zip.path])
    XCTAssertEqual(Array(try Data(contentsOf:zip).prefix(2)),[0x50,0x4B])
    let listing=Process(),pipe=Pipe();listing.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");listing.arguments=["-Z1",zip.path];listing.standardOutput=pipe
    try listing.run();let names=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).split(separator:"\n").map(String.init);listing.waitUntilExit()
    XCTAssertEqual(listing.terminationStatus,0)
    XCTAssertEqual(Set(names.filter {!$0.hasSuffix("/")}),Set((Array(files.keys)+["Manifest.json"]).map {"Production/"+$0}))
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undos)
    if let directory=ProcessInfo.processInfo.environment["FORM_PRODUCTION_PROOF_DIR"] {let proof=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:proof,withIntermediateDirectories:true);for name in files.keys {try Data(contentsOf:folder.appendingPathComponent(name)).write(to:proof.appendingPathComponent(name))};try Data(contentsOf:folder.appendingPathComponent("Manifest.json")).write(to:proof.appendingPathComponent("Manifest.json"));try Data(contentsOf:zip).write(to:proof.appendingPathComponent("Packet.zip"))}
  }
  func testArchivedJobsRemainPortableAfterSourceDeletionAndLibraryChanges()throws {
    let (store,root,id,sourceID)=try fixture();defer {clean(store,root)}
    let stock=try thread(store)
    _ = try store.productionCall("form_textile_stock",arguments:["command":"assign_thread","object_id":id.uuidString,"thread_index":0,"stock_id":stock.id.uuidString])
    let job=try capture(store,id),captured=try store.productionProgram(job:job)
    store.engine.project!.objects.removeAll {$0.id==id || $0.id==sourceID};try store.engine.flush()
    let movedRoot=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:movedRoot)}
    let moved=try ProjectRepository(root:movedRoot),projectID=store.project!.id
    try FileManager.default.copyItem(at:store.repository.url(for:projectID),to:moved.url(for:projectID))
    let reopened=StudioStore(repository:moved,seedLibrary:false);defer {reopened.engine.project=nil};try reopened.engine.open(projectID)
    XCTAssertTrue(reopened.library.textileProduction?.threads.isEmpty ?? true)
    let saved=reopened.project!.productionJobs!.first!
    XCTAssertEqual(try reopened.productionProgram(job:saved),captured)
    XCTAssertEqual(try reopened.productionRevision(job:saved).object.textile?.embroidery?.threads[0].stock?.sku,"OR-01")
    let result=try reopened.productionCall("form_production_job",arguments:["command":"get","job_id":job.id.uuidString]) as! [String:Any]
    XCTAssertEqual(result["current_source"] as? String,"missing")
    _ = try reopened.exportProductionPacket(job:saved,arguments:["format":"folder","path":movedRoot.appendingPathComponent("PortablePacket").path])
  }
  func testBadInputsAndCorruptAssetsPreserveExistingPacketAndState()throws {
    let (store,root,id,_)=try fixture();defer {clean(store,root)}
    let before=store.project!
    XCTAssertThrowsError(try store.productionCall("form_production_job",arguments:["command":"create","object_id":id.uuidString,"quantity":true]))
    XCTAssertThrowsError(try store.productionCall("form_production_job",arguments:["command":"create","object_id":id.uuidString,"outputs":["pes"]]))
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    let job=try capture(store,id),state=store.project!,program=ProductionAssets.folder(repository:store.repository,projectID:state.id).appendingPathComponent(job.programDigest+".program.json")
    try Data("Corrupt archived data".utf8).write(to:program)
    let packet=root.appendingPathComponent("Approved.zip"),sentinel=Data("Approved existing packet".utf8);try sentinel.write(to:packet)
    XCTAssertThrowsError(try store.exportProductionPacket(job:job,arguments:["format":"zip","path":packet.path]))
    XCTAssertEqual(try Data(contentsOf:packet),sentinel);XCTAssertEqual(store.project,state)
  }
  func testNativeCaptureAndUserRecordAutosaveWithoutDeductingStock()async throws {
    let (store,root,id,_)=try fixture();defer {clean(store,root)}
    let stock=try thread(store)
    _ = try store.productionCall("form_textile_stock",arguments:["command":"assign_thread","object_id":id.uuidString,"thread_index":0,"stock_id":stock.id.uuidString],source:"Studio")
    let objects=store.project!.objects,job=try capture(store,id)
    _ = try store.productionCall("form_production_job",arguments:["command":"event","job_id":job.id.uuidString,"record":["kind":"sample","notes":"User reports a trial sample; no machine telemetry.","reportedMeters":0.8]],source:"Studio")
    XCTAssertTrue(store.saving)
    try await Task.sleep(nanoseconds:600_000_000)
    let disk=try store.repository.load(store.project!.id)
    XCTAssertEqual(disk.productionJobs?.first?.id,job.id);XCTAssertEqual(disk.productionJobs?.first?.records.first?.reportedMeters,0.8)
    XCTAssertEqual(try JSONEncoder.form.encode(disk.objects),try JSONEncoder.form.encode(objects))
    XCTAssertEqual(StudioLibrary.load(from:root).textileProduction?.threads.first?.availableMeters,100)
    XCTAssertFalse(store.saving);XCTAssertNil(store.error)
  }
}

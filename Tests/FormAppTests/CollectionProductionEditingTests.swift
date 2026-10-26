import AppKit
import SwiftUI
import PDFKit
import XCTest
@testable import FormCore
@testable import FormGraphics
@testable import FormApp

@MainActor final class CollectionProductionEditingTests:XCTestCase {
  private func fixture(nasa:Bool=false)throws->(StudioStore,URL) {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),repo=try ProjectRepository(root:root)
    var p:Project
    if nasa {p=Samples.flightJacket()}else {
      p=Project(name:"ORBITAL / captured manufacture")
      var patch=try p.makeObject(recipeID:"textilePatch",name:"Original mission patch",parameters:["width":80,"depth":60,"corner":3],materialID:"patch-twill")
      let line=ArtworkElement(kind:"line",x:10,y:15,width:40,height:0.1,color:"#C75332")
      patch.artwork=Artwork(background:"#FFFFFF",elements:[line],bleed:0);patch.artwork?.backgroundOpacity=0
      patch.textile?.embroidery = .init(threads:[.init(name:"Signal",color:line.color)],regions:[.init(elementIDs:[line.id],method:.running)])
      p.objects=[patch]
    }
    try repo.save(p);let store=StudioStore(repository:repo,seedLibrary:false);store.fontLibraryPreferences = .init(file:root.appendingPathComponent("FontPreferences.json"));try store.engine.open(p.id)
    addTeardownBlock{store.engine.project=nil;try? FileManager.default.removeItem(at:root)};return(store,root)
  }
  private func call(_ store:StudioStore,_ command:String,_ args:[String:Any]=[:])throws->[String:Any] {
    guard let result=try store.productionCall("form_production_job",arguments:["kind":"collection","command":command].merging(args){_,n in n}) as? [String:Any] else{throw FormError.invalid("Unexpected collection result type.")};return result
  }
  private func save(_ store:StudioStore,_ plan:CollectionProductionPlan)throws {_ = try call(store,"save_plan",["definition":try jsonObject(plan)])}
  private func capture(_ store:StudioStore,_ plan:CollectionProductionPlan)throws->CollectionCapture {
    let r=try call(store,"create",["plan_id":plan.id.uuidString]);return try JSONDecoder.form.decode(CollectionCapture.self,from:JSONSerialization.data(withJSONObject:r["job"]!))
  }
  func testSaveCaptureUndoAutosaveReopenAndOriginalSourceStayExact()async throws {
    let(store,root)=try fixture(),before=store.project!,plan=CollectionProductionPlan(name:"Run",runs:[.init(objectID:before.objects[0].id,quantity:3)])
    try save(store,plan);let saved=store.project!,history=store.engine.undoStack.count;XCTAssertEqual(saved.objects,before.objects);XCTAssertEqual(saved.camera,before.camera)
    let job=try capture(store,plan);XCTAssertEqual(store.engine.undoStack.count,history+1);let captured=store.project!
    XCTAssertEqual(captured.objects,before.objects);XCTAssertEqual(captured.camera,before.camera);XCTAssertEqual(captured.collectionProduction?.captures,[job])
    store.engine.undo();XCTAssertEqual(store.project,saved);store.engine.redo();XCTAssertEqual(store.project,captured)
    try await Task.sleep(nanoseconds:500_000_000)
    XCTAssertEqual(try ProjectRepository(root:root).load(captured.id).collectionProduction?.captures,[job])
    try store.engine.open(captured.id);XCTAssertEqual(try call(store,"get",["job_id":job.id.uuidString])["current_source"] as? String,"matches")
  }
  func testLegacyArchivedProgramsDeriveOnceThenExportExactAfterSourceAndFontDeletion()throws {
    let(store,root)=try fixture(),object=store.project!.objects[0]
    let old=try XCTUnwrap(try store.productionCall("form_production_job",arguments:["command":"create","object_id":object.id.uuidString,"quantity":1,"outputs":["dst","svg","json"],"assumptions":["upperThreadFactor":1.2,"allowanceMetersPerThreadPerItem":0,"laborMinutesPerItem":1,"hourlyLaborRate":10,"laborCurrency":"USD"]]) as? [String:Any])
    let process=try JSONDecoder.form.decode(ProductionJob.self,from:JSONSerialization.data(withJSONObject:old["job"]!))
    var plan=CollectionProductionPlan(name:"Archived stitch run",runs:[.init(objectID:object.id)]);plan.processes=[.init(jobID:process.id,kind:"embroidery")];try save(store,plan)
    let job=try capture(store,plan),archive=try store.collectionArchive(job)
    let prefix="Processes/"+process.id.uuidString+"/"
    XCTAssertEqual(archive.files[prefix+"Program.original.json"],try ProductionAssets.read(process.programDigest,kind:"program",repository:store.repository,projectID:store.project!.id))
    XCTAssertEqual(archive.files[prefix+"Revision.original.json"],try ProductionAssets.read(process.revisionDigest,kind:"revision",repository:store.repository,projectID:store.project!.id))
    XCTAssertTrue(archive.revision.artifacts.contains{$0.name.hasSuffix("Needle.derived.dst") && $0.provenance.contains("Derived once")})
    let labor=try XCTUnwrap(archive.revision.report.rows.first{$0.role=="labor"});XCTAssertEqual(labor.cost,"0.166666666667");XCTAssertEqual(labor.calculation?.rounded,true)
    store.engine.project!.objects=[];store.engine.project!.productionJobs=[];store.library.textileProduction=nil
    let result=try call(store,"get",["job_id":job.id.uuidString]);XCTAssertEqual(result["current_source"] as? String,"missing")
    let destination=root.appendingPathComponent("Exported")
    _ = try call(store,"export",["job_id":job.id.uuidString,"format":"folder","path":destination.path])
    for (name,data) in archive.files {XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent(name)),data,name)}
    if let folder=ProcessInfo.processInfo.environment["FORM_COLLECTION_PROOF_DIR"] {let out=URL(fileURLWithPath:folder).appendingPathComponent("Legacy");try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true);for(name,data)in archive.files {let u=out.appendingPathComponent(name);try FileManager.default.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:u)}}
  }
  func testDecorationFilesCopiedByteForByteAndFrozenReviewNeverReconstructed()throws {
    let(store,root)=try fixture(),id=store.project!.objects[0].id
    let result=try XCTUnwrap(try store.productionCall("form_production_job",arguments:["kind":"decoration","command":"create","object_id":id.uuidString,"quantity":2,"preparation":["process":"htv","mirror":true]]) as? [String:Any])
    let process=try JSONDecoder.form.decode(DecorationPreparation.self,from:JSONSerialization.data(withJSONObject:result["job"]!)),original=try store.decorationRevision(process)
    var plan=CollectionProductionPlan(name:"HTV archive",runs:[.init(objectID:id,quantity:2)]);plan.processes=[.init(jobID:process.id,kind:"decoration")];try save(store,plan);let job=try capture(store,plan),archive=try store.collectionArchive(job)
    for file in original.files {XCTAssertEqual(archive.files["Processes/"+process.id.uuidString+"/"+file.name],try DecorationPacketAssets.read(file.digest,repository:store.repository,projectID:store.project!.id,expectedBytes:file.bytes))}
    let pdf=try XCTUnwrap(archive.files["Review.pdf"]);store.engine.project!.objects=[];store.engine.project!.decorationPreparations=[]
    let output=root.appendingPathComponent("HTV");_ = try call(store,"export",["job_id":job.id.uuidString,"format":"folder","path":output.path]);XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent("Review.pdf")),pdf)
  }
  func testSupplyLibraryEditsDoNotRewriteProjectHistoryOrPortableAssignments()throws {
    let(store,_)=try fixture(),before=store.project!,n=store.engine.undoStack.count
    var supply=StudioSupply(name:"Declared zipper",category:"trim");supply.available="20";supply.unitPrice="3.125";supply.currency="EUR"
    _ = try store.productionCall("form_textile_stock",arguments:["command":"save_supply","supply":try jsonObject(supply)])
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,n)
    let stock=CollectionStockSnapshot(supply:supply);var plan=CollectionProductionPlan(name:"Portable",runs:[.init(objectID:before.objects[0].id)])
    var extra=CollectionExtraLine(name:"Zipper");extra.quantity="1";plan.extras=[extra];var rule=CollectionLineRule(rowID:"extra/"+extra.id.uuidString);rule.stock=stock;plan.rules=[rule];try save(store,plan)
    let saved=store.project!;supply.available="0";supply.unitPrice="99"
    _ = try store.productionCall("form_textile_stock",arguments:["command":"save_supply","supply":try jsonObject(supply)]);_ = try store.productionCall("form_textile_stock",arguments:["command":"remove_supply","stock_id":supply.id.uuidString])
    XCTAssertEqual(store.project,saved);XCTAssertEqual(store.project?.collectionProduction?.plans.first?.rules.first?.stock?.supply?.unitPrice,"3.125")
  }
  func testCorruptMissingArchiveAndInvalidCapturePreserveHistorySourceAndDestination()throws {
    let(store,root)=try fixture(),plan=CollectionProductionPlan(name:"Guarded",runs:[.init(objectID:store.project!.objects[0].id)])
    try save(store,plan);let job=try capture(store,plan),archive=try store.collectionArchive(job),before=store.project!,history=store.engine.undoStack.count
    let target=root.appendingPathComponent("existing.zip"),sentinel=Data("KEEP".utf8);try sentinel.write(to:target)
    let artifact=try XCTUnwrap(archive.revision.artifacts.first{$0.name=="Review.pdf"}),u=try CollectionPacketAssets.url(artifact.digest,repository:store.repository,projectID:before.id)
    try Data("corrupt".utf8).write(to:u);XCTAssertThrowsError(try call(store,"export",["job_id":job.id.uuidString,"path":target.path]));XCTAssertEqual(try Data(contentsOf:target),sentinel)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,history)
    var invalid=plan;invalid.runs.append(invalid.runs[0]);XCTAssertThrowsError(try save(store,invalid));XCTAssertEqual(store.project,before)
  }
  func testCollectionPreflightReadOnlyAndRejectedMutationPreserveFocusedTextDraft()throws {
    let(store,_)=try fixture();var p=store.project!,sheet=try p.makeObject(recipeID:"artboard",parameters:["width":100,"depth":80]);let e=ArtworkElement(kind:"text",x:5,y:5,width:80,height:20,text:"Original words");sheet.artwork=Artwork(elements:[e]);p.objects.append(sheet);store.engine.project=p
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:800,height:600),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;let canvas=VectorCanvasView(frame:window.contentView!.bounds);canvas.session=store.artworkSession;store.artworkSession.canvas=canvas;store.artworkSession.objectID=sheet.id;store.artworkSession.choose([e.id]);window.contentView=canvas;canvas.synchronize();defer{canvas.finishText();window.close()}
    canvas.beginText(e);let text=try XCTUnwrap(window.firstResponder as? CanvasTextView);text.setSelectedRange(.init(location:0,length:8));text.insertText("Pending",replacementRange:text.selectedRange())
    let before=store.project!,draft=text.string,range=text.selectedRange(),history=store.engine.undoStack.count
    let plan=CollectionProductionPlan(name:"Read only",runs:[.init(objectID:p.objects[0].id)]);_ = try call(store,"preflight",["definition":try jsonObject(plan)])
    XCTAssertTrue(window.firstResponder === text);XCTAssertEqual(text.string,draft);XCTAssertEqual(store.project,before)
    var bad=plan;bad.runs[0].quantity=0
    XCTAssertThrowsError(try store.preflightCollectionHandoff("form_production_job",["kind":"collection","command":"save_plan","definition":try jsonObject(bad)]))
    XCTAssertTrue(window.firstResponder === text);XCTAssertEqual(text.selectedRange(),range);XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,history)
  }
  func testNativeDraftScopeInvalidActiveValuesAndCancelDoNotPublish()throws {
    let(store,_)=try fixture(),draft=CollectionDraft(project:store.project!)
    draft.runs=[.init(.init(objectID:store.project!.objects[0].id))];draft.runs[0].quantity="1.5";let before=store.project!
    XCTAssertThrowsError(try draft.save(store));XCTAssertEqual(store.project,before)
    draft.runs[0].quantity="2";try draft.save(store);XCTAssertEqual(store.project!.collectionProduction!.plans[0].runs[0].quantity,2)
    store.engine.undo();XCTAssertEqual(store.project,before)
    store.engine.project=Project(name:"Another project");XCTAssertThrowsError(try draft.save(store))
  }
  func testOriginalNASACollectionProofRetains110OccurrencesAndPhysicalA4Pages()throws {
    let(store,_)=try fixture(nasa:true),draft=CollectionDraft(project:store.project!);draft.orbital(store)
    let plan=try draft.definition(store);try save(store,plan);let job=try capture(store,plan),archive=try store.collectionArchive(job)
    XCTAssertEqual(archive.revision.report.occurrences.reduce(0){$0+$1.quantity},110)
    let bytes=try XCTUnwrap(archive.files["Review.pdf"]),pdf=try XCTUnwrap(PDFDocument(data:bytes));XCTAssertTrue((3...100).contains(pdf.pageCount))
    for i in 0..<pdf.pageCount {let box=pdf.page(at:i)!.bounds(for:.mediaBox);XCTAssertEqual(box.width*25.4/72,210,accuracy:0.01);XCTAssertEqual(box.height*25.4/72,297,accuracy:0.01)}
    XCTAssertTrue(pdf.string?.contains("Complete estimate unknown") ?? false);XCTAssertTrue(pdf.string?.contains("No portable stock assigned; availability is unknown.") ?? false)
    for root in store.project!.objects where root.textile?.kind == .garment {
      let heading=root.name+" / "+(root.textile?.blankName ?? root.recipeID)
      let page=try XCTUnwrap((0..<pdf.pageCount).compactMap{pdf.page(at:$0)?.string}.first{$0.contains(heading)})
      let range=try XCTUnwrap(page.range(of:heading))
      XCTAssertTrue(page[range.upperBound...].contains("Manufacturer:"),"A construction heading must remain with its first detail.")
    }
    if let folder=ProcessInfo.processInfo.environment["FORM_COLLECTION_PROOF_DIR"] {let out=URL(fileURLWithPath:folder).appendingPathComponent("NASA");try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true);for(name,data)in archive.files {let u=out.appendingPathComponent(name);try FileManager.default.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:u)}}
  }
  private func fields(_ root:NSView)->[NSTextField] {([root as? NSTextField].compactMap{$0})+root.subviews.flatMap{fields($0)}}
  private func host<V:View>(_ value:V)->(NSWindow,NSHostingView<V>) {
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1100,height:700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let view=NSHostingView(rootView:value);view.sizingOptions=[];window.contentView=view;window.setContentSize(.init(width:1100,height:700));view.frame = .init(x:0,y:0,width:1100,height:700);window.orderBack(nil);view.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.08));return(window,view)
  }
  private func accessible(_ root:any NSAccessibilityProtocol,_ id:String,depth:Int=0)->(any NSAccessibilityProtocol)? {
    guard depth<40 else{return nil}
    if root.accessibilityIdentifier()==id {return root}
    for child in root.accessibilityChildren() ?? [] {if let child=child as? any NSAccessibilityProtocol,let found=accessible(child,id,depth:depth+1){return found}}
    return nil
  }
  private func footerButtons(_ view:NSView)throws->[NSRect] {
    let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
    let step=3.0,w=Int(view.bounds.width/step),h=Int(view.bounds.height/step),scale=Double(bitmap.pixelsWide)/view.bounds.width
    var mask=[Bool](repeating:false,count:w*h),seen=mask
    for y in h/2..<h {for x in 0..<w {
      guard let c=bitmap.colorAt(x:Int(Double(x)*step*scale),y:Int(Double(y)*step*scale))?.usingColorSpace(.sRGB) else{continue}
      let r=c.redComponent,g=c.greenComponent,b=c.blueComponent,v=(r+g+b)/3
      mask[y*w+x]=c.alphaComponent>0.9 && v>0.86 && v<0.94 && max(r,max(g,b))-min(r,min(g,b))<0.035
    }}
    var result:[NSRect]=[]
    for index in 0..<mask.count where mask[index] && !seen[index] {
      var pending=[index],count=0,minX=index%w,maxX=minX,minY=index/w,maxY=minY;seen[index]=true
      while let p=pending.popLast() {let x=p%w,y=p/w;count+=1;minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y)
        for (nx,ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where nx>=0 && nx<w && ny>=0 && ny<h {let n=ny*w+nx;if mask[n] && !seen[n] {seen[n]=true;pending.append(n)}}
      }
      let width=Double(maxX-minX+1)*step,height=Double(maxY-minY+1)*step,density=Double(count)/Double((maxX-minX+1)*(maxY-minY+1))
      if width>40,height>=12,height<=38,density>0.3 {result.append(.init(x:Double(minX)*step,y:Double(minY)*step,width:width,height:height))}
    }
    return result
  }
  private func press(_ id:String,window:NSWindow,view:NSView)throws {
    view.layoutSubtreeIfNeeded()
    if let folder=ProcessInfo.processInfo.environment["FORM_COLLECTION_PROOF_DIR"],let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds){view.cacheDisplay(in:view.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:folder).appendingPathComponent("button-"+id+".png"))}
    let location:NSPoint
    if let target=accessible(view,id) {let r=window.convertFromScreen(target.accessibilityFrame());location = .init(x:r.midX,y:r.midY)}
    else {
      // Inactive offscreen SwiftUI exposes no AX children. Locate actual rendered
      // native footer button bounds; do not guess coordinates or invoke actions.
      let all=try footerButtons(view),isSupply=id=="collection-supply-save"
      let start=fields(view).first{$0.placeholderString=="Collection plan name"}.map{view.convert($0.bounds,from:$0).minX} ?? 0
      let choices=all.filter{isSupply || $0.minX>=start-5},bottom=try XCTUnwrap(choices.map(\.midY).max()),footer=choices.filter{abs($0.midY-bottom)<18}.sorted{$0.minX<$1.minX}
      let index=(isSupply || id=="collection-capture") ? footer.count-1:(id=="collection-cancel" ? 0:1);XCTAssertTrue(footer.indices.contains(index),String(describing:all));let r=try XCTUnwrap(footer.indices.contains(index) ? footer[index]:nil)
      location=view.convert(.init(x:r.midX,y:view.isFlipped ? r.midY:view.bounds.height-r.midY),to:nil)
    }
    let stamp=ProcessInfo.processInfo.systemUptime
    let down=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:stamp,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)),up=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:stamp+0.02,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0))
    NSApp.postEvent(up,atStart:false);NSApp.sendEvent(down);NSApp.sendEvent(up);RunLoop.main.run(until:Date().addingTimeInterval(0.1))
  }
  private func enter(_ value:String,_ name:String,window:NSWindow,view:NSView)throws {
    let editables=fields(view).filter{$0.isEditable},formIndex=["Supply name":0,"Available quantity · unknown if blank":1,"Declared price per unit":2,"Currency":3]
    let field=try XCTUnwrap(editables.first{$0.placeholderString==name} ?? formIndex[name].flatMap{editables.indices.contains($0) ? editables[$0]:nil})
    window.makeFirstResponder(field);let editor=try XCTUnwrap(window.firstResponder as? NSTextView);editor.selectAll(nil);editor.insertText(value,replacementRange:.init(location:NSNotFound,length:0));RunLoop.main.run(until:Date().addingTimeInterval(0.03))
  }
  func testActualNativeSaveButtonCommitsFocusedRunWithoutTabAndOneUndo()throws {
    let(store,_)=try fixture(),before=store.project!,draft=CollectionDraft(project:before);draft.runs=[.init(.init(objectID:before.objects[0].id))]
    let(window,view)=host(CollectionProductionView(store:store,draft:draft).padding(20).background(Palette.paper));defer{window.close()}
    try enter("7","Run quantity",window:window,view:view);try press("collection-save",window:window,view:view)
    XCTAssertEqual(store.project?.collectionProduction?.plans.first?.runs.first?.quantity,7,draft.error);XCTAssertEqual(store.engine.undoStack.count,1);XCTAssertEqual(store.project?.objects,before.objects);XCTAssertEqual(store.project?.camera,before.camera)
    if let folder=ProcessInfo.processInfo.environment["FORM_COLLECTION_PROOF_DIR"],let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {view.cacheDisplay(in:view.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:folder).appendingPathComponent("native-collection.png"))}
    store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testCleanNativeCollectionFormFollowsSavedQuantityUndoAndRedo()throws {
    let(store,_)=try fixture(),plan=CollectionProductionPlan(name:"History",runs:[.init(objectID:store.project!.objects[0].id)])
    try save(store,plan);let before=store.project!,draft=CollectionDraft(project:before);draft.load(plan,store)
    let(window,view)=host(CollectionProductionView(store:store,draft:draft).padding(20).background(Palette.paper));defer{window.close()}
    try enter("7","Run quantity",window:window,view:view);try press("collection-save",window:window,view:view)
    window.makeFirstResponder(nil);let saved=store.project!;XCTAssertEqual(draft.runs[0].quantity,"7")
    store.undo();RunLoop.main.run(until:Date().addingTimeInterval(0.08))
    XCTAssertEqual(store.project,before);XCTAssertEqual(draft.runs[0].quantity,"1")
    XCTAssertEqual(fields(view).first{$0.placeholderString=="Run quantity"}?.stringValue,"1")
    store.redo();RunLoop.main.run(until:Date().addingTimeInterval(0.08))
    XCTAssertEqual(store.project,saved);XCTAssertEqual(draft.runs[0].quantity,"7")
    XCTAssertEqual(fields(view).first{$0.placeholderString=="Run quantity"}?.stringValue,"7")
  }
  func testCollectionHistoryDoesNotReplaceOrCommitALaggingFocusedEditor()throws {
    let(store,_)=try fixture(),plan=CollectionProductionPlan(name:"Pending input",runs:[.init(objectID:store.project!.objects[0].id)])
    try save(store,plan);let before=store.project!,draft=CollectionDraft(project:before);draft.load(plan,store)
    draft.runs[0].quantity="7";try draft.save(store)
    let(window,view)=host(CollectionProductionView(store:store,draft:draft).padding(20).background(Palette.paper));defer{window.close()}
    let field=try XCTUnwrap(fields(view).first{$0.placeholderString=="Run quantity"});window.makeFirstResponder(field)
    let editor=try XCTUnwrap(window.firstResponder as? NSTextView);editor.string="9.5";editor.setSelectedRange(.init(location:1,length:1))
    store.undo();RunLoop.main.run(until:Date().addingTimeInterval(0.08))
    XCTAssertEqual(store.project,before);XCTAssertTrue(window.firstResponder === editor)
    XCTAssertEqual(editor.string,"9.5");XCTAssertEqual(editor.selectedRange(),.init(location:1,length:1));XCTAssertEqual(draft.runs[0].quantity,"7")
    // Publish the pending native edit normally; it remains an independent invalid
    // draft after document Undo, rather than being overwritten with the saved1.
    editor.didChangeText();window.makeFirstResponder(nil);RunLoop.main.run(until:Date().addingTimeInterval(0.08))
    XCTAssertEqual(draft.runs[0].quantity,"9.5");XCTAssertThrowsError(try draft.save(store));XCTAssertEqual(store.project,before)
  }
  func testNativeCaptureUndoReturnsToTheEditableSavedPlan()throws {
    let(store,_)=try fixture(),plan=CollectionProductionPlan(name:"Capture history",runs:[.init(objectID:store.project!.objects[0].id)])
    try save(store,plan);let before=store.project!,draft=CollectionDraft(project:before);draft.load(plan,store)
    let(window,view)=host(CollectionProductionView(store:store,draft:draft).padding(20).background(Palette.paper));defer{window.close()}
    try press("collection-capture",window:window,view:view);XCTAssertEqual(store.project?.collectionProduction?.captures.count,1)
    XCTAssertNil(fields(view).first{$0.placeholderString=="Collection plan name"})
    store.undo();RunLoop.main.run(until:Date().addingTimeInterval(0.08))
    XCTAssertEqual(store.project,before);XCTAssertEqual(fields(view).first{$0.placeholderString=="Collection plan name"}?.stringValue,plan.name)
    XCTAssertEqual(draft.runs[0].quantity,"1")
  }
  func testActualNativeInvalidSaveAndCancelKeepSourceHistoryAndDraftExact()throws {
    let(store,_)=try fixture(),before=store.project!,draft=CollectionDraft(project:before);draft.runs=[.init(.init(objectID:before.objects[0].id))]
    let(window,view)=host(CollectionProductionView(store:store,draft:draft).padding(20).background(Palette.paper));defer{window.close()}
    try enter("1.5","Run quantity",window:window,view:view);try press("collection-save",window:window,view:view)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty);XCTAssertEqual(draft.runs[0].quantity,"1.5");XCTAssertFalse(draft.error.isEmpty)
    try press("collection-cancel",window:window,view:view);XCTAssertTrue(draft.cancelled);XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testActualSupplySaveButtonUsesFocusedExactStringAndRejectsPartialDecimal()throws {
    let(store,_)=try fixture(),before=store.project!;var saved:StudioSupply?
    let(window,view)=host(CollectionSupplyEditor(item:.init(name:"Declared trim")){saved=$0});defer{window.close()}
    try enter("1.234567891234","Declared price per unit",window:window,view:view);try enter("USD","Currency",window:window,view:view);try enter("2.5x","Available quantity · unknown if blank",window:window,view:view);try press("collection-supply-save",window:window,view:view)
    XCTAssertNil(saved);XCTAssertEqual(store.project,before)
    try enter("12","Available quantity · unknown if blank",window:window,view:view);try press("collection-supply-save",window:window,view:view)
    XCTAssertEqual(saved?.unitPrice,"1.234567891234");XCTAssertEqual(saved?.available,"12");XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testPacketCSVOriginalTextSafeZIPAndCopiedPackageRemainPortable()throws {
    let(store,root)=try fixture();var plan=CollectionProductionPlan(name:"Safe portable packet",runs:[.init(objectID:store.project!.objects[0].id)])
    var extra=CollectionExtraLine(name:" =SUM(1,2)");extra.quantity="1";extra.unitPrice="2.5";extra.currency="USD";extra.supplier="\t@DECLARED";extra.sku="A,\"B\"";plan.extras=[extra]
    try save(store,plan);let job=try capture(store,plan),archive=try store.collectionArchive(job),csv=String(decoding:archive.files["BOM.csv"]!,as:UTF8.self)
    XCTAssertTrue(csv.contains("' =SUM(1,2)"));XCTAssertTrue(csv.contains("'\t@DECLARED"));XCTAssertTrue(csv.contains("A,\"\"B\"\""));XCTAssertEqual(archive.revision.plan.extras[0].name,extra.name)
    let zip=root.appendingPathComponent("Collection.zip");_ = try call(store,"export",["job_id":job.id.uuidString,"path":zip.path]);XCTAssertTrue(FileManager.default.fileExists(atPath:zip.path))
    store.engine.project!.objects=[];store.save()
    let second=root.appendingPathComponent("CopiedLibrary"),repo=try ProjectRepository(root:second),projectID=store.project!.id
    try FileManager.default.copyItem(at:store.repository.url(for:projectID),to:repo.url(for:projectID))
    let copied=StudioStore(repository:repo,seedLibrary:false);copied.fontLibraryPreferences = .init(file:second.appendingPathComponent("Fonts.json"));try copied.engine.open(projectID);defer{copied.engine.project=nil}
    let portable=try copied.collectionArchive(job);XCTAssertEqual(portable.files,archive.files)
    if let folder=ProcessInfo.processInfo.environment["FORM_COLLECTION_PROOF_DIR"] {let out=URL(fileURLWithPath:folder).appendingPathComponent("Safety");try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true);for(name,data)in archive.files {let u=out.appendingPathComponent(name);try FileManager.default.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:u)};let u=URL(fileURLWithPath:folder).appendingPathComponent("Collection.zip");if FileManager.default.fileExists(atPath:u.path){try FileManager.default.removeItem(at:u)};try FileManager.default.copyItem(at:zip,to:u)}
  }
  func testPurchasedComponentProcessFilesDoNotAddManufacturingCostsOrStockAgain()throws {
    let(store,_)=try fixture(),object=store.project!.objects[0]
    let old=try XCTUnwrap(try store.productionCall("form_production_job",arguments:["command":"create","object_id":object.id.uuidString,"quantity":1,"assumptions":["upperThreadFactor":2,"allowanceMetersPerThreadPerItem":0,"laborMinutesPerItem":1,"hourlyLaborRate":10,"laborCurrency":"USD"]]) as? [String:Any])
    let job=try JSONDecoder.form.decode(ProductionJob.self,from:JSONSerialization.data(withJSONObject:old["job"]!)),run=CollectionRun(objectID:object.id)
    var plan=CollectionProductionPlan(name:"Purchased complete patch",runs:[run]),rule=CollectionLineRule(rowID:run.id.uuidString+"/"+object.id.uuidString)
    rule.costBasis = .purchased;rule.unitPrice="3";rule.currency="USD";plan.rules=[rule];plan.processes=[.init(jobID:job.id,kind:"embroidery")]
    let report=try store.collectionPlanning(["definition":try jsonObject(plan)]).report
    XCTAssertEqual(report.completeTotal,"3");XCTAssertTrue(report.rows.filter{["thread","labor"].contains($0.role)}.allSatisfy{$0.excludedReason != nil});XCTAssertTrue(report.stock.isEmpty)
  }
  func testUnknownFieldsBadLineageAndOversizedAssetRejectBeforePublication()throws {
    let(store,root)=try fixture(),plan=CollectionProductionPlan(name:"Guarded",runs:[.init(objectID:store.project!.objects[0].id)])
    let before=store.project!,history=store.engine.undoStack.count;var raw=try jsonObject(plan) as! [String:Any];raw["unknown_rate"]="1"
    XCTAssertThrowsError(try store.preflightCollectionHandoff("form_production_job",["kind":"collection","command":"save_plan","definition":raw]));XCTAssertEqual(store.project,before)
    try save(store,plan);let saved=store.project!
    XCTAssertThrowsError(try store.preflightCollectionHandoff("form_production_job",["kind":"collection","command":"create","plan_id":plan.id.uuidString,"supersedes_job_id":UUID().uuidString]));XCTAssertEqual(store.project,saved)
    let assets=store.repository.url(for:saved.id).appendingPathComponent("Assets");try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true);let file=assets.appendingPathComponent("oversized.png");FileManager.default.createFile(atPath:file.path,contents:nil);let handle=try FileHandle(forWritingTo:file);try handle.truncate(atOffset:UInt64(CollectionLimits.fileBytes+1));try handle.close()
    store.engine.project!.objects[0].artwork!.elements[0].asset="oversized.png";let oversized=store.project!
    XCTAssertThrowsError(try call(store,"preflight",["plan_id":plan.id.uuidString]));XCTAssertEqual(store.project,oversized);XCTAssertEqual(store.engine.undoStack.count,history+1)
    XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("not-created.zip").path))
  }

  func testPureCollectionCaptureDoesNotRebuildEvictedAssemblyMeshOrAdvanceCloth()throws {
    let(store,_)=try fixture();let(source,definition)=try PatternAssemblySamples.roundedPouch();var p=source,assembly=try p.makeObject(recipeID:"patternAssembly",name:"Source-backed assembly");assembly.patternAssembly=definition;p.objects.append(assembly)
    store.engine.project=p;store.showingHome=false;store.engine.selection=[assembly.id];try store.cloth.activate(assembly.id)
    let builds=AssemblyProducts.builds,identity=store.cloth.preview.source,positions=store.cloth.preview.frame?.positionsMm,diagnostics=store.cloth.preview.diagnostics
    AssemblyProducts.clear()
    let plan=CollectionProductionPlan(name:"Records only",runs:[.init(objectID:assembly.id)]);try save(store,plan);_ = try capture(store,plan)
    XCTAssertEqual(AssemblyProducts.builds,builds);XCTAssertEqual(store.cloth.preview.source,identity);XCTAssertEqual(store.cloth.preview.frame?.positionsMm,positions);XCTAssertEqual(store.cloth.preview.diagnostics,diagnostics)
    store.cloth.clear()
  }
  func testCollectionAndShotMetadataHistoryPreserveEvictedActiveAssembly()throws {
    let(store,_)=try fixture();let(source,definition)=try PatternAssemblySamples.roundedPouch()
    var p=source,assembly=try p.makeObject(recipeID:"patternAssembly",name:"Active assembly")
    assembly.patternAssembly=definition;p.objects.append(assembly);p.camera.viewportAspect=1.5
    let shot=StudioShot(name:"Existing composition",camera:p.camera,referenceAspect:1.5)
    p.studioPresentation = .init(shots:[shot]);store.engine.project=p;store.showingHome=false
    try store.cloth.activate(assembly.id)
    let builds=AssemblyProducts.builds,identity=store.cloth.preview.source
    let positions=store.cloth.preview.frame?.positionsMm,diagnostics=store.cloth.preview.diagnostics
    defer{store.cloth.clear()};AssemblyProducts.clear()
    func unchanged(file:StaticString=#filePath,line:UInt=#line) {
      XCTAssertEqual(AssemblyProducts.builds,builds,file:file,line:line)
      XCTAssertEqual(store.cloth.preview.source,identity,file:file,line:line)
      XCTAssertEqual(store.cloth.preview.frame?.positionsMm,positions,file:file,line:line)
      XCTAssertEqual(store.cloth.preview.diagnostics,diagnostics,file:file,line:line)
    }
    let plan=CollectionProductionPlan(name:"Metadata only",runs:[.init(objectID:assembly.id)])
    try save(store,plan);unchanged();_ = try capture(store,plan);unchanged()
    store.undo();unchanged();store.redo();unchanged()
    store.studioShots.name="Metadata rename";try store.studioShots.rename(shot.id);unchanged()
    store.undo();unchanged();XCTAssertEqual(store.project?.studioPresentation?.shots[0].name,shot.name)
    store.redo();unchanged();XCTAssertEqual(store.project?.studioPresentation?.shots[0].name,"Metadata rename")
    let before=store.project;store.engine.undo();store.historyRecordsChanged(from:before);unchanged()
    // A real panel edit still takes the established source/history reset path.
    try store.engine.edit("Source edit"){value in value.objects[0].artwork?.elements[0].color="#CC5533"}
    store.undo();XCTAssertGreaterThan(AssemblyProducts.builds,builds)
  }
  func testActualNativeCaptureButtonPublishesOneRevisionAfterSaveAndKeepsSourceExact()throws {
    let(store,_)=try fixture(),before=store.project!,draft=CollectionDraft(project:before);draft.runs=[.init(.init(objectID:before.objects[0].id))]
    let(window,view)=host(CollectionProductionView(store:store,draft:draft).padding(20).background(Palette.paper));defer{window.close()}
    try press("collection-save",window:window,view:view);let saved=store.project!,history=store.engine.undoStack.count
    try press("collection-capture",window:window,view:view)
    XCTAssertEqual(store.project?.collectionProduction?.captures.count,1,draft.error);XCTAssertEqual(store.engine.undoStack.count,history+1);XCTAssertEqual(store.project?.objects,before.objects);XCTAssertEqual(store.project?.camera,before.camera)
    store.engine.undo();XCTAssertEqual(store.project,saved)
  }

  func testCapturedFoldedCuttingFilesUseActualPhysicalLayoutAndRemainExactAfterSourceDeletion()throws {
    let(store,_)=try fixture();var p=Project(name:"Actual folded cut allocation"),stock=TextileDesign.materials.first{$0.id=="flight-nylon"}!
    stock.fabric?.usableWidth=200;stock.fabric?.inventoryMeters=1;p.materials=[stock]
    var piece=ArtworkElement(kind:"rectangle",x:0,y:0,width:20,height:30,color:"#FF00FF")
    piece.sewingPiece = .init(name:"Original two-ply panel");piece.sewingPiece?.seamAllowance=0;piece.sewingPiece?.cutQuantity=2;piece.sewingPiece?.materialID=stock.id
    let sourceOnly=ArtworkElement(kind:"text",x:25,y:0,width:60,height:20,text:"SOURCE ART MUST STAY ORIGINAL")
    var owner=try p.makeObject(recipeID:"artboard"),art=Artwork(elements:[piece,sourceOnly]),layout=SewingCutLayout(materialID:stock.id,stockWidth:200)
    layout.stock = .foldedPair;layout.margin=0;layout.spacing=0.1;layout.costPerSquareMeter=10;layout.costCurrency="USD";layout.placements=[.init(elementID:piece.id,copies:[1,2],x:0,y:0)];art.sewingLayout=layout;owner.artwork=art
    var product=try p.makeObject(recipeID:"patternAssembly",name:"Sewn actual panels")
    let panels=[1,2].map{PatternPanelPlacement(panel:.init(elementID:piece.id,copy:$0),pose:.init(),material:stock,densityGSM:180)}
    product.patternAssembly = .init(sourceObjectID:owner.id,panels:panels,seamIDs:[]);p.objects=[owner,product];store.engine.project=p
    let run=CollectionRun(objectID:product.id,quantity:3,includeAttachments:false);var plan=CollectionProductionPlan(name:"Actual folded cutting packet",runs:[run]);plan.layouts=[.init(runID:run.id,objectID:owner.id)]
    try save(store,plan);let before=store.project!,job=try capture(store,plan),archive=try store.collectionArchive(job)
    XCTAssertEqual(store.project!.objects,before.objects);XCTAssertEqual(archive.revision.report.completeTotal,"0.18")
    let pdfName=try XCTUnwrap(archive.files.keys.first{$0.hasPrefix("Patterns/") && $0.hasSuffix(".pdf")}),svgName=String(pdfName.dropLast(4))+".svg"
    let pdf=try XCTUnwrap(PDFDocument(data:archive.files[pdfName]!)),box=try XCTUnwrap(pdf.page(at:0)).bounds(for:.mediaBox)
    XCTAssertEqual(pdf.pageCount,1);XCTAssertEqual(box.width*25.4/72,100,accuracy:0.001);XCTAssertEqual(box.height*25.4/72,30,accuracy:0.001)
    let svg=String(decoding:archive.files[svgName]!,as:UTF8.self)
    let document=try XMLDocument(data:archive.files[svgName]!,options:[])
    XCTAssertEqual(document.rootElement()?.attribute(forName:"width")?.stringValue.map{Double(String($0.dropLast(2)))},100);XCTAssertEqual(document.rootElement()?.attribute(forName:"height")?.stringValue.map{Double(String($0.dropLast(2)))},30);XCTAssertTrue(svg.contains("form-cutting-layout"));XCTAssertFalse(svg.contains(sourceOnly.text))
    let source=try JSONDecoder.form.decode(CollectionSource.self,from:archive.files["Source.json"]!)
    XCTAssertEqual(source.project.objects.first{$0.id==owner.id}?.artwork,art)
    try store.engine.edit("Remove live source",source:"test"){$0.objects=[]};store.changed()
    XCTAssertEqual(try store.collectionArchive(job).files,archive.files)
    if let folder=ProcessInfo.processInfo.environment["FORM_COLLECTION_PROOF_DIR"] {let out=URL(fileURLWithPath:folder).appendingPathComponent("Cutting");try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true);for(name,data)in archive.files {let u=out.appendingPathComponent(name);try FileManager.default.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:u)}}
  }

  func testArchivedPlanAndPhysicalSourceComparisonsRemainIndependent()throws {
    let(store,_)=try fixture(),plan=CollectionProductionPlan(name:"Original reviewed plan",runs:[.init(objectID:store.project!.objects[0].id)])
    try save(store,plan);let job=try capture(store,plan),files=try store.collectionArchive(job).files
    var changed=plan;changed.name="Revised commercial plan";try save(store,changed)
    var state=try call(store,"get",["job_id":job.id.uuidString])
    XCTAssertEqual(state["current_plan"] as? String,"changed");XCTAssertEqual(state["current_source"] as? String,"matches")
    try store.engine.edit("Changed physical source",source:"test"){$0.objects[0].name="Revised original patch"}
    state=try call(store,"get",["job_id":job.id.uuidString]);XCTAssertEqual(state["current_source"] as? String,"changed");XCTAssertEqual(state["current_plan"] as? String,"changed")
    store.engine.undo();_ = try call(store,"remove_plan",["plan_id":plan.id.uuidString])
    state=try call(store,"get",["job_id":job.id.uuidString]);XCTAssertEqual(state["current_plan"] as? String,"missing");XCTAssertEqual(state["current_source"] as? String,"matches")
    XCTAssertEqual(try store.collectionArchive(job).files,files)
  }

}

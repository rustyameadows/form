import AppKit
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class DecorationPreparationEditingTests:XCTestCase {
  private func fixture()throws->(StudioStore,ProductObject) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false);store.fontLibraryPreferences = .init(file:root.appendingPathComponent("FontPreferences.json"))
    var p=Project(name:"Transfer preparation"),object=try p.makeObject(recipeID:"artboard",name:"ORBITAL / Transfer artwork",parameters:["width":100,"depth":80])
    var text=ArtworkElement(kind:"text",x:10,y:15,width:80,height:18,text:"Orbital / 001",color:"#15324B",fontSize:18)
    var type=Typography();type.fontName="Georgia";type.caseTreatment="uppercase";text.typography=type
    var art=Artwork(background:"#FFFFFF",elements:[text,.init(kind:"ellipse",x:20,y:45,width:60,height:20,color:"#C7573B")],bleed:0);art.backgroundOpacity=0
    object.artwork=art;p.objects=[object];store.engine.project=p;try store.engine.flush();return(store,object)
  }
  private func args(_ objectID:UUID,process:DecorationProcess = .dtf)throws->[String:Any] {
    var options=DecorationPreparationOptions(process:process);options.dpi=127
    return ["kind":"decoration","command":"create","object_id":objectID.uuidString,"preparation":try jsonObject(options),"name":"ORBITAL / archived transfer","quantity":12]
  }
  private func create(_ store:StudioStore,_ id:UUID)throws->DecorationPreparation {
    _ = try store.engine.call("form_production_job",arguments:args(id));return try XCTUnwrap(store.project?.decorationPreparations?.last)
  }
  private func export(_ store:StudioStore,_ job:DecorationPreparation,_ label:String,format:String="folder")throws->URL {
    let path=store.repository.root.appendingPathComponent(label+(format=="zip" ? ".zip":""))
    _ = try store.engine.call("form_production_job",arguments:["kind":"decoration","command":"export","job_id":job.id.uuidString,"format":format,"path":path.path]);return path
  }
  private func folderBytes(_ folder:URL)throws->[String:Data] {
    let names=FileManager.default.enumerator(atPath:folder.path)!.compactMap{$0 as? String}
    var result:[String:Data]=[:]
    for name in names {
      let file=folder.appendingPathComponent(name)
      if (try file.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile==true {result[name]=try Data(contentsOf:file)}
    }
    return result
  }
  func testCaptureIsOneUndoPreservesSourceResourcesAndReopensSchemaThirtyEight()throws {
    let(store,object)=try fixture(),baseline=store.project!
    let manifest=store.repository.url(for:baseline.id).appendingPathComponent("Manifest.json")
    func resources()throws->[String] {(try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [String:Any])["objects"].map{($0 as! [[String:Any]]).map{$0["file"] as! String}}!}
    let files=try resources(),job=try create(store,object.id)
    XCTAssertEqual(store.engine.undoStack.count,1);XCTAssertEqual(store.project!.objects,baseline.objects);XCTAssertEqual(store.project!.camera,baseline.camera)
    XCTAssertEqual(try resources(),files);XCTAssertEqual(store.project!.schemaVersion,38)
    RunLoop.main.run(until:Date().addingTimeInterval(0.45))
    let reopened=try store.repository.load(baseline.id);XCTAssertEqual(reopened.decorationPreparations?.map(\.id),[job.id]);XCTAssertEqual(reopened.objects,baseline.objects)
    let revision=try store.decorationRevision(job);XCTAssertEqual(revision.options.process,.dtf);XCTAssertEqual(revision.quantity,12)
    let review=try XCTUnwrap(revision.files.first{$0.name=="Review.pdf"}),bytes=try DecorationPacketAssets.read(review.digest,repository:store.repository,projectID:baseline.id,expectedBytes:review.bytes)
    let pdf=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:bytes as CFData)!));XCTAssertGreaterThanOrEqual(pdf.numberOfPages,2)
    XCTAssertEqual(pdf.page(at:2)!.getBoxRect(.mediaBox).width/TypographyEngine.pointsPerMM,210,accuracy:0.0001)
    XCTAssertTrue(revision.files.contains{$0.name=="Report.json" && $0.role=="reference"})
    store.engine.undo();XCTAssertEqual(store.project,baseline);store.engine.redo();XCTAssertEqual(store.project!.decorationPreparations?.last,job)
  }
  func testArchiveExportsRemainByteExactAfterSourceDeletionAndPackageReopen()throws {
    let(store,object)=try fixture(),job=try create(store,object.id),id=store.project!.id
    let folder=try export(store,job,"packet-before"),original=try folderBytes(folder)
    if let dir=ProcessInfo.processInfo.environment["FORM_DECORATION_PROOF_DIR"] {
      let target=URL(fileURLWithPath:dir).appendingPathComponent("archive");try? FileManager.default.removeItem(at:target);try FileManager.default.copyItem(at:folder,to:target)
    }
    try store.engine.edit("Deleted live source"){p in p.objects=[]};store.changed()
    try store.engine.open(id)
    let archived=try XCTUnwrap(store.project!.decorationPreparations?.first)
    let after=try folderBytes(export(store,archived,"packet-after"))
    XCTAssertEqual(after,original);XCTAssertTrue(after.keys.contains("Source.json"));XCTAssertTrue(after.keys.contains("Color.png"))
    let state=try store.engine.call("form_production_job",arguments:["kind":"decoration","command":"get","job_id":job.id.uuidString,"include_source":true]) as! [String:Any]
    XCTAssertEqual(state["current_source"] as? String,"missing")
    let source=state["source"] as! [String:Any],objects=source["objects"] as! [[String:Any]]
    let art=objects.first{$0["id"] as? String==object.id.uuidString}!["artwork"] as! [String:Any]
    XCTAssertEqual((art["elements"] as! [[String:Any]])[0]["text"] as? String,"Orbital / 001")
    let zip=try export(store,archived,"packet-zip",format:"zip");XCTAssertGreaterThan(try Data(contentsOf:zip).count,1000)
  }
  func testRejectedInputsStaleSourceAndCorruptArchivePreserveStateAndDestination()throws {
    let(store,object)=try fixture();let baseline=store.project!
    var bad=try args(object.id);bad["quantity"]=true
    XCTAssertThrowsError(try store.engine.call("form_production_job",arguments:bad));XCTAssertEqual(store.project,baseline);XCTAssertTrue(store.engine.undoStack.isEmpty)
    var options=DecorationPreparationOptions(process:.dtf);options.dpi=127
    let plan=try DecorationGeometry(project:baseline,objectID:object.id,options:options,assets:store.repository.url(for:baseline.id).appendingPathComponent("Assets"))
    try store.engine.edit("Changed source"){p in p.objects[0].artwork!.elements[0].text="Changed source"}
    let changed=store.project!,count=store.engine.undoStack.count
    XCTAssertThrowsError(try store.captureDecoration(plan,name:"Stale",quantity:1,notes:nil));XCTAssertEqual(store.project,changed);XCTAssertEqual(store.engine.undoStack.count,count)
    let job=try create(store,object.id),revision=try store.decorationRevision(job),file=try XCTUnwrap(revision.files.first{$0.role=="delivery"})
    try Data("Corrupt archive".utf8).write(to:DecorationPacketAssets.url(file.digest,repository:store.repository,projectID:baseline.id))
    let before=store.project!,target=store.repository.root.appendingPathComponent("preserve.zip");try Data("KEEP".utf8).write(to:target)
    XCTAssertThrowsError(try store.engine.call("form_production_job",arguments:["kind":"decoration","command":"export","job_id":job.id.uuidString,"format":"zip","path":target.path]))
    XCTAssertEqual(try Data(contentsOf:target),Data("KEEP".utf8));XCTAssertEqual(store.project,before)
  }
  func testArchivedExportKeepsCurrentNativeTextFocusSelectionAndUnsavedWords()throws {
    _=NSApplication.shared;let(store,object)=try fixture(),job=try create(store,object.id),p=store.project!
    let window=NSWindow(contentRect:.init(x:0,y:0,width:900,height:700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:window.contentView!.bounds),session=store.artworkSession
    canvas.session=session;session.canvas=canvas;session.objectID=object.id;session.choose([p.objects[0].artwork!.elements[0].id]);window.contentView=canvas;canvas.synchronize();defer{canvas.finishText();window.close()}
    canvas.beginText(p.objects[0].artwork!.elements[0]);let editor=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    editor.undoManager?.groupsByEvent=false;editor.setSelectedRange(.init(location:editor.string.utf16.count,length:0));editor.insertText(" LIVE",replacementRange:.init(location:NSNotFound,length:0))
    let before=store.project!,selected=editor.selectedRange(),count=store.engine.undoStack.count
    _ = try export(store,job,"while-editing")
    XCTAssertTrue(window.firstResponder === editor);XCTAssertTrue(session.editingText);XCTAssertEqual(editor.selectedRange(),selected);XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,count)
  }
  private func preparationWindow(_ store:StudioStore,_ object:ProductObject,_ draft:DecorationPreparationDraft)throws->(NSWindow,NSView) {
    _=NSApplication.shared
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1080,height:760),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let view=NSHostingView(rootView:DecorationPreparationView(store:store,objectID:object.id,draft:draft));window.contentView=view;window.setFrameOrigin(.init(x:-10000,y:-10000));window.orderBack(nil)
    view.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.08));view.layoutSubtreeIfNeeded();return(window,view)
  }
  private func fields(_ view:NSView)->[NSTextField] {([view as? NSTextField].compactMap{$0})+view.subviews.flatMap{fields($0)}}
  private func enter(_ value:String,placeholder:String,window:NSWindow,view:NSView)throws {
    let field=try XCTUnwrap(fields(view).first{$0.isEditable && $0.placeholderString==placeholder})
    window.makeFirstResponder(field);let editor=try XCTUnwrap(window.firstResponder as? NSTextView);editor.selectAll(nil);editor.insertText(value,replacementRange:.init(location:NSNotFound,length:0));RunLoop.main.run(until:Date().addingTimeInterval(0.02))
  }
  private func captureButton(window:NSWindow,view:NSView)throws {
    view.layoutSubtreeIfNeeded();let local=NSPoint(x:view.bounds.maxX-130,y:view.isFlipped ? view.bounds.maxY-35:view.bounds.minY+35),location=view.convert(local,to:nil),stamp=ProcessInfo.processInfo.systemUptime
    let down=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:stamp,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
    let up=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:stamp+0.02,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0))
    // Exercise the real SwiftUI Button in this offscreen test window, with no
    // event injection into FORM or another process and no direct draft.capture().
    NSApp.postEvent(up,atStart:false);NSApp.sendEvent(down);NSApp.sendEvent(up);RunLoop.main.run(until:Date().addingTimeInterval(0.06))
  }
  func testNativeCaptureButtonCommitsFocusedDPIWithoutTabAndOneUndo()throws {
    let(store,object)=try fixture(),baseline=store.project!,draft=DecorationPreparationDraft(store:store,objectID:object.id),builds=draft.geometryBuilds
    let(window,view)=try preparationWindow(store,object,draft);defer{window.close()}
    try enter("127.5",placeholder:"Requested DPI",window:window,view:view)
    if let dir=ProcessInfo.processInfo.environment["FORM_DECORATION_PROOF_DIR"] {
      view.layoutSubtreeIfNeeded();let image=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:image)
      try XCTUnwrap(image.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:dir).appendingPathComponent("native-preparation.png"))
    }
    XCTAssertEqual(draft.geometryBuilds,builds,"Typing and view layout must not rebuild vector geometry")
    try captureButton(window:window,view:view)
    let job=try XCTUnwrap(store.project?.decorationPreparations?.last),revision=try store.decorationRevision(job)
    XCTAssertEqual(revision.options.dpi,127.5);XCTAssertEqual(store.engine.undoStack.count,1)
    XCTAssertEqual(store.project!.objects,baseline.objects);XCTAssertEqual(store.project!.camera,baseline.camera)
    store.engine.undo();XCTAssertEqual(store.project,baseline)
  }
  func testNativeHTVCaptureButtonKeepsFocusedWeedPaddingAndMaterialDeclarations()throws {
    let(store,object)=try fixture(),baseline=store.project!,draft=DecorationPreparationDraft(store:store,objectID:object.id)
    draft.chooseProcess(.htv);let key=try XCTUnwrap(draft.plan?.regions.first?.paintKey);draft.materials[key]="User selected vinyl / SKU unverified"
    let(window,view)=try preparationWindow(store,object,draft);defer{window.close()}
    try enter("4.25",placeholder:"Weed padding (mm)",window:window,view:view);try captureButton(window:window,view:view)
    let job=try XCTUnwrap(store.project?.decorationPreparations?.last),revision=try store.decorationRevision(job)
    XCTAssertEqual(revision.options.weedMargin,4.25);XCTAssertTrue(revision.options.mirror)
    XCTAssertEqual(revision.options.layerMaterials.first?.name,"User selected vinyl / SKU unverified")
    XCTAssertEqual(store.engine.undoStack.count,1);store.engine.undo();XCTAssertEqual(store.project,baseline)
  }
  func testNativeCaptureRejectsInvalidFocusedDPIAndClosingDraftKeepsExactState()throws {
    let(store,object)=try fixture(),baseline=store.project!,draft=DecorationPreparationDraft(store:store,objectID:object.id)
    let(window,view)=try preparationWindow(store,object,draft);defer{window.close()}
    for value in ["nan","601","-1",""] {
      try enter(value,placeholder:"Requested DPI",window:window,view:view);try captureButton(window:window,view:view)
      XCTAssertTrue(draft.error.contains("DPI"));XCTAssertEqual(draft.dpi,value);XCTAssertEqual(store.project,baseline);XCTAssertTrue(store.engine.undoStack.isEmpty)
    }
    try enter("144.5",placeholder:"Requested DPI",window:window,view:view);window.close()
    XCTAssertEqual(store.project,baseline);XCTAssertTrue(store.engine.undoStack.isEmpty)
    store.engine.project=Project(name:"Different project");let switched=store.project!
    XCTAssertFalse(draft.capture());XCTAssertEqual(store.project,switched);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testOriginalICCAndRecoverableImportBytesAreArchivedWithoutReplacingInkIntent()throws {
    let(store,object)=try fixture();var p=store.project!
    let assets=store.repository.url(for:p.id).appendingPathComponent("Assets")
    let profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"));try profile.store(in:assets)
    let ink=ProductionInk(kind:.processCMYK,components:.init(0.125,0.2718281828,0.5,0.01),profile:profile.reference)
    let color=try SwatchCommands.save(in:&p,name:"Original process declaration",color:profile.inkPreview(ink),printInk:ink);p.objects[0].artwork!.elements[1].fillSwatchID=color
    p.objects[0].artwork!.outputColorProfile=profile.reference
    let original=Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><text>Recoverable original words</text></svg>".utf8)
    try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true);try original.write(to:assets.appendingPathComponent("original.svg"))
    p.objects[0].artwork!.imports=[.init(asset:"original.svg",name:"Original editable reference",width:100,height:80)];store.engine.project=p;try store.engine.flush()
    let baseline=store.project!,job=try create(store,object.id),revision=try store.decorationRevision(job)
    let snapshot=try XCTUnwrap(revision.files.first{$0.name=="Source.json"}),data=try DecorationPacketAssets.read(snapshot.digest,repository:store.repository,projectID:p.id,expectedBytes:snapshot.bytes)
    let source=try JSONDecoder.form.decode(DecorationSourceSnapshot.self,from:data)
    XCTAssertEqual(try JSONEncoder.form.encode(source.objects.first{$0.id==object.id}),try JSONEncoder.form.encode(baseline.objects[0]));XCTAssertEqual(source.swatches.first?.printInk,ink)
    for (name,expected) in [("Assets/original.svg",original),("Assets/"+profile.reference.asset,profile.data)] {
      let file=try XCTUnwrap(revision.files.first{$0.name==name});XCTAssertEqual(try DecorationPacketAssets.read(file.digest,repository:store.repository,projectID:p.id,expectedBytes:file.bytes),expected)
    }
    XCTAssertEqual(store.project!.objects,baseline.objects);XCTAssertEqual(store.project!.swatches,baseline.swatches)
    if let dir=ProcessInfo.processInfo.environment["FORM_DECORATION_PROOF_DIR"] {
      let target=URL(fileURLWithPath:dir).appendingPathComponent("archive-original-assets");try? FileManager.default.removeItem(at:target)
      _ = try store.exportDecorationPacket(job,revision:revision,arguments:["format":"folder","path":target.path])
    }
  }

  func testOversizedOriginalAssetSetRejectsBeforeArchiveWritesOrHistory()throws {
    let(store,object)=try fixture();var p=store.project!
    let assets=store.repository.url(for:p.id).appendingPathComponent("Assets");try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    var imports:[ArtworkImport]=[]
    for index in 0..<2 {
      let name="large-original-\(index).svg",url=assets.appendingPathComponent(name)
      XCTAssertTrue(FileManager.default.createFile(atPath:url.path,contents:Data()))
      let file=try FileHandle(forWritingTo:url);try file.truncate(atOffset:64_000_000);try file.close()
      imports.append(.init(asset:name,name:"Recoverable original",width:100,height:80))
    }
    p.objects[0].artwork!.imports=imports;store.engine.project=p;let baseline=store.project!,count=store.engine.undoStack.count
    XCTAssertThrowsError(try store.engine.call("form_production_job",arguments:args(object.id))) {error in XCTAssertTrue(error.localizedDescription.contains("budget"))}
    XCTAssertEqual(store.project,baseline);XCTAssertEqual(store.engine.undoStack.count,count)
    XCTAssertFalse(FileManager.default.fileExists(atPath:store.repository.url(for:p.id).appendingPathComponent("Production/Decorations").path))
  }

}

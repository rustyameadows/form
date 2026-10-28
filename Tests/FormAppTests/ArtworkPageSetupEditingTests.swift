import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class ArtworkPageSetupEditingTests:XCTestCase {
  private func fixture()throws->(StudioStore,URL,UUID) {
    _=NSApplication.shared;let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false);store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    var p=Project(name:"Physical page"),o=try p.makeObject(recipeID:"artboard",parameters:["width":200,"depth":150]),art=Artwork(background:"#D8E6E0",elements:[.init(kind:"rectangle",x:-3,y:30,width:30,height:80,color:"#C45339"),.init(kind:"text",x:18,y:18,width:165,height:16,text:"FORM / PHYSICAL PAGE",color:"#243C3A",fontSize:18)],bleed:3)
    art.safeInset=5;o.artwork=art;p.objects=[o];store.engine.project=p;try store.engine.flush();store.mode = .artwork;store.artworkSession.objectID=o.id
    addTeardownBlock{MainActor.assumeIsolated{store.artworkSession.canvas?.finishText();store.cloth.clear();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}}
    return(store,root,o.id)
  }
  private func fields(_ v:NSView)->[NSTextField] {([v as? NSTextField].compactMap{$0})+v.subviews.flatMap{fields($0)}}
  private func ax(_ v:Any,_ identifier:String)->(any NSAccessibilityProtocol)? {
    guard let value=v as? any NSAccessibilityProtocol else{return nil}
    if value.accessibilityIdentifier()==identifier{return value}
    for child in value.accessibilityChildren() ?? [] {if let found=ax(child,identifier){return found}}
    return nil
  }
  private func footerButtons(_ view:NSView)throws->[NSRect] {
    let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
    let step=3.0,w=Int(view.bounds.width/step),h=Int(view.bounds.height/step),scale=Double(bitmap.pixelsWide)/view.bounds.width
    var mask=[Bool](repeating:false,count:w*h),seen=mask
    for y in 0..<h {for x in 0..<w {
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
  private func clickApply(window:NSWindow,view:NSView)throws {
    let location:NSPoint
    if let button=ax(view,"apply-page-setup"),!button.accessibilityFrame().isEmpty {let r=window.convertFromScreen(button.accessibilityFrame());location = .init(x:r.midX,y:r.midY)}
    else {let all=try footerButtons(view),bottom=try XCTUnwrap(all.map(\.midY).max()),row=all.filter{abs($0.midY-bottom)<18}.sorted{$0.minX<$1.minX},r=try XCTUnwrap(row.first);XCTAssertGreaterThanOrEqual(row.count,2);location=view.convert(.init(x:r.midX,y:view.isFlipped ? r.midY:view.bounds.height-r.midY),to:nil)}
    let stamp=ProcessInfo.processInfo.systemUptime,down=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:stamp,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)),up=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:stamp+0.02,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0))
    NSApp.postEvent(up,atStart:false);NSApp.sendEvent(down);NSApp.sendEvent(up);RunLoop.main.run(until:Date().addingTimeInterval(0.1))
  }
  func testNativeFocusedStringsApplyWithoutTabOneUndoAndCleanUndoDraftSync()throws {
    let(store,_,id)=try fixture(),before=store.project!,draft=ArtworkPageSetupDraft(store:store,objectID:id)
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:450,height:350),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;defer{window.close()}
    let host=NSHostingView(rootView:ArtworkPageSetupControls(store:store,objectID:id,draft:draft).padding(24).frame(width:450,height:350).background(Palette.paper));window.contentView=host;window.orderBack(nil);host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.08));host.layoutSubtreeIfNeeded()
    let field=try XCTUnwrap(fields(host).first{$0.placeholderString=="None if blank"});window.makeFirstResponder(field);let editor=try XCTUnwrap(window.firstResponder as? NSTextView);editor.selectAll(nil);editor.insertText("7.125",replacementRange:.init(location:NSNotFound,length:0));RunLoop.main.run(until:Date().addingTimeInterval(0.03));XCTAssertEqual(draft.safe,"7.125")
    if let path=ProcessInfo.processInfo.environment["FORM_PAGE_SETUP_PROOF_DIR"],let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {host.cacheDisplay(in:host.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path).appendingPathComponent("native-page-controls.png"))}
    try clickApply(window:window,view:host)
    RunLoop.main.run(until:Date().addingTimeInterval(0.03));XCTAssertEqual(store.project!.objects[0].artwork!.safeInset,7.125,draft.error);XCTAssertEqual(store.engine.undoStack.count,1);XCTAssertEqual(store.project!.camera,before.camera)
    window.makeFirstResponder(nil);draft.focused=[];store.undo();draft.synchronize();XCTAssertEqual(store.project,before);XCTAssertEqual(draft.safe,"5");store.redo();draft.synchronize();XCTAssertEqual(draft.safe,"7.125")
    draft.safe="bad";store.undo();draft.synchronize();XCTAssertEqual(draft.safe,"bad");let p=store.project,count=store.engine.undoStack.count;try clickApply(window:window,view:host);XCTAssertFalse(draft.error.isEmpty);XCTAssertEqual(store.project,p);XCTAssertEqual(store.engine.undoStack.count,count)
  }
  func testUntouchedUnderlyingValuesExactUnitParsingInvalidAndStaleProjectGuards()throws {
    let(store,_,id)=try fixture();var p=store.project!;p.objects[0].artwork!.bleed=3.123456789012345;store.engine.project=p
    let draft=ArtworkPageSetupDraft(store:store,objectID:id);draft.safe="0.25 in";XCTAssertTrue(draft.apply(),draft.error);XCTAssertEqual(store.project!.objects[0].artwork!.bleed,3.123456789012345);XCTAssertEqual(store.project!.objects[0].artwork!.safeInset,6.35)
    for value in ["75","nan","-2","1 mm junk",String(repeating:"1",count:129)] {draft.safe=value;let before=store.project,count=store.engine.undoStack.count;XCTAssertFalse(draft.apply());XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,count);XCTAssertEqual(draft.safe,value)}
    store.engine.project=Project(name:"Different source");let before=store.project;draft.safe="5";XCTAssertFalse(draft.apply());XCTAssertEqual(store.project,before)
  }
  func testReadOnlyPreflightReviewAndPDFExportKeepNativeDraftCaretAndHistoryExact()throws {
    let(store,root,id)=try fixture(),window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:950,height:700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:window.contentView!.bounds),session=store.artworkSession;canvas.session=session;session.canvas=canvas;window.contentView=canvas;canvas.synchronize();canvas.beginText(store.project!.objects[0].artwork!.elements[1]);let view=try XCTUnwrap(window.firstResponder as? CanvasTextView);view.undoManager?.groupsByEvent=false;view.setSelectedRange(.init(location:0,length:4));let range=view.selectedRange(),native=NSAttributedString(attributedString:view.attributedString()),before=store.project!,undo=store.engine.undoStack.count
    defer{window.makeFirstResponder(nil);canvas.finishText();window.close()}
    let options:[String:Any]=["area":"bleed","crop_marks":true,"mark_gap_mm":1,"mark_length_mm":3]
    let report=try store.exportArtwork(object:before.objects[0],arguments:["format":"preflight","page_output":options]) as! [String:Any]
    XCTAssertEqual(report["appearance_validated"] as? Bool,false);XCTAssertEqual(report["assets_validated"] as? Bool,false);XCTAssertNil(report["path"])
    let model=ArtworkPageReviewModel(store:store,objectID:id);model.cropMarks=true;model.refresh();XCTAssertNotNil(model.proof,model.error);XCTAssertTrue(model.export(path:root.appendingPathComponent("page.pdf")),model.error)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo);XCTAssertTrue(window.firstResponder === view);XCTAssertEqual(view.selectedRange(),range);XCTAssertTrue(GlyphEngine.nativeEqual(view.attributedString(),native))
    XCTAssertThrowsError(try store.preflightPageSetupHandoff("form_edit_artwork",["object_id":id.uuidString,"command":"page_setup","safe_inset":75]));XCTAssertEqual(store.project,before);XCTAssertTrue(window.firstResponder === view)
  }
  func testExplicitPageOptionsRejectSelectorsBeforeReplacingExistingFile()throws {
    let(store,root,id)=try fixture(),object=store.project!.objects[0],path=root.appendingPathComponent("keep.pdf"),sentinel=Data("ORIGINAL DELIVERY".utf8);try sentinel.write(to:path)
    let options:[String:Any]=["area":"bleed"],before=store.project
    for conflict in [["element_ids":[]],["roles":[]],["pattern_pieces":false],["ink_output":"plates"],["cut_layout":true],["page_output":["area":"bleed","unknown":2]],["format":"png"],["outline_text":1]] as [[String:Any]] {
      var args:[String:Any]=["object_id":id.uuidString,"format":"pdf","path":path.path,"page_output":options];args.merge(conflict){_,v in v};XCTAssertThrowsError(try store.exportArtwork(object:object,arguments:args));XCTAssertEqual(try Data(contentsOf:path),sentinel);XCTAssertEqual(store.project,before)
    }
    XCTAssertThrowsError(try store.preflightPageSetupHandoff("form_batch",["operations":[["name":"form_export_artwork","arguments":["object_id":id.uuidString,"format":"preflight","page_output":options]]]]));XCTAssertEqual(store.project,before)
  }
  func testGuideMetadataAndHistoryPreserveActiveEvictedAssemblyWhilePhysicalEditsInvalidate()throws {
    let(store,_,_)=try fixture(),(source,definition)=try PatternAssemblySamples.roundedPouch();var p=source,assembly=try p.makeObject(recipeID:"patternAssembly",name:"Active assembly");assembly.patternAssembly=definition;p.objects.append(assembly);store.engine.project=p;store.showingHome=false;store.engine.selection=[assembly.id];try store.cloth.activate(assembly.id);store.synchronizeScene()
    let authoritative=try PatternAssemblyGenerator.sourceDigest(definition,in:p),preparation=try JSONEncoder.form.encode(definition.preparation),geometry=store.scene!.geometryBuilds
    let objectID=definition.sourceObjectID,draft=ArtworkPageSetupDraft(store:store,objectID:objectID),builds=AssemblyProducts.builds,identity=store.cloth.preview.source,positions=store.cloth.preview.frame?.positionsMm,diagnostics=store.cloth.preview.diagnostics
    defer{store.cloth.clear()};AssemblyProducts.clear();draft.safe="5";draft.bleed="4.25";XCTAssertTrue(draft.apply(),draft.error)
    func unchanged(){store.synchronizeScene();XCTAssertEqual(store.scene!.geometryBuilds,geometry);XCTAssertEqual(AssemblyProducts.builds,builds);XCTAssertEqual(store.cloth.preview.source,identity);XCTAssertEqual(store.cloth.preview.frame?.positionsMm,positions);XCTAssertEqual(store.cloth.preview.diagnostics,diagnostics)}
    unchanged();XCTAssertNotEqual(try PatternAssemblyGenerator.sourceDigest(definition,in:store.project!),authoritative);XCTAssertEqual(ClothSceneSurface.sourceIdentity(object:assembly,project:store.project!),identity)
    XCTAssertEqual(try JSONEncoder.form.encode(store.project!.objects.last!.patternAssembly!.preparation),preparation)
    store.undo();unchanged();store.redo();unchanged()
    var painted=store.project!;painted.objects[0].artwork!.elements[0].color="#CC5533";XCTAssertNotEqual(ClothSceneSurface.sourceIdentity(object:assembly,project:painted),identity)
    try store.engine.edit("Physical pattern change"){$0.objects[0].artwork!.elements[0].color="#CC5533"};store.undo();XCTAssertGreaterThan(AssemblyProducts.builds,builds)
  }
  func testActualPagePDFProofAndLegacyNoOptionDimensionsRemainSourceExact()throws {
    let(store,root,id)=try fixture(),before=store.project!,object=before.objects[0],output=root.appendingPathComponent("Proof");try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    var records:[[String:Any]]=[]
    for (name,area,marks) in [("trim","trim",false),("bleed","bleed",false),("crop","bleed",true),("trim-crop","trim",true)] {
      let result=try store.exportArtwork(object:object,arguments:["format":"pdf","path":output.appendingPathComponent(name+".pdf").path,"page_output":["area":area,"crop_marks":marks]]) as! [String:Any]
      var record=result;record["name"]=name;record["review_guides_printed"]=false;records.append(record)
      let doc=try XCTUnwrap(PDFDocument(url:output.appendingPathComponent(name+".pdf")));XCTAssertEqual(doc.pageCount,1);XCTAssertEqual(doc.page(at:0)?.string?.trimmingCharacters(in:.whitespacesAndNewlines),"FORM / PHYSICAL PAGE")
    }
    let (_,art,g,assets,_,dpi)=try store.pageOutputSource(objectID:id,arguments:["format":"pdf","page_output":["area":"bleed","crop_marks":true]])
    let reference=try ArtworkPagePDF.pdf(art,geometry:g,assets:assets,dpi:dpi,referenceGuides:true);try reference.write(to:output.appendingPathComponent("crop-reference.pdf"));var record=g.metadata;record["name"]="crop-reference";record["review_guides_printed"]=true;records.append(record)
    _ = try store.exportArtwork(object:object,arguments:["format":"pdf","path":output.appendingPathComponent("legacy.pdf").path]);let legacy=try XCTUnwrap(PDFDocument(url:output.appendingPathComponent("legacy.pdf")));XCTAssertEqual(legacy.page(at:0)!.bounds(for:.mediaBox).width/ArtworkPageGeometry.pointsPerMM,200,accuracy:0.001);XCTAssertEqual(legacy.page(at:0)!.bounds(for:.mediaBox).height/ArtworkPageGeometry.pointsPerMM,150,accuracy:0.001)
    var transparent=art;transparent.backgroundOpacity=0.35;transparent.elements=[];try ArtworkPagePDF.pdf(transparent,geometry:g,assets:assets).write(to:output.appendingPathComponent("transparent.pdf"))
    try JSONSerialization.data(withJSONObject:["records":records,"source_unchanged":store.project==before],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"));try JSONEncoder.form.encode(before).write(to:output.appendingPathComponent("Source.json"));XCTAssertEqual(store.project,before)
    if let path=ProcessInfo.processInfo.environment["FORM_PAGE_SETUP_PROOF_DIR"] {let target=URL(fileURLWithPath:path);try? FileManager.default.removeItem(at:target);try FileManager.default.copyItem(at:output,to:target)}
  }
  func testFocusedCleanUndoAndIndependentDraftUnitMeaningSurviveExternalChanges()throws {
    let(store,_,id)=try fixture(),draft=ArtworkPageSetupDraft(store:store,objectID:id)
    draft.safe="7.125";XCTAssertTrue(draft.apply());draft.focused=["safe"];store.undo();draft.synchronize();XCTAssertEqual(draft.safe,"5")
    draft.safe="6";var p=store.project!;p.objects[0].artwork!.unit = .cm;store.engine.project=p;draft.synchronize();XCTAssertEqual(draft.safe,"6");XCTAssertEqual(draft.unit,.mm)
    XCTAssertTrue(draft.apply(),draft.error);XCTAssertEqual(store.project!.objects[0].artwork!.safeInset,6)
    draft.focused=[];draft.synchronize();XCTAssertEqual(draft.unit,.cm);XCTAssertEqual(draft.safe,"0.6")
  }
  func testInvalidReviewOptionsCanRecoverToCachedValidPageWithoutHistoryOrSourceChanges()throws {
    let(store,_,id)=try fixture(),before=store.project!,model=ArtworkPageReviewModel(store:store,objectID:id);model.refresh();XCTAssertNotNil(model.proof,model.error)
    model.gap="nan";model.refresh();XCTAssertNil(model.proof);XCTAssertFalse(model.error.isEmpty)
    model.gap="1";model.refresh();XCTAssertNotNil(model.proof,model.error);XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testPageOutputPreservesICCBoxesAndRequiresExplicitUsedInkPreview()throws {
    let(store,root,id)=try fixture(),profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc")),assets=store.repository.url(for:store.project!.id).appendingPathComponent("Assets");try profile.store(in:assets)
    var p=store.project!;p.objects[0].artwork!.outputColorProfile=profile.reference;store.engine.project=p;let path=root.appendingPathComponent("profile.pdf"),args:[String:Any]=["format":"pdf","path":path.path,"page_output":["area":"bleed","crop_marks":true]]
    let result=try store.exportArtwork(object:p.objects[0],arguments:args) as! [String:Any],data=try Data(contentsOf:path),pdf=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:data as CFData)!)),page=try XCTUnwrap(pdf.page(at:1)),raw=String(decoding:data,as:UTF8.self)
    XCTAssertEqual(result["color_space"] as? String,"CMYK");XCTAssertEqual((result["pdf_output_profile"] as? [String:Any])?["sha256"] as? String,profile.reference.sha256);XCTAssertEqual(page.getBoxRect(.trimBox).width,200*72/25.4,accuracy:0.001);XCTAssertEqual(page.getBoxRect(.mediaBox).width,216*72/25.4,accuracy:0.001);XCTAssertTrue(raw.contains("/N 4"));XCTAssertEqual(store.project,p)
    var swatch=ArtworkSwatch(name:"Named source",color:"#C45339");swatch.printInk = .init(kind:.spot,components:.init(0.1,0.8,0.6,0.1),profile:profile.reference,spotName:"FORM Test Ink")
    p.swatches=[swatch];store.engine.project=p
    // An unused declaration does not poison the physical page route.
    _ = try store.exportArtwork(object:p.objects[0],arguments:args)
    p.objects[0].artwork!.elements[0].fillSwatchID=swatch.id;store.engine.project=p;let sentinel=Data("Preserve declared output".utf8);try sentinel.write(to:path)
    XCTAssertThrowsError(try store.exportArtwork(object:p.objects[0],arguments:args));XCTAssertEqual(try Data(contentsOf:path),sentinel)
    var preview=args;preview["ink_output"]="preview";let report=try store.exportArtwork(object:p.objects[0],arguments:preview) as! [String:Any];XCTAssertEqual(report["ink_output"] as? String,"preview");XCTAssertEqual(report["ink_declarations_encoded"] as? Bool,false);XCTAssertEqual(report["color_space"] as? String,"sRGB");XCTAssertEqual(store.project,p)
  }
  func testSourceOnlyPreflightDoesNotClaimImageValidationAndRenderingRejectsAssetBudgetsBeforeWrites()throws {
    let(store,root,_)=try fixture();var p=store.project!,image=ArtworkElement(kind:"image",x:50,y:50,width:20,height:20);image.asset="missing.png";p.objects[0].artwork!.elements.append(image);store.engine.project=p
    let options:[String:Any]=["area":"bleed"],report=try store.exportArtwork(object:p.objects[0],arguments:["format":"preflight","page_output":options]) as! [String:Any]
    XCTAssertEqual(report["appearance_validated"] as? Bool,false);XCTAssertEqual(report["assets_validated"] as? Bool,false)
    let path=root.appendingPathComponent("existing.pdf"),sentinel=Data("Keep existing".utf8);try sentinel.write(to:path)
    XCTAssertThrowsError(try store.exportArtwork(object:p.objects[0],arguments:["format":"pdf","page_output":options,"path":path.path]));XCTAssertEqual(try Data(contentsOf:path),sentinel)
    let assets=store.repository.url(for:p.id).appendingPathComponent("Assets");try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true);let large=assets.appendingPathComponent("large.png");_ = FileManager.default.createFile(atPath:large.path,contents:Data());let handle=try FileHandle(forWritingTo:large);try handle.truncate(atOffset:33_000_000);try handle.close()
    p.objects[0].artwork!.elements[p.objects[0].artwork!.elements.count-1].asset="large.png";store.engine.project=p
    XCTAssertThrowsError(try store.exportArtwork(object:p.objects[0],arguments:["format":"pdf","page_output":options,"path":path.path])){XCTAssertTrue($0.localizedDescription.contains("32 MB"))};XCTAssertEqual(try Data(contentsOf:path),sentinel)
    XCTAssertEqual(store.project,p)
  }

  private func pdfViews(_ view:NSView)->[PhysicalPDFView] {([view as? PhysicalPDFView].compactMap{$0})+view.subviews.flatMap{pdfViews($0)}}
  func testNativePhysicalPageReviewUsesSharedVectorPDFCanvasWithoutChangingSource()throws {
    let(store,_,id)=try fixture(),before=store.project!,model=ArtworkPageReviewModel(store:store,objectID:id);model.cropMarks=true;model.refresh()
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1120,height:820),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;defer{window.close()}
    let host=NSHostingView(rootView:ArtworkPageReview(store:store,objectID:id,model:model));window.contentView=host;window.orderBack(nil);host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.15));host.layoutSubtreeIfNeeded()
    let view=try XCTUnwrap(pdfViews(host).first);XCTAssertEqual(view.document?.pageCount,1);XCTAssertEqual(view.document?.page(at:0)?.bounds(for:.mediaBox).width ?? 0,216*72/25.4,accuracy:0.001)
    if let path=ProcessInfo.processInfo.environment["FORM_PAGE_SETUP_PROOF_DIR"],let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {host.cacheDisplay(in:host.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path).appendingPathComponent("native-page-review.png"))}
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testLinkedStoryEditsInvalidateReadOnlyPageReviewWithoutDuplicatedSource()throws {
    let(store,_,id)=try fixture();var p=store.project!,capacity=p.objects[0].artwork!.elements[1],second=try p.makeObject(recipeID:"artboard",parameters:["width":200,"depth":150]);capacity.id=UUID();capacity.text="";second.artwork = .init(elements:[capacity]);p.objects.append(second)
    let frame=p.objects[0].artwork!.elements[1],storyID=try PublicationCommands.createStory(in:&p,frames:[.init(objectID:id,elementID:frame.id),.init(objectID:second.id,elementID:capacity.id)])
    store.engine.project=p;let model=ArtworkPageReviewModel(store:store,objectID:id);model.refresh();let before=try XCTUnwrap(model.proof)
    let index=p.textStories!.firstIndex{$0.id==storyID}!;p.textStories![index].text="UPDATED GLOBAL SOURCE";store.engine.project=p;model.refresh();let after=try XCTUnwrap(model.proof);XCTAssertNotEqual(after,before);XCTAssertEqual(PDFDocument(data:after)?.string?.trimmingCharacters(in:.whitespacesAndNewlines),"UPDATED GLOBAL SOURCE");XCTAssertEqual(store.project,p)
    XCTAssertEqual(p.objects[0].artwork!.elements[1].text,"")
  }

  func testPhysicalPageExportRetainsOpticalPositionAndSmallCapWarningsWithoutPreflightAppearanceClaims()throws {
    let(store,root,id)=try fixture();var project=store.project!,type=Typography()
    type.fontName="Georgia";type.baseline=3;type.characterPosition = .superscript;type.opticalSizing = .init(.automatic);type.features=[37:1]
    project.objects[0].artwork!.elements[1].text="Orbital original";project.objects[0].artwork!.elements[1].typography=type;store.engine.project=project
    let options:[String:Any]=["area":"bleed","crop_marks":true],before=store.project
    let preflight=try store.exportArtworkPage(objectID:id,arguments:["format":"preflight","page_output":options]) as! [String:Any]
    XCTAssertEqual(preflight["appearance_validated"] as? Bool,false);XCTAssertNil(preflight["character_position_warnings"])
    let result=try store.exportArtworkPage(objectID:id,arguments:["format":"pdf","page_output":options,"path":root.appendingPathComponent("source-forms.pdf").path]) as! [String:Any]
    XCTAssertFalse((result["optical_sizing_warnings"] as? [String] ?? []).isEmpty)
    XCTAssertTrue((result["character_position_warnings"] as? [String] ?? []).contains{$0.contains("geometric-fallback")})
    XCTAssertTrue((result["small_caps_warnings"] as? [String] ?? []).contains{$0.contains("does not offer")})
    let review=ArtworkPageReviewModel(store:store,objectID:id);review.refresh();XCTAssertTrue(review.matchesReview,review.error)
    for key in ["optical_sizing_warnings","character_position_warnings","small_caps_warnings"] {for warning in result[key] as? [String] ?? [] {XCTAssertTrue(review.warnings.contains(warning))}}
    XCTAssertEqual(result["appearance_validated"] as? Bool,true);XCTAssertEqual(store.project,before)
  }

  func testFocusedCropOptionDraftCannotExportAnUnreviewedPage()throws {
    let(store,root,id)=try fixture(),before=store.project!,model=ArtworkPageReviewModel(store:store,objectID:id);model.cropMarks=true;model.refresh();XCTAssertTrue(model.matchesReview,model.error)
    let original=try XCTUnwrap(model.proof),sheet=try XCTUnwrap(model.geometry).mediaMm
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1120,height:820),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;defer{window.makeFirstResponder(nil);window.close()}
    let host=NSHostingView(rootView:ArtworkPageReview(store:store,objectID:id,model:model));window.contentView=host;window.orderBack(nil);host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.06))
    let field=try XCTUnwrap(fields(host).first{$0.placeholderString=="Mark gap"});window.makeFirstResponder(field);let editor=try XCTUnwrap(window.firstResponder as? NSTextView);editor.selectAll(nil);editor.insertText("5",replacementRange:.init(location:NSNotFound,length:0));RunLoop.main.run(until:Date().addingTimeInterval(0.03))
    XCTAssertEqual(model.gap,"5");XCTAssertFalse(model.matchesReview);XCTAssertEqual(model.proof,original);XCTAssertEqual(model.geometry?.mediaMm,sheet)
    let target=root.appendingPathComponent("preserved.pdf"),retained=Data("Retained approved output".utf8);try retained.write(to:target)
    XCTAssertFalse(model.export(path:target));XCTAssertEqual(try Data(contentsOf:target),retained);XCTAssertEqual(store.project,before)
    model.length="6";model.refresh();XCTAssertTrue(model.matchesReview,model.error);XCTAssertEqual(model.geometry!.mediaMm.width,230,accuracy:1e-9);XCTAssertNotEqual(model.proof,original)
    XCTAssertTrue(model.export(path:target),model.error);XCTAssertEqual(PDFDocument(url:target)?.pageCount,1);XCTAssertEqual(store.project,before)
    let reviewed=try Data(contentsOf:target)
    model.gap="bad";XCTAssertFalse(model.matchesReview);model.refresh();XCTAssertNil(model.proof);XCTAssertFalse(model.matchesReview);XCTAssertFalse(model.export(path:target))
    XCTAssertEqual(try Data(contentsOf:target),reviewed)
  }

}

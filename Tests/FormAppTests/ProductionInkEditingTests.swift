import AppKit
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class ProductionInkEditingTests:XCTestCase {
  private func fixture() throws -> (StudioStore,ProductObject,ProductObject,ArtworkSwatch,ICCOutputProfile) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("FontPreferences.json"))
    var p=Project(name:"Ink intent"),sheet=try p.makeObject(recipeID:"artboard",name:"Ink source",parameters:["width":160,"depth":120]),product=try p.makeObject(recipeID:"box",name:"Linked box",parameters:["width":160,"depth":120,"height":8])
    let profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"))
    let preview=try profile.inkPreview(.init(kind:.spot,components:.init(0,0,0,0),profile:profile.reference,spotName:"FORM White"))
    let color=ArtworkSwatch(name:"Paper",color:preview)
    var e=ArtworkElement(kind:"text",x:12,y:18,width:136,height:50,text:"Original words / 0123456789",color:color.color,fontSize:24);e.typography=Typography();e.typography!.fontName="Georgia";e.fillSwatchID=color.id
    var art=Artwork(background:"#243C35",elements:[e],bleed:3);art.outputColorProfile=profile.reference
    sheet.artwork=art;p.objects=[sheet,product];p.swatches=[color];try p.linkArtwork(product.id,sourceID:sheet.id)
    try profile.store(in:store.repository.url(for:p.id).appendingPathComponent("Assets"));store.engine.project=p
    return(store,p.objects.first{$0.id==sheet.id}!,p.objects.first{$0.id==product.id}!,color,profile)
  }
  private func declare(_ store:StudioStore,_ color:ArtworkSwatch,_ profile:ICCOutputProfile,components:CMYKComponents = .init(0,0,0,0)) throws {
    let ink=ProductionInk(kind:.spot,components:components,profile:profile.reference,spotName:"FORM White")
    _ = try store.engine.call("form_swatch",arguments:["command":"update","swatch_id":color.id.uuidString,"print_ink":try jsonObject(ink)])
  }
  func testNativeSharedSwatchDeclarationIsOneUndoKeepsSourceWordsAndDoesNotInvalidatePreviewKeys() throws {
    let(store,sheet,product,color,profile)=try fixture();let p=store.project!,source=p.surfaceArtwork(product)!,before=try source.renderCacheData()
    func resources() throws -> [String] {
      let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:store.repository.url(for:p.id).appendingPathComponent("Manifest.json"))) as! [String:Any]
      return (manifest["objects"] as! [[String:Any]]).map{$0["file"] as! String}.sorted()
    }
    try store.engine.flush();let sourceFiles=try resources()
    try declare(store,color,profile);try store.engine.flush();XCTAssertEqual(try resources(),sourceFiles)
    let changed=store.project!,derived=try XCTUnwrap(changed.surfaceArtwork(product))
    XCTAssertTrue(derived.requiresInkOutput);XCTAssertEqual(try derived.renderCacheData(),before)
    XCTAssertEqual(changed.objects,p.objects);XCTAssertEqual(changed.swatches![0].color,color.color);XCTAssertEqual(store.engine.undoStack.count,1)
    XCTAssertFalse(changed.objects.first{$0.id==sheet.id}!.artwork!.requiresInkOutput)
    let data=try JSONEncoder.form.encode(derived);XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("requiresInkOutput"))
    XCTAssertFalse(try JSONDecoder.form.decode(Artwork.self,from:data).requiresInkOutput)
    var comparison=derived;comparison.requiresInkOutput=false;XCTAssertEqual(comparison,derived)
    store.engine.undo();XCTAssertEqual(store.project,p);store.engine.redo();XCTAssertEqual(store.project,changed)
  }
  func testExplicitCompositeAndInkMapExportsPreserveDestinationOnErrorAndRGBPreviewIsLabeled() throws {
    let(store,sheet,product,color,profile)=try fixture();try declare(store,color,profile)
    let root=store.repository.root,target=root.appendingPathComponent("ink-output.pdf"),sentinel=Data("Existing approved file".utf8)
    try sentinel.write(to:target)
    XCTAssertThrowsError(try store.exportArtwork(object:product,arguments:["format":"pdf","path":target.path]))
    XCTAssertEqual(try Data(contentsOf:target),sentinel)
    XCTAssertThrowsError(try store.export(format:"pdf",arguments:["object_id":product.id.uuidString,"path":target.path]));XCTAssertEqual(try Data(contentsOf:target),sentinel)
    let report=try store.exportArtwork(object:sheet,arguments:["format":"pdf","ink_output":"preflight"]) as! [String:Any]
    XCTAssertEqual(report["can_export"] as? Bool,true)
    let baseline=store.project
    let composite=try store.exportArtwork(object:product,arguments:["format":"pdf","ink_output":"composite","path":target.path]) as! [String:Any]
    XCTAssertEqual(composite["mode"] as? String,"composite");XCTAssertGreaterThan(try Data(contentsOf:target).count,10000)
    let plates=try store.exportArtwork(object:product,arguments:["format":"pdf","ink_output":"plates","path":root.appendingPathComponent("maps.pdf").path]) as! [String:Any]
    XCTAssertEqual(plates["pdf_pages"] as? Int,5)
    let preview=try store.exportArtwork(object:product,arguments:["format":"pdf","ink_output":"preview","path":root.appendingPathComponent("preview.pdf").path]) as! [String:Any]
    XCTAssertEqual(preview["ink_output"] as? String,"preview");XCTAssertEqual(preview["ink_declarations_encoded"] as? Bool,false);XCTAssertEqual(preview["color_space"] as? String,"sRGB")
    XCTAssertEqual(store.project,baseline)
    XCTAssertThrowsError(try store.exportArtwork(object:sheet,arguments:["format":"pdf","ink_output":"composite","cut_layout":true]))
  }
  func testFailedProfilePreparationAndPaletteBatchKeepAllDeclarationsAndSourceUnchanged() throws {
    let(store,_,_,color,profile)=try fixture();let baseline=store.project!
    var bad=ProductionInk(kind:.processCMYK,components:.init(0.1,0.2,0.3,0.4),profile:profile.reference)
    bad.profile.sha256=String(repeating:"b",count:64);bad.profile.asset="icc-"+bad.profile.sha256+".icc"
    XCTAssertThrowsError(try store.engine.call("form_swatch",arguments:["command":"update","swatch_id":color.id.uuidString,"print_ink":try jsonObject(bad)]));XCTAssertEqual(store.project,baseline)
    XCTAssertThrowsError(try store.engine.call("form_batch",arguments:["operations":[
      ["name":"form_swatch","arguments":["command":"update","swatch_id":color.id.uuidString,"name":"Must roll back"]],
      ["name":"form_swatch","arguments":["command":"update","swatch_id":color.id.uuidString,"print_ink":try jsonObject(bad)]]]]))
    XCTAssertEqual(store.project,baseline);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testUnusedInkDoesNotBlockAFrameAndSourceDetachRetainsInkLinksWithoutRuntimeFlags() throws {
    let(store,sheet,product,color,profile)=try fixture();var p=store.project!
    let unused=ProductionInk(kind:.spot,components:.init(0,0.65,1,0),profile:profile.reference,spotName:"Unused Orange")
    _ = try SwatchCommands.save(in:&p,name:"Unused",color:"#DD6B22",printInk:unused)
    XCTAssertFalse(p.surfaceArtwork(sheet)!.requiresInkOutput)
    store.engine.project=p;try declare(store,color,profile);p=store.project!
    try p.linkArtwork(product.id,sourceID:nil)
    let detached=p.objects.first{$0.id==product.id}!
    XCTAssertFalse(detached.artwork!.requiresInkOutput);XCTAssertEqual(detached.artwork!.elements[0].fillSwatchID,color.id)
    XCTAssertTrue(p.surfaceArtwork(detached)!.requiresInkOutput)
  }
  func testPublicationProductionModesRetainOrderedMixedPageBoxesAndSingleSource() throws {
    let(store,_,_,_,profile)=try fixture();var p=try Samples.fieldGuide()
    try profile.store(in:store.repository.url(for:p.id).appendingPathComponent("Assets"))
    for i in p.objects.indices {p.objects[i].artwork!.outputColorProfile=profile.reference}
    let ink=ProductionInk(kind:.processCMYK,components:.init(0.1,0.45,0.8,0.2),profile:profile.reference)
    let id=try SwatchCommands.save(in:&p,name:"Body process ink",color:"#A87845",printInk:ink),frame=p.textStories![0].frames[0]
    try SwatchCommands.assign(in:&p,objectID:frame.objectID,ids:[frame.elementID],swatchID:id)
    store.engine.project=p;let baseline=p,document=p.publications![0].id
    XCTAssertThrowsError(try PublicationOutput.pdf(p,documentID:document,assets:store.repository.url(for:p.id).appendingPathComponent("Assets")))
    let result=try store.publicationGraphicsCall("form_export_publication",["publication_id":document.uuidString,"ink_output":"composite","path":store.repository.root.appendingPathComponent("booklet.pdf").path]) as! [String:Any]
    XCTAssertEqual(result["pdf_pages"] as? Int,3)
    let pdf=try XCTUnwrap(CGPDFDocument(CGDataProvider(url:URL(fileURLWithPath:result["path"] as! String) as CFURL)!))
    XCTAssertEqual(pdf.page(at:3)!.getBoxRect(.trimBox).width/TypographyEngine.pointsPerMM,210,accuracy:0.001)
    let preview=try store.publicationGraphicsCall("form_export_publication",["publication_id":document.uuidString,"ink_output":"preview","path":store.repository.root.appendingPathComponent("booklet-preview.pdf").path]) as! [String:Any]
    XCTAssertEqual(preview["ink_declarations_encoded"] as? Bool,false);XCTAssertTrue(preview["output_profile"] is NSNull)
    XCTAssertEqual(store.project,baseline);XCTAssertEqual(store.project!.textStories![0].text,p.textStories![0].text)
  }
  func testComponentAndSharedStoryGuardsRetainPaletteIntentAndIgnoreUnusedDefinitions() throws {
    let(store,sheet,_,color,profile)=try fixture();var p=store.project!
    let text=sheet.artwork!.elements[0]
    _ = try ComponentCommands.create(in:&p,objectID:sheet.id,elements:[text.id],name:"Ink lettering")
    store.engine.project=p
    let before=try p.surfaceArtwork(p.objects.first{$0.id==sheet.id}!)!.renderCacheData()
    XCTAssertFalse(p.surfaceArtwork(p.objects.first{$0.id==sheet.id}!)!.requiresInkOutput)
    try declare(store,color,profile);p=store.project!
    let resolved=p.surfaceArtwork(p.objects.first{$0.id==sheet.id}!)!
    XCTAssertTrue(resolved.requiresInkOutput);XCTAssertEqual(try resolved.renderCacheData(),before)
    XCTAssertTrue(p.objects.allSatisfy{$0.artwork?.requiresInkOutput != true})
    var book=try Samples.fieldGuide()
    let id=try SwatchCommands.save(in:&book,name:"Story ink",color:"#FFFFFF",printInk:.init(kind:.spot,components:.init(0,0,0,0),profile:profile.reference,spotName:"Story White"))
    let frame=book.textStories![0].frames[0]
    try SwatchCommands.assign(in:&book,objectID:frame.objectID,ids:[frame.elementID],swatchID:id)
    XCTAssertFalse(book.surfaceArtwork(book.objects[0])!.requiresInkOutput)
    XCTAssertTrue(book.surfaceArtwork(book.objects[1])!.requiresInkOutput)
  }
  func testRGBOnlySelectionIsNotBlockedByAnotherLayersInkDeclaration() throws {
    let(store,sheet,_,color,profile)=try fixture();var p=store.project!
    let e=ArtworkElement(kind:"rectangle",x:12,y:80,width:20,height:20,color:"#A55A36")
    p.objects[0].artwork!.elements.append(e);store.engine.project=p;try declare(store,color,profile)
    let result=try store.exportArtwork(object:store.project!.objects.first{$0.id==sheet.id}!,arguments:["format":"pdf","element_ids":[e.id.uuidString],"path":store.repository.root.appendingPathComponent("rgb-selection.pdf").path]) as! [String:Any]
    XCTAssertNil(result["ink_output"])
  }

  func testFocusedNativeCMYKFieldCommitsBeforeSavingInkAndOneUndoRestoresIt() throws {
    _=NSApplication.shared;let(store,sheet,_,color,profile)=try fixture();try declare(store,color,profile)
    store.artworkSession.activate(sheet.id)
    let baseline=store.project!,undoCount=store.engine.undoStack.count
    let swatch=store.project!.swatches!.first{$0.id==color.id}!
    let window=NSWindow(contentRect:.init(x:0,y:0,width:390,height:610),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;defer{window.close()}
    let draft=ProductionInkDraft(session:store.artworkSession,swatch:swatch)
    let view=NSHostingView(rootView:ProductionInkEditor(session:store.artworkSession,swatch:swatch,draft:draft))
    window.contentView=view;view.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.05));view.layoutSubtreeIfNeeded()
    func fields(_ root:NSView)->[NSTextField] {([root as? NSTextField].compactMap{$0})+root.subviews.flatMap{fields($0)}}
    let field=try XCTUnwrap(fields(view).first{$0.isEditable && $0.placeholderString=="Cyan"})
    window.makeFirstResponder(field);RunLoop.main.run(until:Date().addingTimeInterval(0.02));let editor=try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.selectAll(nil);editor.insertText("12.5",replacementRange:NSRange(location:NSNotFound,length:0))
    RunLoop.main.run(until:Date().addingTimeInterval(0.02))
    XCTAssertTrue(draft.save(),draft.error ?? "Save failed")
    XCTAssertEqual(store.project!.swatches!.first{$0.id==color.id}!.printInk!.components.cyan,0.125,accuracy:1e-12)
    XCTAssertEqual(store.engine.undoStack.count,undoCount+1);XCTAssertEqual(store.project!.objects,baseline.objects)
    if store.engine.undoStack.count>undoCount {store.engine.undo();XCTAssertEqual(store.project,baseline)}
    if let path=ProcessInfo.processInfo.environment["FORM_INK_PROOF_DIR"] {
      view.layoutSubtreeIfNeeded();let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
      try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path).appendingPathComponent("native-production-ink-editor.png"))
    }
  }

  func testFabricTileRetainsDerivedIntentAndYardagePDFCannotSilentlyFlattenNamedInks() throws {
    let(store,sheet,_,color,profile)=try fixture();try declare(store,color,profile)
    var p=store.project!,fabric=FormCore.Material("ink-fabric","Ink fabric","Fabric","#EEEEDD")
    fabric.fabric=FabricProfile(composition:"Cotton",structure:.woven)
    p.materials.append(fabric)
    var pattern=FabricPattern(sourceObjectID:sheet.id);pattern.outputWidth=200;pattern.outputLength=150
    try p.setFabricPattern(pattern,materialID:fabric.id);store.engine.project=p
    let design=try XCTUnwrap(p.resolvedFabricPattern(materialID:fabric.id))
    XCTAssertTrue(design.artwork.requiresInkOutput);XCTAssertFalse(design.renderDefinition.artwork.requiresInkOutput)
    let baseline=p,target=store.repository.root.appendingPathComponent("yardage.pdf");try Data("KEEP".utf8).write(to:target)
    XCTAssertThrowsError(try store.exportFabricPattern(materialID:fabric.id,arguments:["format":"pdf","path":target.path]))
    XCTAssertEqual(try Data(contentsOf:target),Data("KEEP".utf8))
    let preview=try store.exportFabricPattern(materialID:fabric.id,arguments:["format":"svg","path":store.repository.root.appendingPathComponent("yardage.svg").path]) as! [String:Any]
    XCTAssertEqual(preview["ink_declarations_encoded"] as? Bool,false);XCTAssertEqual(store.project,baseline)
    p.objects[0].artwork!.elements[0].fillSwatchID=nil;p.objects[0].artwork!.backgroundSwatchID=color.id
    XCTAssertFalse(try XCTUnwrap(p.resolvedFabricPattern(materialID:fabric.id)).artwork.requiresInkOutput,"Excluded tile background must not block output")
  }

  func testNativeSelectedCharacterInkAssignmentKeepsWordsAndRejectsImplicitDetachBeforeUndo() throws {
    _=NSApplication.shared;let(store,sheet,_,color,profile)=try fixture()
    var p=store.project!;p.objects[0].artwork!.elements[0].fillSwatchID=nil;store.engine.project=p
    try declare(store,color,profile);let baseline=store.project!,e=baseline.objects[0].artwork!.elements[0]
    let window=NSWindow(contentRect:.init(x:0,y:0,width:900,height:700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:window.contentView!.bounds),session=store.artworkSession
    canvas.session=session;session.canvas=canvas;session.objectID=sheet.id;session.choose([e.id]);window.contentView=canvas;canvas.synchronize()
    defer{canvas.finishText();window.close()}
    canvas.beginText(e);let text=try XCTUnwrap(window.firstResponder as? CanvasTextView);text.undoManager?.groupsByEvent=false
    text.setSelectedRange(NSRange(location:0,length:8))
    XCTAssertTrue(session.swatch("assign",["swatch_id":color.id.uuidString]))
    let changed=store.project!,run=try XCTUnwrap(changed.objects[0].artwork!.elements[0].textRuns?.first)
    XCTAssertEqual(run.swatchID,color.id);XCTAssertEqual(changed.objects[0].artwork!.elements[0].text,e.text)
    let selected=text.selectedRange(),undoCount=store.engine.undoStack.count
    XCTAssertFalse(session.swatch("detach"));XCTAssertEqual(store.project,changed)
    XCTAssertTrue(window.firstResponder === text);XCTAssertEqual(text.selectedRange(),selected);XCTAssertEqual(store.engine.undoStack.count,undoCount)
    text.undoManager?.undo();canvas.finishText();XCTAssertEqual(store.project,baseline)
  }


  private func editorWindow(_ store:StudioStore,_ sheet:ProductObject,_ swatchID:UUID) throws -> (NSWindow,NSHostingView<ProductionInkEditor>,ProductionInkDraft) {
    _=NSApplication.shared;store.artworkSession.activate(sheet.id)
    let swatch=try XCTUnwrap(store.project!.swatches!.first{$0.id==swatchID}),draft=ProductionInkDraft(session:store.artworkSession,swatch:swatch)
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:390,height:610),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let view=NSHostingView(rootView:ProductionInkEditor(session:store.artworkSession,swatch:swatch,draft:draft));window.contentView=view
    // SwiftUI's real gesture/action handling requires a mounted window. Keep this
    // fixture offscreen and behind other windows; no application is activated.
    window.setFrameOrigin(.init(x:-10000,y:-10000));window.orderBack(nil)
    view.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.05));view.layoutSubtreeIfNeeded()
    return(window,view,draft)
  }
  private func nativeFields(_ root:NSView)->[NSTextField] {([root as? NSTextField].compactMap{$0})+root.subviews.flatMap{nativeFields($0)}}
  private func enter(_ value:String,in title:String,window:NSWindow,view:NSView) throws {
    let field=try XCTUnwrap(nativeFields(view).first{$0.isEditable && $0.placeholderString==title})
    window.makeFirstResponder(field);let editor=try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.selectAll(nil);editor.insertText(value,replacementRange:NSRange(location:NSNotFound,length:0));RunLoop.main.run(until:Date().addingTimeInterval(0.02))
  }
  private func pressEditorButton(save:Bool,window:NSWindow,view:NSView) throws {
    view.layoutSubtreeIfNeeded()
    let point=NSPoint(x:save ? view.bounds.maxX-62:view.bounds.minX+55,y:view.isFlipped ? view.bounds.maxY-34:view.bounds.minY+34)
    let location=view.convert(point,to:nil),stamp=ProcessInfo.processInfo.systemUptime
    let down=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:stamp,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
    let up=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:stamp+0.02,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0))
    // Dispatch through this test application's event loop so SwiftUI receives an
    // actual current mouse event and invokes its Button action. Nothing is posted
    // to the OS event stream or another process; this never calls draft.save().
    NSApp.postEvent(up,atStart:false);NSApp.sendEvent(down);NSApp.sendEvent(up);RunLoop.main.run(until:Date().addingTimeInterval(0.05))
  }
  func testNativeButtonSaveCommitsFocusedCMYKEntryAndKeepsUntouchedRawComponents() throws {
    let(store,sheet,_,color,profile)=try fixture()
    let components=CMYKComponents(0.1,0.12345678912345679,0.9876543219876543,0.000000000031)
    let ink=ProductionInk(kind:.processCMYK,components:components,profile:profile.reference)
    _ = try store.engine.call("form_swatch",arguments:["command":"update","swatch_id":color.id.uuidString,"print_ink":try jsonObject(ink)])
    let baseline=store.project!,count=store.engine.undoStack.count
    let(window,view,_)=try editorWindow(store,sheet,color.id);defer{window.close()}
    try enter("15.5",in:"Cyan",window:window,view:view)
    try pressEditorButton(save:true,window:window,view:view)
    let saved=store.project!.swatches!.first{$0.id==color.id}!.printInk!
    XCTAssertEqual(saved.components.cyan,0.155,accuracy:1e-12)
    XCTAssertEqual(saved.components.magenta,components.magenta);XCTAssertEqual(saved.components.yellow,components.yellow);XCTAssertEqual(saved.components.black,components.black)
    XCTAssertEqual(store.project!.objects,baseline.objects);XCTAssertEqual(store.project!.camera,baseline.camera)
    XCTAssertEqual(store.engine.undoStack.count,count+1);store.engine.undo();XCTAssertEqual(store.project,baseline)
  }
  func testNativeButtonSaveCommitsSpotNameAndTintWhicheverFieldRemainsFocused() throws {
    for focused in ["Ink tint","Exact colorant name"] {
      let(store,sheet,_,color,profile)=try fixture();try declare(store,color,profile)
      let baseline=store.project!,count=store.engine.undoStack.count
      let(window,view,_)=try editorWindow(store,sheet,color.id);defer{window.close()}
      if focused=="Ink tint" {
        try enter("FORM Dedicated Ink",in:"Exact colorant name",window:window,view:view);try enter("62.5",in:"Ink tint",window:window,view:view)
      } else {
        try enter("62.5",in:"Ink tint",window:window,view:view);try enter("FORM Dedicated Ink",in:"Exact colorant name",window:window,view:view)
      }
      try pressEditorButton(save:true,window:window,view:view)
      let saved=store.project!.swatches!.first{$0.id==color.id}!.printInk!
      XCTAssertEqual(saved.spotName,"FORM Dedicated Ink");XCTAssertEqual(saved.tint,0.625)
      XCTAssertEqual(store.engine.undoStack.count,count+1);store.engine.undo();XCTAssertEqual(store.project,baseline)
    }
  }
  func testNativeSaveButtonRejectsInvalidActiveFieldsWithoutClampingOrHistory() throws {
    let(store,sheet,_,color,profile)=try fixture();try declare(store,color,profile)
    let baseline=store.project!,count=store.engine.undoStack.count
    let(window,view,draft)=try editorWindow(store,sheet,color.id);defer{window.close()}
    for value in ["101","-1","nan",""] {
      try enter(value,in:"Cyan",window:window,view:view);try pressEditorButton(save:true,window:window,view:view)
      XCTAssertTrue(draft.error?.contains("Cyan")==true);XCTAssertEqual(draft.cyanText,value);XCTAssertEqual(store.project,baseline);XCTAssertEqual(store.engine.undoStack.count,count)
    }
    try enter("0",in:"Cyan",window:window,view:view)
    try enter("105",in:"Ink tint",window:window,view:view);try pressEditorButton(save:true,window:window,view:view)
    XCTAssertTrue(draft.error?.contains("Ink tint")==true);XCTAssertEqual(draft.tintText,"105");XCTAssertEqual(store.project,baseline)
    try enter("100",in:"Ink tint",window:window,view:view)
    try enter("Cyan",in:"Exact colorant name",window:window,view:view);try pressEditorButton(save:true,window:window,view:view)
    XCTAssertNotNil(draft.error);XCTAssertEqual(store.project,baseline);XCTAssertEqual(store.engine.undoStack.count,count)
  }
  func testNativeCancelWithFocusedInkDraftLeavesSourceAndHistoryExact() throws {
    let(store,sheet,_,color,profile)=try fixture();try declare(store,color,profile)
    let baseline=store.project!,count=store.engine.undoStack.count
    let(window,view,_)=try editorWindow(store,sheet,color.id);defer{window.close()}
    try enter("Do not save this name",in:"Exact colorant name",window:window,view:view)
    try enter("18.5",in:"Cyan",window:window,view:view);try pressEditorButton(save:false,window:window,view:view)
    XCTAssertEqual(store.project,baseline);XCTAssertEqual(store.engine.undoStack.count,count)
  }
}

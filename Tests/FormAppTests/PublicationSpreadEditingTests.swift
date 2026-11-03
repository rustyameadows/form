import AppKit
import PDFKit
import XCTest
import FormCore
import FormGeometry
import FormGraphics
@testable import FormApp

@MainActor final class PublicationSpreadEditingTests:XCTestCase {
  private struct Fixture {
    var store:StudioStore
    var folder:URL
    var assets:URL
    var document:UUID
    var pages:[UUID]
    var image:UUID
    var text:UUID
    var assembly:UUID
    var independent:UUID
  }
  private func fixture()throws->Fixture {
    _=NSApplication.shared
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("reader-spread-edit-"+UUID().uuidString)
    let store=StudioStore(repository:try .init(root:folder),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:folder.appendingPathComponent("Fonts.json"))
    var project=Project(name:"Editable physical reader spreads")
    for index in 0..<4 {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index+1)",parameters:["width":100,"depth":140])
      page.artwork = .init(background:"#FFFFFF",elements:[],bleed:0)
      page.artwork?.backgroundOpacity=0;page.artwork?.snapEnabled=false
      page.artwork?.canvasPosition = .init(36+Double(index)*136,40)
      project.objects.append(page)
    }
    let pages=project.objects.map(\.id)
    let document=try PublicationCommands.createPublication(in:&project,name:"Reader source",pages:pages,margins:.init(top:10,right:10,bottom:10,left:10))
    var doc=project.publications![0];doc.layout = .init(facingPages:true)
    try PublicationCommands.setPublication(in:&project,document:doc)
    let image=ArtworkElement(kind:"image",x:70,y:50,width:60,height:40,asset:"asymmetric.png")
    var text=ArtworkElement(kind:"text",x:75,y:105,width:70,height:16,text:"Crossing the gutter",color:"#000000",fontSize:14)
    text.typography = .init();text.typography?.fontName="HelveticaNeue";text.typography?.frameMode="area"
    project.objects[1].artwork?.elements=[image,text]
    let entries=project.publications![0].pages
    let stock=PaperStock(thicknessMM:0.2,profile:.init(texture:.smooth,color:"#F1D9B5",textureDepthMM:0))
    var definition=SheetAssemblyDefinition(publicationID:document,stock:stock,openingDegrees:180,activeSpread:1)
    definition.parentSheets=[.init(frontPageIDs:[entries[3].id,entries[0].id],backPageIDs:[entries[1].id,entries[2].id],stock:stock,sizeMM:.init(200,140))]
    let assembly=try SheetAssemblyCommands.create(in:&project,definition:definition)
    var independent=try project.makeObject(recipeID:"artboard",name:"Independent canvas source",parameters:["width":40,"depth":30])
    independent.artwork = .init(elements:[]);independent.artwork?.canvasPosition = .init(800,600);project.objects.append(independent)
    try store.repository.save(project)
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
    let graphics=try XCTUnwrap(CGContext(data:nil,width:120,height:80,bitsPerComponent:8,bytesPerRow:0,
      space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    graphics.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[1,0,0,1])));graphics.fill(.init(x:0,y:0,width:60,height:80))
    graphics.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[0,0,1,1])));graphics.fill(.init(x:60,y:0,width:60,height:80))
    graphics.setFillColor(try XCTUnwrap(CGColor(colorSpace:space,components:[0,1,0,1])));graphics.fill(.init(x:0,y:73,width:24,height:7))
    let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(graphics.makeImage()))
    let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
    let decoded=try XCTUnwrap(NSBitmapImageRep(data:png))
    let red=try XCTUnwrap(decoded.colorAt(x:15,y:40)?.usingColorSpace(.sRGB)),blue=try XCTUnwrap(decoded.colorAt(x:90,y:40)?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(red.redComponent,red.blueComponent+0.8,"The actual PNG must contain its asymmetric source colors before testing any renderer")
    XCTAssertGreaterThan(blue.blueComponent,blue.redComponent+0.8)
    try png.write(to:assets.appendingPathComponent("asymmetric.png"))
    try store.engine.open(project.id);store.showingHome=false;store.artworkSession.activate(pages[2])
    addTeardownBlock{@MainActor in store.artworkSession.canvas?.finishText();store.engine.project=nil;try? FileManager.default.removeItem(at:folder)}
    return .init(store:store,folder:folder,assets:assets,document:document,pages:pages,image:image.id,text:text.id,assembly:assembly,independent:independent.id)
  }
  private func event(_ type:NSEvent.EventType,world:CGPoint,canvas:VectorCanvasView,window:NSWindow)->NSEvent {
    NSEvent.mouseEvent(with:type,location:canvas.convert(canvas.documentPoint(world),to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
      windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
  }
  private func drag(from:CGPoint,to:CGPoint,canvas:VectorCanvasView,window:NSWindow) {
    canvas.mouseDown(with:event(.leftMouseDown,world:from,canvas:canvas,window:window))
    canvas.mouseDragged(with:event(.leftMouseDragged,world:to,canvas:canvas,window:window))
    canvas.mouseUp(with:event(.leftMouseUp,world:to,canvas:canvas,window:window))
  }
  private func pdfColor(_ data:Data,page:Int,x:Double,y:Double)throws->NSColor {
    let doc=try XCTUnwrap(PDFDocument(data:data)),value=try XCTUnwrap(doc.page(at:page))
    let image=value.thumbnail(of:.init(width:400,height:560),for:.trimBox)
    let bitmap=NSBitmapImageRep(cgImage:try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)))
    return try XCTUnwrap(bitmap.colorAt(x:Int(x/100*Double(bitmap.pixelsWide)),y:Int(y/140*Double(bitmap.pixelsHigh)))?.usingColorSpace(.sRGB))
  }
  private func frontImage(_ project:Project,fixture:Fixture)throws->NSBitmapImageRep {
    let object=try XCTUnwrap(project.objects.first{$0.id==fixture.assembly})
    let resolved=try project.resolvedSheetAssembly(object),page=try XCTUnwrap(project.publications?.first{$0.id==fixture.document}).pages[2]
    let leaf=try XCTUnwrap(resolved.leaves.first{$0.frontPageID==page.id})
    let root=try SheetAssemblyGeometry.make(object,project:project,assets:fixture.assets,limit:512)
    let face=try XCTUnwrap(root.childNode(withName:SheetAssemblyGeometry.leafName(leaf.id),recursively:true)?.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true))
    let image=try XCTUnwrap(face.geometry?.materials[0].diffuse.contents as? NSImage)
    return NSBitmapImageRep(cgImage:try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)))
  }
  func testFacingCanvasIsDefaultWithoutRailAndPersistsAcrossNavigationAndReopen()throws {
    let f=try fixture(),session=f.store.artworkSession,controller=session.publicationWorkspace
    let original=try XCTUnwrap(f.store.project)
    XCTAssertFalse(controller.isVisible)
    let frames=session.frames,left=try XCTUnwrap(frames.first{$0.id==f.pages[1]}),right=try XCTUnwrap(frames.first{$0.id==f.pages[2]})
    XCTAssertEqual(left.rect.maxX,right.rect.minX,accuracy:0.000001);XCTAssertEqual(left.rect.minY,right.rect.minY)
    XCTAssertEqual(left.publicationSpread?.frameIDs,Set([f.pages[1],f.pages[2]]))
    let positions=Dictionary(uniqueKeysWithValues:frames.map{($0.id,$0.rect)})
    controller.open(f.document);controller.showsSpreads=false;controller.close()
    XCTAssertEqual(Dictionary(uniqueKeysWithValues:session.frames.map{($0.id,$0.rect)}),positions)
    XCTAssertEqual(f.store.project,original);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertEqual(frames.first{$0.id==f.independent}?.rect.origin,CGPoint(x:800,y:600))
    let substrate=try XCTUnwrap(CanvasPublicationSpreads.substrate(for:left,project:original))
    XCTAssertEqual(substrate.color,"#F1D9B5");XCTAssertEqual(original.objects.first{$0.id==f.pages[1]}?.artwork?.backgroundOpacity,0)
    try f.store.engine.flush();try f.store.engine.open(original.id);controller.reset()
    XCTAssertFalse(controller.isVisible)
    XCTAssertEqual(Dictionary(uniqueKeysWithValues:session.frames.map{($0.id,$0.rect)}),positions)
    XCTAssertEqual(f.store.project?.objects,original.objects)
  }
  func testSpreadBackdropsRespectOrdinaryCanvasLayerOrderAndNeverTintPrintSource()throws {
    let f=try fixture(),session=f.store.artworkSession
    let source=try XCTUnwrap(session.frames.first{$0.id==f.pages[1]}),spread=try XCTUnwrap(source.publicationSpread)
    try f.store.engine.edit("Ordinary artwork behind a reader spread"){project in
      var background=try project.makeObject(recipeID:"artboard",name:"Behind the reader spread",parameters:["width":240,"depth":160])
      background.artwork = .init(background:"#FF0000",elements:[],bleed:0)
      background.artwork?.canvasPosition = .init(spread.bounds.minX-10,spread.bounds.minY-10)
      project.objects.insert(background,at:0)
    }
    let original=try XCTUnwrap(f.store.project)
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1700,height:1700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:window.contentView!.bounds);canvas.session=session;session.canvas=canvas;window.contentView=canvas;canvas.synchronize()
    defer{window.contentView=nil;window.close();session.canvas=nil}
    let origin=canvas.documentPoint(spread.bounds.origin),end=canvas.documentPoint(.init(x:spread.bounds.maxX,y:spread.bounds.maxY))
    let rect=CGRect(x:origin.x,y:origin.y,width:end.x-origin.x,height:end.y-origin.y)
    let bitmap=try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in:rect))
    canvas.cacheDisplay(in:rect,to:bitmap)
    let color=try XCTUnwrap(bitmap.colorAt(x:Int(Double(bitmap.pixelsWide)*0.1),y:bitmap.pixelsHigh/2)?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(color.greenComponent,0.6,"Paper must cover ordinary red artwork behind it, without duplicate page painting")
    XCTAssertGreaterThan(color.blueComponent,0.4)
    XCTAssertEqual(f.store.project,original)
    XCTAssertEqual(f.store.project?.objects.first{$0.id==f.pages[1]}?.artwork?.backgroundOpacity,0)
  }
  func testFrontmostOrdinaryArtboardOccludesSpreadOverflowForActualNativePicking()throws {
    let f=try fixture(),session=f.store.artworkSession
    let right=try XCTUnwrap(session.frames.first{$0.id==f.pages[2]})
    let point=CGPoint(x:right.rect.minX+12,y:right.rect.minY+70)
    var foregroundID:UUID?,graphicID:UUID?
    try f.store.engine.edit("Ordinary artboard above reader content"){project in
      var foreground=try project.makeObject(recipeID:"artboard",name:"Frontmost ordinary sheet",parameters:["width":40,"depth":40])
      let graphic=ArtworkElement(kind:"rectangle",x:5,y:5,width:30,height:30,color:"#00FF00")
      var artwork=Artwork(background:"#FFFFFF",elements:[graphic],bleed:0)
      artwork.backgroundOpacity=0;artwork.snapEnabled=false;artwork.canvasPosition = .init(point.x-20,point.y-20)
      foreground.artwork=artwork;foregroundID=foreground.id;graphicID=graphic.id;project.objects.append(foreground)
    }
    let before=try XCTUnwrap(f.store.project),undo=f.store.engine.undoStack.count
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1700,height:1700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:window.contentView!.bounds);canvas.session=session;session.canvas=canvas;window.contentView=canvas;canvas.synchronize()
    defer{window.contentView=nil;window.close();session.canvas=nil}
    XCTAssertNil(CanvasPublicationSpreads.artworkFrame(at:point,frames:session.frames,session:session,tolerance:0.5),"The visible ordinary backdrop blocks underlying publication hits")
    canvas.mouseDown(with:event(.leftMouseDown,world:point,canvas:canvas,window:window))
    canvas.mouseUp(with:event(.leftMouseUp,world:point,canvas:canvas,window:window))
    XCTAssertEqual(session.objectID,foregroundID);XCTAssertEqual(session.selection,Set([try XCTUnwrap(graphicID)]))
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.undoStack.count,undo)
    // Removing only the foreground restores picking the original gutter owner.
    try f.store.engine.edit("Remove occluding sheet"){project in project.objects.removeAll{$0.id==foregroundID}}
    canvas.synchronize()
    XCTAssertEqual(CanvasPublicationSpreads.artworkFrame(at:point,frames:session.frames,session:session,tolerance:0.5)?.id,f.pages[1])
  }
  func testNativeOtherHalfPickingMoveResizeAndTextEditFeedBothPDFCropsAndPhysicalFaceWithUndo()throws {
    let f=try fixture(),session=f.store.artworkSession,original=try XCTUnwrap(f.store.project)
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1700,height:1700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:window.contentView!.bounds);canvas.session=session;session.canvas=canvas;window.contentView=canvas;canvas.synchronize()
    defer{canvas.finishText();window.contentView=nil;window.close();session.canvas=nil}
    let left=try XCTUnwrap(session.frames.first{$0.id==f.pages[1]})
    let across=CGPoint(x:left.rect.minX+115,y:left.rect.minY+70)
    XCTAssertEqual(CanvasPublicationSpreads.artworkFrame(at:across,frames:session.frames,session:session,tolerance:0.2)?.id,f.pages[1])
    let evidence=FileManager.default.temporaryDirectory.appendingPathComponent("form-reader-spread-proof-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
    print("READER_SPREAD_EVIDENCE=\(evidence.path)")
    try Data(contentsOf:f.assets.appendingPathComponent("asymmetric.png")).write(to:evidence.appendingPathComponent("source-asymmetric.png"))
    let beforePDF=try PublicationOutput.pdf(original,documentID:f.document,assets:f.assets)
    try beforePDF.write(to:evidence.appendingPathComponent("before.pdf"))
    let beforeLeft=try pdfColor(beforePDF,page:1,x:75,y:70),beforeRight=try pdfColor(beforePDF,page:2,x:5,y:70)
    XCTAssertGreaterThan(beforeLeft.redComponent,beforeLeft.blueComponent+0.5)
    XCTAssertGreaterThan(beforeRight.blueComponent,beforeRight.redComponent+0.5)
    let beforeFace=try frontImage(original,fixture:f)
    try XCTUnwrap(beforeFace.representation(using:.png,properties:[:])).write(to:evidence.appendingPathComponent("before-physical-face.png"))
    let beforePhysical=try XCTUnwrap(beforeFace.colorAt(x:Int(Double(beforeFace.pixelsWide)*0.05),y:Int(Double(beforeFace.pixelsHigh)*0.5))?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(beforePhysical.blueComponent,beforePhysical.redComponent+0.3)
    drag(from:across,to:.init(x:across.x+10,y:across.y),canvas:canvas,window:window)
    XCTAssertEqual(session.objectID,f.pages[1]);XCTAssertEqual(session.selection,[f.image])
    var art=try XCTUnwrap(f.store.project?.objects.first{$0.id==f.pages[1]}?.artwork)
    var image=try XCTUnwrap(art.elements.first{$0.id==f.image}),bounds=art.bounds(of:image)
    XCTAssertEqual(bounds.x,80,accuracy:0.01);XCTAssertEqual(bounds.width,60,accuracy:0.01)
    let corner=CGPoint(x:left.rect.minX+bounds.maxX,y:left.rect.minY+bounds.maxY)
    drag(from:corner,to:.init(x:corner.x+20,y:corner.y+10),canvas:canvas,window:window)
    art=try XCTUnwrap(f.store.project?.objects.first{$0.id==f.pages[1]}?.artwork);image=try XCTUnwrap(art.elements.first{$0.id==f.image});bounds=art.bounds(of:image)
    XCTAssertEqual(bounds.x,80,accuracy:0.01);XCTAssertEqual(bounds.width,80,accuracy:0.01);XCTAssertEqual(bounds.height,50,accuracy:0.01)
    let caption=try XCTUnwrap(art.elements.first{$0.id==f.text});canvas.beginText(caption)
    let native=try XCTUnwrap(window.firstResponder as? CanvasTextView),clip=try XCTUnwrap(native.superview?.superview)
    let spread=try XCTUnwrap(session.frames.first{$0.id==f.pages[1]}?.publicationSpread)
    let expectedWidth=canvas.documentPoint(.init(x:spread.bounds.maxX,y:0)).x-canvas.documentPoint(.init(x:spread.bounds.minX,y:0)).x
    XCTAssertEqual(clip.frame.width,expectedWidth,accuracy:0.01)
    native.insertText(" edited",replacementRange:.init(location:caption.text.utf16.count,length:0));canvas.finishText()
    let changed=try XCTUnwrap(f.store.project)
    XCTAssertEqual(changed.objects.first{$0.id==f.pages[1]}?.artwork?.elements.first{$0.id==f.text}?.text,"Crossing the gutter edited")
    XCTAssertEqual(changed.objects.first{$0.id==f.pages[2]},original.objects.first{$0.id==f.pages[2]})
    XCTAssertEqual(changed.objects.flatMap{$0.artwork?.elements ?? []}.filter{$0.id==f.image}.count,1)
    let afterPDF=try PublicationOutput.pdf(changed,documentID:f.document,assets:f.assets)
    try afterPDF.write(to:evidence.appendingPathComponent("after.pdf"))
    let afterLeft=try pdfColor(afterPDF,page:1,x:75,y:70),afterRight=try pdfColor(afterPDF,page:2,x:5,y:70)
    XCTAssertGreaterThan(afterLeft.greenComponent,beforeLeft.greenComponent+0.5)
    XCTAssertGreaterThan(afterRight.redComponent,afterRight.blueComponent+0.5)
    let afterFace=try frontImage(changed,fixture:f)
    try XCTUnwrap(afterFace.representation(using:.png,properties:[:])).write(to:evidence.appendingPathComponent("after-physical-face.png"))
    let afterPhysical=try XCTUnwrap(afterFace.colorAt(x:Int(Double(afterFace.pixelsWide)*0.05),y:Int(Double(afterFace.pixelsHigh)*0.5))?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(afterPhysical.redComponent,afterPhysical.blueComponent+0.3)
    XCTAssertEqual(f.store.engine.undoStack.count,3)
    f.store.engine.undo();f.store.engine.undo();f.store.engine.undo();XCTAssertEqual(f.store.project,original)
    f.store.engine.redo();f.store.engine.redo();f.store.engine.redo();XCTAssertEqual(f.store.project,changed)
    try f.store.engine.flush();let reopened=try f.store.repository.load(changed.id)
    XCTAssertEqual(reopened.objects,changed.objects);XCTAssertEqual(reopened.publications,changed.publications)
  }
  func testRightOwnedNativeTextKeepsSpreadCoordinatesWithoutMovingEitherPageSource()throws {
    let f=try fixture(),session=f.store.artworkSession
    var rightText=ArtworkElement(kind:"text",x:-25,y:105,width:70,height:16,text:"Right owner across gutter",fontSize:14)
    rightText.typography = .init();rightText.typography?.fontName="HelveticaNeue";rightText.typography?.frameMode="area"
    try f.store.engine.edit("Authored right source caption"){project in
      let index=project.objects.firstIndex{$0.id==f.pages[2]}!;project.objects[index].artwork!.elements=[rightText]
    }
    let before=try XCTUnwrap(f.store.project),undo=f.store.engine.undoStack.count
    session.activate(f.pages[2])
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1700,height:1700),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:window.contentView!.bounds);canvas.session=session;session.canvas=canvas;window.contentView=canvas;canvas.synchronize()
    defer{canvas.finishText();window.contentView=nil;window.close();session.canvas=nil}
    canvas.beginText(rightText)
    let native=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    let frame=try XCTUnwrap(session.frames.first{$0.id==f.pages[2]})
    let topLeft=native.convert(CGPoint.zero,to:canvas)
    let expected=canvas.documentPoint(.init(x:frame.rect.minX-25,y:frame.rect.minY+105))
    XCTAssertEqual(topLeft.x,expected.x,accuracy:0.01);XCTAssertEqual(topLeft.y,expected.y,accuracy:0.01)
    native.insertText(" revised",replacementRange:.init(location:rightText.text.utf16.count,length:0));canvas.finishText()
    XCTAssertEqual(f.store.project?.objects.first{$0.id==f.pages[2]}?.artwork?.elements.first{$0.id==rightText.id}?.text,"Right owner across gutter revised")
    XCTAssertEqual(f.store.project?.objects.first{$0.id==f.pages[1]},before.objects.first{$0.id==f.pages[1]})
    XCTAssertEqual(f.store.engine.undoStack.count,undo+1)
    f.store.engine.undo();XCTAssertEqual(f.store.project,before)
  }
  func testPreflightAcceptsGutterSourceWithoutDuplicateWarningsAndFindRetainsOffOwnerGraphic()throws {
    let f=try fixture(),session=f.store.artworkSession
    let initial=PublicationOutput.preflight(try XCTUnwrap(f.store.project),documentID:f.document,assets:f.assets)
    XCTAssertTrue(initial["can_export"] as? Bool==true)
    XCTAssertFalse((initial["issues"] as? [[String:Any]] ?? []).contains{($0["message"] as? String ?? "").contains("bleed area")})
    try f.store.engine.edit("Move image wholly onto neighbor"){project in
      let index=project.objects.firstIndex{$0.id==f.pages[1]}!
      project.objects[index].artwork!.elements[0].x=115
    }
    session.activate(f.pages[2])
    let found=f.store.workspaceFindResults(for:.artwork,query:"image")
    XCTAssertTrue(found.contains{if case .canvasElement(_,let source,let element)=$0.target{return source==f.pages[1] && element==f.image};return false})
    let frame=try XCTUnwrap(session.frames.first{$0.id==f.pages[1]})
    XCTAssertEqual(CanvasPublicationSpreads.artworkFrame(at:.init(x:frame.rect.minX+125,y:frame.rect.minY+70),frames:session.frames,session:session,tolerance:0.2)?.id,f.pages[1])
    try f.store.engine.edit("Move source outside physical spread"){project in
      let index=project.objects.firstIndex{$0.id==f.pages[1]}!;project.objects[index].artwork!.elements[0].x=210
    }
    let report=PublicationOutput.preflight(try XCTUnwrap(f.store.project),documentID:f.document,assets:f.assets)
    let warnings=(report["issues"] as? [[String:Any]] ?? []).filter{($0["message"] as? String ?? "").contains("bleed area")}
    XCTAssertEqual(warnings.count,1);XCTAssertEqual(warnings.first?["element_id"] as? String,f.image.uuidString)
  }
}

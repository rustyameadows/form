import AppKit
import XCTest
@testable import FormApp
@testable import FormCore

@MainActor final class PublicationDenseCanvasIntegrationTests:XCTestCase {
  private struct Fixture {
    let store:StudioStore
    let pages:[UUID]
    let visible:UUID
    let overflow:UUID
    let gutter:UUID
  }
  private func fixture(partnerWidth:Double=40)throws->Fixture {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("publication-dense-cache-integration-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    var project=Project(name:"Canonical spread with cached navigation")
    for index in 0..<3 {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index+1)",parameters:["width":index==2 ? partnerWidth:100,"depth":140])
      page.artwork = .init(background:"#FFFFFF",elements:[],bleed:0);page.artwork?.canvasPosition = .init(36+Double(index)*136,40)
      project.objects.append(page)
    }
    let pages=project.objects.map(\.id)
    let visible=ArtworkElement(kind:"rectangle",x:20,y:20,width:20,height:20,color:"#CC3311")
    let overflow=ArtworkElement(kind:"rectangle",x:150,y:50,width:20,height:20,color:"#33AA44")
    let gutter=ArtworkElement(kind:"rectangle",x:70,y:90,width:60,height:25,color:"#0000FF")
    project.objects[1].artwork!.elements=[visible,overflow,gutter]
    let id=try PublicationCommands.createPublication(in:&project,name:"Facing pages",pages:pages)
    var document=try XCTUnwrap(project.publications?.first{$0.id==id});document.layout = .init(facingPages:true)
    try PublicationCommands.setPublication(in:&project,document:document)
    try store.repository.save(project);try store.engine.open(project.id);store.showingHome=false
    store.artworkSession.activate(pages[1]);store.artworkSession.choose([])
    addTeardownBlock{@MainActor in store.artworkSession.canvas?.finishText();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return .init(store:store,pages:pages,visible:visible.id,overflow:overflow.id,gutter:gutter.id)
  }
  private func mount(_ fixture:Fixture)throws->(NSWindow,VectorCanvasView) {
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1050,height:850),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let scroll=ArtworkScrollView(frame:window.contentView!.bounds)
    scroll.allowsMagnification=true;scroll.minMagnification=0.08;scroll.maxMagnification=24
    let canvas=VectorCanvasView(frame:scroll.bounds);canvas.session=fixture.store.artworkSession;fixture.store.artworkSession.canvas=canvas
    scroll.documentView=canvas;window.contentView=scroll
    canvas.synchronize();_=canvas.fit(frameIDs:Set(fixture.pages.suffix(2)))
    return(window,canvas)
  }
  private func hover(_ world:CGPoint,canvas:VectorCanvasView,window:NSWindow)throws {
    let event=try XCTUnwrap(NSEvent.mouseEvent(with:.mouseMoved,location:canvas.convert(canvas.documentPoint(world),to:nil),modifierFlags:[],
      timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:0,pressure:0))
    canvas.mouseMoved(with:event)
  }
  func testEveryWarmGenerationCacheReturnRetainsDefaultReaderLayoutWithoutCachingItsDisplayPositions()throws {
    let f=try fixture(),session=f.store.artworkSession,before=try XCTUnwrap(f.store.project)
    let first=session.frames,left=try XCTUnwrap(first.first{$0.id==f.pages[1]}),right=try XCTUnwrap(first.first{$0.id==f.pages[2]})
    XCTAssertNotNil(left.publicationSpread);XCTAssertEqual(left.rect.maxX,right.rect.minX,accuracy:0.0001)
    let builds=session.frameBuildCount
    for _ in 0..<20 {
      let frames=session.frames
      XCTAssertNotNil(frames.first{$0.id==f.pages[1]}?.publicationSpread)
      XCTAssertEqual(frames.first{$0.id==f.pages[1]}?.rect,left.rect)
    }
    var camera=before;camera.camera.azimuth+=0.4;f.store.engine.project=camera
    XCTAssertEqual(session.frames.first{$0.id==f.pages[1]}?.rect,left.rect)
    XCTAssertNotNil(session.frames.first{$0.id==f.pages[1]}?.publicationSpread)
    XCTAssertEqual(session.frameBuildCount,builds,"Camera-only generation changes should reuse canonical frames and still apply the reader layout")
    f.store.engine.project=before
    session.publicationWorkspace.close();session.publicationWorkspace.open(before.publications!.first!.id)
    XCTAssertEqual(session.frames.first{$0.id==f.pages[1]}?.rect,left.rect)
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }
  func testWarmPhysicalClipAndHoverPickerRefreshWhenOnlyTheUnchangedOwnersNeighborGrows()throws {
    let f=try fixture(),session=f.store.artworkSession,before=try XCTUnwrap(f.store.project)
    let(window,canvas)=try mount(f)
    defer{window.contentView=nil;window.close();session.canvas=nil}
    let left=try XCTUnwrap(session.frames.first{$0.id==f.pages[1]})
    let inner=CGPoint(x:left.rect.minX+30,y:left.rect.minY+30),overflow=CGPoint(x:left.rect.minX+160,y:left.rect.minY+60)
    let local=CGPoint(x:160,y:60),clip=try XCTUnwrap(canvas.physicalPickingClip(for:left))
    XCTAssertFalse(clip.contains(local))
    try hover(inner,canvas:canvas,window:window);XCTAssertEqual(canvas.hoveredElementID,f.visible)
    let builds=try XCTUnwrap(canvas.diagnostics["hover_picker_builds"] as? Int)
    try f.store.engine.edit("Expanded the neighboring physical trim") {project in
      let index=try XCTUnwrap(project.objects.firstIndex{$0.id==f.pages[2]});project.objects[index].parameters["width"]=100
    }
    canvas.synchronize()
    let updated=try XCTUnwrap(session.frames.first{$0.id==f.pages[1]})
    XCTAssertEqual(updated.object,left.object);XCTAssertEqual(updated.artwork,left.artwork)
    XCTAssertTrue(try XCTUnwrap(canvas.physicalPickingClip(for:updated)).contains(local),"The old140mm spread clip must not survive its neighboring page growing to200mm")
    try hover(overflow,canvas:canvas,window:window)
    XCTAssertEqual(canvas.hoveredElementID,f.overflow,"A real native hover must pick unchanged owner artwork newly exposed on the larger neighboring page")
    XCTAssertGreaterThan(canvas.diagnostics["hover_picker_builds"] as? Int ?? 0,builds)
    f.store.engine.undo();canvas.synchronize()
    let restored=try XCTUnwrap(session.frames.first{$0.id==f.pages[1]})
    XCTAssertFalse(try XCTUnwrap(canvas.physicalPickingClip(for:restored)).contains(local))
    try hover(overflow,canvas:canvas,window:window);XCTAssertNil(canvas.hoveredElementID)
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }
  func testDistantOverviewDrawKeepsTheSingleGutterGraphicAcrossBothPagesAsNativeVectors()throws {
    let f=try fixture(partnerWidth:100),session=f.store.artworkSession,before=try XCTUnwrap(f.store.project)
    let(window,canvas)=try mount(f)
    defer{window.contentView=nil;window.close();session.canvas=nil}
    canvas.setZoom(0.2);canvas.synchronize()
    let left=try XCTUnwrap(session.frames.first{$0.id==f.pages[1]}),spread=try XCTUnwrap(left.publicationSpread)
    let origin=canvas.documentPoint(spread.bounds.origin),end=canvas.documentPoint(CGPoint(x:spread.bounds.maxX,y:spread.bounds.maxY))
    let region=CGRect(x:origin.x,y:origin.y,width:end.x-origin.x,height:end.y-origin.y)
    let bitmap=try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in:region))
    canvas.cacheDisplay(in:region,to:bitmap)
    XCTAssertEqual(canvas.diagnostics["last_raster_frames"] as? Int,0,"A per-page overview image would crop the owner's artwork at the gutter")
    let point=canvas.documentPoint(CGPoint(x:left.rect.minX+115,y:left.rect.minY+100))
    let x=Int((point.x-region.minX)*CGFloat(bitmap.pixelsWide)/region.width),y=Int((point.y-region.minY)*CGFloat(bitmap.pixelsHigh)/region.height)
    let pixel=try XCTUnwrap(bitmap.colorAt(x:x,y:y)?.usingColorSpace(NSColorSpace.sRGB))
    XCTAssertGreaterThan(pixel.blueComponent,pixel.redComponent+0.6,"The owner's blue rectangle must remain visible on the neighboring physical half at overview zoom")
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertEqual(before.objects.flatMap{$0.artwork?.elements ?? []}.filter{$0.id==f.gutter}.count,1)
  }
}

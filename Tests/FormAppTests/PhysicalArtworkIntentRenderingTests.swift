import AppKit
import FormCore
import FormGeometry
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class PhysicalArtworkIntentRenderingTests:XCTestCase {
  private func fixture() throws -> (StudioStore,UUID) {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("physical-intent-canvas-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.engine.project=Project(name:"Physical guide views")
    let definition=PlanarConstructionDefinition(name:"Generic panel named net",size:.init(70,40),panels:[
      .init(id:"front",name:"Front",polygon:[.init(0,0),.init(40,0),.init(40,40),.init(0,40)]),
      .init(id:"net",name:"Named net",polygon:[.init(40,0),.init(70,0),.init(40,40)])],
      hinges:[.init(id:"crease",parentPanelID:"front",childPanelID:"net",start:.init(40,0),end:.init(40,40),angleDegrees:90)],rootPanelID:"front")
    let created=try XCTUnwrap(store.engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(definition)]) as? [String:Any])
    let id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(created["object_id"] as? String)))
    try store.engine.edit("Plain source"){p in p.objects[0].artwork = .init(background:"#FFFFFF",bleed:0)}
    store.showingHome=false;store.mode = .artwork;store.select(id);store.paperShowingGuides=true
    addTeardownBlock{@MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return(store,id)
  }
  private func set(_ store:StudioStore,_ id:UUID,_ intent:PhysicalArtworkIntent) throws {
    _ = try store.engine.call("form_surface",arguments:["command":"set_intent","object_id":id.uuidString,"intent":try jsonObject(intent)])
  }
  func testNativePolygonGuidesRenderOutsideTrimFitAndReuseOneSourceReport() throws {
    let (store,id)=try fixture()
    try set(store,id,.init(surface:.init(kind:.net),bleedMM:4,safeInsetMM:3))
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count,session=store.artworkSession
    let frame=try XCTUnwrap(session.frames.first{$0.projection?.isProof == true});session.activate(frame.id)
    let scroll=NSScrollView(frame:.init(x:0,y:0,width:800,height:600)),canvas=VectorCanvasView()
    scroll.allowsMagnification=true;scroll.documentView=canvas;canvas.session=session;session.canvas=canvas;canvas.synchronize()
    let fit=canvas.contentBounds(all:false)
    XCTAssertLessThan(fit.minX,frame.rect.minX-3.9)
    XCTAssertGreaterThan(fit.maxX,frame.rect.maxX+3.9)
    let region=frame.rect.insetBy(dx:-8,dy:-8)
    let a=canvas.documentPoint(region.origin),b=canvas.documentPoint(.init(x:region.maxX,y:region.maxY))
    let rect=CGRect(x:a.x,y:a.y,width:b.x-a.x,height:b.y-a.y)
    let bitmap=try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in:rect))
    canvas.cacheDisplay(in:rect,to:bitmap)
    var bleed=0,safe=0
    for y in 0..<bitmap.pixelsHigh {for x in 0..<bitmap.pixelsWide {
      guard let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else{continue}
      if c.redComponent-c.greenComponent>0.25,c.blueComponent-c.greenComponent>0.25 {bleed+=1}
      if c.greenComponent-c.redComponent>0.2,c.blueComponent-c.redComponent>0.2,
        abs(c.greenComponent-c.blueComponent)<0.15 {safe+=1}
    }}
    XCTAssertGreaterThan(bleed,20,"Actual outward bleed guides must be visible beyond the cut outline")
    XCTAssertGreaterThan(safe,20,"Actual polygon safety guides must be visible inside the cut outline")
    canvas.cacheDisplay(in:rect,to:bitmap)
    XCTAssertEqual(canvas.diagnostics["physical_guide_builds"] as? Int,1)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
    canvas.fit(all:false)
    XCTAssertTrue(canvas.visibleCanvasRect.insetBy(dx:-0.01,dy:-0.01).contains(fit))
    XCTAssertEqual(store.project,before)
  }
  func testDirtyRegionContainingOnlyOuterBleedStillDrawsItsGuide() throws {
    let (store,id)=try fixture()
    try set(store,id,.init(surface:.init(kind:.net),bleedMM:25,safeInsetMM:0))
    let session=store.artworkSession,proof=try XCTUnwrap(session.frames.first{$0.projection?.isProof == true})
    session.activate(proof.id)
    let scroll=NSScrollView(frame:.init(x:0,y:0,width:800,height:600)),canvas=VectorCanvasView()
    scroll.allowsMagnification=true;scroll.documentView=canvas;canvas.session=session;session.canvas=canvas;canvas.synchronize()
    let region=CGRect(x:proof.rect.minX-26,y:proof.rect.minY+8,width:3,height:20)
    XCTAssertFalse(region.intersects(proof.rect.insetBy(dx:-12,dy:-12)),"Exercise the region excluded by the old fixed culling margin")
    let a=canvas.documentPoint(region.origin),b=canvas.documentPoint(.init(x:region.maxX,y:region.maxY))
    let rect=CGRect(x:a.x,y:a.y,width:b.x-a.x,height:b.y-a.y),bitmap=try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in:rect))
    canvas.cacheDisplay(in:rect,to:bitmap)
    var purple=0
    for y in 0..<bitmap.pixelsHigh {for x in 0..<bitmap.pixelsWide {
      guard let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else{continue}
      if c.redComponent-c.greenComponent>0.25,c.blueComponent-c.greenComponent>0.25 {purple+=1}
    }}
    XCTAssertGreaterThan(purple,10,"A visible25mm bleed guide must not disappear when its frame lies outside the dirty region")
  }
  func testUnframedSewingGuideFitUsesFiniteCutPieceRatherThanWorkspaceRectangle() throws {
    let (store,_)=try fixture()
    var project=Project(name:"One Canvas with a cut piece")
    let workspace=try project.ensureCanvasWorkspace()
    var piece=ArtworkElement(kind:"rectangle",x:-220,y:-160,width:80,height:40)
    piece.sewingPiece = .init(name:"Shared surface finite piece");piece.sewingPiece!.seamAllowance=3
    project.objects[0].artwork!.elements=[piece]
    store.engine.project=project;store.select(workspace.id)
    try set(store,workspace.id,.init(surface:.init(kind:.sewingPiece,surfaceID:piece.id.uuidString),bleedMM:2,safeInsetMM:4))
    let before=try XCTUnwrap(store.project),session=store.artworkSession
    session.objectID=workspace.id;session.activate(workspace.id)
    let scroll=NSScrollView(frame:.init(x:0,y:0,width:800,height:600)),canvas=VectorCanvasView()
    scroll.allowsMagnification=true;scroll.documentView=canvas;canvas.session=session;session.canvas=canvas;canvas.synchronize()
    let bounds=canvas.contentBounds(all:true)
    XCTAssertLessThan(bounds.minX,-224.9);XCTAssertLessThan(bounds.minY,-164.9)
    XCTAssertGreaterThan(bounds.maxX,-135.1);XCTAssertGreaterThan(bounds.maxY,-115.1)
    XCTAssertLessThan(bounds.width,100);XCTAssertLessThan(bounds.height,60)
    canvas.fit(all:true)
    XCTAssertTrue(canvas.visibleCanvasRect.insetBy(dx:-0.01,dy:-0.01).contains(bounds))
    XCTAssertEqual(canvas.diagnostics["physical_guide_builds"] as? Int,1)
    XCTAssertEqual(store.project,before)
  }
  func testSourceNamedNetCannotCollideWithProofAndLegacyPositionsStillOpen() throws {
    let (store,id)=try fixture(),session=store.artworkSession
    let proof=try XCTUnwrap(session.frames.first{$0.projection?.isProof == true})
    let panel=try XCTUnwrap(session.frames.first{$0.projection?.panelID == "net"})
    XCTAssertNotEqual(proof.id,panel.id)
    XCTAssertNotEqual(proof.projection?.key,panel.projection?.key)
    XCTAssertEqual(Set(session.frames.map(\.id)).count,session.frames.count)
    try store.engine.edit("Legacy layout"){p in p.objects[0].canvasProjectionPositions=[proof.projection!.legacyKey:.init(-200,300)]}
    let oldFrames=session.frames
    XCTAssertEqual(try XCTUnwrap(oldFrames.first{$0.id==proof.id}).rect.origin,.init(x:-200,y:300))
    session.activate(panel.id);session.moveCanvasFrame(to:.init(500,600))
    let moved=session.frames
    XCTAssertEqual(try XCTUnwrap(moved.first{$0.id==panel.id}).rect.origin,.init(x:500,y:600))
    XCTAssertEqual(try XCTUnwrap(moved.first{$0.id==proof.id}).rect.origin,.init(x:-200,y:300))
    XCTAssertNotNil(store.project?.objects.first{$0.id==id}?.canvasProjectionPositions?[panel.projection!.key])
    try store.engine.flush();let loaded=try store.repository.load(try XCTUnwrap(store.project?.id))
    XCTAssertEqual(loaded.objects,store.project?.objects)
  }
  func testGuideOnlyEditsReusePanelBuffersAndFoldChangesReuseFlatGuideReport() throws {
    let (store,id)=try fixture(),assets=store.artworkSession.assets
    let original=try XCTUnwrap(store.project),object=original.objects[0]
    func sources(_ root:MeshNode) -> [MeshGeometrySource] {
      var result:[MeshGeometrySource]=[]
      root.enumerateChildNodes{node,_ in
        if node.name?.hasPrefix(PaperGeometry.panelPrefix)==true,let source=node.geometry?.sources.first {result.append(source)}
      }
      return result
    }
    let first=sources(GeometryFactory.object(object,project:original,assets:assets,textureLimit:128))
    try set(store,id,.init(surface:.init(kind:.panel,surfaceID:"front"),bleedMM:3,safeInsetMM:2))
    let withIntent=try XCTUnwrap(store.project),physical=withIntent.objects[0],cache=CanvasPhysicalArtworkGuideCache()
    let second=sources(GeometryFactory.object(physical,project:withIntent,assets:assets,textureLimit:128))
    XCTAssertFalse(first.isEmpty);XCTAssertEqual(first.count,second.count)
    for (a,b) in zip(first,second){XCTAssertTrue(a === b,"Guide intent is not geometry or texture source")}
    let initial=try XCTUnwrap(cache.report(for:physical,in:withIntent))
    _ = try store.engine.call("form_construction",arguments:["command":"parameter","object_id":id.uuidString,"values":["fold":37]])
    let folded=try XCTUnwrap(store.project),report=try XCTUnwrap(cache.report(for:folded.objects[0],in:folded))
    XCTAssertEqual(initial.sourceRevision,report.sourceRevision);XCTAssertEqual(cache.builds,1)
    var invalid=folded.objects[0];invalid.physicalArtworkIntents![0].safeInsetMM=100
    let reviewed=try XCTUnwrap(cache.report(for:invalid,in:folded))
    XCTAssertTrue(try XCTUnwrap(reviewed.guides.first).safe.isEmpty)
    XCTAssertTrue(reviewed.requiresReview);XCTAssertEqual(cache.builds,2)
  }
  func testAssemblySelectedSourceUsesCanonicalSewingIntentForNativeGuidePixelsAndFit() throws {
    let (store,_)=try fixture()
    var project=Project(name:"Unregistered source preview relationship")
    let recipe=Recipe("linkedGuideSource","Original curved source","scissors","Canonical source controls",[
      .init("width","Source width",180,100...300),.init("depth","Source height",130,80...200),.init("span","Span",80,30...120)])
    project.recipes=[recipe]
    var source=try project.makeObject(recipeID:recipe.id)
    var piece=ArtworkElement(kind:"path",x:20,y:20,width:80,height:60)
    var contour=VectorContour([.init(.init(0,0)),.init(.init(80,0),outgoing:.init(83,25)),
      .init(.init(72,60),incoming:.init(80,48)),.init(.init(0,55))]);contour.id=UUID()
    piece.path = .init(width:80,height:60,contours:[contour])
    var annotation=SewingPatternPiece(name:"Original curved panel");annotation.seamAllowance=5
    piece.sewingPiece=try SewingPatterns.bindingStableEdges(annotation,to:piece);piece.fillEnabled=false
    source.artwork = .init(background:"#FFFFFF",elements:[piece])
    source.artworkParameterBindings=[.init(id:"panel-span",elementID:piece.id,property:.width,value:"span")]
    project.objects=[source]
    let material=project.material("flight-nylon")
    let assembly=try project.addPatternAssembly(.init(sourceObjectID:source.id,panels:[
      .init(panel:.init(elementID:piece.id,copy:1),pose:.init(originMm:.init(0,100,0)),material:material,densityGSM:180)
    ],seamIDs:[]),name:"Selected assembled preview")
    store.engine.project=project;store.select(assembly)
    XCTAssertEqual(store.activateFabricPatternSource(for:assembly),source.id)
    try set(store,source.id,.init(surface:.init(kind:.sewingPiece,surfaceID:piece.id.uuidString),bleedMM:3,safeInsetMM:4))
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count,session=store.artworkSession
    let frame=try XCTUnwrap(session.frames.first{$0.id==source.id})
    XCTAssertEqual(session.linkedTargetID,assembly);XCTAssertEqual(store.primary?.id,assembly)
    XCTAssertEqual(frame.surfaceObject.id,assembly,"The preview context must remain the actual assembled object")
    XCTAssertEqual(frame.physicalGuideObject.id,source.id,"Ordinary source frames derive their guides from their canonical owner")
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:900,height:680),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let scroll=ArtworkScrollView(frame:.init(x:0,y:0,width:860,height:630)),canvas=VectorCanvasView()
    scroll.allowsMagnification=true;scroll.minMagnification=0.08;scroll.maxMagnification=24
    scroll.documentView=canvas;canvas.session=session;session.canvas=canvas
    scroll.hasHorizontalRuler=true;scroll.hasVerticalRuler=true
    scroll.horizontalRulerView=ArtworkRuler(scrollView:scroll,orientation:.horizontalRuler)
    scroll.verticalRulerView=ArtworkRuler(scrollView:scroll,orientation:.verticalRuler);scroll.rulersVisible=true
    window.contentView?.addSubview(scroll);window.contentView?.layoutSubtreeIfNeeded();canvas.synchronize();scroll.tile()
    defer{canvas.finishText();window.contentView=nil;window.close()}
    let region=frame.rect.insetBy(dx:-8,dy:-8),a=canvas.documentPoint(region.origin),b=canvas.documentPoint(.init(x:region.maxX,y:region.maxY))
    let rect=CGRect(x:a.x,y:a.y,width:b.x-a.x,height:b.y-a.y),bitmap=try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in:rect))
    canvas.cacheDisplay(in:rect,to:bitmap)
    var purple=0,teal=0
    for y in 0..<bitmap.pixelsHigh {for x in 0..<bitmap.pixelsWide {
      guard let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else{continue}
      if c.redComponent-c.greenComponent>0.25,c.blueComponent-c.greenComponent>0.25{purple+=1}
      if c.greenComponent-c.redComponent>0.2,c.blueComponent-c.redComponent>0.2,abs(c.greenComponent-c.blueComponent)<0.15{teal+=1}
    }}
    XCTAssertGreaterThan(purple,20);XCTAssertGreaterThan(teal,20)
    XCTAssertEqual(canvas.diagnostics["physical_guide_builds"] as? Int,1)
    let guide=try XCTUnwrap(before.physicalArtworkIntentReport(for:frame.physicalGuideObject).guides.first)
    let points=(guide.trim+guide.bleed+guide.safe).flatMap{$0},first=try XCTUnwrap(points.first)
    let physical=points.dropFirst().reduce(CGRect(x:first.x,y:first.y,width:0,height:0)){$0.union(.init(x:$1.x,y:$1.y,width:0,height:0))}
      .offsetBy(dx:frame.rect.minX,dy:frame.rect.minY)
    for origin in [CGPoint.zero,CGPoint(x:-150,y:60)] {
      canvas.setFrameOrigin(origin);canvas.fit(all:true)
      XCTAssertTrue(canvas.visibleCanvasRect.insetBy(dx:-0.002,dy:-0.002).contains(physical))
      let document=CGRect(origin:canvas.documentPoint(physical.origin),size:.init(width:physical.width*72/25.4,height:physical.height*72/25.4))
      for ruler in [scroll.horizontalRulerView,scroll.verticalRulerView].compactMap({$0}) {
        XCTAssertFalse(document.intersects(canvas.convert(ruler.visibleRect,from:ruler)),"Fit must leave the actual native ruler bands unobstructed")
      }
    }
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
    XCTAssertEqual(store.project?.objects.first{$0.id==source.id}?.artwork,source.artwork)
  }

}

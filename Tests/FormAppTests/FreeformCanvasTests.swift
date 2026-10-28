import AppKit
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class FreeformCanvasTests: XCTestCase {
  @MainActor private final class Fixture {
    let root:URL,store:StudioStore,session:ArtworkSession,window:NSWindow,scroll:NSScrollView,canvas:VectorCanvasView
    let workspaceID:UUID
    let frameID:UUID?
    init(frame:Bool = false,elements:[ArtworkElement] = []) throws {
      _ = NSApplication.shared
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      store = StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
      var p = Project(name:"Freeform Canvas")
      let workspace = try p.ensureCanvasWorkspace(); workspaceID = workspace.id
      p.objects[0].artwork!.elements = elements
      p.objects[0].artwork!.snapEnabled = false
      if frame {
        var object = try p.makeObject(recipeID:"artboard",name:"Destination",parameters:["width":100,"depth":80])
        var art = Artwork(background:"#FFFFFF",bleed:0); art.canvasPosition = .init(100,100); art.snapEnabled = false
        object.artwork = art; p.objects.append(object); frameID = object.id
      } else { frameID = nil }
      p.schemaVersion = p.minimumSchemaVersion
      store.engine.project = p; store.mode = .artwork; store.showingHome = false
      session = store.artworkSession; session.objectID = workspaceID
      window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed = false
      scroll = NSScrollView(frame:window.contentView!.bounds); scroll.allowsMagnification = true
      scroll.minMagnification = 0.08; scroll.maxMagnification = 24
      canvas = VectorCanvasView(frame:NSRect(x:0,y:0,width:900,height:650))
      canvas.session = session; session.canvas = canvas; scroll.documentView = canvas
      window.contentView = scroll; window.makeFirstResponder(canvas)
      canvas.synchronize(); canvas.fit(all:true)
    }
    func close() { window.close(); try? FileManager.default.removeItem(at:root) }
    func event(_ type:NSEvent.EventType,_ world:CGPoint,count:Int = 1) -> NSEvent {
      let point = canvas.convert(canvas.documentPoint(world),to:nil)
      return NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
        windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:count,pressure:type == .leftMouseUp ? 0 : 1)!
    }
    func drag(from:CGPoint,to:CGPoint) {
      canvas.mouseDown(with:event(.leftMouseDown,from))
      canvas.mouseDragged(with:event(.leftMouseDragged,to))
      canvas.mouseUp(with:event(.leftMouseUp,to))
    }
    func textView(in parent:NSView? = nil) -> CanvasTextView? {
      let node = parent ?? canvas
      if let text = node as? CanvasTextView { return text }
      return node.subviews.compactMap { textView(in:$0) }.first
    }
  }
  private func assertPoint(_ a:CGPoint,_ b:CGPoint,accuracy:Double = 0.001,
    file:StaticString = #filePath,line:UInt = #line) {
    XCTAssertEqual(a.x,b.x,accuracy:accuracy,file:file,line:line)
    XCTAssertEqual(a.y,b.y,accuracy:accuracy,file:file,line:line)
  }
  func testWorkspaceIsUnframedFallbackAndDoesNotFollowOrReplacePhysicalSelection() throws {
    let f = try Fixture(frame:true); defer { f.close() }
    f.store.engine.selection = [f.frameID!]
    f.session.reconcile()
    XCTAssertEqual(f.session.objectID,f.workspaceID)
    XCTAssertNil(f.session.previewObject)
    XCTAssertTrue(f.session.frames.first!.isWorkspace)
    XCTAssertEqual(f.canvas.frame(atCanvasPoint:.init(x:130,y:130))?.id,f.frameID)
    XCTAssertEqual(f.canvas.frame(atCanvasPoint:.init(x:-300,y:-200))?.id,f.workspaceID)
    f.session.activate(f.frameID!); f.session.activate(f.workspaceID)
    XCTAssertEqual(f.store.engine.selection,[f.frameID!])
    f.session.reconcile(); XCTAssertEqual(f.session.objectID,f.workspaceID)
  }
  func testNativeShapeToolDrawsAtNegativeCoordinatesWithoutCreatingAFrame() throws {
    let f = try Fixture(); defer { f.close() }
    let baseline = f.store.project!
    f.session.tool = .rectangle
    f.drag(from:.init(x:-65,y:-45),to:.init(x:-25,y:-15))
    let shape = try XCTUnwrap(f.session.primary)
    XCTAssertEqual(shape.kind,"rectangle"); XCTAssertEqual(shape.x,-65,accuracy:0.001)
    XCTAssertEqual(shape.y,-45,accuracy:0.001); XCTAssertEqual(shape.width,40,accuracy:0.001)
    XCTAssertEqual(shape.height,30,accuracy:0.001)
    XCTAssertEqual(f.store.project!.objects.count,1)
    XCTAssertNil(f.store.error)
    f.store.engine.undo(); XCTAssertEqual(f.store.project,baseline)
  }
  func testNegativeCoordinateNativeTextInputIsPositionedAndUndoable() throws {
    let f = try Fixture(); defer { f.close() }
    let baseline = f.store.project!
    f.session.tool = .text
    f.canvas.mouseDown(with:f.event(.leftMouseDown,.init(x:-50,y:-30)))
    f.canvas.mouseUp(with:f.event(.leftMouseUp,.init(x:-50,y:-30)))
    XCTAssertTrue(f.session.editingText)
    let text = try XCTUnwrap(f.textView())
    assertPoint(text.convert(.zero,to:f.canvas),f.canvas.documentPoint(.init(x:-50,y:-30)))
    text.insertText("Free text",replacementRange:NSRange(location:0,length:text.string.utf16.count))
    XCTAssertEqual(f.session.primary?.text,"Free text")
    XCTAssertEqual(f.session.primary?.x,-50)
    f.canvas.finishText(); f.store.engine.undo()
    XCTAssertEqual(f.store.project,baseline)
  }
  func testNativeDragTransfersLooseArtworkOntoAFrameInOneUndoAndBack() throws {
    let shape = ArtworkElement(kind:"rectangle",x:-80,y:-50,width:30,height:20,color:"#AA5533")
    let f = try Fixture(frame:true,elements:[shape]); defer { f.close() }
    let baseline = f.store.project!
    f.session.choose([shape.id])
    f.drag(from:.init(x:-65,y:-40),to:.init(x:130,y:130))
    XCTAssertEqual(f.session.objectID,f.frameID)
    XCTAssertTrue(f.store.project!.canvasWorkspace!.artwork!.elements.isEmpty)
    let moved = try XCTUnwrap(f.session.primary)
    let point = f.session.art.worldTransform(moved).apply(.init(15,10))
    assertPoint(.init(x:point.x+100,y:point.y+100),.init(x:130,y:130))
    XCTAssertEqual(f.store.engine.undoStack.count,1)
    let placed = f.store.project!
    f.store.engine.undo(); XCTAssertEqual(f.store.project,baseline)
    f.store.engine.redo(); XCTAssertEqual(f.store.project,placed)
    f.canvas.synchronize(); f.session.choose([shape.id])
    f.drag(from:.init(x:130,y:130),to:.init(x:-120,y:-90))
    XCTAssertEqual(f.session.objectID,f.workspaceID)
    XCTAssertTrue(f.store.project!.objects.first { $0.id == f.frameID }!.artwork!.elements.isEmpty)
    XCTAssertNil(f.store.error)
    f.store.engine.undo(); XCTAssertEqual(f.store.project,placed)
  }
  func testRejectedInheritedAppearanceTransferRestoresTheOriginalDrag() throws {
    var group = ArtworkElement(kind:"group",x:-80,y:-60,width:60,height:50)
    group.contentSize = .init(60,50); group.opacity = 0.5
    var child = ArtworkElement(kind:"rectangle",x:10,y:10,width:30,height:20)
    child.parentID = group.id
    let f = try Fixture(frame:true,elements:[group,child]); defer { f.close() }
    f.session.scopeID = group.id; f.session.choose([child.id])
    let baseline = f.store.project!
    f.drag(from:.init(x:-55,y:-40),to:.init(x:130,y:130))
    XCTAssertNotNil(f.store.error)
    XCTAssertEqual(f.store.project,baseline)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }
  func testContentFitIgnoresTheWorkspaceExtentAndViewportSurvivesNegativeGrowth() throws {
    let shape = ArtworkElement(kind:"rectangle",x:-80,y:-50,width:30,height:20)
    let f = try Fixture(elements:[shape]); defer { f.close() }
    XCTAssertEqual(f.canvas.contentBounds(all:true),CGRect(x:-80,y:-50,width:30,height:20))
    f.canvas.fit(all:true)
    let before = f.canvas.visibleCanvasRect.origin
    f.session.add([ArtworkElement(kind:"ellipse",x:-1800,y:-900,width:40,height:40)])
    f.canvas.synchronize()
    assertPoint(f.canvas.visibleCanvasRect.origin,before)
    let point = CGPoint(x:-1760,y:-870)
    assertPoint(f.canvas.canvasPoint(f.canvas.documentPoint(point)),point)
    XCTAssertLessThan(f.canvas.canvasOrigin.x,-1800)
  }
  func testUnboundedRendererDrawsNegativeArtworkWithoutDrawingPaper() throws {
    var source = Artwork(background:"#0000FF",elements:[ArtworkElement(kind:"rectangle",x:-20,y:-20,width:10,height:10,color:"#FF0000")],bleed:0)
    source.backgroundOpacity = 1
    func counts(unbounded:Bool) throws -> (red:Int,blue:Int) {
      let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:80,pixelsHigh:80,bitsPerSample:8,
        samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
      let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep:bitmap))
      NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
      let context = graphics.cgContext; context.setFillColor(NSColor.white.cgColor)
      context.fill(CGRect(x:0,y:0,width:80,height:80)); context.translateBy(x:40,y:40)
      ArtworkRenderer.draw(source,width:20,height:20,assets:URL(fileURLWithPath:"/tmp"),unbounded:unbounded)
      NSGraphicsContext.restoreGraphicsState()
      var red = 0,blue = 0
      for y in 0..<80 { for x in 0..<80 {
        let color = bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
        if color.redComponent > 0.9 && color.greenComponent < 0.1 && color.blueComponent < 0.1 { red += 1 }
        if color.blueComponent > 0.9 && color.redComponent < 0.1 && color.greenComponent < 0.1 { blue += 1 }
      } }
      return(red,blue)
    }
    let bounded = try counts(unbounded:false),loose = try counts(unbounded:true)
    XCTAssertEqual(bounded.red,0); XCTAssertGreaterThan(bounded.blue,300)
    XCTAssertGreaterThan(loose.red,80); XCTAssertEqual(loose.blue,0)
  }
  func testLooseSelectionExportUsesItsPhysicalCropAndRejectsAnUnboundedExport() throws {
    let shape = ArtworkElement(kind:"rectangle",x:-80,y:-50,width:30,height:20,color:"#AA5533")
    let f = try Fixture(elements:[shape]); defer { f.close() }
    let url = f.root.appendingPathComponent("loose.svg")
    let object = f.store.project!.canvasWorkspace!
    XCTAssertThrowsError(try f.store.exportArtwork(object:object,arguments:["format":"svg","path":url.path]))
    XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    let result = try f.store.exportArtwork(object:object,arguments:["format":"svg","path":url.path,
      "element_ids":[shape.id.uuidString]]) as! [String:Any]
    XCTAssertEqual(result["width_mm"] as? Double,30); XCTAssertEqual(result["height_mm"] as? Double,20)
    XCTAssertTrue(try String(contentsOf:url,encoding:.utf8).contains("#AA5533"))
  }
  func testImagePlacementAcceptsLooseCanvasAndPreservesItsOriginalAsset() throws {
    let f = try Fixture(); defer { f.close() }
    let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:20,pixelsHigh:10,bitsPerSample:8,
      samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    let data = try XCTUnwrap(image.representation(using:.png,properties:[:]))
    let url = f.root.appendingPathComponent("reference.png"); try data.write(to:url)
    XCTAssertTrue(f.session.placeImages([url],point:.init(-60,-40)))
    let placed = try XCTUnwrap(f.session.primary)
    XCTAssertEqual(placed.kind,"image"); XCTAssertLessThanOrEqual(placed.width,120)
    XCTAssertEqual(placed.x+placed.width/2,-60,accuracy:0.001)
    XCTAssertEqual(placed.y+placed.height/2,-40,accuracy:0.001)
    let asset = f.session.assets.appendingPathComponent(try XCTUnwrap(placed.asset))
    XCTAssertEqual(try Data(contentsOf:asset),data)
    XCTAssertNil(f.store.error)
  }
}

import AppKit
import FormCADModel
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class CanvasFrameIdentityTests:XCTestCase {
  @MainActor private final class Fixture {
    let directory:URL,store:StudioStore,session:ArtworkSession,canvas:VectorCanvasView,window:NSWindow
    let artboardID:UUID,paperID:UUID
    init()throws {
      _ = NSApplication.shared
      directory=FileManager.default.temporaryDirectory.appendingPathComponent("canvas-frame-identity-"+UUID().uuidString)
      store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
      var project=Project(name:"Frame chrome is not artwork")
      var artboard=try project.makeObject(recipeID:"artboard",name:"Art",parameters:["width":120,"depth":80])
      var art=Artwork(background:"#FFFFFF",elements:[.init(kind:"rectangle",x:45,y:30,width:10,height:8,color:"#862A91")],bleed:0)
      art.showGuides=false;art.snapEnabled=false;art.canvasPosition = .init(36,40);artboard.artwork=art
      let definition=PlanarConstructionDefinition(name:"Generic sheet",size:.init(120,80),panels:[
        .init(id:"sheet",name:"Sheet",polygon:[.init(0,0),.init(120,0),.init(120,80),.init(0,80)],
          cutouts:[.init(id:"window",polygon:[.init(70,30),.init(80,30),.init(80,40),.init(70,40)],kind:.window)])],rootPanelID:"sheet")
      project.recipes.append(.init("frame-identity-sheet","Paper","square","Authored fixture",[
        .init("fold","Fold",100,0...100),.init("opening","Opening",0,0...100)]))
      var paper=try project.makeObject(recipeID:"frame-identity-sheet",name:"Paper")
      var settings=PaperConstruction(kind:.authored,dimensions:.init(width:120,height:80,depth:1));settings.authored=definition;paper.paperConstruction=settings
      art.canvasPosition=nil;art.backgroundOpacity=0;paper.artwork=art
      artboardID=artboard.id;paperID=paper.id;project.objects=[artboard,paper];project.schemaVersion=project.minimumSchemaVersion
      store.engine.project=project;store.showingHome=false;store.mode = .artwork;store.paperShowingGuides=false
      session=store.artworkSession;session.activate(artboardID)
      window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1000,height:700),styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false
      let scroll=ArtworkScrollView(frame:window.contentView!.bounds)
      scroll.allowsMagnification=true;scroll.minMagnification=0.08;scroll.maxMagnification=24
      canvas=VectorCanvasView(frame:scroll.bounds);canvas.session=session;session.canvas=canvas;scroll.documentView=canvas;window.contentView=scroll
      window.makeFirstResponder(canvas);canvas.synchronize();canvas.fit(all:true)
    }
    func frame(_ role:CanvasFrameRole)throws->CanvasFrame {
      try XCTUnwrap(session.frames.first {frame in
        switch role {
        case .artboard:return frame.id==artboardID
        case .construction:return frame.projection?.constructionID==paperID && frame.projection?.inside==false && frame.projection?.isProof==true
        case .surface:return frame.projection?.constructionID==paperID && frame.projection?.inside==false && frame.projection?.panelID=="sheet"
        }
      })
    }
    func capture(_ world:CGRect)throws->NSBitmapImageRep {
      canvas.ensureViewportCoverage(preserving:.init(x:world.midX,y:world.midY))
      let a=canvas.documentPoint(world.origin),b=canvas.documentPoint(.init(x:world.maxX,y:world.maxY))
      let rect=CGRect(x:a.x,y:a.y,width:b.x-a.x,height:b.y-a.y)
      let bitmap=try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in:rect));canvas.cacheDisplay(in:rect,to:bitmap);return bitmap
    }
    func exports()throws->[String] {
      try store.project!.objects.map {object in
        try SVGRenderer.document(try XCTUnwrap(object.artwork),width:120,height:80,assets:directory)
      }
    }
    func close() {canvas.finishText();window.contentView=nil;window.close();store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
  }
  private struct Pixels {
    let width:Int,height:Int,bytes:[UInt8]
    init(_ bitmap:NSBitmapImageRep)throws {
      let image=try XCTUnwrap(bitmap.cgImage);width=image.width;height=image.height
      let context=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
        space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image,in:.init(x:0,y:0,width:width,height:height))
      bytes=Array(UnsafeBufferPointer(start:try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self),count:width*height*4))
    }
    func inkBounds(color:NSColor,background:NSColor,xRange:Range<Int>?=nil)->CGRect? {
      let c=color.usingColorSpace(.sRGB)!,bg=background.usingColorSpace(.sRGB)!
      let rgb=[Double(c.redComponent),Double(c.greenComponent),Double(c.blueComponent)],base=[Double(bg.redComponent),Double(bg.greenComponent),Double(bg.blueComponent)]
      var minX=width,minY=height,maxX = -1,maxY = -1
      for y in 0..<height {for x in xRange ?? 0..<width {
        let index=(y*width+x)*4,actual=(0..<3).map{Double(bytes[index+$0])/255}
        let difference=zip(actual,rgb).map{abs($0.0-$0.1)}.max()!,contrast=zip(actual,base).map{abs($0.0-$0.1)}.max()!
        if difference<0.28 && contrast>0.18 {minX=min(minX,x);minY=min(minY,y);maxX=max(maxX,x);maxY=max(maxY,y)}
      }}
      return maxX>=minX ? .init(x:minX,y:minY,width:maxX-minX+1,height:maxY-minY+1):nil
    }
  }
  private func header(_ frame:CanvasFrame,scale:Double,appearance:InterfaceAppearance)throws->Pixels {
    let size=CGSize(width:min(240,frame.rect.width*scale),height:CanvasFrameChrome.headerHeight),density=2.0
    let image=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(ceil(size.width*density)),pixelsHigh:Int(size.height*density),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    let context=try XCTUnwrap(NSGraphicsContext(bitmapImageRep:image)).cgContext
    context.scaleBy(x:density,y:density);context.setFillColor(appearance.canvasBackgroundColor.cgColor)
    // The rounded-up pixel width can exceed the requested point width. Paint
    // that fractional final column too; transparent black is not header ink.
    context.fill(.init(x:0,y:0,width:Double(image.pixelsWide)/density,height:Double(image.pixelsHigh)/density))
    let rect=CanvasFrameChrome.headerRect(for:frame,scale:scale)
    context.scaleBy(x:scale,y:scale);context.translateBy(x:-rect.minX,y:-rect.minY)
    NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
    NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
    CanvasFrameChrome.drawHeader(frame,context:context,scale:scale,appearance:appearance)
    return try Pixels(image)
  }
  private func contrast(_ a:NSColor,_ b:NSColor)->Double {
    func luminance(_ value:NSColor)->Double {
      let c=value.usingColorSpace(.sRGB)!
      func channel(_ x:CGFloat)->Double {x<=0.04045 ? Double(x)/12.92:pow((Double(x)+0.055)/1.055,2.4)}
      return 0.2126*channel(c.redComponent)+0.7152*channel(c.greenComponent)+0.0722*channel(c.blueComponent)
    }
    let x=luminance(a),y=luminance(b);return(max(x,y)+0.05)/(min(x,y)+0.05)
  }

  func testClassificationUsesActualProjectionAndSewingSourceRatherThanRecipeNames()throws {
    let f=try Fixture();defer{f.close()}
    for role in CanvasFrameRole.allCases {XCTAssertEqual(try f.frame(role).role,role);XCTAssertNotNil(NSImage(systemSymbolName:role.symbolName,accessibilityDescription:nil))}
    XCTAssertEqual(CanvasFrameRole.artboard.defaultHex,"#3D4148");XCTAssertEqual(CanvasFrameRole.construction.defaultHex,"#376BB0");XCTAssertEqual(CanvasFrameRole.surface.defaultHex,"#AD5145")
    var sewing=try f.frame(.artboard);sewing.artwork.elements[0].sewingPiece = .init(name:"Authored panel")
    XCTAssertEqual(sewing.role,.construction)
    var legacy=try f.frame(.artboard);legacy.legacyDieline=true;XCTAssertEqual(legacy.role,.construction)
    var workspace=legacy;workspace.object.canvasWorkspace=true;XCTAssertEqual(workspace.role,.artboard)
  }

  func testProductionHeaderRasterKeepsReadableColoredSymbolsAndTextAtConstantScreenSizeOnBothBackgrounds()throws {
    let f=try Fixture();defer{f.close()}
    let appearance=InterfaceAppearance(file:f.directory.appendingPathComponent("private-appearance.json"))
    for background in ["#FFFFFF","#222222"] {
      try appearance.setCanvasBackground(background)
      for role in CanvasFrameRole.allCases {
        let frame=try f.frame(role),color=appearance.frameColor(for:role)
        XCTAssertGreaterThanOrEqual(contrast(color,appearance.canvasBackgroundColor),4.5-1e-6)
        let rgb=try XCTUnwrap(color.usingColorSpace(.sRGB))
        if role == .construction {XCTAssertGreaterThan(rgb.blueComponent,rgb.redComponent+0.10)}
        if role == .surface {XCTAssertGreaterThan(rgb.redComponent,rgb.blueComponent+0.10)}
        var iconSizes:[CGSize]=[],labelHeights:[CGFloat]=[]
        for zoom in [0.25,1.5] {
          let scale=TypographyEngine.pointsPerMM*zoom,rect=CanvasFrameChrome.headerRect(for:frame,scale:scale)
          XCTAssertEqual(rect.height*scale,16,accuracy:1e-8);XCTAssertEqual(rect.maxY,frame.rect.minY,accuracy:1e-8)
          let pixels=try header(frame,scale:scale,appearance:appearance)
          let caseLabel="\(role.rawValue), \(background), zoom \(zoom)"
          XCTAssertTrue(stride(from:3,to:pixels.bytes.count,by:4).allSatisfy{pixels.bytes[$0]==255},"Every allocated pixel needs an opaque background: \(caseLabel).")
          let icon=try XCTUnwrap(pixels.inkBounds(color:color,background:appearance.canvasBackgroundColor,xRange:0..<28),"The actual SF icon must contain visible category ink: \(caseLabel).")
          let label=try XCTUnwrap(pixels.inkBounds(color:color,background:appearance.canvasBackgroundColor,xRange:28..<pixels.width),"The actual title must contain readable category ink: \(caseLabel).")
          iconSizes.append(.init(width:icon.width/2,height:icon.height/2));labelHeights.append(label.height/2)
          XCTAssertGreaterThan(icon.width/2,2.5);XCTAssertLessThanOrEqual(icon.width/2,12)
          XCTAssertGreaterThan(label.height/2,3,caseLabel);XCTAssertLessThanOrEqual(label.height/2,12,caseLabel)
        }
        XCTAssertEqual(iconSizes[0].width,iconSizes[1].width,accuracy:2)
        XCTAssertEqual(iconSizes[0].height,iconSizes[1].height,accuracy:2)
        XCTAssertEqual(labelHeights[0],labelHeights[1],accuracy:2,"\(role.rawValue), \(background)")
      }
    }
  }

  func testActualCanvasHeadersAndOutlinesKeepCategoryColorWhenActiveOrInactiveWithoutChangingExport()throws {
    let f=try Fixture();defer{f.close()}
    let before=try XCTUnwrap(f.store.project),exports=try f.exports()
    for zoom in [0.25,1.5] {for role in CanvasFrameRole.allCases {for active in [false,true] {
      let frame=try f.frame(role),other=try f.frame(role == .artboard ? .surface:.artboard)
      f.session.activate(active ? frame.id:other.id);f.session.choose([]);f.canvas.synchronize();f.canvas.setZoom(zoom)
      let scale=TypographyEngine.pointsPerMM*zoom,color=InterfaceAppearance.shared.frameColor(for:role),background=Palette.canvasBackgroundNS
      let header=CanvasFrameChrome.headerRect(for:frame,scale:scale)
      let heading=CGRect(x:header.minX,y:header.minY,width:min(header.width,160/scale),height:header.height)
      XCTAssertNotNil(try Pixels(f.capture(heading)).inkBounds(color:color,background:background),"Native Canvas must draw the shared header, active=\(active), role=\(role).")
      let edge=CGRect(x:frame.rect.minX+20/scale,y:frame.rect.minY-2/scale,width:40/scale,height:4/scale)
      XCTAssertNotNil(try Pixels(f.capture(edge)).inkBounds(color:color,background:background),"Active state must retain the outline category.")
      if role == .surface {
        let hole=CGRect(x:frame.rect.minX+70-2/scale,y:frame.rect.minY+34,width:4/scale,height:2)
        XCTAssertNotNil(try Pixels(f.capture(hole)).inkBounds(color:color,background:background),"Projected outlines must follow the real window contour.")
      }
    }}}
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty);XCTAssertEqual(try f.exports(),exports)
  }

  func testRealTitleStripDraggingKeepsPhysicalArtworkAndExportWhileMovingOnlyFramePlacement()throws {
    let f=try Fixture();defer{f.close()}
    for role in CanvasFrameRole.allCases {
      let frame=try f.frame(role),before=try XCTUnwrap(f.store.project),exports=try f.exports()
      f.session.activate(frame.id);f.canvas.synchronize();f.canvas.setZoom(1)
      let scale=TypographyEngine.pointsPerMM,header=CanvasFrameChrome.headerRect(for:frame,scale:scale)
      let world=CGPoint(x:header.minX+20/scale,y:header.midY)
      XCTAssertTrue(header.contains(world));XCTAssertFalse(frame.rect.contains(world))
      f.canvas.ensureViewportCoverage(preserving:world)
      let start=f.canvas.convert(f.canvas.documentPoint(world),to:nil),end=CGPoint(x:start.x+7*scale,y:start.y-5*scale)
      let host=try XCTUnwrap(f.window.contentView),hit=host.hitTest(host.superview?.convert(start,from:nil) ?? start)
      XCTAssertTrue(hit === f.canvas)
      func event(_ type:NSEvent.EventType,_ point:CGPoint)throws->NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:f.window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1))
      }
      hit?.mouseDown(with:try event(.leftMouseDown,start));f.canvas.mouseDragged(with:try event(.leftMouseDragged,end));f.canvas.mouseUp(with:try event(.leftMouseUp,end))
      let moved=try f.frame(role)
      XCTAssertEqual(moved.id,frame.id);XCTAssertEqual(moved.rect.minX,frame.rect.minX+7,accuracy:1e-7);XCTAssertEqual(moved.rect.minY,frame.rect.minY+5,accuracy:1e-7)
      for original in before.objects {
        var actual=try XCTUnwrap(f.store.project?.objects.first{$0.id==original.id}?.artwork)
        actual.canvasPosition=original.artwork?.canvasPosition;XCTAssertEqual(actual,original.artwork)
      }
      XCTAssertEqual(try f.exports(),exports);XCTAssertEqual(f.store.engine.undoStack.count,1)
      f.store.engine.undo();f.session.reconcile();f.canvas.synchronize();XCTAssertEqual(f.store.project,before)
    }
  }
}

import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class EmbroideryProcessTests:XCTestCase {
  private func fixture()throws -> (Project,ProductObject) {
    var p=Project(name:"Needle process proof")
    var object=try p.makeObject(recipeID:"textilePatch",parameters:["width":80,"depth":60,"corner":3])
    let satin=ArtworkElement(kind:"line",x:7,y:10,width:30,height:0.1,color:"#C75332")
    var fill=ArtworkElement(kind:"path",x:0,y:0,width:80,height:60,color:"#285B8A")
    func contour(_ x:Double,_ y:Double,_ w:Double,_ h:Double)->VectorContour {.init([BezierNode(.init(x,y)),BezierNode(.init(x+w,y)),BezierNode(.init(x+w,y+h)),BezierNode(.init(x,y+h))],closed:true)}
    fill.path = .init(width:80,height:60,contours:[contour(45,8,27,43),contour(52,22,12,15)],evenOdd:true)
    object.artwork=Artwork(background:"#E9E2D2",elements:[satin,fill],bleed:0)
    var a=EmbroideryRegion(elementIDs:[satin.id],method:.satin),b=EmbroideryRegion(elementIDs:[fill.id],method:.fill,threadIndex:1)
    a.satinWidth=3;a.stitchLength=4;a.spacing=0.6;a.underlay = .init(method:.centerWalk)
    b.spacing=0.65;b.underlay = .init(method:.sparseFill)
    var process=EmbroideryProcess();process.tieIn=true;process.tieOff=true;process.tieLength=0.7;process.threadDiameter=0.3
    var design=EmbroideryDesign(threads:[.init(name:"Orange",color:satin.color),.init(name:"Blue",color:fill.color)],regions:[a,b]);design.process=process
    object.textile?.embroidery=design;p.objects=[object];return (p,object)
  }
  func testCenterWalkCrossFillAndBacktrackingAreRealOrderedBoundedNeedleCommands()throws {
    let (p,object)=try fixture(),program=try EmbroideryDigitizer.generate(object:object,project:p)
    try program.validate()
    let underlay=program.commands.filter {$0.action == .stitch && $0.purpose == .underlay}
    let ties=program.commands.filter {$0.action == .stitch && [.tieIn,.tieOff].contains($0.purpose)}
    XCTAssertGreaterThan(underlay.count,100);XCTAssertGreaterThan(ties.count,8)
    for region in program.design.regions {
      let firstTop=try XCTUnwrap(program.commands.firstIndex {$0.regionID==region.id && $0.action == .stitch && $0.purpose==nil})
      let lastUnderlay=try XCTUnwrap(program.commands.lastIndex {$0.regionID==region.id && $0.action == .stitch && $0.purpose == .underlay})
      XCTAssertLessThan(lastUnderlay,firstTop)
    }
    let satin=underlay.filter {$0.threadIndex==0}
    XCTAssertEqual(satin.first?.x,satin.last?.x);XCTAssertEqual(satin.first?.y,satin.last?.y)
    var plain=program.design;plain.process?.tieIn=false;plain.process?.tieOff=false
    let unlocked=try EmbroideryDigitizer.generate(object:object,project:p,design:plain)
    XCTAssertEqual(program.commands.filter {$0.purpose != .tieIn && $0.purpose != .tieOff},unlocked.commands)
    var prior=Point2()
    for command in program.commands {
      if command.purpose == .tieIn || command.purpose == .tieOff {
        XCTAssertLessThanOrEqual(hypot(command.point.x-prior.x,command.point.y-prior.y),0.85)
      }
      prior=command.point
    }
    XCTAssertEqual(try EmbroideryDigitizer.generate(object:object,project:p),program)
    if let folder=ProcessInfo.processInfo.environment["FORM_EMBROIDERY_PROCESS_PROOF_DIR"] {
      let directory=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
      try EmbroideryDST.data(program).write(to:directory.appendingPathComponent("complete-process.dst"));try JSONEncoder.form.encode(program).write(to:directory.appendingPathComponent("complete-process.json"))
    }
  }
  func testSparseUnderlayPreservesCompoundHoleAndPhysicalInset()throws {
    let (p,object)=try fixture(),program=try EmbroideryDigitizer.generate(object:object,project:p)
    var previous=Point2()
    for command in program.commands {
      if command.action == .stitch,command.purpose == .underlay,command.threadIndex==1 {
        for fraction in [0.0,0.5,1.0] {
          let x=previous.x+(command.point.x-previous.x)*fraction+40,y=previous.y+(command.point.y-previous.y)*fraction+30
          XCTAssertGreaterThanOrEqual(x,45.35);XCTAssertLessThanOrEqual(x,71.65)
          XCTAssertGreaterThanOrEqual(y,8.35);XCTAssertLessThanOrEqual(y,50.65)
          XCTAssertFalse(x>51.65 && x<64.35 && y>21.65 && y<37.35)
        }
      }
      previous=command.point
    }
  }
  func testProcessDefaultsAndSchema28PersistenceAndBudgetPreflight()throws {
    let (p,object)=try fixture()
    let process=try JSONDecoder.form.decode(EmbroideryProcess.self,from:Data("{\"tieIn\":true}".utf8))
    XCTAssertTrue(process.tieIn);XCTAssertEqual(process.threadDiameter,0.22);XCTAssertFalse(process.tieOff)
    XCTAssertEqual(p.minimumSchemaVersion,28)
    var invalid=object.textile!.embroidery!;invalid.regions[0].underlay?.method = .sparseFill
    XCTAssertThrowsError(try invalid.validate())
    invalid=object.textile!.embroidery!;invalid.regions[1].underlay?.spacing=0.8
    XCTAssertThrowsError(try invalid.validate())
    invalid=object.textile!.embroidery!;invalid.process?.tieLength = .nan
    XCTAssertThrowsError(try invalid.validate())
    var unlocked=object.textile!.embroidery!;unlocked.process?.tieIn=false;unlocked.process?.tieOff=false
    let plain=try EmbroideryDigitizer.generate(object:object,project:p,design:unlocked)
    var bounded=object.textile!.embroidery!;bounded.maximumStitches=plain.stitchCount
    XCTAssertThrowsError(try EmbroideryDigitizer.generate(object:object,project:p,design:bounded))
    let pointOnly=EmbroideryProgram(name:"Point",sourceDigest:"point",design:object.textile!.embroidery!,commands:[
      .init(.jump,x:10,y:10,threadIndex:0),.init(.stitch,x:10,y:10,threadIndex:0),.init(.end,x:10,y:10,threadIndex:0)])
    XCTAssertThrowsError(try EmbroideryTies.applying(to:pointOnly))
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root);try repository.save(p)
    let loaded=try repository.load(p.id)
    XCTAssertEqual(loaded.schemaVersion,28);XCTAssertEqual(loaded.objects[0].textile?.embroidery,object.textile?.embroidery)
  }
  func testSurfaceMapsUseExactFaceCoordinatesAndNeverPaintTravel()throws {
    var region=EmbroideryRegion(elementIDs:[UUID()],method:.running);region.stitchLength=10
    var design=EmbroideryDesign(threads:[.init(name:"Orange",color:"#C75332"),.init(name:"Blue",color:"#285B8A")],regions:[region])
    var process=EmbroideryProcess();process.threadDiameter=0.5;design.process=process
    let commands:[EmbroideryCommand]=[.init(.jump,x:-200,y:-150,threadIndex:0),.init(.stitch,x:-200,y:-150,threadIndex:0),.init(.stitch,x:-100,y:-150,threadIndex:0),.init(.trim,x:-100,y:-150,threadIndex:0),.init(.colorChange,x:-100,y:-150,threadIndex:1),.init(.jump,x:100,y:100,threadIndex:1),.init(.stitch,x:100,y:100,threadIndex:1),.init(.stitch,x:200,y:100,threadIndex:1),.init(.end,x:200,y:100,threadIndex:1)]
    let program=EmbroideryProgram(name:"Placement",sourceDigest:"known",design:design,commands:commands)
    let result=try EmbroiderySurface.make(program:program,width:80,height:60,limit:320)
    XCTAssertEqual(result.pixelsWide,320);XCTAssertEqual(result.pixelsHigh,240)
    let color=try XCTUnwrap(result.diffuse.representations.first as? NSBitmapImageRep),normal=try XCTUnwrap(result.normal.representations.first as? NSBitmapImageRep)
    func pixel(_ x:Double,_ y:Double)->NSColor {color.colorAt(x:Int((x+40)*4),y:Int((y+30)*4))!.usingColorSpace(.sRGB)!}
    XCTAssertGreaterThan(pixel(-15,-15).alphaComponent,0.9);XCTAssertGreaterThan(pixel(-15,-15).redComponent,pixel(-15,-15).blueComponent)
    XCTAssertGreaterThan(pixel(15,10).blueComponent,pixel(15,10).redComponent)
    XCTAssertEqual(pixel(0,-2.5).alphaComponent,0,accuracy:0.01);XCTAssertEqual(pixel(-10,-7.5).alphaComponent,0,accuracy:0.01)
    // A normal map encodes vector components, not display-managed colors.
    // Inspect stored channels directly; NSColor profile conversion changes them.
    var flat=[UInt](repeating:0,count:4);normal.getPixel(&flat,atX:160,y:120)
    XCTAssertEqual(flat,[128,128,255,255])
    let bounded=try EmbroiderySurface.make(program:program,width:80,height:60,limit:8192)
    XCTAssertEqual(bounded.pixelsWide,1024);XCTAssertLessThanOrEqual(bounded.pixelsHigh,1024)
  }
  func testSurfaceCacheInvalidatesGeometryAndFontsWhileIgnoringPlacementAndPrintRoleFiltering()throws {
    var (p,object)=try fixture();EmbroiderySurface.invalidate()
    object.artwork!.elements[0].productionRole="stitch";p.objects=[object]
    let before=EmbroiderySurface.programBuilds,first=try EmbroiderySurface.resources(object:object,project:p,fontRevision:10,textureLimit:320)
    XCTAssertTrue(first === (try EmbroiderySurface.resources(object:object,project:p,fontRevision:10,textureLimit:320)))
    var moved=object;moved.position.x+=100;moved.textile?.attachment=nil
    XCTAssertTrue(first === (try EmbroiderySurface.resources(object:moved,project:p,fontRevision:10,textureLimit:320)))
    XCTAssertEqual(EmbroiderySurface.programBuilds,before+1)
    let font=try EmbroiderySurface.resources(object:object,project:p,fontRevision:11,textureLimit:320)
    XCTAssertFalse(first === font);XCTAssertEqual(font.program.commands,first.program.commands)
    object.artwork!.elements[0].width=24;p.objects=[object]
    let changed=try EmbroiderySurface.resources(object:object,project:p,fontRevision:11,textureLimit:320)
    XCTAssertNotEqual(changed.program.commands,first.program.commands)
    XCTAssertNotEqual(changed.program.sourceDigest,first.program.sourceDigest)
  }
}

import AppKit
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class EmbroideryTests:XCTestCase {
  private func fixture()throws -> (Project,ProductObject,ArtworkElement,ArtworkElement,ArtworkElement) {
    var p=Project(name:"Orbital stitch study")
    var patch=try p.makeObject(recipeID:"textilePatch",name:"Orbital patch",parameters:["width":80,"depth":60,"corner":3])
    let running=ArtworkElement(kind:"line",x:8,y:8,width:30,height:0.1,color:"#C74C32")
    let satin=ArtworkElement(kind:"line",x:8,y:17,width:30,height:0.1,color:"#E9DDB7")
    let fill=ArtworkElement(kind:"rectangle",x:45,y:10,width:25,height:35,color:"#285B8A")
    patch.artwork=Artwork(background:"#FFFFFF",elements:[running,satin,fill],bleed:0)
    var a=EmbroideryRegion(elementIDs:[running.id],method:.running),b=EmbroideryRegion(elementIDs:[satin.id],method:.satin,threadIndex:1),c=EmbroideryRegion(elementIDs:[fill.id],method:.fill,threadIndex:2)
    a.stitchLength=2;b.stitchLength=4;b.satinWidth=3;b.spacing=0.7;c.spacing=1;c.stitchLength=2.5
    patch.textile?.embroidery = .init(threads:[.init(name:"Orange",color:running.color),.init(name:"Ecru",color:satin.color),.init(name:"Blue",color:fill.color)],regions:[a,b,c])
    p.objects=[patch];return (p,patch,running,satin,fill)
  }
  func testDSTBalancedTernaryCoversEveryAxisPairAndKnownIndependentBitPositions()throws {
    XCTAssertEqual(try EmbroideryDST.record(dx:1,dy:0),[1,0,3])
    XCTAssertEqual(try EmbroideryDST.record(dx:0,dy:1),[0x40,0,3])
    XCTAssertEqual(try EmbroideryDST.record(dx:81,dy:-81,jump:true),[0,0,0xA7])
    for x in -121...121 {for y in -121...121 {
      let actual=try EmbroideryDST.movement(EmbroideryDST.record(dx:x,dy:y,jump:x%2==0))
      XCTAssertEqual(actual.x,x);XCTAssertEqual(actual.y,y);XCTAssertEqual(actual.jump,x%2==0)
    }}
    XCTAssertThrowsError(try EmbroideryDST.record(dx:122,dy:0))
    XCTAssertThrowsError(try EmbroideryDST.record(dx:Int.min,dy:0))
    XCTAssertThrowsError(try EmbroideryDST.movement([0,0,0xC3]))
  }
  func testActualMethodsRespectLengthSatinRailsThreadChangesAndDeterminism()throws {
    let (p,patch,running,satin,_)=try fixture()
    let a=try EmbroideryDigitizer.generate(object:patch,project:p),b=try EmbroideryDigitizer.generate(object:patch,project:p)
    XCTAssertEqual(a,b);XCTAssertGreaterThan(a.stitchCount,300);XCTAssertEqual(a.threadOrder,[0,1,2])
    let satinID=patch.textile!.embroidery!.regions[1].id
    let rail=a.commands.filter {$0.regionID==satinID && $0.action == .stitch}
    XCTAssertGreaterThan(rail.count,30)
    // The line's 0.1 mm height makes its centerline very slightly sloped.
    let ys=rail.map {Double($0.y)/10-(satin.y-30)}
    XCTAssertEqual(ys.max()!,1.6,accuracy:0.11);XCTAssertEqual(ys.min()!,-1.5,accuracy:0.11)
    var previous=Point2()
    for command in a.commands {
      if command.action == .stitch {
        let maximum=command.threadIndex==0 ? 2.15:command.threadIndex==1 ? 4.15:2.65
        XCTAssertLessThanOrEqual(hypot(command.point.x-previous.x,command.point.y-previous.y),maximum)
      }
      previous=command.point
    }
    XCTAssertEqual(a.commands.filter {$0.action == .colorChange}.count,2)
    XCTAssertTrue(a.commands.contains {$0.action == .trim});XCTAssertTrue(a.commands.contains {$0.action == .jump})
    var changed=p;changed.objects[0].artwork!.elements.firstIndex(where:{$0.id==running.id}).map {changed.objects[0].artwork!.elements[$0].width=20}
    let c=try EmbroideryDigitizer.generate(object:changed.objects[0],project:changed)
    XCTAssertNotEqual(a.sourceDigest,c.sourceDigest);XCTAssertNotEqual(a.commands,c.commands)
  }
  func testCompoundHolesAndInheritedClipPreventFillSegmentsAcrossEmptyAreas()throws {
    var (p,patch,_,_,_)=try fixture()
    func contour(_ x:Double,_ y:Double,_ w:Double,_ h:Double)->VectorContour {.init([BezierNode(.init(x,y)),BezierNode(.init(x+w,y)),BezierNode(.init(x+w,y+h)),BezierNode(.init(x,y+h))],closed:true)}
    var group=ArtworkElement(kind:"group",x:5,y:4,width:60,height:45);group.contentSize = .init(60,45)
    var mask=ArtworkElement(kind:"rectangle",x:8,y:2,width:35,height:38);mask.parentID=group.id
    group.clipID=mask.id
    var shape=ArtworkElement(kind:"path",x:0,y:0,width:50,height:40);shape.parentID=group.id
    shape.path = .init(width:50,height:40,contours:[contour(0,0,50,40),contour(15,10,14,16)],evenOdd:true)
    patch.artwork=Artwork(background:"#FFFFFF",elements:[group,mask,shape],bleed:0)
    var region=EmbroideryRegion(elementIDs:[shape.id],method:.fill);region.spacing=0.8;region.angle=27
    patch.textile?.embroidery = .init(threads:[.init(name:"Blue",color:"#285B8A")],regions:[region]);p.objects=[patch]
    let program=try EmbroideryDigitizer.generate(object:patch,project:p)
    let path=VectorGeometry.worldPath(shape,in:patch.artwork!),clip=VectorGeometry.worldPath(mask,in:patch.artwork!)
    var previous=Point2()
    for command in program.commands {
      if command.action == .stitch {
        for f in [0.2,0.5,0.8] {
          let point=CGPoint(x:previous.x+(command.point.x-previous.x)*f+40,y:previous.y+(command.point.y-previous.y)*f+30)
          XCTAssertTrue(path.contains(point,using:.evenOdd),"Fill crossed the compound hole at \(point)")
          XCTAssertTrue(clip.contains(point),"Fill crossed its inherited clipping boundary")
        }
      }
      previous=command.point
    }
    XCTAssertGreaterThan(program.stitchCount,100)
  }
  func testCubicRunningGeometryIsFlattenedAtPhysicalToleranceAndBounded()throws {
    var (p,patch,_,_,_)=try fixture()
    let n1=BezierNode(.init(3,25),outgoing:.init(3,0)),n2=BezierNode(.init(65,25),incoming:.init(65,55))
    var curve=ArtworkElement(kind:"path",x:0,y:0,width:80,height:60);curve.fillEnabled=false
    curve.path = .init(width:80,height:60,contours:[.init([n1,n2],closed:false)])
    patch.artwork=Artwork(elements:[curve]);var region=EmbroideryRegion(elementIDs:[curve.id],method:.running);region.stitchLength=1.7
    patch.textile?.embroidery = .init(threads:[.init(name:"Ecru",color:"#E9DDB7")],regions:[region]);p.objects=[patch]
    let program=try EmbroideryDigitizer.generate(object:patch,project:p)
    let points=program.commands.filter {$0.action == .stitch}.map(\.point)
    XCTAssertGreaterThan(points.count,35);XCTAssertLessThan(points.map(\.y).min()!,-7)
    XCTAssertGreaterThan(points.map(\.y).max()!,0)
    try program.validate()
  }
  func testPreflightRejectsHoopOverflowMissingHiddenSourceAndSampleBudget()throws {
    let (p,patch,_,_,_)=try fixture()
    var design=patch.textile!.embroidery!;design.hoopWidth=20;design.hoopHeight=20
    XCTAssertThrowsError(try EmbroideryDigitizer.generate(object:patch,project:p,design:design))
    design=patch.textile!.embroidery!;design.maximumStitches=10
    XCTAssertThrowsError(try EmbroideryDigitizer.generate(object:patch,project:p,design:design))
    design=patch.textile!.embroidery!;design.regions[0].elementIDs=[UUID()]
    XCTAssertThrowsError(try EmbroideryDigitizer.generate(object:patch,project:p,design:design))
    var hidden=p;hidden.objects[0].artwork!.elements[0].hidden=true
    XCTAssertThrowsError(try EmbroideryDigitizer.generate(object:hidden.objects[0],project:hidden))
    design=patch.textile!.embroidery!;design.hoopWidth = .infinity
    XCTAssertThrowsError(try design.validate())
    design=patch.textile!.embroidery!;design.regions[0].spacing=0
    XCTAssertThrowsError(try design.validate())
  }
  func testSVGContainsPhysicalActualCommandsAndDSTControlRecords()throws {
    let (p,patch,_,_,_)=try fixture();let program=try EmbroideryDigitizer.generate(object:patch,project:p)
    let svg=try EmbroideryRenderer.svg(program),hidden=try EmbroideryRenderer.svg(program,showJumps:false)
    XCTAssertTrue(XMLParser(data:Data(svg.utf8)).parse())
    XCTAssertTrue(svg.contains("width=\"100.000mm\""));XCTAssertTrue(svg.contains("data-command=\"stitch\""))
    XCTAssertTrue(svg.contains("stroke-dasharray"));XCTAssertFalse(hidden.contains("data-command=\"jump\""))
    for color in program.design.threads.map(\.color) {XCTAssertTrue(svg.contains(color))}
    let dst=try EmbroideryDST.data(program)
    XCTAssertEqual((dst.count-512)%3,0);XCTAssertEqual(Array(dst.suffix(3)),[0,0,0xF3])
    XCTAssertEqual(dst.prefix(3),Data("LA:".utf8))
    XCTAssertTrue(String(decoding:dst.prefix(512),as:UTF8.self).contains("CO:  2"))
    if let folder=ProcessInfo.processInfo.environment["FORM_EMBROIDERY_PROOF_DIR"] {
      let url=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
      try dst.write(to:url.appendingPathComponent("orbital.dst"));try JSONEncoder.form.encode(program).write(to:url.appendingPathComponent("orbital.json"));try Data(svg.utf8).write(to:url.appendingPathComponent("orbital.svg"))
    }
  }
  func testSavedDigitizingSourcePersistsAsSchema25AndLeavesVectorWordsEditable()throws {
    let (p,patch,_,_,_)=try fixture()
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root);try repository.save(p)
    let loaded=try repository.load(p.id)
    XCTAssertEqual(loaded.schemaVersion,25);XCTAssertEqual(loaded.objects[0].textile,patch.textile)
    XCTAssertEqual(loaded.objects[0].artwork,patch.artwork)
    XCTAssertEqual(try EmbroideryDigitizer.generate(object:loaded.objects[0],project:loaded),try EmbroideryDigitizer.generate(object:patch,project:p))
  }
  func testNASAStudyDigitizesItsContainedRingOrbitAndEditableTextWithCorrectThreads()throws {
    let project=Samples.flightJacket(),patch=try XCTUnwrap(project.objects.first {$0.name=="Mission patch / standalone"})
    let design=try EmbroideryDigitizer.defaultDesign(object:patch,project:project)
    XCTAssertTrue(design.threads.contains {$0.color=="#DACDB3"})
    XCTAssertTrue(design.regions.contains {$0.method == .running});XCTAssertTrue(design.regions.contains {$0.method == .fill})
    let program=try EmbroideryDigitizer.generate(object:patch,project:project,design:design)
    XCTAssertGreaterThan(program.stitchCount,1000)
    XCTAssertEqual(Set(program.commands.compactMap(\.regionID)),Set(design.regions.map(\.id)))
    XCTAssertNotNil(project.objects.first {$0.id==patch.id}?.textile?.embroidery)
  }
}

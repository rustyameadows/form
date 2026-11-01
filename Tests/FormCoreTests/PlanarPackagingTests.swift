import Foundation
import XCTest
import FormCADModel
@testable import FormCore

final class PlanarPackagingTests:XCTestCase {
  private func source()->PlanarConstructionDefinition {
    .init(name:"Independent fitted sheets",parameters:[.init("span",10,8...15)],
      size:.init("3*span",10),stockThickness:1,panels:[
        .init(id:"base",name:"Base",polygon:[.init(0,0),.init("span",0),.init("span",10),.init(0,10)],
          cutouts:[.init(id:"window",polygon:[.init(4,4),.init(6,4),.init(6,6),.init(4,6)],kind:.window)]),
        .init(id:"lid",name:"Lid",polygon:[.init("2*span",0),.init("3*span",0),.init("3*span",10),.init("2*span",10)])],
      rootPanelID:"base",components:[
        .init(id:"base",name:"Base",rootPanelID:"base",anchor:.init(0,10)),
        .init(id:"lid",name:"Lid",rootPanelID:"lid",anchor:.init("2*span",10),position:.init(0,0,"5+opening/10"))],
      interiors:[.init(id:"cavity",name:"Usable cavity",componentID:"base",origin:.init(),size:.init("span",10,4),
        opening:.init(axis:.z,width:8,height:8,origin:.init(1,1)))])
  }
  private func paper(_ definition:PlanarConstructionDefinition)throws->PaperConstruction {
    var p=PaperConstruction(kind:.authored,dimensions:.init(width:10,height:10,depth:4),
      stock:.init(thicknessMM:try definition.number(definition.stockThickness)))
    p.authored=definition;return p
  }
  func testIndependentRootsRetainFlatCoordinatesAndOnlyOpeningComponentMoves()throws {
    let d=source(),p=try paper(d),net=try d.net()
    XCTAssertEqual(d.version,3);XCTAssertEqual(net.panels.count,2);XCTAssertTrue(net.folds.isEmpty)
    let closed=try p.resolvedPanels();var opened=p;opened.openingPercent=100
    let open=try opened.resolvedPanels()
    XCTAssertEqual(closed[0],open[0]);XCTAssertEqual(open[1].flatToWorld[11]-closed[1].flatToWorld[11],10,accuracy:1e-10)
    XCTAssertEqual(try opened.net(),net)
    let flat=try p.resolvedPanels(foldPercent:0)
    for pose in flat {let matrix=pose.flatToWorld
      XCTAssertEqual(matrix[2],0,accuracy:1e-12);XCTAssertEqual(matrix[6],1,accuracy:1e-12)
    }
    XCTAssertEqual(flat[0].flatToWorld,flat[1].flatToWorld)
    var larger=d;try larger.setParameters(["span":12]);XCTAssertEqual(try larger.net().panels[0].bounds.width,12)
    XCTAssertEqual(try larger.net().panels[1].bounds.width,12)
  }
  func testPhysicalCutoutsHaveStableTechnicalEdgesAndInsideFrameMapping()throws {
    let d=source(),net=try d.net(),base=net.panels[0]
    XCTAssertFalse(base.containsMaterial(.init(5,5)));XCTAssertTrue(base.containsMaterial(.init(2,2)))
    let cuts=net.cutEdges.filter{$0.cutoutID=="window"}
    XCTAssertEqual(cuts.count,4);XCTAssertTrue(cuts.allSatisfy{$0.cutoutKind == .window})
    XCTAssertEqual(cuts.map(\.id),["base.cutout.window.0","base.cutout.window.1","base.cutout.window.2","base.cutout.window.3"])
    let frame=try PhysicalArtworkFrame.paper(net:net,panelID:"base",inside:true)
    XCTAssertEqual(frame.cutouts?.first,base.cutouts?.first?.polygon.map(frame.sourceToLocal.apply))
    var larger=d;try larger.setParameters(["span":12])
    XCTAssertEqual(try larger.net().cutEdges.filter{$0.cutoutID=="window"}.map(\.id),cuts.map(\.id))
  }
  func testMalformedRootsHolesAndOldSourceVersionReject()throws {
    var d=source();d.version=2;XCTAssertThrowsError(try d.net())
    d=source();d.components![1].rootPanelID="base";XCTAssertThrowsError(try d.net())
    d=source();d.components!.removeLast();XCTAssertThrowsError(try d.net())
    d=source();d.panels[0].cutouts![0].polygon=[.init(0,4),.init(2,4),.init(2,6),.init(0,6)]
    XCTAssertThrowsError(try d.net())
    d=source();d.panels[0].cutouts!.append(.init(id:"nested",polygon:[.init(4.2,4.2),.init(5.8,4.2),.init(5.8,5.8),.init(4.2,5.8)]))
    XCTAssertThrowsError(try d.net())
    d=source();d.components![0].anchor = .init(5,5);XCTAssertThrowsError(try d.net())
  }
  func testFitUsesActualOrientedCornersAndSeparatelyReportsOpening()throws {
    var p=try paper(source());p.authored!.interiors![0].rotationDegrees = .init(0,0,90)
    let i=try XCTUnwrap(PaperConstructionEngine.resolvedInteriors(p).first),target=UUID(),owner=UUID()
    func corners(_ low:Vector3,_ high:Vector3)->[Vector3] {
      [low.x,high.x].flatMap{x in [low.y,high.y].flatMap{y in [low.z,high.z].map{z in
        .init(i.origin.x+x*i.uAxis.x+y*i.vAxis.x+z*i.wAxis.x,
          i.origin.y+x*i.uAxis.y+y*i.vAxis.y+z*i.wAxis.y,
          i.origin.z+x*i.uAxis.z+y*i.vAxis.z+z*i.wAxis.z)
      }}}
    }
    let contents=PaperContentsBounds(objectID:target,revision:"actual-target-revision",corners:corners(.init(2,2,1),.init(7,7,3)))
    let good=try PaperConstructionEngine.fitContents(p,interiorID:"cavity",contents:contents,clearanceMM:0.5,sourceObjectID:owner,sourceRevision:"source-revision")
    XCTAssertTrue(good.passed);XCTAssertEqual(good.contentsObjectID,target);XCTAssertEqual(good.sourceObjectID,owner)
    XCTAssertEqual(good.contentsRevision,"actual-target-revision");XCTAssertEqual(good.minimum.x,2,accuracy:1e-10)
    var wide=contents;wide.corners=corners(.init(0.5,2,1),.init(9.5,7,3))
    let failed=try PaperConstructionEngine.fitContents(p,interiorID:"cavity",contents:wide,clearanceMM:0.25)
    XCTAssertTrue(failed.containmentPassed);XCTAssertEqual(failed.openingPassed,false);XCTAssertFalse(failed.passed)
    wide.corners=corners(.init(-1,2,1),.init(7,7,3))
    XCTAssertFalse(try PaperConstructionEngine.fitContents(p,interiorID:"cavity",contents:wide).containmentPassed)
    XCTAssertThrowsError(try PaperConstructionEngine.fitContents(p,interiorID:"unknown",contents:contents))
    XCTAssertNil(try p.preflight().usableInternalDimensions)
    XCTAssertThrowsError(try p.preflight(contents:.init(width:1,height:1,depth:1)))
  }
  func testAuthoredStockMetadataAndSourceCaliperCannotBeSilentlyRepaired()throws {
    var p=try paper(source());p.stock.gsm = -.infinity;XCTAssertThrowsError(try PaperConstructionEngine.validate(p))
    p=try paper(source());p.stock.thicknessMM=2
    var object=ProductObject(name:"Bad saved caliper",recipeID:"authored",parameters:[:]);object.paperConstruction=p
    XCTAssertThrowsError(try PaperConstruction.definition(for:object))
    p=try paper(source());p.stock.sheetSizeMM = .init(1,2);XCTAssertThrowsError(try PaperConstructionEngine.validate(p))
  }
  func testFourteenPackagingSourcesAndSeparateLinerCreateEditUndoAndReopen()throws {
    let repoURL=FileManager.default.temporaryDirectory.appendingPathComponent("packaging-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:repoURL)}
    let engine=OperationEngine(repository:try ProjectRepository(root:repoURL));engine.project=Project(name:"Packaging source tests")
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("examples/paper-packaging")
    let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}.sorted{$0.path<$1.path}
    XCTAssertEqual(files.count,15)
    let primary=files.filter{!$0.lastPathComponent.contains("liner-component")}
    XCTAssertEqual(Set(primary.map{String($0.lastPathComponent.prefix(2))}),Set((1...14).map{String(format:"%02d",$0)}))
    XCTAssertEqual(files.filter{$0.lastPathComponent=="07-liner-component.json"}.count,1)
    for file in files {
      let data=try Data(contentsOf:file),definition=try JSONDecoder.form.decode(PlanarConstructionDefinition.self,from:data)
      let net=try definition.net();XCTAssertFalse(net.panels.isEmpty,file.lastPathComponent)
      let raw=try JSONSerialization.jsonObject(with:data)
      let response=try XCTUnwrap(engine.call("form_construction",arguments:["command":"create","definition":raw]) as? [String:Any])
      let id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(response["object_id"] as? String)))
      let object=try XCTUnwrap(engine.project!.objects.first{$0.id==id}),before=object
      for opening in [0.0,50,100] {var paper=try PaperConstruction.definition(for:object);paper.openingPercent=opening
        XCTAssertEqual(try paper.resolvedPanels().count,net.panels.count,file.lastPathComponent)
      }
      let width=try XCTUnwrap(definition.values["width"])
      _ = try engine.call("form_construction",arguments:["command":"parameter","object_id":id.uuidString,"values":["width":width*1.05]])
      let changed=try XCTUnwrap(engine.project!.objects.first{$0.id==id});XCTAssertNotEqual(changed.paperConstruction?.authored,before.paperConstruction?.authored)
      XCTAssertEqual(try PaperConstruction.definition(for:changed).net().panels.map(\.id),net.panels.map(\.id))
      engine.undo();XCTAssertEqual(engine.project!.objects.first{$0.id==id},before)
    }
    try engine.flush();let saved=try engine.repository.load(engine.project!.id)
    XCTAssertEqual(saved.objects,engine.project!.objects);XCTAssertGreaterThanOrEqual(saved.schemaVersion,57)
  }
}

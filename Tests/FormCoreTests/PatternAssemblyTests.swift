import Foundation
import XCTest
@testable import FormCore

final class PatternAssemblyTests:XCTestCase {
  private func fixture()throws -> (Project,PatternAssemblyDefinition) {try PatternAssemblySamples.roundedPouch()}
  func testPreparedSourceRetainsOriginalCurvesAndGuardsEverySeamEndpoint()throws {
    let template=try SewingPatternTemplates.roundedPouch();var p=Project(name:"Source identities"),source=try p.makeObject(recipeID:"artboard")
    source.artwork=template.artwork;p.objects=[source]
    let main=source.artwork!.elements[0],facing=source.artwork!.elements[1]
    try PatternAssemblySource.prepare(in:&p,objectID:source.id,elements:[main.id,facing.id])
    let art=p.objects[0].artwork!
    XCTAssertEqual(art.elements[0].path,main.path);XCTAssertEqual(art.elements[1].width,facing.width);XCTAssertEqual(art.elements[1].height,facing.height)
    XCTAssertEqual(art.elements[1].kind,"path");XCTAssertTrue(art.sewingSeams!.allSatisfy{$0.first.edgeID != nil && $0.first.endID != nil && $0.second.edgeID != nil && $0.second.endID != nil})
    try p.validateArtworkLinks();let before=p
    try PatternAssemblySource.prepare(in:&p,objectID:source.id,elements:[main.id,facing.id]);XCTAssertEqual(p,before)
  }
  func testCurvedPouchProducesFourRealPanelsPhysicalMassAndExactSourceSeamSamples()throws {
    let (p,definition)=try fixture(),product=try PatternAssemblyGenerator.generate(definition,in:p),mesh=product.study.mesh
    XCTAssertEqual(product.panels.count,4);XCTAssertEqual(Set(mesh.panelIDs!),[0,1,2,3]);XCTAssertLessThanOrEqual(mesh.restPositionsMm.count,4096);XCTAssertLessThanOrEqual(mesh.triangles.count,8192)
    let expected=product.panels.reduce(0){$0+$1.meshAreaMm2*$1.densityGSM*1e-9}
    XCTAssertEqual(mesh.massesKg.reduce(0,+),expected,accuracy:1e-12);XCTAssertTrue(mesh.massesKg.allSatisfy{$0>0})
    XCTAssertGreaterThan(product.seamSamples.count,30);XCTAssertEqual(product.sourceDigest.count,64);XCTAssertLessThan(product.operations,definition.maximumMeshingOperations)
    let art=p.objects[0].artwork!
    for sample in product.seamSamples {
      let seam=art.sewingSeams!.first{$0.id==sample.seamID}!,firstPanel=product.panels.first{$0.id == .init(elementID:seam.first.elementID,copy:seam.first.copy)}!,secondPanel=product.panels.first{$0.id == .init(elementID:seam.second.elementID,copy:seam.second.copy)}!
      for (end,panel,index,fraction) in [(seam.first,firstPanel,sample.firstVertex,sample.firstFraction),(seam.second,secondPanel,sample.secondVertex,sample.secondFraction)] {
        let source=art.elements.first{$0.id==end.elementID}!,edge=try SewingCurves.boundaries(source,in:art).flatMap(\.edges).first{$0.id==end.edgeID}!,point=edge.sample(fraction:fraction).point,actual=product.materialPointsMm[index]
        XCTAssertEqual(actual.x+panel.sourceOriginMm.x,point.x,accuracy:1e-7);XCTAssertEqual(actual.y+panel.sourceOriginMm.y,point.y,accuracy:1e-7)
      }
    }
    if let directory=ProcessInfo.processInfo.environment["FORM_ASSEMBLY_PROOF_DIR"] {
      let root=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
      let report:[String:Any]=["definition":try jsonObject(definition),"study":try jsonObject(product.study),"material_points_mm":try jsonObject(product.materialPointsMm),"seam_samples":try jsonObject(product.seamSamples),"source_digest":product.sourceDigest,"source_artwork":try jsonObject(art),"panel_records":try jsonObject(product.panels),"operations":product.operations,"panels":product.panels.map{["name":$0.name,"copy":$0.id.copy,"vertices":$0.vertexIndices.count,"source_area_mm2":$0.sourceAreaMm2,"mesh_area_mm2":$0.meshAreaMm2] as [String:Any]}]
      try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("rounded-pouch-assembly.json"))
    }
  }
  func testSourceSeamDirectionChangesRealCorrespondenceAndDigest()throws {
    var (p,definition)=try fixture();let a=try PatternAssemblyGenerator.generate(definition,in:p),id=definition.seamIDs[0],index=p.objects[0].artwork!.sewingSeams!.firstIndex{$0.id==id}!
    p.objects[0].artwork!.sewingSeams![index].reversed.toggle()
    let b=try PatternAssemblyGenerator.generate(definition,in:p),first=a.seamSamples.first{$0.seamID==id}!,second=b.seamSamples.first{$0.seamID==id}!
    XCTAssertEqual(first.firstFraction,0);XCTAssertEqual(first.secondFraction,1);XCTAssertEqual(second.secondFraction,0)
    XCTAssertNotEqual(first.secondVertex,second.secondVertex);XCTAssertNotEqual(a.sourceDigest,b.sourceDigest)
    definition.seamIDs=[UUID()];XCTAssertThrowsError(try PatternAssemblyGenerator.generate(definition,in:p))
  }
  func testUnequalPhysicalSeamsAndChangedOriginalEdgesFailWithoutMutatingSource()throws {
    var (p,definition)=try fixture();let before=p
    p.objects[0].artwork!.elements[1].width+=20
    XCTAssertThrowsError(try PatternAssemblyGenerator.generate(definition,in:p));XCTAssertEqual(p.objects[0].artwork!.elements[1].width,before.objects[0].artwork!.elements[1].width+20)
    p=before;p.objects[0].artwork!.elements[0].path!.contours[0].nodes[0].id=UUID()
    XCTAssertThrowsError(try PatternAssemblyGenerator.generate(definition,in:p))
    p=before;definition.panels[0].densityGSM=0;XCTAssertThrowsError(try PatternAssemblyGenerator.generate(definition,in:p))
  }
  func testSolverClosesActualCurvedPerimeterAndKeepsDeclaredOpeningPins()throws {
    let (p,definition)=try fixture(),product=try PatternAssemblyGenerator.generate(definition,in:p)
    var solver=try ClothSolver(mesh:product.study.mesh,settings:product.study.settings,colliders:product.study.colliders,preparation:product.study.preparation)
    let initial=solver.frame;XCTAssertEqual(initial.diagnostics.maximumSeamGapMm,60,accuracy:1e-7)
    try solver.start();try finishAssemblyPreparation(&solver);for _ in 0..<60 {try solver.advance()}
    XCTAssertLessThan(solver.diagnostics.maximumSeamGapMm,3)
    for pin in product.study.mesh.pins {let current=solver.frame.positionsMm[pin.vertex];XCTAssertEqual(current.x,pin.targetMm.x,accuracy:1e-7);XCTAssertEqual(current.y,pin.targetMm.y,accuracy:1e-7);XCTAssertEqual(current.z,pin.targetMm.z,accuracy:1e-7)}
    XCTAssertGreaterThan(zip(initial.positionsMm,solver.frame.positionsMm).map{hypot($0.z-$1.z,$0.y-$1.y)}.max()!,20)
    XCTAssertEqual(solver.mesh.uv,product.study.mesh.uv);XCTAssertEqual(solver.mesh.triangles,product.study.mesh.triangles)
  }
  func testPhysicalAnchorResolvesAfterNewTessellationAndSourceEditHasOneUndo()throws {
    let (p,definition)=try fixture();var finer=definition;finer.maximumEdgeMm=18
    let a=try PatternAssemblyGenerator.generate(definition,in:p),b=try PatternAssemblyGenerator.generate(finer,in:p),main=p.objects[0].artwork!.elements[0]
    let anchor=PatternAssemblyAnchor(panel:.init(elementID:main.id,copy:1),materialPointMm:.init(130,80),normalOffsetMm:2)
    let fa=try ClothSolver(mesh:a.study.mesh,settings:a.study.settings,colliders:a.study.colliders,preparation:a.study.preparation).frame,fb=try ClothSolver(mesh:b.study.mesh,settings:b.study.settings,colliders:b.study.colliders,preparation:b.study.preparation).frame
    let pa=try anchor.placement(in:a,frame:fa),pb=try anchor.placement(in:b,frame:fb)
    XCTAssertEqual(pa.positionMm.x,pb.positionMm.x,accuracy:1e-7);XCTAssertEqual(pa.positionMm.y,pb.positionMm.y,accuracy:1e-7);XCTAssertEqual(pa.positionMm.z,pb.positionMm.z,accuracy:1e-7)
    XCTAssertThrowsError(try PatternAssemblyAnchor(panel:anchor.panel,materialPointMm:.init(-30,80)).resolve(in:a))
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=p
    try engine.edit("Changed matching original curves") {
      $0.objects[0].artwork!.elements[0].path!.contours[0].nodes[2].outgoing!.y+=3
      $0.objects[0].artwork!.elements[0].path!.contours[0].nodes[5].incoming!.y+=3
    }
    let changed=try PatternAssemblyGenerator.generate(definition,in:engine.project!)
    XCTAssertNotEqual(changed.sourceDigest,a.sourceDigest);XCTAssertEqual(engine.undoStack.count,1)
    engine.undo();XCTAssertEqual(engine.project,p);XCTAssertEqual(try PatternAssemblyGenerator.generate(definition,in:engine.project!).sourceDigest,a.sourceDigest)
  }
}

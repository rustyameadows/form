import Foundation
import XCTest
@testable import FormCore

final class ClothDocumentTests:XCTestCase {
  func testBothTemplatesDeclarePhysicalMassAndIndependentMaterialPanels()throws {
    var project=Project(name:"Cloth templates")
    XCTAssertEqual(project.minimumSchemaVersion,1)
    let sheet=try project.makeObject(recipeID:"clothPanel"),tote=try project.makeObject(recipeID:"clothTote")
    project.objects=[sheet,tote];try project.validateArtworkLinks();XCTAssertEqual(project.minimumSchemaVersion,31)
    XCTAssertEqual(sheet.cloth!.mesh.massesKg.reduce(0,+),0.32*0.30*0.220,accuracy:1e-12)
    XCTAssertEqual(tote.cloth!.mesh.massesKg.reduce(0,+),2*0.22*0.26*0.200,accuracy:1e-12)
    XCTAssertEqual(Set(tote.cloth!.mesh.panelIDs!),[0,1]);XCTAssertTrue(tote.cloth!.mesh.links.contains {$0.kind == .seam})
    XCTAssertNoThrow(try sheet.cloth!.validate());XCTAssertNoThrow(try tote.cloth!.validate())
    let names=MCP.tools.compactMap {$0["name"] as? String};XCTAssertTrue(names.contains("form_cloth"));XCTAssertEqual(names.count,Set(names).count)
  }
  func testPanelAnchorSurvivesResolutionChangeAndInvalidReplacementRollsBack()throws {
    var project=Project(name:"Mapped decoration")
    let source=try project.makeObject(recipeID:"clothTote",parameters:["resolution":6]),label=try project.makeObject(recipeID:"textileLabel")
    project.objects=[source,label]
    let uv=Point2(0.31,0.72),anchor=try source.cloth!.mesh.anchor(at:uv,panel:1,normalOffsetMm:2)
    project.objects[1].clothAttachment = .init(surfaceObjectID:source.id,anchor:anchor,rotationDegrees:17)
    let before=project
    var wider=source;wider.parameters["width"]=300;wider.parameters["resolution"]=12
    try project.setCloth(ClothDesign.definition(for:wider),for:source.id)
    let next=project.objects[1].clothAttachment!.anchor,mesh=project.objects[0].cloth!.mesh,point=try mesh.materialPoint(next)
    XCTAssertEqual(mesh.panelID(forTriangle:next.triangle),1);XCTAssertEqual(point.x,uv.x,accuracy:1e-8);XCTAssertEqual(point.y,uv.y,accuracy:1e-8)
    XCTAssertEqual(next.normalOffsetMm,2);XCTAssertEqual(project.objects[1].clothAttachment!.rotationDegrees,17)
    let accepted=project
    var invalid=project.objects[0].cloth!;invalid.mesh.panelIDs=[Int](repeating:0,count:invalid.mesh.restPositionsMm.count)
    XCTAssertThrowsError(try project.setCloth(invalid,for:source.id));XCTAssertEqual(project,accepted)
    XCTAssertThrowsError(try project.setCloth(nil,for:source.id));XCTAssertEqual(project,accepted);XCTAssertNotEqual(project,before)
  }
  func testInvalidOpenSurfaceSourcesCannotReplaceGarmentsOrCanvasWorkspaces()throws {
    var project=Project(name:"Supported cloth ownership")
    let garment=try project.makeObject(recipeID:"bomberJacket"),study=try project.makeObject(recipeID:"clothPanel").cloth!
    project.objects=[garment];let before=project
    XCTAssertThrowsError(try project.setCloth(study,for:garment.id));XCTAssertEqual(project,before)
    var missing=try project.makeObject(recipeID:"clothPanel");missing.cloth=nil;project.objects=[missing]
    XCTAssertThrowsError(try project.validateArtworkLinks())
  }
  func testPreparedNASAStudyContainsActualDrapeSeamsAndMaterialPointLabel()throws {
    let project=try Samples.make("clothLab");try project.validateArtworkLinks()
    for artwork in project.objects.compactMap(\.artwork) {try validateArtwork(artwork)}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("cloth-lab-source-\(UUID().uuidString)");defer {try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root),engine=OperationEngine(repository:repository)
    _ = try engine.call("form_create_project",arguments:["name":"Persisted cloth lab","template":"clothLab"])
    XCTAssertEqual(try repository.load(engine.project!.id).objects.count,3)
    XCTAssertEqual(project.schemaVersion,31);XCTAssertEqual(project.objects.filter {$0.cloth != nil}.count,2)
    XCTAssertEqual(project.objects.filter {$0.clothAttachment != nil}.count,1)
    XCTAssertTrue(project.objects.allSatisfy {$0.artwork != nil})
    for object in project.objects where object.cloth != nil {XCTAssertNoThrow(try object.cloth!.validate())}
    let label=project.objects.first {$0.clothAttachment != nil}!
    let placement=try XCTUnwrap(project.clothPlacement(label));XCTAssertTrue(placement.positionMm.x.isFinite)
  }

  func testPackagedWorkflowPanelSeamsCloseWithinDeclaredHalfSecondStudy()throws {
    let project=Project(name:"Seam workflow"),source=try project.makeObject(recipeID:"clothTote",parameters:["resolution":8]),study=source.cloth!
    var solver=try ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders);try solver.start();for _ in 0..<30 {try solver.advance(frames:1)}
    XCTAssertLessThan(solver.diagnostics.maximumSeamGapMm,2);XCTAssertLessThan(solver.diagnostics.maximumSurfacePenetrationMm,0.01)
    XCTAssertEqual(solver.elapsedSeconds,0.5,accuracy:1e-9)
  }

}

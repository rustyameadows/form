import Foundation
import XCTest
@testable import FormCore

final class ObjectPresentationTests:XCTestCase {
  func testTemplateOnlyAdditionRaisesSchemaAndSurvivesRepositoryReopen()throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("template-schema-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:directory)}
    let repository=try ProjectRepository(root:directory)
    var project=Project(name:"Legacy stock with retained template")
    var paper=try project.makeObject(recipeID:"paperEnvelope")
    project.objects=[paper]
    XCTAssertLessThan(project.minimumSchemaVersion,57)
    let hash=String(repeating:"a",count:64)
    let reference=PaperTemplateReference(originalAsset:"paper-template-"+hash+".svg",originalSHA256:hash,
      sourceName:"supplier.svg",instructions:"Return artwork separately.",sizeMM:.init(100,80),
      viewBox:.init(x:0,y:0,width:100,height:80),channels:[.init(elementID:"cut",kind:.cut)],
      interpretedGeometrySHA256:hash)
    try reference.validate();paper.paperTemplateReference=reference;project.objects=[paper]
    XCTAssertEqual(project.minimumSchemaVersion,57)
    try repository.save(project)
    let reopened=try repository.load(project.id)
    XCTAssertEqual(reopened.schemaVersion,57)
    XCTAssertEqual(reopened.objects.first?.paperTemplateReference,reference)
  }
  func testNewInsideSourceIsCanvasOnlyAndPersistsWithoutChangingLegacyArtboards()throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("source-presentation-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:directory)}
    let repository=try ProjectRepository(root:directory),engine=OperationEngine(repository:repository)
    var project=Project(name:"Canonical inside source")
    let paper=try project.makeObject(recipeID:"paperEnvelope"),legacy=try project.makeObject(recipeID:"artboard")
    project.objects=[paper,legacy];engine.project=project
    let response=try XCTUnwrap(engine.call("form_paper",arguments:["command":"ensure_inside","object_id":paper.id.uuidString]) as? [String:Any])
    let id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(response["inside_source_id"] as? String)))
    let created=try XCTUnwrap(engine.project!.objects.first{$0.id==id})
    XCTAssertEqual(created.canvasSourceOnly,true);XCTAssertFalse(created.hasTablePresentation)
    XCTAssertTrue(legacy.hasTablePresentation);XCTAssertNil(legacy.canvasSourceOnly)
    XCTAssertTrue(engine.project!.isIndependentFlatArtworkSource(created))
    XCTAssertEqual(engine.project!.physicalObjectCount,2);XCTAssertEqual(engine.undoStack.count,1)
    XCTAssertEqual(try StudioVisibility().resolved(in:engine.project!),[paper.id,legacy.id])
    XCTAssertThrowsError(try StudioVisibility(mode:.objects,objectIDs:[id]).resolved(in:engine.project!))
    engine.undo();XCTAssertEqual(engine.project!.objects,project.objects)
    engine.redo();XCTAssertEqual(engine.project!.objects.first{$0.id==id},created)
    try engine.edit("Canonical source text"){p in
      var art=try XCTUnwrap(p.objects.first{$0.id==id}?.artwork)
      art.elements=[.init(kind:"text",x:10,y:20,text:"Editable registered inside",fontSize:12)]
      try p.setArtwork(art,for:id)
    }
    XCTAssertEqual(engine.project!.objects.first{$0.id==paper.id}?.paperConstruction?.insideArtworkSourceID,id)
    try engine.flush();let reopened=try repository.load(project.id)
    XCTAssertEqual(reopened.objects,engine.project!.objects);XCTAssertEqual(reopened.physicalObjectCount,2)
    XCTAssertEqual(try repository.list().first{$0.id==project.id}?.objectCount,2)
    XCTAssertGreaterThanOrEqual(reopened.minimumSchemaVersion,57)
    let count=engine.undoStack.count
    _ = try engine.call("form_paper",arguments:["command":"ensure_inside","object_id":paper.id.uuidString])
    XCTAssertEqual(engine.undoStack.count,count)
  }
  func testExistingInsideAssociationRetainsItsOriginalVisibleSource()throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("legacy-source-presentation-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:directory)}
    let engine=OperationEngine(repository:try ProjectRepository(root:directory))
    var p=Project(name:"Historical inside association"),paper=try p.makeObject(recipeID:"paperEnvelope")
    var inside=try p.makeObject(recipeID:"artboard")
    inside.artwork = .init(elements:[.init(kind:"text",x:2,y:3,text:"Existing source")])
    paper.paperConstruction!.insideArtworkSourceID=inside.id;p.objects=[paper,inside];engine.project=p
    _ = try engine.call("form_paper",arguments:["command":"ensure_inside","object_id":paper.id.uuidString])
    XCTAssertEqual(engine.project!.objects,p.objects);XCTAssertTrue(engine.undoStack.isEmpty)
    XCTAssertTrue(inside.hasTablePresentation);XCTAssertEqual(p.physicalObjectCount,2)
  }
}

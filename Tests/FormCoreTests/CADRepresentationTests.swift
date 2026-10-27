import XCTest
import FormCADModel
@testable import FormCore

final class CADRepresentationTests:XCTestCase {
  private func fixture()throws->(Project,ProductObject) {
    var project=Project(name:"Exact persistence")
    let feature=CADFeatureNode(name:"Box",operation:.init(.box,values:["width":80,"height":50,"depth":20]))
    let model=CADModelDefinition(name:"Box",features:[feature],outputs:[feature.id])
    let hash=String(repeating:"a",count:64)
    let component=CADComponentRepresentation(id:feature.id,name:"Body",brepAsset:"body.brep",brepSHA256:hash,meshAsset:"body.cadmesh",meshSHA256:hash,minimum:.init(-40,0,-10),maximum:.init(40,50,10),volumeMM3:80000,valid:true,closed:true,solidCount:1,faceCount:6,edgeCount:12,vertexCount:8,triangleCount:12)
    var object=try project.makeObject(recipeID:"cadModel",name:"Box")
    object.cadModel=model;object.cadRepresentation = .init(modelID:model.id,definitionSHA256:try CADRepresentation.definitionHash(model),kernelVersion:"8.0.1",components:[component])
    project.objects=[object];return(project,object)
  }
  func testExactMetadataRoundTripsAndOnlyNewRepresentationsRequireSchema52()throws {
    let(project,object)=try fixture();try project.validateArtworkLinks()
    XCTAssertEqual(project.minimumSchemaVersion,52)
    XCTAssertEqual(object.footprintWidth,80);XCTAssertEqual(object.footprintDepth,20)
    let decoded=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(project))
    XCTAssertEqual(decoded.objects,project.objects)
    XCTAssertEqual(try JSONEncoder.form.encode(decoded),try JSONEncoder.form.encode(project))
    let legacy=Project(name:"Legacy");XCTAssertLessThan(legacy.minimumSchemaVersion,52)
  }
  func testMalformedOrStaleRepresentationNeverPublishesAsExactSolid()throws {
    let(project,_)=try fixture()
    var changed=project;changed.objects[0].cadModel!.name="Stale definition"
    XCTAssertThrowsError(try changed.validateArtworkLinks())
    changed=project;changed.objects[0].cadRepresentation!.components[0].brepAsset="../source.brep"
    XCTAssertThrowsError(try changed.validateArtworkLinks())
    changed=project;changed.objects[0].cadRepresentation!.components[0].closed=false
    XCTAssertThrowsError(try changed.validateArtworkLinks())
    changed=project;changed.objects[0].cadRepresentation!.components[0].id=UUID()
    XCTAssertThrowsError(try changed.validateArtworkLinks())
    changed=project;changed.objects[0].cadRepresentation!.components[0].minimum.x = .nan
    XCTAssertThrowsError(try changed.validateArtworkLinks())
  }
  func testIndependentCADIterationGetsNewModelIdentityAndRetainsExactResources()throws {
    let(project,object)=try fixture(),folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:folder)}
    let engine=OperationEngine(repository:try ProjectRepository(root:folder));engine.project=project
    _=try engine.call("form_duplicate_object",arguments:["object_id":object.id.uuidString,"mode":"iteration"])
    let next=try XCTUnwrap(engine.project?.objects.last)
    XCTAssertNotEqual(next.cadModel?.id,object.cadModel?.id)
    XCTAssertEqual(next.cadModel?.id,next.cadRepresentation?.modelID)
    XCTAssertEqual(next.cadRepresentation?.components,object.cadRepresentation?.components)
    try engine.project!.validateArtworkLinks()
    _=try engine.call("form_undo");XCTAssertEqual(engine.project,project)
  }
  func testGenericAddCannotCreateAnEmptyExactOrImportedObject()throws {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:folder)}
    let engine=OperationEngine(repository:try ProjectRepository(root:folder));engine.project=Project(name:"Guarded")
    for recipe in ["cadModel","importedMesh"] {XCTAssertThrowsError(try engine.call("form_add_object",arguments:["recipe_id":recipe]))}
    XCTAssertTrue(engine.project!.objects.isEmpty);XCTAssertTrue(engine.undoStack.isEmpty)
  }
}

import Foundation
import XCTest
@testable import FormCore

final class ProjectReadTests:XCTestCase {
  private func engine()throws->OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("project-read-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let value=OperationEngine(repository:try ProjectRepository(root:root));value.project=Project(name:"Read contract");return value
  }
  private func dictionary(_ value:Any)throws->[String:Any] {try XCTUnwrap(value as? [String:Any])}
  private func size(_ value:Any)throws->Int {try JSONSerialization.data(withJSONObject:value).count}
  private func rows(_ response:[String:Any],_ section:String)throws->[[String:Any]] {
    try XCTUnwrap((response["sections"] as? [String:Any])?[section] as? [[String:Any]])
  }
  private func page(_ response:[String:Any],_ section:String)throws->[String:Any] {
    try XCTUnwrap((response["pages"] as? [String:Any])?[section] as? [String:Any])
  }
  private func denseProject()throws->Project {
    let width=64,height=62
    var points=[Vector3](),uv=[Point2](),triangles=[ClothTriangle](),links=[ClothLink]()
    for y in 0..<height {for x in 0..<width {
      points.append(.init(Double(x)/7,4*sin(Double(x)*0.017),Double(y)/11));uv.append(.init(Double(x)/Double(width-1),Double(y)/Double(height-1)))
      let i=y*width+x
      if x+1<width {links.append(.init(i,i+1,kind:.warp))}
      if y+1<height {links.append(.init(i,i+width,kind:.weft))}
      if x+1<width,y+1<height {
        triangles += [.init(i,i+width,i+1),.init(i+1,i+width,i+width+1)]
        links += [.init(i,i+width+1,kind:.shear),.init(i+1,i+width,kind:.shear)]
      }
      if x+2<width {links.append(.init(i,i+2,kind:.bendDistance))}
      if y+2<height {links.append(.init(i,i+width*2,kind:.bendDistance))}
    }}
    let mesh=ClothMesh(restPositionsMm:points,massesKg:Array(repeating:0.0001,count:points.count),triangles:triangles,uv:uv,links:links)
    try mesh.validate()
    var project=Project(name:"Dense editable surfaces")
    for index in 0..<14 {
      var object=try project.makeObject(recipeID:"clothPanel",name:"Surface \(index)")
      object.cloth = .init(mesh:mesh);object.position.x=Double(index)*200;project.objects.append(object)
    }
    return project
  }
  func testDefaultFullShapeAndSummaryReadDoNotMutateDocumentOrUndo()throws {
    let engine=try engine();var project=engine.project!
    var object=try project.makeObject(recipeID:"clothPanel",name:"Flexible surface")
    object.position = .init(12,34,56);project.objects=[object];project.notes=[.init("An authored decision")];project.conversationReference="authored-session-token";engine.project=project
    let generation=engine.projectGeneration
    let legacy=try dictionary(engine.call("form_get_project"))
    XCTAssertEqual(legacy as NSDictionary,try dictionary(jsonObject(project)) as NSDictionary)
    let summary=try dictionary(engine.call("form_get_project",arguments:["view":"summary"]))
    XCTAssertEqual((summary["project"] as? [String:Any])?["id"] as? String,project.id.uuidString)
    XCTAssertEqual((summary["project"] as? [String:Any])?["conversationReference"] as? String,project.conversationReference)
    XCTAssertEqual(summary["object_count"] as? Int,1);XCTAssertEqual(summary["response_complete"] as? Bool,false)
    let record=try XCTUnwrap(rows(summary,"objects").first)
    XCTAssertNil(record["cloth"]);XCTAssertTrue((record["available_detail_fields"] as? [String] ?? []).contains("cloth"))
    XCTAssertEqual(record["parameters"] as? [String:Double],object.parameters)
    XCTAssertEqual((record["position"] as? [String:Double])?["y"],34)
    XCTAssertEqual(try page(summary,"objects")["complete"] as? Bool,true)
    XCTAssertEqual(engine.projectGeneration,generation);XCTAssertTrue(engine.project==project);XCTAssertTrue(engine.undoStack.isEmpty)
    try engine.flush()
    let afterSave=try dictionary(engine.call("form_get_project",arguments:["view":"summary","expected_revision":try XCTUnwrap(summary["revision"] as? String)]))
    XCTAssertEqual(afterSave as NSDictionary,summary as NSDictionary,"A pure autosave preserves both revision and metadata across pages.")
    try engine.repository.save(project)
    // Repository persistence records the minimum schema required by the cloth
    // source. The hand-built in-memory fixture still has its initial schema.
    let persisted=try engine.repository.load(project.id)
    XCTAssertEqual(persisted.schemaVersion,project.minimumSchemaVersion)
    let expectedOpen=try dictionary(jsonObject(persisted))
    let reopened=try dictionary(engine.call("form_open_project",arguments:["project_id":project.id.uuidString]))
    XCTAssertTrue((reopened as NSDictionary)==(expectedOpen as NSDictionary),"Full open must return the exact legacy persisted Project shape.")
  }
  func testDenseFullFailureAndScopedPagesPreserveEveryCompleteObject()throws {
    let engine=try engine(),project=try denseProject();engine.project=project
    XCTAssertGreaterThan(try size(jsonObject(project)),ProjectReadCommands.bridgeByteLimit)
    XCTAssertThrowsError(try engine.call("form_get_project")) {error in
      XCTAssertTrue(error.localizedDescription.contains("view:summary"));XCTAssertTrue(error.localizedDescription.contains("object_ids"))
    }
    let summary=try dictionary(engine.call("form_get_project",arguments:["view":"summary"]))
    XCTAssertLessThan(try size(summary),128*1024)
    let revision=try XCTUnwrap(summary["revision"] as? String)
    var offset=0,received=[ProductObject](),pages=0
    repeat {
      let result=try dictionary(engine.call("form_get_project",arguments:["view":"scoped","sections":["objects"],"offset":offset,"limit":128,"expected_revision":revision]))
      XCTAssertLessThanOrEqual(try size(result),ProjectReadCommands.scopedByteLimit)
      let records=try rows(result,"objects"),info=try page(result,"objects")
      XCTAssertFalse(records.isEmpty);XCTAssertEqual(info["returned"] as? Int,records.count)
      XCTAssertEqual(info["total"] as? Int,project.objects.count);XCTAssertEqual(info["complete"] as? Bool,false)
      for record in records {received.append(try JSONDecoder.form.decode(ProductObject.self,from:JSONSerialization.data(withJSONObject:record)))}
      pages+=1;XCTAssertLessThanOrEqual(pages,project.objects.count)
      if let next=info["next_offset"] as? Int {XCTAssertGreaterThan(next,offset);offset=next} else {XCTAssertEqual(info["has_more"] as? Bool,false);break}
    } while pages<=project.objects.count
    XCTAssertTrue(received==project.objects,"Paged records must exactly reconstruct every original object without a partial-record substitution.");XCTAssertGreaterThan(pages,1)
    let one=try dictionary(engine.call("form_get_project",arguments:["view":"scoped","sections":["objects"],"object_ids":[project.objects[3].id.uuidString],"expected_revision":revision]))
    XCTAssertEqual(try rows(one,"objects").count,1);XCTAssertEqual(try page(one,"objects")["complete"] as? Bool,true)
  }
  func testIndependentSectionPagesFiltersAndRevisionGuards()throws {
    let engine=try engine();var project=engine.project!
    for index in 0..<5 {project.objects.append(try project.makeObject(recipeID:"box",name:"Solid \(index)"))}
    project.notes=[.init("First"),.init("Second"),.init("Third")];engine.project=project
    let response=try dictionary(engine.call("form_get_project",arguments:["view":"scoped","sections":["objects","notes","camera"],"offset":1,"limit":2]))
    XCTAssertEqual(try rows(response,"objects").map{$0["id"] as? String},Array(project.objects[1...2]).map{Optional($0.id.uuidString)})
    XCTAssertEqual(try page(response,"objects")["next_offset"] as? Int,3)
    XCTAssertEqual(try page(response,"notes")["has_more"] as? Bool,false)
    XCTAssertEqual(try page(response,"notes")["complete"] as? Bool,false,"A final page starting at1 is not the entire section.")
    XCTAssertEqual(try page(response,"camera")["complete"] as? Bool,true)
    let filtered=try dictionary(engine.call("form_get_project",arguments:["view":"summary","object_ids":[project.objects[4].id.uuidString,project.objects[1].id.uuidString]]))
    XCTAssertEqual(try rows(filtered,"objects").map{$0["id"] as? String},[project.objects[1].id,project.objects[4].id].map{Optional($0.uuidString)})
    let revision=try XCTUnwrap(response["revision"] as? String)
    try engine.edit("Move source"){$0.objects[0].position.x+=1}
    XCTAssertThrowsError(try engine.call("form_get_project",arguments:["view":"summary","expected_revision":revision]))
    engine.undo()
    XCTAssertThrowsError(try engine.call("form_get_project",arguments:["view":"summary","expected_revision":revision]))
    let other=try self.engine();other.project=project
    XCTAssertThrowsError(try other.call("form_get_project",arguments:["view":"summary","expected_revision":revision]))
    let beforeOpen=try dictionary(engine.call("form_get_project",arguments:["view":"summary"]))
    try engine.repository.save(engine.project!)
    _=try engine.call("form_open_project",arguments:["project_id":project.id.uuidString,"view":"summary"])
    XCTAssertThrowsError(try engine.call("form_get_project",arguments:["view":"summary","expected_revision":try XCTUnwrap(beforeOpen["revision"] as? String)]))
  }
  func testOpenPreflightsOversizeAndTargetSelectionBeforeSwitching()throws {
    let engine=try engine(),large=try denseProject();try engine.repository.save(large)
    let existing=try engine.project!.makeObject(recipeID:"box");engine.project?.objects=[existing];engine.selection=[existing.id]
    try engine.edit("Rename current"){$0.name="Current edited document"}
    let before=engine.project,undo=engine.undoStack,selection=engine.selection
    XCTAssertThrowsError(try engine.call("form_open_project",arguments:["project_id":large.id.uuidString]))
    XCTAssertThrowsError(try engine.call("form_open_project",arguments:["project_id":large.id.uuidString,"view":"scoped","sections":["objects"],"object_ids":[existing.id.uuidString]]))
    XCTAssertTrue(engine.project==before);XCTAssertTrue(engine.undoStack==undo);XCTAssertEqual(engine.selection,selection)
    let result=try dictionary(engine.call("form_open_project",arguments:["project_id":large.id.uuidString,"view":"summary"]))
    XCTAssertEqual(engine.project?.id,large.id);XCTAssertEqual((result["project"] as? [String:Any])?["id"] as? String,large.id.uuidString)
    XCTAssertEqual(result["object_count"] as? Int,large.objects.count);XCTAssertTrue(engine.undoStack.isEmpty)
  }
  func testMalformedScopesAndOversizedIndividualRecordsFailExplicitly()throws {
    let engine=try engine()
    let requests:[[String:Any]]=[
      ["view":"unknown"],["view":NSNull()],["view":"summary","offset":true],["view":"summary","limit":1.5],
      ["view":"summary","limit":129],["view":"summary","sections":["notes"]],
      ["view":"scoped"],["view":"scoped","sections":["unknown"]],["view":"scoped","sections":["notes","notes"]],
      ["view":"scoped","sections":["notes"],"object_ids":[UUID().uuidString]],
      ["view":"summary","object_ids":[UUID().uuidString]],["view":"summary","object_ids":[]],
      ["view":"full","offset":0],["view":"summary","offset":1],["view":"scoped","sections":["camera"],"offset":1],
      ["view":"summary","unexpected":true]]
    for arguments in requests {XCTAssertThrowsError(try engine.call("form_get_project",arguments:arguments),String(describing:arguments))}
    engine.project?.notes=[.init(String(repeating:"x",count:ProjectReadCommands.scopedByteLimit))]
    XCTAssertThrowsError(try engine.call("form_get_project",arguments:["view":"scoped","sections":["notes"]])) {error in
      XCTAssertTrue(error.localizedDescription.contains("4 MiB"));XCTAssertTrue(error.localizedDescription.contains("notes"))
    }
  }
  func testCompiledSchemasAdvertiseProjectionAndOpenDoesNotAcceptReadRevision()throws {
    for name in ["form_get_project","form_open_project"] {
      let tool=try XCTUnwrap(MCP.tools.first{$0["name"] as? String==name}),schema=try dictionary(tool["inputSchema"]!),properties=try dictionary(schema["properties"]!)
      for field in ["view","sections","object_ids","offset","limit"] {XCTAssertNotNil(properties[field])}
      XCTAssertEqual(properties["expected_revision"] != nil,name=="form_get_project")
    }
    let engine=try engine(),project=engine.project!;try engine.repository.save(project)
    XCTAssertThrowsError(try engine.call("form_open_project",arguments:["project_id":project.id.uuidString,"view":"summary","expected_revision":"stale"]))
  }
}

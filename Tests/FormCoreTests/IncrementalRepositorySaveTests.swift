import Foundation
import XCTest
@testable import FormCore

final class IncrementalRepositorySaveTests:XCTestCase {
  private func fixture()throws->(ProjectRepository,Project) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("incremental-save-"+UUID().uuidString)
    let repository=try ProjectRepository(root:root)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    var project=Project(name:"Immutable revisions")
    var first=try project.makeObject(recipeID:"box"),second=try project.makeObject(recipeID:"box")
    first.artwork = .init(elements:(0..<100).map{.init(kind:"rectangle",x:Double($0),y:0,width:10,height:10,color:"#28382F")})
    second.artwork = .init(elements:[.init(kind:"text",x:0,y:0,width:50,height:20,text:"Keep exact source")])
    project.objects=[first,second];project.schemaVersion=project.minimumSchemaVersion
    return (repository,project)
  }
  private func references(_ repository:ProjectRepository,_ id:UUID)throws->[[String:Any]] {
    let data=try Data(contentsOf:repository.url(for:id).appendingPathComponent("Manifest.json"))
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    return try XCTUnwrap(object["objects"] as? [[String:Any]])
  }
  private func persisted(_ project:Project)throws->Project {
    var project=project;project.schemaVersion=project.minimumSchemaVersion
    return try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(project))
  }

  func testUnchangedObjectsReuseImmutableReferencesAndOnlyAnEditedObjectIsEncoded()throws {
    let (repository,initial)=try fixture();var project=initial
    try repository.save(project)
    XCTAssertEqual(repository.lastSaveEncodedObjectCount,2);XCTAssertEqual(repository.lastSaveReusedObjectCount,0)
    let firstReferences=try references(repository,project.id)
    project.camera.azimuth+=0.5;project.name="Metadata update";project.updatedAt=Date()
    try repository.save(project)
    XCTAssertEqual(repository.lastSaveEncodedObjectCount,0);XCTAssertEqual(repository.lastSaveReusedObjectCount,2)
    XCTAssertEqual(try references(repository,project.id).map{$0["file"] as? String},firstReferences.map{$0["file"] as? String})
    XCTAssertEqual(try repository.load(project.id),try persisted(project))
    project.objects[0].artwork?.elements[17].color="#B65E3D"
    try repository.save(project)
    XCTAssertEqual(repository.lastSaveEncodedObjectCount,1);XCTAssertEqual(repository.lastSaveReusedObjectCount,1)
    let changedReferences=try references(repository,project.id)
    XCTAssertNotEqual(changedReferences[0]["file"] as? String,firstReferences[0]["file"] as? String)
    XCTAssertEqual(changedReferences[1]["file"] as? String,firstReferences[1]["file"] as? String)
    XCTAssertEqual(try repository.load(project.id),try persisted(project))
    project.objects.removeFirst();try repository.save(project)
    XCTAssertEqual(repository.lastSaveEncodedObjectCount,0);XCTAssertEqual(repository.lastSaveReusedObjectCount,1)
    XCTAssertEqual(try repository.load(project.id).objects,project.objects)
  }

  func testMissingImmutableRevisionIsRecreatedInsteadOfPublishingDanglingReference()throws {
    let (repository,project)=try fixture();try repository.save(project)
    let refs=try references(repository,project.id)
    let filename=try XCTUnwrap(refs[0]["file"] as? String)
    let path=repository.url(for:project.id).appendingPathComponent("Objects").appendingPathComponent(filename)
    let bytes=try Data(contentsOf:path);try FileManager.default.removeItem(at:path)
    try repository.save(project)
    XCTAssertEqual(repository.lastSaveEncodedObjectCount,1);XCTAssertEqual(repository.lastSaveReusedObjectCount,1)
    XCTAssertEqual(try Data(contentsOf:path),bytes)
    XCTAssertEqual(try repository.load(project.id),try persisted(project))
    try FileManager.default.removeItem(at:repository.url(for:project.id).appendingPathComponent("Objects"))
    try repository.save(project)
    XCTAssertEqual(repository.lastSaveEncodedObjectCount,2)
    XCTAssertEqual(try repository.load(project.id),try persisted(project))
  }

  func testFailedManifestPublicationKeepsLastSuccessfulCacheAndRetriesChangedObject()throws {
    let (repository,initial)=try fixture();try repository.save(initial);try repository.save(initial)
    let package=repository.url(for:initial.id),manifest=package.appendingPathComponent("Manifest.json")
    let previous=try Data(contentsOf:manifest),backup=package.appendingPathComponent("SavedManifest.json")
    try FileManager.default.moveItem(at:manifest,to:backup)
    try FileManager.default.createDirectory(at:manifest,withIntermediateDirectories:false)
    var changed=initial;changed.objects[0].color="#B65E3D"
    XCTAssertThrowsError(try repository.save(changed))
    XCTAssertEqual(repository.lastSaveEncodedObjectCount,0,"Only a successfully published save may replace the cache")
    XCTAssertEqual(try Data(contentsOf:backup),previous)
    try FileManager.default.removeItem(at:manifest);try FileManager.default.moveItem(at:backup,to:manifest)
    XCTAssertEqual(try repository.load(initial.id),try persisted(initial))
    try repository.save(changed)
    XCTAssertEqual(repository.lastSaveEncodedObjectCount,1,"Retry must not trust an unpublished cache snapshot")
    XCTAssertEqual(repository.lastSaveReusedObjectCount,1)
    XCTAssertEqual(try repository.load(changed.id),try persisted(changed))
  }

  func testValidationStillRunsForCachedObjectsAndProjectSwitchEvictsPriorSnapshot()throws {
    let (repository,initial)=try fixture();try repository.save(initial)
    let manifest=repository.url(for:initial.id).appendingPathComponent("Manifest.json"),before=try Data(contentsOf:manifest)
    var invalid=initial;invalid.objects[0].artworkSourceID=UUID()
    XCTAssertThrowsError(try repository.save(invalid));XCTAssertEqual(try Data(contentsOf:manifest),before)
    var second=initial;second.id=UUID();second.name="Another project"
    try repository.save(second)
    XCTAssertEqual(repository.lastSaveEncodedObjectCount,2);XCTAssertEqual(repository.lastSaveReusedObjectCount,0)
    XCTAssertEqual(try repository.load(second.id),try persisted(second))
    try repository.save(initial)
    XCTAssertEqual(repository.lastSaveEncodedObjectCount,2,"The cache retains one project snapshot, not an unbounded project history")
    XCTAssertEqual(try repository.load(initial.id),try persisted(initial))
  }
}

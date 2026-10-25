import Foundation
import XCTest
@testable import FormCore

final class ProjectContentTests:XCTestCase {
  func testWorkspaceIsNotAPhysicalObjectAndManifestKeepsCanvasSummaryWithoutOpeningObjects() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let repo = try ProjectRepository(root:root)
    var project = Project(name:"Canvas project")
    _ = try project.ensureCanvasWorkspace()
    let group = ArtworkElement(kind:"group",x:-200,y:-100,width:100,height:60)
    var child = ArtworkElement(kind:"rectangle",x:10,y:10,width:20,height:20)
    child.parentID = group.id
    var hidden = ArtworkElement(kind:"text",x:0,y:0,width:10,height:10,text:"Hidden source")
    hidden.hidden = true
    project.objects[0].artwork!.elements = [group,child,hidden]
    XCTAssertEqual(project.contentDescription,"0 objects · 1 Canvas item")
    try repo.save(project)
    let summary = try XCTUnwrap(repo.list().first)
    XCTAssertEqual(summary.objectCount,0); XCTAssertEqual(summary.canvasItemCount,1)
    XCTAssertEqual(summary.contentDescription,project.contentDescription)
    // New manifests hold a lightweight summary; Home need not parse every resource.
    try FileManager.default.removeItem(at:repo.url(for:project.id).appendingPathComponent("Objects"))
    XCTAssertEqual(try repo.list().first?.contentDescription,"0 objects · 1 Canvas item")
  }

  func testEarlySchemaNineteenSummaryReadsOldReferencesAndRetainsExactProjectContent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let repo = try ProjectRepository(root:root)
    var project = Project(name:"Early Canvas")
    _ = try project.ensureCanvasWorkspace()
    project.objects[0].artwork!.elements = [ArtworkElement(kind:"text",x:-50,y:-40,width:80,height:20,text:"A loose idea")]
    project.objects.append(try project.makeObject(recipeID:"box"))
    project.schemaVersion = project.minimumSchemaVersion
    try repo.save(project)
    let persisted = try repo.load(project.id)
    let manifest = repo.url(for:project.id).appendingPathComponent("Manifest.json")
    var value = try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [String:Any]
    value["objects"] = (value["objects"] as! [[String:Any]]).map { ref in
      ref.filter { !["canvasWorkspace","canvasItemCount"].contains($0.key) }
    }
    try JSONSerialization.data(withJSONObject:value).write(to:manifest)
    let summary = try XCTUnwrap(repo.list().first)
    XCTAssertEqual(summary.objectCount,1); XCTAssertEqual(summary.canvasItemCount,1)
    XCTAssertEqual(summary.contentDescription,"1 object · 1 Canvas item")
    XCTAssertEqual(try repo.load(project.id),persisted)
  }
}

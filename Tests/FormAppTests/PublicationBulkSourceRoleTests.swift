import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class PublicationBulkSourceRoleTests:XCTestCase {
  func testBulkCanvasSourcesKeepActualEditableCanvasFramesBeforeAndAfterPhysicalAssemblyAdmission()throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("bulk-source-canvas-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    defer{store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    var project=Project(name:"Canonical bulk pages")
    let publication=try PublicationCommands.createPublication(in:&project,name:"Physical run",pages:[])
    store.engine.project=project
    let result=try XCTUnwrap(store.engine.call("form_publication",arguments:["command":"create_pages","publication_id":publication.uuidString,
      "count":8,"width":148,"height":210,"canvas_source_only":true]) as? [String:Any])
    let ids=Set(try XCTUnwrap(result["page_ids"] as? [String]).compactMap(UUID.init(uuidString:)))
    let session=store.artworkSession,created=try XCTUnwrap(store.project)
    let frames=session.frames.filter{ids.contains($0.object.id)}
    XCTAssertEqual(Set(frames.map{$0.object.id}),ids)
    XCTAssertTrue(frames.allSatisfy{$0.editable && $0.projection==nil && !$0.isWorkspace})
    XCTAssertTrue(created.tablePresentationObjects.isEmpty,"Authoring pages must not transiently create eight independent Table meshes.")
    let definition=SheetAssemblyDefinition(publicationID:publication)
    _=try store.engine.call("form_publication",arguments:["command":"sheet_assembly_create","definition":try jsonObject(definition)])
    let assembled=try XCTUnwrap(store.project),assembly=try XCTUnwrap(assembled.objects.first{$0.sheetAssembly != nil})
    XCTAssertEqual(assembled.tablePresentationObjects.map(\.id),[assembly.id])
    XCTAssertEqual(Set(session.frames.filter{$0.projection==nil && ids.contains($0.object.id)}.map{$0.object.id}),ids)
    XCTAssertEqual(assembled.objects.filter{ids.contains($0.id)},created.objects)
    XCTAssertTrue(ids.isSubset(of:try assembled.resolvedSheetAssembly(assembly).sourceObjectIDs))
  }
}

import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class PublicationTrimControlsTests:XCTestCase {
  private func fixture()throws->(StudioStore,PublicationTrimTarget) {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-publication-trim-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    var project=Project(name:"Native whole document trim")
    let id=try PublicationCommands.createPublication(in:&project,name:"Captured source document",pages:[])
    _=try PublicationCommands.addPages(in:&project,publicationID:id,count:4,width:148,height:210)
    project.camera.azimuth=0.9;store.engine.project=project;store.showingHome=false
    addTeardownBlock{@MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return(store,.init(projectID:project.id,publicationID:id))
  }
  func testCompactNativeAxisControlsUseOneSharedTrimCommandAndCurrentOtherAxisWithExactUndo()throws {
    let(store,target)=try fixture(),session=store.artworkSession,before=try XCTUnwrap(store.project)
    let selected:Set<UUID>=[before.objects[0].id];store.engine.selection=selected
    XCTAssertTrue(try target.resize(using:session,width:150))
    XCTAssertTrue(try target.resize(using:session,height:215))
    let after=try XCTUnwrap(store.project)
    XCTAssertTrue(after.objects.allSatisfy{$0.artworkSize == .init(150,215)})
    XCTAssertEqual(after.objects.map(\.artwork),before.objects.map(\.artwork))
    XCTAssertEqual(after.publications,before.publications);XCTAssertEqual(after.camera,before.camera);XCTAssertEqual(store.engine.selection,selected)
    XCTAssertEqual(store.engine.undoStack.count,2)
    store.engine.undo();XCTAssertTrue(store.project!.objects.allSatisfy{$0.artworkSize == .init(150,210)})
    store.engine.undo();XCTAssertEqual(store.project,before)
    store.engine.redo();store.engine.redo();XCTAssertEqual(store.project,after)
  }
  func testCapturedProjectAndPublicationRejectStaleImportedContextAndInvalidBoundsWithoutWrites()throws {
    let(store,target)=try fixture(),before=try XCTUnwrap(store.project),session=store.artworkSession
    var imported=before;imported.id=UUID();store.engine.project=imported
    XCTAssertFalse(try target.resize(using:session,width:150));XCTAssertEqual(store.project,imported)
    store.engine.project=before
    XCTAssertThrowsError(try target.resize(using:session,height:19));XCTAssertEqual(store.project,before)
    let stale=PublicationTrimTarget(projectID:before.id,publicationID:UUID())
    XCTAssertFalse(try stale.resize(using:session,width:150));XCTAssertEqual(store.project,before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
}

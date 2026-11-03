import AppKit
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore

@MainActor final class PublicationNavigationTests:XCTestCase {
  private func fixture()throws->StudioStore {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("publication-navigation-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    let project=Project(name:"Navigation source")
    try store.repository.save(project);try store.engine.open(project.id);store.showingHome=false
    _=try XCTUnwrap(store.artworkSession.publicationWorkspace.create(name:"Reading order",pageCount:8))
    addTeardownBlock{@MainActor in store.closeDetachedCanvas();store.artworkSession.canvas?.finishText();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return store
  }
  func testDiscoverablePagesEntryClearsFindWithoutChangingSplitCameraSourceOrUndo()throws {
    let store=try fixture(),controller=store.artworkSession.publicationWorkspace
    let doc=try XCTUnwrap(controller.document),page=doc.pages[4].objectID
    controller.focusPage(page);controller.close()
    store.surfaceLayout = .split;store.splitDirection = .stacked;store.mode = .table;store.canvasFindVisible=true
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count,selection=store.engine.selection
    store.showPublicationPages()
    XCTAssertTrue(controller.isVisible);XCTAssertFalse(store.canvasFindVisible)
    XCTAssertEqual(controller.currentPageID,page);XCTAssertEqual(store.surfaceLayout,.split);XCTAssertEqual(store.splitDirection,.stacked)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.selection,selection);XCTAssertEqual(store.engine.undoStack.count,undo)
    store.togglePublicationPages();XCTAssertFalse(controller.isVisible)
    store.canvasFindVisible=true;store.togglePublicationPages();XCTAssertTrue(controller.isVisible);XCTAssertFalse(store.canvasFindVisible)
    XCTAssertEqual(controller.currentPageID,page);XCTAssertEqual(store.project,before)
  }
  func testPagesEntryLeavesStudioExplicitlyAndDoesNotCreateAnUnrelatedCanvas()throws {
    let store=try fixture(),before=try XCTUnwrap(store.project)
    store.showEnvironment(.studio);store.showPublicationPages()
    XCTAssertEqual(store.environment,.form);XCTAssertEqual(store.mode,.artwork)
    XCTAssertTrue(store.artworkSession.publicationWorkspace.isVisible)
    XCTAssertEqual(store.project,before);XCTAssertNil(store.project?.canvasWorkspace)
  }
  func testSettingsTargetsRailDocumentAfterSelectionMovesToAnotherPublication()throws {
    let store=try fixture(),controller=store.artworkSession.publicationWorkspace
    let first=try XCTUnwrap(controller.document)
    let second=try XCTUnwrap(controller.create(name:"Another document",pageCount:4))
    let foreign=try XCTUnwrap(store.project?.publications?.first{$0.id==second}).pages[0].objectID
    controller.open(first.id);store.artworkSession.activate(foreign)
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    XCTAssertNil(controller.currentPageID)
    controller.showSettings()
    XCTAssertEqual(controller.publicationID,first.id);XCTAssertEqual(controller.currentPageID,first.pages[0].objectID)
    XCTAssertEqual(store.artworkSession.currentPublication?.id,first.id)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
    store.mode = .table;store.surfaceLayout = .single
    XCTAssertFalse(store.publicationPagesAreShown)
    store.showPublicationPages();XCTAssertTrue(store.publicationPagesAreShown)
  }
  func testSettingsRevealsTheActualPublicationControlsInsideTheMountedInspector()throws {
    let store=try fixture(),session=store.artworkSession
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1200,height:820),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:ArtworkStudio(session:session).environmentObject(store))
    host.sizingOptions=[];window.contentView=host;host.frame=window.contentView!.bounds
    defer{session.canvas?.finishText();window.contentView=nil;window.close();session.canvas=nil}
    func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.1))
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    session.publicationWorkspace.showSettings()
    host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.2));host.layoutSubtreeIfNeeded()
    let field=try XCTUnwrap(descendants(host).compactMap{$0 as? NSTextField}.first{$0.placeholderString=="Publication name"})
    let scroll=try XCTUnwrap(field.enclosingScrollView),document=try XCTUnwrap(scroll.documentView)
    XCTAssertGreaterThan(scroll.documentVisibleRect.minY,0,"Settings must reveal the publication controls below general artwork controls")
    XCTAssertTrue(field.convert(field.bounds,to:document).intersects(scroll.documentVisibleRect),"The actual publication name field must be on screen")
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
  }
  func testPrintedLabelsAndCoverNamesResolveWithoutConfusingLogicalPageOrder() {
    var pages=(0..<8).map{_ in PublicationPage(objectID:UUID())}
    pages[0].label="Front cover";pages[1].label="Inside front cover";pages[2].numberOverride=1
    let doc=PublicationDocument(name:"Folio order",pages:pages,layout:.init(facingPages:true))
    XCTAssertEqual(PublicationNavigationPosition.resolve(" 3 ",in:doc),pages[4].objectID)
    XCTAssertEqual(PublicationNavigationPosition.resolve("front COVER",in:doc),pages[0].objectID)
    for invalid in ["", "missing", "0", "-1", String(Int.min), String(Int.max)] {XCTAssertNil(PublicationNavigationPosition.resolve(invalid,in:doc))}
    let first=PublicationNavigationPosition(document:doc,selectedPageID:pages[0].objectID,spreads:true)
    XCTAssertFalse(first.canNavigate(-1));XCTAssertTrue(first.canNavigate(1));XCTAssertEqual(first.title,"Front cover")
    let last=PublicationNavigationPosition(document:doc,selectedPageID:pages.last!.objectID,spreads:true)
    XCTAssertFalse(last.canNavigate(1));XCTAssertTrue(last.canNavigate(-1))
    let second=PublicationNavigationPosition(document:doc,selectedPageID:pages[2].objectID,spreads:true)
    XCTAssertEqual(second.title,"Inside front cover–1")
    XCTAssertEqual(PublicationNavigationPosition(document:doc,selectedPageID:nil,spreads:false).title,"Choose a page")
  }
}

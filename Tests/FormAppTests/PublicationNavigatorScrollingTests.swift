import AppKit
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore

@MainActor private struct MountedPublicationRail:View {
  @ObservedObject var session:ArtworkSession
  @ObservedObject var controller:PublicationWorkspaceController
  var body:some View {
    if controller.isVisible {PublicationNavigator(session:session,controller:controller,maxHeight:640)}
    else {Color.clear}
  }
}

@MainActor final class PublicationNavigatorScrollingTests:XCTestCase {
  func testFarSelectedThumbnailIsActuallyVisibleAfterNavigationLayoutChangesAndReopening52PageRail()async throws {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("publication-rail-scrolling-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    let project=Project(name:"Long native publication navigation")
    try store.repository.save(project);try store.engine.open(project.id);store.showingHome=false
    let session=store.artworkSession,controller=session.publicationWorkspace
    let publication=try XCTUnwrap(controller.create(name:"52 canonical pages",width:100,height:140,pageCount:52,facingPages:true,linkedBody:false))
    let document=try XCTUnwrap(controller.document),first=try XCTUnwrap(document.pages.first).objectID,target=document.pages[37].objectID
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count,tableSelection=store.engine.selection
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:260,height:680),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:MountedPublicationRail(session:session,controller:controller).environmentObject(store))
    host.sizingOptions=[];window.contentView=host;host.frame=window.contentView!.bounds
    defer{window.contentView=nil;window.close();session.canvas?.finishText();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    func tile(_ id:UUID)->PublicationPageNativeButton? {
      descendants(host).compactMap{$0 as? PublicationPageNativeButton}.first{$0.accessibilityIdentifier()=="publication-page-"+id.uuidString}
    }
    func waitForVisible(_ id:UUID,spreads:Bool,file:StaticString=#filePath,line:UInt=#line)async throws {
      var diagnostic="Selected lazy thumbnail was never realized"
      for _ in 0..<200 {
        host.layoutSubtreeIfNeeded()
        if let button=tile(id),let scroll=button.enclosingScrollView,let content=scroll.documentView {
          let box=button.convert(button.bounds,to:content),visible=scroll.documentVisibleRect
          diagnostic="Tile \(box), document visible \(visible), native bounds \(button.bounds)"
          let expectedWidth:CGFloat=spreads ? 92:174
          if !button.isHiddenOrHasHiddenAncestor,abs(button.bounds.width-expectedWidth)<1,
            box.width>0,box.height>0,!box.intersection(visible).isNull,
            box.intersection(visible).height>=box.height*0.9 {return}
        }
        try await Task.sleep(nanoseconds:10_000_000)
      }
      XCTFail("The actual selected page tile must be visible after rail navigation: \(diagnostic)",file:file,line:line)
    }
    try await waitForVisible(first,spreads:true)
    controller.focusPage(target)
    try await waitForVisible(target,spreads:true)
    XCTAssertEqual(controller.currentPageID,target);XCTAssertEqual(tile(target)?.accessibilityValue() as? String,"Selected")
    controller.showsSpreads=false
    try await waitForVisible(target,spreads:false)
    controller.showsSpreads=true
    try await waitForVisible(target,spreads:true)
    controller.close()
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded();if tile(target)==nil {break}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    XCTAssertNil(tile(target),"Closing the rail must unmount the navigator before testing its opening scroll")
    controller.open(publication)
    try await waitForVisible(target,spreads:true)
    XCTAssertEqual(controller.currentPageID,target)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo);XCTAssertEqual(store.engine.selection,tableSelection)
  }
}

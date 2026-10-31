import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

@MainActor private final class NavigationRowRebindState:ObservableObject {
  @Published var target=0
  @Published var enabled=true
  @Published var selected=true
  var actions:[Int]=[]
}
private struct NavigationRowRebindView:View {
  @ObservedObject var state:NavigationRowRebindState
  var body:some View {
    let target=state.target
    WorkspaceNavigationRow(title:"Target \(target)",subtitle:"Current navigation target",symbol:"cube.transparent",selected:state.selected,
      accessibilityLabel:"Navigate to target \(target)",identifier:"navigation-row-\(target)") {state.actions.append(target)}
      .disabled(!state.enabled)
  }
}

@MainActor final class TableObjectNavigatorTests:XCTestCase {
  @MainActor private final class Fixture {
    let directory:URL,store:StudioStore,workspaceID:UUID,elementID:UUID,first:UUID,second:UUID,tray:UUID,groupID:UUID
    init()throws {
      _ = NSApplication.shared
      directory=FileManager.default.temporaryDirectory.appendingPathComponent("table-object-navigator-"+UUID().uuidString)
      store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
      var project=Project(name:"One physical object inventory")
      let workspace=try project.ensureCanvasWorkspace(),element=ArtworkElement(kind:"rectangle",x:12,y:14,width:20,height:18)
      workspaceID=workspace.id;elementID=element.id;project.objects[0].artwork?.elements=[element]
      let group=UUID();groupID=group
      var a=try project.makeObject(recipeID:"box",name:"Café Clock");a.groupID=group
      var b=try project.makeObject(recipeID:"box",name:"Résumé Clock",position:.init(400,0,0));b.groupID=group;b.locked=true
      let c=try project.makeObject(recipeID:"box",name:"Crème Tray",position:.init(700,0,300))
      var source=try project.makeObject(recipeID:"artboard",name:"Private Café Source");source.canvasSourceOnly=true;source.artwork=Artwork()
      var card=try project.makeObject(recipeID:"artboard",name:"Visible Display Card");card.artwork=Artwork()
      first=a.id;second=b.id;tray=c.id;project.objects += [a,b,c,source,card];project.schemaVersion=project.minimumSchemaVersion
      store.engine.project=project;store.showingHome=false;store.environment = .form;store.mode = .table
      store.select(tray);store.tableInspectorVisible=false
      store.artworkSession.activate(workspaceID);store.artworkSession.choose([elementID]);store.artworkSession.zoom=2
    }
    func close() {store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
  }
  private func descendants(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(descendants)}
  private func accessibility(_ value:Any,depth:Int=0)->[any NSAccessibilityProtocol] {
    guard depth<30,let item=value as? any NSAccessibilityProtocol else{return []}
    return [item]+(item.accessibilityChildren() ?? []).flatMap{accessibility($0,depth:depth+1)}
  }
  private func button(_ root:NSView,_ label:String)throws->any NSAccessibilityProtocol {
    try XCTUnwrap(descendants(root).flatMap{accessibility($0)}.first {
      $0.accessibilityRole() == .button && ($0.accessibilityLabel()==label || $0.accessibilityTitle()==label)
    },"Missing navigator action: "+label)
  }
  private func settle(_ root:NSView) {
    root.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.05));root.layoutSubtreeIfNeeded()
  }
  private func mount(_ f:Fixture,maxHeight:CGFloat=360)->(NSWindow,NSView) {
    let host=NSHostingView(rootView:TableObjectNavigator(maxHeight:maxHeight).environmentObject(f.store).frame(width:220,height:maxHeight,alignment:.top).labInterface())
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:220,height:maxHeight),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil);settle(host)
    addTeardownBlock{@MainActor in window.makeFirstResponder(nil);window.contentView=nil;window.close()}
    return(window,host)
  }
  private func key(_ code:UInt16,_ window:NSWindow,characters:String="")throws {
    window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)))
  }
  private func assertCanvas(_ f:Fixture,file:StaticString=#filePath,line:UInt=#line) {
    XCTAssertEqual(f.store.artworkSession.objectID,f.workspaceID,file:file,line:line)
    XCTAssertEqual(f.store.artworkSession.activeFrameID,f.workspaceID,file:file,line:line)
    XCTAssertEqual(f.store.artworkSession.selection,[f.elementID],file:file,line:line)
    XCTAssertEqual(f.store.artworkSession.zoom,2,file:file,line:line)
  }
  private func assertNavigationPreservesAuthoring(_ f:Fixture,before:Project,file:StaticString=#filePath,line:UInt=#line)throws {
    let after=try XCTUnwrap(f.store.project,file:file,line:line)
    XCTAssertEqual(after.objects,before.objects,file:file,line:line);XCTAssertEqual(after.history,before.history,file:file,line:line)
    // An explicit jump changes the saved view pose; all other project fields
    // remain exact. Query and arrow-only checks below still compare full state.
    var authoring=after;authoring.camera=before.camera
    XCTAssertEqual(authoring,before,file:file,line:line);XCTAssertTrue(f.store.engine.undoStack.isEmpty,file:file,line:line)
  }

  func testInventoryUsesVisiblePhysicalObjectsAndSharedNormalizedMultiwordMatching()throws {
    let f=try Fixture();defer{f.close()}
    let before=try XCTUnwrap(f.store.project),items=TableNavigationInventory.items(in:before,isolated:[f.first])
    XCTAssertEqual(items.map(\.title),["Café Clock","Résumé Clock","Crème Tray","Visible Display Card"])
    XCTAssertEqual(items.first?.groupID,f.groupID);XCTAssertEqual(items.first?.groupCount,2)
    XCTAssertTrue(try XCTUnwrap(items.first).isVisible)
    let second=try XCTUnwrap(items.first{$0.id==f.second});XCTAssertFalse(second.isVisible);XCTAssertTrue(second.isLocked)
    XCTAssertTrue(second.subtitle.contains("Group 1"));XCTAssertTrue(second.subtitle.contains("Hidden by isolation"))
    XCTAssertEqual(TableNavigationInventory.items(in:before,query:"  CAFE\n  cLoCk ").map(\.id),[f.first])
    XCTAssertEqual(TableNavigationInventory.items(in:before,query:"REsume\tclock").map(\.id),[f.second])
    XCTAssertEqual(TableNavigationInventory.items(in:before,query:"   \n\t").map(\.id),items.map(\.id))
    XCTAssertTrue(TableNavigationInventory.items(in:before,query:"private").isEmpty)
    XCTAssertTrue(TableNavigationInventory.items(in:before,query:"missing name").isEmpty)
    XCTAssertTrue(TableNavigationInventory.items(in:nil).isEmpty)
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testNativeRowClickNavigatesAndRevealsIsolationWithoutOpeningInspectorOrChangingCanvas()throws {
    let f=try Fixture();defer{f.close()}
    f.store.isolated=[f.first]
    let before=try XCTUnwrap(f.store.project),(_,host)=mount(f)
    XCTAssertTrue(try button(host,"Navigate to Crème Tray").accessibilityPerformPress());settle(host)
    XCTAssertTrue(f.store.engine.selection.contains(f.tray));XCTAssertTrue(f.store.isolated.isEmpty)
    XCTAssertFalse(f.store.tableInspectorVisible);assertCanvas(f)
    try assertNavigationPreservesAuthoring(f,before:before)
  }

  func testNativeCmdFFocusTypingAndArrowsDoNotNavigateUntilReturn()throws {
    let f=try Fixture();defer{f.close()}
    let before=try XCTUnwrap(f.store.project),selection=f.store.engine.selection,(window,host)=mount(f)
    f.store.requestTableSearchFocus();settle(host)
    let editor=try XCTUnwrap(window.firstResponder as? NSTextView,"The request must focus the real search field editor.")
    editor.insertText("clock",replacementRange:.init(location:0,length:editor.string.utf16.count));settle(host)
    XCTAssertEqual(f.store.tableSearchQuery,"clock")
    XCTAssertEqual(f.store.engine.selection,selection);XCTAssertEqual(f.store.project,before)
    try key(125,window,characters:"\u{f701}");settle(host)
    XCTAssertEqual(f.store.engine.selection,selection,"Down highlights a result without selecting/focusing a product.")
    try key(126,window,characters:"\u{f700}");settle(host)
    try key(125,window,characters:"\u{f701}");settle(host)
    XCTAssertEqual(f.store.engine.selection,selection,"Up/Down remain local search navigation.")
    XCTAssertEqual(f.store.project,before);assertCanvas(f)
    try key(36,window,characters:"\r");settle(host)
    XCTAssertEqual(f.store.engine.selection,[f.second],"A named search result selects that physical object, not its entire group.")
    XCTAssertFalse(f.store.tableInspectorVisible);assertCanvas(f)
    XCTAssertNotEqual(f.store.project?.camera.target,before.camera.target,"Return should perform the explicit focus action.")
    try assertNavigationPreservesAuthoring(f,before:before)
  }

  func testNativeNamedGroupedRowSelectsOnlyThatObjectAndRetainsOpenInspector()throws {
    let f=try Fixture();defer{f.close()}
    f.store.tableSearchQuery="resume";f.store.tableInspectorVisible=true
    let before=try XCTUnwrap(f.store.project),(_,host)=mount(f)
    XCTAssertTrue(try button(host,"Navigate to Résumé Clock").accessibilityPerformPress());settle(host)
    XCTAssertEqual(f.store.engine.selection,[f.second]);XCTAssertFalse(f.store.engine.selection.contains(f.first))
    XCTAssertTrue(f.store.tableInspectorVisible);assertCanvas(f)
    try assertNavigationPreservesAuthoring(f,before:before)
  }

  func testNativeEscapeClearsThenClosesAndHeaderClosePreservesPersistentQuery()throws {
    let f=try Fixture();defer{f.close()}
    f.store.tableSearchQuery="clock"
    let before=try XCTUnwrap(f.store.project),selection=f.store.engine.selection,(window,host)=mount(f)
    f.store.requestTableSearchFocus();settle(host)
    XCTAssertTrue(window.firstResponder is NSTextView)
    try key(53,window,characters:"\u{1b}");settle(host)
    XCTAssertEqual(f.store.tableSearchQuery,"");XCTAssertTrue(f.store.tableNavigatorVisible)
    try key(53,window,characters:"\u{1b}");settle(host)
    XCTAssertFalse(f.store.tableNavigatorVisible)
    f.store.tableSearchQuery="Tray";f.store.requestTableSearchFocus();settle(host)
    XCTAssertTrue(try button(host,"Close Table objects").accessibilityPerformPress());settle(host)
    XCTAssertFalse(f.store.tableNavigatorVisible);XCTAssertEqual(f.store.tableSearchQuery,"Tray")
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.selection,selection);XCTAssertTrue(f.store.engine.undoStack.isEmpty);assertCanvas(f)
  }

  func testHeightHonorsAvailablePaneAndSearchDoesNotWriteHistoryWhenObjectsDisappear()throws {
    XCTAssertEqual(TableObjectNavigator.height(for:1000,maxHeight:900),360)
    XCTAssertEqual(TableObjectNavigator.height(for:1000,maxHeight:180),180)
    XCTAssertEqual(TableObjectNavigator.height(for:0,maxHeight:100),100)
    let f=try Fixture();defer{f.close()}
    let before=try XCTUnwrap(f.store.project),(_,host)=mount(f,maxHeight:180)
    f.store.tableSearchQuery="unmatched words";settle(host)
    XCTAssertTrue(TableNavigationInventory.items(in:f.store.project,query:f.store.tableSearchQuery).isEmpty)
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty);assertCanvas(f)
    XCTAssertLessThanOrEqual(host.fittingSize.width,220.1)
  }

  func testSharedNativeRowRebindsActionSelectionAndDisabledStateWithoutReplacingItsTarget()throws {
    _ = NSApplication.shared
    let state=NavigationRowRebindState(),host=NSHostingView(rootView:NavigationRowRebindView(state:state).frame(width:220,height:40))
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:220,height:40),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host
    defer{window.contentView=nil;window.close()}
    settle(host)
    let first=try XCTUnwrap(descendants(host).compactMap{$0 as? WorkspaceNavigationNativeButton}.first)
    XCTAssertEqual(first.bounds.height,40);XCTAssertEqual(first.accessibilityRole(),.button)
    XCTAssertEqual(first.accessibilityValue() as? String,"Selected")
    XCTAssertTrue(first.accessibilityPerformPress());XCTAssertEqual(state.actions,[0])
    state.target=1;state.selected=false;settle(host)
    let rebound=try XCTUnwrap(descendants(host).compactMap{$0 as? WorkspaceNavigationNativeButton}.first)
    XCTAssertTrue(first === rebound);XCTAssertEqual(rebound.accessibilityLabel(),"Navigate to target 1")
    XCTAssertEqual(rebound.accessibilityValue() as? String,"")
    XCTAssertTrue(rebound.accessibilityPerformPress());XCTAssertEqual(state.actions,[0,1])
    for x in [CGFloat(1),rebound.bounds.maxX-1] {for y in [CGFloat(1),39] {
      let point=rebound.convert(.init(x:x,y:y),to:nil),hit=host.hitTest(host.superview?.convert(point,from:nil) ?? point)
      XCTAssertTrue(hit === rebound,"Every row corner remains a real native button target.")
    }}
    state.enabled=false;settle(host)
    XCTAssertFalse(rebound.accessibilityPerformPress());XCTAssertEqual(state.actions,[0,1])
  }
}

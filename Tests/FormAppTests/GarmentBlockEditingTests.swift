import AppKit
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class GarmentBlockEditingTests:XCTestCase {
  private func fixture()throws->StudioStore {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("FontPreferences.json"))
    var project=Project(name:"Original measured garment block");let owner=try project.ensureCanvasWorkspace()
    store.engine.project=project;store.showingHome=false;store.mode = .artwork;store.artworkSession.objectID=owner.id
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    return store
  }
  private func fields(_ root:NSView)->[NSTextField] {([root as? NSTextField].compactMap{$0})+root.subviews.flatMap{fields($0)}}
  private func host(_ store:StudioStore,_ controller:GarmentBlockController)->(NSWindow,NSHostingView<AnyView>) {
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1180,height:850),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let view=NSHostingView(rootView:AnyView(GarmentBlockEditor(session:store.artworkSession,controller:controller).environmentObject(store)))
    view.sizingOptions=[];window.contentView=view;window.setContentSize(.init(width:1180,height:850));view.frame = .init(x:0,y:0,width:1180,height:850)
    window.orderBack(nil);view.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.1))
    return (window,view)
  }
  @discardableResult private func enter(_ text:String,_ name:String,window:NSWindow,view:NSView)throws->NSTextView {
    let field=try XCTUnwrap(fields(view).first{$0.isEditable && $0.placeholderString==name})
    window.makeFirstResponder(field);let editor=try XCTUnwrap(window.firstResponder as? NSTextView)
    editor.selectAll(nil);editor.insertText(text,replacementRange:.init(location:NSNotFound,length:0))
    RunLoop.main.run(until:Date().addingTimeInterval(0.15));return editor
  }
  private func pressPrimary(window:NSWindow,view:NSView)throws {
    view.layoutSubtreeIfNeeded()
    let point=NSPoint(x:view.bounds.maxX-100,y:view.isFlipped ? view.bounds.maxY-36:view.bounds.minY+36)
    let location=view.convert(point,to:nil),stamp=ProcessInfo.processInfo.systemUptime
    let down=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:stamp,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
    let up=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:stamp+0.02,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0))
    NSApp.postEvent(up,atStart:false);NSApp.sendEvent(down);NSApp.sendEvent(up)
    RunLoop.main.run(until:Date().addingTimeInterval(0.15))
  }
  func testRealNativeGenerateAndApplyCommitFocusedFieldsWithOneUndoAndAutosave() async throws {
    let store=try fixture(),before=store.project!,controller=GarmentBlockController(session:store.artworkSession)
    defer{store.engine.project=nil}
    let (window,view)=host(store,controller);defer{window.close()}
    XCTAssertEqual(store.project,before,"Opening and reviewing the proposal is read-only.")
    let preview=try XCTUnwrap(CGPDFDocument(CGDataProvider(data:try XCTUnwrap(controller.proof) as CFData)!))
    XCTAssertEqual(preview.numberOfPages,3,"The same-project size proposal has one physical vector page per size.")
    try enter("1000","Body fullest hip",window:window,view:view)
    try pressPrimary(window:window,view:view)
    XCTAssertEqual(store.engine.undoStack.count,1,controller.error)
    let block=try XCTUnwrap(store.project!.garmentBlocks?.first)
    XCTAssertEqual(block.body.hip,1000)
    XCTAssertTrue(store.saving)
    let deadline=Date().addingTimeInterval(4)
    while store.saving && Date()<deadline {try await Task.sleep(for:.milliseconds(20))}
    let loaded=try store.repository.load(before.id)
    XCTAssertEqual(loaded.garmentBlocks,store.project!.garmentBlocks)
    let generated=store.project!,count=store.engine.undoStack.count
    try enter("1040","Body fullest hip",window:window,view:view)
    try pressPrimary(window:window,view:view)
    XCTAssertEqual(store.project!.garmentBlocks![0].body.hip,1040,controller.error)
    XCTAssertEqual(store.engine.undoStack.count,count+1)
    store.engine.undo();XCTAssertEqual(store.project,generated)
    if let path=ProcessInfo.processInfo.environment["FORM_GARMENT_BLOCK_PROOF_DIR"] {
      let folder=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
      controller.select(controller.blockID);view.layoutSubtreeIfNeeded();try await Task.sleep(for:.milliseconds(100))
      try controller.proof?.write(to:folder.appendingPathComponent("native-three-size-review.pdf"))
      let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
      try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("native-garment-chart.png"))
    }
    store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testReadOnlyQueriesKeepActualActiveNativeDraftAndSelectionFocusExact() throws {
    let store=try fixture(),controller=GarmentBlockController(session:store.artworkSession)
    controller.refreshPreview();XCTAssertTrue(controller.apply("create"),controller.error)
    let (window,view)=host(store,controller);defer{window.close()}
    let editor=try enter("1037.5","Body fullest hip",window:window,view:view),range=editor.selectedRange()
    let baseline=store.project!,count=store.engine.undoStack.count,selection=store.artworkSession.selection
    for operation in ["list","get","report"] {
      let args:[String:Any]=["command":"garment_block","operation":operation,"block_id":controller.blockID!.uuidString,"object_id":controller.objectID!.uuidString]
      XCTAssertTrue(GarmentBlockCommands.isReadOnly(args),"The actual native bridge uses this predicate before finishing any field editing.")
      _=try store.engine.call("form_edit_artwork",arguments:args)
      controller.refreshContext()
      XCTAssertTrue(window.firstResponder === editor)
      XCTAssertEqual(editor.selectedRange(),range);XCTAssertEqual(controller.draft.values["hip"],"1037.5")
      XCTAssertEqual(store.project,baseline);XCTAssertEqual(store.engine.undoStack.count,count)
      XCTAssertEqual(store.artworkSession.selection,selection);XCTAssertFalse(controller.externalChange)
    }
  }
  func testInvalidActiveMeasurementsAndSourceConflictsRejectWithoutReplacingDraftOrSource() throws {
    let store=try fixture(),controller=GarmentBlockController(session:store.artworkSession)
    controller.refreshPreview();XCTAssertTrue(controller.apply("create"))
    let baseline=store.project!,count=store.engine.undoStack.count
    for value in ["nan","","-1","10000"] {
      controller.draft.values["hip"]=value;controller.refreshPreview()
      XCTAssertNil(controller.proof);XCTAssertFalse(controller.apply("update"))
      XCTAssertEqual(controller.draft.values["hip"],value);XCTAssertEqual(store.project,baseline)
      XCTAssertEqual(store.engine.undoStack.count,count)
    }
    controller.select(controller.blockID)
    var locked=store.project!;locked.objects[0].locked=true;store.engine.project=locked
    XCTAssertFalse(controller.apply("update"));XCTAssertEqual(store.project,locked)
    XCTAssertEqual(store.engine.undoStack.count,count)
    store.engine.project=baseline;controller.select(controller.blockID)
    var project=store.project!,art=project.canvasWorkspace!.artwork!
    let id=project.garmentBlocks![0].bindings[0].elementID,index=art.elements.firstIndex{$0.id==id}!
    art.elements[index].sewingPiece!.notes="Keep this hand-edited sewing intent."
    try project.setArtwork(art,for:controller.objectID!);store.engine.project=project
    controller.refreshContext();XCTAssertFalse(controller.conflicts.isEmpty)
    controller.draft.values["hip"]="1010"
    XCTAssertFalse(controller.apply("update"));XCTAssertEqual(store.project,project)
    XCTAssertTrue(controller.apply("create_revision"),controller.error)
    XCTAssertEqual(store.project!.canvasWorkspace!.artwork!.elements.first{$0.id==id},art.elements[index])
  }
  func testExternalChartChangesPreserveDirtyValuesUntilExplicitReloadAndDraftRebasePreservesResolvedSizes() throws {
    let store=try fixture(),controller=GarmentBlockController(session:store.artworkSession)
    controller.refreshPreview();XCTAssertTrue(controller.apply("create"))
    controller.draft.values["hip"]="1030"
    _=try store.engine.call("form_edit_artwork",arguments:["object_id":controller.objectID!.uuidString,"command":"garment_block","operation":"configure","block_id":controller.blockID!.uuidString,"block":["grade":["hip":45]]])
    let saved=store.project!;controller.refreshContext()
    XCTAssertTrue(controller.externalChange);XCTAssertEqual(controller.draft.values["hip"],"1030")
    XCTAssertFalse(controller.apply("update"));XCTAssertEqual(store.project,saved)
    store.engine.undo();controller.refreshContext()
    XCTAssertFalse(controller.externalChange);XCTAssertEqual(controller.draft.values["hip"],"1030")
    store.engine.redo();controller.refreshContext();XCTAssertTrue(controller.externalChange)
    controller.select(controller.blockID)
    let before=try controller.draft.block(),resolved=try before.sizes.map{try before.resolved($0)}
    controller.draft.rebase(before.sizes[0].id)
    let after=try controller.draft.block(),next=try after.sizes.map{try after.resolved($0)}
    XCTAssertEqual(resolved,next);XCTAssertEqual(store.project,saved)
    controller.draft.removeSize(before.sizes[1].id)
    XCTAssertTrue(controller.apply("configure"),controller.error)
    XCTAssertEqual(store.project!.objects,saved.objects)
  }
}

import AppKit
import SwiftUI
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class PublicationWorkspaceTests:XCTestCase {
  private func fixture()throws->(StudioStore,PublicationWorkspaceController) {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-publication-workspace-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.fontLibraryPreferences = .init(file:root.appendingPathComponent("Fonts.json"))
    var project=Project(name:"Independent publication workspace")
    var independent=try project.makeObject(recipeID:"artboard",name:"Independent source",parameters:["width":80,"depth":90])
    independent.artwork = .init(elements:[.init(kind:"text",x:4,y:8,width:70,height:25,text:"Keep this artwork",fontSize:12)])
    independent.artwork?.canvasPosition = .init(400,600)
    project.objects=[independent];project.camera.azimuth=0.91;project.camera.distance=17
    try store.repository.save(project);try store.engine.open(project.id);store.showingHome=false
    addTeardownBlock{@MainActor in store.artworkSession.canvas?.finishText();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return(store,store.artworkSession.publicationWorkspace)
  }
  private func create(_ controller:PublicationWorkspaceController,count:Int=4)throws->UUID {
    try XCTUnwrap(controller.create(name:"Native authored document",width:148,height:210,pageCount:count,columns:2,gutter:8,margins:.init(top:12,right:12,bottom:12,left:12),facingPages:true))
  }
  func testPublicViewNavigationOpensSameControllerAtChosenDocumentAndPageWithoutSourceEdits()throws {
    let(store,controller)=try fixture();let first=try create(controller),second=try XCTUnwrap(controller.create(name:"Second public document",pageCount:4))
    let project=try XCTUnwrap(store.project),target=try XCTUnwrap(project.publications?.first{$0.id==second}).pages[2].objectID
    let other=try XCTUnwrap(project.publications?.first{$0.id==first}).pages[0].objectID
    let tableSelection:Set<UUID>=[project.objects[0].id];store.engine.selection=tableSelection;store.splitDirection = .stacked
    let undo=store.engine.undoStack.count
    XCTAssertNil(project.canvasWorkspace)
    defer{store.closeDetachedCanvas()}
    for view in ["canvas","split","artwork","canvas_window"] {
      store.artworkSession.activate(other)
      let response=try XCTUnwrap(try store.engine.call("form_set_view",arguments:["view":view,"publication_id":second.uuidString,"object_id":target.uuidString]) as? [String:Any])
      XCTAssertTrue(store.artworkSession.publicationWorkspace === controller)
      XCTAssertEqual(controller.publicationID,second);XCTAssertEqual(controller.currentPageID,target);XCTAssertTrue(controller.isVisible)
      XCTAssertEqual(response["publication_id"] as? String,second.uuidString);XCTAssertEqual(response["object_id"] as? String,target.uuidString)
      XCTAssertEqual(response["navigator_visible"] as? Bool,true)
      XCTAssertEqual(store.project,project,"Opening existing pages must not create an unrelated Canvas workspace")
      XCTAssertEqual(store.project?.camera,project.camera);XCTAssertEqual(store.engine.undoStack.count,undo);XCTAssertEqual(store.engine.selection,tableSelection)
      XCTAssertEqual(store.splitDirection,.stacked)
    }
    store.closeDetachedCanvas();controller.close();store.artworkSession.activate(target)
    _=try store.engine.call("form_set_view",arguments:["view":"canvas","publication_id":second.uuidString])
    XCTAssertEqual(controller.currentPageID,target,"Omitting object_id retains the current page of the chosen document")
    store.artworkSession.activate(other)
    _=try store.engine.call("form_set_view",arguments:["view":"split","publication_id":second.uuidString])
    XCTAssertEqual(controller.currentPageID,project.publications!.first{$0.id==second}!.pages[0].objectID)
    XCTAssertEqual(store.project,project);XCTAssertEqual(store.engine.undoStack.count,undo)
  }
  func testInvalidPublicPublicationNavigationPreservesNativeMarkedDraftAndEveryViewState()throws {
    let(store,controller)=try fixture();let first=try create(controller),second=try XCTUnwrap(controller.create(name:"Other publication",pageCount:4))
    var empty:UUID?
    try store.engine.edit("Prepared empty publication"){project in empty=try PublicationCommands.createPublication(in:&project,name:"No pages yet",pages:[])}
    let session=store.artworkSession,document=try XCTUnwrap(store.project?.publications?.first{$0.id==first}),page=document.pages[0].objectID
    session.activate(page);store.surfaceLayout = .split;store.splitDirection = .stacked
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1000,height:800),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:window.contentView!.bounds);canvas.session=session;session.canvas=canvas;window.contentView=canvas;canvas.synchronize()
    defer{canvas.finishText();window.contentView=nil;window.close();session.canvas=nil}
    let source=try XCTUnwrap(store.project?.objects.first{$0.id==page}?.artwork?.elements.first{$0.storyFrame != nil})
    canvas.beginText(source);let editor=try XCTUnwrap(canvas.storyEditor),text=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    text.setMarkedText("に",selectedRange:.init(location:1,length:0),replacementRange:.init(location:NSNotFound,length:0))
    XCTAssertTrue(text.hasMarkedText())
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count,mode=store.mode,environment=store.environment,layout=store.surfaceLayout,home=store.showingHome
    let active=session.objectID,selection=session.selection,nodes=session.nodes,tableSelection=store.engine.selection,publication=controller.publicationID,visible=controller.isVisible
    let invalid:[[String:Any]]=[
      ["view":"canvas","publication_id":"not-a-uuid"],
      ["view":"split","publication_id":UUID().uuidString],
      ["view":"front","publication_id":first.uuidString],
      ["view":"studio","studio_command":"capture","publication_id":first.uuidString],
      ["view":"canvas","publication_id":first.uuidString,"object_id":37],
      ["view":"canvas","publication_id":first.uuidString,"object_id":UUID().uuidString],
      ["view":"canvas","publication_id":second.uuidString,"object_id":page.uuidString],
      ["view":"canvas_window","publication_id":empty!.uuidString],
      ["view":"artwork","publication_id":first.uuidString,"element_ids":[UUID().uuidString]],
      ["view":"canvas","publication_id":first.uuidString,"node_ids":[UUID().uuidString]]]
    for args in invalid {
      let view=args["view"] as! String
      XCTAssertThrowsError(try store.publicationViewRequest(view,args),"Bridge handoff must reject invalid navigation before finishing native text")
      XCTAssertThrowsError(try store.engine.call("form_set_view",arguments:args))
      XCTAssertTrue(canvas.storyEditor === editor);XCTAssertTrue(text.hasMarkedText());XCTAssertTrue(window.firstResponder === text)
      XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
      XCTAssertEqual(store.mode,mode);XCTAssertEqual(store.environment,environment);XCTAssertEqual(store.surfaceLayout,layout);XCTAssertEqual(store.splitDirection,.stacked);XCTAssertEqual(store.showingHome,home)
      XCTAssertEqual(session.objectID,active);XCTAssertEqual(session.selection,selection);XCTAssertEqual(session.nodes,nodes);XCTAssertEqual(store.engine.selection,tableSelection)
      XCTAssertEqual(controller.publicationID,publication);XCTAssertEqual(controller.isVisible,visible);XCTAssertNil(store.canvasWindowController)
    }
    text.unmarkText()
  }
  func testTwelvePageCreationIsOneUndoKeepsIndependentSourceAndReopensExact()throws {
    let(store,controller)=try fixture(),before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    let id=try create(controller,count:12),created=try XCTUnwrap(store.project),document=try XCTUnwrap(created.publications?.first{$0.id==id})
    XCTAssertEqual(document.pages.count,12);XCTAssertEqual(document.layout?.facingPages,true)
    XCTAssertEqual(created.textStories?.first?.frames.count,24)
    XCTAssertEqual(created.objects.first{$0.id==before.objects[0].id},before.objects[0]);XCTAssertEqual(created.camera,before.camera)
    XCTAssertEqual(store.engine.undoStack.count,undo+1)
    XCTAssertTrue(controller.isVisible);XCTAssertEqual(controller.publicationID,id)
    let sources=created.objects
    controller.showsSpreads=false;controller.showsSpreads=true;controller.close();controller.open(id)
    XCTAssertEqual(store.project?.objects,sources,"View-only page/spread navigation cannot rewrite Canvas positions or artwork")
    try store.engine.flush();let reopened=try store.repository.load(created.id)
    XCTAssertEqual(reopened.publications,created.publications);XCTAssertEqual(reopened.textStories,created.textStories);XCTAssertEqual(reopened.objects,created.objects)
    store.engine.undo();controller.reconcile();XCTAssertEqual(store.project,before)
    store.engine.redo();controller.reconcile();XCTAssertEqual(store.project?.objects,created.objects)
  }
  func testSecondPublicationCreationUsesCanonicalPlacementWhileFirstSpreadLensIsOpen()throws {
    let(store,controller)=try fixture();let first=try create(controller,count:12),before=try XCTUnwrap(store.project)
    let firstPages=try XCTUnwrap(before.publications?.first{$0.id==first}).pages
    let firstIDs=Set(firstPages.map(\.objectID))
    let canonicalRight=try XCTUnwrap(before.objects.filter{firstIDs.contains($0.id)}.map{object in object.artwork!.canvasPosition!.x+object.artworkSize.x}.max())
    XCTAssertTrue(controller.isVisible);XCTAssertTrue(controller.showsSpreads)
    let second=try XCTUnwrap(controller.create(name:"Second independent publication",pageCount:4)),created=try XCTUnwrap(store.project)
    let secondIDs=Set(try XCTUnwrap(created.publications?.first{$0.id==second}).pages.map(\.objectID))
    for object in created.objects where secondIDs.contains(object.id) {
      XCTAssertGreaterThan(object.artwork!.canvasPosition!.x,canonicalRight)
    }
    XCTAssertEqual(created.objects.filter{firstIDs.contains($0.id)},before.objects.filter{firstIDs.contains($0.id)})
    controller.close()
    let ordinary=store.artworkSession.frames
    let oldFrames=ordinary.filter{firstIDs.contains($0.object.id)},newFrames=ordinary.filter{secondIDs.contains($0.object.id)}
    XCTAssertEqual(oldFrames.count,12);XCTAssertEqual(newFrames.count,4)
    XCTAssertTrue(oldFrames.allSatisfy{old in newFrames.allSatisfy{!old.rect.intersects($0.rect)}})
    store.engine.undo();controller.reconcile();XCTAssertEqual(store.project,before)
  }
  func testRailLeavesLegacyCanvasLayoutExactUntilFacingPagesAreExplicit()throws {
    let(store,controller)=try fixture();let id=try create(controller)
    var document=try XCTUnwrap(store.project?.publications?.first{$0.id==id});document.layout=nil
    try store.engine.edit("Legacy layout"){try PublicationCommands.setPublication(in:&$0,document:document)}
    let before=try XCTUnwrap(store.project);controller.close();controller.open(id)
    for page in document.pages {XCTAssertNil(controller.frameRect(for:page.objectID,size:.init(width:148,height:210)))}
    XCTAssertEqual(store.project,before)
    XCTAssertTrue(controller.update(documentID:id,expectedProjectID:before.id){$0.layout = .init(facingPages:true)})
    let first=try XCTUnwrap(document.pages.first),second=document.pages[1],third=document.pages[2]
    let left=try XCTUnwrap(controller.frameRect(for:second.objectID,size:.init(width:148,height:210))),right=try XCTUnwrap(controller.frameRect(for:third.objectID,size:.init(width:148,height:210)))
    XCTAssertEqual(left.maxX,right.minX,accuracy:0.001);XCTAssertEqual(left.minY,right.minY)
    let firstFrame=try XCTUnwrap(controller.frameRect(for:first.objectID,size:.init(width:148,height:210)))
    XCTAssertGreaterThan(left.minY,firstFrame.maxY)
    XCTAssertEqual(store.project?.objects,before.objects)
  }
  func testDuplicateReorderAndRemovalKeepSingleStoryWordsAndExactUndo()throws {
    let(store,controller)=try fixture();let id=try create(controller)
    let storyID=try XCTUnwrap(store.project?.textStories?.first?.id)
    try store.engine.edit("Authored global words"){project in var source=project.textStories![0].sourceElement;source.text=String(repeating:"One source flows through these physical pages. ",count:30);try PublicationCommands.setSource(in:&project,storyID:storyID,source:source)}
    let before=try XCTUnwrap(store.project),story=before.textStories![0],first=before.publications![0].pages[0].objectID
    let copy=try XCTUnwrap(controller.duplicatePage(first)),duplicated=try XCTUnwrap(store.project)
    XCTAssertEqual(duplicated.textStories![0].text,story.text);XCTAssertEqual(duplicated.textStories![0].frames.count,story.frames.count+2)
    XCTAssertTrue(duplicated.objects.first{$0.id==copy}!.artwork!.elements.filter{$0.storyFrame != nil}.allSatisfy{$0.text.isEmpty})
    store.engine.undo();controller.reconcile();XCTAssertEqual(store.project,before)
    store.engine.redo();controller.reconcile();XCTAssertEqual(store.project?.objects,duplicated.objects)
    XCTAssertTrue(controller.movePage(copy,by:1));XCTAssertEqual(store.project!.textStories![0].text,story.text)
    let reordered=try XCTUnwrap(store.project),order=Dictionary(uniqueKeysWithValues:reordered.publications![0].pages.enumerated().map{($0.element.objectID,$0.offset)})
    XCTAssertEqual(reordered.textStories![0].frames.map{order[$0.objectID]!},reordered.textStories![0].frames.map{order[$0.objectID]!}.sorted())
    XCTAssertTrue(controller.removePage(copy));XCTAssertEqual(store.project!.textStories![0].text,story.text)
    XCTAssertTrue(store.project!.objects.contains{$0.id==copy},"Removing membership preserves the independently editable page")
    XCTAssertFalse(store.project!.publications!.first{$0.id==id}!.pages.contains{$0.objectID==copy})
    store.engine.undo();controller.reconcile();XCTAssertEqual(store.project,reordered)
  }
  func testNativeChapterTypingSharesGlobalStorageReflowsAndUndoesWithoutSourceCopies()throws {
    let(store,controller)=try fixture();_=try create(controller)
    let session=store.artworkSession
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1000,height:800),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let canvas=VectorCanvasView(frame:window.contentView!.bounds);canvas.session=session;session.canvas=canvas;window.contentView=canvas;canvas.synchronize()
    defer{canvas.finishText();window.contentView=nil;window.close();session.canvas=nil}
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    let chapter=try XCTUnwrap(controller.newChapter(name:"A new source chapter",openEditor:false)),created=try XCTUnwrap(store.project)
    XCTAssertEqual(store.engine.undoStack.count,undo+1);XCTAssertEqual(created.publications![0].pages.count,before.publications![0].pages.count+1)
    XCTAssertEqual(created.textStories!.count,before.textStories!.count+1)
    let frame=try XCTUnwrap(created.textStories!.first{$0.id==chapter}?.frames.first)
    let element=try XCTUnwrap(created.storyFrame(frame)?.element)
    canvas.beginText(element);let editor=try XCTUnwrap(canvas.storyEditor);editor.nativeUndo.groupsByEvent=false
    let text=try XCTUnwrap(window.firstResponder as? CanvasTextView)
    XCTAssertTrue(text.textStorage === editor.composition.storage)
    text.insertText("Words typed in the actual native publication editor.",replacementRange:.init(location:NSNotFound,length:0))
    XCTAssertEqual(store.project!.textStories!.first{$0.id==chapter}?.text,"Words typed in the actual native publication editor.")
    XCTAssertEqual(store.project!.objects,created.objects,"Pages retain empty references rather than displayed text copies")
    XCTAssertEqual(store.project!.textStories!.first{$0.id==before.textStories![0].id},before.textStories![0])
    editor.nativeUndo.undo();XCTAssertEqual(store.project!.textStories!.first{$0.id==chapter}?.text,"")
    canvas.finishText();store.engine.undo();controller.reconcile();XCTAssertEqual(store.project,before)
  }
  func testNativePageThumbnailHasRealHitTargetAndNavigatesWithoutChangingTableSelection()throws {
    let(store,controller)=try fixture();_=try create(controller)
    let document=try XCTUnwrap(controller.document),last=document.pages[1]
    let selected=store.project!.objects[0].id;store.engine.selection=[selected]
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:260,height:620),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:PublicationNavigator(session:store.artworkSession,controller:controller,maxHeight:600).environmentObject(store));host.sizingOptions=[];window.contentView=host;host.frame=window.contentView!.bounds
    defer{window.contentView=nil;window.close()}
    host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.05))
    func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    let button=try XCTUnwrap(descendants(host).compactMap{$0 as? PublicationPageNativeButton}.first{$0.accessibilityIdentifier()=="publication-page-"+last.objectID.uuidString})
    XCTAssertTrue(button.isEnabled)
    let point=button.superview!.convert(.init(x:button.bounds.midX,y:button.bounds.midY),from:button)
    XCTAssertTrue(button.hitTest(point) === button)
    XCTAssertTrue(button.accessibilityPerformPress())
    XCTAssertEqual(store.artworkSession.objectID,last.objectID);XCTAssertEqual(store.engine.selection,[selected])
    XCTAssertEqual(button.accessibilityRole(),.button)
  }
  func testMasterSourceReturnsToPublicationWithoutBecomingBodyStoryCapacity()throws {
    let(store,controller)=try fixture();let id=try create(controller),before=try XCTUnwrap(store.project)
    let master=try XCTUnwrap(controller.createMaster(documentID:id,expectedProjectID:before.id))
    let element=ArtworkElement(kind:"text",x:8,y:8,width:120,height:16,text:"{{page.number}} / {{chapter.title}}",fontSize:11)
    try store.engine.edit("Authored running furniture"){project in let index=project.objects.firstIndex{$0.id==master}!;project.objects[index].artwork!.elements.append(element)}
    store.artworkSession.activate(master);store.artworkSession.choose([element.id])
    XCTAssertEqual(store.artworkSession.currentPublication?.id,id)
    XCTAssertTrue(store.artworkSession.isPublicationMasterSource)
    XCTAssertNil(store.artworkSession.publicationStoryFrame,"A running header is master artwork, never linked body capacity")
    XCTAssertEqual(store.project?.textStories,before.textStories)
    XCTAssertEqual(controller.publicationID,id);XCTAssertNil(controller.currentPageID)
  }
  func testSharedMasterKeepsExplicitPublicationContextWithoutChangingSourcesOrTableSelection()throws {
    let(store,controller)=try fixture(),first=try create(controller)
    let source=try XCTUnwrap(controller.createMaster(documentID:first,expectedProjectID:store.project!.id))
    let second=try XCTUnwrap(controller.create(name:"Second document",pageCount:4))
    let element=ArtworkElement(kind:"text",x:8,y:8,width:120,height:16,text:"{{publication.name}}",fontSize:11)
    try store.engine.edit("Shared master source"){project in
      let index=project.objects.firstIndex{$0.id==source}!
      project.objects[index].artwork!.elements.append(element)
      var document=project.publications!.first{$0.id==second}!
      document.masters=[.init(name:"Shared running header",sourceObjectID:source)]
      try PublicationCommands.setPublication(in:&project,document:document)
    }
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    let tableSelection:Set<UUID>=[before.objects[0].id];store.engine.selection=tableSelection
    for id in [second,first,second] {
      XCTAssertTrue(controller.focusMaster(source,publicationID:id))
      store.artworkSession.choose([element.id])
      XCTAssertEqual(store.artworkSession.currentPublication?.id,id)
      XCTAssertEqual(controller.publicationID,id);XCTAssertNil(controller.currentPageID)
      XCTAssertNil(store.artworkSession.publicationStoryFrame)
      XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
      XCTAssertEqual(store.engine.selection,tableSelection)
    }
    XCTAssertFalse(controller.focusMaster(source,publicationID:UUID()))
    XCTAssertEqual(store.artworkSession.currentPublication?.id,second)
  }
  func testExplicitRailOpenFitsAfterMountedViewportInsetsAndClosingCancelsPendingFocus()async throws {
    let(store,controller)=try fixture();let id=try create(controller),session=store.artworkSession
    controller.close();store.mode = .artwork
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:1100,height:780),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:ArtworkStudio(session:session).environmentObject(store));window.contentView=host;window.orderBack(nil)
    defer{window.contentView=nil;window.close();session.canvas=nil}
    func settle(_ condition:()->Bool)async throws {
      for _ in 0..<100 {host.layoutSubtreeIfNeeded();if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
      XCTFail("Mounted publication viewport did not settle")
    }
    try await settle{(session.canvas?.enclosingScrollView?.contentSize.width ?? 0)>1000}
    func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    let hideLayers=try XCTUnwrap(descendants(host).compactMap{$0 as? WorkspaceToolbarNativeButton}.first{$0.accessibilityLabel()=="Canvas & Surfaces"})
    XCTAssertTrue(hideLayers.isEnabled);hideLayers.performClick(nil)
    try await settle{session.canvas?.fittingInsets.left==16}
    let canvas=try XCTUnwrap(session.canvas),before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    func fitCount()->Int{(canvas.diagnostics["last_fit"] as? [String:Any])?["request"] as? Int ?? 0}
    let firstCount=fitCount();controller.open(id)
    try await settle{canvas.fittingInsets.left==266 && fitCount()>firstCount}
    let fit=try XCTUnwrap(canvas.diagnostics["last_fit"] as? [String:Any]),after=try XCTUnwrap(fit["after"] as? [String:Any]),insets=try XCTUnwrap(after["fitting_insets_visual_points"] as? [String:CGFloat])
    XCTAssertEqual(insets["left"],266);XCTAssertEqual(insets["right"],318)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
    controller.close();try await settle{canvas.fittingInsets.left==16}
    let canceledCount=fitCount();controller.open(id);controller.close()
    try await Task.sleep(nanoseconds:100_000_000);host.layoutSubtreeIfNeeded()
    XCTAssertEqual(fitCount(),canceledCount,"Closing before the deferred explicit action must not move the viewport later")
    XCTAssertEqual(store.project,before)
  }
  func testMountedBindingKeyboardGestureUsesSharedNativeControlWithOneUndoAndExactSources()throws {
    let(store,controller)=try fixture();let id=try create(controller),session=store.artworkSession
    var assemblyID:UUID?
    try store.engine.edit("Prepared ordinary physical binding"){project in assemblyID=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:id,stock:.init(thicknessMM:0.16)),name:"Native physical source")}
    let assembly=try XCTUnwrap(assemblyID),before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    let selection:Set<UUID>=[before.objects[0].id];store.engine.selection=selection
    let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:300,height:560),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:PublicationBindingControls(session:session,publicationID:id).environmentObject(store).padding(16));host.sizingOptions=[];window.contentView=host;host.frame=window.contentView!.bounds
    defer{window.contentView=nil;window.close()}
    host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.05))
    func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    let slider=try XCTUnwrap(descendants(host).compactMap{$0 as? InspectorNativeSlider}.first{$0.accessibilityLabel()=="Sheet opening"})
    XCTAssertTrue(slider.isEnabled);XCTAssertEqual(slider.doubleValue,0)
    XCTAssertTrue(window.makeFirstResponder(slider))
    for index in 0..<8 {
      let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:Double(index),windowNumber:window.windowNumber,context:nil,characters:"\u{f703}",charactersIgnoringModifiers:"\u{f703}",isARepeat:index>0,keyCode:124))
      slider.keyDown(with:event)
    }
    XCTAssertTrue(store.engine.hasActiveInteraction)
    let release=try XCTUnwrap(NSEvent.keyEvent(with:.keyUp,location:.zero,modifierFlags:[],timestamp:8,windowNumber:window.windowNumber,context:nil,characters:"\u{f703}",charactersIgnoringModifiers:"\u{f703}",isARepeat:false,keyCode:124))
    slider.keyUp(with:release)
    XCTAssertFalse(store.engine.hasActiveInteraction)
    let after=try XCTUnwrap(store.project),object=try XCTUnwrap(after.objects.first{$0.id==assembly})
    XCTAssertEqual(object.sheetAssembly?.openingDegrees ?? -1,14.4,accuracy:0.000001)
    XCTAssertEqual(store.engine.undoStack.count,undo+1)
    XCTAssertEqual(after.objects.filter{$0.id != assembly},before.objects.filter{$0.id != assembly})
    XCTAssertEqual(after.publications,before.publications);XCTAssertEqual(after.textStories,before.textStories);XCTAssertEqual(after.camera,before.camera)
    XCTAssertEqual(object.sheetAssembly?.stock,before.objects.first{$0.id==assembly}?.sheetAssembly?.stock)
    XCTAssertEqual(store.engine.selection,selection,"A physical setting cannot implicitly navigate/select the other viewport")
    try store.engine.flush();XCTAssertEqual(try store.repository.load(after.id).objects,after.objects)
    store.engine.undo();XCTAssertEqual(store.project,before)
    store.engine.redo();XCTAssertEqual(store.project?.objects,after.objects)
  }

}

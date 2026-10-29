import AppKit
import SwiftUI
import XCTest
import FormCADModel
import FormCore
import FormGeometry
@testable import FormApp

@MainActor final class CanvasSourceAuthoringTests:XCTestCase {
  private final class Gate {
    var entered=false
    var continuation:CheckedContinuation<Void,Never>?
    func wait()async{entered=true;await withCheckedContinuation{continuation=$0}}
    func release(){continuation?.resume();continuation=nil}
  }
  private struct Controls:View {
    @ObservedObject var store:StudioStore
    let id:UUID
    var body:some View {if let object=store.project?.objects.first(where:{$0.id==id}) {FabricEnvironmentControls(object:object).environmentObject(store)}}
  }
  private func store(_ project:Project)throws->StudioStore {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("canvas-source-authoring-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false);store.engine.project=project
    store.showingHome=false;store.environment = .function
    addTeardownBlock{@MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return store
  }
  private func cosmetics()throws->(StudioStore,UUID,UUID) {
    let project=try PaperSamples.cosmetics(),object=try XCTUnwrap(project.objects.first{$0.paperConstruction?.insideArtworkSourceID != nil})
    return (try store(project),object.id,try XCTUnwrap(object.paperConstruction?.insideArtworkSourceID))
  }
  private func authored()throws->(StudioStore,UUID) {
    var project=Project(name:"Unknown sewn source controls")
    let recipe=Recipe("newCurvedSource","Unregistered curved source","scissors","No product registration",[
      .init("width","Source width",220,100...300),.init("depth","Source height",120,80...200),.init("span","Panel span",40,20...100)])
    project.recipes=[recipe]
    var object=try project.makeObject(recipeID:recipe.id)
    var path=ArtworkElement(kind:"path",x:10,y:10,width:40,height:40)
    var contour=VectorContour([.init(.init(0,0)),.init(.init(40,0)),.init(.init(36,40),incoming:.init(45,28)),.init(.init(0,36))]);contour.id=UUID()
    path.path = .init(width:40,height:40,contours:[contour])
    var piece=SewingPatternPiece(name:"Unfamiliar curved panel");piece.seamAllowance=5
    path.sewingPiece=try SewingPatterns.bindingStableEdges(piece,to:path);path.fillEnabled=false
    object.artwork = .init(background:"#FFFFFF",elements:[path]);object.artworkParameterBindings=[.init(id:"panel-span",elementID:path.id,property:.width,value:"span")]
    project.objects=[object];try project.validateArtworkLinks()
    return (try store(project),object.id)
  }
  func testFreshInsideSourceOpensItsReadableNetOnceAndNativeEditsRetainSourceUndo()throws {
    let (store,id,inside)=try cosmetics(),before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    store.select(id)
    XCTAssertFalse(store.artworkSession.frames.contains{$0.id==inside && $0.projection==nil})
    XCTAssertEqual(store.project?.objects,before.objects,"Enumerating physical frames cannot rewrite canonical sources")
    store.select(inside);store.artworkSession.reconcile()
    let session=store.artworkSession,proof=try XCTUnwrap(session.activeCanvasFrame)
    XCTAssertEqual(proof.projection?.constructionID,id);XCTAssertEqual(proof.projection?.sourceID,inside)
    XCTAssertEqual(proof.projection?.inside,true);XCTAssertEqual(proof.projection?.isProof,true)
    XCTAssertEqual(store.primary?.id,id);XCTAssertEqual(session.objectID,inside)
    XCTAssertEqual(session.frames.filter{$0.projection?.sourceID==inside && $0.projection?.isProof == true}.count,1)
    let canonical=try XCTUnwrap(before.objects.first{$0.id==inside}?.artwork),normal=ArtworkElement(kind:"text",x:4,y:5,text:"INSIDE R")
    session.add([normal]);XCTAssertEqual(store.engine.undoStack.count,undo+1)
    let saved=try XCTUnwrap(store.project?.objects.first{$0.id==inside}?.artwork?.elements.first{$0.id==normal.id}?.affine)
    XCTAssertLessThan(saved.a*saved.d-saved.b*saved.c,0)
    let visible=try XCTUnwrap(session.art.elements.first{$0.id==normal.id}),t=visible.affine ?? .init()
    XCTAssertGreaterThan(t.a*t.d-t.b*t.c,0)
    XCTAssertEqual(store.project?.objects.first{$0.id==inside}?.artwork?.elements.filter{$0.id != normal.id},canonical.elements)
    store.engine.undo();XCTAssertEqual(store.project?.objects,before.objects)
  }
  func testMultiplePhysicalOwnersRequireExplicitConstructionInsteadOfChoosingAnInsideFrame()throws {
    let (store,id,inside)=try cosmetics()
    try store.engine.edit("Another declared physical owner"){p in
      var duplicate=p.objects.first{$0.id==id}!;duplicate.id=UUID();duplicate.designID=UUID();duplicate.position.x+=300;p.objects.append(duplicate)
    }
    store.select(inside);let before=store.project,undo=store.engine.undoStack.count
    store.artworkSession.activate(inside)
    let frame=try XCTUnwrap(store.artworkSession.frames.first{$0.id==inside})
    XCTAssertNil(frame.projection);XCTAssertTrue(frame.sourceReview?.contains("multiple physical owners")==true)
    XCTAssertEqual(store.primary?.id,inside);XCTAssertNil(store.artworkSession.activeProjection)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
    store.select(id);let object=try XCTUnwrap(store.primary);store.setPaperInside(true,object:object)
    XCTAssertEqual(store.artworkSession.activeProjection?.constructionID,id)
    XCTAssertEqual(store.artworkSession.activeProjection?.inside,true)
  }
  func testPaperLinkedSewingSourceRetainsItsCanonicalContoursAndStandardEditingPath()throws {
    let (store,id,inside)=try cosmetics(),net=try PaperConstruction.definition(for:XCTUnwrap(store.project?.objects.first{$0.id==id})).net()
    try store.engine.edit("A genuine second physical source role"){p in
      let index=p.objects.firstIndex{$0.id==inside}!
      p.objects[index].parameters["width"]=net.size.x+100
      var art=p.objects[index].artwork!,piece=ArtworkElement(kind:"rectangle",x:net.size.x+20,y:5,width:15,height:20)
      var annotation=SewingPatternPiece(name:"Shared cloth test piece");annotation.seamAllowance=2;piece.sewingPiece=annotation
      art.elements.append(piece);try p.setArtwork(art,for:inside)
    }
    store.select(inside);let before=store.project,undo=store.engine.undoStack.count
    store.artworkSession.activate(inside)
    let frame=try XCTUnwrap(store.artworkSession.frames.first{$0.id==inside})
    XCTAssertNil(frame.projection);XCTAssertTrue(frame.sourceReview?.contains("sewing geometry")==true)
    let piece=try XCTUnwrap(frame.artwork.elements.first{$0.sewingPiece != nil})
    XCTAssertGreaterThan(piece.x,net.size.x);XCTAssertGreaterThan(frame.rect.width,piece.x+piece.width,"Canonical sewing contours beyond the paper net remain reachable")
    XCTAssertNil(store.artworkSession.activeProjection);XCTAssertEqual(store.artworkSession.art,frame.artwork)
    XCTAssertTrue(FabricEnvironmentContext.applies(to:try XCTUnwrap(store.primary),in:try XCTUnwrap(store.project)))
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
  }
  func testUnregisteredSewnRecipeHasRealNativeControlsThatChangeCanonicalBoundaryWithOneUndo()async throws {
    let (store,id)=try authored();store.select(id)
    XCTAssertNotNil(FabricEnvironmentContext(object:try XCTUnwrap(store.primary),project:try XCTUnwrap(store.project)))
    XCTAssertNotNil(store.artworkSession.frames.first{$0.object.id==id},"Frame discovery follows source annotation, not the artboard recipe name")
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count,nodeIDs=before.objects[0].artwork!.elements[0].path!.contours.flatMap(\.nodes).map(\.id)
    NSApp.setActivationPolicy(.accessory)
    let window=NSWindow(contentRect:.init(x:60,y:60,width:400,height:1000),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.aqua)
    let host=NSHostingView(rootView:Controls(store:store,id:id));window.contentView=host;window.makeKeyAndOrderFront(nil)
    defer{window.close()}
    func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    var controls:[NSSlider]=[]
    for _ in 0..<200 {host.layoutSubtreeIfNeeded();controls=descendants(host).compactMap{$0 as? NSSlider};if controls.count==3{break};try await Task.sleep(nanoseconds:10_000_000)}
    XCTAssertEqual(controls.count,3)
    let slider=try XCTUnwrap(controls.first{$0.accessibilityLabel()=="Panel span"} ?? controls.last)
    XCTAssertTrue(window.makeFirstResponder(slider))
    for _ in 0..<3 {
      let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.function,.numericPad],timestamp:ProcessInfo.processInfo.systemUptime,
        windowNumber:window.windowNumber,context:nil,characters:"\u{F703}",charactersIgnoringModifiers:"\u{F703}",isARepeat:false,keyCode:124))
      window.sendEvent(event);try await Task.sleep(nanoseconds:5_000_000)
    }
    let changed=try XCTUnwrap(store.project?.objects.first{$0.id==id})
    XCTAssertGreaterThan(changed["span"],40);XCTAssertEqual(changed.artwork?.elements[0].width,changed["span"])
    XCTAssertEqual(changed.artwork?.elements[0].path?.contours.flatMap(\.nodes).map(\.id),nodeIDs)
    XCTAssertEqual(store.engine.undoStack.count,undo+1)
    let report=try await ConstructionCommands.artworkValidationRequest(project:try XCTUnwrap(store.project),arguments:["command":"validate_cases","object_id":id.uuidString]).run()
    XCTAssertTrue(report.passed);XCTAssertGreaterThan(report.cases[0].pieces[0].stitchBoundsMM.width,40)
    store.engine.undo();XCTAssertEqual(store.project?.objects,before.objects)
  }
  func testNewSourceCasesSupersedeObsoleteArtworkReportsOnTheSharedCoordinator()async throws {
    let (store,id)=try authored(),before=try XCTUnwrap(store.project),gate=Gate()
    let oldRequest=try ConstructionCommands.artworkValidationRequest(project:before,arguments:["command":"validate_cases","object_id":id.uuidString])
    let old=Task {try await store.constructionValidation.validate(oldRequest,checkpoint:{await gate.wait()}){oldRequest.isCurrent(in:store.project)}}
    for _ in 0..<500 {if gate.entered{break};try await Task.sleep(nanoseconds:1_000_000)}
    XCTAssertTrue(gate.entered)
    _ = try store.engine.call("form_update_object",arguments:["object_id":id.uuidString,"parameters":["span":65.0]])
    store.constructionValidation.projectDidChange(store.project)
    let latest=try ConstructionCommands.artworkValidationRequest(project:try XCTUnwrap(store.project),arguments:["command":"validate_cases","object_id":id.uuidString])
    let report=try await store.constructionValidation.validate(latest){latest.isCurrent(in:store.project)}
    XCTAssertTrue(report.passed);XCTAssertNotEqual(report.sourceRevision,oldRequest.sourceRevision)
    XCTAssertGreaterThan(report.cases[0].pieces[0].stitchBoundsMM.width,60)
    gate.release()
    do{_ = try await old.value;XCTFail("Obsolete artwork source evidence was accepted")}catch is CancellationError{}catch{XCTFail("Expected obsolete generation cancellation, got \(error)")}
  }
  func testBindingProgramMetadataWithoutChangedResolvedArtworkReusesActualGeometryHandle()throws {
    let (store,id)=try authored();var project=try XCTUnwrap(store.project)
    project.recipes[0].parts=[.init("box",["width":"width","height":"2","depth":"depth"])]
    let object=try XCTUnwrap(project.objects.first{$0.id==id}),first=GeometryFactory.object(object,project:project,assets:store.artworkSession.assets,textureLimit:128)
    func nodes(_ node:MeshNode)->[MeshNode] {[node]+node.childNodes.flatMap(nodes)}
    let geometry=try XCTUnwrap(nodes(first).compactMap(\.geometry).first)
    project.objects[0].artworkParameterBindings![0].value="span+0"
    try project.validateArtworkParameterBindings()
    let next=GeometryFactory.object(project.objects[0],project:project,assets:store.artworkSession.assets,textureLimit:128)
    XCTAssertTrue(nodes(next).compactMap(\.geometry).first === geometry,"Changing equivalent source expressions must not rebuild identical resolved geometry")
  }
  func testComponentDefinitionSharedWithPaperKeepsItsCanonicalEditorAndReturnContext()throws {
    let (store,_,inside)=try cosmetics();var hostID=UUID(),instance=ArtworkElement(kind:"group",x:10,y:10,width:35,height:40)
    try store.engine.edit("A genuine component source role"){p in
      let i=p.objects.firstIndex{$0.id==inside}!;p.objects[i].componentDefinition=true
      instance.component = .init(sourceObjectID:inside);instance.contentSize=p.objects[i].artworkSize
      var host=try p.makeObject(recipeID:"artboard",name:"Existing component instance");host.artwork = .init(elements:[instance]);hostID=host.id;p.objects.append(host)
    }
    store.select(hostID);let session=store.artworkSession;session.activate(hostID);session.choose([instance.id])
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    session.editComponentSource(instance);session.reconcile()
    XCTAssertEqual(session.objectID,inside);XCTAssertNotNil(session.componentReturn);XCTAssertEqual(session.componentReturn?.objectID,hostID)
    XCTAssertNil(session.activeProjection);XCTAssertNotNil(session.frames.first{$0.id==inside && $0.projection==nil})
    XCTAssertTrue(session.activeCanvasFrame?.sourceReview?.contains("component definition")==true)
    XCTAssertEqual(store.project?.objects,before.objects);XCTAssertEqual(store.engine.undoStack.count,undo)
    let text=ArtworkElement(kind:"text",x:6,y:7,text:"Canonical component")
    session.add([text]);XCTAssertEqual(store.engine.undoStack.count,undo+1)
    let saved=try XCTUnwrap(store.project?.objects.first{$0.id==inside}?.artwork?.elements.first{$0.id==text.id})
    XCTAssertEqual(saved.affine,text.affine,"Canonical component editing must not apply the inside physical-view reflection")
    store.engine.undo();XCTAssertEqual(store.project?.objects,before.objects)
    session.returnToComponent();XCTAssertNil(session.componentReturn);XCTAssertEqual(session.objectID,hostID)
    XCTAssertEqual(session.selection,[instance.id]);XCTAssertEqual(store.project?.objects,before.objects)
  }

}

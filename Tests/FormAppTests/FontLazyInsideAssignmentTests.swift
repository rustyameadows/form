import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class FontLazyInsideAssignmentTests:XCTestCase {
  @MainActor private final class Fixture {
    let directory:URL,store:StudioStore,paperID:UUID,textID:UUID
    var window:NSWindow?,canvas:VectorCanvasView?
    var session:ArtworkSession {store.artworkSession}
    init(sharedElementID:Bool=false)throws {
      _ = NSApplication.shared
      directory=FileManager.default.temporaryDirectory.appendingPathComponent("font-lazy-inside-"+UUID().uuidString)
      store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
      store.fontLibraryPreferences = .init(file:directory.appendingPathComponent("fonts.json"))
      var project=Project(name:"Legacy inside font assignment")
      var paper=try project.makeObject(recipeID:"paperEnvelope")
      var inside=ArtworkElement(kind:"text",x:20,y:30,width:100,height:20,text:"Inside 👩🏽‍💻 range",fontSize:18)
      var typography=Typography();typography.fontName="Georgia";typography.frameMode="area"
      inside.typography=typography;textID=inside.id
      var outside=ArtworkElement(kind:"text",x:10,y:15,width:100,height:20,text:"Outside remains unchanged",fontSize:14)
      outside.typography=typography
      if sharedElementID {outside.id=inside.id}
      paper.artwork = .init(background:"#FFFFFF",elements:[outside])
      var legacy=Artwork(background:"#F7F5EF",elements:[inside]);legacy.backgroundOpacity=0
      legacy.language="fr";legacy.guides=[.init(axis:"x",position:7)]
      var definition=try PaperConstruction.definition(for:paper);definition.insideArtwork=legacy
      paper.paperConstruction=definition;paperID=paper.id;project.objects=[paper]
      store.engine.project=project;store.showingHome=false;store.mode = .artwork
      let frame=try XCTUnwrap(session.frames.first{$0.projection?.constructionID==paperID && $0.projection?.inside==true && $0.projection?.isProof==true})
      session.activate(frame.id);session.choose([textID])
      XCTAssertTrue(session.activeProjection?.requiresInsideSource==true)
    }
    func mount()throws->CanvasTextView {
      let window=NSWindow(contentRect:.init(x:-10000,y:-10000,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed=false
      let canvas=VectorCanvasView(frame:window.contentView!.bounds)
      window.contentView=canvas;canvas.session=session;session.canvas=canvas
      self.window=window;self.canvas=canvas;canvas.synchronize()
      canvas.beginText(try XCTUnwrap(session.primary))
      let view=try XCTUnwrap(canvas.activeTextView);view.undoManager?.groupsByEvent=false
      return view
    }
    func insideArtwork()throws->Artwork {
      let project=try XCTUnwrap(store.project),paper=try XCTUnwrap(project.objects.first{$0.id==paperID})
      let sourceID=try XCTUnwrap(paper.paperConstruction?.insideArtworkSourceID)
      return try XCTUnwrap(project.objects.first{$0.id==sourceID}?.artwork)
    }
    func close() {
      canvas?.finishText();window?.contentView=nil;window?.close();store.engine.project=nil
      try? FileManager.default.removeItem(at:directory)
    }
  }

  func testLegacyInsideFontPreflightIsReadOnlyAndAssignmentMigratesOnlyChosenFaceWithOneUndo()throws {
    // Independent faces can retain the same layer identities from older files.
    // Routing by the physical object ID would successfully edit the wrong face.
    let f=try Fixture(sharedElementID:true);defer{f.close()}
    let before=try XCTUnwrap(f.store.project),frameID=f.session.activeFrameID
    let arguments:[String:Any]=["object_id":f.paperID.uuidString,"element_ids":[f.textID.uuidString],"command":"font","font_name":"Georgia-Bold"]
    try f.store.preflightFontHandoff("form_edit_artwork",arguments,projection:f.session.activeProjection)
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertTrue(f.store.fontLibraryPreferences.recent.isEmpty)
    XCTAssertTrue(f.session.chooseFont("Georgia-Bold"),f.store.error ?? "Inside font assignment failed")
    let after=try XCTUnwrap(f.store.project),inside=try f.insideArtwork()
    let physical=try XCTUnwrap(after.objects.first{$0.id==f.paperID}),sourceID=try XCTUnwrap(physical.paperConstruction?.insideArtworkSourceID)
    XCTAssertNil(physical.paperConstruction?.insideArtwork)
    XCTAssertEqual(after.objects.count,before.objects.count+1)
    XCTAssertEqual(physical.artwork,before.objects[0].artwork)
    XCTAssertEqual(f.session.objectID,sourceID);XCTAssertEqual(f.session.activeFrameID,frameID)
    XCTAssertEqual(inside.elements[0].typography?.fontName,"Georgia-Bold")
    var expected=try XCTUnwrap(before.objects[0].paperConstruction?.insideArtwork)
    _ = try ArtworkCommands.apply("font",to:&expected,ids:[f.textID],arguments:arguments)
    XCTAssertEqual(inside,expected,"Font assignment must retain registered placement and all inside metadata.")
    XCTAssertEqual(f.store.fontLibraryPreferences.recent,["Georgia-Bold"])
    XCTAssertEqual(f.store.engine.undoStack.count,1)
    f.store.engine.undo();f.session.reconcile();XCTAssertEqual(f.store.project,before)
    XCTAssertEqual(f.session.activeFrameID,frameID);XCTAssertTrue(f.session.activeProjection?.requiresInsideSource==true)
    f.store.engine.redo();f.session.reconcile();XCTAssertEqual(f.store.project,after)
  }

  func testNativeInsideUTF16RangeAssignsWithoutLookingForItsLayerOnOutsideAndKeepsOneDocumentUndo()throws {
    let f=try Fixture();defer{f.close()}
    let before=try XCTUnwrap(f.store.project),view=try f.mount()
    let range=(view.string as NSString).range(of:"👩🏽‍💻")
    XCTAssertNotEqual(range.location,NSNotFound);view.setSelectedRange(range)
    let context=f.session.captureFontSelection()
    XCTAssertEqual(context.sourceRange,range)
    XCTAssertTrue(f.session.chooseFont("Georgia-Bold",context:context),f.store.error ?? "Native inside font assignment failed")
    XCTAssertTrue(f.window?.firstResponder === view)
    XCTAssertEqual(TextCase.source(view.attributedString()).sourceRange(view.selectedRange()),range)
    let source=try XCTUnwrap(f.insideArtwork().elements.first{$0.id==f.textID})
    XCTAssertEqual(source.text,before.objects[0].paperConstruction?.insideArtwork?.elements[0].text)
    let runs=try XCTUnwrap(source.textRuns)
    for run in runs {
      XCTAssertEqual(run.typography.fontName,
        NSIntersectionRange(.init(location:run.location,length:run.length),range).length>0 ? "Georgia-Bold":"Georgia")
    }
    XCTAssertEqual(f.store.project?.objects.first{$0.id==f.paperID}?.artwork,before.objects[0].artwork)
    f.canvas?.finishText()
    let after=try XCTUnwrap(f.store.project)
    XCTAssertEqual(f.store.engine.undoStack.count,1)
    f.store.engine.undo();f.session.reconcile();XCTAssertEqual(f.store.project,before)
    f.store.engine.redo();f.session.reconcile();XCTAssertEqual(f.store.project,after)
  }

  func testLockedLinkedVariantRejectsInsideHandoffWithoutCreatingSourceHistoryOrRecents()throws {
    let f=try Fixture();defer{f.close()}
    var project=try XCTUnwrap(f.store.project),sibling=project.objects[0]
    sibling.id=UUID();sibling.locked=true;project.objects.append(sibling);f.store.engine.project=project
    XCTAssertFalse(f.session.chooseFont("Georgia-Bold"))
    XCTAssertNotNil(f.store.error);XCTAssertEqual(f.store.project,project)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty);XCTAssertTrue(f.store.fontLibraryPreferences.recent.isEmpty)
    XCTAssertNil(f.store.project?.objects[0].paperConstruction?.insideArtworkSourceID)
  }
}

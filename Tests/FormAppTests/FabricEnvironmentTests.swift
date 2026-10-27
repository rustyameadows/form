import AppKit
import FormCore
import FormGraphics
import PDFKit
import XCTest
@testable import FormApp

@MainActor final class FabricEnvironmentTests:XCTestCase {
  private func fixture()throws->(StudioStore,UUID,UUID) {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("fabric-environments-"+UUID().uuidString),repository=try ProjectRepository(root:root)
    var(project,definition)=try PatternAssemblySamples.roundedPouch()
    let assembly=try project.addPatternAssembly(definition),source=definition.sourceObjectID
    let box=try project.makeObject(recipeID:"box");project.objects.append(box)
    try repository.save(project)
    let store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(project.id);store.showingHome=false;store.select(assembly)
    addTeardownBlock { @MainActor in store.cloth.clear();store.closeDetachedCanvas();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return(store,assembly,source)
  }
  func testPatternAssemblyUsesItsOriginalSourceForFabricationWithoutRigidPrintOptions()throws {
    let(store,id,source)=try fixture(),project=store.project!,assembly=project.objects.first{$0.id==id}!,context=try XCTUnwrap(FabricEnvironmentContext(object:assembly,project:project))
    XCTAssertEqual(context.sourceID,source);XCTAssertGreaterThan(context.pieceCount,0);XCTAssertGreaterThan(context.cutCount,0)
    XCTAssertEqual(context.seamCount,project.objects.first{$0.id==source}?.artwork?.sewingSeams?.count)
    XCTAssertEqual(context.fabricationRoutes,[.pattern,.layout,.jobs,.collection])
    XCTAssertTrue(FabricationDestination.pattern.available(in:project,object:assembly));XCTAssertTrue(FabricationDestination.layout.available(in:project,object:assembly));XCTAssertFalse(FabricationDestination.print3D.available(in:project,object:assembly))
    let rigid=project.objects.last!
    XCTAssertFalse(FabricEnvironmentContext.applies(to:rigid,in:project));XCTAssertTrue(FabricationDestination.print3D.available(in:project,object:rigid));XCTAssertNil(store.activateFabricPatternSource(for:rigid.id))
  }
  func testAssemblyProductionReviewRetainsSelectedProductEnvironmentSurfaceCameraAndHistory()throws {
    let(store,id,source)=try fixture()
    store.showEnvironment(.fabricate);store.surfaceLayout = .split;store.mode = .table
    store.engine.project!.camera.azimuth=0.73
    let before=store.project!,history=store.engine.undoStack
    for destination in [FabricationDestination.pattern,.layout] {
      store.presentFabrication(destination)
      XCTAssertEqual(store.fabricationReview?.destination,destination);XCTAssertEqual(store.fabricationReview?.objectID,source)
      XCTAssertEqual(store.engine.selection,[id]);XCTAssertEqual(store.artworkSession.objectID,source);XCTAssertEqual(store.artworkSession.linkedTargetID,id)
      XCTAssertEqual(store.environment,.fabricate);XCTAssertEqual(store.surfaceLayout,.split);XCTAssertEqual(store.mode,.table)
      XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack,history)
    }
    XCTAssertFalse(store.showingPrint)
  }
  func testConstructionEditorEditsCanonicalSourceAndUndoPreservesAssemblyIdentity()throws {
    let(store,id,source)=try fixture(),before=store.project!,assembly=before.objects.first{$0.id==id}!,sourceObject=before.objects.first{$0.id==source}!,piece=try XCTUnwrap(sourceObject.artwork?.elements.first{$0.sewingPiece != nil}),allowance=piece.sewingPiece!.seamAllowance
    store.showEnvironment(.function)
    XCTAssertEqual(store.activateFabricPatternSource(for:id),source);store.artworkSession.choose([piece.id])
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty);XCTAssertEqual(store.engine.selection,[id])
    store.artworkSession.update{$0.sewingPiece?.seamAllowance=allowance+1}
    let changed=try XCTUnwrap(store.project?.objects.first{$0.id==source}?.artwork?.elements.first{$0.id==piece.id})
    XCTAssertEqual(changed.sewingPiece?.seamAllowance,allowance+1);XCTAssertEqual(changed.width,piece.width);XCTAssertEqual(changed.height,piece.height)
    XCTAssertEqual(store.project?.objects.first{$0.id==id}?.patternAssembly,assembly.patternAssembly);XCTAssertEqual(store.engine.undoStack.count,1)
    for environment in [ProjectEnvironment.fabricate,.form,.function] {store.showEnvironment(environment);XCTAssertEqual(store.engine.selection,[id]);XCTAssertEqual(store.artworkSession.objectID,source)}
    store.undo();XCTAssertEqual(store.project,before)
  }
  func testFabricRoutesFollowDeclaredProcessAndRelatedDecorationRecords()throws {
    var project=Project(name:"Declared fabric processes")
    let garment=try project.makeObject(recipeID:"bomberJacket")
    var patch=try project.makeObject(recipeID:"textilePatch")
    patch.artwork = .init(elements:[.init(kind:"rectangle",x:0,y:0,width:40,height:30)])
    patch.textile?.attachment = .init(garmentID:garment.id,zone:.leftChest)
    project.objects=[garment,patch]
    var context=try XCTUnwrap(FabricEnvironmentContext(object:patch,project:project))
    XCTAssertTrue(context.fabricationRoutes.contains(.embroidery));XCTAssertFalse(context.fabricationRoutes.contains(.decoration));XCTAssertFalse(context.fabricationRoutes.contains(.print3D));XCTAssertFalse(context.fabricationRoutes.contains(.page))
    patch.textile?.process = .wovenPatch;project.objects[1]=patch
    context=try XCTUnwrap(FabricEnvironmentContext(object:patch,project:project));XCTAssertEqual(context.fabricationRoutes,[.jobs,.collection])
    patch.textile?.process = .printedPatch;project.objects[1]=patch
    context=try XCTUnwrap(FabricEnvironmentContext(object:patch,project:project));XCTAssertTrue(context.fabricationRoutes.contains(.decoration));XCTAssertFalse(context.fabricationRoutes.contains(.embroidery))
    XCTAssertEqual(FabricEnvironmentContext(object:garment,project:project)?.decorations.map(\.id),[patch.id])
    XCTAssertNil(FabricEnvironmentContext(object:garment,project:project)?.sourceID)
    let frame=try project.makeObject(recipeID:"artboard");XCTAssertFalse(FabricEnvironmentContext.applies(to:frame,in:project))
    var paper=patch;paper.recipeID="paperEnvelope"
    XCTAssertFalse(FabricEnvironmentContext.applies(to:paper,in:project));XCTAssertFalse(FabricationDestination.print3D.available(in:project,object:paper))
  }
  func testInlinePatternProofUsesCanonicalPhysicalSourceAndCachesCameraChanges()throws {
    let(store,id,source)=try fixture()
    store.showEnvironment(.function);store.surfaceLayout = .split;store.mode = .artwork
    let before=store.project!,history=store.engine.undoStack
    XCTAssertEqual(store.activateFabricPatternSource(for:id),source)
    let model=SewingPatternReviewModel(session:store.artworkSession)
    model.refresh()
    let data=try XCTUnwrap(model.proof),document=try XCTUnwrap(PDFDocument(data:data)),page=try XCTUnwrap(document.page(at:0))
    XCTAssertEqual(document.pageCount,1);XCTAssertGreaterThan(model.pieceCount,0);XCTAssertEqual(model.sourceBuilds,1)
    XCTAssertEqual(page.bounds(for:.mediaBox).width,model.size.x*72/25.4,accuracy:0.02)
    XCTAssertEqual(page.bounds(for:.mediaBox).height,model.size.y*72/25.4,accuracy:0.02)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack,history)
    store.engine.project!.camera.azimuth += 0.2;model.refresh();model.refresh()
    XCTAssertEqual(model.sourceBuilds,1);XCTAssertEqual(model.proof,data)
    XCTAssertEqual(store.engine.selection,[id]);XCTAssertEqual(store.artworkSession.objectID,source);XCTAssertEqual(store.artworkSession.linkedTargetID,id)
    XCTAssertEqual(store.surfaceLayout,.split);XCTAssertEqual(store.mode,.artwork);XCTAssertEqual(store.environment,.function)
    XCTAssertEqual(store.project?.objects,before.objects);XCTAssertEqual(store.engine.undoStack,history)
  }
  func testInlineTiledProofDraftIsTransientAndExplicitSaveIsOneUndoOnOriginalSource()throws {
    let(store,id,source)=try fixture()
    store.showEnvironment(.fabricate);XCTAssertEqual(store.activateFabricPatternSource(for:id),source)
    let before=store.project!,model=SewingPatternReviewModel(session:store.artworkSession)
    model.refresh();model.tiled=true;model.refresh()
    XCTAssertNotNil(model.proof);XCTAssertGreaterThan(model.pageCount,1);XCTAssertEqual(model.sourceBuilds,1)
    model.draft.values[SewingTileDraft.Field.width.rawValue]="-1";model.refresh()
    XCTAssertNil(model.proof);XCTAssertFalse(model.error.isEmpty);XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    model.draft.preset("Letter landscape");model.refresh()
    XCTAssertNotNil(model.proof);XCTAssertTrue(model.error.isEmpty);XCTAssertEqual(model.sourceBuilds,1)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    let saved=try model.draft.options()
    XCTAssertTrue(model.saveOptions());XCTAssertEqual(store.project?.objects.first{$0.id==source}?.artwork?.sewingTiles,saved)
    XCTAssertEqual(store.engine.undoStack.count,1);XCTAssertEqual(store.engine.selection,[id])
    XCTAssertEqual(store.project?.objects.first{$0.id==id}?.patternAssembly,before.objects.first{$0.id==id}?.patternAssembly)
    XCTAssertEqual(model.sourceBuilds,1)
    store.undo();model.refresh()
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.selection,[id]);XCTAssertNil(store.project?.objects.first{$0.id==source}?.artwork?.sewingTiles)
  }
  func testEditFabricSourceReturnsToFormWithoutCreatingCanvasOrChangingAssemblyLayout()throws {
    let(store,id,source)=try fixture()
    store.showEnvironment(.function);store.surfaceLayout = .split;store.mode = .table
    let before=store.project!,history=store.engine.undoStack
    XCTAssertNil(store.project?.canvasWorkspace)
    store.editFabricPatternSourceOnCanvas(for:id)
    XCTAssertEqual(store.environment,.form);XCTAssertEqual(store.mode,.artwork);XCTAssertEqual(store.surfaceLayout,.split)
    XCTAssertEqual(store.engine.selection,[id]);XCTAssertEqual(store.artworkSession.objectID,source);XCTAssertEqual(store.artworkSession.linkedTargetID,id)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack,history);XCTAssertNil(store.project?.canvasWorkspace)
  }
}

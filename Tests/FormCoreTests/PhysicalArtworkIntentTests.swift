import Foundation
import XCTest
import FormCADModel
@testable import FormCore

final class PhysicalArtworkIntentTests:XCTestCase {
  private func fixture() throws -> (OperationEngine,UUID) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("physical-intent-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    engine.project=Project(name:"Shared physical intent")
    let source=PlanarConstructionDefinition(name:"Authored net panel",size:.init(70,40),panels:[
      .init(id:"front",name:"Front",polygon:[.init(0,0),.init(40,0),.init(40,40),.init(0,40)]),
      .init(id:"net",name:"Net is an ordinary panel name",polygon:[.init(40,0),.init(70,0),.init(40,40)])],
      hinges:[.init(id:"crease",parentPanelID:"front",childPanelID:"net",start:.init(40,0),end:.init(40,40),angleDegrees:90)],rootPanelID:"front")
    let created=try XCTUnwrap(engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(source)]) as? [String:Any])
    return(engine,try XCTUnwrap(UUID(uuidString:try XCTUnwrap(created["object_id"] as? String))))
  }
  private func set(_ engine:OperationEngine,_ id:UUID,_ intent:PhysicalArtworkIntent) throws {
    _ = try engine.call("form_surface",arguments:["command":"set_intent","object_id":id.uuidString,"intent":try jsonObject(intent)])
  }
  func testNetSafetyUsesUnionAndExplicitPanelBleedOverlapRetainsSourceIdentities() throws {
    let (engine,id)=try fixture(),before=try XCTUnwrap(engine.project),object=before.objects[0]
    let net=PhysicalArtworkIntent(surface:.init(kind:.net),bleedMM:3,safeInsetMM:2)
    let first=PhysicalArtworkIntent(surface:.init(kind:.panel,surfaceID:"front"),bleedMM:3,safeInsetMM:2)
    let second=PhysicalArtworkIntent(surface:.init(kind:.panel,surfaceID:"net"),bleedMM:3,safeInsetMM:2)
    XCTAssertNotEqual(net.id,second.id)
    XCTAssertEqual(PhysicalArtworkSurfaceIdentity(kind:.panel,surfaceID:"é").key,
      PhysicalArtworkSurfaceIdentity(kind:.panel,surfaceID:"e\u{301}").key)
    for intent in [net,first,second] {try set(engine,id,intent)}
    let project=try XCTUnwrap(engine.project),current=project.objects[0]
    let report=try project.physicalArtworkIntentReport(for:current)
    let guides=try XCTUnwrap(report.guides.first{$0.intent.id==net.id})
    XCTAssertEqual(guides.trim.count,1)
    XCTAssertEqual(guides.trim.reduce(0){$0+SewingCurves.signedArea($1)},2200,accuracy:0.001)
    XCTAssertTrue(guides.safe.contains{SewingCurves.contains(.init(40,20),ring:$0)},"A crease inside the material union must not introduce an artificial safety gap")
    let overlap=try XCTUnwrap(report.issues.first{$0.code=="bleed_overlap"})
    XCTAssertEqual(Set(overlap.surfaceIDs),Set([first.id,second.id]))
    XCTAssertGreaterThan(try XCTUnwrap(overlap.overlapAreaMM2),0)
    XCTAssertTrue(report.requiresReview)
    XCTAssertEqual(current.paperConstruction,object.paperConstruction)
    XCTAssertEqual(current.artwork,object.artwork)
    XCTAssertEqual(project.objects.count,before.objects.count)
    let frame=try PhysicalArtworkFrame.paper(net:PaperConstruction.definition(for:current).net(),panelID:"net",inside:true)
    let canonical=try XCTUnwrap(report.guides.first{$0.intent.id==second.id})
    let local=canonical.transformed(by:frame.sourceToLocal)
    XCTAssertEqual(local.trim[0],canonical.trim[0].map(frame.sourceToLocal.apply))
    XCTAssertEqual(local.intent,canonical.intent)
  }
  func testCollapseAndRemovedSurfaceReturnCurrentReviewWithoutStalePolygons() throws {
    let (engine,id)=try fixture()
    let intent=PhysicalArtworkIntent(surface:.init(kind:.panel,surfaceID:"net"),bleedMM:3,safeInsetMM:2)
    try set(engine,id,intent)
    var project=try XCTUnwrap(engine.project)
    let original=try project.physicalArtworkIntentReport(for:project.objects[0])
    XCTAssertFalse(try XCTUnwrap(original.guides.first).safe.isEmpty)
    project.objects[0].physicalArtworkIntents![0].safeInsetMM=100
    let collapsed=try project.physicalArtworkIntentReport(for:project.objects[0])
    XCTAssertTrue(try XCTUnwrap(collapsed.guides.first).safe.isEmpty)
    XCTAssertTrue(collapsed.issues.contains{$0.code=="safe_inset_collapsed" && $0.surfaceIDs==[intent.id]})
    XCTAssertNotEqual(collapsed.sourceRevision,original.sourceRevision)
    project.objects[0].paperConstruction!.authored!.panels.removeLast()
    project.objects[0].paperConstruction!.authored!.hinges=[]
    let removed=try project.physicalArtworkIntentReport(for:project.objects[0])
    XCTAssertTrue(removed.guides.isEmpty)
    XCTAssertEqual(removed.issues.map(\.code),["unresolved_surface"])
    XCTAssertEqual(removed.issues.first?.surfaceIDs,[intent.id])
    XCTAssertNoThrow(try project.validateArtworkLinks(),"Missing targets retain repairable intent instead of attaching to another surface")
  }
  func testIntentPersistsWithOneUndoAndStaleOrInvalidEditsRejectAtomically() throws {
    let (engine,id)=try fixture(),before=try XCTUnwrap(engine.project),undo=engine.undoStack.count
    let revision=try before.physicalArtworkIntentRevision(for:before.objects[0])
    let intent=PhysicalArtworkIntent(surface:.init(kind:.net,side:.inside),bleedMM:4,safeInsetMM:3)
    _ = try engine.call("form_surface",arguments:["command":"set_intent","object_id":id.uuidString,
      "expected_revision":revision,"intent":try jsonObject(intent)])
    XCTAssertEqual(engine.undoStack.count,undo+1)
    let accepted=try XCTUnwrap(engine.project)
    try engine.flush();let reopened=try engine.repository.load(accepted.id)
    XCTAssertEqual(reopened.schemaVersion,56);XCTAssertEqual(reopened.objects,accepted.objects)
    XCTAssertThrowsError(try engine.call("form_surface",arguments:["command":"set_intent","object_id":id.uuidString,
      "expected_revision":revision,"intent":try jsonObject(intent)]))
    let missing=PhysicalArtworkIntent(surface:.init(kind:.panel,surfaceID:"missing"))
    XCTAssertThrowsError(try set(engine,id,missing))
    XCTAssertEqual(engine.project,accepted);XCTAssertEqual(engine.undoStack.count,undo+1)
    engine.undo();XCTAssertEqual(engine.project,before)
    engine.redo();XCTAssertEqual(engine.project,accepted)
    _ = try engine.call("form_surface",arguments:["command":"clear_intent","object_id":id.uuidString,"surface":try jsonObject(intent.surface)])
    XCTAssertNil(engine.project?.objects[0].physicalArtworkIntents)
    XCTAssertEqual(engine.project?.objects[0].paperConstruction,before.objects[0].paperConstruction)
  }
  func testSharedVariantGuideOwnershipCannotBeLostDuringArtworkTransfer() throws {
    for selectedHasIntent in [false,true] {
      let root=FileManager.default.temporaryDirectory.appendingPathComponent("variant-intent-"+UUID().uuidString)
      defer{try? FileManager.default.removeItem(at:root)}
      let engine=OperationEngine(repository:try ProjectRepository(root:root))
      var p=Project(name:"Shared variant guide ownership")
      var source=try p.makeObject(recipeID:"artboard",parameters:["width":100,"depth":100])
      var piece=ArtworkElement(kind:"rectangle",x:5,y:5,width:30,height:20)
      piece.sewingPiece = .init(name:"Shared canonical piece")
      source.artwork = .init(elements:[piece])
      let intent=PhysicalArtworkIntent(surface:.init(kind:.sewingPiece,surfaceID:piece.id.uuidString))
      if selectedHasIntent {source.physicalArtworkIntents=[intent]}
      var sibling=source;sibling.id=UUID();sibling.physicalArtworkIntents=[intent]
      var destination=try p.makeObject(recipeID:"artboard",parameters:["width":100,"depth":100])
      destination.artwork = .init(elements:[])
      p.objects=[source,sibling,destination];engine.project=p
      XCTAssertThrowsError(try engine.edit("Move"){q in
        _ = try q.transferArtwork(from:source.id,to:destination.id,ids:[piece.id])
      }) {error in XCTAssertTrue(error.localizedDescription.contains("variant"))}
      XCTAssertEqual(engine.project,p);XCTAssertTrue(engine.undoStack.isEmpty)
      // A destination family also has no implicit mapping for process intent.
      source.physicalArtworkIntents=[intent]
      var targetSibling=destination;targetSibling.id=UUID()
      p.objects=[source,destination,targetSibling];engine.project=p
      XCTAssertThrowsError(try engine.edit("Move"){q in
        _ = try q.transferArtwork(from:source.id,to:destination.id,ids:[piece.id])
      }) {error in XCTAssertTrue(error.localizedDescription.contains("variant"))}
      XCTAssertEqual(engine.project,p);XCTAssertTrue(engine.undoStack.isEmpty)
    }
  }
  func testFiniteSewingGuideOnSharedCanvasTransfersWithRemappedPieceAndOneUndo() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("canvas-sewn-intent-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    var project=Project(name:"Shared canvas cut intent")
    let workspace=try project.ensureCanvasWorkspace()
    var frame=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":120])
    var piece=ArtworkElement(kind:"rectangle",x:5,y:5,width:80,height:40)
    piece.sewingPiece = .init(name:"Canonical finite piece");piece.sewingPiece!.seamAllowance=3
    project.objects[0].artwork!.elements=[piece]
    // Destination already uses that local ID; transfer must reassign the moving
    // element and its intent together, while retaining the original destination.
    frame.artwork = .init(elements:[piece]);project.objects.append(frame);engine.project=project
    let intent=PhysicalArtworkIntent(surface:.init(kind:.sewingPiece,surfaceID:piece.id.uuidString),bleedMM:2,safeInsetMM:4)
    try set(engine,workspace.id,intent)
    let before=try XCTUnwrap(engine.project),undo=engine.undoStack.count
    XCTAssertThrowsError(try set(engine,workspace.id,.init(surface:.init(kind:.net))))
    XCTAssertEqual(engine.project,before)
    var moved=Set<UUID>()
    try engine.edit("Moved physical cut piece"){p in
      moved=try p.transferArtwork(from:workspace.id,to:frame.id,ids:[piece.id],offset:.init(0,50))
    }
    let accepted=try XCTUnwrap(engine.project),newID=try XCTUnwrap(moved.first)
    XCTAssertNotEqual(newID,piece.id)
    XCTAssertNil(accepted.objects.first{$0.id==workspace.id}?.physicalArtworkIntents)
    let target=try XCTUnwrap(accepted.objects.first{$0.id==frame.id})
    XCTAssertEqual(target.physicalArtworkIntents?.first?.surface.surfaceID,newID.uuidString)
    XCTAssertEqual(target.physicalArtworkIntents?.first?.bleedMM,2)
    XCTAssertEqual(Set(target.artwork!.elements.map(\.id)),[piece.id,newID])
    XCTAssertEqual(engine.undoStack.count,undo+1)
    let report=try accepted.physicalArtworkIntentReport(for:target)
    XCTAssertEqual(report.guides.first?.intent.surface.surfaceID,newID.uuidString)
    XCTAssertFalse(try XCTUnwrap(report.guides.first).safe.isEmpty)
    try engine.flush();XCTAssertEqual(try engine.repository.load(accepted.id).objects,accepted.objects)
    engine.undo();XCTAssertEqual(engine.project,before)
  }
  func testSewnPieceUsesItsRealCutAllowanceBeforeTheSharedBleedAndSafetyOffsets() throws {
    var project=Project(name:"Sewn physical frame")
    var object=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":100])
    var piece=ArtworkElement(kind:"rectangle",x:0,y:0,width:80,height:40)
    piece.sewingPiece = .init(name:"Independent authored piece");piece.sewingPiece!.seamAllowance=3
    object.artwork = .init(elements:[piece])
    let identity=PhysicalArtworkSurfaceIdentity(kind:.sewingPiece,surfaceID:piece.id.uuidString.lowercased())
    object.physicalArtworkIntents=[.init(surface:identity,bleedMM:2,safeInsetMM:4)];project.objects=[object]
    let report=try project.physicalArtworkIntentReport(for:object),guide=try XCTUnwrap(report.guides.first)
    XCTAssertTrue(report.issues.isEmpty)
    XCTAssertEqual(try XCTUnwrap(guide.trim.flatMap{$0}.map(\.x).min()),-3,accuracy:0.001)
    XCTAssertEqual(try XCTUnwrap(guide.bleed.flatMap{$0}.map(\.x).min()),-5,accuracy:0.001)
    XCTAssertEqual(try XCTUnwrap(guide.safe.flatMap{$0}.map(\.x).min()),1,accuracy:0.001)
    XCTAssertEqual(identity.key,PhysicalArtworkSurfaceIdentity(kind:.sewingPiece,surfaceID:piece.id.uuidString).key)
    XCTAssertEqual(project.objects[0].artwork?.elements.first,piece)
  }
}

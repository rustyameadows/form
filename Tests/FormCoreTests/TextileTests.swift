import XCTest
@testable import FormCore

final class TextileTests:XCTestCase {
  func testFlightStudyHasIndependentLinkedDecorationsAndEstimatedMaterials() throws {
    let p=Samples.flightJacket()
    XCTAssertEqual(p.objects.filter{$0.recipeID=="bomberJacket"}.count,2)
    XCTAssertEqual(p.objects.filter{$0.textile?.attachment != nil}.count,8)
    XCTAssertEqual(p.objects.filter{$0.recipeID=="artboard"}.count,3)
    XCTAssertEqual(p.minimumSchemaVersion,17)
    XCTAssertNoThrow(try p.validateArtworkLinks())
    for object in p.objects where object.textile != nil {
      XCTAssertFalse(object.textile!.measurementsVerified)
      XCTAssertNotNil(p.material(object.materialID).fabric)
      if object.textile?.kind != .garment {XCTAssertNotNil(p.editableArtwork(object))}
    }
    for object in p.objects {if let art=object.artwork {XCTAssertNoThrow(try validateArtwork(art))}}
    XCTAssertFalse(p.objects.first!.supportsArtworkFace)
  }
  func testAttachmentTracksParentDimensionsRotationAndMovementWithoutChangingSourceObjects() throws {
    var p=Samples.flightJacket();let garment=p.objects[0],decoration=p.objects.first{$0.textile?.attachment?.garmentID==garment.id}!
    let source=p.artworkOwner(decoration),before=p.textilePlacement(decoration)
    let fixed=decoration
    p.objects[0].position = .init(200,50,-100);p.objects[0].rotation=90;p.objects[0].parameters["width"]=780
    let after=p.textilePlacement(decoration)
    XCTAssertNotEqual(before.position,after.position)
    let landmark=TextileDesign.anchor(p.objects[0],zone:decoration.textile!.attachment!.zone)
    XCTAssertEqual(after.position.x,200+landmark.z,accuracy:1e-8)
    XCTAssertEqual(after.position.z,-100-landmark.x,accuracy:1e-8)
    XCTAssertEqual(after.rotation,90)
    XCTAssertEqual(p.objects.first{$0.id==decoration.id},fixed)
    XCTAssertEqual(p.artworkOwner(decoration),source)
    let target=Vector3(after.position.x+20,after.position.y,after.position.z-30)
    p.setTextileWorldPosition(decoration.id,to:target)
    let moved=p.textilePlacement(p.objects.first{$0.id==decoration.id}!)
    XCTAssertEqual(moved.position.x,target.x,accuracy:1e-8);XCTAssertEqual(moved.position.z,target.z,accuracy:1e-8)
  }
  func testGarmentDeletionDetachesDecorationsAndUndoRestoresRelationships() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let e=OperationEngine(repository:try ProjectRepository(root:root));let original=Samples.flightJacket();e.project=original
    let garment=original.objects[0],parts=original.objects.filter{$0.textile?.attachment?.garmentID==garment.id}
    let placements=Dictionary(uniqueKeysWithValues:parts.map{($0.id,original.textilePlacement($0))})
    _=try e.call("form_delete_objects",arguments:["object_ids":[garment.id.uuidString]])
    for id in placements.keys {
      let component=e.project!.objects.first{$0.id==id}!
      XCTAssertNil(component.textile?.attachment);XCTAssertEqual(component.position,placements[id]!.position)
      XCTAssertNotNil(e.project!.editableArtwork(component))
    }
    e.undo();XCTAssertEqual(e.project,original)
  }
  func testTextileMetadataMutationAndInvalidAttachmentAreAtomic() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let e=OperationEngine(repository:try ProjectRepository(root:root));e.project=Samples.flightJacket()
    let original=e.project!,part=original.objects.first{$0.textile?.attachment != nil}!
    var invalid=part.textile!;invalid.attachment!.garmentID=UUID()
    XCTAssertThrowsError(try e.call("form_batch",arguments:["operations":[
      ["name":"form_update_object","arguments":["object_id":original.objects[0].id.uuidString,"parameters":["width":710]]],
      ["name":"form_update_object","arguments":["object_id":part.id.uuidString,"textile":try jsonObject(invalid)]]]]))
    XCTAssertEqual(e.project,original)
    var next=part.textile!;next.attachment!.offset = .init(25,40);next.backing="Sew-on, no adhesive"
    _=try e.call("form_update_object",arguments:["object_id":part.id.uuidString,"textile":try jsonObject(next)])
    XCTAssertEqual(e.project!.objects.first{$0.id==part.id}!.textile,next)
    e.undo();XCTAssertEqual(e.project,original)
    _=try e.call("form_duplicate_object",arguments:["object_id":part.id.uuidString,"mode":"variant"])
    XCTAssertNil(e.project!.objects.last!.textile?.attachment)
    XCTAssertNotEqual(e.project!.objects.last!.position,part.position)
    _=try e.call("form_add_object",arguments:["recipe_id":"textilePatch","textile":["kind":"patch","process":"printedPatch"]])
    XCTAssertEqual(e.project!.objects.last!.textile?.process,.printedPatch)
    XCTAssertEqual(e.project!.objects.last!.textile?.measurementsVerified,false)
  }
  func testRepositorySchemaAndFabricLibraryRoundTripWithoutPromotingLegacyProjects() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let repo=try ProjectRepository(root:root),p=Samples.flightJacket();try repo.save(p)
    let expected=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(p))
    XCTAssertEqual(try repo.load(p.id),expected)
    let legacy=Project(name:"Legacy");try repo.save(legacy);XCTAssertEqual(try repo.load(legacy.id).schemaVersion,1)
    var library=StudioLibrary();let index=library.materials.firstIndex{$0.id=="flight-nylon"}!
    library.materials[index].fabric!.inventoryMeters=8.5;library.materials[index].fabric!.supplier="Sample studio"
    try library.save(to:root);XCTAssertEqual(StudioLibrary.load(from:root),library)
    let old=Data("{\"materials\":[],\"equipment\":[]}".utf8)
    let upgraded=try JSONDecoder.form.decode(StudioLibrary.self,from:old)
    XCTAssertEqual(upgraded.materials.filter{$0.fabric != nil}.count,6)
    XCTAssertThrowsError(try FabricProfile(composition:"Nylon",structure:.woven,weightGSM:Double.nan).validate())
  }
  func testArtworkEditsLeaveGarmentAndIndependentComponentResourcesUntouched() throws {
    var p=Samples.flightJacket(),baseline=p
    let attached=p.objects.first{$0.textile?.attachment != nil}!,source=p.artworkOwner(attached)
    var art=source.artwork!;art.elements[0].stroke!.color="#FFCC44"
    try p.setArtwork(art,for:attached.id)
    XCTAssertEqual(p.objects.filter{$0.recipeID != "artboard"},baseline.objects.filter{$0.recipeID != "artboard"})
    XCTAssertEqual(p.editableArtwork(attached),art)
    let sameSource=p.objects.filter{$0.artworkSourceID==source.id};XCTAssertGreaterThan(sameSource.count,3)
    for object in sameSource {XCTAssertEqual(p.editableArtwork(object),art)}
    baseline.objects[0].textile!.notes="Different notes";XCTAssertEqual(p.objects[0].textile?.renderDefinition,baseline.objects[0].textile?.renderDefinition)
  }
}

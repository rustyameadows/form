import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class PaperMaterialityTests:XCTestCase {
  func testShoulderLegacyDecodeBoundsAndStrictPublicCommandUndo()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("paper-shoulder-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    var project=Project(name:"Editable relief")
    var object=try project.makeObject(recipeID:"paperEnvelope")
    let mark=ArtworkElement(kind:"rectangle",x:30,y:80,width:20,height:12,color:"#17283A")
    object.artwork = .init(elements:[mark]);project.objects=[object];engine.project=project
    func update(_ patch:[String:Any])throws {
      _=try engine.call("form_paper",arguments:["command":"set_finish","object_id":object.id.uuidString,"finish":patch])
    }
    try update(["kind":"letterpress","elementIDs":[mark.id.uuidString],"depthMM":0.12])
    let legacy=try XCTUnwrap(engine.project?.objects[0].paperConstruction?.finishes?.first)
    XCTAssertNil(legacy.shoulderRadiusMM)
    let encoded=try JSONEncoder.form.encode(legacy)
    XCTAssertNil((try JSONSerialization.jsonObject(with:encoded) as? [String:Any])?["shoulderRadiusMM"])
    XCTAssertEqual(try JSONDecoder.form.decode(PaperFinishAssignment.self,from:encoded),legacy)
    let before=try XCTUnwrap(engine.project),undoCount=engine.undoStack.count
    try update(["id":legacy.id.uuidString,"shoulderRadiusMM":0.18])
    let edited=try XCTUnwrap(engine.project)
    XCTAssertEqual(edited.minimumSchemaVersion,68)
    XCTAssertEqual(edited.objects[0].paperConstruction?.finishes?.first?.shoulderRadiusMM,0.18)
    XCTAssertEqual(edited.objects[0].paperConstruction?.finishes?.first?.depthMM,0.12)
    XCTAssertEqual(edited.objects[0].parameters,before.objects[0].parameters)
    XCTAssertEqual(edited.objects[0].artwork,before.objects[0].artwork)
    XCTAssertEqual(edited.objects[0].paperConstruction?.stock,before.objects[0].paperConstruction?.stock)
    XCTAssertEqual(engine.undoStack.count,undoCount+1)
    engine.undo();XCTAssertEqual(engine.project,before)
    engine.redo();XCTAssertEqual(engine.project,edited)
    try engine.flush()
    let reopened=try engine.repository.load(project.id)
    XCTAssertEqual(reopened.schemaVersion,68);XCTAssertEqual(reopened.objects,edited.objects)
    for invalid in [-0.001,2.001] {
      let retained=engine.project
      XCTAssertThrowsError(try update(["id":legacy.id.uuidString,"shoulderRadiusMM":invalid]))
      XCTAssertEqual(engine.project,retained)
    }
    XCTAssertThrowsError(try update(["id":legacy.id.uuidString,"shoulderWidthMM":0.1]))
    var invalid=legacy;invalid.shoulderRadiusMM = .nan;XCTAssertThrowsError(try invalid.validate())
    try update(["id":legacy.id.uuidString,"shoulderRadiusMM":0.0])
    XCTAssertEqual(engine.project?.objects[0].paperConstruction?.finishes?.first?.shoulderRadiusMM,0)
    try update(["id":legacy.id.uuidString,"shoulderRadiusMM":NSNull()])
    XCTAssertNil(engine.project?.objects[0].paperConstruction?.finishes?.first?.shoulderRadiusMM)
  }
  func testNestedPaperMaterialityRaisesOnlyItsSchemaAndRoundTrips()throws {
    var finish=PaperFinishAssignment(name:"Raised artwork",kind:.emboss,elementIDs:[UUID()],heightMM:0.1)
    finish.shoulderRadiusMM=0.15
    var edge=PaperStock(profile:.init());edge.profile!.edgeAppearance=PhysicalAppearance()
    let nested=SheetPanelFeatures(wrap:.init(stock:edge,turnInMM:4))
    func object()->ProductObject {.init(name:"Physical source",recipeID:"box",parameters:["width":100,"height":140,"depth":1])}
    var leaf=object();leaf.sheetAssembly = .init(publicationID:UUID(),leaves:[.init(finishes:[finish])])
    var enclosure=object();enclosure.sheetAssembly = .init(publicationID:UUID(),enclosure:[.init(id:"cover",name:"Cover",size:.init(100,140),finishes:[finish])])
    var wrap=object();wrap.sheetAssembly = .init(publicationID:UUID(),enclosure:[.init(id:"cover",name:"Cover",size:.init(100,140),features:nested)])
    var insert=object();insert.sheetAssembly = .init(publicationID:UUID(),enclosure:[.init(id:"cover",name:"Cover",size:.init(100,140),features:.init(recesses:[.init(id:"inset",origin:.init(10,10),size:.init(20,20),depthMM:0.2,insert:.init(stock:edge))]))])
    for source in [leaf,enclosure,wrap,insert] {
      var project=Project(name:"Nested optical controls");project.objects=[source]
      XCTAssertEqual(project.minimumSchemaVersion,68)
      let decoded=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(project))
      XCTAssertEqual(decoded.objects,project.objects);XCTAssertEqual(decoded.minimumSchemaVersion,68)
    }
    var material=Material("stock","Stock","Paper","#FFFFFF");material.paperStock=edge
    var resource=Project(name:"Saved edge stock");resource.materials=[material]
    XCTAssertEqual(resource.minimumSchemaVersion,68)
    resource.materials[0].paperStock?.profile?.edgeAppearance=nil
    XCTAssertEqual(resource.minimumSchemaVersion,57)
    resource.renderSettings = .init();XCTAssertEqual(resource.minimumSchemaVersion,67)
  }
}

import Foundation
import XCTest
@testable import FormCore

final class ClothSavedRecipeTests:XCTestCase {
  func testOpeningLegacySourceAndChangingSettingsNeverReplacesDeclaredRestMesh()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root)
    var project=Project(name:"Saved legacy height"),object=try project.makeObject(recipeID:"clothPanel")
    for i in object.cloth!.mesh.restPositionsMm.indices {object.cloth!.mesh.restPositionsMm[i].y=2*object["supportRadius"]+55}
    project.objects=[object];try repository.save(project)
    let reopened=try repository.load(project.id),original=try XCTUnwrap(reopened.objects[0].cloth),engine=OperationEngine(repository:repository)
    XCTAssertEqual(original.mesh,object.cloth!.mesh);engine.project=reopened
    var friction=original.settings;friction.friction=0.7
    let changed=try ClothDesign.updatingSettings(friction,for:reopened.objects[0],study:original)
    try engine.edit("Friction") {try $0.setCloth(changed,for:object.id)}
    XCTAssertEqual(engine.project!.objects[0].cloth!.mesh,original.mesh)
    try engine.flush();let savedFriction=try repository.load(project.id)
    XCTAssertEqual(savedFriction.objects[0].cloth!.mesh,original.mesh);XCTAssertEqual(savedFriction.objects[0].cloth!.settings.friction,0.7)
    var thickness=friction;thickness.collisionThicknessMm=3
    let thicker=try ClothDesign.updatingSettings(thickness,for:savedFriction.objects[0],study:changed)
    var expectedMesh=original.mesh;expectedMesh.pins[0].targetMm.y=2*object["supportRadius"]+1.5
    XCTAssertEqual(thicker.mesh,expectedMesh)
    try engine.edit("Contact thickness") {try $0.setCloth(thicker,for:object.id)}
    XCTAssertEqual(engine.project!.objects[0].cloth!.mesh.restPositionsMm,original.mesh.restPositionsMm)
    try engine.flush();XCTAssertEqual(try repository.load(project.id).objects[0].cloth!.mesh,expectedMesh)
    engine.undo();XCTAssertEqual(engine.project!.objects[0].cloth,changed)
    engine.undo();XCTAssertEqual(engine.project,reopened)
  }
  func testTangentSourceSettingsAndExplicitCustomPinHaveDistinctOwnership()throws {
    let object=try Project(name:"Current source").makeObject(recipeID:"clothPanel"),study=try XCTUnwrap(object.cloth)
    var settings=study.settings;settings.collisionThicknessMm=2
    let result=try ClothDesign.updatingSettings(settings,for:object,study:study)
    XCTAssertEqual(result.mesh.restPositionsMm,study.mesh.restPositionsMm)
    XCTAssertEqual(result.mesh.pins[0].targetMm.y,2*object["supportRadius"]+1,accuracy:1e-9)
    var custom=study;custom.mesh.pins[0].targetMm.y+=10
    let preserved=try ClothDesign.updatingSettings(settings,for:object,study:custom)
    XCTAssertEqual(preserved.mesh,custom.mesh)
    var geometry=object;geometry.parameters["width"]=400
    XCTAssertNotEqual(try ClothDesign.definition(for:geometry).mesh.restPositionsMm,study.mesh.restPositionsMm)
  }
}

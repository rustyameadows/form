import Foundation
import XCTest
import FormCADModel
@testable import FormCore

final class PlanarSolidRequirementTests:XCTestCase {
  private func definition() -> PlanarConstructionDefinition {
    var source=ConstructionCommands.example()
    source.solidChecks=[.init(id:"explicit-pair",firstPanelID:"base",secondPanelID:"left",
      metric:.interference,relation:.lessThanOrEqual,value:"depth*0.35",message:"Allow the declared crease zone")]
    source.version=2;return source
  }
  func testSavedVersionTwoRequirementsRoundTripAndOlderVersionsFailClosed() throws {
    let source=definition()
    XCTAssertNoThrow(try source.net())
    let restored=try JSONDecoder().decode(PlanarConstructionDefinition.self,from:JSONEncoder().encode(source))
    XCTAssertEqual(restored,source)
    var old=source;old.version=1;XCTAssertThrowsError(try old.net())
    old.solidChecks=nil;XCTAssertNoThrow(try old.net())
    old.version=3;XCTAssertNoThrow(try old.net())
    old.version=4;XCTAssertThrowsError(try old.net())
    var numeric=source;numeric.solidChecks![0].value=0
    let raw=try XCTUnwrap(jsonObject(numeric) as? [String:Any]),checks=try XCTUnwrap(raw["solidChecks"] as? [[String:Any]])
    XCTAssertEqual(checks[0]["value"] as? String,"0","CADScalar's established canonical encoding is an expression string")
    XCTAssertEqual(try JSONDecoder().decode(PlanarConstructionDefinition.self,from:JSONSerialization.data(withJSONObject:raw)),numeric)
    var legacy=raw,legacyChecks=checks;legacyChecks[0]["value"]=0.0;legacy["solidChecks"]=legacyChecks
    let decoded=try JSONDecoder().decode(PlanarConstructionDefinition.self,from:JSONSerialization.data(withJSONObject:legacy))
    XCTAssertEqual(try decoded.number(XCTUnwrap(decoded.solidChecks?.first).value),0)
    XCTAssertNoThrow(try decoded.net())
    XCTAssertEqual(try JSONDecoder().decode(PlanarConstructionDefinition.self,from:JSONEncoder().encode(decoded)),decoded)
  }
  func testInvalidPanelPairsMetricsExpressionsAndDuplicateChecksRejectBeforePublication() throws {
    let good=definition()
    var variants:[PlanarConstructionDefinition]=[]
    var bad=good;bad.solidChecks![0].secondPanelID="missing";variants.append(bad)
    bad=good;bad.solidChecks![0].secondPanelID="base";variants.append(bad)
    bad=good;bad.solidChecks![0].metric = .volume;variants.append(bad)
    bad=good;bad.solidChecks![0].value="missingParameter";variants.append(bad)
    bad=good;bad.solidChecks![0].value = -1;variants.append(bad)
    bad=good;bad.solidChecks![0].tolerance = .infinity;variants.append(bad)
    bad=good;bad.solidChecks!.append(bad.solidChecks![0]);variants.append(bad)
    for value in variants {XCTAssertThrowsError(try value.net())}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=Project(name:"Checks")
    let before=engine.project
    var raw=try XCTUnwrap(jsonObject(good) as? [String:Any])
    var checks=try XCTUnwrap(raw["solidChecks"] as? [[String:Any]]);checks[0]["secondPanel"]="left";raw["solidChecks"]=checks
    XCTAssertThrowsError(try engine.call("form_construction",arguments:["command":"create","definition":raw]))
    XCTAssertEqual(engine.project,before)
  }
  func testCoreNeverClaimsExactChecksPassedAndSavedSourcePreservesArtworkAndUndo() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=Project(name:"Checks")
    let created=try XCTUnwrap(engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(definition())]) as? [String:Any])
    let id=try XCTUnwrap(created["object_id"] as? String)
    XCTAssertEqual(created["solid_checks_status"] as? String,"not_evaluated")
    try engine.edit("Artwork"){project in project.objects[0].artwork = .init(background:"#FFFFFF",elements:[.init(kind:"text",x:40,y:50,text:"Original source")])}
    let before=engine.project!,undo=engine.undoStack.count
    XCTAssertThrowsError(try engine.call("form_construction",arguments:["command":"validate_cases","object_id":id])) {error in
      XCTAssertTrue(error.localizedDescription.contains("exact runtime"))
    }
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,undo)
    try engine.flush();let saved=try engine.repository.load(before.id)
    XCTAssertEqual(saved.objects,before.objects)
    let source=try PaperConstruction.definition(for:saved.objects[0])
    XCTAssertEqual(source.authored?.solidChecks,definition().solidChecks)
    _ = try engine.call("form_construction",arguments:["command":"parameter","object_id":id,"values":["width":140]])
    XCTAssertEqual(engine.project!.objects[0].artwork,before.objects[0].artwork)
    engine.undo();XCTAssertEqual(engine.project!.objects,before.objects)
  }
}

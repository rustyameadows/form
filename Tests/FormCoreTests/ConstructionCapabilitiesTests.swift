import Foundation
import XCTest
@testable import FormCore

final class ConstructionCapabilitiesTests:XCTestCase {
  func testDiscoveredVersionThreeExampleCreatesWithAccurateFieldsAndReadOnlyCapabilities()throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("construction-discovery-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:directory)}
    let engine=OperationEngine(repository:try ProjectRepository(root:directory))
    XCTAssertNil(engine.project)
    let value=try engine.call("form_construction",arguments:["command":"capabilities"])
    let capabilities=try XCTUnwrap(value as? [String:Any])
    XCTAssertNil(engine.project);XCTAssertTrue(engine.undoStack.isEmpty)
    XCTAssertTrue(try XCTUnwrap(capabilities["source_versions"] as? [Int]).contains(3))
    let example=try XCTUnwrap(capabilities["multi_component_example"] as? [String:Any])
    func catalog(_ key:String)throws->Set<String> {Set(try XCTUnwrap(capabilities[key] as? [String]))}
    func fields(_ raw:[String:Any],_ prefix:String)throws {
      let allowed=try catalog(prefix+"_fields"),required=try catalog(prefix+"_required_fields"),optional=try catalog(prefix+"_optional_fields")
      XCTAssertEqual(allowed,required.union(optional),prefix)
      XCTAssertTrue(required.isSubset(of:Set(raw.keys)),prefix)
      XCTAssertTrue(Set(raw.keys).isSubset(of:allowed),prefix)
    }
    try fields(example,"definition")
    let panels=try XCTUnwrap(example["panels"] as? [[String:Any]])
    XCTAssertTrue(try catalog("panel_fields").contains("cutouts"))
    for panel in panels {try fields(panel,"panel")}
    let cutout=try XCTUnwrap((panels[0]["cutouts"] as? [[String:Any]])?.first)
    try fields(cutout,"cutout")
    let kinds=try catalog("cutout_kinds")
    XCTAssertEqual(kinds,["cutout","window","slot","perforation"])
    for kind in kinds {
      XCTAssertEqual(try JSONDecoder.form.decode(PaperCutoutKind.self,from:JSONEncoder.form.encode(kind)).rawValue,kind)
    }
    let components=try XCTUnwrap(example["components"] as? [[String:Any]])
    XCTAssertEqual(components.count,2)
    for component in components {
      try fields(component,"component")
      XCTAssertEqual(Set(try XCTUnwrap(component["anchor"] as? [String:Any]).keys),try catalog("point2_fields"))
      for key in ["position","rotationDegrees"] {
        XCTAssertEqual(Set(try XCTUnwrap(component[key] as? [String:Any]).keys),try catalog("point3_fields"))
      }
    }
    let interior=try XCTUnwrap((example["interiors"] as? [[String:Any]])?.first)
    try fields(interior,"interior")
    let opening=try XCTUnwrap(interior["opening"] as? [String:Any]);try fields(opening,"opening")
    XCTAssertEqual(try catalog("opening_axes"),["x","y","z"])
    XCTAssertEqual(capabilities["opening_transverse_axes"] as? [String:[String]],["x":["y","z"],"y":["x","z"],"z":["x","y"]])
    let limits=try XCTUnwrap(capabilities["limits"] as? [String:Any])
    XCTAssertEqual((limits["components"] as? NSNumber)?.intValue,32);XCTAssertEqual((limits["interiors"] as? NSNumber)?.intValue,64)
    XCTAssertEqual((limits["cutouts_per_panel"] as? NSNumber)?.intValue,64)

    engine.project=Project(name:"Discovered source")
    let before=engine.project!,history=engine.undoStack.count
    _ = try engine.call("form_construction",arguments:["command":"capabilities"])
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,history)
    let response=try engine.call("form_construction",arguments:["command":"create","definition":example])
    let result=try XCTUnwrap(response as? [String:Any]),id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(result["object_id"] as? String)))
    let object=try XCTUnwrap(engine.project!.objects.first{$0.id==id}),source=try PaperConstruction.definition(for:object)
    XCTAssertEqual(source.authored?.version,3);XCTAssertEqual(try source.net().panels.count,2)
    XCTAssertEqual(try PaperConstructionEngine.resolvedComponents(source).count,2)
    XCTAssertEqual(try source.net().panels.first?.cutouts?.first?.id,"window")
    XCTAssertEqual(try PaperConstructionEngine.resolvedInteriors(source).first?.id,"review-volume")
    XCTAssertEqual(engine.undoStack.count,history+1)
    engine.undo();XCTAssertEqual(engine.project!.objects,before.objects);XCTAssertEqual(engine.project!.recipes,before.recipes)
    engine.redo();XCTAssertEqual(engine.project!.objects.first?.id,id)
  }
}

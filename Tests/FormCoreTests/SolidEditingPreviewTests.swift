import XCTest
@testable import FormCore

final class SolidEditingPreviewTests:XCTestCase {
  private func fixture()->Recipe {
    .init("profiledAssembly","Profiled assembly","cube","An editable repeated construction",[
      .init("ribs","Ribs",4,1...12,unit:"",step:1),
      .init("pitch","Pitch",6,3...12),
      .init("height","Height",40,20...80)
    ],solid:.init(spacing:"0.5",normalizeHeight:"height",fillVoids:true,nodes:[
      .init(kind:"sweep",count:"ribs",index:"i",sweep:.init(samples:"16",variable:"u",values:[
        "x":"i*pitch+sin(pi*u)","y":"height*u","z":"0","radiusX":"mix(1,0.2,u)","radiusY":"0.5"
      ],sides:8,initialNormal:["1","0","0"]))
    ],previewNodes:[
      .init(kind:"ellipsoid",values:["x":"(ribs-1)*pitch/2","y":"height/2","z":"0","radiusX":"ribs*pitch/2","radiusY":"height/2","radiusZ":"1"])
    ]))
  }

  func testEditingSelectionRetainsFullDefinitionAndPhysicalSettings()throws {
    let recipe=fixture(),solid=try XCTUnwrap(recipe.solid)
    let full=try solid.evaluate(recipe.defaults)
    let editing=try solid.evaluate(recipe.defaults,useEditingPreview:true)
    XCTAssertEqual(full.sweeps.count,4)
    XCTAssertTrue(full.primitives.isEmpty)
    XCTAssertTrue(editing.sweeps.isEmpty)
    XCTAssertEqual(editing.primitives.count,1)
    XCTAssertEqual(editing.primitives[0].values["x"],9)
    XCTAssertEqual(editing.spacing,full.spacing)
    XCTAssertEqual(editing.normalizeHeight,full.normalizeHeight)
    XCTAssertEqual(editing.fillVoids,full.fillVoids)
    let definition=solid.editingPreviewDefinition
    XCTAssertNil(definition.previewNodes)
    XCTAssertEqual(definition.nodes,solid.previewNodes)
    XCTAssertEqual(try definition.evaluate(recipe.defaults).primitives.map(\.values),editing.primitives.map(\.values))
    XCTAssertEqual(solid.nodes.count,1,"Selecting the editing representation cannot rewrite retained source.")
    XCTAssertEqual(try solid.evaluate(recipe.defaults).sweeps.count,4,"Default evaluation must keep full geometry.")
    var changed=recipe.defaults;changed["ribs"]=8;changed["height"]=70
    XCTAssertEqual(try solid.evaluate(changed).sweeps.count,8)
    let changedPreview=try solid.evaluate(changed,useEditingPreview:true)
    XCTAssertEqual(changedPreview.primitives[0].values["radiusY"],35)
    XCTAssertEqual(changedPreview.normalizeHeight,70)
  }

  func testLegacySourceRoundTripsWithoutPreviewAndFallsBackToFullGeometry()throws {
    var legacy=try XCTUnwrap(fixture().solid);legacy.previewNodes=nil
    let encoded=try JSONEncoder().encode(legacy)
    let source=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
    XCTAssertNil(source["previewNodes"])
    let decoded=try JSONDecoder().decode(ParametricSolid.self,from:encoded)
    XCTAssertEqual(decoded,legacy)
    XCTAssertNil(decoded.previewNodes)
    XCTAssertEqual(decoded.editingPreviewDefinition,decoded)
    let parameters=fixture().defaults
    XCTAssertEqual(try decoded.evaluate(parameters,useEditingPreview:true).sweeps.map(\.sections),try decoded.evaluate(parameters).sweeps.map(\.sections))
    let withPreview=try XCTUnwrap(fixture().solid)
    XCTAssertEqual(try JSONDecoder().decode(ParametricSolid.self,from:JSONEncoder().encode(withPreview)),withPreview)
  }

  func testValidationChecksBothDefinitionsWithoutDoubleEvaluatingSelectedSource()throws {
    let recipe=fixture(),original=try XCTUnwrap(recipe.solid)
    try original.validateDefinitions(recipe.defaults)
    var invalidPreview=original;invalidPreview.previewNodes=[]
    XCTAssertNoThrow(try invalidPreview.evaluate(recipe.defaults),"Full evaluation is independent from preview evaluation.")
    XCTAssertThrowsError(try invalidPreview.evaluate(recipe.defaults,useEditingPreview:true))
    XCTAssertThrowsError(try invalidPreview.validateDefinitions(recipe.defaults))
    invalidPreview=original;invalidPreview.previewNodes![0].values!["radiusY"]="unknownParameter"
    XCTAssertThrowsError(try invalidPreview.validateDefinitions(recipe.defaults))
    var invalidFull=original;invalidFull.nodes[0].sweep!.values["x"]="unknownParameter"
    XCTAssertNoThrow(try invalidFull.evaluate(recipe.defaults,useEditingPreview:true),"Editing evaluates only the selected representation.")
    XCTAssertThrowsError(try invalidFull.validateDefinitions(recipe.defaults),"Mutation-time validation must still protect retained full source.")
  }

  func testMalformedPreviewCannotCreateOrReplaceProjectRecipe()throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:directory)}
    let engine=OperationEngine(repository:try ProjectRepository(root:directory))
    _ = try engine.call("form_create_project",arguments:["name":"Editable construction"])
    let recipe=fixture(),emptyProject=engine.project!
    var invalid=recipe;invalid.solid!.previewNodes=[]
    XCTAssertThrowsError(try engine.call("form_create_recipe",arguments:["recipe":try jsonObject(invalid)]))
    XCTAssertEqual(engine.project,emptyProject)
    _ = try engine.call("form_create_recipe",arguments:["recipe":try jsonObject(recipe)])
    _ = try engine.call("form_add_object",arguments:["recipe_id":recipe.id])
    let accepted=engine.project!
    invalid=recipe;invalid.solid!.previewNodes![0].values!["radiusX"]="-1"
    XCTAssertThrowsError(try engine.call("form_create_recipe",arguments:["recipe":try jsonObject(invalid),"replace":true]))
    XCTAssertEqual(engine.project,accepted,"Rejected alternate geometry cannot alter existing project data.")
    try engine.flush()
    let reopened=try engine.repository.load(accepted.id)
    XCTAssertEqual(reopened.recipes,accepted.recipes)
    XCTAssertEqual(reopened.minimumSchemaVersion,57)
    XCTAssertEqual(reopened.schemaVersion,57)
    let solid=try XCTUnwrap(reopened.recipes.first?.solid)
    XCTAssertEqual(solid.previewNodes,recipe.solid?.previewNodes)
  }

  func testCancelledEvaluationDoesNotPublishFullOrEditingGeometry()async throws {
    let recipe=fixture(),solid=try XCTUnwrap(recipe.solid),parameters=recipe.defaults
    for editing in [false,true] {
      let evaluation=Task.detached { ()throws->Int in
        withUnsafeCurrentTask {$0?.cancel()}
        let result=try solid.evaluate(parameters,useEditingPreview:editing)
        return result.primitives.count+result.sweeps.count
      }
      do {
        _ = try await evaluation.value
        XCTFail("Cancelled geometry work must throw before returning a result.")
      }catch {XCTAssertTrue(error is CancellationError,"Unexpected cancellation result: \(error)")}
    }
  }
}

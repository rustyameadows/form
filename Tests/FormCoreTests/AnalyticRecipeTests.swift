import XCTest
@testable import FormCore

final class AnalyticRecipeTests: XCTestCase {
  private func fixture() -> Recipe {
    .init("curvedRibs", "Curved ribs", "cube", "A repeated assembly of profiled ribs", [
      .init("count", "Count", 4, 1...12, unit: "", step: 1),
      .init("pitch", "Pitch", 5, 2...12),
      .init("length", "Length", 30, 15...60),
      .init("lift", "Lift", 3, 0...8)
    ], solid: .init(nodes: [
      .init(kind: "sweep", count: "count", index: "i", bindings: [.init("offset", "i*pitch")], sweep: .init(
        samples: "12", variable: "u", bindings: [.init("bend", "lift*sin(pi*u)"), .init("sectionX", "offset+bend")],
        values: ["x": "sectionX", "y": "length*u", "z": "0", "radiusX": "mix(1,0.1,u)", "radiusY": "0.4", "roll": "u*0.2"],
        profile: [[-1,-0.8],[-0.8,-1],[0.8,-1],[1,-0.8],[1,0.8],[0.8,1],[-0.8,1],[-1,0.8]],
        initialNormal: ["1", "0", "0"], smoothProfile: false
      ))
    ]))
  }

  func testRepeatedParameterizedSweepsPreserveBindingsAndDeterministicSections() throws {
    let recipe = fixture(), solid = try XCTUnwrap(recipe.solid)
    let first = try solid.evaluate(recipe.defaults), second = try solid.evaluate(recipe.defaults)
    XCTAssertTrue(first.primitives.isEmpty)
    XCTAssertEqual(first.sweeps.count, 4)
    XCTAssertEqual(first.sweeps.map(\.sections), second.sweeps.map(\.sections))
    XCTAssertEqual(first.sweeps[0].sections.count, 12)
    XCTAssertEqual(first.sweeps[0].sections[0]["x"], 0)
    XCTAssertEqual(first.sweeps[3].sections[0]["x"], 15)
    XCTAssertEqual(first.sweeps[3].sections[11]["y"], 30)
    XCTAssertEqual(first.sweeps[0].initialNormal, [1,0,0])
    XCTAssertFalse(first.sweeps[0].smoothProfile)
    var parameters = recipe.defaults; parameters["count"] = 7; parameters["length"] = 48
    let changed = try solid.evaluate(parameters)
    XCTAssertEqual(changed.sweeps.count, 7)
    XCTAssertEqual(changed.sweeps[6].sections[11]["y"], 48)
    XCTAssertEqual(changed.sweeps[6].sections[0]["x"], 30)
  }

  func testSweepScopeRejectsShadowingAndDoesNotLeakBetweenSiblings() throws {
    let recipe = fixture(), original = try XCTUnwrap(recipe.solid)
    var siblings = original
    siblings.nodes.append(original.nodes[0])
    XCTAssertEqual(try siblings.evaluate(recipe.defaults).sweeps.count, 8)
    var invalid = original
    invalid.nodes[0].sweep!.bindings = [.init("count", "u")]
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults))
    invalid = original; invalid.nodes[0].sweep!.bindings = [.init("bend", "u"), .init("bend", "u+1")]
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults))
    invalid = original; invalid.nodes[0].sweep!.variable = "i"
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults))
    invalid = original; invalid.nodes[0].sweep!.bindings = [.init("bend", "later"), .init("later", "u")]
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults))
    invalid = original; invalid.nodes[0].sweep!.initialNormal = ["u", "0", "0"]
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults))
    // An index cannot silently shadow a parameter merely by omitting count.
    invalid = original; invalid.nodes[0].count = nil; invalid.nodes[0].index = "length"
    invalid.nodes[0].bindings = [.init("offset", "0")]
    invalid.nodes[0].sweep!.values["y"] = "30*u"
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults))
  }

  func testInvalidProfilesAndUnrenderableFramesAreRejectedBeforePublishing() throws {
    let recipe = fixture(), original = try XCTUnwrap(recipe.solid)
    for profile in [
      [[-1.0,-1],[1,1],[-1,1],[1,-1]],
      [[0.0,0],[1,0],[2,0]],
      [[0.0,0],[1,0],[2,0],[2,1],[0,1]],
      [[0.0,0],[1,0],[1,0],[0,1]]
    ] {
      var invalid = original; invalid.nodes[0].sweep!.profile = profile
      XCTAssertThrowsError(try invalid.evaluate(recipe.defaults), "Invalid profile \(profile) must fail in core validation.")
    }
    var invalid = original
    invalid.nodes[0].sweep!.initialNormal = ["0", "1", "0"]
    invalid.nodes[0].sweep!.values["x"] = "offset"
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults), "An axis parallel to the first tangent cannot establish a frame.")
    invalid = original
    invalid.nodes[0].sweep!.samples = "3"
    invalid.nodes[0].sweep!.values["x"] = "0"
    invalid.nodes[0].sweep!.values["y"] = "sin(pi*u)"
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults), "An exact path reversal has no transported section frame.")
  }

  func testSampleProfileRadiusAndExpandedTriangleBudgets() throws {
    let recipe = fixture(), original = try XCTUnwrap(recipe.solid)
    for samples in ["1", "129", "12.5"] {
      var invalid = original; invalid.nodes[0].sweep!.samples = samples
      XCTAssertThrowsError(try invalid.evaluate(recipe.defaults))
    }
    var invalid = original
    invalid.nodes[0].sweep!.sides = 16
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults), "A custom profile and ellipse sides are mutually exclusive.")
    invalid = original; invalid.nodes[0].sweep!.values["radiusY"] = "0.004"
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults))
    invalid = original; invalid.nodes[0].sweep!.values["unknown"] = "1"
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults))
    invalid = original; invalid.floorY = "0"
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults), "Implicit floor trimming cannot silently alter an analytic assembly.")
    invalid = original; invalid.nodes[0].sweep!.profile = nil; invalid.nodes[0].sweep!.sides = 64
    invalid.nodes[0].sweep!.samples = "128"; invalid.nodes[0].count = "1000"
    XCTAssertThrowsError(try invalid.evaluate(recipe.defaults), "Expanded surfaces must respect the aggregate triangle budget.")
  }

  func testSweepRecipeReplacementUndoAndSchema62Persistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = OperationEngine(repository: try ProjectRepository(root: root))
    _ = try engine.call("form_create_project", arguments: ["name": "Profile construction"])
    let recipe = fixture()
    _ = try engine.call("form_create_recipe", arguments: ["recipe": try jsonObject(recipe)])
    _ = try engine.call("form_add_object", arguments: ["recipe_id": recipe.id, "parameters": ["count": 6]])
    let before = engine.project!
    XCTAssertEqual(before.minimumSchemaVersion, 62)
    var changed = recipe; changed.solid!.nodes[0].sweep!.values["radiusY"] = "0.6"
    _ = try engine.call("form_create_recipe", arguments: ["recipe": try jsonObject(changed), "replace": true])
    XCTAssertEqual(engine.project!.objects[0]["count"], 6)
    engine.undo(); XCTAssertEqual(engine.project, before)
    engine.redo(); try engine.flush()
    let restored = try engine.repository.load(engine.project!.id)
    XCTAssertEqual(restored.schemaVersion, 62)
    XCTAssertEqual(restored.recipes, engine.project!.recipes)
    XCTAssertEqual(restored.objects, engine.project!.objects)
    let solid = try XCTUnwrap(restored.recipes.first?.solid)
    XCTAssertEqual(try solid.evaluate(restored.objects[0].parameters).sweeps.count, 6)
    let noSweep = ParametricSolid(nodes: [.init(kind: "ellipsoid", values: ["x":"0","y":"0","z":"0","radiusX":"1","radiusY":"1","radiusZ":"1"])])
    XCTAssertFalse(noSweep.hasAnalyticSweeps)
    XCTAssertTrue(solid.hasAnalyticSweeps)
  }
}

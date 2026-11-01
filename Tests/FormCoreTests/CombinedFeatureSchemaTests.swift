import XCTest
import FormCADModel
@testable import FormCore

final class CombinedFeatureSchemaTests: XCTestCase {
  private func fixture() -> Project {
    let recipe = Recipe("combinedSolid", "Combined solid", "cube", "Generic schema fixture",
      [.init("radius", "Radius", 3, 1...10)],
      solid: .init(nodes: [.init(kind: "ellipsoid", values: [
        "x": "0", "y": "3", "z": "0", "radiusX": "radius", "radiusY": "3", "radiusZ": "3"
      ])]))
    let source = ProductObject(name: "Source", recipeID: recipe.id, parameters: recipe.defaults)
    var view = ArtworkElement(kind: "rectangle", x: 0, y: 0)
    view.objectView = .init(sourceID: source.id)
    view.paintStack = [.init(.init(color: "#123456"))]
    var image = ArtworkElement(kind: "image", x: 70, y: 0, asset: "generated.png")
    image.imageGeneration = .init(createdAt: Date(timeIntervalSince1970: 123456),
      prompt: "An abstract study", model: "local", provider: "Local demo",
      isDemo: true, settings: [:], outputSHA256: String(repeating: "a", count: 64),
      pixelWidth: 64, pixelHeight: 64)
    var project = Project(name: "Combined features")
    project.recipes = [recipe]
    project.fontLibrary = .init(faceNames: ["Helvetica"])
    project.objects = [source, ProductObject(name: "Page", recipeID: "artboard", parameters: [:],
      artwork: Artwork(elements: [view, image]))]
    return project
  }

  func testAllFeaturesPersistAtHighestSchemaWithoutDroppingMetadata() throws {
    let project = fixture()
    XCTAssertEqual(project.minimumSchemaVersion, 62)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ProjectRepository(root: root)
    try repository.save(project)
    let reopened = try repository.load(project.id)
    XCTAssertEqual(reopened.schemaVersion, 62)
    XCTAssertEqual(reopened.recipes, project.recipes)
    XCTAssertEqual(reopened.fontLibrary, project.fontLibrary)
    XCTAssertEqual(reopened.objects, project.objects)
    var withoutSolid = project
    withoutSolid.recipes = []
    XCTAssertEqual(withoutSolid.minimumSchemaVersion, 61)
    withoutSolid.objects[1].artwork?.elements[0].objectView = nil
    XCTAssertEqual(withoutSolid.minimumSchemaVersion, 60)
    withoutSolid.objects[1].artwork?.elements[1].imageGeneration = nil
    XCTAssertEqual(withoutSolid.minimumSchemaVersion, 59)
    withoutSolid.fontLibrary = nil
    XCTAssertEqual(withoutSolid.minimumSchemaVersion, 58)
  }

  func testRequirementsAndSolidValidationBothSurviveRecipeMerge() throws {
    var recipe = fixture().recipes[0]
    recipe.requirements = [.init(id: "radiusLimit", lhs: "radius", relation: .lessThanOrEqual,
      rhs: 8, message: "Radius must fit")]
    XCTAssertNoThrow(try recipe.validate(["radius": 4]))
    XCTAssertThrowsError(try recipe.validate(["radius": 9]))
    recipe.solid?.nodes[0].values?["radiusX"] = "0"
    XCTAssertThrowsError(try recipe.validate(["radius": 4]))
  }

  private func nestedProject(artwork:Artwork,inside:Bool)throws->Project {
    var project=Project(name:"Nested feature metadata")
    if inside {
      var paper=try project.makeObject(recipeID:"paperEnvelope")
      var definition=try PaperConstruction.definition(for:paper)
      definition.insideArtwork=artwork;paper.paperConstruction=definition;paper.artwork=nil
      project.objects=[paper]
    } else {
      let feature=CADFeatureNode(name:"Body",operation:.init(.box,values:["width":100,"height":20,"depth":50]))
      let definition=CADModelDefinition(name:"Body",features:[feature],outputs:[feature.id])
      let hash=String(repeating:"a",count:64)
      let component=CADComponentRepresentation(id:feature.id,name:"Body",brepAsset:"body.brep",brepSHA256:hash,
        meshAsset:"body.mesh",meshSHA256:hash,minimum:.init(),maximum:.init(100,20,50),volumeMM3:100000,
        valid:true,closed:true,solidCount:1,faceCount:6,edgeCount:12,vertexCount:8,triangleCount:12)
      var model=ProductObject(name:"Body",recipeID:"cadModel",parameters:[:])
      model.cadModel=definition
      model.cadRepresentation = .init(modelID:definition.id,definitionSHA256:try CADRepresentation.definitionHash(definition),
        kernelVersion:"test",components:[component])
      var detached=PhysicalSurfaceArtworkBinding(surfaceID:"top",sourceObjectID:UUID(),widthMM:100,heightMM:50)
      detached.sourceObjectID=nil;detached.artwork=artwork;model.surfaceArtworkBindings=[detached]
      project.objects=[model]
    }
    return project
  }

  func testNestedInsideAndDetachedSurfaceMetadataRequireTheirOwnSchemaAndRoundTrip()throws {
    var artwork=try XCTUnwrap(fixture().objects[1].artwork)
    artwork.elements[0].objectView=nil
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root)
    for inside in [true,false] {
      for generated in [true,false] {
        var source=artwork
        if !generated {source.elements[1].imageGeneration=nil}
        let project=try nestedProject(artwork:source,inside:inside),schema=generated ? 60:58
        XCTAssertTrue(project.objects.allSatisfy{$0.artwork==nil},"Only nested documents may select the schema in this regression.")
        XCTAssertEqual(project.minimumSchemaVersion,schema)
        try project.validateArtworkLinks()
        try repository.save(project)
        let reopened=try repository.load(project.id)
        XCTAssertEqual(reopened.schemaVersion,schema)
        XCTAssertEqual(reopened.objects,project.objects)
        XCTAssertEqual(reopened.storedArtworks,[source])
      }
    }
  }

  func testConstrainedSolidRecipeMCPReplacementPreservesRequirementsUndoAndRejectedParameterEdits()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    _ = try engine.call("form_create_project",arguments:["name":"Constrained replacement"])
    var recipe=fixture().recipes[0]
    recipe.requirements=[.init(id:"radiusLimit",lhs:"radius",relation:.lessThanOrEqual,rhs:8,message:"Radius must fit")]
    _ = try engine.call("form_create_recipe",arguments:["recipe":try jsonObject(recipe)])
    _ = try engine.call("form_add_object",arguments:["recipe_id":recipe.id,"parameters":["radius":4.0]])
    let before=try XCTUnwrap(engine.project),objectID=try XCTUnwrap(before.objects.first?.id)
    XCTAssertEqual(before.recipes[0].requirements,recipe.requirements)
    var replacement=recipe
    replacement.solid?.nodes[0].values?["radiusX"]="radius*2"
    _ = try engine.call("form_create_recipe",arguments:["recipe":try jsonObject(replacement),"replace":true])
    let after=try XCTUnwrap(engine.project),undo=engine.undoStack.count
    XCTAssertEqual(after.recipes[0],replacement)
    XCTAssertEqual(after.objects[0].parameters["radius"],4)
    XCTAssertEqual(after.minimumSchemaVersion,62)
    engine.undo();XCTAssertEqual(engine.project,before)
    engine.redo();XCTAssertEqual(engine.project,after)
    XCTAssertThrowsError(try engine.call("form_update_object",arguments:["object_id":objectID.uuidString,"parameters":["radius":9.0]]))
    XCTAssertEqual(engine.project,after);XCTAssertEqual(engine.undoStack.count,undo)
    // Defaults still pass; the existing object's retained value must be checked.
    var tooTight=replacement;tooTight.requirements![0].rhs=3.5
    XCTAssertThrowsError(try engine.call("form_create_recipe",arguments:["recipe":try jsonObject(tooTight),"replace":true]))
    XCTAssertEqual(engine.project,after);XCTAssertEqual(engine.undoStack.count,undo)
    try engine.flush()
    XCTAssertEqual(try engine.repository.load(after.id).recipes,[replacement])
  }

  func testMalformedAndUnboundedRequirementReplacementIsAtomicAndNullClearsOptionalRules()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    _ = try engine.call("form_create_project",arguments:["name":"Bounded replacement"])
    let recipe=fixture().recipes[0],raw=try XCTUnwrap(jsonObject(recipe) as? [String:Any])
    _ = try engine.call("form_create_recipe",arguments:["recipe":raw])
    let before=engine.project,undo=engine.undoStack.count
    let rule:[String:Any]=["id":"limit","lhs":"radius","relation":"<=","rhs":8.0,"message":"Radius must fit"]
    var oversized=rule;oversized["message"]=String(repeating:"x",count:512001)
    let malformed:[Any]=[Array(repeating:rule,count:129),[rule,rule],[oversized],"not a rule list"]
    for rules in malformed {
      var invalid=raw;invalid["requirements"]=rules
      XCTAssertThrowsError(try engine.call("form_create_recipe",arguments:["recipe":invalid,"replace":true]))
      XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,undo)
    }
    var nullable=raw;nullable["requirements"]=NSNull()
    XCTAssertNil(try decodeRecipe(nullable).requirements)
  }

  func testCanonicalArtworkRecipesStillAllowNoPlaceholderGeometry() throws {
    let recipe = try decodeRecipe(["id": "emptySource", "name": "Artwork source",
      "parameters": [["id": "width", "name": "Width", "value": 10.0, "minimum": 1.0, "maximum": 100.0]],
      "parts": [] as [[String: Any]]])
    XCTAssertTrue(recipe.parts.isEmpty)
    XCTAssertNil(recipe.solid)
    var project = Project(name: "Existing project")
    project.schemaVersion = 57
    project.recipes = [recipe]
    XCTAssertEqual(project.minimumSchemaVersion, 57)
  }
}
